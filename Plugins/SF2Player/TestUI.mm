// Drives the shared SF2 editor with synthesized interaction (no host needed).
#import <Cocoa/Cocoa.h>
#include "SF2UI.h"
using namespace SF2Plugin;
static int fails = 0;
static void check(bool ok, const char *what) { printf("  %s %s\n", ok ? "ok  " : "FAIL", what); if (!ok) fails++; }
static NSView *find(NSView *v, Class c) { if ([v isKindOfClass:c]) return v; for (NSView *s in v.subviews) if (NSView *r = find(s, c)) return r; return nil; }
static void pump(double s) { [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:s]]; }
int main(int argc, char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        auto core = std::make_shared<Core>();   // loads SF2PLAYER_DEFAULT_SF2
        core->initParams(); core->synth.setSampleRate(44100);
        std::vector<std::pair<uint32_t, double>> edits;
        SF2EditorView *view = [[SF2EditorView alloc] initWithCore:core edit:[&](uint32_t id, double v) { edits.push_back({id, v}); }];
        NSWindow *w = [[NSWindow alloc] initWithContentRect:view.frame styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        w.contentView = view; [w orderFront:nil]; pump(0.3);
        NSTableView *table = (NSTableView *)find(view, [NSTableView class]);
        NSSearchField *search = (NSSearchField *)find(view, [NSSearchField class]);
        printf("editor test\n");
        check(table.numberOfRows == (NSInteger)core->font->presets.size(), "preset table lists every preset in the file");
        // choose a row
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:40] byExtendingSelection:NO]; pump(0.1);
        check(core->presetIndex == 40, "selecting a row loads that preset");
        std::string name = core->font->presets[40].name;
        // search
        search.stringValue = @"violin"; [view controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:search]];
        pump(0.1);
        check(table.numberOfRows >= 1 && table.numberOfRows < 10, "search narrows the list");
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO]; pump(0.1);
        check(core->font->presets[core->presetIndex].name.find("Violin") != std::string::npos, "a search result loads the right preset");
        search.stringValue = @"zzzznothing"; [view controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:search]];
        check(table.numberOfRows == 0, "no matches shows an empty list");
        search.stringValue = @""; [view controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:search]];
        // sliders
        NSSlider *vol = nil; for (NSView *s in view.subviews) if ([s isKindOfClass:[NSSlider class]]) { vol = (NSSlider *)s; break; }
        vol.doubleValue = 0.4; [view performSelector:@selector(sliderMoved:) withObject:vol];
        check(fabs(core->synth.volume.load() - 0.4) < 1e-6 && !edits.empty() && edits.back().first == kVolume, "volume slider changes the synth and notifies the host");
        // audition keyboard → sound
        core->audition(true, 60, 100);
        std::vector<float> L(2048), R(2048); float peak = 0;
        for (int i = 0; i < 8; i++) { core->render(L.data(), R.data(), 256); for (int k = 0; k < 256; k++) peak = std::max(peak, fabsf(L[k])); }
        check(peak > 0.01f, "audition keyboard makes sound");
        // loading another file path (same file) keeps working and resets selection sensibly
        check(core->loadFile("/definitely/not/here.sf2") == false && !core->error.empty(), "a missing file reports an error instead of crashing");
        pump(0.3);
        check(core->font != nullptr, "the previously loaded SoundFont stays loaded after a failed load");
        [view shutdown];
    }
    printf(fails ? "%d FAILED\n" : "ALL PASSED\n", fails);
    return fails ? 1 : 0;
}
