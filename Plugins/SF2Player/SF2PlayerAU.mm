// SF2 Player — Audio Unit (v2 component) built on Apple's AudioUnitSDK.
#import <Cocoa/Cocoa.h>
#import <CoreAudioKit/CoreAudioKit.h>
#import <AudioUnit/AUCocoaUIView.h>
#include <AudioUnitSDK/MusicDeviceBase.h>
#include <AudioUnitSDK/AUPlugInDispatch.h>
#include "SF2UI.h"

using namespace SF2Plugin;

static const AudioUnitPropertyID kSF2PropertyCoreID = 64001;   // custom: registry id of the Core (for the editor)
static const char *kViewClassName = "MBSF2AUViewFactory";

class SF2PlayerAU : public ausdk::MusicDeviceBase {
    using Base = ausdk::MusicDeviceBase;
public:
    explicit SF2PlayerAU(AudioComponentInstance ci) : Base(ci, 0, 1) {
        CreateElements();
        core = std::make_shared<Core>();
        core->initParams();
        coreID = registerCore(core);
        for (uint32_t i = kVolume; i <= kPreset; i++) Globals()->SetParameter(i, (AudioUnitParameterValue)def(i).def);
        Globals()->SetParameter(kPreset, (AudioUnitParameterValue)core->presetIndex.load());
        core->onPresetChanged = [this] {
            AudioUnitParameter p = {GetComponentInstance(), kPreset, kAudioUnitScope_Global, 0};
            Globals()->SetParameter(kPreset, (AudioUnitParameterValue)core->presetIndex.load());
            AUParameterSet(nullptr, nullptr, &p, (AudioUnitParameterValue)core->presetIndex.load(), 0);
            PropertyChanged(kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0);
        };
    }
    ~SF2PlayerAU() override { core->onPresetChanged = nullptr; }

    bool StreamFormatWritable(AudioUnitScope, AudioUnitElement) override { return !IsInitialized(); }
    bool CanScheduleParameters() const noexcept AUSDK_RTSAFE override { return false; }
    UInt32 SupportedNumChannels(const AUChannelInfo **outInfo) override {
        static const AUChannelInfo info[] = {{0, 2}, {0, 1}};
        if (outInfo) *outInfo = info;
        return 2;
    }
    bool ValidFormat(AudioUnitScope scope, AudioUnitElement element, const AudioStreamBasicDescription &f) override {
        return f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsFloat && f.mBitsPerChannel == 32 &&
               (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved || f.mChannelsPerFrame == 1) && f.mChannelsPerFrame >= 1 && f.mChannelsPerFrame <= 2;
    }
    OSStatus Initialize() override {
        OSStatus r = Base::Initialize();
        if (r == noErr) core->synth.setSampleRate(GetOutput(0)->GetStreamFormat().mSampleRate);
        return r;
    }
    OSStatus Reset(AudioUnitScope scope, AudioUnitElement element) override { core->synth.allSoundOff(); return Base::Reset(scope, element); }

    // MARK: MIDI (queued with sample offsets, applied in Render)

    OSStatus HandleMIDIEvent(UInt8 status, UInt8 channel, UInt8 d1, UInt8 d2, UInt32 startFrame) override {
        while (qlock.test_and_set(std::memory_order_acquire)) {}
        if (qcount < kQueue) queue[qcount++] = {status, d1, d2, startFrame};
        qlock.clear(std::memory_order_release);
        return noErr;
    }

    OSStatus Render(AudioUnitRenderActionFlags &, const AudioTimeStamp &, UInt32 n) override {
        AudioBufferList &abl = GetOutput(0)->GetBufferList();
        if (abl.mNumberBuffers < 1) return noErr;
        float *l = (float *)abl.mBuffers[0].mData;
        float *r = abl.mNumberBuffers > 1 ? (float *)abl.mBuffers[1].mData : nullptr;
        if (!r) { scratch.resize(n); r = scratch.data(); }

        Ev local[kQueue]; int count = 0;
        while (qlock.test_and_set(std::memory_order_acquire)) {}
        count = qcount; std::memcpy(local, queue, sizeof(Ev) * count); qcount = 0;
        qlock.clear(std::memory_order_release);
        std::stable_sort(local, local + count, [](const Ev &a, const Ev &b) { return a.off < b.off; });

        UInt32 pos = 0;
        for (int i = 0; i < count; i++) {
            UInt32 at = std::min(n, local[i].off);
            if (at > pos) { core->render(l + pos, r + pos, at - pos); pos = at; }
            apply(local[i]);
        }
        if (n > pos) core->render(l + pos, r + pos, n - pos);
        if (abl.mNumberBuffers > 1 && abl.mBuffers[1].mData == nullptr) {}
        return noErr;
    }

    // MARK: parameters

    OSStatus GetParameterList(AudioUnitScope scope, AudioUnitParameterID *outList, UInt32 &outNum) override {
        if (scope != kAudioUnitScope_Global) { outNum = 0; return noErr; }
        outNum = kPreset + 1;
        if (outList) for (UInt32 i = 0; i < outNum; i++) outList[i] = i;
        return noErr;
    }
    OSStatus GetParameterInfo(AudioUnitScope scope, AudioUnitParameterID id, AudioUnitParameterInfo &info) override {
        if (scope != kAudioUnitScope_Global || id > kPreset) return kAudioUnitErr_InvalidParameter;
        const ParamDef &d = def(id);
        info.flags = kAudioUnitParameterFlag_IsWritable | kAudioUnitParameterFlag_IsReadable;
        FillInParameterName(info, (__bridge CFStringRef)[NSString stringWithUTF8String:d.name], false);
        info.minValue = (AudioUnitParameterValue)d.min; info.maxValue = (AudioUnitParameterValue)d.max; info.defaultValue = (AudioUnitParameterValue)d.def;
        info.unit = kAudioUnitParameterUnit_Generic;
        if (id == kVolume || id == kReverb) { info.unit = kAudioUnitParameterUnit_Percent; info.minValue = 0; info.maxValue = 1; }
        if (id == kBendRange || id == kTranspose) info.unit = kAudioUnitParameterUnit_RelativeSemiTones;
        if (id == kPreset) {
            info.unit = kAudioUnitParameterUnit_Indexed;
            info.flags |= kAudioUnitParameterFlag_ValuesHaveStrings;
            int n = presetCount();
            info.minValue = 0; info.maxValue = (AudioUnitParameterValue)std::max(1, n - 1);
        }
        return noErr;
    }
    OSStatus GetParameterValueStrings(AudioUnitScope scope, AudioUnitParameterID id, CFArrayRef *outStrings) override {
        if (scope != kAudioUnitScope_Global || id != kPreset) return kAudioUnitErr_InvalidParameter;
        if (!outStrings) return noErr;
        NSMutableArray *names = [NSMutableArray array];
        std::shared_ptr<SF2::SoundFont> f; { std::lock_guard<std::mutex> l(core->mu); f = core->font; }
        if (f) for (auto &p : f->presets) [names addObject:[NSString stringWithFormat:@"%03d:%03d %s", p.bank, p.program, p.name.c_str()]];
        else [names addObject:@"(load a SoundFont)"];
        *outStrings = (CFArrayRef)CFBridgingRetain(names);
        return noErr;
    }
    OSStatus SetParameter(AudioUnitParameterID id, AudioUnitScope scope, AudioUnitElement el, AudioUnitParameterValue v, UInt32 off) override {
        OSStatus r = Base::SetParameter(id, scope, el, v, off);
        if (scope == kAudioUnitScope_Global) {
            if (id == kPreset) core->selectPresetAsync((int)std::lround(v));
            else if (id < kPreset) core->setParam(id, v);
        }
        return r;
    }

    // Presets: every SoundFont preset is a factory preset, so hosts list them by name.
    OSStatus GetPresets(CFArrayRef *outData) const override {
        if (!outData) return noErr;
        std::shared_ptr<SF2::SoundFont> f; { std::lock_guard<std::mutex> l(core->mu); f = core->font; }
        if (!f) { *outData = nullptr; return kAudioUnitErr_InvalidProperty; }
        CFMutableArrayRef arr = CFArrayCreateMutable(nullptr, 0, nullptr);
        const_cast<SF2PlayerAU *>(this)->presetNames.clear();
        for (size_t i = 0; i < f->presets.size(); i++) {
            auto &p = f->presets[i];
            const_cast<SF2PlayerAU *>(this)->presetNames.push_back(std::string() + std::to_string(p.bank) + ":" + std::to_string(p.program) + " " + p.name);
        }
        factory.resize(f->presets.size());
        for (size_t i = 0; i < f->presets.size(); i++) {
            factory[i].presetNumber = (SInt32)i;
            factory[i].presetName = CFStringCreateWithCString(nullptr, presetNames[i].c_str(), kCFStringEncodingUTF8);
            CFArrayAppendValue(arr, &factory[i]);
        }
        *outData = arr;
        return noErr;
    }
    OSStatus NewFactoryPresetSet(const AUPreset &p) override {
        if (p.presetNumber < 0) return kAudioUnitErr_InvalidProperty;
        core->selectPreset((int)p.presetNumber, false);
        SetAFactoryPresetAsCurrent(p);
        return noErr;
    }

    // MARK: state

    OSStatus SaveState(CFPropertyListRef *out) override {
        OSStatus r = Base::SaveState(out);
        if (r != noErr || !out || !*out) return r;
        CFMutableDictionaryRef d = (CFMutableDictionaryRef)*out;
        std::string path; { std::lock_guard<std::mutex> l(core->mu); path = core->path; }
        if (!path.empty()) { CFStringRef s = CFStringCreateWithCString(nullptr, path.c_str(), kCFStringEncodingUTF8); CFDictionarySetValue(d, CFSTR("sf2.path"), s); CFRelease(s); }
        SInt32 idx = core->presetIndex.load(); CFNumberRef n = CFNumberCreate(nullptr, kCFNumberSInt32Type, &idx);
        CFDictionarySetValue(d, CFSTR("sf2.preset"), n); CFRelease(n);
        return r;
    }
    OSStatus RestoreState(CFPropertyListRef plist) override {
        OSStatus r = Base::RestoreState(plist);
        if (CFGetTypeID(plist) != CFDictionaryGetTypeID()) return r;
        CFDictionaryRef d = (CFDictionaryRef)plist;
        int idx = -1; SInt32 tmp;
        if (CFNumberRef n = (CFNumberRef)CFDictionaryGetValue(d, CFSTR("sf2.preset"))) if (CFNumberGetValue(n, kCFNumberSInt32Type, &tmp)) idx = tmp;
        char buf[2048] = {};
        if (CFStringRef s = (CFStringRef)CFDictionaryGetValue(d, CFSTR("sf2.path"))) if (CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8) && buf[0]) core->loadFile(buf, idx);
        else if (idx >= 0) core->selectPreset(idx, false);
        for (uint32_t i = kVolume; i <= kTranspose; i++) core->setParam(i, Globals()->GetParameter(i));
        return r;
    }

    // MARK: properties (editor)

    OSStatus GetPropertyInfo(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el, UInt32 &size, bool &writable) override {
        if (id == kAudioUnitProperty_CocoaUI) { size = sizeof(AudioUnitCocoaViewInfo); writable = false; return noErr; }
        if (id == kSF2PropertyCoreID) { size = sizeof(int64_t); writable = false; return noErr; }
        if (id == kAudioUnitProperty_ParameterStringFromValue) { size = sizeof(AudioUnitParameterStringFromValue); writable = false; return noErr; }
        if (id == kAudioUnitProperty_ParameterValueFromString) { size = sizeof(AudioUnitParameterValueFromString); writable = false; return noErr; }
        return Base::GetPropertyInfo(id, scope, el, size, writable);
    }
    OSStatus GetProperty(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el, void *out) override {
        if (id == kAudioUnitProperty_CocoaUI) {
            CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR("com.macband.sf2player.au"));
            if (!bundle) return kAudioUnitErr_InvalidProperty;
            auto *info = (AudioUnitCocoaViewInfo *)out;
            info->mCocoaAUViewBundleLocation = CFBundleCopyBundleURL(bundle);
            info->mCocoaAUViewClass[0] = CFStringCreateWithCString(nullptr, kViewClassName, kCFStringEncodingUTF8);
            return noErr;
        }
        if (id == kSF2PropertyCoreID) { *(int64_t *)out = coreID; return noErr; }
        if (id == kAudioUnitProperty_ParameterStringFromValue) {
            auto *q = (AudioUnitParameterStringFromValue *)out;
            if (q->inParamID > kPreset) return kAudioUnitErr_InvalidParameter;
            double v = q->inValue ? *q->inValue : Globals()->GetParameter(q->inParamID);
            q->outString = (CFStringRef)CFBridgingRetain(valueString(q->inParamID, v));
            return noErr;
        }
        if (id == kAudioUnitProperty_ParameterValueFromString) {
            auto *q = (AudioUnitParameterValueFromString *)out;
            if (q->inParamID > kPreset) return kAudioUnitErr_InvalidParameter;
            NSString *str = (__bridge NSString *)q->inString;
            if (q->inParamID == kPreset) {
                std::shared_ptr<SF2::SoundFont> f; { std::lock_guard<std::mutex> l(core->mu); f = core->font; }
                if (f) for (size_t i = 0; i < f->presets.size(); i++)
                    if ([str rangeOfString:[NSString stringWithUTF8String:f->presets[i].name.c_str()] options:NSCaseInsensitiveSearch].location != NSNotFound) { q->outValue = (AudioUnitParameterValue)i; return noErr; }
            }
            double v = str.doubleValue; if (q->inParamID == kVolume || q->inParamID == kReverb) v /= 100;
            q->outValue = (AudioUnitParameterValue)v;
            return noErr;
        }
        return Base::GetProperty(id, scope, el, out);
    }

private:
    struct Ev { UInt8 status, d1, d2; UInt32 off; };
    static constexpr int kQueue = 1024;
    Ev queue[kQueue]; int qcount = 0; std::atomic_flag qlock = ATOMIC_FLAG_INIT;
    std::vector<float> scratch;
    mutable std::vector<AUPreset> factory;
    std::vector<std::string> presetNames;
    std::shared_ptr<Core> core; int64_t coreID = 0;

    NSString *valueString(uint32_t id, double v) {
        if (id == kPreset) {
            std::shared_ptr<SF2::SoundFont> f; { std::lock_guard<std::mutex> l(core->mu); f = core->font; }
            int i = (int)std::lround(v);
            if (f && i >= 0 && i < (int)f->presets.size()) return [NSString stringWithFormat:@"%03d:%03d %s", f->presets[i].bank, f->presets[i].program, f->presets[i].name.c_str()];
            return [NSString stringWithFormat:@"%d", i + 1];
        }
        if (id == kVolume || id == kReverb) return [NSString stringWithFormat:@"%.0f%%", v * 100];
        return [NSString stringWithFormat:@"%.0f", v];
    }
    int presetCount() { std::lock_guard<std::mutex> l(core->mu); return core->font ? (int)core->font->presets.size() : 0; }
    void apply(const Ev &e) {
        switch (e.status) {
            case 0x90: if (e.d2) core->synth.noteOn(e.d1, e.d2); else core->synth.noteOff(e.d1); break;
            case 0x80: core->synth.noteOff(e.d1); break;
            case 0xB0: if (e.d1 == 0) core->pendingBank = e.d2; else core->synth.controller(e.d1, e.d2); break;
            case 0xE0: core->synth.pitchBend(e.d1 | (e.d2 << 7)); break;
            case 0xC0: core->programChange(e.d1); break;
            default: break;
        }
    }
};

AUSDK_COMPONENT_ENTRY(ausdk::AUMusicDeviceFactory, SF2PlayerAU)

// MARK: - Cocoa UI factory

@interface MBSF2AUViewFactory : NSObject <AUCocoaUIBase>
@end

@implementation MBSF2AUViewFactory
- (unsigned)interfaceVersion { return 0; }
- (NSString *)description { return @"SF2 Player"; }
- (NSView *)uiViewForAudioUnit:(AudioUnit)au withSize:(NSSize)size {
    int64_t id = 0; UInt32 sz = sizeof(id);
    if (AudioUnitGetProperty(au, kSF2PropertyCoreID, kAudioUnitScope_Global, 0, &id, &sz) != noErr) return nil;
    auto core = findCore(id);
    if (!core) return nil;
    return [[SF2EditorView alloc] initWithCore:core edit:[au](uint32_t pid, double plain) {
        AudioUnitParameter p = {au, pid, kAudioUnitScope_Global, 0};
        AUParameterSet(nullptr, nullptr, &p, (AudioUnitParameterValue)plain, 0);
    }];
}
@end
