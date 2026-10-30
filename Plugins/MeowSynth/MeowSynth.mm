// MeowSynth — a macOS VST3 instrument that meows. Processor, controller, editor and factory.
#import <Cocoa/Cocoa.h>
#include <string>

#include "base/source/fstreamer.h"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/base/ustring.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstmidicontrollers.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/vstspeaker.h"
#include "public.sdk/source/common/pluginview.h"
#include "public.sdk/source/vst/vstaudioeffect.h"
#include "public.sdk/source/vst/vsteditcontroller.h"

#include "MeowEngine.h"

using namespace Steinberg;
using namespace Steinberg::Vst;

static const FUID kProcessorUID(0x4D454F57, 0x53594E54, 0x50524F43, 0x00000001);
static const FUID kControllerUID(0x4D454F57, 0x53594E54, 0x43544C52, 0x00000001);

class MeowController;

// MARK: - Processor

class MeowProcessor : public AudioEffect {
public:
    MeowProcessor() {
        setControllerClass(kControllerUID);
        shared = std::make_shared<Meow::Shared>();
        sharedID = Meow::registerShared(shared);
        for (uint32_t i = 0; i < Meow::kNumParams; i++) normalized[i] = Meow::toNorm(i, Meow::def(i).def);
        normalized[Meow::kBend] = 0.5;
    }

    tresult PLUGIN_API initialize(FUnknown *context) SMTG_OVERRIDE {
        tresult r = AudioEffect::initialize(context);
        if (r != kResultOk) return r;
        addEventInput(STR16("Events In"), 1);
        addAudioOutput(STR16("Stereo Out"), SpeakerArr::kStereo);
        return kResultOk;
    }

    tresult PLUGIN_API setBusArrangements(SpeakerArrangement *inputs, int32 numIns, SpeakerArrangement *outputs, int32 numOuts) SMTG_OVERRIDE {
        if (numIns == 0 && numOuts == 1 && outputs[0] == SpeakerArr::kStereo) return AudioEffect::setBusArrangements(inputs, numIns, outputs, numOuts);
        return kResultFalse;
    }

    tresult PLUGIN_API connect(IConnectionPoint *other) SMTG_OVERRIDE {
        tresult r = AudioEffect::connect(other);
        // tell the editor where to read the animation values (same process)
        if (IMessage *m = allocateMessage()) {
            FReleaser rel(m);
            m->setMessageID("MeowShared");
            m->getAttributes()->setInt("id", sharedID);
            sendMessage(m);
        }
        return r;
    }

    tresult PLUGIN_API canProcessSampleSize(int32 s) SMTG_OVERRIDE { return s == kSample32 ? kResultTrue : kResultFalse; }

    tresult PLUGIN_API setupProcessing(ProcessSetup &setup) SMTG_OVERRIDE {
        engine.setSampleRate(setup.sampleRate);
        pushParams();
        return AudioEffect::setupProcessing(setup);
    }

    tresult PLUGIN_API setActive(TBool state) SMTG_OVERRIDE {
        if (!state) engine.reset();
        return AudioEffect::setActive(state);
    }

    tresult PLUGIN_API process(ProcessData &data) SMTG_OVERRIDE {
        if (data.inputParameterChanges) {
            int32 n = data.inputParameterChanges->getParameterCount();
            for (int32 i = 0; i < n; i++) {
                IParamValueQueue *q = data.inputParameterChanges->getParameterData(i);
                if (!q) continue;
                int32 pts = q->getPointCount();
                if (pts <= 0) continue;
                int32 off; ParamValue v;
                if (q->getPoint(pts - 1, off, v) == kResultTrue && q->getParameterId() < Meow::kNumParams) normalized[q->getParameterId()] = v;
            }
            pushParams();
        }
        if (data.numOutputs < 1 || data.outputs[0].numChannels < 1) return kResultOk;
        const int32 frames = data.numSamples;
        float *l = data.outputs[0].channelBuffers32[0];
        float *r = data.outputs[0].numChannels > 1 ? data.outputs[0].channelBuffers32[1] : nullptr;
        if (!r) { scratch.resize(frames); r = scratch.data(); }

        double tempo = 120;
        if (data.processContext && (data.processContext->state & ProcessContext::kTempoValid)) tempo = data.processContext->tempo;

        // render in segments between note events
        int32 pos = 0;
        auto renderTo = [&](int32 end) {
            if (end > pos) { engine.process(l + pos, r + pos, end - pos, tempo); pos = end; }
        };
        if (data.inputEvents) {
            int32 count = data.inputEvents->getEventCount();
            for (int32 i = 0; i < count; i++) {
                Event e;
                if (data.inputEvents->getEvent(i, e) != kResultOk) continue;
                renderTo(std::min(frames, std::max(pos, e.sampleOffset)));
                if (e.type == Event::kNoteOnEvent) {
                    if (e.noteOn.velocity <= 0) engine.noteOff(e.noteOn.pitch); else engine.noteOn(e.noteOn.pitch, e.noteOn.velocity);
                } else if (e.type == Event::kNoteOffEvent) engine.noteOff(e.noteOff.pitch);
            }
        }
        renderTo(frames);
        if (data.outputs[0].numChannels > 1) data.outputs[0].silenceFlags = 0;

        shared->mouth.store(engine.mouth());
        shared->voices.store(engine.activeVoices());
        return kResultOk;
    }

    tresult PLUGIN_API setState(IBStream *state) SMTG_OVERRIDE {
        IBStreamer s(state, kLittleEndian);
        int32 version = 0;
        if (!s.readInt32(version) || version != 1) return kResultFalse;
        for (uint32_t i = 0; i < Meow::kNumParams; i++) { double v; if (s.readDouble(v)) normalized[i] = v; }
        pushParams();
        return kResultOk;
    }
    tresult PLUGIN_API getState(IBStream *state) SMTG_OVERRIDE {
        IBStreamer s(state, kLittleEndian);
        s.writeInt32(1);
        for (uint32_t i = 0; i < Meow::kNumParams; i++) s.writeDouble(normalized[i]);
        return kResultOk;
    }

private:
    void pushParams() {
        double p[Meow::kNumParams];
        for (uint32_t i = 0; i < Meow::kNumParams; i++) p[i] = Meow::toPlain(i, normalized[i]);
        engine.setParams(p);
        // pitch bend: normalized 0…1 → ±bend range semitones
        engine.setBend((normalized[Meow::kBend] * 2 - 1) * p[Meow::kBendRange]);
    }

    Meow::Engine engine;
    double normalized[Meow::kNumParams];
    std::shared_ptr<Meow::Shared> shared;
    int64_t sharedID = 0;
    std::vector<float> scratch;
};

// MARK: - Editor (AppKit)

@interface MeowCanvas : NSView
@property(nonatomic) MeowController *controller;
- (void)stop;
@end

// MARK: - Controller

class MeowController : public EditController, public IMidiMapping {
public:
    tresult PLUGIN_API initialize(FUnknown *context) SMTG_OVERRIDE {
        tresult r = EditController::initialize(context);
        if (r != kResultOk) return r;
        for (uint32_t i = 0; i < Meow::kNumParams; i++) {
            const Meow::ParamDef &d = Meow::def(i);
            UString128 title(d.name), units(d.units);
            int32 flags = ParameterInfo::kCanAutomate;
            double dn = Meow::toNorm(i, d.def);
            if (i == Meow::kBend) { flags = ParameterInfo::kIsHidden; dn = 0.5; }
            parameters.addParameter(title, units, d.steps, dn, flags, i);
        }
        return kResultOk;
    }

    tresult PLUGIN_API setComponentState(IBStream *state) SMTG_OVERRIDE {
        IBStreamer s(state, kLittleEndian);
        int32 version = 0;
        if (!s.readInt32(version) || version != 1) return kResultFalse;
        for (uint32_t i = 0; i < Meow::kNumParams; i++) { double v; if (s.readDouble(v)) setParamNormalized(i, v); }
        return kResultOk;
    }

    tresult PLUGIN_API notify(IMessage *message) SMTG_OVERRIDE {
        if (message && strcmp(message->getMessageID(), "MeowShared") == 0) {
            int64 id = 0;
            if (message->getAttributes()->getInt("id", id) == kResultOk) shared = Meow::findShared(id);
            return kResultOk;
        }
        return EditController::notify(message);
    }

    IPlugView *PLUGIN_API createView(FIDString name) SMTG_OVERRIDE;

    tresult PLUGIN_API getParamStringByValue(ParamID id, ParamValue norm, String128 string) SMTG_OVERRIDE {
        if (id >= Meow::kNumParams) return kResultFalse;
        UString(string, 128).fromAscii(format(id, Meow::toPlain(id, norm)).c_str());
        return kResultTrue;
    }
    tresult PLUGIN_API getParamValueByString(ParamID id, TChar *string, ParamValue &norm) SMTG_OVERRIDE {
        if (id >= Meow::kNumParams) return kResultFalse;
        char buf[128]; UString128(string).toAscii(buf, 128);
        norm = Meow::toNorm(id, atof(buf));
        return kResultTrue;
    }
    ParamValue PLUGIN_API normalizedParamToPlain(ParamID id, ParamValue v) SMTG_OVERRIDE { return id < Meow::kNumParams ? Meow::toPlain(id, v) : v; }
    ParamValue PLUGIN_API plainParamToNormalized(ParamID id, ParamValue v) SMTG_OVERRIDE { return id < Meow::kNumParams ? Meow::toNorm(id, v) : v; }

    tresult PLUGIN_API getMidiControllerAssignment(int32 busIndex, int16 channel, CtrlNumber number, ParamID &id) SMTG_OVERRIDE {
        if (busIndex == 0 && number == kPitchBend) { id = Meow::kBend; return kResultTrue; }
        return kResultFalse;
    }

    static std::string format(uint32_t id, double v) {
        const Meow::ParamDef &d = Meow::def(id);
        char b[64];
        if (d.scale == Meow::Scale::Toggle) return v >= 0.5 ? "On" : "Off";
        if (d.scale == Meow::Scale::List) return Meow::divisionName((int)v);
        if (id == Meow::kBend) { snprintf(b, sizeof b, "%+.2f st", v); return b; }
        if (!strcmp(d.units, "ms") || !strcmp(d.units, "Hz")) {
            if (!strcmp(d.units, "ms") && v >= 1000) snprintf(b, sizeof b, "%.2f s", v / 1000);
            else if (v >= 1000) snprintf(b, sizeof b, "%.2f kHz", v / 1000);
            else snprintf(b, sizeof b, v < 10 && !strcmp(d.units, "Hz") ? "%.1f Hz" : "%.0f %s", v, d.units);
            std::string s = b;
            if (!strcmp(d.units, "ms") && v < 1000) s = std::string(b).substr(0, std::string(b).find(' ')) + " ms";
            return s;
        }
        if (d.steps > 0) snprintf(b, sizeof b, "%.0f %s", v, d.units);
        else if (!strcmp(d.units, "")) snprintf(b, sizeof b, "%.0f%%", v * 100);
        else snprintf(b, sizeof b, "%.1f %s", v, d.units);
        return b;
    }

    std::shared_ptr<Meow::Shared> shared;

    OBJ_METHODS(MeowController, EditController)
    DEFINE_INTERFACES
        DEF_INTERFACE(IMidiMapping)
    END_DEFINE_INTERFACES(EditController)
    REFCOUNT_METHODS(EditController)
};

// MARK: - Editor view

namespace {
struct Control {
    uint32_t id; NSRect rect; BOOL isKnob;
};
NSColor *C(CGFloat r, CGFloat g, CGFloat b, CGFloat a = 1) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a]; }
}

@implementation MeowCanvas {
    std::vector<Control> controls;
    int dragging, hover;
    NSPoint lastPoint;
    NSTimer *timer;
    float shownMouth, whisker;
    double blink;
}
@synthesize controller;

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

- (instancetype)initWithFrame:(NSRect)f {
    self = [super initWithFrame:f];
    dragging = -1; hover = -1; shownMouth = 0; whisker = 0; blink = 0;
    [self buildLayout];
    timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *t) { [self tick]; }];
    NSTrackingArea *ta = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:ta];
    return self;
}
- (void)stop { [timer invalidate]; timer = nil; controller = nullptr; }
- (void)dealloc { [timer invalidate]; }

- (void)buildLayout {
    controls.clear();
    const CGFloat x0 = 292, cw = 82, ch = 102, y0 = 52;
    auto knob = [&](uint32_t id, int col, int row) { controls.push_back({id, NSMakeRect(x0 + col * cw, y0 + row * ch + 18, cw, ch - 18), YES}); };
    auto sw = [&](uint32_t id, int col, int row) { controls.push_back({id, NSMakeRect(x0 + col * cw + 6, y0 + row * ch + 38, cw - 12, 30), NO}); };
    using namespace Meow;
    knob(kVolume, 0, 0); knob(kNoise, 1, 0); knob(kPorta, 2, 0); knob(kChorus, 3, 0); sw(kPoly, 4, 0); knob(kBendRange, 5, 0);
    knob(kAttack, 0, 1); knob(kDecay, 1, 1); knob(kSustain, 2, 1); knob(kRelease, 3, 1);
    knob(kCutoff, 0, 2); knob(kResonance, 1, 2); knob(kSweep, 2, 2); knob(kSweepAttack, 3, 2); knob(kSweepDecay, 4, 2); knob(kKeyTrack, 5, 2);
    knob(kVibRate, 0, 3); knob(kVibDepth, 1, 3); knob(kVibAttack, 2, 3); sw(kVibSync, 3, 3); sw(kVibDiv, 4, 3);
}

- (void)tick {
    float m = controller && controller->shared ? controller->shared->mouth.load() : 0;
    blink += 1.0 / 30;
    if (fabsf(m - shownMouth) > 0.003 || fabsf(whisker - m) > 0.01 || fmod(blink, 4.0) < 0.2) { shownMouth = m; whisker += (m - whisker) * 0.3f; [self setNeedsDisplay:YES]; }
}

// MARK: Parameter access

- (double)norm:(uint32_t)i { return controller ? controller->getParamNormalized(i) : 0; }
- (void)set:(uint32_t)i norm:(double)v {
    if (!controller) return;
    v = std::min(1.0, std::max(0.0, v));
    if (Meow::def(i).steps > 0) v = std::round(v * Meow::def(i).steps) / Meow::def(i).steps;
    controller->setParamNormalized(i, v);
    controller->performEdit(i, v);
}

// MARK: Drawing

- (void)drawRect:(NSRect)dirty {
    [C(0.105, 0.095, 0.125) setFill]; NSRectFill(self.bounds);
    [self drawCat];
    [self drawPanel];
}

- (void)drawPanel {
    NSDictionary *head = @{NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightBold], NSForegroundColorAttributeName: C(1, 1, 1, 0.38)};
    const char *titles[] = {"VOICE", "AMP", "MOUTH  (filter sweep)", "VIBRATO"};
    for (int r = 0; r < 4; r++) {
        NSString *t = [NSString stringWithUTF8String:titles[r]];
        [t drawAtPoint:NSMakePoint(298, 52 + r * 102) withAttributes:head];
        [C(1, 1, 1, 0.06) setFill]; NSRectFill(NSMakeRect(298, 52 + r * 102 + 15, 470, 1));
    }
    for (size_t i = 0; i < controls.size(); i++) [self drawControl:controls[i] hot:((int)i == hover || (int)i == dragging)];
    NSDictionary *small = @{NSFontAttributeName: [NSFont systemFontOfSize:10], NSForegroundColorAttributeName: C(1, 1, 1, 0.3)};
    [@"double-click a knob to reset  ·  shift-drag for fine control" drawAtPoint:NSMakePoint(298, self.bounds.size.height - 22) withAttributes:small];
}

- (void)drawControl:(Control)c hot:(BOOL)hot {
    using namespace Meow;
    const ParamDef &d = def(c.id);
    double n = [self norm:c.id];
    NSString *label = [NSString stringWithUTF8String:d.name];
    std::string valueText = MeowController::format(c.id, toPlain(c.id, n));
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter;
    NSDictionary *la = @{NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightMedium], NSForegroundColorAttributeName: C(1, 1, 1, hot ? 0.85 : 0.55), NSParagraphStyleAttributeName: ps};
    NSDictionary *va = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular], NSForegroundColorAttributeName: C(1.0, 0.72, 0.38, hot ? 1 : 0.8), NSParagraphStyleAttributeName: ps};
    NSColor *accent = C(1.0, 0.60, 0.24);

    if (c.isKnob) {
        NSPoint ctr = NSMakePoint(NSMidX(c.rect), c.rect.origin.y + 24);
        CGFloat r = 19;
        NSBezierPath *track = [NSBezierPath bezierPath];
        [track appendBezierPathWithArcWithCenter:ctr radius:r startAngle:135 endAngle:405 clockwise:NO];
        track.lineWidth = 3.5; track.lineCapStyle = NSLineCapStyleRound;
        [C(1, 1, 1, 0.10) setStroke]; [track stroke];
        // y axis is flipped, so angles run clockwise on screen
        double a0 = 135, a1 = 135 + 270 * n;
        BOOL bipolar = (c.id == kBend);
        NSBezierPath *val = [NSBezierPath bezierPath];
        [val appendBezierPathWithArcWithCenter:ctr radius:r startAngle:bipolar ? 270 : a0 endAngle:bipolar ? a1 : a1 clockwise:NO];
        val.lineWidth = 3.5; val.lineCapStyle = NSLineCapStyleRound;
        [(hot ? C(1.0, 0.72, 0.38) : accent) setStroke]; [val stroke];
        double ang = (a1) * M_PI / 180;
        NSBezierPath *ptr = [NSBezierPath bezierPath];
        [ptr moveToPoint:NSMakePoint(ctr.x + cos(ang) * 5, ctr.y + sin(ang) * 5)];
        [ptr lineToPoint:NSMakePoint(ctr.x + cos(ang) * (r - 3), ctr.y + sin(ang) * (r - 3))];
        ptr.lineWidth = 2; ptr.lineCapStyle = NSLineCapStyleRound; [C(1, 1, 1, 0.9) setStroke]; [ptr stroke];
        [label drawInRect:NSMakeRect(c.rect.origin.x, c.rect.origin.y + 47, c.rect.size.width, 14) withAttributes:la];
        [[NSString stringWithUTF8String:valueText.c_str()] drawInRect:NSMakeRect(c.rect.origin.x, c.rect.origin.y + 60, c.rect.size.width, 14) withAttributes:va];
    } else {
        NSRect b = c.rect;
        BOOL on = (d.scale == Scale::Toggle) ? n >= 0.5 : YES;
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:b xRadius:7 yRadius:7];
        [(on && d.scale == Scale::Toggle ? C(1.0, 0.60, 0.24, 0.22) : C(1, 1, 1, hot ? 0.10 : 0.06)) setFill]; [p fill];
        [(on && d.scale == Scale::Toggle ? accent : C(1, 1, 1, 0.12)) setStroke]; p.lineWidth = 1; [p stroke];
        NSString *txt = d.scale == Scale::List ? [NSString stringWithUTF8String:valueText.c_str()] : (n >= 0.5 ? @"ON" : @"OFF");
        NSDictionary *ta = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: (on && d.scale == Scale::Toggle) ? accent : C(1, 1, 1, 0.7), NSParagraphStyleAttributeName: ps};
        [txt drawInRect:NSMakeRect(b.origin.x, b.origin.y + 7, b.size.width, 16) withAttributes:ta];
        [label drawInRect:NSMakeRect(b.origin.x - 6, b.origin.y + 33, b.size.width + 12, 14) withAttributes:la];
    }
}

- (void)drawCat {
    static NSImage *closedImg, *openImg;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *b = [NSBundle bundleForClass:[MeowCanvas class]];
        closedImg = [[NSImage alloc] initWithContentsOfFile:[b pathForResource:@"cat_closed" ofType:@"png"]];
        openImg = [[NSImage alloc] initWithContentsOfFile:[b pathForResource:@"cat_open" ofType:@"png"]];
    });
    const double m = shownMouth;
    NSRect frame = NSMakeRect(18, 54, 256, 186);

    // glow behind the picture that swells with the meow
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:C(1.0, 0.6, 0.25, 0.08 + 0.30 * m) endingColor:C(1, 0.6, 0.25, 0)];
    [g drawFromCenter:NSMakePoint(NSMidX(frame), NSMidY(frame)) radius:20 toCenter:NSMakePoint(NSMidX(frame), NSMidY(frame)) radius:210 options:0];

    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:frame xRadius:14 yRadius:14];
    [NSGraphicsContext saveGraphicsState];
    [clip addClip];
    [C(0.07, 0.065, 0.08) setFill]; NSRectFill(frame);
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
    // mouth closed → open crossfade; the open picture takes over quickly so frames don't ghost
    double open = std::min(1.0, std::max(0.0, (m - 0.10) / 0.28));
    open = open * open * (3 - 2 * open);
    if (closedImg) [closedImg drawInRect:frame fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:nil];
    if (openImg) [openImg drawInRect:frame fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:open respectFlipped:YES hints:nil];
    [NSGraphicsContext restoreGraphicsState];
    [C(1, 1, 1, 0.14) setStroke]; clip.lineWidth = 1; [clip stroke];

    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter;
    [@"MeowSynth" drawInRect:NSMakeRect(18, 262, 256, 30) withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:26 weight:NSFontWeightHeavy], NSForegroundColorAttributeName: C(1.0, 0.72, 0.38), NSParagraphStyleAttributeName: ps}];
    int v = controller && controller->shared ? controller->shared->voices.load() : 0;
    NSString *sub = v > 0 ? [NSString stringWithFormat:@"%d voice%@ meowing", v, v == 1 ? @"" : @"s"] : @"waiting for notes…";
    [sub drawInRect:NSMakeRect(18, 296, 256, 16) withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11], NSForegroundColorAttributeName: C(1, 1, 1, 0.38), NSParagraphStyleAttributeName: ps}];
}

// MARK: Mouse

- (int)hit:(NSPoint)p {
    for (size_t i = 0; i < controls.size(); i++) if (NSPointInRect(p, controls[i].rect)) return (int)i;
    return -1;
}
- (void)mouseMoved:(NSEvent *)e { int h = [self hit:[self convertPoint:e.locationInWindow fromView:nil]]; if (h != hover) { hover = h; [self setNeedsDisplay:YES]; } }

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    int h = [self hit:p];
    if (h < 0 || !controller) return;
    const Control &c = controls[h];
    const Meow::ParamDef &d = Meow::def(c.id);
    controller->beginEdit(c.id);
    if (e.clickCount == 2 && c.isKnob) {
        [self set:c.id norm:Meow::toNorm(c.id, d.def)];
        controller->endEdit(c.id);
        [self setNeedsDisplay:YES]; return;
    }
    if (!c.isKnob) {
        double n = [self norm:c.id];
        if (d.scale == Meow::Scale::Toggle) [self set:c.id norm:n >= 0.5 ? 0 : 1];
        else {
            int cur = (int)std::round(Meow::toPlain(c.id, n)), cnt = (int)d.max + 1;
            cur = (cur + (e.modifierFlags & NSEventModifierFlagShift ? cnt - 1 : 1)) % cnt;
            [self set:c.id norm:Meow::toNorm(c.id, cur)];
        }
        controller->endEdit(c.id);
        [self setNeedsDisplay:YES]; return;
    }
    dragging = h; lastPoint = p;
    [self setNeedsDisplay:YES];
}
- (void)mouseDragged:(NSEvent *)e {
    if (dragging < 0 || !controller) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    const Control &c = controls[dragging];
    double per = (e.modifierFlags & NSEventModifierFlagShift) ? 0.0008 : 0.006;
    double steps = Meow::def(c.id).steps;
    if (steps > 0 && steps < 40) per = (e.modifierFlags & NSEventModifierFlagShift) ? 0.002 : 1.0 / (steps + 1) / 6;
    [self set:c.id norm:[self norm:c.id] + (lastPoint.y - p.y) * per];
    lastPoint = p;
    [self setNeedsDisplay:YES];
}
- (void)mouseUp:(NSEvent *)e {
    if (dragging >= 0 && controller) controller->endEdit(controls[dragging].id);
    dragging = -1; [self setNeedsDisplay:YES];
}
- (void)scrollWheel:(NSEvent *)e {
    int h = [self hit:[self convertPoint:e.locationInWindow fromView:nil]];
    if (h < 0 || !controller || !controls[h].isKnob) return;
    uint32_t id = controls[h].id;
    controller->beginEdit(id);
    [self set:id norm:[self norm:id] + e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.002 : 0.01)];
    controller->endEdit(id);
    [self setNeedsDisplay:YES];
}
@end

class MeowEditor : public CPluginView {
public:
    explicit MeowEditor(MeowController *c) : CPluginView(nullptr), ctrl(c) {
        ViewRect r(0, 0, 780, 500);
        setRect(r);
    }
    ~MeowEditor() SMTG_OVERRIDE { destroyView(); }

    tresult PLUGIN_API isPlatformTypeSupported(FIDString type) SMTG_OVERRIDE {
        return strcmp(type, kPlatformTypeNSView) == 0 ? kResultTrue : kResultFalse;
    }
    tresult PLUGIN_API attached(void *parent, FIDString type) SMTG_OVERRIDE {
        NSView *host = (__bridge NSView *)parent;
        canvas = [[MeowCanvas alloc] initWithFrame:NSMakeRect(0, 0, rect.getWidth(), rect.getHeight())];
        canvas.controller = ctrl;
        canvas.autoresizingMask = NSViewNotSizable;
        [host addSubview:canvas];
        return CPluginView::attached(parent, type);
    }
    tresult PLUGIN_API removed() SMTG_OVERRIDE { destroyView(); return CPluginView::removed(); }
    tresult PLUGIN_API canResize() SMTG_OVERRIDE { return kResultFalse; }

private:
    void destroyView() {
        if (canvas) { [canvas stop]; [canvas removeFromSuperview]; canvas = nil; }
    }
    MeowController *ctrl;
    MeowCanvas *canvas = nil;
};

IPlugView *PLUGIN_API MeowController::createView(FIDString name) {
    if (name && strcmp(name, ViewType::kEditor) == 0) return new MeowEditor(this);
    return nullptr;
}

// MARK: - Factory & module entry

class MeowFactory : public IPluginFactory3 {
public:
    tresult PLUGIN_API queryInterface(const TUID iid, void **obj) SMTG_OVERRIDE {
        QUERY_INTERFACE(iid, obj, FUnknown::iid, IPluginFactory3)
        QUERY_INTERFACE(iid, obj, IPluginFactory::iid, IPluginFactory3)
        QUERY_INTERFACE(iid, obj, IPluginFactory2::iid, IPluginFactory3)
        QUERY_INTERFACE(iid, obj, IPluginFactory3::iid, IPluginFactory3)
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return ++refs; }
    uint32 PLUGIN_API release() SMTG_OVERRIDE { uint32 r = --refs; if (r == 0) delete this; return r; }

    tresult PLUGIN_API getFactoryInfo(PFactoryInfo *info) SMTG_OVERRIDE {
        *info = PFactoryInfo("MacBand", "https://localhost", "mailto:none@localhost", PFactoryInfo::kUnicode);
        return kResultOk;
    }
    int32 PLUGIN_API countClasses() SMTG_OVERRIDE { return 2; }
    tresult PLUGIN_API getClassInfo(int32 i, PClassInfo *info) SMTG_OVERRIDE {
        PClassInfo2 i2;
        if (getClassInfo2(i, &i2) != kResultOk) return kResultFalse;
        memcpy(info, &i2, sizeof(PClassInfo));
        return kResultOk;
    }
    tresult PLUGIN_API getClassInfo2(int32 i, PClassInfo2 *info) SMTG_OVERRIDE {
        if (i == 0) { *info = PClassInfo2(kProcessorUID.toTUID(), PClassInfo::kManyInstances, kVstAudioEffectClass, "MeowSynth", Vst::kDistributable, PlugType::kInstrumentSynth, "MacBand", "1.0.0", kVstVersionString); return kResultOk; }
        if (i == 1) { *info = PClassInfo2(kControllerUID.toTUID(), PClassInfo::kManyInstances, kVstComponentControllerClass, "MeowSynth Controller", 0, "", "MacBand", "1.0.0", kVstVersionString); return kResultOk; }
        return kResultFalse;
    }
    tresult PLUGIN_API getClassInfoUnicode(int32 i, PClassInfoW *info) SMTG_OVERRIDE {
        PClassInfo2 i2;
        if (getClassInfo2(i, &i2) != kResultOk) return kResultFalse;
        info->fromAscii(i2);
        return kResultOk;
    }
    tresult PLUGIN_API createInstance(FIDString cid, FIDString iid, void **obj) SMTG_OVERRIDE {
        FUnknown *inst = nullptr;
        if (FUnknownPrivate::iidEqual(cid, kProcessorUID.toTUID())) inst = static_cast<IAudioProcessor *>(new MeowProcessor());
        else if (FUnknownPrivate::iidEqual(cid, kControllerUID.toTUID())) inst = static_cast<IEditController *>(new MeowController());
        if (!inst) { *obj = nullptr; return kNoInterface; }
        tresult r = inst->queryInterface(iid, obj);
        inst->release();
        return r;
    }
    tresult PLUGIN_API setHostContext(FUnknown *) SMTG_OVERRIDE { return kResultOk; }
private:
    std::atomic<uint32> refs{1};
};

extern "C" {
__attribute__((visibility("default"))) bool bundleEntry(CFBundleRef) { return true; }
__attribute__((visibility("default"))) bool bundleExit() { return true; }
__attribute__((visibility("default"))) IPluginFactory *GetPluginFactory() { return new MeowFactory(); }
}
