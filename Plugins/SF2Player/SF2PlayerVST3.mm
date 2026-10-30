// SF2 Player — VST3 wrapper around the shared SF2 core.
#import <Cocoa/Cocoa.h>
#include "base/source/fstreamer.h"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/base/ustring.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstmidicontrollers.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/vstspeaker.h"
#include "public.sdk/source/common/pluginview.h"
#include "public.sdk/source/vst/vstaudioeffect.h"
#include "public.sdk/source/vst/vsteditcontroller.h"
#include "SF2UI.h"

using namespace Steinberg;
using namespace Steinberg::Vst;
using namespace SF2Plugin;

static const FUID kProcessorUID(0x53463250, 0x4C415945, 0x52505243, 0x00000001);
static const FUID kControllerUID(0x53463250, 0x4C415945, 0x52434E54, 0x00000001);

// MARK: - Processor

class SF2Processor : public AudioEffect {
public:
    SF2Processor() {
        setControllerClass(kControllerUID);
        core = std::make_shared<Core>();
        core->initParams();
        coreID = registerCore(core);
        for (uint32_t i = 0; i < kNumParams; i++) normalized[i] = toNorm(i, def(i).def);
        normalized[kPreset] = core->presetIndex.load() / 4095.0;
    }

    tresult PLUGIN_API initialize(FUnknown *context) SMTG_OVERRIDE {
        tresult r = AudioEffect::initialize(context);
        if (r != kResultOk) return r;
        addEventInput(STR16("Events In"), 1);
        addAudioOutput(STR16("Stereo Out"), SpeakerArr::kStereo);
        return kResultOk;
    }
    tresult PLUGIN_API setBusArrangements(SpeakerArrangement *in, int32 nIn, SpeakerArrangement *out, int32 nOut) SMTG_OVERRIDE {
        if (nIn == 0 && nOut == 1 && out[0] == SpeakerArr::kStereo) return AudioEffect::setBusArrangements(in, nIn, out, nOut);
        return kResultFalse;
    }
    tresult PLUGIN_API connect(IConnectionPoint *other) SMTG_OVERRIDE {
        tresult r = AudioEffect::connect(other);
        if (IMessage *m = allocateMessage()) {
            FReleaser rel(m);
            m->setMessageID("SF2Core");
            m->getAttributes()->setInt("id", coreID);
            sendMessage(m);
        }
        return r;
    }
    tresult PLUGIN_API canProcessSampleSize(int32 s) SMTG_OVERRIDE { return s == kSample32 ? kResultTrue : kResultFalse; }
    tresult PLUGIN_API setupProcessing(ProcessSetup &setup) SMTG_OVERRIDE {
        core->synth.setSampleRate(setup.sampleRate);
        return AudioEffect::setupProcessing(setup);
    }
    tresult PLUGIN_API setActive(TBool state) SMTG_OVERRIDE {
        if (!state) core->synth.allSoundOff();
        return AudioEffect::setActive(state);
    }

    tresult PLUGIN_API process(ProcessData &data) SMTG_OVERRIDE {
        if (data.inputParameterChanges) {
            int32 n = data.inputParameterChanges->getParameterCount();
            for (int32 i = 0; i < n; i++) {
                IParamValueQueue *q = data.inputParameterChanges->getParameterData(i);
                if (!q || q->getParameterId() >= kNumParams) continue;
                for (int32 p = 0; p < q->getPointCount(); p++) { int32 off; ParamValue v; if (q->getPoint(p, off, v) == kResultTrue) applyParam(q->getParameterId(), v); }
            }
        }
        if (data.numOutputs < 1 || data.outputs[0].numChannels < 1) return kResultOk;
        const int32 frames = data.numSamples;
        float *l = data.outputs[0].channelBuffers32[0];
        float *r = data.outputs[0].numChannels > 1 ? data.outputs[0].channelBuffers32[1] : nullptr;
        if (!r) { scratch.resize(frames); r = scratch.data(); }
        int32 pos = 0;
        auto renderTo = [&](int32 end) { if (end > pos) { core->render(l + pos, r + pos, end - pos); pos = end; } };
        if (data.inputEvents) {
            int32 count = data.inputEvents->getEventCount();
            for (int32 i = 0; i < count; i++) {
                Event e;
                if (data.inputEvents->getEvent(i, e) != kResultOk) continue;
                renderTo(std::min(frames, std::max(pos, e.sampleOffset)));
                if (e.type == Event::kNoteOnEvent) { if (e.noteOn.velocity <= 0) core->synth.noteOff(e.noteOn.pitch); else core->synth.noteOn(e.noteOn.pitch, std::max(1, (int)std::lround(e.noteOn.velocity * 127))); }
                else if (e.type == Event::kNoteOffEvent) core->synth.noteOff(e.noteOff.pitch);
            }
        }
        renderTo(frames);
        data.outputs[0].silenceFlags = 0;
        return kResultOk;
    }

    tresult PLUGIN_API setState(IBStream *state) SMTG_OVERRIDE {
        IBStreamer s(state, kLittleEndian);
        int32 version = 0;
        if (!s.readInt32(version) || version != 1) return kResultFalse;
        double v[4]; for (int i = 0; i < 4; i++) { s.readDouble(v[i]); core->setParam(i, v[i]); normalized[i] = toNorm(i, v[i]); }
        int32 preset = 0, len = 0;
        s.readInt32(preset); s.readInt32(len);
        std::string path;
        if (len > 0 && len < 4096) { path.resize(len); s.readRaw(&path[0], len); }
        if (!path.empty()) {
            if (!core->loadFile(path, preset)) { /* error text is shown in the editor */ }
        } else core->selectPreset(preset, false);
        normalized[kPreset] = core->presetIndex.load() / 4095.0;
        return kResultOk;
    }
    tresult PLUGIN_API getState(IBStream *state) SMTG_OVERRIDE {
        IBStreamer s(state, kLittleEndian);
        s.writeInt32(1);
        for (int i = 0; i < 4; i++) s.writeDouble(core->value(i));
        s.writeInt32(core->presetIndex.load());
        std::string path; { std::lock_guard<std::mutex> l(core->mu); path = core->path; }
        s.writeInt32((int32)path.size());
        if (!path.empty()) s.writeRaw((void *)path.data(), (int32)path.size());
        return kResultOk;
    }

private:
    void applyParam(uint32_t id, double n) {
        normalized[id] = n;
        const int cc = (int)std::lround(n * 127);
        switch (id) {
            case kVolume: case kReverb: case kBendRange: case kTranspose: core->setParam(id, toPlain(id, n)); break;
            case kPreset: { int idx = (int)std::lround(n * 4095); core->selectPresetAsync(idx); break; }
            case kModWheel: core->synth.controller(1, cc); break;
            case kCC7: core->synth.controller(7, cc); break;
            case kCC10: core->synth.controller(10, cc); break;
            case kCC11: core->synth.controller(11, cc); break;
            case kSustain: core->synth.controller(64, cc); break;
            case kCC91: core->synth.controller(91, cc); break;
            case kBendWheel: core->synth.pitchBend((int)std::lround(n * 16383)); break;
        }
    }
    std::shared_ptr<Core> core;
    int64_t coreID = 0;
    double normalized[kNumParams];
    std::vector<float> scratch;
};

// MARK: - Controller & editor

class SF2Controller : public EditController, public IMidiMapping {
public:
    tresult PLUGIN_API initialize(FUnknown *context) SMTG_OVERRIDE {
        tresult r = EditController::initialize(context);
        if (r != kResultOk) return r;
        for (uint32_t i = 0; i < kNumParams; i++) {
            const ParamDef &d = def(i);
            parameters.addParameter(UString128(d.name), nullptr, d.steps, toNorm(i, d.def), d.hidden ? ParameterInfo::kIsHidden : ParameterInfo::kCanAutomate, i);
        }
        return kResultOk;
    }
    tresult PLUGIN_API notify(IMessage *message) SMTG_OVERRIDE {
        if (message && strcmp(message->getMessageID(), "SF2Core") == 0) {
            int64 id = 0;
            if (message->getAttributes()->getInt("id", id) == kResultOk) {
                core = findCore(id);
                if (core) core->onPresetChanged = [this] { double n = core->presetIndex.load() / 4095.0; setParamNormalized(kPreset, n); beginEdit(kPreset); performEdit(kPreset, n); endEdit(kPreset); };
            }
            return kResultOk;
        }
        return EditController::notify(message);
    }
    tresult PLUGIN_API terminate() SMTG_OVERRIDE { if (core) core->onPresetChanged = nullptr; core.reset(); return EditController::terminate(); }

    IPlugView *PLUGIN_API createView(FIDString name) SMTG_OVERRIDE;

    tresult PLUGIN_API getParamStringByValue(ParamID id, ParamValue norm, String128 string) SMTG_OVERRIDE {
        if (id >= kNumParams) return kResultFalse;
        char b[96];
        if (id == kPreset) {
            int idx = (int)std::lround(norm * 4095);
            std::shared_ptr<SF2::SoundFont> f; if (core) { std::lock_guard<std::mutex> l(core->mu); f = core->font; }
            if (f && idx < (int)f->presets.size()) snprintf(b, sizeof b, "%03d:%03d %s", f->presets[idx].bank, f->presets[idx].program, f->presets[idx].name.c_str());
            else snprintf(b, sizeof b, "#%d", idx + 1);
        } else if (id == kVolume || id == kReverb) snprintf(b, sizeof b, "%.0f%%", toPlain(id, norm) * 100);
        else snprintf(b, sizeof b, "%.0f", toPlain(id, norm));
        UString(string, 128).fromAscii(b);
        return kResultTrue;
    }
    tresult PLUGIN_API getParamValueByString(ParamID id, TChar *string, ParamValue &norm) SMTG_OVERRIDE {
        if (id >= kNumParams) return kResultFalse;
        char b[128]; UString128(string).toAscii(b, 128);
        double v = atof(b); if (id == kVolume || id == kReverb) v /= 100;
        norm = toNorm(id, v); return kResultTrue;
    }
    ParamValue PLUGIN_API normalizedParamToPlain(ParamID id, ParamValue v) SMTG_OVERRIDE { return id < kNumParams ? toPlain(id, v) : v; }
    ParamValue PLUGIN_API plainParamToNormalized(ParamID id, ParamValue v) SMTG_OVERRIDE { return id < kNumParams ? toNorm(id, v) : v; }

    tresult PLUGIN_API getMidiControllerAssignment(int32 bus, int16 ch, CtrlNumber n, ParamID &id) SMTG_OVERRIDE {
        if (bus != 0) return kResultFalse;
        switch (n) {
            case Steinberg::Vst::kPitchBend: id = kBendWheel; return kResultTrue;
            case 1: id = kModWheel; return kResultTrue;
            case 7: id = kCC7; return kResultTrue;
            case 10: id = kCC10; return kResultTrue;
            case 11: id = kCC11; return kResultTrue;
            case 64: id = kSustain; return kResultTrue;
            case 91: id = kCC91; return kResultTrue;
            default: return kResultFalse;
        }
    }

    std::shared_ptr<Core> core;

    OBJ_METHODS(SF2Controller, EditController)
    DEFINE_INTERFACES
        DEF_INTERFACE(IMidiMapping)
    END_DEFINE_INTERFACES(EditController)
    REFCOUNT_METHODS(EditController)
};

class SF2Editor : public CPluginView {
public:
    explicit SF2Editor(SF2Controller *c) : CPluginView(nullptr), ctrl(c) { ViewRect r(0, 0, 720, 540); setRect(r); }
    ~SF2Editor() SMTG_OVERRIDE { destroy(); }
    tresult PLUGIN_API isPlatformTypeSupported(FIDString type) SMTG_OVERRIDE { return strcmp(type, kPlatformTypeNSView) == 0 ? kResultTrue : kResultFalse; }
    tresult PLUGIN_API attached(void *parent, FIDString type) SMTG_OVERRIDE {
        if (!ctrl->core) return kResultFalse;
        NSView *host = (__bridge NSView *)parent;
        SF2Controller *c = ctrl;
        view = [[SF2EditorView alloc] initWithCore:ctrl->core edit:[c](uint32_t id, double plain) {
            double n = toNorm(id, plain);
            c->setParamNormalized(id, n); c->beginEdit(id); c->performEdit(id, n); c->endEdit(id);
        }];
        view.frame = NSMakeRect(0, 0, rect.getWidth(), rect.getHeight());
        [host addSubview:view];
        return CPluginView::attached(parent, type);
    }
    tresult PLUGIN_API removed() SMTG_OVERRIDE { destroy(); return CPluginView::removed(); }
    tresult PLUGIN_API canResize() SMTG_OVERRIDE { return kResultFalse; }
private:
    void destroy() { if (view) { [view shutdown]; [view removeFromSuperview]; view = nil; } }
    SF2Controller *ctrl;
    SF2EditorView *view = nil;
};

IPlugView *PLUGIN_API SF2Controller::createView(FIDString name) {
    if (name && strcmp(name, ViewType::kEditor) == 0) return new SF2Editor(this);
    return nullptr;
}

// MARK: - Factory & entry

class SF2Factory : public IPluginFactory3 {
public:
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) SMTG_OVERRIDE {
        QUERY_INTERFACE(iid, obj, FUnknown::iid, IPluginFactory3)
        QUERY_INTERFACE(iid, obj, IPluginFactory::iid, IPluginFactory3)
        QUERY_INTERFACE(iid, obj, IPluginFactory2::iid, IPluginFactory3)
        QUERY_INTERFACE(iid, obj, IPluginFactory3::iid, IPluginFactory3)
        *obj = nullptr; return kNoInterface;
    }
    uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return ++refs; }
    uint32 PLUGIN_API release() SMTG_OVERRIDE { uint32 r = --refs; if (r == 0) delete this; return r; }
    tresult PLUGIN_API getFactoryInfo(PFactoryInfo *info) SMTG_OVERRIDE { *info = PFactoryInfo("MacBand", "https://localhost", "mailto:none@localhost", PFactoryInfo::kUnicode); return kResultOk; }
    int32 PLUGIN_API countClasses() SMTG_OVERRIDE { return 2; }
    tresult PLUGIN_API getClassInfo(int32 i, PClassInfo *info) SMTG_OVERRIDE { PClassInfo2 i2; if (getClassInfo2(i, &i2) != kResultOk) return kResultFalse; memcpy(info, &i2, sizeof(PClassInfo)); return kResultOk; }
    tresult PLUGIN_API getClassInfo2(int32 i, PClassInfo2 *info) SMTG_OVERRIDE {
        if (i == 0) { *info = PClassInfo2(kProcessorUID.toTUID(), PClassInfo::kManyInstances, kVstAudioEffectClass, "SF2 Player", Vst::kDistributable, PlugType::kInstrumentSynth, "MacBand", "1.0.0", kVstVersionString); return kResultOk; }
        if (i == 1) { *info = PClassInfo2(kControllerUID.toTUID(), PClassInfo::kManyInstances, kVstComponentControllerClass, "SF2 Player Controller", 0, "", "MacBand", "1.0.0", kVstVersionString); return kResultOk; }
        return kResultFalse;
    }
    tresult PLUGIN_API getClassInfoUnicode(int32 i, PClassInfoW *info) SMTG_OVERRIDE { PClassInfo2 i2; if (getClassInfo2(i, &i2) != kResultOk) return kResultFalse; info->fromAscii(i2); return kResultOk; }
    tresult PLUGIN_API createInstance(FIDString cid, FIDString iid, void **obj) SMTG_OVERRIDE {
        FUnknown *inst = nullptr;
        if (FUnknownPrivate::iidEqual(cid, kProcessorUID.toTUID())) inst = static_cast<IAudioProcessor *>(new SF2Processor());
        else if (FUnknownPrivate::iidEqual(cid, kControllerUID.toTUID())) inst = static_cast<IEditController *>(new SF2Controller());
        if (!inst) { *obj = nullptr; return kNoInterface; }
        tresult r = inst->queryInterface(iid, obj); inst->release(); return r;
    }
    tresult PLUGIN_API setHostContext(FUnknown *) SMTG_OVERRIDE { return kResultOk; }
private:
    std::atomic<uint32> refs{1};
};

extern "C" {
__attribute__((visibility("default"))) bool bundleEntry(CFBundleRef) { return true; }
__attribute__((visibility("default"))) bool bundleExit() { return true; }
__attribute__((visibility("default"))) IPluginFactory *GetPluginFactory() { return new SF2Factory(); }
}
