#import "SF2UI.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <vector>

using namespace SF2Plugin;

static NSColor *RGB(CGFloat r, CGFloat g, CGFloat b, CGFloat a = 1) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a]; }
static NSColor *Accent() { return RGB(0.36, 0.72, 1.0); }

// MARK: - Audition keyboard

@interface SF2KeyboardView : NSView
@property(nonatomic) std::shared_ptr<Core> core;
@end

@implementation SF2KeyboardView {
    int down;
}
@synthesize core;
static const int kLow = 36, kHigh = 96;   // C2 … C7
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
static bool IsBlack(int n) { int k = n % 12; return k == 1 || k == 3 || k == 6 || k == 8 || k == 10; }
- (CGFloat)whiteWidth { int whites = 0; for (int n = kLow; n <= kHigh; n++) if (!IsBlack(n)) whites++; return self.bounds.size.width / whites; }
- (NSRect)rectForKey:(int)n {
    CGFloat ww = [self whiteWidth]; int whiteIndex = 0;
    for (int i = kLow; i < n; i++) if (!IsBlack(i)) whiteIndex++;
    if (!IsBlack(n)) return NSMakeRect(whiteIndex * ww, 0, ww, self.bounds.size.height);
    return NSMakeRect(whiteIndex * ww - ww * 0.3, 0, ww * 0.6, self.bounds.size.height * 0.62);
}
- (int)keyAt:(NSPoint)p {
    for (int n = kLow; n <= kHigh; n++) if (IsBlack(n) && NSPointInRect(p, [self rectForKey:n])) return n;
    for (int n = kLow; n <= kHigh; n++) if (!IsBlack(n) && NSPointInRect(p, [self rectForKey:n])) return n;
    return -1;
}
- (void)drawRect:(NSRect)dirty {
    [RGB(0.08, 0.08, 0.09) setFill]; NSRectFill(self.bounds);
    for (int n = kLow; n <= kHigh; n++) if (!IsBlack(n)) {
        NSRect r = NSInsetRect([self rectForKey:n], 0.5, 0);
        [(n == down ? Accent() : RGB(0.90, 0.90, 0.92)) setFill]; NSRectFill(r);
        if (n % 12 == 0) {
            NSDictionary *a = @{NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightMedium], NSForegroundColorAttributeName: RGB(0.35, 0.35, 0.4)};
            [[NSString stringWithFormat:@"C%d", n / 12 - 1] drawAtPoint:NSMakePoint(r.origin.x + 3, r.size.height - 13) withAttributes:a];
        }
    }
    for (int n = kLow; n <= kHigh; n++) if (IsBlack(n)) { [(n == down ? Accent() : RGB(0.12, 0.12, 0.14)) setFill]; NSRectFill([self rectForKey:n]); }
}
- (void)play:(int)n vel:(int)v {
    if (n == down) return;
    if (down >= 0 && core) core->audition(false, down);
    down = n;
    if (n >= 0 && core) core->audition(true, n, v);
    [self setNeedsDisplay:YES];
}
- (int)velocityFor:(NSPoint)p { return (int)std::min(127.0, std::max(30.0, 40 + 87 * p.y / self.bounds.size.height)); }
- (void)mouseDown:(NSEvent *)e { down = -1; NSPoint p = [self convertPoint:e.locationInWindow fromView:nil]; [self play:[self keyAt:p] vel:[self velocityFor:p]]; }
- (void)mouseDragged:(NSEvent *)e { NSPoint p = [self convertPoint:e.locationInWindow fromView:nil]; [self play:[self keyAt:p] vel:[self velocityFor:p]]; }
- (void)mouseUp:(NSEvent *)e { if (down >= 0 && core) core->audition(false, down); down = -1; [self setNeedsDisplay:YES]; }
@end

// MARK: - Editor

@interface SF2EditorView () <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>
@end

@implementation SF2EditorView {
    std::shared_ptr<Core> core;
    std::function<void(uint32_t, double)> editCB;
    std::shared_ptr<SF2::SoundFont> shownFont;
    std::vector<int> rows;               // indices into shownFont->presets that match the search
    int shownRevision;
    NSString *query;
    NSTableView *table;
    NSTextField *fileLabel, *statusLabel, *countLabel, *voiceLabel;
    NSSearchField *search;
    SF2KeyboardView *keys;
    NSTimer *timer;
    NSSlider *sliders[4];
    NSTextField *sliderValues[4];
    uint32_t sliderIDs[4];
    NSView *meter;
    NSProgressIndicator *busy;
}

static NSTextField *Label(NSString *s, CGFloat size, NSFontWeight w, NSColor *c) {
    NSTextField *t = [NSTextField labelWithString:s];
    t.font = [NSFont systemFontOfSize:size weight:w]; t.textColor = c; t.lineBreakMode = NSLineBreakByTruncatingMiddle;
    return t;
}

- (instancetype)initWithCore:(std::shared_ptr<Core>)c edit:(std::function<void(uint32_t, double)>)edit {
    self = [super initWithFrame:NSMakeRect(0, 0, 720, 540)];
    core = c; editCB = edit; shownRevision = -1; query = @"";
    self.wantsLayer = YES; self.layer.backgroundColor = RGB(0.115, 0.12, 0.135).CGColor;
    self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];

    NSTextField *title = Label(@"SF2 Player", 22, NSFontWeightHeavy, RGB(0.9, 0.93, 1));
    title.frame = NSMakeRect(20, 14, 200, 28); [self addSubview:title];

    NSButton *load = [NSButton buttonWithTitle:@"Load SoundFont…" target:self action:@selector(chooseFile:)];
    load.bezelStyle = NSBezelStyleRounded; load.frame = NSMakeRect(20, 52, 150, 28); [self addSubview:load];

    fileLabel = Label(@"No SoundFont loaded — click Load, or drop an .sf2 file here", 12, NSFontWeightMedium, RGB(1, 1, 1, 0.75));
    fileLabel.frame = NSMakeRect(180, 56, 360, 18); [self addSubview:fileLabel];
    statusLabel = Label(@"", 11, NSFontWeightRegular, RGB(1, 1, 1, 0.4));
    statusLabel.frame = NSMakeRect(180, 74, 360, 14); [self addSubview:statusLabel];

    voiceLabel = Label(@"", 11, NSFontWeightRegular, RGB(1, 1, 1, 0.4));
    voiceLabel.alignment = NSTextAlignmentRight; voiceLabel.frame = NSMakeRect(560, 18, 140, 14); [self addSubview:voiceLabel];
    meter = [[NSView alloc] initWithFrame:NSMakeRect(560, 36, 140, 5)];
    meter.wantsLayer = YES; meter.layer.backgroundColor = RGB(1, 1, 1, 0.1).CGColor; meter.layer.cornerRadius = 2.5;
    NSView *fill = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 0, 5)]; fill.wantsLayer = YES; fill.layer.backgroundColor = Accent().CGColor; fill.layer.cornerRadius = 2.5; fill.identifier = @"fill";
    [meter addSubview:fill]; [self addSubview:meter];

    search = [[NSSearchField alloc] initWithFrame:NSMakeRect(20, 96, 680, 26)];
    search.placeholderString = @"Search presets by name, bank or program"; search.delegate = self;
    [self addSubview:search];
    countLabel = Label(@"", 11, NSFontWeightRegular, RGB(1, 1, 1, 0.4));
    countLabel.alignment = NSTextAlignmentRight; countLabel.frame = NSMakeRect(480, 130, 220, 14);

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 148, 680, 204)];
    scroll.hasVerticalScroller = YES; scroll.borderType = NSNoBorder; scroll.drawsBackground = NO;
    table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    table.backgroundColor = RGB(0.085, 0.09, 0.10); table.rowHeight = 22; table.usesAlternatingRowBackgroundColors = NO;
    table.gridStyleMask = NSTableViewSolidHorizontalGridLineMask; table.gridColor = RGB(1, 1, 1, 0.04);
    table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    NSArray *cols = @[@[@"bank", @"Bank", @60], @[@"prog", @"Program", @70], @[@"name", @"Preset", @520]];
    for (NSArray *c in cols) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
        col.title = c[1]; col.width = [c[2] floatValue]; col.minWidth = 40; [table addTableColumn:col];
    }
    table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = @selector(rowClicked:); table.action = @selector(rowClicked:);
    scroll.documentView = table; [self addSubview:scroll]; [self addSubview:countLabel];

    // sliders
    const uint32_t ids[4] = {kVolume, kReverb, kBendRange, kTranspose};
    for (int i = 0; i < 4; i++) {
        sliderIDs[i] = ids[i];
        const ParamDef &d = def(ids[i]);
        CGFloat x = 20 + i * 172;
        NSTextField *l = Label([NSString stringWithUTF8String:d.name], 11, NSFontWeightSemibold, RGB(1, 1, 1, 0.55));
        l.frame = NSMakeRect(x, 366, 90, 14); [self addSubview:l];
        sliderValues[i] = Label(@"", 11, NSFontWeightRegular, Accent()); sliderValues[i].alignment = NSTextAlignmentRight;
        sliderValues[i].frame = NSMakeRect(x + 90, 366, 66, 14); [self addSubview:sliderValues[i]];
        sliders[i] = [NSSlider sliderWithValue:d.def minValue:d.min maxValue:d.max target:self action:@selector(sliderMoved:)];
        sliders[i].tag = i; sliders[i].frame = NSMakeRect(x, 384, 156, 20);
        if (@available(macOS 10.12.2, *)) sliders[i].trackFillColor = Accent();
        [self addSubview:sliders[i]];
    }

    keys = [[SF2KeyboardView alloc] initWithFrame:NSMakeRect(20, 420, 680, 100)];
    keys.core = core; keys.wantsLayer = YES; keys.layer.cornerRadius = 6; keys.layer.masksToBounds = YES;
    [self addSubview:keys];

    timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 15 repeats:YES block:^(NSTimer *t) { [self tick]; }];
    [self refresh];
    return self;
}

- (void)shutdown { [timer invalidate]; timer = nil; core.reset(); keys.core = nullptr; editCB = nullptr; }
- (void)dealloc { [timer invalidate]; }
- (BOOL)isFlipped { return YES; }

// MARK: Data

- (void)refresh {
    if (!core) return;
    {
        std::lock_guard<std::mutex> l(core->mu);
        shownFont = core->font;
        shownRevision = core->revision.load();
        NSString *err = core->error.empty() ? nil : [NSString stringWithUTF8String:core->error.c_str()];
        if (shownFont) {
            NSString *file = [[NSString stringWithUTF8String:core->path.c_str()] lastPathComponent];
            fileLabel.stringValue = file;
            NSString *nm = shownFont->name.empty() ? @"" : [NSString stringWithUTF8String:shownFont->name.c_str()];
            statusLabel.stringValue = err ?: [NSString stringWithFormat:@"%@%@%zu presets · %.1f M samples", nm, nm.length ? @" · " : @"", shownFont->presets.size(), shownFont->sampleCount() / 1e6];
        } else if (err) statusLabel.stringValue = err;
        if (err) statusLabel.textColor = RGB(1, 0.55, 0.45);
        else statusLabel.textColor = RGB(1, 1, 1, 0.4);
    }
    rows.clear();
    if (shownFont) {
        NSString *q = query.lowercaseString;
        for (size_t i = 0; i < shownFont->presets.size(); i++) {
            const auto &p = shownFont->presets[i];
            if (q.length) {
                NSString *hay = [[NSString stringWithFormat:@"%s %03d %03d %d:%d", p.name.c_str(), p.bank, p.program, p.bank, p.program] lowercaseString];
                if ([hay rangeOfString:q].location == NSNotFound) continue;
            }
            rows.push_back((int)i);
        }
    }
    countLabel.stringValue = shownFont ? [NSString stringWithFormat:@"%zu of %zu", rows.size(), shownFont->presets.size()] : @"";
    [table reloadData];
    [self syncSelection];
}

- (void)syncSelection {
    int cur = core ? core->presetIndex.load() : 0;
    NSInteger row = NSNotFound;
    for (size_t i = 0; i < rows.size(); i++) if (rows[i] == cur) { row = (NSInteger)i; break; }
    if (row != NSNotFound) { [table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO]; [table scrollRowToVisible:row]; }
    else [table deselectAll:nil];
}

- (void)tick {
    if (!core) return;
    core->synth.collectGarbage();
    if (core->revision.load() != shownRevision) [self refresh];
    for (int i = 0; i < 4; i++) {
        double v = core->value(sliderIDs[i]);
        if (fabs(sliders[i].doubleValue - v) > 1e-6 && ![sliders[i].cell isHighlighted]) sliders[i].doubleValue = v;
        const ParamDef &d = def(sliderIDs[i]);
        sliderValues[i].stringValue = d.steps ? [NSString stringWithFormat:@"%+.0f", v] : [NSString stringWithFormat:@"%.0f%%", v * 100];
        if (sliderIDs[i] == kBendRange) sliderValues[i].stringValue = [NSString stringWithFormat:@"%.0f st", v];
    }
    int voices = core->synth.activeVoices();
    voiceLabel.stringValue = voices ? [NSString stringWithFormat:@"%d voice%@", voices, voices == 1 ? @"" : @"s"] : @"";
    for (NSView *v in meter.subviews) if ([v.identifier isEqualToString:@"fill"]) {
        float lv = core->level.load();
        double db = lv > 1e-5 ? 20 * log10(lv) : -90;
        v.frame = NSMakeRect(0, 0, 140 * std::min(1.0, std::max(0.0, (db + 60) / 60)), 5);
    }
}

// MARK: Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)rows.size(); }
- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)rows.size() || !shownFont) return nil;
    const auto &p = shownFont->presets[rows[row]];
    NSTextField *t = [tv makeViewWithIdentifier:col.identifier owner:self];
    if (!t) { t = [NSTextField labelWithString:@""]; t.identifier = col.identifier; t.font = [NSFont systemFontOfSize:12]; t.lineBreakMode = NSLineBreakByTruncatingTail; }
    if ([col.identifier isEqualToString:@"bank"]) { t.stringValue = [NSString stringWithFormat:@"%03d", p.bank]; t.textColor = RGB(1, 1, 1, 0.45); t.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular]; }
    else if ([col.identifier isEqualToString:@"prog"]) { t.stringValue = [NSString stringWithFormat:@"%03d", p.program]; t.textColor = RGB(1, 1, 1, 0.45); t.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular]; }
    else { t.stringValue = [NSString stringWithUTF8String:p.name.c_str()]; t.textColor = RGB(1, 1, 1, 0.92); t.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]; }
    return t;
}
- (void)rowClicked:(id)sender {
    NSInteger r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow;
    if (r >= 0 && r < (NSInteger)rows.size() && core) core->selectPreset(rows[r]);
}
- (void)tableViewSelectionDidChange:(NSNotification *)n {
    NSInteger r = table.selectedRow;
    if (r >= 0 && r < (NSInteger)rows.size() && core && rows[r] != core->presetIndex.load()) core->selectPreset(rows[r]);   // arrow-key browsing
}
- (void)controlTextDidChange:(NSNotification *)n { query = search.stringValue ?: @""; [self refresh]; }

// MARK: Actions

- (void)sliderMoved:(NSSlider *)s {
    if (!core) return;
    uint32_t id = sliderIDs[s.tag];
    double v = def(id).steps ? round(s.doubleValue) : s.doubleValue;
    core->setParam(id, v);
    if (editCB) editCB(id, v);
}

- (void)chooseFile:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.title = @"Choose a SoundFont"; p.allowsMultipleSelection = NO; p.canChooseDirectories = NO;
    UTType *sf2 = [UTType typeWithFilenameExtension:@"sf2"];
    if (sf2) p.allowedContentTypes = @[sf2];
    if ([p runModal] == NSModalResponseOK && p.URL) [self loadPath:p.URL.path];
}
- (void)loadPath:(NSString *)path {
    if (!core) return;
    statusLabel.stringValue = @"Loading…";
    auto c = core; std::string s = path.UTF8String;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ c->loadFile(s); });
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info { return NSDragOperationCopy; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    NSArray<NSURL *> *urls = [info.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    for (NSURL *u in urls) if ([u.pathExtension.lowercaseString isEqualToString:@"sf2"]) { [self loadPath:u.path]; return YES; }
    return NO;
}
@end
