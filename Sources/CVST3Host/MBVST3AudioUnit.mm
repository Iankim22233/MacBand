#import "MBVST3.h"
#import <AppKit/AppKit.h>
#import <CoreAudioKit/CoreAudioKit.h>

#include <atomic>
#include <memory>
#include <vector>
#include <string>
#include <mutex>

#include "public.sdk/source/vst/hosting/module.h"
#include "public.sdk/source/vst/hosting/hostclasses.h"
#include "public.sdk/source/vst/hosting/processdata.h"
#include "public.sdk/source/vst/hosting/eventlist.h"
#include "public.sdk/source/vst/hosting/parameterchanges.h"
#include "public.sdk/source/common/memorystream.h"
#include "pluginterfaces/base/funknown.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstmidicontrollers.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/vstspeaker.h"

using namespace Steinberg;
using namespace Steinberg::Vst;

// MARK: - Host-side interface implementations

namespace {

class ComponentHandler : public IComponentHandler {
public:
    ParameterChangeTransfer *transfer = nullptr;
    tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API performEdit(ParamID id, ParamValue value) override {
        if (transfer) transfer->addChange(id, value, 0);
        return kResultOk;
    }
    tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API restartComponent(int32) override { return kResultOk; }

    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override {
        QUERY_INTERFACE(iid, obj, FUnknown::iid, IComponentHandler)
        QUERY_INTERFACE(iid, obj, IComponentHandler::iid, IComponentHandler)
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return ++refs; }
    uint32 PLUGIN_API release() override { uint32 r = --refs; if (r == 0) delete this; return r; }
private:
    std::atomic<uint32> refs{1};
};

class PlugFrame : public IPlugFrame {
public:
    __weak NSViewController *owner = nil;
    tresult PLUGIN_API resizeView(IPlugView *view, ViewRect *newSize) override;
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) override {
        QUERY_INTERFACE(iid, obj, FUnknown::iid, IPlugFrame)
        QUERY_INTERFACE(iid, obj, IPlugFrame::iid, IPlugFrame)
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1000; }
    uint32 PLUGIN_API release() override { return 1000; }
};

struct PluginInfo {
    std::string path, classID, name;
    bool instrument;
};

NSMutableDictionary<NSNumber *, NSDictionary *> *Registry() {
    static NSMutableDictionary *r = [NSMutableDictionary new];
    return r;
}

struct Instance {
    VST3::Hosting::Module::Ptr module;
    IPtr<HostApplication> host;
    IPtr<IComponent> component;
    IPtr<IAudioProcessor> processor;
    IPtr<IEditController> controller;
    IPtr<ComponentHandler> handler;
    FUnknownPtr<IMidiMapping> midiMapping;
    bool separateController = false;
    bool isInstrument = false;
    bool hasEventIn = false;
    int32 outChannels = 2, inChannels = 0;
    ParameterChangeTransfer transfer{512};
    HostProcessData data;
    EventList events{1024};
    EventList outEvents{256};
    ParameterChanges params{128};
    ParameterChanges outParams{32};
    ProcessContext context{};
    bool active[16][128] = {};
    uint64 samplePos = 0;
    std::vector<std::vector<float>> inScratch;
    AudioBufferList *inList = nullptr;
    bool processing = false;
    int32 maxFrames = 4096;
    double sampleRate = 44100;
    std::atomic<double> hostTempo{120}, hostBeat{0};
    std::atomic<bool> hostPlaying{false};
    std::atomic<uint32> hostSerial{0};
    uint32 seenSerial = 0;
    double beatBase = 0; uint64 beatSampleBase = 0;
};

std::string ToUTF8(const TChar *s) {
    NSString *str = [NSString stringWithCharacters:(const unichar *)s length:std::char_traits<char16_t>::length((const char16_t *)s)];
    return str.UTF8String ?: "";
}

} // namespace

// MARK: - View controller for the plugin editor

@interface MBVST3ViewController : NSViewController {
@public
    IPtr<IPlugView> plugView;
    PlugFrame *frame;
    NSSize contentSize;
    BOOL attached;
}
@end

tresult PLUGIN_API PlugFrame::resizeView(IPlugView *view, ViewRect *newSize) {
    NSViewController *vc = owner;
    if (!vc || !newSize) return kResultFalse;
    NSSize size = NSMakeSize(newSize->getWidth(), newSize->getHeight());
    ViewRect rect = *newSize;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSViewController *c = owner;
        if (!c) return;
        c.view.frame = NSMakeRect(0, 0, size.width, size.height);
        c.preferredContentSize = size;
        ViewRect r2 = rect;
        if (view) view->onSize(&r2);
    });
    return kResultOk;
}

@implementation MBVST3ViewController
- (void)loadView {
    ViewRect r{};
    plugView->getSize(&r);
    contentSize = NSMakeSize(MAX(r.getWidth(), 50), MAX(r.getHeight(), 50));
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)];
    self.view = v;
    self.preferredContentSize = contentSize;
    plugView->setFrame(frame);
    if (plugView->attached((__bridge void *)v, kPlatformTypeNSView) == kResultOk) attached = YES;
}
- (void)viewDidLayout {
    [super viewDidLayout];
    if (attached && plugView->canResize() == kResultTrue) {
        NSSize s = self.view.bounds.size;
        ViewRect r(0, 0, (int32)s.width, (int32)s.height);
        plugView->checkSizeConstraint(&r);
        plugView->onSize(&r);
    }
}
- (void)dealloc {
    if (plugView) {
        if (attached) plugView->removed();
        plugView->setFrame(nullptr);
    }
    delete frame;
}
@end

// MARK: - The audio unit

@implementation MBVST3AudioUnit {
    std::shared_ptr<Instance> _inst;
    AUAudioUnitBusArray *_inputs;
    AUAudioUnitBusArray *_outputs;
    NSString *_name;
}

+ (BOOL)registerPluginAtPath:(NSString *)path classID:(NSString *)classID name:(NSString *)name instrument:(BOOL)isInstrument subtype:(UInt32)subtype {
    @synchronized (self) {
        Registry()[@(subtype)] = @{@"path": path, @"cid": classID, @"name": name, @"inst": @(isInstrument)};
    }
    AudioComponentDescription desc = {};
    desc.componentType = isInstrument ? kAudioUnitType_MusicDevice : kAudioUnitType_Effect;
    desc.componentSubType = subtype;
    desc.componentManufacturer = 'MBnd';
    [AUAudioUnit registerSubclass:self asComponentDescription:desc name:[@"MacBand VST3: " stringByAppendingString:name] version:1];
    return YES;
}

+ (NSArray<NSDictionary *> *)scanBundleAtPath:(NSString *)path {
    std::string err;
    auto module = VST3::Hosting::Module::create(path.UTF8String, err);
    if (!module) return @[];
    NSMutableArray *out = [NSMutableArray new];
    auto &factory = module->getFactory();
    auto finfo = factory.info();
    for (auto &ci : factory.classInfos()) {
        if (ci.category() != kVstAudioEffectClass) continue;
        bool inst = false;
        for (auto &sc : ci.subCategories()) if (sc == "Instrument") inst = true;
        NSString *vendor = ci.vendor().empty() ? [NSString stringWithUTF8String:finfo.vendor().c_str()] : [NSString stringWithUTF8String:ci.vendor().c_str()];
        [out addObject:@{@"name": [NSString stringWithUTF8String:ci.name().c_str()],
                         @"vendor": vendor ?: @"",
                         @"classID": [NSString stringWithUTF8String:ci.ID().toString().c_str()],
                         @"instrument": @(inst)}];
    }
    return out;
}

- (instancetype)initWithComponentDescription:(AudioComponentDescription)desc options:(AudioComponentInstantiationOptions)options error:(NSError **)outError {
    self = [super initWithComponentDescription:desc options:options error:outError];
    if (!self) return nil;

    NSDictionary *info;
    @synchronized ([MBVST3AudioUnit class]) { info = Registry()[@(desc.componentSubType)]; }
    if (!info) {
        if (outError) *outError = [NSError errorWithDomain:@"MacBand" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Unknown VST3 plugin."}];
        return nil;
    }
    _name = info[@"name"];
    __block NSString *failure = nil;
    __block std::shared_ptr<Instance> made;
    void (^load)(void) = ^{
        std::string err;
        auto inst = std::make_shared<Instance>();
        inst->isInstrument = [info[@"inst"] boolValue];
        inst->module = VST3::Hosting::Module::create([info[@"path"] UTF8String], err);
        if (!inst->module) { failure = [NSString stringWithFormat:@"Couldn't load %@ (%s)", info[@"name"], err.c_str()]; return; }
        inst->host = owned(new HostApplication());
        auto &factory = inst->module->getFactory();
        factory.setHostContext(inst->host.get());
        auto uid = VST3::UID::fromString(std::string([info[@"cid"] UTF8String]));
        if (!uid) { failure = @"Bad VST3 class ID."; return; }
        inst->component = factory.createInstance<IComponent>(*uid);
        if (!inst->component) { failure = @"The plugin couldn't create its audio component."; return; }
        if (inst->component->initialize(inst->host.get()) != kResultOk) { failure = @"The plugin failed to initialize."; return; }
        inst->processor = FUnknownPtr<IAudioProcessor>(inst->component);
        if (!inst->processor) { failure = @"The plugin has no audio processor."; return; }
        if (inst->processor->canProcessSampleSize(kSample32) != kResultTrue) { failure = @"The plugin doesn't support 32-bit processing."; return; }

        // Controller (same object, or a separate class connected to the component)
        inst->controller = FUnknownPtr<IEditController>(inst->component);
        if (!inst->controller) {
            TUID cid;
            if (inst->component->getControllerClassId(cid) == kResultTrue) {
                inst->controller = factory.createInstance<IEditController>(VST3::UID(cid));
                if (inst->controller) {
                    inst->controller->initialize(inst->host.get());
                    inst->separateController = true;
                }
            }
        }
        if (inst->controller) {
            inst->handler = owned(new ComponentHandler());
            inst->handler->transfer = &inst->transfer;
            inst->controller->setComponentHandler(inst->handler.get());
            if (inst->separateController) {
                FUnknownPtr<IConnectionPoint> a(inst->component), b(inst->controller);
                if (a && b) { a->connect(b); b->connect(a); }
                MemoryStream stream;
                if (inst->component->getState(&stream) == kResultOk) {
                    stream.seek(0, IBStream::kIBSeekSet, nullptr);
                    inst->controller->setComponentState(&stream);
                }
            }
            inst->midiMapping = FUnknownPtr<IMidiMapping>(inst->controller);
        }

        // Buses: stereo main in/out
        int32 nIn = inst->component->getBusCount(kAudio, kInput), nOut = inst->component->getBusCount(kAudio, kOutput);
        std::vector<SpeakerArrangement> inArr(nIn), outArr(nOut);
        for (int32 i = 0; i < nIn; i++) inst->processor->getBusArrangement(kInput, i, inArr[i]);
        for (int32 i = 0; i < nOut; i++) inst->processor->getBusArrangement(kOutput, i, outArr[i]);
        if (nIn > 0) inArr[0] = SpeakerArr::kStereo;
        if (nOut > 0) outArr[0] = SpeakerArr::kStereo;
        inst->processor->setBusArrangements(nIn ? inArr.data() : nullptr, nIn, nOut ? outArr.data() : nullptr, nOut);
        if (nIn > 0) { inst->component->activateBus(kAudio, kInput, 0, true); BusInfo bi{}; inst->component->getBusInfo(kAudio, kInput, 0, bi); inst->inChannels = bi.channelCount; }
        if (nOut > 0) { inst->component->activateBus(kAudio, kOutput, 0, true); BusInfo bi{}; inst->component->getBusInfo(kAudio, kOutput, 0, bi); inst->outChannels = bi.channelCount; }
        if (inst->component->getBusCount(kEvent, kInput) > 0) { inst->component->activateBus(kEvent, kInput, 0, true); inst->hasEventIn = true; }
        if (nOut == 0) { failure = @"The plugin has no audio output."; return; }
        made = inst;
    };
    if ([NSThread isMainThread]) load(); else dispatch_sync(dispatch_get_main_queue(), load);
    if (!made) {
        if (outError) *outError = [NSError errorWithDomain:@"MacBand" code:2 userInfo:@{NSLocalizedDescriptionKey: failure ?: @"VST3 load failed."}];
        return nil;
    }
    _inst = made;

    AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
    AUAudioUnitBus *outBus = [[AUAudioUnitBus alloc] initWithFormat:fmt error:nil];
    _outputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[outBus]];
    if (_inst->isInstrument || _inst->inChannels == 0) {
        _inputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[]];
    } else {
        AUAudioUnitBus *inBus = [[AUAudioUnitBus alloc] initWithFormat:fmt error:nil];
        _inputs = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[inBus]];
    }
    self.maximumFramesToRender = 4096;
    return self;
}

- (void)dealloc {
    std::shared_ptr<Instance> inst = _inst;
    _inst.reset();
    if (!inst) return;
    void (^teardown)(void) = ^{
        if (inst->processing) { inst->processor->setProcessing(false); }
        inst->component->setActive(false);
        if (inst->controller) {
            inst->controller->setComponentHandler(nullptr);
            if (inst->separateController) inst->controller->terminate();
        }
        inst->component->terminate();
    };
    if ([NSThread isMainThread]) teardown(); else dispatch_async(dispatch_get_main_queue(), teardown);
}

- (AUAudioUnitBusArray *)inputBusses { return _inputs; }
- (AUAudioUnitBusArray *)outputBusses { return _outputs; }
- (BOOL)supportsMPE { return NO; }
- (NSArray<NSNumber *> *)channelCapabilities { return _inst->isInstrument ? @[@0, @2] : @[@2, @2]; }

- (BOOL)shouldChangeToFormat:(AVAudioFormat *)format forBus:(AUAudioUnitBus *)bus {
    return format.channelCount >= 1 && format.channelCount <= 2 && format.commonFormat == AVAudioPCMFormatFloat32;
}

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)outError {
    if (![super allocateRenderResourcesAndReturnError:outError]) return NO;
    Instance &i = *_inst;
    i.sampleRate = _outputs[0].format.sampleRate;
    i.maxFrames = (int32)self.maximumFramesToRender;
    ProcessSetup setup{};
    setup.processMode = self.renderingOffline ? kOffline : kRealtime;
    setup.symbolicSampleSize = kSample32;
    setup.maxSamplesPerBlock = i.maxFrames;
    setup.sampleRate = i.sampleRate;
    i.processor->setupProcessing(setup);
    i.data.prepare(*i.component, i.maxFrames, kSample32);
    i.data.processMode = setup.processMode;
    i.data.symbolicSampleSize = kSample32;
    i.inScratch.assign(2, std::vector<float>(i.maxFrames, 0.f));
    i.inList = (AudioBufferList *)calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
    i.component->setActive(true);
    i.processor->setProcessing(true);
    i.processing = true;
    i.samplePos = 0;
    i.beatBase = i.hostBeat.load(); i.beatSampleBase = 0;
    return YES;
}

- (void)deallocateRenderResources {
    Instance &i = *_inst;
    if (i.processing) { i.processor->setProcessing(false); i.processing = false; }
    i.component->setActive(false);
    i.data.unprepare();
    if (i.inList) { free(i.inList); i.inList = nullptr; }
    [super deallocateRenderResources];
}

- (void)setHostTempo:(double)bpm beat:(double)beat playing:(BOOL)playing {
    if (!_inst) return;
    _inst->hostTempo = bpm; _inst->hostBeat = beat; _inst->hostPlaying = playing;
    _inst->hostSerial++;
}

// MARK: Render

static void AddParam(Instance &i, ParamID pid, ParamValue v, int32 offset) {
    int32 idx = 0;
    if (IParamValueQueue *q = i.params.addParameterData(pid, idx)) { int32 pi; q->addPoint(offset, v, pi); }
}

static void AllNotesOff(Instance &i, int32 offset) {
    for (int ch = 0; ch < 16; ch++) for (int p = 0; p < 128; p++) if (i.active[ch][p]) {
        i.active[ch][p] = false;
        Event e{}; e.busIndex = 0; e.sampleOffset = offset; e.type = Event::kNoteOffEvent;
        e.noteOff.channel = ch; e.noteOff.pitch = p; e.noteOff.velocity = 0; e.noteOff.noteId = ch * 128 + p; e.noteOff.tuning = 0;
        i.events.addEvent(e);
    }
}

static void HandleMIDI(Instance &i, const uint8_t *d, int len, int32 offset) {
    if (len < 1) return;
    uint8_t status = d[0] & 0xF0, ch = d[0] & 0x0F;
    uint8_t d1 = len > 1 ? d[1] & 0x7F : 0, d2 = len > 2 ? d[2] & 0x7F : 0;
    switch (status) {
        case 0x90:
            if (d2 > 0) {
                if (!i.hasEventIn) return;
                Event e{}; e.busIndex = 0; e.sampleOffset = offset; e.flags = Event::kIsLive; e.type = Event::kNoteOnEvent;
                e.noteOn.channel = ch; e.noteOn.pitch = d1; e.noteOn.velocity = d2 / 127.f; e.noteOn.length = 0; e.noteOn.tuning = 0; e.noteOn.noteId = ch * 128 + d1;
                if (i.events.addEvent(e) == kResultOk) i.active[ch][d1] = true;
                return;
            }
            // fallthrough: note on with velocity 0 == note off
        case 0x80: {
            if (!i.hasEventIn) return;
            Event e{}; e.busIndex = 0; e.sampleOffset = offset; e.flags = Event::kIsLive; e.type = Event::kNoteOffEvent;
            e.noteOff.channel = ch; e.noteOff.pitch = d1; e.noteOff.velocity = d2 / 127.f; e.noteOff.noteId = ch * 128 + d1; e.noteOff.tuning = 0;
            i.events.addEvent(e); i.active[ch][d1] = false;
            return;
        }
        case 0xB0:
            if (d1 == 123 || d1 == 120) { AllNotesOff(i, offset); return; }
            if (i.midiMapping) { ParamID pid; if (i.midiMapping->getMidiControllerAssignment(0, ch, d1, pid) == kResultTrue) AddParam(i, pid, d2 / 127.0, offset); }
            return;
        case 0xE0:
            if (i.midiMapping) { ParamID pid; if (i.midiMapping->getMidiControllerAssignment(0, ch, kPitchBend, pid) == kResultTrue) AddParam(i, pid, ((d2 << 7) | d1) / 16383.0, offset); }
            return;
        case 0xD0:
            if (i.midiMapping) { ParamID pid; if (i.midiMapping->getMidiControllerAssignment(0, ch, kAfterTouch, pid) == kResultTrue) AddParam(i, pid, d1 / 127.0, offset); }
            return;
        default: return;
    }
}

- (AUInternalRenderBlock)internalRenderBlock {
    std::shared_ptr<Instance> keep = _inst;
    Instance *ip = keep.get();
    __unsafe_unretained MBVST3AudioUnit *unit = self;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp, AVAudioFrameCount frames,
                              NSInteger outputBus, AudioBufferList *outputData, const AURenderEvent *eventHead, AURenderPullInputBlock pullInput) {
        Instance &i = *ip;   // `keep` is captured by the block, so the instance outlives rendering
        (void)keep;
        if ((int32)frames > i.maxFrames) return kAudioUnitErr_TooManyFramesToProcess;
        ProcessData &pd = i.data;
        uint32_t outCh = outputData->mNumberBuffers;

        // Input (effects)
        bool bypass = unit.shouldBypassEffect;
        if (!i.isInstrument && i.inChannels > 0 && pullInput) {
            i.inList->mNumberBuffers = 2;
            AudioBufferList *bl = (AudioBufferList *)alloca(sizeof(AudioBufferList) + sizeof(AudioBuffer));
            bl->mNumberBuffers = 2;
            for (int c = 0; c < 2; c++) { bl->mBuffers[c].mNumberChannels = 1; bl->mBuffers[c].mDataByteSize = frames * 4; bl->mBuffers[c].mData = i.inScratch[c].data(); }
            AudioUnitRenderActionFlags f = 0;
            if (pullInput(&f, timestamp, frames, 0, bl) == noErr && pd.numInputs > 0) {
                AudioBusBuffers &ib = pd.inputs[0];
                for (int32 c = 0; c < ib.numChannels; c++) {
                    const float *src = (const float *)bl->mBuffers[MIN(c, 1)].mData;
                    if (src && ib.channelBuffers32[c]) memcpy(ib.channelBuffers32[c], src, frames * 4);
                }
            }
            if (bypass) {
                for (uint32_t c = 0; c < outCh; c++) {
                    float *dst = (float *)outputData->mBuffers[c].mData;
                    if (!dst) { outputData->mBuffers[c].mData = i.inScratch[MIN(c, 1u)].data(); continue; }
                    memcpy(dst, bl->mBuffers[MIN(c, 1u)].mData, frames * 4);
                }
                return noErr;
            }
        }

        // Transport context
        uint32 serial = i.hostSerial.load();
        if (serial != i.seenSerial) { i.seenSerial = serial; i.beatBase = i.hostBeat.load(); i.beatSampleBase = i.samplePos; }
        double tempo = i.hostTempo.load();
        i.context = ProcessContext{};
        i.context.state = ProcessContext::kTempoValid | ProcessContext::kTimeSigValid | ProcessContext::kProjectTimeMusicValid |
                          (i.hostPlaying.load() ? ProcessContext::kPlaying : 0);
        i.context.sampleRate = i.sampleRate;
        i.context.projectTimeSamples = (TSamples)i.samplePos;
        i.context.tempo = tempo;
        i.context.timeSigNumerator = 4; i.context.timeSigDenominator = 4;
        i.context.projectTimeMusic = i.hostPlaying.load() ? i.beatBase + (double)(i.samplePos - i.beatSampleBase) / i.sampleRate * tempo / 60.0 : i.beatBase;
        pd.processContext = &i.context;

        // Events & parameters
        i.transfer.transferChangesTo(i.params);
        double sampleTime = timestamp->mSampleTime;
        for (const AURenderEvent *e = eventHead; e; e = e->head.next) {
            int32 off = (int32)(e->head.eventSampleTime - (AUEventSampleTime)sampleTime);
            off = MAX(0, MIN((int32)frames - 1, off));
            if (e->head.eventType == AURenderEventMIDI || e->head.eventType == AURenderEventMIDISysEx) {
                if (e->head.eventType == AURenderEventMIDI) HandleMIDI(i, e->MIDI.data, e->MIDI.length, off);
            } else if (e->head.eventType == AURenderEventMIDIEventList) {
                const MIDIEventList *list = &e->MIDIEventsList.eventList;
                const MIDIEventPacket *pk = &list->packet[0];
                for (UInt32 n = 0; n < list->numPackets; n++) {
                    for (UInt32 w = 0; w < pk->wordCount; w++) {
                        UInt32 word = pk->words[w];
                        if (((word >> 28) & 0xF) != 2) continue;
                        uint8_t bytes[3] = {(uint8_t)(word >> 16), (uint8_t)(word >> 8), (uint8_t)word};
                        HandleMIDI(i, bytes, 3, off);
                    }
                    pk = MIDIEventPacketNext(pk);
                }
            }
        }

        pd.numSamples = frames;
        pd.inputEvents = i.hasEventIn ? &i.events : nullptr;
        pd.outputEvents = &i.outEvents;
        pd.inputParameterChanges = &i.params;
        pd.outputParameterChanges = &i.outParams;
        for (int32 b = 0; b < pd.numOutputs; b++) pd.outputs[b].silenceFlags = 0;
        i.processor->process(pd);

        i.events.clear(); i.outEvents.clear(); i.params.clearQueue(); i.outParams.clearQueue();
        i.samplePos += frames;

        // Copy main output to the AU buffers
        if (pd.numOutputs > 0) {
            AudioBusBuffers &ob = pd.outputs[0];
            for (uint32_t c = 0; c < outCh; c++) {
                int32 sc = ob.numChannels == 1 ? 0 : MIN((int32)c, ob.numChannels - 1);
                float *dst = (float *)outputData->mBuffers[c].mData;
                float *src = ob.numChannels > 0 ? ob.channelBuffers32[sc] : nullptr;
                if (!dst) { outputData->mBuffers[c].mData = src; continue; }
                if (src) memcpy(dst, src, frames * 4); else memset(dst, 0, frames * 4);
            }
        }
        for (uint32_t c = 0; c < outCh; c++) outputData->mBuffers[c].mDataByteSize = frames * 4;
        return noErr;
    };
}

// MARK: State

- (NSDictionary<NSString *, id> *)fullState {
    NSMutableDictionary *d = [NSMutableDictionary new];
    if (!_inst) return d;
    MemoryStream cs;
    if (_inst->component->getState(&cs) == kResultOk && cs.getSize() > 0) d[@"vst3.component"] = [NSData dataWithBytes:cs.getData() length:(NSUInteger)cs.getSize()];
    if (_inst->controller && _inst->separateController) {
        MemoryStream ks;
        if (_inst->controller->getState(&ks) == kResultOk && ks.getSize() > 0) d[@"vst3.controller"] = [NSData dataWithBytes:ks.getData() length:(NSUInteger)ks.getSize()];
    }
    return d;
}

- (void)setFullState:(NSDictionary<NSString *, id> *)state {
    if (!_inst || ![state isKindOfClass:[NSDictionary class]]) return;
    NSData *c = state[@"vst3.component"], *k = state[@"vst3.controller"];
    void (^apply)(void) = ^{
        if ([c isKindOfClass:[NSData class]] && c.length) {
            MemoryStream s((void *)c.bytes, (TSize)c.length);
            _inst->component->setState(&s);
            if (_inst->controller) { s.seek(0, IBStream::kIBSeekSet, nullptr); _inst->controller->setComponentState(&s); }
        }
        if ([k isKindOfClass:[NSData class]] && k.length && _inst->controller) {
            MemoryStream s((void *)k.bytes, (TSize)k.length);
            _inst->controller->setState(&s);
        }
    };
    if ([NSThread isMainThread]) apply(); else dispatch_sync(dispatch_get_main_queue(), apply);
}

// MARK: Editor

- (void)requestViewControllerWithCompletionHandler:(void (^)(NSViewController * _Nullable))completionHandler {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_inst || !self->_inst->controller) { completionHandler(nil); return; }
        IPtr<IPlugView> view = owned(self->_inst->controller->createView(ViewType::kEditor));
        if (!view || view->isPlatformTypeSupported(kPlatformTypeNSView) != kResultTrue) { completionHandler(nil); return; }
        MBVST3ViewController *vc = [MBVST3ViewController new];
        vc->plugView = view;
        vc->frame = new PlugFrame();
        vc->frame->owner = vc;
        vc->attached = NO;
        completionHandler(vc);
    });
}

@end
