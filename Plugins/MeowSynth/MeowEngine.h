#pragma once
// MeowSynth DSP: band-limited saw → resonant filter whose cutoff sweeps up and back down on every
// note (the "mouth opening"), noise breath, ADSR, vibrato with fade-in (optionally tempo-synced),
// portamento, mono/poly ("Polycat"), and a stereo chorus.
#include "MeowShared.h"
#include <cstring>
#include <vector>

namespace Meow {

class Engine {
public:
    static constexpr int kMaxVoices = 8;

    void setSampleRate(double sr) {
        sampleRate = sr;
        chorusLen = (int)(sr * 0.06) + 8;
        for (auto &d : chorus) d.assign(chorusLen, 0.f);
        chorusPos = 0;
        reset();
    }
    void reset() {
        for (auto &v : voices) v = Voice();
        held.clear();
        lastLog = -1;
        for (auto &d : chorus) std::fill(d.begin(), d.end(), 0.f);
    }

    /// `p` holds plain parameter values indexed by ParamID.
    void setParams(const double *p) { std::memcpy(plain, p, sizeof(plain)); }
    void setBend(double semis) { bend = semis; }

    void noteOn(int note, float vel) {
        const bool poly = plain[kPoly] >= 0.5;
        const double target = std::log2(440.0 * std::pow(2.0, (note - 69) / 12.0));
        if (!poly) {
            held.erase(std::remove(held.begin(), held.end(), note), held.end());
            held.push_back(note);
            Voice &v = voices[0];
            const bool wasActive = v.active;
            if (!wasActive) v = Voice();
            start(v, note, vel, target, wasActive);
            return;
        }
        Voice *slot = nullptr;
        for (auto &v : voices) if (!v.active) { slot = &v; break; }
        if (!slot) {   // steal the quietest releasing voice, else the oldest
            double best = 1e9;
            for (auto &v : voices) { double score = (v.released ? 0 : 10) + v.env + v.age * 1e-4 * -1; if (score < best) { best = score; slot = &v; } }
        }
        *slot = Voice();
        start(*slot, note, vel, target, false);
    }

    void noteOff(int note) {
        if (plain[kPoly] < 0.5) {
            held.erase(std::remove(held.begin(), held.end(), note), held.end());
            Voice &v = voices[0];
            if (!v.active) return;
            if (!held.empty() && v.note == note) {      // fall back to the previous held note, meowing again
                int n = held.back();
                start(v, n, v.vel, std::log2(440.0 * std::pow(2.0, (n - 69) / 12.0)), true);
            } else if (held.empty()) release(v);
            return;
        }
        for (auto &v : voices) if (v.active && !v.released && v.note == note) release(v);
    }

    void allNotesOff() { for (auto &v : voices) if (v.active) release(v); held.clear(); }

    float mouth() const { return mouthValue; }
    int activeVoices() const { int n = 0; for (auto &v : voices) n += v.active; return n; }

    void process(float *outL, float *outR, int n, double tempoBPM) {
        const double sr = sampleRate;
        const double vol = plain[kVolume] * plain[kVolume] * 0.9;
        const double portaTau = plain[kPorta] > 0.5 ? plain[kPorta] * 0.001 / 3.0 : 0;
        const double portaCoef = portaTau > 0 ? 1.0 - std::exp(-1.0 / (portaTau * sr)) : 1.0;
        const double vibRate = plain[kVibSync] >= 0.5
            ? std::max(0.05, tempoBPM / 60.0 / divisionBeats((int)plain[kVibDiv])) : plain[kVibRate];
        const double vibDepth = plain[kVibDepth] / 1200.0;
        const double vibFade = plain[kVibAttack] * 0.001;
        const double aInc = 1.0 / std::max(1.0, plain[kAttack] * 0.001 * sr);
        const double dCoef = 1.0 - std::exp(-4.6 / std::max(1.0, plain[kDecay] * 0.001 * sr));
        const double rCoef = std::exp(-4.6 / std::max(1.0, plain[kRelease] * 0.001 * sr));
        const double sustain = plain[kSustain];
        const double sweepA = std::max(0.001, plain[kSweepAttack] * 0.001), sweepD = std::max(0.001, plain[kSweepDecay] * 0.001);
        const double noiseAmt = plain[kNoise];
        const double invSR = 1.0 / sr;
        float mouthTarget = 0;

        for (int i = 0; i < n; i++) { outL[i] = 0; outR[i] = 0; }

        for (auto &v : voices) {
            if (!v.active) continue;
            float vm = 0;
            for (int i = 0; i < n; i++) {
                // envelopes
                if (v.released) {
                    v.env *= rCoef;
                    if (v.env < 1e-4) { v.active = false; v.env = 0; break; }
                } else if (v.stage == 0) {
                    v.env += aInc;
                    if (v.env >= 1) { v.env = 1; v.stage = 1; }
                } else {
                    v.env += (sustain - v.env) * dCoef;
                }
                const double t = v.age;
                // meow sweep: cutoff glides up over sweepA, then back down over sweepD
                double sw;
                if (t < sweepA) { double x = t / sweepA; sw = x * x * (3 - 2 * x); }
                else { double x = std::min(1.0, (t - sweepA) / sweepD); sw = 1 - x * x * (3 - 2 * x); }

                // pitch: portamento, bend, vibrato (fades in per note)
                v.logFreq += (v.targetLog - v.logFreq) * portaCoef;
                const double fade = vibFade > 0 ? std::min(1.0, t / vibFade) : 1.0;
                v.vibPhase += vibRate * invSR; if (v.vibPhase >= 1) v.vibPhase -= 1;
                const double lf = v.logFreq + bend / 12.0 + vibDepth * fade * std::sin(2 * M_PI * v.vibPhase);
                const double freq = std::exp2(lf);
                const double dt = std::min(0.45, freq * invSR);

                // band-limited saw + breath noise
                double saw = 2 * v.phase - 1 - polyBLEP(v.phase, dt);
                v.phase += dt; if (v.phase >= 1) v.phase -= 1;
                double nz = noise(v);
                double x = saw * 0.6 + nz * noiseAmt * 0.8;

                // resonant low-pass, recomputed every 8 samples
                if ((v.k++ & 7) == 0) {
                    double fc = plain[kCutoff] * std::exp2(plain[kSweep] * sw) * std::pow(std::exp2(v.targetLog) / 261.63, plain[kKeyTrack]);
                    fc = std::min(fc, sr * 0.42);
                    fc = std::max(fc, 30.0);
                    const double g = std::tan(M_PI * fc * invSR);
                    v.kq = 1.0 / plain[kResonance];
                    v.a1 = 1.0 / (1.0 + g * (g + v.kq));
                    v.a2 = g * v.a1; v.a3 = g * v.a2;
                }
                const double v3 = x - v.ic2;
                const double v1 = v.a1 * v.ic1 + v.a2 * v3;
                const double v2 = v.ic2 + v.a2 * v.ic1 + v.a3 * v3;
                v.ic1 = 2 * v1 - v.ic1; v.ic2 = 2 * v2 - v.ic2;
                double y = v2 + v1 * v.kq * 0.35;                       // low-pass plus a little band for the whistly formant
                y *= 1.0 / (0.6 + 0.4 * std::sqrt(plain[kResonance]));  // tame the resonant peak
                y = std::tanh(y * 1.4) * 0.8;

                const float s = (float)(y * v.env * (0.35 + 0.65 * v.vel) * 0.5);
                outL[i] += s; outR[i] += s;
                v.age += invSR;
                vm = std::max(vm, (float)(v.env * (0.15 + 0.85 * sw)));
            }
            mouthTarget = std::max(mouthTarget, vm);
        }

        // chorus
        const double mix = plain[kChorus];
        for (int i = 0; i < n; i++) {
            const float dryL = outL[i], dryR = outR[i];
            const float in = 0.5f * (dryL + dryR);
            chorus[0][chorusPos] = in; chorus[1][chorusPos] = in;
            if (mix > 0.001) {
                const double l1 = 0.012 + 0.003 * std::sin(2 * M_PI * cPhase), l2 = 0.017 + 0.003 * std::sin(2 * M_PI * (cPhase * 0.77 + 0.3));
                const float wl = tap(0, l1 * sampleRate) * 0.5f + tap(0, l2 * sampleRate) * 0.5f;
                const double r1 = 0.014 + 0.003 * std::sin(2 * M_PI * (cPhase + 0.5)), r2 = 0.019 + 0.003 * std::sin(2 * M_PI * (cPhase * 0.77 + 0.8));
                const float wr = tap(1, r1 * sampleRate) * 0.5f + tap(1, r2 * sampleRate) * 0.5f;
                outL[i] = (float)(dryL * (1 - 0.5 * mix) + wl * mix * 0.9);
                outR[i] = (float)(dryR * (1 - 0.5 * mix) + wr * mix * 0.9);
            }
            chorusPos = (chorusPos + 1) % chorusLen;
            cPhase += 0.45 / sampleRate; if (cPhase >= 1) cPhase -= 1;
            outL[i] = (float)(outL[i] * vol * 2.2); outR[i] = (float)(outR[i] * vol * 2.2);
        }
        // mouth follows the louder of rise/fall, smoothed so the cat doesn't flicker
        mouthValue += (mouthTarget - mouthValue) * (mouthTarget > mouthValue ? 0.5f : 0.12f);
    }

private:
    struct Voice {
        bool active = false, released = false;
        int note = 0; float vel = 0;
        int stage = 0;               // 0 attack, 1 decay/sustain
        double env = 0, age = 0, phase = 0, vibPhase = 0;
        double logFreq = 0, targetLog = 0;
        double ic1 = 0, ic2 = 0, a1 = 0, a2 = 0, a3 = 0, kq = 0.1;
        uint32_t rng = 22222; unsigned k = 0;
    };

    static double polyBLEP(double t, double dt) {
        if (t < dt) { t /= dt; return t + t - t * t - 1; }
        if (t > 1 - dt) { t = (t - 1) / dt; return t * t + t + t + 1; }
        return 0;
    }
    static double noise(Voice &v) { v.rng ^= v.rng << 13; v.rng ^= v.rng >> 17; v.rng ^= v.rng << 5; return (double)(int32_t)v.rng / 2147483648.0; }
    float tap(int ch, double delaySamples) const {
        double pos = (double)chorusPos - delaySamples;
        while (pos < 0) pos += chorusLen;
        int i0 = (int)pos; double f = pos - i0; int i1 = (i0 + 1) % chorusLen;
        return (float)(chorus[ch][i0] * (1 - f) + chorus[ch][i1] * f);
    }

    void start(Voice &v, int note, float vel, double targetLog, bool keepGlide) {
        v.active = true; v.released = false; v.note = note; v.vel = vel;
        v.stage = 0; v.age = 0; v.vibPhase = 0; v.targetLog = targetLog;
        if (!keepGlide) {
            const bool glide = plain[kPorta] > 0.5 && lastLog > 0;
            v.logFreq = glide ? lastLog : targetLog;
            v.rng = 22222u + (uint32_t)note * 977u;
        }
        lastLog = targetLog;
    }
    void release(Voice &v) { v.released = true; }

    double sampleRate = 44100;
    double plain[kNumParams] = {};
    double bend = 0;
    Voice voices[kMaxVoices];
    std::vector<int> held;
    double lastLog = -1;
    std::vector<float> chorus[2];
    int chorusLen = 4096, chorusPos = 0;
    double cPhase = 0;
    float mouthValue = 0;
};

} // namespace Meow
