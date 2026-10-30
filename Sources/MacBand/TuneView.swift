import SwiftUI
import AppKit
import Combine

final class TuneState: ObservableObject {
    @Published var scrollX: CGFloat = 0        // seconds in the audio file
    @Published var topPitch: CGFloat = 72
    @Published var pps: CGFloat = 120          // points per second
    @Published var rowH: CGFloat = 22
    static let keysW: CGFloat = 62
    static let rulerH: CGFloat = 22
    static let waveH: CGFloat = 34
}

// MARK: - Container & toolbar

struct TuneContainer: View {
    @EnvironmentObject var session: Session
    @StateObject private var state = TuneState()

    var body: some View {
        if let loc = session.selectedAudioLocation {
            let clip = session.project.tracks[loc.track].audioClips[loc.clip]
            VStack(spacing: 0) {
                TuneToolbar(clip: clip, state: state)
                Divider().overlay(Theme.line)
                TuneRepresentable(session: session, state: state)
            }
            .onChange(of: session.selectedAudioClipID) { _ in center(clip) }
            .onChange(of: clip.tune?.analyzed ?? false) { _ in center(clip) }
            .onAppear { center(clip) }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 26)).foregroundStyle(Theme.faint)
                Text("Import a vocal to tune it").font(.system(size: 13)).foregroundStyle(Theme.dim)
                Text("MacBand finds the pitch of the voice, turns it into notes locked to the nearest pitch, and writes the sung words on them.")
                    .font(.system(size: 11)).foregroundStyle(Theme.faint).multilineTextAlignment(.center).frame(maxWidth: 420)
                HStack { Button("Import Audio…") { session.importAudio() }; Button("New Audio Track") { session.addAudioTrack() } }.buttonStyle(.bordered)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func center(_ clip: AudioClip) {
        state.scrollX = CGFloat(clip.offset)
        if let t = clip.tune, let lo = t.notes.map({ $0.voices.min() ?? $0.pitch }).min(), let hi = t.notes.map({ $0.voices.max() ?? $0.pitch }).max() {
            state.topPitch = CGFloat(min(127, (lo + hi) / 2 + 6))
        } else if let t = clip.tune, !t.pitch.isEmpty {
            let v: [Float] = t.pitch.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }.filter { $0 > 0 }
            if let lo = v.min(), let hi = v.max() { state.topPitch = CGFloat(min(127, Int((lo + hi) / 2) + 6)) }
        } else { state.topPitch = 60 }
    }
}

struct TuneToolbar: View {
    @EnvironmentObject var session: Session
    let clip: AudioClip
    @ObservedObject var state: TuneState
    @State private var draggingStrength = false

    private var tune: TuneData { clip.tune ?? TuneData() }
    private var working: Bool { session.tuneWorking.contains(clip.id) }

    var body: some View {
        HStack(spacing: 12) {
            // On / Off
            Button { session.setTuneEnabled(clip.id, !tune.enabled) } label: {
                HStack(spacing: 6) {
                    Circle().fill(tune.enabled ? Color.green : Color.white.opacity(0.25)).frame(width: 8, height: 8)
                    Text(tune.enabled ? "Tune On" : "Tune Off").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(tune.enabled ? Color.black.opacity(0.85) : Theme.text)
                .padding(.horizontal, 12).frame(height: 26)
                .background(Capsule().fill(tune.enabled ? Theme.accent : Color.white.opacity(0.09)))
            }
            .buttonStyle(.plain).disabled(!tune.analyzed)
            .help("Turn pitch correction on or off for this clip (T)")

            // Strength
            HStack(spacing: 8) {
                Text("Strength").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.dim)
                Text("Natural").font(.system(size: 9)).foregroundStyle(Theme.faint)
                Slider(value: Binding(get: { tune.amount * 100 }, set: { v in session.editTune(clip.id) { $0.amount = v / 100 } }), in: 0...100,
                       onEditingChanged: { editing in if editing && !draggingStrength { session.pushUndo(); draggingStrength = true }; if !editing { draggingStrength = false } })
                    .frame(width: 100).controlSize(.small).tint(Theme.accent)
                Text("Robot").font(.system(size: 9)).foregroundStyle(Theme.faint)
                Text("\(Int((tune.amount * 100).rounded()))").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text).frame(width: 28, alignment: .trailing)
            }
            .help("0 leaves the voice as sung; 100 pulls every moment onto the note: flat, robotic hard-tune")

            // Chords
            Menu {
                Section("Stack a chord on the selected words") {
                    ForEach(["Major", "Minor", "Power", "Sus2", "Sus4", "Major 7", "Minor 7", "Dominant 7", "Octave"], id: \.self) { name in
                        Button(name) { session.applyChord(clip.id, noteIDs: targetNotes, intervals: session.chordIntervals(name)) }
                    }
                }
                Divider()
                Button("Add One More Pitch") { for id in targetNotes { session.addVoice(clip.id, noteID: id) } }
                Button("Clear Chord") { session.applyChord(clip.id, noteIDs: targetNotes, intervals: []) }
            } label: {
                HStack(spacing: 4) { Image(systemName: "pianokeys"); Text("Chord") }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 9).frame(height: 24).background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Give a word several pitches at once. Applies to the selected notes, or all notes if none are selected.")

            // Words
            Menu {
                Button("Move Words Right  (⌥→)") { session.shiftWords(clip.id, by: 1, noteIDs: session.selectedTuneNoteIDs) }
                Button("Move Words Left  (⌥←)") { session.shiftWords(clip.id, by: -1, noteIDs: session.selectedTuneNoteIDs) }
                Divider()
                Button("Clear Words") { session.clearWords(clip.id, noteIDs: session.selectedTuneNoteIDs) }
            } label: {
                HStack(spacing: 4) { Image(systemName: "text.alignleft"); Text("Words") }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 9).frame(height: 24).background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Drag a word sideways onto another note, or slide the words along the notes. With notes selected only their words move.")

            // Split
            Menu {
                Button("Split Selected Notes at the Playhead  (S)") { session.splitNotesAtPlayhead(clip.id, noteIDs: targetNotes) }
                Divider()
                ForEach([2, 3, 4], id: \.self) { n in Button("Split Selected Into \(n) Equal Sections") { session.splitNotes(clip.id, noteIDs: targetNotes, parts: n) } }
                Divider()
                Button(session.tuneSplitTool ? "Turn Off the Split Tool" : "Split Tool: Click a Note to Cut It") { session.tuneSplitTool.toggle() }
                Button("Merge Selected Notes") { session.mergeNotes(clip.id, noteIDs: targetNotes) }
            } label: {
                HStack(spacing: 4) { Image(systemName: "scissors"); Text(session.tuneSplitTool ? "Split Tool On" : "Split") }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(session.tuneSplitTool ? Color.black.opacity(0.85) : Theme.text)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 5).fill(session.tuneSplitTool ? Theme.accent : Color.white.opacity(0.08)))
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Cut a note into sections so each part can have its own pitch (press S to split at the playhead)")

            // Key: choose a key and move the vocal into it
            Menu {
                if let g = Session.detectKey(tune.notes) { Text("This vocal sounds like \(g.name)") }
                Picker("Key", selection: Binding(get: { session.project.keyRoot }, set: { v in session.edit { $0.keyRoot = v } })) {
                    ForEach(0..<12, id: \.self) { Text(Pitch.names[$0]).tag($0) }
                }
                Picker("Scale", selection: Binding(get: { session.project.scale == .chromatic ? .major : session.project.scale }, set: { v in session.edit { $0.scale = v } })) {
                    ForEach(ScaleKind.allCases.filter { $0 != .chromatic }) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Button("Transpose Notes into This Key") { session.transposeToKey(clip.id, root: session.project.keyRoot, scale: session.project.scale == .chromatic ? .major : session.project.scale) }
                Button("Snap Out-of-Key Notes to This Key") { session.snapNotesToKey(clip.id, root: session.project.keyRoot, scale: session.project.scale == .chromatic ? .major : session.project.scale) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "music.note.list")
                    Text(session.project.scale == .chromatic ? "Key" : "\(Pitch.names[session.project.keyRoot]) \(session.project.scale.rawValue)")
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
                .padding(.horizontal, 9).frame(height: 24).background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Pick a key, then transpose the vocal into it (notes and chords move together) or just snap stray notes into the key")

            Toggle("Snap to key", isOn: Binding(get: { tune.snapToScale }, set: { v in session.updateTune(clip.id) { $0.snapToScale = v } }))
                .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(Theme.dim)
                .help("When a key and scale are set in the piano roll, detected notes snap to that scale. Applies on the next analysis.")

            Button { session.analyzeClip(clip.id) } label: {
                HStack(spacing: 4) { Image(systemName: "arrow.triangle.2.circlepath"); Text(tune.analyzed ? "Re-analyze" : "Analyze") }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 9).frame(height: 24).background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
            }.buttonStyle(.plain).disabled(working)
            .help("Detect the pitch, notes and words again. This replaces edits you made to the notes.")

            Spacer(minLength: 4)
            if working { ProgressView().controlSize(.small) }
            if !tune.status.isEmpty { Text(tune.status).font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(1) }
            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.faint)
                Slider(value: Binding(get: { Double(state.pps) }, set: { state.pps = CGFloat($0) }), in: 30...500).frame(width: 80).controlSize(.mini)
                Image(systemName: "plus.magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 10).frame(height: 40).background(Theme.panel)
    }

    private var targetNotes: Set<UUID> {
        session.selectedTuneNoteIDs.isEmpty ? Set(tune.notes.map { $0.id }) : session.selectedTuneNoteIDs
    }
}

struct TuneRepresentable: NSViewRepresentable {
    let session: Session; let state: TuneState
    func makeNSView(context: Context) -> TuneCanvas { TuneCanvas(session: session, state: state) }
    func updateNSView(_ v: TuneCanvas, context: Context) {}
}

// MARK: - Canvas

final class TuneCanvas: NSView, NSTextFieldDelegate {
    let session: Session
    let state: TuneState
    private var bag = Set<AnyCancellable>()
    private let playhead = CALayer()
    private var editor: NSTextField?
    private var editingNote: UUID?

    private enum Drag {
        case none, seek, marquee
        case move(id: UUID, voice: Int, grabPitch: Int, origs: [UUID: (pitch: Int, extra: [Int])])
        case resizeStart(id: UUID), resizeEnd(id: UUID)
        case word(id: UUID)
        case slide(grabTime: Double, origs: [UUID: (start: Double, end: Double, marker: Double?)])
        case marker(id: UUID)
    }
    private var drag: Drag = .none
    private var didPush = false
    private var downPoint: CGPoint = .zero
    private var marquee: CGRect?
    private var hoverNote: UUID?
    private var wordTarget: UUID?
    private var wordGhostX: CGFloat = 0

    init(session: Session, state: TuneState) {
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
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var debugState: TuneState { state }

    // MARK: Geometry / data

    private let keysW = TuneState.keysW, rulerH = TuneState.rulerH, waveH = TuneState.waveH
    private var pps: CGFloat { state.pps }
    private var rowH: CGFloat { state.rowH }
    private var top: CGFloat { rulerH + waveH }
    private func x(_ t: Double) -> CGFloat { keysW + (CGFloat(t) - state.scrollX) * pps }
    private func time(_ x: CGFloat) -> Double { Double((x - keysW) / pps + state.scrollX) }
    private func y(_ pitch: Int) -> CGFloat { top + (state.topPitch - CGFloat(pitch)) * rowH }
    private func yc(_ f: Double) -> CGFloat { top + (state.topPitch - CGFloat(f)) * rowH + rowH / 2 }
    private func pitch(at y: CGFloat) -> Int { min(127, max(0, Int(ceil(state.topPitch - (y - top) / rowH)))) }

    private var loc: (track: Int, clip: Int)? { session.selectedAudioLocation }
    private var clip: AudioClip? { loc.map { session.project.tracks[$0.track].audioClips[$0.clip] } }
    private var tune: TuneData { clip?.tune ?? TuneData() }
    private var color: NSColor { Theme.accentNS }

    private func updatePlayhead() {
        guard let c = clip else { return }
        let p = session.project
        let t = p.seconds(atBeat: session.transport.beat) - p.seconds(atBeat: c.start) + c.offset
        let px = x(t)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playhead.frame = CGRect(x: px - 0.75, y: rulerH, width: 1.5, height: max(0, bounds.height - rulerH))
        playhead.isHidden = px < keysW || px > bounds.width
        CATransaction.commit()
    }
    override func layout() { super.layout(); updatePlayhead() }

    private func edit(_ body: @escaping (inout TuneData) -> Void) {
        guard let c = clip else { return }
        session.editTune(c.id, body)
    }
    private func beginChange() { if !didPush { session.pushUndo(); didPush = true } }

    // MARK: Note rectangles

    private func noteRect(_ n: TuneNote, pitch p: Int) -> CGRect {
        let x0 = x(n.start), x1 = x(n.end)
        return CGRect(x: x0, y: y(p) + 1, width: max(12, x1 - x0), height: rowH - 2)
    }
    private func markerX(_ n: TuneNote) -> CGFloat { x(n.marker ?? n.end) }

    // MARK: Drawing

    private static let keyAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8.5, weight: .medium), .foregroundColor: NSColor(white: 0.25, alpha: 1)]
    private static let rulerAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: Theme.ns.dim]

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let c = clip else { return }
        let w = bounds.width, h = bounds.height
        let t = tune
        let on = t.enabled
        let p = session.project

        // rows
        ctx.saveGState()
        ctx.clip(to: CGRect(x: keysW, y: top, width: w - keysW, height: h - top))
        let topP = min(127, Int(ceil(state.topPitch)) + 1), botP = max(0, Int(floor(state.topPitch - (h - top) / rowH)) - 1)
        let scale = p.scale.intervals
        if topP >= botP {
            for pi in botP...topP {
                let rel = ((pi - p.keyRoot) % 12 + 12) % 12
                var fill = Pitch.isBlack(pi) ? NSColor(white: 0, alpha: 0.18) : NSColor(white: 1, alpha: 0.018)
                if p.scale != .chromatic { fill = scale.contains(rel) ? (rel == 0 ? color.withAlphaComponent(0.13) : color.withAlphaComponent(0.05)) : NSColor(white: 0, alpha: 0.28) }
                ctx.setFillColor(fill.cgColor); ctx.fill(CGRect(x: keysW, y: y(pi), width: w, height: rowH))
                ctx.setFillColor(NSColor(white: 1, alpha: pi % 12 == 0 ? 0.10 : 0.03).cgColor); ctx.fill(CGRect(x: keysW, y: y(pi) + rowH - 1, width: w, height: 1))
            }
        }
        // time grid
        var step = 1.0
        while Double(pps) * step < 60 { step *= 2 }
        while Double(pps) * step > 240 && step > 0.1 { step /= 2 }
        var tt = (Double(state.scrollX) / step).rounded(.down) * step
        while x(tt) < w {
            ctx.setFillColor(NSColor(white: 1, alpha: 0.06).cgColor); ctx.fill(CGRect(x: x(tt), y: top, width: 1, height: h - top)); tt += step
        }
        // outside the clip
        let cs = x(c.offset), ce = x(c.offset + c.length)
        ctx.setFillColor(NSColor(white: 0, alpha: 0.35).cgColor)
        if cs > keysW { ctx.fill(CGRect(x: keysW, y: top, width: cs - keysW, height: h)) }
        if ce < w { ctx.fill(CGRect(x: ce, y: top, width: w - ce, height: h)) }

        // notes (every voice)
        for n in t.notes {
            let selected = session.selectedTuneNoteIDs.contains(n.id)
            for (vi, pv) in n.voices.enumerated() { drawNote(ctx, n, voice: vi, pitch: pv, on: on, selected: selected) }
            if wordTarget == n.id { let r = noteRect(n, pitch: n.pitch); ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(2.5); ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -3, dy: -3), cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.strokePath() }
            if n.voices.count > 1 {   // chord bracket
                let lo = n.voices.min()!, hi = n.voices.max()!
                ctx.setFillColor(color.withAlphaComponent(on ? 0.55 : 0.3).cgColor)
                ctx.fill(CGRect(x: x(n.start) - 3, y: y(hi) + 3, width: 2, height: y(lo) - y(hi) + rowH - 6))
            }
        }

        if case .word(let wid) = drag, let n = tune.notes.first(where: { $0.id == wid }), !n.word.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
            let size = (n.word as NSString).size(withAttributes: attrs)
            let r = noteRect(n, pitch: n.pitch)
            let pill = CGRect(x: wordGhostX - size.width / 2 - 8, y: r.minY - 3, width: size.width + 16, height: r.height + 6)
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.setFillColor(NSColor.black.withAlphaComponent(0.8).cgColor); ctx.fillPath()
            (n.word as NSString).draw(at: CGPoint(x: pill.minX + 8, y: pill.minY + (pill.height - size.height) / 2), withAttributes: attrs)
        }

        // pitch curves: what was sung (red) and where it's tuned to (green)
        let detected: [Float] = t.pitch.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        if !detected.isEmpty {
            func polyline(_ values: [Float], _ col: NSColor, _ width: CGFloat) {
                ctx.setStrokeColor(col.cgColor); ctx.setLineWidth(width); ctx.setLineJoin(.round); ctx.setLineCap(.round)
                var open = false
                for (i, v) in values.enumerated() {
                    let px = x(Double(i) * PitchAnalyzer.hop)
                    if px < keysW - 20 { if open { ctx.strokePath(); open = false }; continue }
                    if px > w + 20 { break }
                    if v > 0 { let pt = CGPoint(x: px, y: yc(Double(v))); if open { ctx.addLine(to: pt) } else { ctx.move(to: pt); open = true } }
                    else if open { ctx.strokePath(); open = false }
                }
                if open { ctx.strokePath() }
            }
            let green = NSColor(srgbRed: 0.45, green: 0.95, blue: 0.4, alpha: 1), red = NSColor(srgbRed: 0.98, green: 0.4, blue: 0.38, alpha: 1)
            let c0 = Retuner.curve(frames: detected.count, detected: detected, notes: t.notes, voice: 0, amount: t.amount, defaultGlide: t.defaultGlide)
            polyline(detected, red.withAlphaComponent(on ? 0.35 : 1), on ? 2 : 3)
            polyline(c0.target, green.withAlphaComponent(on ? 1 : 0.4), on ? 3 : 2)
        } else if !(session.tuneWorking.contains(c.id)) {
            ("Click Analyze to find the notes and words" as NSString).draw(at: CGPoint(x: keysW + 20, y: top + 20), withAttributes: Self.rulerAttrs)
        }
        if let m = marquee {
            ctx.setFillColor(color.withAlphaComponent(0.14).cgColor); ctx.fill(m)
            ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(1); ctx.stroke(m)
        }
        ctx.restoreGState()

        drawWave(ctx, c)
        drawKeys(ctx)
        drawRuler(ctx)
    }

    private func drawNote(_ ctx: CGContext, _ n: TuneNote, voice: Int, pitch p: Int, on: Bool, selected: Bool) {
        let r = noteRect(n, pitch: p)
        if r.maxX < keysW || r.minX > bounds.width || r.maxY < top || r.minY > bounds.height { return }
        let path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
        let alpha: CGFloat = (voice == 0 ? 1.0 : 0.82) * (on ? 1.0 : 0.38)    // slightly transparent until tuning is switched on
        ctx.addPath(path); ctx.setFillColor(color.withAlphaComponent(alpha).cgColor); ctx.fillPath()
        ctx.addPath(path); ctx.setStrokeColor((selected ? NSColor.white : color.withAlphaComponent(on ? 1 : 0.7)).cgColor); ctx.setLineWidth(selected ? 2 : 1); ctx.strokePath()

        // text: the word on the main voice, the pitch name otherwise
        let textColor = NSColor.black.withAlphaComponent(on ? 0.9 : 0.75)
        if voice == 0 {
            let name = Pitch.name(p)
            var carried = false
            if case .word(let wid) = drag, wid == n.id { carried = true }
            if !n.word.isEmpty && !carried {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: textColor]
                let size = (n.word as NSString).size(withAttributes: attrs)
                if size.width + 14 <= r.width {
                    ctx.saveGState(); ctx.clip(to: r.insetBy(dx: 2, dy: 0))
                    (n.word as NSString).draw(at: CGPoint(x: r.minX + 6, y: r.minY + (r.height - 15) / 2), withAttributes: attrs)
                    if r.width > size.width + 60 { (name as NSString).draw(at: CGPoint(x: r.maxX - 34, y: r.minY + (r.height - 12) / 2), withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: textColor.withAlphaComponent(0.55)]) }
                    ctx.restoreGState()
                } else {   // short note: the word spills out to the right on a small backing so it stays readable
                    let pill = CGRect(x: r.minX, y: r.minY, width: size.width + 12, height: r.height)
                    let pp = CGPath(roundedRect: pill, cornerWidth: 4, cornerHeight: 4, transform: nil)
                    ctx.addPath(pp); ctx.setFillColor(NSColor.black.withAlphaComponent(on ? 0.7 : 0.5).cgColor); ctx.fillPath()
                    (n.word as NSString).draw(at: CGPoint(x: r.minX + 6, y: r.minY + (r.height - 15) / 2), withAttributes: [.font: attrs[.font]!, .foregroundColor: NSColor.white.withAlphaComponent(on ? 1 : 0.85)])
                }
            } else if r.width > 30 {
                ctx.saveGState(); ctx.clip(to: r.insetBy(dx: 2, dy: 0))
                (name as NSString).draw(at: CGPoint(x: r.minX + 6, y: r.minY + (r.height - 14) / 2), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: textColor])
                ctx.restoreGState()
            }
        } else if r.width > 30 {
            ctx.saveGState(); ctx.clip(to: r.insetBy(dx: 2, dy: 0))
            (Pitch.name(p) as NSString).draw(at: CGPoint(x: r.minX + 6, y: r.minY + (r.height - 13) / 2), withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: textColor.withAlphaComponent(0.8)])
            ctx.restoreGState()
        }

        guard voice == 0 else { return }
        // end bar (the handle for the note's end) as in the design
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.85).cgColor)
        ctx.fill(CGRect(x: r.maxX - 4, y: r.minY + 3, width: 2.5, height: r.height - 6))
        // transition marker: pause icon if the correction waits, clock if it starts early (slower glide)
        if let mk = n.marker {
            let mx = x(mk), cy = r.midY
            let waits = mk > n.end + 0.001
            ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: CGRect(x: mx - 8, y: cy - 8, width: 16, height: 16))
            ctx.setStrokeColor(NSColor.black.cgColor); ctx.setLineWidth(1.6); ctx.strokeEllipse(in: CGRect(x: mx - 8, y: cy - 8, width: 16, height: 16))
            ctx.setStrokeColor(NSColor.black.cgColor); ctx.setLineWidth(2); ctx.setLineCap(.round)
            if waits {   // II
                ctx.move(to: CGPoint(x: mx - 2.5, y: cy - 4)); ctx.addLine(to: CGPoint(x: mx - 2.5, y: cy + 4))
                ctx.move(to: CGPoint(x: mx + 2.5, y: cy - 4)); ctx.addLine(to: CGPoint(x: mx + 2.5, y: cy + 4)); ctx.strokePath()
            } else {     // clock
                ctx.move(to: CGPoint(x: mx, y: cy - 4.5)); ctx.addLine(to: CGPoint(x: mx, y: cy)); ctx.addLine(to: CGPoint(x: mx + 3.5, y: cy + 2)); ctx.strokePath()
            }
        } else if hoverNote == n.id || selected {
            let h = markerHandle(n)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.65).cgColor); ctx.setLineWidth(1.3)
            ctx.strokeEllipse(in: CGRect(x: h.x - 5, y: h.y - 5, width: 10, height: 10))
        }
    }

    private func drawWave(_ ctx: CGContext, _ c: AudioClip) {
        let w = bounds.width
        ctx.setFillColor(NSColor(white: 0, alpha: 0.28).cgColor); ctx.fill(CGRect(x: keysW, y: rulerH, width: w - keysW, height: waveH))
        ctx.saveGState(); ctx.clip(to: CGRect(x: keysW, y: rulerH, width: w - keysW, height: waveH))
        ctx.setFillColor(NSColor(white: 1, alpha: 0.35).cgColor)
        let mid = rulerH + waveH / 2
        c.peaks.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            var px = keysW
            while px < w {
                let t = time(px)
                let i = Int(t * 100)
                if i >= 0 && i < b.count { let a = CGFloat(b[i]) / 255 * (waveH / 2 - 2); ctx.fill(CGRect(x: px, y: mid - a, width: 1, height: max(1, 2 * a))) }
                px += 1
            }
        }
        ctx.restoreGState()
    }

    private func drawKeys(_ ctx: CGContext) {
        let h = bounds.height
        ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: top, width: keysW, height: h - top))
        ctx.setFillColor(NSColor(white: 0.17, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: top, width: keysW, height: h))
        let topP = min(127, Int(ceil(state.topPitch)) + 1), botP = max(0, Int(floor(state.topPitch - (h - top) / rowH)) - 1)
        if topP >= botP {
            for pi in botP...topP {
                let black = Pitch.isBlack(pi), ry = y(pi)
                if black {
                    ctx.setFillColor(NSColor(white: 0.10, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: ry, width: keysW * 0.62, height: rowH))
                    ctx.setFillColor(NSColor(white: 0.84, alpha: 1).cgColor); ctx.fill(CGRect(x: keysW * 0.62, y: ry, width: keysW * 0.38, height: rowH))
                } else {
                    ctx.setFillColor(NSColor(white: 0.84, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: ry, width: keysW, height: rowH))
                    if pi % 12 == 0 || rowH >= 18 { (Pitch.name(pi) as NSString).draw(at: CGPoint(x: keysW - 22, y: ry + (rowH - 10) / 2), withAttributes: Self.keyAttrs) }
                }
                ctx.setFillColor(NSColor(white: 0, alpha: 0.28).cgColor); ctx.fill(CGRect(x: 0, y: ry + rowH - 1, width: keysW, height: 1))
            }
        }
        ctx.restoreGState()
        ctx.setFillColor(Theme.ns.lineStrong.cgColor); ctx.fill(CGRect(x: keysW - 1, y: top, width: 1, height: h))
        ctx.setFillColor(Theme.ns.panel.cgColor); ctx.fill(CGRect(x: 0, y: rulerH, width: keysW, height: waveH))
    }

    private func drawRuler(_ ctx: CGContext) {
        let w = bounds.width
        ctx.setFillColor(Theme.ns.panel.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: rulerH))
        ctx.saveGState(); ctx.clip(to: CGRect(x: keysW, y: 0, width: w - keysW, height: rulerH))
        var step = 1.0
        while Double(pps) * step < 60 { step *= 2 }
        while Double(pps) * step > 240 && step > 0.1 { step /= 2 }
        var tt = (Double(state.scrollX) / step).rounded(.down) * step
        while x(tt) < w {
            ctx.setFillColor(NSColor(white: 1, alpha: 0.3).cgColor); ctx.fill(CGRect(x: x(tt), y: 4, width: 1, height: rulerH - 4))
            (String(format: "%g s", (tt * 100).rounded() / 100) as NSString).draw(at: CGPoint(x: x(tt) + 4, y: 4), withAttributes: Self.rulerAttrs)
            tt += step
        }
        ctx.restoreGState()
        ctx.setFillColor(Theme.ns.line.cgColor); ctx.fill(CGRect(x: 0, y: rulerH - 1, width: w, height: 1))
    }

    // MARK: Hit testing

    private struct Hit { var note: TuneNote; var voice: Int; var zone: Zone }
    private enum Zone { case body, start, end, marker }

    /// The little ring that creates a transition marker sits just past the note's end bar, never inside the note.
    private func markerHandle(_ n: TuneNote) -> CGPoint { CGPoint(x: x(n.end) + 12, y: noteRect(n, pitch: n.pitch).midY) }

    private func hit(_ pt: CGPoint, option: Bool = false) -> Hit? {
        let ns = tune.notes
        // a visible marker icon sits on top of its note
        for n in ns.reversed() {
            if let mk = n.marker, hypot(pt.x - x(mk), pt.y - noteRect(n, pitch: n.pitch).midY) < 10 { return Hit(note: n, voice: 0, zone: .marker) }
        }
        // pressing on (or near) a note means that note; small notes get a minimum grab width and the nearest one wins
        var best: (hit: Hit, dist: CGFloat)? = nil
        for n in ns {
            for (vi, pv) in n.voices.enumerated() {
                let r = noteRect(n, pitch: pv)
                let grow = max(2, (26 - r.width) / 2)
                guard r.insetBy(dx: -grow, dy: 0).contains(pt) else { continue }
                var zone = Zone.body
                if r.width >= 44 {                       // wide notes have resize edges
                    if vi == 0 && pt.x > r.maxX - min(8, r.width * 0.2) { zone = .end }
                    else if pt.x < r.minX + min(6, r.width * 0.15) { zone = .start }
                } else if option && vi == 0 {            // ⌥ on a small note: left half / right half resize it
                    zone = pt.x > r.midX ? .end : .start
                }
                let d = abs(pt.x - r.midX) + (vi == 0 ? 0 : 0.5)
                if best == nil || d < best!.dist { best = (Hit(note: n, voice: vi, zone: zone), d) }
            }
        }
        if let b = best { return b.hit }
        // then the creation ring beside a note's end
        for n in ns.reversed() {
            if n.marker == nil, n.id == hoverNote || session.selectedTuneNoteIDs.contains(n.id) {
                let h = markerHandle(n)
                if hypot(pt.x - h.x, pt.y - h.y) < 9 { return Hit(note: n, voice: 0, zone: .marker) }
            }
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let h = hit(pt)
        let near = h?.note.id ?? tune.notes.first(where: { hypot(pt.x - markerHandle($0).x, pt.y - markerHandle($0).y) < 14 })?.id
        if hoverNote != near { hoverNote = near; needsDisplay = true }
        if session.tuneSplitTool, h != nil { NSCursor.crosshair.set(); return }
        switch h?.zone { case .end?, .start?: NSCursor.resizeLeftRight.set(); case .marker?: NSCursor.pointingHand.set(); default: NSCursor.arrow.set() }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        endWordEditing(commit: true)
        let pt = convert(event.locationInWindow, from: nil)
        downPoint = pt; didPush = false
        guard let c = clip else { return }
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }

        if pt.y < rulerH + waveH && pt.x >= keysW {   // ruler / waveform: move the playhead
            drag = .seek
            seekTo(time(pt.x), c); return
        }
        guard pt.y >= top, pt.x >= keysW else { return }

        if session.tuneSplitTool, let h = hit(pt), h.zone != .marker {
            session.splitNote(c.id, noteID: h.note.id, at: time(pt.x)); drag = .none; return
        }
        if let h = hit(pt, option: event.modifierFlags.contains(.option)) {
            if event.clickCount == 2 && h.zone == .body { beginWordEditing(h.note); drag = .none; return }
            if event.modifierFlags.contains(.command) && h.zone == .body && !h.note.word.isEmpty && h.voice == 0 {
                session.selectedTuneNoteIDs = [h.note.id]; drag = .word(id: h.note.id); wordGhostX = pt.x; return
            }
            if event.modifierFlags.contains(.shift) {
                if session.selectedTuneNoteIDs.contains(h.note.id) { session.selectedTuneNoteIDs.remove(h.note.id); drag = .none; return }
                session.selectedTuneNoteIDs.insert(h.note.id)
            } else if !session.selectedTuneNoteIDs.contains(h.note.id) { session.selectedTuneNoteIDs = [h.note.id] }
            switch h.zone {
            case .body: drag = .move(id: h.note.id, voice: h.voice, grabPitch: pitch(at: pt.y), origs: selectedOriginals())
            case .start: drag = .resizeStart(id: h.note.id)
            case .end: drag = .resizeEnd(id: h.note.id)
            case .marker: drag = .marker(id: h.note.id)
            }
            return
        }
        // empty space: double-click adds a note, otherwise a marquee selection
        if event.clickCount == 2 {
            session.pushUndo()
            let t0 = max(c.offset, time(pt.x) - 0.2)
            let n = TuneNote(start: t0, end: min(c.offset + c.length, t0 + 0.4), pitch: pitch(at: pt.y), detected: Double(pitch(at: pt.y)), edited: true)
            edit { $0.notes.append(n); $0.notes.sort { $0.start < $1.start } }
            session.selectedTuneNoteIDs = [n.id]
            drag = .none; return
        }
        if !event.modifierFlags.contains(.shift) { session.selectedTuneNoteIDs = [] }
        drag = .marquee; marquee = CGRect(origin: pt, size: .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard let c = clip else { return }
        let moved = abs(pt.x - downPoint.x) > 2 || abs(pt.y - downPoint.y) > 2
        switch drag {
        case .none: break
        case .seek: seekTo(time(pt.x), c)
        case .marquee:
            let r = CGRect(x: min(downPoint.x, pt.x), y: min(downPoint.y, pt.y), width: abs(pt.x - downPoint.x), height: abs(pt.y - downPoint.y))
            marquee = r
            var sel: Set<UUID> = event.modifierFlags.contains(.shift) ? session.selectedTuneNoteIDs : []
            for n in tune.notes { for pv in n.voices where noteRect(n, pitch: pv).intersects(r) { sel.insert(n.id) } }
            session.selectedTuneNoteIDs = sel; needsDisplay = true
        case .move(_, let voice, let grab, let origs):
            guard moved else { return }
            // a sideways drag slides the notes in time, a vertical one changes their pitch
            if !didPush {
                let dx = abs(pt.x - downPoint.x), dy = abs(pt.y - downPoint.y)
                if max(dx, dy) < 5 { return }
                if dx > dy + 3 { drag = .slide(grabTime: time(downPoint.x), origs: selectedTimes()); mouseDragged(with: event); return }
            }
            beginChange()
            let dp = pitch(at: pt.y) - grab
            edit { t in
                for i in t.notes.indices {
                    guard let o = origs[t.notes[i].id] else { continue }
                    if voice == 0 {
                        t.notes[i].pitch = max(0, min(127, o.pitch + dp))
                        t.notes[i].extra = o.extra.map { max(0, min(127, $0 + dp)) }          // chords travel with their word
                    } else if voice - 1 < o.extra.count, voice - 1 < t.notes[i].extra.count {
                        t.notes[i].extra[voice - 1] = max(0, min(127, o.extra[voice - 1] + dp))
                    }
                    t.notes[i].edited = true
                }
            }
        case .slide(let grabTime, let origs):
            beginChange()
            var dt = time(pt.x) - grabTime
            // can't pass through (or leave the clip past) the notes that aren't being moved
            let fixed = tune.notes.filter { origs[$0.id] == nil }
            var lo = -Double.infinity, hi = Double.infinity
            for (id, o) in origs {
                _ = id
                let prevEnd = fixed.filter { $0.end <= o.start + 1e-6 }.map { $0.end }.max() ?? c.offset
                let nextStart = fixed.filter { $0.start >= o.end - 1e-6 }.map { $0.start }.min() ?? (c.offset + c.length)
                lo = max(lo, prevEnd - o.start); hi = min(hi, nextStart - o.end)
            }
            if lo <= hi { dt = min(hi, max(lo, dt)) } else { dt = 0 }
            dt = (dt / 0.005).rounded() * 0.005
            edit { d in
                for i in d.notes.indices {
                    guard let o = origs[d.notes[i].id] else { continue }
                    d.notes[i].start = o.start + dt; d.notes[i].end = o.end + dt
                    d.notes[i].marker = o.marker.map { $0 + dt }
                    d.notes[i].edited = true
                }
            }
        case .word(let id):
            wordGhostX = pt.x
            wordTarget = noteForWord(at: pt.x, excluding: id)
            needsDisplay = true
        case .resizeStart(let id):
            guard moved else { return }
            if abs(pt.y - downPoint.y) > abs(pt.x - downPoint.x) + 2, let n = tune.notes.first(where: { $0.id == id }) {
                drag = .move(id: id, voice: 0, grabPitch: pitch(at: downPoint.y), origs: selectedOriginals(including: n)); return
            }
            beginChange()
            let t = max(c.offset, time(pt.x))
            edit { d in if let i = d.notes.firstIndex(where: { $0.id == id }) { d.notes[i].start = min(t, d.notes[i].end - 0.05); d.notes[i].edited = true } }
        case .resizeEnd(let id):
            guard moved else { return }
            if abs(pt.y - downPoint.y) > abs(pt.x - downPoint.x) + 2, let n = tune.notes.first(where: { $0.id == id }) {
                drag = .move(id: id, voice: 0, grabPitch: pitch(at: downPoint.y), origs: selectedOriginals(including: n)); return
            }
            beginChange()
            let t = min(c.offset + c.length, time(pt.x))
            edit { d in if let i = d.notes.firstIndex(where: { $0.id == id }) { d.notes[i].end = max(t, d.notes[i].start + 0.05); d.notes[i].edited = true } }
        case .marker(let id):
            guard moved else { return }
            beginChange()
            let t = time(pt.x)
            edit { d in
                guard let i = d.notes.firstIndex(where: { $0.id == id }) else { return }
                let lo = d.notes[i].start + 0.03, hi = d.notes[i].end + 1.0
                d.notes[i].marker = abs(t - d.notes[i].end) < 0.008 ? nil : min(hi, max(lo, t))
                d.notes[i].edited = true
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .word(let id) = drag, let target = wordTarget, let c = clip { session.moveWord(c.id, from: id, to: target) }
        marquee = nil; drag = .none; wordTarget = nil; needsDisplay = true
    }

    /// The note a dragged word would land on: the one under the cursor, else the closest within a short distance.
    private func noteForWord(at px: CGFloat, excluding id: UUID) -> UUID? {
        let t = time(px)
        var best: (UUID, Double)? = nil
        for n in tune.notes where n.id != id {
            let d: Double = (t >= n.start && t <= n.end) ? 0 : min(abs(t - n.start), abs(t - n.end))
            if d < 0.35, best == nil || d < best!.1 { best = (n.id, d) }
        }
        return best?.0
    }

    private func seekTo(_ t: Double, _ c: AudioClip) {
        let p = session.project
        let beat = p.beat(atSeconds: max(0, p.seconds(atBeat: c.start) + (t - c.offset)))
        session.seek(to: beat)
    }

    /// Original pitches of everything that moves together: the whole selection (or just `including` when it isn't part of one).
    private func selectedOriginals(including n: TuneNote? = nil) -> [UUID: (pitch: Int, extra: [Int])] {
        var out: [UUID: (pitch: Int, extra: [Int])] = [:]
        let sel = session.selectedTuneNoteIDs
        for note in tune.notes where sel.contains(note.id) { out[note.id] = (note.pitch, note.extra) }
        if let n, out[n.id] == nil { out = [n.id: (n.pitch, n.extra)] }
        return out
    }

    /// Start/end/marker of every selected note, so a sideways drag moves them together.
    private func selectedTimes() -> [UUID: (start: Double, end: Double, marker: Double?)] {
        var out: [UUID: (start: Double, end: Double, marker: Double?)] = [:]
        for n in tune.notes where session.selectedTuneNoteIDs.contains(n.id) { out[n.id] = (n.start, n.end, n.marker) }
        return out
    }

    // MARK: Words

    private func beginWordEditing(_ n: TuneNote) {
        let r = noteRect(n, pitch: n.pitch)
        let f = NSTextField(frame: NSRect(x: r.minX, y: r.minY, width: max(90, r.width), height: r.height))
        f.stringValue = n.word; f.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        f.isBordered = false; f.focusRingType = .none; f.backgroundColor = NSColor(white: 1, alpha: 0.95); f.textColor = .black
        f.delegate = self; f.target = self; f.action = #selector(wordCommitted)
        addSubview(f); window?.makeFirstResponder(f); f.selectText(nil)
        editor = f; editingNote = n.id
    }
    @objc private func wordCommitted() { endWordEditing(commit: true) }
    func controlTextDidEndEditing(_ notification: Notification) { endWordEditing(commit: true) }
    private func endWordEditing(commit: Bool) {
        guard let f = editor, let id = editingNote else { return }
        let text = f.stringValue.trimmingCharacters(in: .whitespaces)
        editor = nil; editingNote = nil
        f.removeFromSuperview()
        if commit, let c = clip { session.pushUndo(); session.updateTune(c.id) { d in if let i = d.notes.firstIndex(where: { $0.id == id }) { d.notes[i].word = text } } }
        window?.makeFirstResponder(self)
    }

    // MARK: Context menu & keys

    override func rightMouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard let c = clip, pt.y >= top else { return }
        let menu = NSMenu()
        func item(_ title: String, _ action: @escaping () -> Void) { menu.addItem(ClosureMenuItem(title: title, action: action)) }
        if let h = hit(pt) {
            session.selectedTuneNoteIDs = [h.note.id]
            let n = h.note
            item("Edit Word…") { self.beginWordEditing(n) }
            item("Add Another Pitch to This Word") { self.session.addVoice(c.id, noteID: n.id) }
            for name in ["Major", "Minor", "Power", "Dominant 7"] { item("Chord: \(name)") { self.session.applyChord(c.id, noteIDs: [n.id], intervals: self.session.chordIntervals(name)) } }
            if n.voices.count > 1 { item("Remove This Pitch (\(Pitch.name(n.voices[h.voice])))") { self.session.removeVoice(c.id, noteID: n.id, pitch: n.voices[h.voice]) } }
            if n.marker != nil { item("Reset Transition") { self.session.pushUndo(); self.edit { d in if let i = d.notes.firstIndex(where: { $0.id == n.id }) { d.notes[i].marker = nil } } } }
            menu.addItem(.separator())
            item("Split Here") { self.session.splitNote(c.id, noteID: n.id, at: self.time(pt.x)) }
            for parts in [2, 3, 4] { item("Split Into \(parts) Sections") { self.session.splitNotes(c.id, noteIDs: [n.id], parts: parts) } }
            item("Merge With Next") { self.mergeNote(n.id) }
            item("Delete Note") { self.deleteNotes([n.id]) }
        } else {
            let t0 = time(pt.x), p0 = pitch(at: pt.y)
            item("Add Note Here") {
                self.session.pushUndo()
                let n = TuneNote(start: max(c.offset, t0 - 0.2), end: t0 + 0.2, pitch: p0, detected: Double(p0), edited: true)
                self.edit { $0.notes.append(n); $0.notes.sort { $0.start < $1.start } }
            }
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func deleteNotes(_ ids: Set<UUID>) {
        guard let c = clip, !ids.isEmpty else { return }
        session.pushUndo(); edit { $0.notes.removeAll { ids.contains($0.id) } }
        session.selectedTuneNoteIDs.subtract(ids)
        _ = c
    }
    private func mergeNote(_ id: UUID) {
        session.pushUndo()
        edit { d in
            guard let i = d.notes.firstIndex(where: { $0.id == id }), i + 1 < d.notes.count else { return }
            d.notes[i].end = d.notes[i + 1].end
            if d.notes[i].word.isEmpty { d.notes[i].word = d.notes[i + 1].word }
            d.notes[i].marker = d.notes[i + 1].marker
            d.notes[i].edited = true
            d.notes.remove(at: i + 1)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let c = clip else { return }
        let sel = session.selectedTuneNoteIDs
        let ch = event.charactersIgnoringModifiers ?? ""
        let cmd = event.modifierFlags.contains(.command)
        switch (event.keyCode, ch) {
        case (51, _), (117, _): deleteNotes(sel)
        case (_, "a") where cmd: session.selectedTuneNoteIDs = Set(tune.notes.map { $0.id })
        case (_, "t") where !cmd: session.toggleTuneForSelection()
        case (_, "s") where !cmd:
            let ids = sel.isEmpty ? Set(tune.notes.map { $0.id }) : sel
            session.splitNotesAtPlayhead(c.id, noteIDs: ids)
        case (_, "=") where !cmd, (_, "+") where !cmd: for id in sel { session.addVoice(c.id, noteID: id) }
        case (123, _) where event.modifierFlags.contains(.option), (124, _) where event.modifierFlags.contains(.option):
            session.shiftWords(c.id, by: event.keyCode == 124 ? 1 : -1, noteIDs: sel)
        case (126, _), (125, _):
            guard !sel.isEmpty else { return }
            let d = (event.keyCode == 126 ? 1 : -1) * (event.modifierFlags.contains(.shift) ? 12 : 1)
            session.pushUndo()
            edit { t in for i in t.notes.indices where sel.contains(t.notes[i].id) { t.notes[i].pitch = max(0, min(127, t.notes[i].pitch + d)); t.notes[i].extra = t.notes[i].extra.map { max(0, min(127, $0 + d)) }; t.notes[i].edited = true } }
        case (53, _): session.selectedTuneNoteIDs = []
        default: super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { state.pps = min(600, max(30, state.pps * (1 + event.scrollingDeltaY * 0.01))); return }
        if event.modifierFlags.contains(.option) { state.rowH = min(40, max(12, state.rowH * (1 + event.scrollingDeltaY * 0.01))); return }
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
        state.scrollX = max(0, state.scrollX - event.scrollingDeltaX * k / pps)
        state.topPitch = min(135, max(8, state.topPitch + event.scrollingDeltaY * k / rowH))
    }
    override func magnify(with event: NSEvent) { state.pps = min(600, max(30, state.pps * (1 + event.magnification))) }
}
