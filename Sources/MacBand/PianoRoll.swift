import SwiftUI
import AppKit
import Combine

final class RollState: ObservableObject {
    @Published var scrollX: CGFloat = 0       // beats
    @Published var topPitch: CGFloat = 76
    @Published var ppb: CGFloat = 90
    @Published var rowH: CGFloat = 16
    static let keysW: CGFloat = 62
    static let rulerH: CGFloat = 22
}

// MARK: - Container (toolbar + roll + lane)

struct PianoRollContainer: View {
    @EnvironmentObject var session: Session
    @StateObject private var state = RollState()

    var body: some View {
        if let loc = session.selectedClipLocation {
            let track = session.project.tracks[loc.track]
            let clip = track.clips[loc.clip]
            VStack(spacing: 0) {
                RollToolbar(state: state, track: track, clip: clip)
                Divider().overlay(Theme.line)
                RollRepresentable(session: session, state: state)
                Divider().overlay(Theme.line)
                LaneHeader()
                LaneRepresentable(session: session, state: state).frame(height: 92)
            }
            .onChange(of: session.selectedClipID) { _ in centerOnNotes() }
            .onAppear { centerOnNotes() }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "pianokeys").font(.system(size: 26)).foregroundStyle(Theme.faint)
                Text("Select a pattern to edit its notes").font(.system(size: 13)).foregroundStyle(Theme.dim)
                Text("Double-click a pattern on the timeline, or double-click an empty spot on a track to make one.")
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
                if let t = session.selectedTrack {
                    Button("New Pattern on “\(t.name)”") {
                        let bpb = session.project.beatsPerBar
                        session.addClip(trackID: t.id, start: (session.transport.beat / bpb).rounded(.down) * bpb)
                    }.buttonStyle(.bordered)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func centerOnNotes() {
        guard let loc = session.selectedClipLocation else { return }
        let notes = session.project.tracks[loc.track].clips[loc.clip].notes
        state.scrollX = 0
        if let lo = notes.map({ $0.pitch }).min(), let hi = notes.map({ $0.pitch }).max() {
            state.topPitch = CGFloat(min(127, (lo + hi) / 2 + 10))
        } else if session.selectedTrack?.instrument.isDrums == true { state.topPitch = 56 }
        else { state.topPitch = 76 }
    }
}

struct LaneHeader: View {
    @EnvironmentObject var session: Session
    var body: some View {
        HStack(spacing: 10) {
            ForEach(AutoLane.allCases) { l in
                Button { session.lane = l } label: {
                    Text(l == .velocity ? "Velocity" : "Volume Automation")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(session.lane == l ? Theme.text : Theme.faint)
                        .padding(.horizontal, 8).frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 4).fill(session.lane == l ? Color.white.opacity(0.09) : .clear))
                }.buttonStyle(.plain)
            }
            Spacer()
            if session.lane == .volume {
                Text("Click to add points · drag to shape · right-click a point to remove")
                    .font(.system(size: 10)).foregroundStyle(Theme.faint)
                Button("Clear") {
                    session.edit { p in
                        if let t = session.selectedTrackIndex, let c = session.clipIndex(track: t, id: session.selectedClipID) { p.tracks[t].clips[c].volume = [] }
                    }
                }.buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.dim)
            }
        }
        .padding(.horizontal, 10).frame(height: 24).background(Theme.panel)
    }
}

struct RollToolbar: View {
    @EnvironmentObject var session: Session
    @ObservedObject var state: RollState
    let track: Track
    let clip: Clip

    static let snaps: [(String, Double)] = [
        ("Bar", -1), ("1/2", 2), ("1/4", 1), ("1/8", 0.5), ("1/16", 0.25), ("1/32", 0.125),
        ("1/8 Triplet", 1.0 / 3), ("1/16 Triplet", 1.0 / 6), ("Off", 0),
    ]
    var snapLabel: String {
        if session.snap == session.project.beatsPerBar { return "Bar" }
        return Self.snaps.first { $0.1 == session.snap }?.0 ?? "Custom"
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 1) {
                ForEach(RollTool.allCases) { t in
                    IconButton(symbol: t.icon, active: session.tool == t, help: "\(t.rawValue) tool", size: 26) { session.tool = t }
                }
            }
            Button { session.slideMode.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
                    Text("Slide").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(session.slideMode ? Color.black.opacity(0.85) : Theme.dim)
                .padding(.horizontal, 9).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(session.slideMode ? Theme.accent : Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("Slide notes glide the sounding note to their pitch. New notes are slide notes while this is on; press S to convert selected notes.")

            Menu {
                ForEach(Self.snaps, id: \.0) { s in
                    Button(s.0) { session.snap = s.1 < 0 ? session.project.beatsPerBar : s.1 }
                }
            } label: {
                HStack(spacing: 4) { Text("Snap").foregroundStyle(Theme.faint); Text(snapLabel).foregroundStyle(Theme.text) }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

            Button("Quantize") { quantize() }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.dim)
                .padding(.horizontal, 8).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))

            Menu {
                Picker("Key", selection: Binding(get: { session.project.keyRoot }, set: { v in session.edit { $0.keyRoot = v } })) {
                    ForEach(0..<12, id: \.self) { Text(Pitch.names[$0]).tag($0) }
                }
                Picker("Scale", selection: Binding(get: { session.project.scale }, set: { v in session.edit { $0.scale = v } })) {
                    ForEach(ScaleKind.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Scale").foregroundStyle(Theme.faint)
                    Text(session.project.scale == .chromatic ? "Off" : "\(Pitch.names[session.project.keyRoot]) \(session.project.scale.rawValue)").foregroundStyle(Theme.text)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

            Spacer(minLength: 6)

            Text(clip.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.color(track.colorIndex)).lineLimit(1)
            Stepper(value: Binding(get: { clip.length / session.project.beatsPerBar }, set: { v in setBars(v) }), in: 1...256, step: 1) {
                Text("\(Int((clip.length / session.project.beatsPerBar).rounded())) bar\(clip.length / session.project.beatsPerBar > 1.5 ? "s" : "")")
                    .font(.system(size: 11)).foregroundStyle(Theme.dim).monospacedDigit()
            }.controlSize(.small).fixedSize()

            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.faint)
                Slider(value: Binding(get: { Double(state.ppb) }, set: { state.ppb = CGFloat($0) }), in: 24...320).frame(width: 90).controlSize(.mini)
                Image(systemName: "plus.magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 10).frame(height: 38).background(Theme.panel)
    }

    private func setBars(_ bars: Double) {
        session.edit { p in
            if let t = session.selectedTrackIndex, let c = session.clipIndex(track: t, id: session.selectedClipID) {
                p.tracks[t].clips[c].length = max(1, bars) * p.beatsPerBar
            }
        }
    }

    private func quantize() {
        let g = session.snap > 0 ? session.snap : 0.25
        let sel = session.selectedNoteIDs
        session.edit { p in
            guard let t = session.selectedTrackIndex, let c = session.clipIndex(track: t, id: session.selectedClipID) else { return }
            for i in p.tracks[t].clips[c].notes.indices where sel.isEmpty || sel.contains(p.tracks[t].clips[c].notes[i].id) {
                var n = p.tracks[t].clips[c].notes[i]
                n.start = max(0, (n.start / g).rounded() * g)
                n.length = max(g, (n.length / g).rounded() * g)
                p.tracks[t].clips[c].notes[i] = n
            }
        }
    }
}

// MARK: - Representables

struct RollRepresentable: NSViewRepresentable {
    let session: Session; let state: RollState
    func makeNSView(context: Context) -> PianoRollView { PianoRollView(session: session, state: state) }
    func updateNSView(_ v: PianoRollView, context: Context) {}
}
struct LaneRepresentable: NSViewRepresentable {
    let session: Session; let state: RollState
    func makeNSView(context: Context) -> LaneView { LaneView(session: session, state: state) }
    func updateNSView(_ v: LaneView, context: Context) {}
}

// MARK: - Piano roll view

final class PianoRollView: NSView {
    let session: Session
    let state: RollState
    private var bag = Set<AnyCancellable>()
    private let playhead = CALayer()

    private enum Mode {
        case none, move, resize, resizeNew(id: UUID), marquee, erase, audition, seek
    }
    private var mode: Mode = .none
    private var origs: [UUID: Note] = [:]
    private var grab: (beat: Double, pitch: Int) = (0, 0)
    private var primary: UUID?
    private var marqueeStart: CGPoint = .zero
    private var marqueeRect: CGRect?
    private var pressedKey: Int?
    private var sounding: Int?
    private var didPush = false
    private var downPoint: CGPoint = .zero
    private var moved = false

    init(session: Session, state: RollState) {
        self.session = session; self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.ns.well.cgColor
        playhead.backgroundColor = NSColor.white.cgColor
        playhead.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        layer?.addSublayer(playhead)
        session.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.needsDisplay = true; self?.updatePlayhead() } }.store(in: &bag)
        state.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.needsDisplay = true; self?.updatePlayhead() } }.store(in: &bag)
        session.transport.$beat.sink { [weak self] _ in self?.updatePlayhead() }.store(in: &bag)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Geometry

    private let keysW = RollState.keysW
    private let rulerH = RollState.rulerH
    private var ppb: CGFloat { state.ppb }
    private var rowH: CGFloat { state.rowH }
    private func x(_ b: Double) -> CGFloat { keysW + (CGFloat(b) - state.scrollX) * ppb }
    private func beat(_ x: CGFloat) -> Double { Double((x - keysW) / ppb + state.scrollX) }
    private func y(_ pitch: Int) -> CGFloat { rulerH + (state.topPitch - CGFloat(pitch)) * rowH }
    private func pitch(at y: CGFloat) -> Int { min(127, max(0, Int(ceil(state.topPitch - (y - rulerH) / rowH)))) }
    private var grid: Double { session.snap }
    private func snapped(_ b: Double) -> Double { grid > 0 ? (b / grid).rounded() * grid : b }
    private func floored(_ b: Double) -> Double { grid > 0 ? (b / grid).rounded(.down) * grid : b }

    private var loc: (track: Int, clip: Int)? { session.selectedClipLocation }
    private var clip: Clip? { loc.map { session.project.tracks[$0.track].clips[$0.clip] } }
    private var track: Track? { loc.map { session.project.tracks[$0.track] } }

    private func updatePlayhead() {
        guard let c = clip else { return }
        let px = x(session.transport.beat - c.start)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playhead.frame = CGRect(x: px - 0.75, y: rulerH, width: 1.5, height: max(0, bounds.height - rulerH))
        playhead.isHidden = px < keysW || px > bounds.width
        CATransaction.commit()
    }
    override func layout() { super.layout(); updatePlayhead() }

    // MARK: Drawing

    private static let keyAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8.5, weight: .medium), .foregroundColor: NSColor(white: 0.25, alpha: 1)]
    private static let rulerAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: Theme.ns.dim]
    private static let noteAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor(white: 0, alpha: 0.65)]

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let c = clip, let t = track else { return }
        let w = bounds.width, h = bounds.height
        let p = session.project
        let col = Palette.nsColor(t.colorIndex)
        let scale = p.scale.intervals

        // Rows
        ctx.saveGState()
        ctx.clip(to: CGRect(x: keysW, y: rulerH, width: w - keysW, height: h - rulerH))
        let topP = min(127, Int(ceil(state.topPitch)) + 1)
        let botP = max(0, Int(floor(state.topPitch - (h - rulerH) / rowH)) - 1)
        if topP >= botP {
            for pi in botP...topP {
                let ry = y(pi)
                let black = Pitch.isBlack(pi)
                let rel = ((pi - p.keyRoot) % 12 + 12) % 12
                let inScale = scale.contains(rel)
                var fill = black ? NSColor(white: 0, alpha: 0.18) : NSColor(white: 1, alpha: 0.018)
                if p.scale != .chromatic {
                    if inScale { fill = rel == 0 ? Theme.accentNS.withAlphaComponent(0.13) : Theme.accentNS.withAlphaComponent(0.05) }
                    else { fill = NSColor(white: 0, alpha: 0.30) }
                }
                ctx.setFillColor(fill.cgColor)
                ctx.fill(CGRect(x: keysW, y: ry, width: w, height: rowH))
                ctx.setFillColor(NSColor(white: 1, alpha: pi % 12 == 0 ? 0.10 : 0.03).cgColor)
                ctx.fill(CGRect(x: keysW, y: ry + rowH - 1, width: w, height: 1))
            }
        }

        drawBeatGrid(ctx, c, p, y0: rulerH, y1: h)

        // Out-of-clip shading
        let endX = x(c.length)
        if endX < w {
            ctx.setFillColor(NSColor(white: 0, alpha: 0.35).cgColor)
            ctx.fill(CGRect(x: max(keysW, endX), y: rulerH, width: w, height: h))
            ctx.setFillColor(NSColor(white: 1, alpha: 0.25).cgColor)
            ctx.fill(CGRect(x: endX, y: rulerH, width: 1, height: h))
        }

        // Slide connectors then notes
        let notes = c.notes
        let normals = notes.filter { !$0.isSlide }
        for n in notes where n.isSlide {
            guard let src = normals.last(where: { $0.start <= n.start + 1e-6 && $0.end > n.start + 1e-6 }) else { continue }
            let from = CGPoint(x: x(n.start), y: y(src.pitch) + rowH / 2)
            let to = CGPoint(x: x(n.end), y: y(n.pitch) + rowH / 2)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(2)
            ctx.setLineCap(.round)
            ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()
            // arrow head
            let ang = atan2(to.y - from.y, to.x - from.x)
            let a1 = CGPoint(x: to.x - 7 * cos(ang - 0.45), y: to.y - 7 * sin(ang - 0.45))
            let a2 = CGPoint(x: to.x - 7 * cos(ang + 0.45), y: to.y - 7 * sin(ang + 0.45))
            ctx.move(to: a1); ctx.addLine(to: to); ctx.addLine(to: a2); ctx.strokePath()
        }
        for n in notes { drawNote(ctx, n, col: col, selected: session.selectedNoteIDs.contains(n.id)) }

        if let r = marqueeRect {
            ctx.setFillColor(Theme.accentNS.withAlphaComponent(0.12).cgColor); ctx.fill(r)
            ctx.setStrokeColor(Theme.accentNS.cgColor); ctx.setLineWidth(1); ctx.stroke(r)
        }
        ctx.restoreGState()

        drawKeys(ctx, p)
        drawRuler(ctx, c, p)
    }

    private func drawBeatGrid(_ ctx: CGContext, _ c: Clip, _ p: Project, y0: CGFloat, y1: CGFloat) {
        let bpb = p.beatsPerBar
        let first = max(0, Int(floor(Double(state.scrollX))) - 1)
        let last = Int(ceil(Double(state.scrollX + (bounds.width - keysW) / ppb))) + 1
        let sub: Double = {
            var g = grid > 0 ? grid : 0.25
            while Double(ppb) * g < 9 { g *= 2 }
            return g
        }()
        var b = (Double(first) / sub).rounded(.down) * sub
        while b <= Double(last) {
            let bx = x(b)
            let isBeat = abs(b - b.rounded()) < 1e-6
            let isBar = isBeat && abs((b + c.start).truncatingRemainder(dividingBy: bpb)) < 1e-6
            let a: CGFloat = isBar ? 0.20 : (isBeat ? 0.09 : 0.035)
            ctx.setFillColor(NSColor(white: 1, alpha: a).cgColor)
            ctx.fill(CGRect(x: bx, y: y0, width: 1, height: y1 - y0))
            b += sub
        }
    }

    private func drawNote(_ ctx: CGContext, _ n: Note, col: NSColor, selected: Bool) {
        let rx = x(n.start), rw = max(3, CGFloat(n.length) * ppb - 1)
        if rx + rw < keysW || rx > bounds.width { return }
        let ry = y(n.pitch)
        if ry + rowH < rulerH || ry > bounds.height { return }
        let r = CGRect(x: rx, y: ry + 1, width: rw, height: rowH - 2)
        let path = CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil)
        let vel = CGFloat(n.velocity) / 127
        if n.isSlide {
            ctx.addPath(path)
            ctx.setFillColor(col.withAlphaComponent(0.30).cgColor); ctx.fillPath()
            ctx.saveGState(); ctx.addPath(path); ctx.clip()
            ctx.setStrokeColor(col.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(1)
            var sx = r.minX - r.height
            while sx < r.maxX { ctx.move(to: CGPoint(x: sx, y: r.maxY)); ctx.addLine(to: CGPoint(x: sx + r.height, y: r.minY)); sx += 5 }
            ctx.strokePath(); ctx.restoreGState()
            ctx.addPath(path)
            ctx.setStrokeColor((selected ? Theme.accentNS : col).cgColor)
            ctx.setLineWidth(selected ? 2 : 1.5); ctx.strokePath()
        } else {
            ctx.addPath(path)
            ctx.setFillColor(col.blended(withFraction: selected ? 0.35 : 0, of: .white)!.withAlphaComponent(0.45 + 0.55 * vel).cgColor)
            ctx.fillPath()
            if selected {
                ctx.addPath(path); ctx.setStrokeColor(Theme.accentNS.cgColor); ctx.setLineWidth(2); ctx.strokePath()
            }
            if rw > 28, rowH >= 13 {
                (Pitch.name(n.pitch) as NSString).draw(at: CGPoint(x: r.minX + 4, y: r.minY + (r.height - 11) / 2), withAttributes: Self.noteAttrs)
            }
        }
    }

    private func drawKeys(_ ctx: CGContext, _ p: Project) {
        let h = bounds.height
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: rulerH, width: keysW, height: h - rulerH))
        ctx.setFillColor(NSColor(white: 0.17, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: rulerH, width: keysW, height: h))
        let topP = min(127, Int(ceil(state.topPitch)) + 1)
        let botP = max(0, Int(floor(state.topPitch - (h - rulerH) / rowH)) - 1)
        if topP >= botP {
            for pi in botP...topP {
                let ry = y(pi)
                let black = Pitch.isBlack(pi)
                let down = pressedKey == pi
                if black {
                    ctx.setFillColor((down ? Theme.accentNS : NSColor(white: 0.10, alpha: 1)).cgColor)
                    ctx.fill(CGRect(x: 0, y: ry, width: keysW * 0.62, height: rowH))
                    ctx.setFillColor((down ? Theme.accentNS : NSColor(white: 0.84, alpha: 1)).cgColor)
                    ctx.fill(CGRect(x: keysW * 0.62, y: ry, width: keysW * 0.38, height: rowH))
                } else {
                    ctx.setFillColor((down ? Theme.accentNS : NSColor(white: 0.84, alpha: 1)).cgColor)
                    ctx.fill(CGRect(x: 0, y: ry, width: keysW, height: rowH))
                    if pi % 12 == 0 || rowH >= 18 {
                        (Pitch.name(pi) as NSString).draw(at: CGPoint(x: keysW - 22, y: ry + (rowH - 10) / 2), withAttributes: Self.keyAttrs)
                    }
                }
                ctx.setFillColor(NSColor(white: 0, alpha: 0.28).cgColor)
                ctx.fill(CGRect(x: 0, y: ry + rowH - 1, width: keysW, height: 1))
            }
        }
        ctx.restoreGState()
        ctx.setFillColor(Theme.ns.lineStrong.cgColor)
        ctx.fill(CGRect(x: keysW - 1, y: rulerH, width: 1, height: h))
    }

    private func drawRuler(_ ctx: CGContext, _ c: Clip, _ p: Project) {
        let w = bounds.width
        ctx.setFillColor(Theme.ns.panel.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: rulerH))
        ctx.saveGState()
        ctx.clip(to: CGRect(x: keysW, y: 0, width: w - keysW, height: rulerH))
        let bpb = p.beatsPerBar
        let first = max(0, Int(floor(Double(state.scrollX))) - 1)
        let last = Int(ceil(Double(state.scrollX + (w - keysW) / ppb))) + 1
        for b in first...max(first, last) {
            let bx = x(Double(b))
            let abs = Double(b) + c.start
            let isBar = Swift.abs(abs.truncatingRemainder(dividingBy: bpb)) < 1e-6
            ctx.setFillColor(NSColor(white: 1, alpha: isBar ? 0.3 : 0.12).cgColor)
            ctx.fill(CGRect(x: bx, y: isBar ? 4 : rulerH - 6, width: 1, height: isBar ? rulerH - 4 : 6))
            if isBar { ("\(Int(abs / bpb) + 1)" as NSString).draw(at: CGPoint(x: bx + 4, y: 4), withAttributes: Self.rulerAttrs) }
        }
        ctx.restoreGState()
        ctx.setFillColor(Theme.ns.line.cgColor)
        ctx.fill(CGRect(x: 0, y: rulerH - 1, width: w, height: 1))
    }

    // MARK: Hit testing

    private enum Zone { case body, end }
    private func noteHit(_ pt: CGPoint) -> (Note, Zone)? {
        guard let c = clip else { return nil }
        for n in c.notes.reversed() {
            let r = CGRect(x: x(n.start), y: y(n.pitch), width: max(3, CGFloat(n.length) * ppb), height: rowH)
            if r.contains(pt) { return (n, pt.x > r.maxX - min(8, r.width / 3) ? .end : .body) }
        }
        return nil
    }

    // MARK: Editing helpers

    private func mutateNotes(_ body: (inout [Note]) -> Void) {
        guard let l = loc else { return }
        session.modify { p in
            body(&p.tracks[l.track].clips[l.clip].notes)
            let bar = p.beatsPerBar
            p.tracks[l.track].clips[l.clip].fitLengthToNotes(minBeats: bar, quantum: bar)
        }
    }

    private func beginChange() { if !didPush { session.pushUndo(); didPush = true } }

    private func startSound(_ pitch: Int) {
        stopSound()
        guard let t = session.selectedTrackID else { return }
        session.engine.noteOn(trackID: t, pitch: pitch, velocity: session.lastVelocity)
        sounding = pitch
    }
    private func stopSound() {
        if let s = sounding, let t = session.selectedTrackID { session.engine.noteOff(trackID: t, pitch: s) }
        sounding = nil
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)
        downPoint = pt; didPush = false; moved = false
        guard let c = clip else { return }

        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }

        if pt.y < rulerH {
            if pt.x >= keysW { mode = .seek; session.seek(to: c.start + max(0, floored(beat(pt.x)))) }
            return
        }
        if pt.x < keysW {
            let p = pitch(at: pt.y); pressedKey = p; mode = .audition; startSound(p); needsDisplay = true; return
        }

        var effectiveTool = session.tool
        if event.modifierFlags.contains(.command) { effectiveTool = .select }

        if effectiveTool == .erase {
            mode = .erase
            eraseAt(pt); return
        }

        if let (n, zone) = noteHit(pt) {
            if event.modifierFlags.contains(.shift) {
                if session.selectedNoteIDs.contains(n.id) { session.selectedNoteIDs.remove(n.id); mode = .none; return }
                session.selectedNoteIDs.insert(n.id)
            } else if !session.selectedNoteIDs.contains(n.id) {
                session.selectedNoteIDs = [n.id]
            }
            if event.modifierFlags.contains(.option) && zone == .body {
                // duplicate selection, drag the copies
                beginChange()
                var copies: [Note] = []
                mutateNotes { notes in
                    for s in notes where self.session.selectedNoteIDs.contains(s.id) { var cp = s; cp.id = UUID(); copies.append(cp) }
                    notes.append(contentsOf: copies)
                }
                session.selectedNoteIDs = Set(copies.map { $0.id })
                if let m = copies.first(where: { $0.pitch == n.pitch && $0.start == n.start }) { primary = m.id } else { primary = copies.first?.id }
            } else { primary = n.id }
            origs = [:]
            for s in clip?.notes ?? [] where session.selectedNoteIDs.contains(s.id) { origs[s.id] = s }
            grab = (beat(pt.x), pitch(at: pt.y))
            mode = zone == .end ? .resize : .move
            if zone == .body { startSound(n.pitch) }
            return
        }

        // empty space
        if effectiveTool == .select || event.modifierFlags.contains(.shift) && effectiveTool != .draw {
            if !event.modifierFlags.contains(.shift) { session.selectedNoteIDs = [] }
            mode = .marquee; marqueeStart = pt; marqueeRect = CGRect(origin: pt, size: .zero)
            return
        }
        // draw a new note
        let start = max(0, floored(beat(pt.x)))
        let g = grid > 0 ? grid : 0.0625
        var note = Note(pitch: pitch(at: pt.y), start: start, length: max(g, session.lastNoteLength), velocity: session.lastVelocity, isSlide: session.slideMode)
        if note.isSlide { note.length = max(note.length, 0.5) }
        beginChange()
        mutateNotes { $0.append(note) }
        session.selectedNoteIDs = [note.id]
        mode = .resizeNew(id: note.id)
        startSound(note.pitch)
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if abs(pt.x - downPoint.x) > 2 || abs(pt.y - downPoint.y) > 2 { moved = true }
        guard let c = clip else { return }
        switch mode {
        case .none: break
        case .seek: session.seek(to: c.start + max(0, floored(beat(pt.x))))
        case .audition:
            let p = pitch(at: pt.y)
            if p != pressedKey { pressedKey = p; startSound(p); needsDisplay = true }
        case .erase: eraseAt(pt)
        case .marquee:
            let r = CGRect(x: min(marqueeStart.x, pt.x), y: min(marqueeStart.y, pt.y), width: abs(pt.x - marqueeStart.x), height: abs(pt.y - marqueeStart.y))
            marqueeRect = r
            var sel = event.modifierFlags.contains(.shift) ? session.selectedNoteIDs : []
            for n in c.notes {
                let nr = CGRect(x: x(n.start), y: y(n.pitch), width: CGFloat(n.length) * ppb, height: rowH)
                if nr.intersects(r) { sel.insert(n.id) }
            }
            session.selectedNoteIDs = sel
            needsDisplay = true
        case .move:
            guard moved, let pid = primary, let po = origs[pid] else { return }
            beginChange()
            let newStart = max(0, event.modifierFlags.contains(.command) ? po.start + beat(pt.x) - grab.beat : snapped(po.start + beat(pt.x) - grab.beat))
            let dB = newStart - po.start
            let dP = pitch(at: pt.y) - grab.pitch
            let ids = origs
            mutateNotes { notes in
                for i in notes.indices {
                    guard let o = ids[notes[i].id] else { continue }
                    notes[i].start = max(0, o.start + dB)
                    notes[i].pitch = min(127, max(0, o.pitch + dP))
                }
            }
            let np = min(127, max(0, po.pitch + dP))
            if np != sounding { startSound(np) }
        case .resize:
            guard moved, let pid = primary, let po = origs[pid] else { return }
            beginChange()
            let minLen = grid > 0 ? grid : 0.0625
            let newEnd = max(po.start + minLen, snapped(beat(pt.x)))
            let dL = newEnd - po.end
            let ids = origs
            mutateNotes { notes in
                for i in notes.indices {
                    guard let o = ids[notes[i].id] else { continue }
                    notes[i].length = max(minLen, o.length + dL)
                }
            }
            session.lastNoteLength = max(minLen, po.length + dL)
        case .resizeNew(let id):
            guard moved, let n = c.notes.first(where: { $0.id == id }) else { return }
            let minLen = grid > 0 ? grid : 0.0625
            let newEnd = max(n.start + minLen, snapped(beat(pt.x)))
            mutateNotes { notes in if let i = notes.firstIndex(where: { $0.id == id }) { notes[i].length = newEnd - n.start } }
            session.lastNoteLength = newEnd - n.start
        }
    }

    override func mouseUp(with event: NSEvent) {
        stopSound()
        pressedKey = nil
        marqueeRect = nil
        mode = .none
        origs = [:]
        needsDisplay = true
    }

    private func eraseAt(_ pt: CGPoint) {
        guard let (n, _) = noteHit(pt) else { return }
        beginChange()
        mutateNotes { $0.removeAll { $0.id == n.id } }
        session.selectedNoteIDs.remove(n.id)
    }

    override func rightMouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let (n, _) = noteHit(pt) {
            session.pushUndo()
            let ids = session.selectedNoteIDs.contains(n.id) ? session.selectedNoteIDs : [n.id]
            mutateNotes { $0.removeAll { ids.contains($0.id) } }
            session.selectedNoteIDs.subtract(ids)
        }
    }

    // MARK: Scroll & zoom

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            state.ppb = min(400, max(20, state.ppb * (1 + event.scrollingDeltaY * 0.01))); return
        }
        if event.modifierFlags.contains(.option) {
            state.rowH = min(32, max(9, state.rowH * (1 + event.scrollingDeltaY * 0.01))); return
        }
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
        state.scrollX = max(0, state.scrollX - event.scrollingDeltaX * k / ppb)
        state.topPitch = min(135, max(CGFloat(8), state.topPitch + event.scrollingDeltaY * k / rowH))
    }

    override func magnify(with event: NSEvent) {
        state.ppb = min(400, max(20, state.ppb * (1 + event.magnification)))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard clip != nil else { return }
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let ch = event.charactersIgnoringModifiers ?? ""
        let sel = session.selectedNoteIDs
        let g = grid > 0 ? grid : 0.25
        switch (event.keyCode, ch) {
        case (51, _), (117, _):
            guard !sel.isEmpty else { return }
            session.pushUndo(); mutateNotes { $0.removeAll { sel.contains($0.id) } }; session.selectedNoteIDs = []
        case (_, "a") where cmd: session.selectedNoteIDs = Set(clip?.notes.map { $0.id } ?? [])
        case (_, "c") where cmd: copySelection()
        case (_, "x") where cmd: copySelection(); session.pushUndo(); mutateNotes { $0.removeAll { sel.contains($0.id) } }; session.selectedNoteIDs = []
        case (_, "v") where cmd: paste()
        case (_, "d") where cmd:
            guard !sel.isEmpty, let c = clip else { return }
            let src = c.notes.filter { sel.contains($0.id) }
            let span = (src.map { $0.end }.max() ?? 0) - (src.map { $0.start }.min() ?? 0)
            let shiftBy = (span / g).rounded(.up) * g
            session.pushUndo()
            var copies: [Note] = []
            for var n in src { n.id = UUID(); n.start += shiftBy; copies.append(n) }
            mutateNotes { $0.append(contentsOf: copies) }
            session.selectedNoteIDs = Set(copies.map { $0.id })
        case (123, _), (124, _):
            guard !sel.isEmpty else { return }
            let d = (event.keyCode == 124 ? 1.0 : -1.0) * (shift ? session.project.beatsPerBar : g)
            session.pushUndo(); mutateNotes { notes in for i in notes.indices where sel.contains(notes[i].id) { notes[i].start = max(0, notes[i].start + d) } }
        case (125, _), (126, _):
            guard !sel.isEmpty else { return }
            let d = (event.keyCode == 126 ? 1 : -1) * (shift ? 12 : 1)
            session.pushUndo(); mutateNotes { notes in for i in notes.indices where sel.contains(notes[i].id) { notes[i].pitch = min(127, max(0, notes[i].pitch + d)) } }
        case (_, "s") where !cmd:
            guard !sel.isEmpty else { session.slideMode.toggle(); return }
            session.pushUndo(); mutateNotes { notes in for i in notes.indices where sel.contains(notes[i].id) { notes[i].isSlide.toggle() } }
        case (_, "q") where !cmd:
            session.pushUndo()
            mutateNotes { notes in
                for i in notes.indices where sel.isEmpty || sel.contains(notes[i].id) {
                    notes[i].start = max(0, (notes[i].start / g).rounded() * g)
                    notes[i].length = max(g, (notes[i].length / g).rounded() * g)
                }
            }
        case (_, "p") where !cmd: session.tool = .draw
        case (_, "v") where !cmd: session.tool = .select
        case (_, "e") where !cmd: session.tool = .erase
        case (53, _): session.selectedNoteIDs = []
        default: super.keyDown(with: event)
        }
    }

    private func copySelection() {
        guard let c = clip else { return }
        let src = c.notes.filter { session.selectedNoteIDs.contains($0.id) }
        guard !src.isEmpty else { return }
        let base = src.map { $0.start }.min() ?? 0
        session.noteClipboard = src.map { var n = $0; n.start -= base; return n }
    }

    private func paste() {
        guard !session.noteClipboard.isEmpty, let c = clip else { return }
        let ph = session.transport.beat - c.start
        let at = max(0, grid > 0 ? (ph / grid).rounded() * grid : ph)
        var copies: [Note] = []
        for var n in session.noteClipboard { n.id = UUID(); n.start += at; copies.append(n) }
        session.pushUndo()
        mutateNotes { $0.append(contentsOf: copies) }
        session.selectedNoteIDs = Set(copies.map { $0.id })
    }
}

// MARK: - Lane (velocity / volume automation)

final class LaneView: NSView {
    let session: Session
    let state: RollState
    private var bag = Set<AnyCancellable>()
    private let playhead = CALayer()
    private var dragPoint: UUID?
    private var didPush = false

    init(session: Session, state: RollState) {
        self.session = session; self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.10, green: 0.105, blue: 0.118, alpha: 1).cgColor
        playhead.backgroundColor = NSColor.white.cgColor
        playhead.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        layer?.addSublayer(playhead)
        session.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.needsDisplay = true } }.store(in: &bag)
        state.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.needsDisplay = true; self?.updatePlayhead() } }.store(in: &bag)
        session.transport.$beat.sink { [weak self] _ in self?.updatePlayhead() }.store(in: &bag)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private let keysW = RollState.keysW
    private let padT: CGFloat = 8, padB: CGFloat = 8
    private func x(_ b: Double) -> CGFloat { keysW + (CGFloat(b) - state.scrollX) * state.ppb }
    private func beat(_ x: CGFloat) -> Double { Double((x - keysW) / state.ppb + state.scrollX) }
    private func yVal(_ v: Double) -> CGFloat { bounds.height - padB - CGFloat(v) * (bounds.height - padT - padB) }
    private func val(atY y: CGFloat) -> Double { min(1, max(0, Double((bounds.height - padB - y) / (bounds.height - padT - padB)))) }
    private var loc: (track: Int, clip: Int)? { session.selectedClipLocation }
    private var clip: Clip? { loc.map { session.project.tracks[$0.track].clips[$0.clip] } }

    private func updatePlayhead() {
        guard let c = clip else { return }
        let px = x(session.transport.beat - c.start)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playhead.frame = CGRect(x: px - 0.75, y: 0, width: 1.5, height: bounds.height)
        playhead.isHidden = px < keysW || px > bounds.width
        CATransaction.commit()
    }
    override func layout() { super.layout(); updatePlayhead() }

    private static let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: Theme.ns.faint]

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let c = clip,
              let ti = session.selectedTrackIndex else { return }
        let w = bounds.width, h = bounds.height
        let col = Palette.nsColor(session.project.tracks[ti].colorIndex)
        // label column
        ctx.setFillColor(Theme.ns.panel.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: keysW, height: h))
        ctx.setFillColor(Theme.ns.lineStrong.cgColor); ctx.fill(CGRect(x: keysW - 1, y: 0, width: 1, height: h))

        ctx.saveGState()
        ctx.clip(to: CGRect(x: keysW, y: 0, width: w - keysW, height: h))
        // beat lines
        let bpb = session.project.beatsPerBar
        let first = max(0, Int(floor(Double(state.scrollX))) - 1)
        let last = Int(ceil(Double(state.scrollX + (w - keysW) / state.ppb))) + 1
        for b in first...max(first, last) {
            let bar = abs((Double(b) + c.start).truncatingRemainder(dividingBy: bpb)) < 1e-6
            ctx.setFillColor(NSColor(white: 1, alpha: bar ? 0.14 : 0.05).cgColor)
            ctx.fill(CGRect(x: x(Double(b)), y: 0, width: 1, height: h))
        }
        let endX = x(c.length)
        if endX < w { ctx.setFillColor(NSColor(white: 0, alpha: 0.3).cgColor); ctx.fill(CGRect(x: max(keysW, endX), y: 0, width: w, height: h)) }

        if session.lane == .velocity {
            for g in [0.0, 0.5, 1.0] {
                ctx.setFillColor(NSColor(white: 1, alpha: 0.05).cgColor)
                ctx.fill(CGRect(x: keysW, y: yVal(g), width: w, height: 1))
            }
            for n in c.notes {
                let vx = x(n.start)
                if vx < keysW - 6 || vx > w { continue }
                let top = yVal(Double(n.velocity) / 127)
                let sel = session.selectedNoteIDs.contains(n.id)
                ctx.setFillColor((sel ? NSColor.white : col).withAlphaComponent(sel ? 0.95 : 0.85).cgColor)
                ctx.fill(CGRect(x: vx, y: top, width: 3, height: yVal(0) - top))
                ctx.fillEllipse(in: CGRect(x: vx - 2.5, y: top - 3, width: 8, height: 8))
            }
        } else {
            // 0 dB line
            let uy = yVal(Automation.unity)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.18).cgColor); ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 4]); ctx.move(to: CGPoint(x: keysW, y: uy)); ctx.addLine(to: CGPoint(x: w, y: uy)); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            let pts = c.volume.sorted { $0.beat < $1.beat }
            if pts.isEmpty {
                ("No automation — volume follows the track fader" as NSString).draw(at: CGPoint(x: keysW + 12, y: 8), withAttributes: Self.attrs)
            } else {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: keysW - 1, y: yVal(pts[0].value)))
                path.addLine(to: CGPoint(x: x(pts[0].beat), y: yVal(pts[0].value)))
                for p in pts.dropFirst() { path.addLine(to: CGPoint(x: x(p.beat), y: yVal(p.value))) }
                path.addLine(to: CGPoint(x: max(x(c.length), x(pts.last!.beat)), y: yVal(pts.last!.value)))
                let fill = CGMutablePath(); fill.addPath(path)
                fill.addLine(to: CGPoint(x: max(x(c.length), x(pts.last!.beat)), y: h)); fill.addLine(to: CGPoint(x: keysW - 1, y: h)); fill.closeSubpath()
                ctx.addPath(fill); ctx.setFillColor(Theme.accentNS.withAlphaComponent(0.12).cgColor); ctx.fillPath()
                ctx.addPath(path); ctx.setStrokeColor(Theme.accentNS.cgColor); ctx.setLineWidth(1.75); ctx.setLineJoin(.round); ctx.strokePath()
                for p in pts {
                    let cp = CGPoint(x: x(p.beat), y: yVal(p.value))
                    ctx.setFillColor(Theme.ns.window.cgColor); ctx.fillEllipse(in: CGRect(x: cp.x - 4.5, y: cp.y - 4.5, width: 9, height: 9))
                    ctx.setStrokeColor(Theme.accentNS.cgColor); ctx.setLineWidth(1.75); ctx.strokeEllipse(in: CGRect(x: cp.x - 4.5, y: cp.y - 4.5, width: 9, height: 9))
                }
            }
        }
        ctx.restoreGState()

        // axis labels
        let labels: [(String, Double)] = session.lane == .velocity ? [("127", 1), ("64", 0.5), ("0", 0)] : [("+5 dB", 1), ("0 dB", Automation.unity), ("−∞", 0)]
        for (t, v) in labels { (t as NSString).draw(at: CGPoint(x: 8, y: min(h - 14, max(2, yVal(v) - 6))), withAttributes: Self.attrs) }
    }

    // MARK: Mouse

    private func pointHit(_ pt: CGPoint) -> AutoPoint? {
        clip?.volume.first { hypot(x($0.beat) - pt.x, yVal($0.value) - pt.y) < 9 }
    }

    private func setVelocity(at pt: CGPoint) {
        guard let c = clip, let l = loc else { return }
        let v = min(127, max(1, Int((val(atY: pt.y) * 127).rounded())))
        guard let n = c.notes.min(by: { abs(x($0.start) - pt.x) < abs(x($1.start) - pt.x) }), abs(x(n.start) - pt.x) < 10 else { return }
        if !didPush { session.pushUndo(); didPush = true }
        let sel = session.selectedNoteIDs
        let multi = sel.contains(n.id) && sel.count > 1
        let delta = v - n.velocity
        session.modify { p in
            for i in p.tracks[l.track].clips[l.clip].notes.indices {
                let id = p.tracks[l.track].clips[l.clip].notes[i].id
                if id == n.id { p.tracks[l.track].clips[l.clip].notes[i].velocity = v }
                else if multi && sel.contains(id) { p.tracks[l.track].clips[l.clip].notes[i].velocity = min(127, max(1, p.tracks[l.track].clips[l.clip].notes[i].velocity + delta)) }
            }
        }
        session.lastVelocity = v
        session.selectedNoteIDs = multi ? sel : [n.id]
    }

    private func grid(_ b: Double) -> Double {
        let g = session.snap > 0 ? session.snap : 0.25
        return max(0, (b / g).rounded() * g)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)
        didPush = false
        guard pt.x >= keysW, let l = loc else { return }
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        if session.lane == .velocity { setVelocity(at: pt); return }
        if let hit = pointHit(pt) {
            if event.clickCount == 2 { session.edit { $0.tracks[l.track].clips[l.clip].volume.removeAll { $0.id == hit.id } }; return }
            dragPoint = hit.id
        } else {
            session.pushUndo(); didPush = true
            var v = val(atY: pt.y)
            if abs(v - Automation.unity) < 0.025 { v = Automation.unity }
            let p = AutoPoint(beat: grid(beat(pt.x)), value: v)
            session.modify { $0.tracks[l.track].clips[l.clip].volume.append(p); $0.tracks[l.track].clips[l.clip].volume.sort { $0.beat < $1.beat } }
            dragPoint = p.id
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard let l = loc else { return }
        if session.lane == .velocity { setVelocity(at: pt); return }
        guard let id = dragPoint else { return }
        if !didPush { session.pushUndo(); didPush = true }
        var v = val(atY: pt.y)
        if abs(v - Automation.unity) < 0.025 { v = Automation.unity }
        let b = event.modifierFlags.contains(.command) ? max(0, beat(pt.x)) : grid(beat(pt.x))
        session.modify { p in
            if let i = p.tracks[l.track].clips[l.clip].volume.firstIndex(where: { $0.id == id }) {
                p.tracks[l.track].clips[l.clip].volume[i].beat = b
                p.tracks[l.track].clips[l.clip].volume[i].value = v
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let l = loc, dragPoint != nil { session.modify { $0.tracks[l.track].clips[l.clip].volume.sort { $0.beat < $1.beat } } }
        dragPoint = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard session.lane == .volume, let l = loc, let hit = pointHit(pt) else { return }
        session.edit { $0.tracks[l.track].clips[l.clip].volume.removeAll { $0.id == hit.id } }
    }

    override func scrollWheel(with event: NSEvent) {
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
        state.scrollX = max(0, state.scrollX - event.scrollingDeltaX * k / state.ppb)
    }
}
