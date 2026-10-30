#pragma once
// SoundFont 2 loader + polyphonic sample synth (header-only, no host dependencies).
//   SoundFont  — memory-maps an .sf2, parses presets/instruments/zones/samples
//   Preset     — a preset flattened to regions (one per sample zone), cheap to play
//   Synth      — voices with DAHDSR volume + modulation envelopes, LFOs, resonant low-pass,
//                pan, loops, exclusive classes, controllers and a built-in reverb
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace SF2 {

// MARK: - Soundfont data

struct SampleHeader {
    std::string name;
    uint32_t start = 0, end = 0, loopStart = 0, loopEnd = 0, rate = 44100;
    uint8_t pitch = 60; int8_t correction = 0;
    uint16_t link = 0, type = 1;
};

enum Gen {
    gStartAddrsOffset = 0, gEndAddrsOffset, gStartloopAddrsOffset, gEndloopAddrsOffset, gStartAddrsCoarse,
    gModLfoToPitch, gVibLfoToPitch, gModEnvToPitch, gInitialFilterFc, gInitialFilterQ, gModLfoToFilterFc,
    gModEnvToFilterFc, gEndAddrsCoarse, gModLfoToVolume, gUnused1, gChorusSend, gReverbSend, gPan,
    gUnused2, gUnused3, gUnused4, gDelayModLFO, gFreqModLFO, gDelayVibLFO, gFreqVibLFO, gDelayModEnv,
    gAttackModEnv, gHoldModEnv, gDecayModEnv, gSustainModEnv, gReleaseModEnv, gKeyToModEnvHold,
    gKeyToModEnvDecay, gDelayVolEnv, gAttackVolEnv, gHoldVolEnv, gDecayVolEnv, gSustainVolEnv,
    gReleaseVolEnv, gKeyToVolEnvHold, gKeyToVolEnvDecay, gInstrument, gReserved1, gKeyRange, gVelRange,
    gStartloopCoarse, gKeynum, gVelocity, gInitialAttenuation, gReserved2, gEndloopCoarse, gCoarseTune,
    gFineTune, gSampleID, gSampleModes, gReserved3, gScaleTuning, gExclusiveClass, gOverridingRootKey,
    gUnused5, gEndOper, gCount = 61
};

struct GenSet {
    int16_t v[gCount] = {};
    bool has[gCount] = {};
    int keyLo = 0, keyHi = 127, velLo = 0, velHi = 127;
    int link = -1;        // instrument index (preset zone) or sample index (instrument zone)
};

struct PresetInfo { std::string name; int bank = 0, program = 0; int zoneStart = 0, zoneEnd = 0; };
struct InstInfo { std::string name; int zoneStart = 0, zoneEnd = 0; };

struct Region {
    int keyLo = 0, keyHi = 127, velLo = 0, velHi = 127;
    uint32_t start = 0, end = 0, loopStart = 0, loopEnd = 0;
    int rootKey = 60, sampleRate = 44100, correction = 0;
    int loopMode = 0;      // 0 none, 1 continuous, 3 until release
    int exclusive = 0;
    int g[gCount] = {};
    const int16_t *smpl = nullptr;
    const uint8_t *sm24 = nullptr;
};

struct Preset {
    std::string name;
    std::vector<Region> regions;
};

class SoundFont {
public:
    std::string path, name, error;
    std::vector<PresetInfo> presets;     // sorted by bank, program

    static std::shared_ptr<SoundFont> load(const std::string &path, std::string &err) {
        auto sf = std::shared_ptr<SoundFont>(new SoundFont());
        sf->path = path;
        if (!sf->open(path, err)) return nullptr;
        return sf;
    }
    ~SoundFont() { if (map && map != MAP_FAILED) munmap(map, mapSize); }

    size_t sampleCount() const { return smplCount; }

    /// Flatten preset `index` (into `presets`) into playable regions.
    std::shared_ptr<Preset> buildPreset(int index) const {
        auto out = std::make_shared<Preset>();
        if (index < 0 || index >= (int)presets.size()) return out;
        const PresetInfo &p = presets[index];
        out->name = p.name;
        int gStart = p.zoneStart;
        bool hasGlobal = false;
        const GenSet *pGlobal = nullptr;
        for (int z = p.zoneStart; z < p.zoneEnd; z++) {
            const GenSet &pz = pzones[z];
            if (pz.link < 0) { if (z == gStart) { hasGlobal = true; pGlobal = &pz; } continue; }
            if (pz.link >= (int)insts.size()) continue;
            const InstInfo &inst = insts[pz.link];
            const GenSet *iGlobal = nullptr;
            for (int iz = inst.zoneStart; iz < inst.zoneEnd; iz++) {
                const GenSet &z2 = izones[iz];
                if (z2.link < 0) { if (iz == inst.zoneStart) iGlobal = &z2; continue; }
                if (z2.link >= (int)shdr.size()) continue;
                const SampleHeader &sh = shdr[z2.link];
                if (sh.type & 0x8000) continue;             // ROM sample
                Region r;
                r.keyLo = std::max(pz.keyLo, z2.keyLo); r.keyHi = std::min(pz.keyHi, z2.keyHi);
                r.velLo = std::max(pz.velLo, z2.velLo); r.velHi = std::min(pz.velHi, z2.velHi);
                if (hasGlobal) { r.keyLo = std::max(r.keyLo, pGlobal->keyLo); r.keyHi = std::min(r.keyHi, pGlobal->keyHi); r.velLo = std::max(r.velLo, pGlobal->velLo); r.velHi = std::min(r.velHi, pGlobal->velHi); }
                if (iGlobal) { r.keyLo = std::max(r.keyLo, iGlobal->keyLo); r.keyHi = std::min(r.keyHi, iGlobal->keyHi); r.velLo = std::max(r.velLo, iGlobal->velLo); r.velHi = std::min(r.velHi, iGlobal->velHi); }
                if (r.keyLo > r.keyHi || r.velLo > r.velHi) continue;

                int g[gCount]; defaults(g);
                auto applyAbs = [&](const GenSet &s) { for (int i = 0; i < gCount; i++) if (s.has[i] && i != gKeyRange && i != gVelRange && i != gSampleID && i != gInstrument) g[i] = s.v[i]; };
                if (iGlobal) applyAbs(*iGlobal);
                applyAbs(z2);
                auto applyRel = [&](const GenSet &s) {
                    for (int i = 0; i < gCount; i++) {
                        if (!s.has[i]) continue;
                        if (i == gKeyRange || i == gVelRange || i == gInstrument || i == gSampleID) continue;
                        if (i <= gEndAddrsOffset || i == gStartloopAddrsOffset || i == gEndloopAddrsOffset || i == gStartAddrsCoarse || i == gEndAddrsCoarse ||
                            i == gStartloopCoarse || i == gEndloopCoarse || i == gSampleModes || i == gExclusiveClass || i == gOverridingRootKey) continue;
                        g[i] += s.v[i];
                    }
                };
                if (hasGlobal) applyRel(*pGlobal);
                applyRel(pz);

                std::memcpy(r.g, g, sizeof(g));
                int64_t st = (int64_t)sh.start + g[gStartAddrsOffset] + 32768 * (int64_t)g[gStartAddrsCoarse];
                int64_t en = (int64_t)sh.end + g[gEndAddrsOffset] + 32768 * (int64_t)g[gEndAddrsCoarse];
                int64_t ls = (int64_t)sh.loopStart + g[gStartloopAddrsOffset] + 32768 * (int64_t)g[gStartloopCoarse];
                int64_t le = (int64_t)sh.loopEnd + g[gEndloopAddrsOffset] + 32768 * (int64_t)g[gEndloopCoarse];
                st = std::max<int64_t>(0, std::min<int64_t>(st, smplCount)); en = std::max<int64_t>(st, std::min<int64_t>(en, smplCount));
                ls = std::max<int64_t>(st, std::min<int64_t>(ls, en)); le = std::max<int64_t>(ls, std::min<int64_t>(le, en));
                r.start = (uint32_t)st; r.end = (uint32_t)en; r.loopStart = (uint32_t)ls; r.loopEnd = (uint32_t)le;
                r.rootKey = g[gOverridingRootKey] >= 0 ? g[gOverridingRootKey] : (sh.pitch > 127 ? 60 : sh.pitch);
                r.sampleRate = (int)sh.rate; r.correction = sh.correction;
                int mode = g[gSampleModes] & 3;
                r.loopMode = (mode == 1 || mode == 3) && r.loopEnd - r.loopStart > 8 ? mode : 0;
                r.exclusive = g[gExclusiveClass];
                r.smpl = smpl; r.sm24 = sm24;
                if (r.end > r.start) out->regions.push_back(r);
            }
        }
        return out;
    }

    static void defaults(int *g) {
        std::memset(g, 0, sizeof(int) * gCount);
        g[gInitialFilterFc] = 13500;
        for (int i : {gDelayModLFO, gDelayVibLFO, gDelayModEnv, gAttackModEnv, gHoldModEnv, gDecayModEnv, gReleaseModEnv,
                      gDelayVolEnv, gAttackVolEnv, gHoldVolEnv, gDecayVolEnv, gReleaseVolEnv}) g[i] = -12000;
        g[gKeynum] = -1; g[gVelocity] = -1; g[gScaleTuning] = 100; g[gOverridingRootKey] = -1;
    }

private:
    SoundFont() = default;
    void *map = nullptr; size_t mapSize = 0;
    const int16_t *smpl = nullptr; const uint8_t *sm24 = nullptr; size_t smplCount = 0;
    std::vector<GenSet> pzones, izones;
    std::vector<InstInfo> insts;
    std::vector<SampleHeader> shdr;

    struct Chunk { const uint8_t *data; uint32_t size; };
    static uint32_t u32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
    static uint16_t u16(const uint8_t *p) { return p[0] | p[1] << 8; }
    static std::string str20(const uint8_t *p) { char b[21] = {}; std::memcpy(b, p, 20); return b; }

    bool open(const std::string &file, std::string &err) {
        int fd = ::open(file.c_str(), O_RDONLY);
        if (fd < 0) { err = "Couldn't open the file."; return false; }
        struct stat st; fstat(fd, &st);
        mapSize = (size_t)st.st_size;
        if (mapSize < 64) { ::close(fd); err = "That file is too small to be a SoundFont."; return false; }
        map = mmap(nullptr, mapSize, PROT_READ, MAP_PRIVATE, fd, 0);
        ::close(fd);
        if (map == MAP_FAILED) { err = "Couldn't read the file."; return false; }
        const uint8_t *b = (const uint8_t *)map;
        if (std::memcmp(b, "RIFF", 4) != 0 || std::memcmp(b + 8, "sfbk", 4) != 0) { err = "Not a SoundFont 2 (.sf2) file."; return false; }

        Chunk phdr{}, pbag{}, pgen{}, inst{}, ibag{}, igen{}, shdrC{}, smplC{}, sm24C{};
        std::string bankName;
        size_t pos = 12, end = std::min(mapSize, (size_t)8 + u32(b + 4));
        while (pos + 8 <= end) {
            uint32_t sz = u32(b + pos + 4);
            if (pos + 8 + sz > mapSize) break;
            if (std::memcmp(b + pos, "LIST", 4) == 0 && sz >= 4) {
                const uint8_t *type = b + pos + 8;
                size_t p = pos + 12, e = pos + 8 + sz;
                while (p + 8 <= e) {
                    uint32_t s2 = u32(b + p + 4);
                    if (p + 8 + s2 > e) break;
                    const uint8_t *id = b + p; const uint8_t *d = b + p + 8;
                    auto is = [&](const char *n) { return std::memcmp(id, n, 4) == 0; };
                    if (!std::memcmp(type, "INFO", 4)) { if (is("INAM")) bankName = std::string((const char *)d, strnlen((const char *)d, s2)); }
                    else if (!std::memcmp(type, "sdta", 4)) { if (is("smpl")) smplC = {d, s2}; else if (is("sm24")) sm24C = {d, s2}; }
                    else if (!std::memcmp(type, "pdta", 4)) {
                        if (is("phdr")) phdr = {d, s2}; else if (is("pbag")) pbag = {d, s2}; else if (is("pgen")) pgen = {d, s2};
                        else if (is("inst")) inst = {d, s2}; else if (is("ibag")) ibag = {d, s2}; else if (is("igen")) igen = {d, s2};
                        else if (is("shdr")) shdrC = {d, s2};
                    }
                    p += 8 + s2 + (s2 & 1);
                }
            }
            pos += 8 + sz + (sz & 1);
        }
        if (!phdr.data || !pbag.data || !pgen.data || !inst.data || !ibag.data || !igen.data || !shdrC.data || !smplC.data) {
            err = "The SoundFont is missing required sections (it may be an SF3/compressed or damaged file)."; return false;
        }
        name = bankName;
        smpl = (const int16_t *)smplC.data; smplCount = smplC.size / 2;
        if (sm24C.data && sm24C.size >= smplCount) sm24 = sm24C.data;

        // samples
        size_t ns = shdrC.size / 46;
        for (size_t i = 0; i + 1 < ns; i++) {
            const uint8_t *p = shdrC.data + i * 46;
            SampleHeader h; h.name = str20(p);
            h.start = u32(p + 20); h.end = u32(p + 24); h.loopStart = u32(p + 28); h.loopEnd = u32(p + 32); h.rate = u32(p + 36);
            h.pitch = p[40]; h.correction = (int8_t)p[41]; h.link = u16(p + 42); h.type = u16(p + 44);
            shdr.push_back(h);
        }
        // zones
        auto readZones = [&](const Chunk &bag, const Chunk &gen, std::vector<GenSet> &zones, bool isPreset) {
            size_t nb = bag.size / 4, ng = gen.size / 4;
            for (size_t i = 0; i + 1 < nb; i++) {
                size_t g0 = u16(bag.data + i * 4), g1 = u16(bag.data + (i + 1) * 4);
                GenSet z;
                for (size_t g = g0; g < g1 && g < ng; g++) {
                    int op = u16(gen.data + g * 4); const uint8_t *a = gen.data + g * 4 + 2;
                    if (op >= gCount) continue;
                    if (op == gKeyRange) { z.keyLo = a[0]; z.keyHi = a[1]; }
                    else if (op == gVelRange) { z.velLo = a[0]; z.velHi = a[1]; }
                    else if (op == gInstrument && isPreset) z.link = u16(a);
                    else if (op == gSampleID && !isPreset) z.link = u16(a);
                    else { z.v[op] = (int16_t)u16(a); z.has[op] = true; }
                }
                zones.push_back(z);
            }
        };
        readZones(pbag, pgen, pzones, true);
        readZones(ibag, igen, izones, false);
        // instruments
        size_t ni = inst.size / 22;
        for (size_t i = 0; i + 1 < ni; i++) {
            InstInfo in; in.name = str20(inst.data + i * 22);
            in.zoneStart = u16(inst.data + i * 22 + 20); in.zoneEnd = u16(inst.data + (i + 1) * 22 + 20);
            in.zoneEnd = std::min<int>(in.zoneEnd, (int)izones.size());
            insts.push_back(in);
        }
        // presets
        size_t np = phdr.size / 38;
        for (size_t i = 0; i + 1 < np; i++) {
            const uint8_t *p = phdr.data + i * 38;
            PresetInfo pi; pi.name = str20(p); pi.program = u16(p + 20); pi.bank = u16(p + 22);
            pi.zoneStart = u16(p + 24); pi.zoneEnd = std::min<int>(u16(p + 38 + 24), (int)pzones.size());
            presets.push_back(pi);
        }
        if (presets.empty()) { err = "The SoundFont contains no presets."; return false; }
        // keep original indices valid: sort a copy for display order but buildPreset indexes `presets`
        std::stable_sort(presets.begin(), presets.end(), [](const PresetInfo &a, const PresetInfo &b) { return std::tie(a.bank, a.program) < std::tie(b.bank, b.program); });
        return true;
    }
};

// MARK: - Reverb (Freeverb-style)

class Reverb {
public:
    void setSampleRate(double sr) {
        const double k = sr / 44100.0;
        static const int ct[8] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
        static const int at[4] = {556, 441, 341, 225};
        for (int c = 0; c < 2; c++) {
            for (int i = 0; i < 8; i++) comb[c][i].init((int)(ct[i] * k) + c * (int)(23 * k));
            for (int i = 0; i < 4; i++) ap[c][i].init((int)(at[i] * k) + c * (int)(23 * k));
        }
    }
    void process(const float *in, float *l, float *r, int n, float wet) {
        for (int i = 0; i < n; i++) {
            float x = in[i] * 0.015f, o[2] = {0, 0};
            for (int c = 0; c < 2; c++) {
                for (int k = 0; k < 8; k++) o[c] += comb[c][k].process(x, 0.84f, 0.25f);
                for (int k = 0; k < 4; k++) o[c] = ap[c][k].process(o[c]);
            }
            l[i] += o[0] * wet * 3.0f; r[i] += o[1] * wet * 3.0f;
        }
    }
    void clear() { for (int c = 0; c < 2; c++) { for (auto &x : comb[c]) x.clear(); for (auto &x : ap[c]) x.clear(); } }
private:
    struct Comb {
        std::vector<float> b; int p = 0; float store = 0;
        void init(int n) { b.assign(std::max(1, n), 0.f); p = 0; store = 0; }
        void clear() { std::fill(b.begin(), b.end(), 0.f); store = 0; }
        float process(float x, float fb, float damp) {
            float y = b[p]; store = y * (1 - damp) + store * damp; b[p] = x + store * fb;
            if (++p >= (int)b.size()) p = 0; return y;
        }
    };
    struct Allpass {
        std::vector<float> b; int p = 0;
        void init(int n) { b.assign(std::max(1, n), 0.f); p = 0; }
        void clear() { std::fill(b.begin(), b.end(), 0.f); }
        float process(float x) { float y = b[p]; float o = -x + y; b[p] = x + y * 0.5f; if (++p >= (int)b.size()) p = 0; return o; }
    };
    Comb comb[2][8]; Allpass ap[2][4];
};

// MARK: - Synth

class Synth {
public:
    static constexpr int kMaxVoices = 96;

    Synth() { garbage.reserve(32); setSampleRate(44100); }

    void setSampleRate(double sr) {
        sampleRate = sr; reverb.setSampleRate(sr);
        revBus.assign(4096, 0.f);
    }

    // Parameters (any thread; plain floats)
    std::atomic<float> volume{0.7f}, reverbLevel{0.25f}, bendRange{2.0f}, transpose{0};

    /// Hand a new preset/soundfont to the audio thread. Safe to call from any non-realtime thread.
    void setPreset(std::shared_ptr<const Preset> p, std::shared_ptr<const SoundFont> f) {
        while (lock.test_and_set(std::memory_order_acquire)) {}
        pendingPreset = std::move(p); pendingFont = std::move(f); hasPending.store(true);
        lock.clear(std::memory_order_release);
    }
    /// Free retired data from a non-realtime thread.
    void collectGarbage() {
        std::vector<std::shared_ptr<const void>> trash;
        while (lock.test_and_set(std::memory_order_acquire)) {}
        trash.swap(garbage); garbage.reserve(32);
        lock.clear(std::memory_order_release);
    }

    // MIDI (audio thread)
    void noteOn(int key, int vel) {
        if (vel == 0) { noteOff(key); return; }
        poll();
        if (!preset) return;
        const int k = std::min(127, std::max(0, key + (int)transpose.load()));
        for (const Region &r : preset->regions) {
            if (k < r.keyLo || k > r.keyHi || vel < r.velLo || vel > r.velHi) continue;
            if (r.exclusive) for (auto &v : voices) if (v.active && v.excl == r.exclusive && !v.released) release(v, true);
            Voice *v = allocate();
            start(*v, r, key, k, vel);
        }
    }
    void noteOff(int key) {
        for (auto &v : voices) if (v.active && v.key == key && !v.released) { if (sustain) v.held = true; else release(v, false); }
    }
    void controller(int cc, int val) {
        cc = cc & 127; val = val & 127;
        switch (cc) {
            case 1: modWheel = val / 127.f; break;
            case 7: cc7 = val / 127.f; break;
            case 10: panCC = (val - 64) / 64.f; break;
            case 11: cc11 = val / 127.f; break;
            case 64: { bool on = val >= 64; if (sustain && !on) for (auto &v : voices) if (v.active && v.held) { v.held = false; release(v, false); } sustain = on; break; }
            case 91: cc91 = val / 127.f; break;
            case 120: allSoundOff(); break;
            case 121: modWheel = 0; cc7 = 1; cc11 = 1; panCC = 0; bend = 0; sustain = false; break;
            case 123: allNotesOff(); break;
            default: break;
        }
    }
    void pitchBend(int v14) { bend = (v14 - 8192) / 8192.f; }
    void allNotesOff() { for (auto &v : voices) if (v.active && !v.released) { if (sustain) v.held = true; else release(v, false); } }
    void allSoundOff() { for (auto &v : voices) v.active = false; reverb.clear(); }
    int activeVoices() const { int n = 0; for (auto &v : voices) n += v.active; return n; }

    /// Renders `n` frames into L/R (overwrites).
    void render(float *L, float *R, int n) {
        poll();
        for (int done = 0; done < n;) {
            int chunk = std::min(n - done, (int)revBus.size());
            renderChunk(L + done, R + done, chunk);
            done += chunk;
        }
        if (retiredFont && activeVoices() == 0) retire(std::static_pointer_cast<const void>(retiredFont)), retiredFont.reset();
    }

private:
    struct Voice {
        bool active = false, released = false, held = false;
        Region r; int key = 0, vel = 0, excl = 0;
        double pos = 0, inc = 1;
        int stage = 0;                 // 0 delay 1 attack 2 hold 3 decay 4 sustain 5 release
        double amp = 0, sustainAmp = 1, cnt = 0, delayS = 0, attackS = 1, holdS = 0, decayMul = 1, relMul = 1;
        int mStage = 0; double mVal = 0, mCnt = 0, mDelayS = 0, mAttackS = 1, mHoldS = 0, mDecayStep = 0, mSustain = 1, mRelStep = 0;
        double modPhase = 0, vibPhase = 0, modDelayS = 0, vibDelayS = 0, modInc = 0, vibInc = 0, lfoT = 0;
        double baseGain = 1, pan = 0.5, reverbSend = 0;
        float x1 = 0, x2 = 0, y1 = 0, y2 = 0, b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
        bool filterOn = false; int tick = 0;
        double fastRelMul = 1;
        bool fast = false;
        double baseCents = 0;
    };

    static double tcSec(int tc) { return std::max(0.001, std::exp2(tc / 1200.0)); }

    void poll() {
        if (!hasPending.load(std::memory_order_relaxed)) return;
        if (lock.test_and_set(std::memory_order_acquire)) return;   // never block the audio thread
        if (hasPending.load()) {
            const bool newFont = pendingFont && pendingFont != font;
            if (newFont || preset) for (auto &v : voices) if (v.active) { release(v, true); }
            if (newFont) { if (retiredFont) garbage.push_back(retiredFont); retiredFont = font; font = pendingFont; }
            if (preset) { if (garbage.size() < 30) garbage.push_back(preset); }
            preset = std::move(pendingPreset); pendingPreset.reset();
            if (!newFont) pendingFont.reset();
            hasPending.store(false);
        }
        lock.clear(std::memory_order_release);
    }
    void retire(std::shared_ptr<const void> p) {
        if (lock.test_and_set(std::memory_order_acquire)) { retiredFont = std::static_pointer_cast<const SoundFont>(p); return; }
        if (garbage.size() < 30) garbage.push_back(std::move(p));
        lock.clear(std::memory_order_release);
    }

    Voice *allocate() {
        Voice *oldestReleased = nullptr, *oldest = nullptr;
        for (auto &v : voices) {
            if (!v.active) return &v;
            if (v.released && (!oldestReleased || v.lfoT > oldestReleased->lfoT)) oldestReleased = &v;
            if (!oldest || v.lfoT > oldest->lfoT) oldest = &v;
        }
        return oldestReleased ? oldestReleased : oldest;
    }

    void start(Voice &v, const Region &r, int key, int k, int vel) {
        v = Voice();
        v.active = true; v.r = r; v.key = key; v.vel = vel; v.excl = r.exclusive;
        const int *g = r.g;
        const int effKey = g[gKeynum] >= 0 ? g[gKeynum] : k;
        const int effVel = g[gVelocity] >= 0 ? g[gVelocity] : vel;
        v.pos = r.start;
        const double sr = sampleRate;
        v.delayS = tcSec(g[gDelayVolEnv]) * sr; if (g[gDelayVolEnv] <= -12000) v.delayS = 0;
        v.attackS = std::max(1.0, tcSec(g[gAttackVolEnv]) * sr);
        v.holdS = tcSec(g[gHoldVolEnv] + (60 - effKey) * g[gKeyToVolEnvHold]) * sr; if (g[gHoldVolEnv] <= -12000 && !g[gKeyToVolEnvHold]) v.holdS = 0;
        const double decaySec = tcSec(g[gDecayVolEnv] + (60 - effKey) * g[gKeyToVolEnvDecay]);
        v.decayMul = std::pow(10.0, -100.0 / 20.0 / (decaySec * sr));      // 100 dB over the decay time
        const double susDB = std::min(144.0, std::max(0, g[gSustainVolEnv]) / 10.0);
        v.sustainAmp = std::pow(10.0, -susDB / 20.0);
        v.relMul = std::pow(10.0, -100.0 / 20.0 / (tcSec(g[gReleaseVolEnv]) * sr));
        v.stage = v.delayS > 0 ? 0 : 1; v.amp = 0;
        // modulation envelope
        v.mDelayS = g[gDelayModEnv] <= -12000 ? 0 : tcSec(g[gDelayModEnv]) * sr;
        v.mAttackS = std::max(1.0, tcSec(g[gAttackModEnv]) * sr);
        v.mHoldS = g[gHoldModEnv] <= -12000 && !g[gKeyToModEnvHold] ? 0 : tcSec(g[gHoldModEnv] + (60 - effKey) * g[gKeyToModEnvHold]) * sr;
        v.mSustain = 1.0 - std::min(1000, std::max(0, g[gSustainModEnv])) / 1000.0;
        v.mDecayStep = (1.0 - v.mSustain) / std::max(1.0, tcSec(g[gDecayModEnv] + (60 - effKey) * g[gKeyToModEnvDecay]) * sr);
        v.mRelStep = 1.0 / std::max(1.0, tcSec(g[gReleaseModEnv]) * sr);
        v.mStage = v.mDelayS > 0 ? 0 : 1;
        // LFOs
        v.modDelayS = tcSec(g[gDelayModLFO]) * sr; if (g[gDelayModLFO] <= -12000) v.modDelayS = 0;
        v.vibDelayS = tcSec(g[gDelayVibLFO]) * sr; if (g[gDelayVibLFO] <= -12000) v.vibDelayS = 0;
        v.modInc = 8.176 * std::exp2(g[gFreqModLFO] / 1200.0) / sr;
        v.vibInc = 8.176 * std::exp2(g[gFreqVibLFO] / 1200.0) / sr;
        // gain
        const double att = std::min(1440, std::max(0, g[gInitialAttenuation]));
        const double velG = (effVel / 127.0) * (effVel / 127.0);
        v.baseGain = std::pow(10.0, -att / 200.0) * velG;
        v.pan = std::min(1.0, std::max(0.0, (g[gPan] + 500) / 1000.0));
        v.reverbSend = std::min(1.0, std::max(0, g[gReverbSend]) / 1000.0);
        v.baseCents = (key - r.rootKey) * (double)g[gScaleTuning] + g[gCoarseTune] * 100.0 + g[gFineTune] + r.correction;
        v.baseCents += (k - key) * (double)g[gScaleTuning];
        v.filterOn = g[gInitialFilterFc] < 13490 || g[gModEnvToFilterFc] != 0 || g[gModLfoToFilterFc] != 0;
        v.lfoT = 0;
        v.inc = ((double)r.sampleRate / sampleRate) * std::exp2(v.baseCents / 1200.0);
        updateFilter(v, 0, 0);
    }

    void release(Voice &v, bool fast) {
        if (v.released && !fast) return;
        v.released = true; v.held = false; v.stage = 5; v.mStage = 5;
        if (fast) { v.relMul = std::pow(10.0, -100.0 / 20.0 / (0.012 * sampleRate)); v.mRelStep = 1.0 / (0.012 * sampleRate); }
        v.mRelStep = v.mRelStep; v.mSustain = std::min(v.mSustain, v.mVal);
    }

    void updateFilter(Voice &v, double modEnv, double modLfo) {
        const int *g = v.r.g;
        double cents = g[gInitialFilterFc] + modEnv * g[gModEnvToFilterFc] + modLfo * g[gModLfoToFilterFc];
        cents = std::min(13500.0, std::max(1500.0, cents));
        double fc = 8.176 * std::exp2(cents / 1200.0);
        fc = std::min(fc, sampleRate * 0.45);
        const double qdB = std::min(96.0, std::max(0, g[gInitialFilterQ]) / 10.0);
        const double Q = 0.7071 * std::pow(10.0, qdB / 20.0);
        const double w0 = 2 * M_PI * fc / sampleRate, cw = std::cos(w0), alpha = std::sin(w0) / (2 * Q);
        const double a0 = 1 + alpha;
        v.b0 = (float)((1 - cw) / 2 / a0); v.b1 = (float)((1 - cw) / a0); v.b2 = v.b0;
        v.a1 = (float)(-2 * cw / a0); v.a2 = (float)((1 - alpha) / a0);
    }

    static inline float sampleAt(const Region &r, int64_t i) {
        if (i < 0) i = 0; if (i >= (int64_t)r.end) i = r.end - 1 < 0 ? 0 : r.end - 1;
        float s = r.smpl[i] * (1.0f / 32768.0f);
        if (r.sm24) s += r.sm24[i] * (1.0f / 8388608.0f);
        return s;
    }

    void renderChunk(float *L, float *R, int n) {
        std::fill(L, L + n, 0.f); std::fill(R, R + n, 0.f);
        std::fill(revBus.begin(), revBus.begin() + n, 0.f);
        const float master = volume.load() * volume.load() * 0.8f;
        const double bendCents = bend * bendRange.load() * 100.0;
        const double sr = sampleRate;
        const double cc7g = (double)cc7 * cc7, cc11g = (double)cc11 * cc11;
        for (auto &v : voices) {
            if (!v.active) continue;
            const Region &r = v.r;
            const int *g = r.g;
            const double modLfoPitch = g[gModLfoToPitch], vibPitch = g[gVibLfoToPitch] + modWheel * 50.0, modEnvPitch = g[gModEnvToPitch];
            const double modLfoVol = g[gModLfoToVolume];
            const double lwr = v.pan;
            const double pc = std::min(1.0, std::max(0.0, lwr + panCC * 0.5));
            const float gl = (float)std::cos(pc * M_PI / 2), gr = (float)std::sin(pc * M_PI / 2);
            const float send = (float)std::min(1.0, v.reverbSend + cc91 * 0.4);
            const double gain = v.baseGain * cc7g * cc11g * master;
            for (int i = 0; i < n; i++) {
                // volume envelope
                switch (v.stage) {
                    case 0: if (++v.cnt >= v.delayS) { v.stage = 1; v.cnt = 0; } break;
                    case 1: v.amp += 1.0 / v.attackS; if (v.amp >= 1) { v.amp = 1; v.stage = v.holdS > 0 ? 2 : 3; v.cnt = 0; } break;
                    case 2: if (++v.cnt >= v.holdS) { v.stage = 3; v.cnt = 0; } break;
                    case 3: v.amp *= v.decayMul; if (v.amp <= v.sustainAmp) { v.amp = v.sustainAmp; v.stage = 4; } break;
                    case 4: break;
                    case 5: v.amp *= v.relMul; if (v.amp < 1e-5) { v.active = false; } break;
                }
                if (!v.active) break;
                // modulation envelope
                switch (v.mStage) {
                    case 0: v.mVal = 0; if (++v.mCnt >= v.mDelayS) { v.mStage = 1; v.mCnt = 0; } break;
                    case 1: v.mVal += 1.0 / v.mAttackS; if (v.mVal >= 1) { v.mVal = 1; v.mStage = v.mHoldS > 0 ? 2 : 3; v.mCnt = 0; } break;
                    case 2: if (++v.mCnt >= v.mHoldS) { v.mStage = 3; v.mCnt = 0; } break;
                    case 3: v.mVal -= v.mDecayStep; if (v.mVal <= v.mSustain) { v.mVal = v.mSustain; v.mStage = 4; } break;
                    case 4: break;
                    case 5: v.mVal = std::max(0.0, v.mVal - v.mRelStep); break;
                }
                // LFOs (triangle)
                v.lfoT += 1.0;
                double modL = 0, vibL = 0;
                if (v.lfoT >= v.modDelayS) { v.modPhase += v.modInc; if (v.modPhase >= 1) v.modPhase -= 1; modL = 1.0 - 4.0 * std::fabs(v.modPhase - 0.5) ; }
                if (v.lfoT >= v.vibDelayS) { v.vibPhase += v.vibInc; if (v.vibPhase >= 1) v.vibPhase -= 1; vibL = 1.0 - 4.0 * std::fabs(v.vibPhase - 0.5); }
                // pitch / filter updates every 8 samples
                if ((v.tick++ & 7) == 0) {
                    const double cents = v.baseCents + bendCents + modL * modLfoPitch + vibL * vibPitch + v.mVal * modEnvPitch;
                    v.inc = ((double)r.sampleRate / sr) * std::exp2(cents / 1200.0);
                    if (v.filterOn) updateFilter(v, v.mVal, modL);
                }
                // sample (Hermite)
                int64_t ip = (int64_t)v.pos;
                float f = (float)(v.pos - ip);
                float y0 = sampleAt(r, ip - 1), y1 = sampleAt(r, ip), y2 = sampleAt(r, ip + 1), y3 = sampleAt(r, ip + 2);
                float c1 = 0.5f * (y2 - y0), c2 = y0 - 2.5f * y1 + 2.f * y2 - 0.5f * y3, c3 = 0.5f * (y3 - y0) + 1.5f * (y1 - y2);
                float s = ((c3 * f + c2) * f + c1) * f + y1;
                v.pos += v.inc;
                if (r.loopMode == 1 || (r.loopMode == 3 && !v.released)) {
                    while (v.pos >= r.loopEnd) v.pos -= (r.loopEnd - r.loopStart);
                } else if (v.pos >= r.end) { v.active = false; break; }
                if (v.filterOn) {
                    float o = v.b0 * s + v.b1 * v.x1 + v.b2 * v.x2 - v.a1 * v.y1 - v.a2 * v.y2;
                    v.x2 = v.x1; v.x1 = s; v.y2 = v.y1; v.y1 = o; s = o;
                }
                double a = v.amp * gain;
                if (modLfoVol != 0) a *= std::pow(10.0, modL * modLfoVol / 200.0);
                float out = s * (float)a;
                L[i] += out * gl; R[i] += out * gr;
                revBus[i] += out * send;
            }
        }
        const float wet = reverbLevel.load();
        if (wet > 0.001f) reverb.process(revBus.data(), L, R, n, wet);
        for (int i = 0; i < n; i++) {   // gentle limiter so dense chords don't clip
            L[i] = softClip(L[i]); R[i] = softClip(R[i]);
        }
    }
    static inline float softClip(float x) { return std::fabs(x) < 0.8f ? x : std::tanh((x - (x > 0 ? 0.8f : -0.8f)) * 5.f) * 0.2f + (x > 0 ? 0.8f : -0.8f); }

    double sampleRate = 44100;
    Voice voices[kMaxVoices];
    std::shared_ptr<const Preset> preset;
    std::shared_ptr<const SoundFont> font, retiredFont;
    std::atomic_flag lock = ATOMIC_FLAG_INIT;
    std::atomic<bool> hasPending{false};
    std::shared_ptr<const Preset> pendingPreset;
    std::shared_ptr<const SoundFont> pendingFont;
    std::vector<std::shared_ptr<const void>> garbage;
    Reverb reverb; std::vector<float> revBus;
    float modWheel = 0, cc7 = 1, cc11 = 1, cc91 = 0, panCC = 0, bend = 0; bool sustain = false;
};

} // namespace SF2
