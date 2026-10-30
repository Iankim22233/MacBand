#pragma once
// Parameter table and state shared by the processor, controller and editor of MeowSynth.
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>

namespace Meow {

enum ParamID : uint32_t {
    kVolume, kAttack, kDecay, kSustain, kRelease,
    kCutoff, kResonance, kSweep, kSweepAttack, kSweepDecay, kKeyTrack,
    kNoise,
    kVibRate, kVibDepth, kVibAttack, kVibSync, kVibDiv,
    kPorta, kChorus, kPoly, kBendRange, kBend,
    kNumParams
};

enum class Scale { Linear, Log, Toggle, List };

struct ParamDef {
    const char *name;
    const char *units;
    double min, max, def;
    Scale scale;
    int steps;      // 0 = continuous; otherwise number of steps (list entries - 1)
};

inline const ParamDef &def(uint32_t id) {
    static const ParamDef defs[kNumParams] = {
        {"Volume",        "",    0,    1,     0.70, Scale::Linear, 0},
        {"Attack",        "ms",  1,    5000,  8,    Scale::Log,    0},
        {"Decay",         "ms",  1,    5000,  300,  Scale::Log,    0},
        {"Sustain",       "",    0,    1,     0.80, Scale::Linear, 0},
        {"Release",       "ms",  5,    5000,  220,  Scale::Log,    0},
        {"Cutoff",        "Hz",  80,   8000,  350,  Scale::Log,    0},
        {"Resonance",     "Q",   0.5,  30,    12,   Scale::Log,    0},
        {"Sweep",         "oct", 0,    5,     2.6,  Scale::Linear, 0},
        {"Sweep Attack",  "ms",  5,    3000,  170,  Scale::Log,    0},
        {"Sweep Decay",   "ms",  20,   5000,  420,  Scale::Log,    0},
        {"Key Track",     "",    0,    1,     0.6,  Scale::Linear, 0},
        {"Noise",         "",    0,    1,     0.06, Scale::Linear, 0},
        {"Vibrato Rate",  "Hz",  0.1,  12,    5.2,  Scale::Log,    0},
        {"Vibrato Depth", "ct",  0,    200,   25,   Scale::Linear, 0},
        {"Vibrato Fade",  "ms",  0,    3000,  350,  Scale::Linear, 0},
        {"Vibrato Sync",  "",    0,    1,     0,    Scale::Toggle, 1},
        {"Vibrato Div",   "",    0,    6,     3,    Scale::List,   6},
        {"Portamento",    "ms",  0,    2000,  0,    Scale::Linear, 0},
        {"Chorus",        "",    0,    1,     0.35, Scale::Linear, 0},
        {"Polycat",       "",    0,    1,     1,    Scale::Toggle, 1},
        {"Bend Range",    "st",  1,    24,    2,    Scale::Linear, 23},
        {"Pitch Bend",    "st",  -1,   1,     0,    Scale::Linear, 0},
    };
    return defs[id];
}

inline const char *divisionName(int i) {
    static const char *n[] = {"1/1", "1/2", "1/4", "1/8", "1/8T", "1/16", "1/16T"};
    return n[std::min(6, std::max(0, i))];
}
inline double divisionBeats(int i) {
    static const double b[] = {4, 2, 1, 0.5, 1.0 / 3, 0.25, 1.0 / 6};
    return b[std::min(6, std::max(0, i))];
}

inline double toPlain(uint32_t id, double n) {
    const ParamDef &d = def(id);
    n = std::min(1.0, std::max(0.0, n));
    double v;
    switch (d.scale) {
        case Scale::Log: v = d.min * std::pow(d.max / d.min, n); break;
        case Scale::Toggle: return n >= 0.5 ? 1 : 0;
        case Scale::List: return std::round(d.min + n * (d.max - d.min));
        default: v = d.min + n * (d.max - d.min);
    }
    if (d.steps > 0 && d.scale == Scale::Linear) v = std::round(v);
    return v;
}
inline double toNorm(uint32_t id, double v) {
    const ParamDef &d = def(id);
    v = std::min(d.max, std::max(d.min, v));
    switch (d.scale) {
        case Scale::Log: return std::log(v / d.min) / std::log(d.max / d.min);
        default: return (v - d.min) / (d.max - d.min);
    }
}

/// Live values passed from the processor to the editor (for the animated cat).
struct Shared {
    std::atomic<float> mouth{0};     // 0 closed … 1 wide open
    std::atomic<float> level{0};
    std::atomic<int> voices{0};
};

inline std::mutex &registryMutex() { static std::mutex m; return m; }
inline std::map<int64_t, std::weak_ptr<Shared>> &registry() { static std::map<int64_t, std::weak_ptr<Shared>> r; return r; }
inline int64_t registerShared(const std::shared_ptr<Shared> &s) {
    static int64_t next = 1;
    std::lock_guard<std::mutex> l(registryMutex());
    registry()[next] = s;
    return next++;
}
inline std::shared_ptr<Shared> findShared(int64_t id) {
    std::lock_guard<std::mutex> l(registryMutex());
    auto it = registry().find(id);
    return it == registry().end() ? nullptr : it->second.lock();
}

} // namespace Meow
