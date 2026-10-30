import SwiftUI
import AppKit
import Combine

final class ArrangementState: ObservableObject {
    @Published var scrollX: CGFloat = 0      // beats
    @Published var scrollY: CGFloat = 0      // points
    @Published var ppb: CGFloat = 26         // points per beat
    @Published var showTempo = true

    static let loopH: CGFloat = 14
    static let rulerH: CGFloat = 38
    static let tempoH: CGFloat = 52
    static let minRowH: CGFloat = 44, maxRowH: CGFloat = 220, defaultRowH: CGFloat = 70
    /// Height of every track, adjustable with the slider above the track list or ⌘-scroll; remembered between launches.
    @Published var rowH: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "trackHeight")
        return v > 0 ? min(ArrangementState.maxRowH, max(ArrangementState.minRowH, CGFloat(v))) : ArrangementState.defaultRowH
    }() { didSet { UserDefaults.standard.set(Double(rowH), forKey: "trackHeight") } }
    var headerH: CGFloat { Self.rulerH + (showTempo ? Self.tempoH : 0) }
}

struct ArrangementView: View {
    @EnvironmentObject var session: Session
    @StateObject private var state = ArrangementState()

    var body: some View {
        HStack(spacing: 0) {
            TrackHeaderColumn(state: state).frame(width: 214)
            Divider().overlay(Theme.line)
            TimelineRepresentable(session: session, state: state)
        }
        .background(Theme.well)
    }
}

// MARK: - Track headers

struct TrackHeaderColumn: View {
    @EnvironmentObject var session: Session
    @ObservedObject var state: ArrangementState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SectionLabel(text: "Tracks").lineLimit(1).fixedSize()
                Spacer(minLength: 2)
                Image(systemName: "arrow.up.and.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint)
                    .frame(width: 14, height: 20).contentShape(Rectangle())
                    .onTapGesture(count: 2) { state.rowH = ArrangementState.defaultRowH }
                    .help("Double-click to reset the track height")
                Slider(value: Binding(get: { Double(state.rowH) }, set: { state.rowH = CGFloat($0) }), in: Double(ArrangementState.minRowH)...Double(ArrangementState.maxRowH))
                    .controlSize(.mini).frame(width: 46)
                    .help("Track height (also ⌘-scroll over the tracks)")
                IconButton(symbol: "waveform.path.ecg", active: state.showTempo, help: "Show tempo lane", size: 24) { state.showTempo.toggle() }
                AddTrackMenu()
            }
            .padding(.horizontal, 10)
            .frame(height: state.headerH)
            .background(Theme.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            GeometryReader { geo in
                VStack(spacing: 0) {
                    ForEach(session.project.tracks) { t in
                        TrackHeaderRow(track: t, selected: t.id == session.selectedTrackID, height: state.rowH)
                    }
                    Color.clear.frame(height: 200)
                }
                .frame(width: geo.size.width, alignment: .top)
                .offset(y: -state.scrollY)
                .frame(height: geo.size.height, alignment: .top)
                .clipped()
            }
        }
        .background(Theme.panel)
    }
}

struct AddTrackMenu: View {
    @EnvironmentObject var session: Session
    var body: some View {
        Menu {
            Button("Audio Track (record or import vocals)") { session.addAudioTrack() }
            Button("Import Audio…") { session.importAudio() }
            Divider()
            InstrumentMenuItems(allowDrums: true) { session.addTrack(instrument: $0) }
        } label: {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Add track")
    }
}

struct TrackHeaderRow: View {
    @EnvironmentObject var session: Session
    let track: Track
    let selected: Bool
    let height: CGFloat
    @State private var renaming = false
    @State private var nameText = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Palette.color(track.colorIndex)).frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                if renaming {
                    TextField("", text: $nameText).textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                        .focused($focused)
                        .onSubmit { commit() }
                        .onExitCommand { renaming = false }
                } else {
                    Text(track.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        .onTapGesture(count: 2) { nameText = track.name; renaming = true; focused = true }
                }
                Text(track.kind == .audio ? "Audio · \(track.audioClips.count) clip\(track.audioClips.count == 1 ? "" : "s")" : track.instrument.displayName).font(.system(size: 10.5)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            .padding(.leading, 10)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Button { session.edit { p in if let i = p.tracks.firstIndex(where: { $0.id == track.id }) { p.tracks[i].mute.toggle() } } } label: {
                    SmallTag(text: "M", active: track.mute, color: .yellow)
                }.buttonStyle(.plain).help("Mute")
                Button { session.edit { p in if let i = p.tracks.firstIndex(where: { $0.id == track.id }) { p.tracks[i].solo.toggle() } } } label: {
                    SmallTag(text: "S", active: track.solo, color: Palette.color(1))
                }.buttonStyle(.plain).help("Solo")
            }
            .padding(.trailing, 10)
        }
        .frame(height: height)
        .background(selected ? Color.white.opacity(0.06) : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { session.selectedTrackID = track.id; if session.selectedTrack?.clips.contains(where: { $0.id == session.selectedClipID }) != true { session.selectedClipID = nil } }
        .contextMenu {
            Button("Rename") { nameText = track.name; renaming = true; focused = true }
            Button("Duplicate") { session.duplicateTrack(track.id) }
            Divider()
            Button("Delete", role: .destructive) { session.deleteTrack(track.id) }
        }
    }

    private func commit() {
        let n = nameText.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { session.edit { p in if let i = p.tracks.firstIndex(where: { $0.id == track.id }) { p.tracks[i].name = n } } }
        renaming = false
    }
}

// MARK: - Timeline (AppKit)

struct TimelineRepresentable: NSViewRepresentable {
    let session: Session
    let state: ArrangementState
    func makeNSView(context: Context) -> TimelineView { TimelineView(session: session, state: state) }
    func updateNSView(_ v: TimelineView, context: Context) {}
}

final class TimelineView: NSView {
    let session: Session
    let state: ArrangementState
    private var bag = Set<AnyCancellable>()
    private let playhead = CALayer()
    private var track: NSTrackingArea?

    private enum Drag {
        case none
        case seek
        case loopNew(anchor: Double)
        case loopEdge(start: Bool)
        case loopMove(grab: Double, len: Double)
        case tempoPoint(id: UUID?, grabDX: Double)
        case clipMove(id: UUID, grabBeat: Double, origStart: Double, startRow: Int)
        case clipResize(id: UUID, origLen: Double)
        case audioMove(id: UUID, grabBeat: Double, origStart: Double)
        case marquee
        case pan
    }
    private var drag: Drag = .none
    private var pushedUndo = false
    private var mouseDownPoint: NSPoint = .zero
    private var frozenTempoRange: (Double, Double)?

    init(session: Session, state: ArrangementState) {
        self.session = session; self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.ns.well.cgColor
        playhead.backgroundColor = NSColor.white.cgColor
        playhead.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        layer?.addSublayer(playhead)
        session.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.needsDisplay = true; self?.updatePlayhead() } }.store(in: &bag)
        state.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.needsDisplay = true; self?.updatePlayhead() } }.store(in: &bag)
        session.transport.$beat.sink { [weak self] b in self?.followPlayhead(b) }.store(in: &bag)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = track { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t); track = t
    }

    // MARK: Geometry

    private var ppb: CGFloat { state.ppb }
    private var headerH: CGFloat { state.headerH }
    private var rowH: CGFloat { state.rowH }
    private func x(_ beat: Double) -> CGFloat { (CGFloat(beat) - state.scrollX) * ppb }
    private func beat(_ x: CGFloat) -> Double { Double(x / ppb + state.scrollX) }
    private func rowTop(_ i: Int) -> CGFloat { headerH + CGFloat(i) * rowH - state.scrollY }
    private func row(at y: CGFloat) -> Int { Int(floor((y - headerH + state.scrollY) / rowH)) }
    private func snap(_ b: Double, _ grid: Double = 1) -> Double { grid > 0 ? (b / grid).rounded() * grid : b }
    private var project: Project { session.project }

    private func updatePlayhead() {
        let b = session.transport.beat
        let px = x(b)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playhead.frame = CGRect(x: px - 0.75, y: 0, width: 1.5, height: bounds.height)
        playhead.isHidden = px < -2 || px > bounds.width + 2
        CATransaction.commit()
    }

    private func followPlayhead(_ b: Double) {
        if session.transport.isPlaying {
            let px = x(b)
            if px > bounds.width - 30 || px < 0 {
                state.scrollX = max(0, CGFloat(b) - 1)
                return
            }
        }
        updatePlayhead()
    }

    override func layout() { super.layout(); updatePlayhead() }

    // MARK: Drawing

    private static let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: Theme.ns.dim]
    private static let clipAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold)]

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = project
        let bpb = p.beatsPerBar
        let w = bounds.width, h = bounds.height

        // Rows
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: headerH, width: w, height: h - headerH))
        for (i, t) in p.tracks.enumerated() {
            let top = rowTop(i)
            if top > h || top + rowH < headerH { continue }
            let sel = t.id == session.selectedTrackID
            ctx.setFillColor((sel ? NSColor(white: 1, alpha: 0.045) : (i % 2 == 0 ? NSColor(white: 1, alpha: 0.012) : NSColor.clear)).cgColor)
            ctx.fill(CGRect(x: 0, y: top, width: w, height: rowH))
            ctx.setFillColor(Theme.ns.line.cgColor)
            ctx.fill(CGRect(x: 0, y: top + rowH - 1, width: w, height: 1))
        }
        drawGrid(ctx, from: headerH, to: h, bpb: bpb)

        // Loop region
        if p.loopEnd > p.loopStart {
            let lx0 = x(p.loopStart), lx1 = x(p.loopEnd)
            ctx.setFillColor(Theme.accentNS.withAlphaComponent(p.loopEnabled ? 0.07 : 0.025).cgColor)
            ctx.fill(CGRect(x: lx0, y: headerH, width: lx1 - lx0, height: h - headerH))
        }

        // Clips
        for (i, t) in p.tracks.enumerated() {
            let top = rowTop(i)
            if top > h || top + rowH < headerH { continue }
            for c in t.clips { drawClip(ctx, c, track: t, top: top) }
            for c in t.audioClips { drawAudioClip(ctx, c, track: t, top: top) }
        }
        ctx.restoreGState()

        drawRuler(ctx, bpb: bpb)
        if state.showTempo { drawTempoLane(ctx) }
    }

    private func gridSteps(_ bpb: Double) -> (bar: Double, beat: Bool) {
        var barStep = 1.0
        while Double(ppb) * bpb * barStep < 26 { barStep *= 2 }
        return (barStep, ppb >= 14)
    }

    private func drawGrid(_ ctx: CGContext, from y0: CGFloat, to y1: CGFloat, bpb: Double) {
        let (barStep, showBeats) = gridSteps(bpb)
        let first = Int(floor(Double(state.scrollX) / bpb)) - 1
        let last = Int(ceil(Double(state.scrollX + bounds.width / ppb) / bpb)) + 1
        for bar in first...max(first, last) where bar >= 0 {
            if showBeats {
                for b in 1..<Int(bpb.rounded(.up)) {
                    let bx = x(Double(bar) * bpb + Double(b))
                    ctx.setFillColor(NSColor(white: 1, alpha: 0.025).cgColor)
                    ctx.fill(CGRect(x: bx, y: y0, width: 1, height: y1 - y0))
                }
            }
            if Double(bar).truncatingRemainder(dividingBy: barStep) == 0 {
                let bx = x(Double(bar) * bpb)
                ctx.setFillColor(NSColor(white: 1, alpha: 0.07).cgColor)
                ctx.fill(CGRect(x: bx, y: y0, width: 1, height: y1 - y0))
            }
        }
    }

    private func drawClip(_ ctx: CGContext, _ c: Clip, track t: Track, top: CGFloat) {
        let r = CGRect(x: x(c.start), y: top + 5, width: max(4, CGFloat(c.length) * ppb), height: rowH - 10)
        if r.maxX < 0 || r.minX > bounds.width { return }
        let col = Palette.nsColor(t.colorIndex)
        let selected = c.id == session.selectedClipID
        let muted = t.mute
        let path = CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.setFillColor(col.withAlphaComponent(muted ? 0.10 : (selected ? 0.34 : 0.22)).cgColor)
        ctx.fill(r)
        ctx.setFillColor(col.withAlphaComponent(muted ? 0.25 : 0.85).cgColor)
        ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 16))
        // mini notes
        if !c.notes.isEmpty {
            let lo = c.notes.map { $0.pitch }.min()!, hi = c.notes.map { $0.pitch }.max()!
            let span = max(11, hi - lo + 1)
            let area = CGRect(x: r.minX, y: r.minY + 20, width: r.width, height: r.height - 24)
            let nh = max(1.5, area.height / CGFloat(span))
            ctx.setFillColor(col.withAlphaComponent(muted ? 0.3 : 0.95).cgColor)
            for n in c.notes where !n.isSlide {
                let nx = r.minX + CGFloat(n.start) * ppb
                if nx > r.maxX || nx + CGFloat(n.length) * ppb < r.minX { continue }
                let ny = area.minY + CGFloat(hi - n.pitch) / CGFloat(span) * (area.height - nh)
                ctx.fill(CGRect(x: nx, y: ny, width: max(1.5, CGFloat(n.length) * ppb - 0.5), height: nh))
            }
        }
        // name
        if r.width > 24 {
            var a = Self.clipAttrs
            a[.foregroundColor] = NSColor(white: 0, alpha: muted ? 0.5 : 0.78)
            (c.name as NSString).draw(at: CGPoint(x: r.minX + 6, y: r.minY + 2), withAttributes: a)
        }
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor((selected ? Theme.accentNS : col.withAlphaComponent(muted ? 0.3 : 0.7)).cgColor)
        ctx.setLineWidth(selected ? 1.5 : 1)
        ctx.strokePath()
    }

    private func drawRuler(_ ctx: CGContext, bpb: Double) {
        let w = bounds.width
        let p = project
        ctx.setFillColor(Theme.ns.panel.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: ArrangementState.rulerH))

        // loop strip
        if p.loopEnd > p.loopStart {
            let r = CGRect(x: x(p.loopStart), y: 2, width: x(p.loopEnd) - x(p.loopStart), height: ArrangementState.loopH - 4)
            ctx.setFillColor(Theme.accentNS.withAlphaComponent(p.loopEnabled ? 0.9 : 0.28).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.fillPath()
        }

        // bars
        let (barStep, showBeats) = gridSteps(bpb)
        let first = Int(floor(Double(state.scrollX) / bpb)) - 1
        let last = Int(ceil(Double(state.scrollX + w / ppb) / bpb)) + 1
        for bar in first...max(first, last) where bar >= 0 {
            if showBeats {
                for b in 1..<Int(bpb.rounded(.up)) {
                    ctx.setFillColor(NSColor(white: 1, alpha: 0.12).cgColor)
                    ctx.fill(CGRect(x: x(Double(bar) * bpb + Double(b)), y: ArrangementState.rulerH - 5, width: 1, height: 5))
                }
            }
            if Double(bar).truncatingRemainder(dividingBy: barStep) == 0 {
                let bx = x(Double(bar) * bpb)
                ctx.setFillColor(NSColor(white: 1, alpha: 0.28).cgColor)
                ctx.fill(CGRect(x: bx, y: ArrangementState.loopH + 4, width: 1, height: ArrangementState.rulerH - ArrangementState.loopH - 4))
                ("\(bar + 1)" as NSString).draw(at: CGPoint(x: bx + 5, y: ArrangementState.loopH + 3), withAttributes: Self.labelAttrs)
            }
        }
        ctx.setFillColor(Theme.ns.line.cgColor)
        ctx.fill(CGRect(x: 0, y: ArrangementState.rulerH - 1, width: w, height: 1))
    }

    // MARK: Tempo lane

    private func tempoRange() -> (Double, Double) {
        if let f = frozenTempoRange { return f }
        let all = [project.tempo] + project.tempoPoints.map { $0.bpm }
        var lo = (all.min() ?? 120) - 30, hi = (all.max() ?? 120) + 30
        if hi - lo < 90 { let mid = (hi + lo) / 2; lo = mid - 45; hi = mid + 45 }
        return (max(10, lo), hi)
    }
    private func tempoY(_ bpm: Double, _ r: (Double, Double)) -> CGFloat {
        let top = ArrangementState.rulerH + 8, bottom = headerH - 8
        return bottom - CGFloat((bpm - r.0) / (r.1 - r.0)) * (bottom - top)
    }
    private func tempoValue(atY y: CGFloat, _ r: (Double, Double)) -> Double {
        let top = ArrangementState.rulerH + 8, bottom = headerH - 8
        return r.0 + Double((bottom - y) / (bottom - top)) * (r.1 - r.0)
    }

    private func drawTempoLane(_ ctx: CGContext) {
        let w = bounds.width
        let top = ArrangementState.rulerH
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: top, width: w, height: ArrangementState.tempoH))
        ctx.setFillColor(NSColor(red: 0.115, green: 0.12, blue: 0.135, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: top, width: w, height: ArrangementState.tempoH))
        drawGrid(ctx, from: top, to: top + ArrangementState.tempoH, bpb: project.beatsPerBar)

        let r = tempoRange()
        let p = project
        let pts = p.tempoPoints.sorted { $0.beat < $1.beat }
        let path = CGMutablePath()
        var curBeat = 0.0, curBPM = p.tempo
        path.move(to: CGPoint(x: x(0) - 2, y: tempoY(curBPM, r)))
        path.addLine(to: CGPoint(x: x(0), y: tempoY(curBPM, r)))
        for pt in pts {
            if pt.ramp {
                path.addLine(to: CGPoint(x: x(pt.beat), y: tempoY(pt.bpm, r)))
            } else {
                path.addLine(to: CGPoint(x: x(pt.beat), y: tempoY(curBPM, r)))
                path.addLine(to: CGPoint(x: x(pt.beat), y: tempoY(pt.bpm, r)))
            }
            curBeat = pt.beat; curBPM = pt.bpm
        }
        _ = curBeat
        path.addLine(to: CGPoint(x: w + 4, y: tempoY(curBPM, r)))
        let fill = CGMutablePath(); fill.addPath(path)
        fill.addLine(to: CGPoint(x: w + 4, y: top + ArrangementState.tempoH)); fill.addLine(to: CGPoint(x: x(0) - 2, y: top + ArrangementState.tempoH)); fill.closeSubpath()
        ctx.addPath(fill); ctx.setFillColor(Theme.accentNS.withAlphaComponent(0.10).cgColor); ctx.fillPath()
        ctx.addPath(path); ctx.setStrokeColor(Theme.accentNS.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(1.5); ctx.setLineJoin(.round); ctx.strokePath()

        let all: [(Double, Double)] = [(0, p.tempo)] + pts.map { ($0.beat, $0.bpm) }
        for (b, bpm) in all {
            let c = CGPoint(x: x(b), y: tempoY(bpm, r))
            ctx.setFillColor(Theme.ns.window.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
            ctx.setStrokeColor(Theme.accentNS.cgColor); ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
            let label = String(format: bpm == bpm.rounded() ? "%.0f" : "%.1f", bpm) as NSString
            label.draw(at: CGPoint(x: c.x + 7, y: min(c.y - 6, top + ArrangementState.tempoH - 14)), withAttributes: Self.labelAttrs)
        }
        if pts.isEmpty {
            ("Tempo — click to add a tempo change" as NSString).draw(at: CGPoint(x: max(80, x(0) + 80), y: top + 4),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: Theme.ns.faint])
        }
        ctx.restoreGState()
        ctx.setFillColor(Theme.ns.line.cgColor)
        ctx.fill(CGRect(x: 0, y: headerH - 1, width: w, height: 1))
    }

    private func tempoHit(_ pt: NSPoint) -> UUID?? {
        let r = tempoRange()
        if hypot(pt.x - x(0), pt.y - tempoY(project.tempo, r)) < 9 { return .some(nil) }   // base tempo
        for t in project.tempoPoints where hypot(pt.x - x(t.beat), pt.y - tempoY(t.bpm, r)) < 9 { return .some(t.id) }
        return nil
    }

    // MARK: Hit testing

    private func audioWidthBeats(_ c: AudioClip) -> Double {
        let p = project
        return p.beat(atSeconds: p.seconds(atBeat: c.start) + c.length) - c.start
    }

    private func drawAudioClip(_ ctx: CGContext, _ c: AudioClip, track t: Track, top: CGFloat) {
        let r = CGRect(x: x(c.start), y: top + 5, width: max(4, CGFloat(audioWidthBeats(c)) * ppb), height: rowH - 10)
        if r.maxX < 0 || r.minX > bounds.width { return }
        let col = Palette.nsColor(t.colorIndex)
        let selected = c.id == session.selectedAudioClipID
        let muted = t.mute
        let path = CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.setFillColor(col.withAlphaComponent(muted ? 0.10 : (selected ? 0.30 : 0.18)).cgColor); ctx.fill(r)
        ctx.setFillColor(col.withAlphaComponent(muted ? 0.25 : 0.85).cgColor); ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 16))
        // waveform
        let mid = r.minY + 16 + (r.height - 16) / 2, amp = (r.height - 20) / 2
        ctx.setFillColor(col.withAlphaComponent(muted ? 0.3 : 0.95).cgColor)
        let p = project
        let startSec = p.seconds(atBeat: c.start)
        c.peaks.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            var px = max(r.minX, 0)
            while px < min(r.maxX, bounds.width) {
                let sec = p.seconds(atBeat: beat(px)) - startSec + c.offset
                let i = Int(sec * 100)
                if i >= 0 && i < b.count { let a = max(0.5, CGFloat(b[i]) / 255 * amp); ctx.fill(CGRect(x: px, y: mid - a, width: 1, height: a * 2)) }
                px += 1
            }
        }
        // transcribed notes on top
        if let tune = c.tune, tune.analyzed, !tune.notes.isEmpty {
            let lo = tune.notes.map { $0.pitch }.min()!, hi = tune.notes.map { $0.pitch }.max()!
            let span = max(7, hi - lo + 1)
            let area = CGRect(x: r.minX, y: r.minY + 18, width: r.width, height: r.height - 22)
            ctx.setFillColor(Theme.accentNS.withAlphaComponent(tune.enabled ? 1 : 0.55).cgColor)
            for n in tune.notes {
                let bx0 = x(p.beat(atSeconds: startSec + n.start - c.offset)), bx1 = x(p.beat(atSeconds: startSec + n.end - c.offset))
                let ny = area.minY + CGFloat(hi - n.pitch) / CGFloat(span) * (area.height - 3)
                ctx.fill(CGRect(x: bx0, y: ny, width: max(1.5, bx1 - bx0 - 0.5), height: 3))
            }
        }
        if r.width > 24 {
            var a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold)]
            a[.foregroundColor] = NSColor(white: 0, alpha: muted ? 0.5 : 0.78)
            let label = (c.tune?.enabled == true ? "♪ " : "") + c.name
            (label as NSString).draw(at: CGPoint(x: r.minX + 6, y: r.minY + 2), withAttributes: a)
        }
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor((selected ? Theme.accentNS : col.withAlphaComponent(muted ? 0.3 : 0.7)).cgColor)
        ctx.setLineWidth(selected ? 1.5 : 1); ctx.strokePath()
    }

    private func audioClipHit(_ pt: NSPoint) -> (ti: Int, clip: AudioClip)? {
        let ti = row(at: pt.y)
        guard ti >= 0, ti < project.tracks.count else { return nil }
        for c in project.tracks[ti].audioClips.reversed() {
            let r = CGRect(x: x(c.start), y: rowTop(ti) + 5, width: max(4, CGFloat(audioWidthBeats(c)) * ppb), height: rowH - 10)
            if r.contains(pt) { return (ti, c) }
        }
        return nil
    }

    private func clipHit(_ pt: NSPoint) -> (ti: Int, clip: Clip, edge: Bool)? {
        let ti = row(at: pt.y)
        guard ti >= 0, ti < project.tracks.count else { return nil }
        for c in project.tracks[ti].clips.reversed() {
            let r = CGRect(x: x(c.start), y: rowTop(ti) + 5, width: max(4, CGFloat(c.length) * ppb), height: rowH - 10)
            if r.contains(pt) { return (ti, c, pt.x > r.maxX - 8) }
        }
        return nil
    }

    private func loopEdgeHit(_ px: CGFloat) -> Bool? {   // true = start edge, false = end edge
        let p = project
        guard p.loopEnd > p.loopStart else { return nil }
        if abs(px - x(p.loopStart)) < 7 { return true }
        if abs(px - x(p.loopEnd)) < 7 { return false }
        return nil
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if pt.y < ArrangementState.loopH, loopEdgeHit(pt.x) != nil { NSCursor.resizeLeftRight.set(); return }
        if state.showTempo, pt.y >= ArrangementState.rulerH, pt.y < headerH { (tempoHit(pt) != nil ? NSCursor.pointingHand : NSCursor.crosshair).set(); return }
        if pt.y >= headerH, let h = clipHit(pt), h.edge { NSCursor.resizeLeftRight.set(); return }
        NSCursor.arrow.set()
    }

    private func setSelection(track ti: Int, clip: Clip?) {
        session.selectedTrackID = project.tracks[ti].id
        if session.selectedClipID != clip?.id { session.selectedNoteIDs = [] }
        session.selectedClipID = clip?.id
    }

    private func beginChange() { if !pushedUndo { session.pushUndo(); pushedUndo = true } }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)
        mouseDownPoint = pt
        pushedUndo = false
        let p = project

        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }

        if pt.y < ArrangementState.loopH {
            if let isStart = loopEdgeHit(pt.x) { drag = .loopEdge(start: isStart) }
            else if p.loopEnd > p.loopStart, pt.x > x(p.loopStart), pt.x < x(p.loopEnd) {
                drag = .loopMove(grab: beat(pt.x) - p.loopStart, len: p.loopEnd - p.loopStart)
            } else { drag = .loopNew(anchor: snap(beat(pt.x), 1)) }
            return
        }
        if pt.y < ArrangementState.rulerH {
            drag = .seek
            session.seek(to: event.modifierFlags.contains(.option) ? max(0, beat(pt.x)) : max(0, snap(beat(pt.x), 0.25)))
            return
        }
        if state.showTempo, pt.y < headerH {
            frozenTempoRange = tempoRange()
            if let hit = tempoHit(pt) {
                if event.clickCount == 2, let id = hit, let i = p.tempoPoints.firstIndex(where: { $0.id == id }) {
                    session.edit { $0.tempoPoints[i].ramp.toggle() }
                    frozenTempoRange = nil
                    drag = .none; return
                }
                drag = .tempoPoint(id: hit, grabDX: 0)
            } else {
                // add a point
                let b = max(1, snap(beat(pt.x), 1))
                let bpm = min(300, max(20, tempoValue(atY: pt.y, frozenTempoRange!).rounded()))
                let tp = TempoPoint(beat: b, bpm: bpm)
                session.edit { $0.tempoPoints.append(tp); $0.tempoPoints.sort { $0.beat < $1.beat } }
                pushedUndo = true
                drag = .tempoPoint(id: tp.id, grabDX: 0)
            }
            return
        }

        // Track rows
        let ti = row(at: pt.y)
        guard ti >= 0, ti < p.tracks.count else { session.selectedClipID = nil; drag = .none; return }
        if let ah = audioClipHit(pt) {
            session.selectedTrackID = p.tracks[ah.ti].id
            session.selectedClipID = nil; session.selectedNoteIDs = []
            if session.selectedAudioClipID != ah.clip.id { session.selectedTuneNoteIDs = [] }
            session.selectedAudioClipID = ah.clip.id
            if event.clickCount == 2 { session.showEditor = true; session.bottomPanel = .tune; drag = .none; return }
            drag = .audioMove(id: ah.clip.id, grabBeat: beat(pt.x), origStart: ah.clip.start)
            return
        }
        if let hit = clipHit(pt) {
            session.selectedAudioClipID = nil
            setSelection(track: ti, clip: hit.clip)
            if event.clickCount == 2 {
                session.showEditor = true; session.bottomPanel = .editor
                drag = .none; return
            }
            if hit.edge {
                drag = .clipResize(id: hit.clip.id, origLen: hit.clip.length)
            } else {
                if event.modifierFlags.contains(.option) {
                    session.duplicateClipInPlace(trackID: p.tracks[ti].id, clipID: hit.clip.id)
                    pushedUndo = true
                }
                drag = .clipMove(id: session.selectedClipID ?? hit.clip.id, grabBeat: beat(pt.x), origStart: hit.clip.start, startRow: ti)
            }
        } else {
            setSelection(track: ti, clip: nil)
            session.selectedAudioClipID = nil
            if event.clickCount == 2 && p.tracks[ti].kind == .audio { session.importAudio(); drag = .none; return }
            if event.clickCount == 2 {
                let bpb = p.beatsPerBar
                let start = max(0, (beat(pt.x) / bpb).rounded(.down) * bpb)
                session.addClip(trackID: p.tracks[ti].id, start: start)
                session.showEditor = true; session.bottomPanel = .editor
            }
            drag = .none
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let noSnap = event.modifierFlags.contains(.shift)
        switch drag {
        case .none, .marquee, .pan: break
        case .seek:
            session.seek(to: max(0, event.modifierFlags.contains(.option) ? beat(pt.x) : snap(beat(pt.x), 0.25)))
        case .loopNew(let anchor):
            let b = max(0, snap(beat(pt.x), 1))
            session.modify { $0.loopStart = min(anchor, b); $0.loopEnd = max(anchor, b) }
        case .loopEdge(let isStart):
            let b = max(0, snap(beat(pt.x), 1))
            session.modify { p in
                if isStart { p.loopStart = min(b, p.loopEnd - 1) } else { p.loopEnd = max(b, p.loopStart + 1) }
            }
        case .loopMove(let grab, let len):
            let s = max(0, snap(beat(pt.x) - grab, 1))
            session.modify { $0.loopStart = s; $0.loopEnd = s + len }
        case .tempoPoint(let id, _):
            let r = frozenTempoRange ?? tempoRange()
            var bpm = tempoValue(atY: pt.y, r)
            bpm = noSnap ? (bpm * 10).rounded() / 10 : bpm.rounded()
            bpm = min(300, max(20, bpm))
            if abs(pt.x - mouseDownPoint.x) > 2 || abs(pt.y - mouseDownPoint.y) > 2 { beginChange() }
            if let id {
                let b = max(1, noSnap ? beat(pt.x) : snap(beat(pt.x), 1))
                session.modify { p in
                    if let i = p.tempoPoints.firstIndex(where: { $0.id == id }) { p.tempoPoints[i].bpm = bpm; p.tempoPoints[i].beat = b }
                }
            } else {
                session.modify { $0.tempo = bpm }
            }
        case .clipMove(let id, let grabBeat, let origStart, let startRow):
            let dx = beat(pt.x) - grabBeat
            if abs(pt.x - mouseDownPoint.x) > 3 || abs(pt.y - mouseDownPoint.y) > 3 { beginChange() } else { return }
            let newStart = max(0, noSnap ? origStart + dx : snap(origStart + dx, 1))
            let targetRow = min(max(0, row(at: pt.y)), project.tracks.count - 1)
            _ = startRow
            session.moveClip(id: id, toTrackIndex: targetRow, start: newStart)
        case .audioMove(let id, let grabBeat, let origStart):
            if abs(pt.x - mouseDownPoint.x) > 3 || abs(pt.y - mouseDownPoint.y) > 3 { beginChange() } else { return }
            let dx = beat(pt.x) - grabBeat
            let newStart = max(0, noSnap ? origStart + dx : snap(origStart + dx, 0.25))
            var targetRow = min(max(0, row(at: pt.y)), project.tracks.count - 1)
            if project.tracks[targetRow].kind != .audio, let cur = session.findAudioClip(id) { targetRow = cur.track }
            session.moveAudioClip(id, toTrackIndex: targetRow, start: newStart)
        case .clipResize(let id, let origLen):
            beginChange()
            guard let loc = session.findClip(id) else { return }
            let c = project.tracks[loc.track].clips[loc.clip]
            var len = origLen + (beat(pt.x) - (c.start + origLen))
            len = max(0.25, noSnap ? len : snap(len, 1))
            session.modify { $0.tracks[loc.track].clips[loc.clip].length = max(0.25, len) }
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .loopNew, .loopEdge, .loopMove:
            if project.loopEnd - project.loopStart >= 1, !project.loopEnabled { session.modify { $0.loopEnabled = true } }
        case .tempoPoint:
            session.modify { $0.tempoPoints.sort { $0.beat < $1.beat } }
            frozenTempoRange = nil
        default: break
        }
        drag = .none
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        func item(_ title: String, _ action: @escaping () -> Void) {
            let it = ClosureMenuItem(title: title, action: action); menu.addItem(it)
        }
        if state.showTempo, pt.y >= ArrangementState.rulerH, pt.y < headerH {
            frozenTempoRange = tempoRange()
            defer { frozenTempoRange = nil }
            if let hit = tempoHit(pt), let id = hit, let tp = project.tempoPoints.first(where: { $0.id == id }) {
                item(tp.ramp ? "Make Tempo Change Instant" : "Glide From Previous Tempo") {
                    self.session.edit { p in if let i = p.tempoPoints.firstIndex(where: { $0.id == id }) { p.tempoPoints[i].ramp.toggle() } }
                }
                item("Delete Tempo Change") { self.session.edit { $0.tempoPoints.removeAll { $0.id == id } } }
            }
            if !project.tempoPoints.isEmpty { item("Clear All Tempo Changes") { self.session.edit { $0.tempoPoints.removeAll() } } }
            if menu.items.isEmpty { return }
        } else if pt.y >= headerH {
            let ti = row(at: pt.y)
            guard ti >= 0, ti < project.tracks.count else { return }
            let tid = project.tracks[ti].id
            if let ah = audioClipHit(pt) {
                session.selectedTrackID = tid; session.selectedClipID = nil; session.selectedAudioClipID = ah.clip.id
                item("Open in Vocal Tune") { self.session.showEditor = true; self.session.bottomPanel = .tune }
                item("Split Into Sections at Playhead") { self.session.splitAudioClip(ah.clip.id, atBeat: self.session.transport.beat) }
                item((ah.clip.tune?.enabled == true) ? "Turn Tuning Off" : "Turn Tuning On") { self.session.setTuneEnabled(ah.clip.id, !(ah.clip.tune?.enabled ?? false)) }
                item("Analyze Again") { self.session.analyzeClip(ah.clip.id) }
                item("Delete") { self.session.deleteAudioClip(ah.clip.id) }
            } else if let hit = clipHit(pt) {
                setSelection(track: ti, clip: hit.clip)
                item("Edit Notes") { self.session.showEditor = true; self.session.bottomPanel = .editor }
                item("Duplicate") { self.session.duplicateClip(trackID: tid, clipID: hit.clip.id) }
                item("Split at Playhead") { self.session.splitClip(trackID: tid, clipID: hit.clip.id, at: self.session.transport.beat) }
                item("Delete") { self.session.deleteClip(trackID: tid, clipID: hit.clip.id) }
            } else {
                let b = max(0, (beat(pt.x) / project.beatsPerBar).rounded(.down) * project.beatsPerBar)
                setSelection(track: ti, clip: nil)
                item("New Pattern Here") { self.session.addClip(trackID: tid, start: b); self.session.showEditor = true; self.session.bottomPanel = .editor }
            }
        } else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:   // delete
            if let aid = session.selectedAudioClipID, session.selectedClipID == nil { session.deleteAudioClip(aid); return }
            if let tid = session.selectedTrackID, let cid = session.selectedClipID { session.deleteClip(trackID: tid, clipID: cid) }
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "d",
               let tid = session.selectedTrackID, let cid = session.selectedClipID { session.duplicateClip(trackID: tid, clipID: cid) }
            else { super.keyDown(with: event) }
        }
    }

    // MARK: Scroll & zoom

    private func maxScrollY() -> CGFloat {
        max(0, CGFloat(project.tracks.count + 1) * rowH - (bounds.height - headerH))
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            resizeTracks(by: 1 + event.scrollingDeltaY * 0.01, anchorY: convert(event.locationInWindow, from: nil).y)
            return
        }
        if event.modifierFlags.contains(.option) {
            zoom(by: 1 + event.scrollingDeltaY * 0.01, anchorX: convert(event.locationInWindow, from: nil).x)
            return
        }
        let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 8
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        if event.modifierFlags.contains(.shift) || abs(dx) > abs(dy) {
            state.scrollX = max(0, state.scrollX - (abs(dx) > abs(dy) ? dx : dy) / ppb)
        } else {
            state.scrollY = min(maxScrollY(), max(0, state.scrollY - dy))
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, anchorX: convert(event.locationInWindow, from: nil).x)
    }

    /// Makes every track taller or shorter, keeping the track under the pointer where it is.
    func resizeTracks(by factor: CGFloat, anchorY: CGFloat) {
        let old = state.rowH
        let new = min(ArrangementState.maxRowH, max(ArrangementState.minRowH, old * factor))
        guard abs(new - old) > 0.01 else { return }
        let rowsAboveAnchor = max(0, anchorY - headerH + state.scrollY) / old
        state.rowH = new
        state.scrollY = min(maxScrollY(), max(0, rowsAboveAnchor * new - max(0, anchorY - headerH)))
    }

    private func zoom(by f: CGFloat, anchorX: CGFloat) {
        let anchorBeat = beat(anchorX)
        state.ppb = min(240, max(4, state.ppb * f))
        state.scrollX = max(0, CGFloat(anchorBeat) - anchorX / state.ppb)
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
