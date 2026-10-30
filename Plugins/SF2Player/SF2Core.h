#pragma once
// Plugin-independent core shared by the VST3 and AU: owns the synth, the loaded SoundFont, the
// current preset, parameters and a lock-free queue for notes played from the editor.
#include "SF2Engine.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <functional>
#include <map>
#include <mutex>

namespace SF2Plugin {

enum Param : uint32_t { kVolume, kReverb, kBendRange, kTranspose, kPreset, kModWheel, kCC7, kCC10, kCC11, kSustain, kCC91, kBendWheel, kNumParams };

struct ParamDef { const char *name; double min, max, def; int steps; bool hidden; };
inline const ParamDef &def(uint32_t i) {
    static const ParamDef d[kNumParams] = {
        {"Volume", 0, 1, 0.7, 0, false}, {"Reverb", 0, 1, 0.25, 0, false}, {"Bend Range", 1, 24, 2, 23, false},
        {"Transpose", -24, 24, 0, 48, false}, {"Preset", 0, 4095, 0, 4095, false},
        {"Mod Wheel", 0, 127, 0, 127, true}, {"Volume CC", 0, 127, 127, 127, true}, {"Pan CC", 0, 127, 64, 127, true},
        {"Expression CC", 0, 127, 127, 127, true}, {"Sustain Pedal", 0, 127, 0, 127, true}, {"Reverb CC", 0, 127, 0, 127, true},
        {"Pitch Bend", 0, 16383, 8192, 0, true},
    };
    return d[i];
}
inline double toPlain(uint32_t i, double n) { const ParamDef &d = def(i); double v = d.min + std::min(1.0, std::max(0.0, n)) * (d.max - d.min); return d.steps ? std::round(v) : v; }
inline double toNorm(uint32_t i, double v) { const ParamDef &d = def(i); return (std::min(d.max, std::max(d.min, v)) - d.min) / (d.max - d.min); }

struct AuditionEvent { uint8_t type, key, vel; };   // 0 off, 1 on

class Core {
public:
    SF2::Synth synth;
    std::mutex mu;                                   // protects font/path/error (never taken on the audio thread)
    std::shared_ptr<SF2::SoundFont> font;
    std::string path, error;
    std::atomic<int> presetIndex{0};
    std::atomic<int> revision{0};                    // bumps when the file or preset changes (UI refresh)
    std::atomic<int> pendingBank{0};
    std::atomic<float> level{0};
    std::function<void()> onPresetChanged;           // e.g. tell the host the "Preset" parameter changed

    Core() {
        if (const char *e = getenv("SF2PLAYER_DEFAULT_SF2")) loadFile(e);       // developer aid for tests
        else { std::string last = lastPath(); if (!last.empty()) loadFile(last); }
    }

    // MARK: file & preset (non-realtime threads)

    bool loadFile(const std::string &p, int wantedPreset = -1) {
        std::string err;
        auto f = SF2::SoundFont::load(p, err);
        std::lock_guard<std::mutex> l(mu);
        if (!f) { error = err; revision++; return false; }
        font = f; path = p; error.clear();
        saveLastPath(p);
        int idx = wantedPreset;
        if (idx < 0 || idx >= (int)f->presets.size()) {
            idx = 0;
            for (size_t i = 0; i < f->presets.size(); i++) if (f->presets[i].bank == 0 && f->presets[i].program == 0) { idx = (int)i; break; }
        }
        presetIndex = idx;
        synth.setPreset(f->buildPreset(idx), f);
        revision++;
        return true;
    }

    void selectPreset(int idx, bool notify = true) {
        std::shared_ptr<SF2::SoundFont> f;
        { std::lock_guard<std::mutex> l(mu); f = font; }
        if (!f || idx < 0 || idx >= (int)f->presets.size()) return;
        presetIndex = idx;
        synth.setPreset(f->buildPreset(idx), f);
        revision++;
        if (notify && onPresetChanged) onPresetChanged();
    }

    /// Safe to call from the audio thread: builds the preset on a worker queue.
    void selectPresetAsync(int idx) {
        if (idx == presetIndex.load()) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ this->selectPreset(idx, false); });
    }

    void programChange(int program) {
        std::shared_ptr<SF2::SoundFont> f;
        { std::lock_guard<std::mutex> l(mu); f = font; }
        if (!f) return;
        const int bank = pendingBank.load();
        for (size_t i = 0; i < f->presets.size(); i++) if (f->presets[i].bank == bank && f->presets[i].program == program) { selectPresetAsync((int)i); return; }
        for (size_t i = 0; i < f->presets.size(); i++) if (f->presets[i].program == program) { selectPresetAsync((int)i); return; }
    }

    // MARK: parameters

    void setParam(uint32_t id, double plain) {
        switch (id) {
            case kVolume: synth.volume = (float)plain; break;
            case kReverb: synth.reverbLevel = (float)plain; break;
            case kBendRange: synth.bendRange = (float)plain; break;
            case kTranspose: synth.transpose = (float)plain; break;
            default: break;
        }
        values[id] = plain;
    }
    double value(uint32_t id) const { return values[id]; }
    double values[kNumParams] = {};
    void initParams() { for (uint32_t i = 0; i < kNumParams; i++) { values[i] = def(i).def; if (i < kPreset) setParam(i, def(i).def); } }

    // MARK: audio thread

    void audition(bool on, int key, int vel = 100) {
        uint32_t h = head.load(std::memory_order_relaxed);
        queue[h & 255] = {(uint8_t)(on ? 1 : 0), (uint8_t)key, (uint8_t)vel};
        head.store(h + 1, std::memory_order_release);
    }
    void drainAudition() {
        uint32_t h = head.load(std::memory_order_acquire);
        while (tail != h) { AuditionEvent e = queue[tail & 255]; tail++; if (e.type) synth.noteOn(e.key, e.vel); else synth.noteOff(e.key); }
    }
    void render(float *L, float *R, int n) {
        drainAudition();
        synth.render(L, R, n);
        float p = 0; for (int i = 0; i < n; i += 8) p = std::max(p, std::max(std::fabs(L[i]), std::fabs(R[i])));
        level.store(std::max(p, level.load() * 0.9f));
    }

    // MARK: persistence

    static std::string lastPath() {
        CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("lastSF2"), CFSTR("com.macband.sf2player"));
        std::string out;
        if (v && CFGetTypeID(v) == CFStringGetTypeID()) { char b[2048]; if (CFStringGetCString((CFStringRef)v, b, sizeof b, kCFStringEncodingUTF8)) out = b; }
        if (v) CFRelease(v);
        return out;
    }
    static void saveLastPath(const std::string &p) {
        CFStringRef s = CFStringCreateWithCString(nullptr, p.c_str(), kCFStringEncodingUTF8);
        CFPreferencesSetAppValue(CFSTR("lastSF2"), s, CFSTR("com.macband.sf2player"));
        CFPreferencesAppSynchronize(CFSTR("com.macband.sf2player"));
        CFRelease(s);
    }

private:
    AuditionEvent queue[256]; std::atomic<uint32_t> head{0}; uint32_t tail = 0;
};

// Lets the editor (which only sees the controller / AudioUnit) find the core.
inline std::mutex &registryMutex() { static std::mutex m; return m; }
inline std::map<int64_t, std::weak_ptr<Core>> &registry() { static std::map<int64_t, std::weak_ptr<Core>> r; return r; }
inline int64_t registerCore(const std::shared_ptr<Core> &c) { static int64_t n = 1; std::lock_guard<std::mutex> l(registryMutex()); registry()[n] = c; return n++; }
inline std::shared_ptr<Core> findCore(int64_t id) { std::lock_guard<std::mutex> l(registryMutex()); auto it = registry().find(id); return it == registry().end() ? nullptr : it->second.lock(); }

} // namespace SF2Plugin
