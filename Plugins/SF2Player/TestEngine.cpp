// Standalone check of the SF2 engine: loads a file, lists presets, renders a chord to a WAV.
#include "SF2Engine.h"
#include <cstdio>
#include <iostream>
int main(int argc, char **argv) {
    std::string err;
    auto sf = SF2::SoundFont::load(argv[1], err);
    if (!sf) { printf("load failed: %s\n", err.c_str()); return 1; }
    printf("bank '%s': %zu presets, %zu samples\n", sf->name.c_str(), sf->presets.size(), sf->sampleCount());
    for (size_t i = 0; i < std::min<size_t>(sf->presets.size(), 12); i++) printf("  %03d:%03d %s\n", sf->presets[i].bank, sf->presets[i].program, sf->presets[i].name.c_str());
    int idx = argc > 2 ? atoi(argv[2]) : 0;
    auto preset = sf->buildPreset(idx);
    printf("preset '%s': %zu regions\n", preset->name.c_str(), preset->regions.size());
    SF2::Synth syn; syn.setSampleRate(44100); syn.setPreset(preset, sf);
    const int total = 44100 * 3; std::vector<float> L(total), R(total);
    int pos = 0, step = 256;
    for (; pos < total; pos += step) {
        static bool on = false, off = false;
        if (!on) { on = true; syn.noteOn(60, 100); syn.noteOn(64, 100); syn.noteOn(67, 100); }
        if (!off && pos >= 44100 * 2) { off = true; syn.noteOff(60); syn.noteOff(64); syn.noteOff(67); }
        syn.render(L.data() + pos, R.data() + pos, std::min(step, total - pos));
    }
    float peak = 0; double e1 = 0, e2 = 0;
    for (int i = 0; i < total; i++) { peak = std::max(peak, std::fabs(L[i])); if (i < 44100) e1 += L[i] * L[i]; else if (i > 44100 * 2.5) e2 += L[i] * L[i]; }
    printf("peak %.3f  rms(first s) %.4f  rms(after release) %.6f  voices at end %d\n", peak, std::sqrt(e1 / 44100), std::sqrt(e2 / (44100 * 0.5)), syn.activeVoices());
    // zero-crossing pitch of a single note
    SF2::Synth s2; s2.setSampleRate(44100); s2.setPreset(preset, sf); s2.reverbLevel = 0;
    std::vector<float> a(44100), b(44100); s2.noteOn(69, 100);
    for (int p = 0; p < 44100; p += 256) s2.render(a.data() + p, b.data() + p, std::min(256, 44100 - p));
    int cross = 0; for (int i = 20000; i < 40000; i++) if (a[i - 1] < 0 && a[i] >= 0) cross++;
    printf("A4 zero-crossing estimate: %.1f Hz (expect ~440 for pitched presets)\n", cross / (20000.0 / 44100));
    return 0;
}
