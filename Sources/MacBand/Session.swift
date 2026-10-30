import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

@MainActor
final class Transport: ObservableObject {
    @Published var beat: Double = 0
    @Published var isPlaying = false
    @Published var isRecording = false
}

enum BottomPanel: String, CaseIterable, Identifiable {
    case editor = "Editor", tune = "Vocal Tune", mixer = "Mixer"
    var id: String { rawValue }
}

enum RollTool: String, CaseIterable, Identifiable {
    case draw = "Draw", select = "Select", erase = "Erase"
    var id: String { rawValue }
    var icon: String {
        switch self { case .draw: return "pencil"; case .select: return "cursorarrow"; case .erase: return "eraser" }
    }
}

enum AutoLane: String, CaseIterable, Identifiable {
    case velocity = "Velocity", volume = "Volume"
    var id: String { rawValue }
}

extension UTType {
    static let macBandProject = UTType(exportedAs: "com.macband.project", conformingTo: .json)
}

@MainActor
final class Session: ObservableObject {
    // Document
    @Published var project: Project
    @Published var fileURL: URL?
    @Published var isDirty = false

    // Selection / UI state
    @Published var selectedTrackID: UUID?
    @Published var selectedClipID: UUID?
    @Published var selectedNoteIDs: Set<UUID> = []
    @Published var selectedAudioClipID: UUID?
    @Published var selectedTuneNoteIDs: Set<UUID> = []
    @Published var tuneSplitTool = false
    @Published var tuneWorking: Set<UUID> = []          // audio clips being analyzed or re-rendered
    var recorder: AudioRecorder?
    var recordStartBeat = 0.0
    var tuneRenderGeneration: [UUID: Int] = [:]
    var tuneRenderWork: [UUID: DispatchWorkItem] = [:]
    @Published var bottomPanel: BottomPanel = .editor
    @Published var showEditor = true
    @Published var showInspector = true
    @Published var showPluginManager = false
    @Published var metronome = false { didSet { engine.metronomeOn = metronome } }
    @Published var musicalTyping = false
    @Published var typingOctave = 4
    @Published var errorMessage: String?
    @Published var busyMessage: String?
    @Published var toast: String?
    @Published var lastMIDIDevice = ""

    // Piano roll settings
    @Published var tool: RollTool = .draw
    @Published var slideMode = false
    @Published var snap: Double = 0.25
    @Published var lane: AutoLane = .velocity
    @Published var lastNoteLength: Double = 0.5
    @Published var lastVelocity = 100

    let transport = Transport()
    let autosaver = Autosaver()
    @Published var lastAutoSave: Date?
    let engine = AudioEngine()
    let library = PluginLibrary.shared

    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var timer: Timer?
    var sequenceDirty = true
    private var reloadWork: DispatchWorkItem?
    private var keyMonitor: Any?
    private var heldKeys: [UInt16: Int] = [:]
    private var tapTimes: [Date] = []
    private var recording: [Int: (beat: Double, vel: Int)] = [:]
    private var recordClipID: UUID?
    var noteClipboard: [Note] = []
    let midiInput = MIDIInput()

    init() {
        var p = Project()
        var t = Track(name: "Piano", colorIndex: 0)
        t.clips = [Clip(name: "Pattern 1", start: 0, length: p.beatsPerBar * 4)]
        p.tracks = [t]
        project = p
        selectedTrackID = t.id
        selectedClipID = t.clips.first?.id
        engine.onError = { [weak self] m in Task { @MainActor in self?.errorMessage = m } }
        engine.onGraphChanged = { [weak self] in Task { @MainActor in self?.graphChanged() } }
        engine.syncTracks(project.tracks)
        applyMix()
        library.rescan()
        startTimer()
        autosaver.start(self)
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) {            // not in the developer test modes
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerRecovery() }
        }
        installKeyMonitor()
        PluginWindows.shared.installFullscreenSupport()
        EventLog.installIfRequested()
        midiInput.onNoteOn = { [weak self] p, v in Task { @MainActor in self?.liveNoteOn(p, v) } }
        midiInput.onNoteOff = { [weak self] p in Task { @MainActor in self?.liveNoteOff(p) } }
        midiInput.onDevices = { [weak self] names in Task { @MainActor in self?.lastMIDIDevice = names.joined(separator: ", ") } }
        midiInput.start()
        if let i = CommandLine.arguments.firstIndex(of: "--demo-tune"), i + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.importAudio(url: url)
                for _ in 0..<120 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if let id = self.selectedAudioClipID, let loc = self.findAudioClip(id), self.project.tracks[loc.track].audioClips[loc.clip].tune?.analyzed == true, !self.tuneWorking.contains(id) {
                        if CommandLine.arguments.contains("--demo-tune-on") { self.setTuneEnabled(id, true); try? await Task.sleep(nanoseconds: 3_000_000_000) }
                        if CommandLine.arguments.contains("--demo-chord") { self.applyChord(id, noteIDs: Set(self.project.tracks[loc.track].audioClips[loc.clip].tune!.notes.prefix(2).map { $0.id }), intervals: self.chordIntervals("Major")) }
                        self.bottomPanel = .tune
                        if CommandLine.arguments.contains("--demo-drag") { try? await Task.sleep(nanoseconds: 1_500_000_000); await self.demoDragNote(id) }
                        print("DEMO_WINDOW \(NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })?.windowNumber ?? 0)"); fflush(stdout)
                        return
                    }
                }
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--fullscreen-test"), i + 1 < CommandLine.arguments.count {
            runFullscreenTest(CommandLine.arguments[i + 1])
        }
        if let i = CommandLine.arguments.firstIndex(of: "--demo-plugin"), i + 1 < CommandLine.arguments.count {
            runDemoPlugin(CommandLine.arguments[i + 1])
        }
    }

    /// Developer aid: drag the first wide note of the selected clip through the real window's event path.
    func demoDragNote(_ clipID: UUID) async {
        func find(_ v: NSView) -> TuneCanvas? { if let c = v as? TuneCanvas { return c }; for s in v.subviews { if let r = find(s) { return r } }; return nil }
        guard let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }), let canvas = win.contentView.flatMap(find) else { print("DRAG no canvas"); return }
        guard let loc = findAudioClip(clipID), let notes = project.tracks[loc.track].audioClips[loc.clip].tune?.notes, let n = notes.max(by: { $0.length < $1.length }) else { print("DRAG no notes"); return }
        let st = canvas.debugState
        let top = TuneState.rulerH + TuneState.waveH
        let px = TuneState.keysW + (CGFloat((n.start + n.end) / 2) - st.scrollX) * st.pps
        let py = top + (st.topPitch - CGFloat(n.pitch)) * st.rowH + st.rowH / 2
        func ev(_ t: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.activate(ignoringOtherApps: true); win.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let winPt = canvas.convert(CGPoint(x: px, y: py), to: nil)
        let hitView = win.contentView?.superview?.hitTest(winPt)
        var chain: [String] = []; var hv = hitView; while let v = hv { chain.append(String(describing: type(of: v)).prefix(40).description); hv = v.superview }
        print("DRAG hit chain: \(chain.joined(separator: " ← "))")
        print("DRAG hit view at that point: \(hitView.map { String(describing: type(of: $0)) } ?? "nil") | canvas frame \(canvas.frame) in window \(canvas.convert(canvas.bounds, to: nil)) | window key \(win.isKeyWindow)")
        func dump(_ v: NSView, _ depth: Int) {
            let r = v.convert(v.bounds, to: nil)
            if v is TimelineView || v is TuneCanvas || v is PianoRollView || String(describing: type(of: v)).contains("Hosting") { print("DRAG   \(String(repeating: " ", count: depth))\(type(of: v)) window-rect \(NSStringFromRect(r)) hidden=\(v.isHidden)") }
            for sv in v.subviews { dump(sv, depth + 1) }
        }
        dump(win.contentView!, 0)
        print("DRAG before: note pitch \(n.pitch) word '\(n.word)' len \(String(format: "%.2f", n.length)) s at (\(Int(px)),\(Int(py)))")
        win.sendEvent(ev(.leftMouseDown, CGPoint(x: px, y: py)))
        for i in 1...8 { win.sendEvent(ev(.leftMouseDragged, CGPoint(x: px, y: py - CGFloat(i) * st.rowH / 4))) }
        win.sendEvent(ev(.leftMouseUp, CGPoint(x: px, y: py - 2 * st.rowH)))
        let after = project.tracks[loc.track].audioClips[loc.clip].tune?.notes.first { $0.id == n.id }
        print("DRAG after: note pitch \(after?.pitch ?? -1) edited \(after?.edited ?? false)")
        fflush(stdout)
    }

    /// Developer aid: `--fullscreen-test au:name` checks plugin windows behave while MacBand is fullscreen.
    func runFullscreenTest(_ arg: String) {
        let vst3 = arg.hasPrefix("vst3:")
        let name = (vst3 ? String(arg.dropFirst(5)) : arg.hasPrefix("au:") ? String(arg.dropFirst(3)) : arg).lowercased()
        Task { @MainActor in
            func out(_ s: String) { print(s); fflush(stdout) }
            func wait(_ seconds: Double, until: () -> Bool = { false }) async {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end && !until() { try? await Task.sleep(nanoseconds: 100_000_000) }
            }
            await wait(20) { NSApp.windows.contains { $0.identifier?.rawValue == "main" } && !library.plugins.isEmpty && !library.scanning }
            guard let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) else { out("no main window"); exit(2) }
            main.toggleFullScreen(nil)
            await wait(4)
            out("main window fullscreen: \(main.styleMask.contains(.fullScreen))")
            guard let lp = library.instruments.first(where: { $0.spec.name.lowercased().contains(name) && (!vst3 || $0.spec.format == .vst3) && (vst3 || $0.spec.format == .au) }) else { out("plugin not found"); exit(2) }
            var spec = lp.spec; spec.id = UUID()
            addTrack(instrument: InstrumentSpec(plugin: spec))
            let tid = selectedTrackID!
            await wait(30) { engine.unit(trackID: tid, specID: spec.id) != nil }
            out("plugin instance ready: \(engine.unit(trackID: tid, specID: spec.id) != nil) error=\(errorMessage ?? "none")")
            openEditor(trackID: tid, spec: spec)
            await wait(25) { PluginWindows.shared.window(for: spec.id) != nil }
            await wait(1)
            guard let w1 = PluginWindows.shared.window(for: spec.id) else { out("FAIL: editor window never appeared"); exit(1) }
            out("1st open: visible=\(w1.isVisible) onActiveSpace=\(w1.isOnActiveSpace) auxiliary=\(w1.collectionBehavior.contains(.fullScreenAuxiliary)) level=\(w1.level.rawValue) size=\(w1.frame.size) key=\(w1.isKeyWindow)")
            if let v = w1.contentView {
                let p = NSPoint(x: v.bounds.midX, y: v.bounds.midY)
                out("   hit-test at centre → \(type(of: v.hitTest(p) ?? v)) (subviews: \(v.subviews.count))")
            }
            w1.performClose(nil)
            await wait(1)
            out("after close: visible=\(w1.isVisible) (hidden, not destroyed)")
            openEditor(trackID: tid, spec: spec)
            await wait(1)
            let w2 = PluginWindows.shared.window(for: spec.id)
            out("2nd open: same window=\(w2 === w1) visible=\(w2?.isVisible ?? false) onActiveSpace=\(w2?.isOnActiveSpace ?? false)")
            // a window the plugin might open itself (nag screen, file dialog…)
            let dlg = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
            dlg.title = "plugin dialog"
            dlg.makeKeyAndOrderFront(nil)
            await wait(1)
            out("plugin-style dialog: visible=\(dlg.isVisible) onActiveSpace=\(dlg.isOnActiveSpace) auxiliary=\(dlg.collectionBehavior.contains(.fullScreenAuxiliary))")
            exit(0)
        }
    }

    /// Developer aid: `MacBand --demo-plugin vst3:sylenth` adds that instrument and opens its window.
    private func runDemoPlugin(_ arg: String) {
        let vst3 = arg.hasPrefix("vst3:")
        var name = (vst3 ? String(arg.dropFirst(5)) : arg).lowercased()
        var maker: UInt32? = nil
        if let at = arg.firstIndex(of: "@") { maker = PluginHost.fourCC(String(arg[arg.index(after: at)...])); name = String(name[..<(name.firstIndex(of: "@") ?? name.endIndex)]) }
        Task { @MainActor in
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !library.scanning, !library.plugins.isEmpty else { continue }
                guard let lp = library.instruments.first(where: { $0.spec.name.lowercased().contains(name) && (!vst3 || $0.spec.format == .vst3) && (maker == nil || $0.spec.auManufacturer == maker!) }) else { return }
                var spec = lp.spec; spec.id = UUID()
                addTrack(instrument: InstrumentSpec(plugin: spec))
                for _ in 0..<60 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if engine.unit(trackID: selectedTrackID ?? UUID(), specID: spec.id) != nil {
                        let tid = selectedTrackID!
                        openEditor(trackID: tid, spec: spec)
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if let w = PluginWindows.shared.window(for: spec.id) { print("PLUGIN_WINDOW \(w.windowNumber) level=\(w.level.rawValue) frame=\(NSStringFromRect(w.frame)) key=\(w.isKeyWindow)"); fflush(stdout) }
                        if let i = CommandLine.arguments.firstIndex(of: "--demo-snapshot"), i + 1 < CommandLine.arguments.count {
                            let path = CommandLine.arguments[i + 1]
                            engine.noteOn(trackID: tid, pitch: 62, velocity: 100)
                            for n in 1...3 {
                                try? await Task.sleep(nanoseconds: 260_000_000)
                                PluginWindows.shared.snapshot(key: spec.id, to: path.replacingOccurrences(of: ".png", with: "\(n).png"))
                            }
                            exit(0)
                        }
                        if CommandLine.arguments.contains("--demo-notes") {
                            while true {   // developer aid: a note every 1.6 s so the editor animation can be seen
                                engine.noteOn(trackID: tid, pitch: 62, velocity: 100)
                                try? await Task.sleep(nanoseconds: 900_000_000)
                                engine.noteOff(trackID: tid, pitch: 62)
                                try? await Task.sleep(nanoseconds: 700_000_000)
                            }
                        }
                        return
                    }
                }
                return
            }
        }
    }

    // MARK: - Derived

    var selectedTrackIndex: Int? { project.tracks.firstIndex { $0.id == selectedTrackID } }
    var selectedTrack: Track? { selectedTrackIndex.map { project.tracks[$0] } }
    func clipIndex(track ti: Int, id: UUID?) -> Int? { project.tracks[ti].clips.firstIndex { $0.id == id } }
    var selectedClipLocation: (track: Int, clip: Int)? {
        guard let ti = selectedTrackIndex, let ci = clipIndex(track: ti, id: selectedClipID) else { return nil }
        return (ti, ci)
    }

    // MARK: - Editing & undo

    func pushUndo() {
        undoStack.append(project)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Mutate the project. Call `pushUndo()` first for user-visible steps.
    func modify(_ body: (inout Project) -> Void) {
        body(&project)
        isDirty = true
        engine.syncTracks(project.tracks)
        applyMix()
        sequenceDidChange()
    }

    func edit(_ body: (inout Project) -> Void) { pushUndo(); modify(body) }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(project)
        let old = project
        project = prev; afterRestore(from: old)
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        let old = project
        project = next; afterRestore(from: old)
    }
    private func afterRestore(from old: Project) {
        isDirty = true
        if !project.tracks.contains(where: { $0.id == selectedTrackID }) { selectedTrackID = project.tracks.first?.id }
        if selectedClipLocation == nil { selectedClipID = nil }
        selectedNoteIDs = selectedNoteIDs.filter { id in project.tracks.contains { $0.clips.contains { $0.notes.contains { $0.id == id } } } }
        engine.syncTracks(project.tracks)
        applyMix()
        sequenceDidChange()
        // tuned audio must follow the restored notes
        let before = Dictionary(uniqueKeysWithValues: old.tracks.flatMap { $0.audioClips }.map { ($0.id, $0.tune) })
        for c in project.tracks.flatMap({ $0.audioClips }) {
            guard let t = c.tune else { continue }
            let was = before[c.id] ?? nil
            if was?.notes != t.notes || was?.amount != t.amount || was?.defaultGlide != t.defaultGlide || was?.enabled != t.enabled {
                if t.enabled { scheduleRetune(c.id, immediately: true) } else { audioContentChanged() }
            }
        }
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func applyMix() { engine.applyMix(project, beat: engine.isPlaying ? engine.position : nil) }

    private func graphChanged() { sequenceDirty = true; flushSequence() }

    private func sequenceDidChange() {
        sequenceDirty = true
        guard engine.isPlaying else { return }
        reloadWork?.cancel()
        let w = DispatchWorkItem { [weak self] in Task { @MainActor in self?.flushSequence() } }
        reloadWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    func flushSequence() {
        guard sequenceDirty else { return }
        sequenceDirty = false
        engine.reloadSequence(project, metronome: true)
    }

    // MARK: - Tracks

    func addTrack(instrument: InstrumentSpec = InstrumentSpec(), name: String? = nil) {
        pushUndo()
        let n = name ?? instrument.displayName
        var t = Track(name: n, colorIndex: project.tracks.count)
        t.instrument = instrument
        if instrument.plugin != nil { t.bendRange = 2 }
        let start = (transport.beat / project.beatsPerBar).rounded(.down) * project.beatsPerBar
        t.clips = [Clip(name: "Pattern 1", start: start, length: project.beatsPerBar * 2)]
        modify { $0.tracks.append(t) }
        selectedTrackID = t.id
        selectedClipID = t.clips.first?.id
        selectedNoteIDs = []
        showEditor = true
    }

    func deleteTrack(_ id: UUID) {
        pushUndo()
        modify { $0.tracks.removeAll { $0.id == id } }
        if selectedTrackID == id { selectedTrackID = project.tracks.first?.id; selectedClipID = nil }
    }

    func duplicateTrack(_ id: UUID) {
        guard var t = project.tracks.first(where: { $0.id == id }) else { return }
        pushUndo()
        t.id = UUID(); t.name += " Copy"
        t.clips = t.clips.map { var c = $0; c.id = UUID(); c.notes = c.notes.map { var n = $0; n.id = UUID(); return n }; return c }
        if var p = t.instrument.plugin { p.id = UUID(); p.state = engine.captureState(of: p.id) ?? p.state; t.instrument.plugin = p }
        t.inserts = t.inserts.map { var p = $0; p.id = UUID(); return p }
        modify { $0.tracks.append(t) }
        selectedTrackID = t.id
    }

    func setInstrument(trackID: UUID, _ inst: InstrumentSpec) {
        pushUndo()
        modify {
            guard let i = $0.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            let oldDefault = $0.tracks[i].instrument.displayName
            $0.tracks[i].instrument = inst
            $0.tracks[i].bendRange = inst.plugin == nil ? 12 : 2
            if $0.tracks[i].name == oldDefault || $0.tracks[i].name.hasPrefix("Track ") { $0.tracks[i].name = inst.displayName }
        }
    }

    func addInsert(trackID: UUID, _ spec: PluginSpec) {
        var s = spec; s.id = UUID()
        edit { if let i = $0.tracks.firstIndex(where: { $0.id == trackID }) { $0.tracks[i].inserts.append(s) } }
    }
    func removeInsert(trackID: UUID, specID: UUID) {
        edit { if let i = $0.tracks.firstIndex(where: { $0.id == trackID }) { $0.tracks[i].inserts.removeAll { $0.id == specID } } }
    }
    func toggleBypass(trackID: UUID, specID: UUID) {
        guard let ti = project.tracks.firstIndex(where: { $0.id == trackID }),
              let si = project.tracks[ti].inserts.firstIndex(where: { $0.id == specID }) else { return }
        pushUndo()
        project.tracks[ti].inserts[si].bypassed.toggle()
        engine.setBypass(trackID: trackID, specID: specID, bypass: project.tracks[ti].inserts[si].bypassed)
        isDirty = true
    }
    func openEditor(trackID: UUID, spec: PluginSpec) {
        guard let u = engine.unit(trackID: trackID, specID: spec.id) else { errorMessage = "\(spec.name) is still loading."; return }
        PluginWindows.shared.open(unit: u, title: spec.name, key: spec.id)
    }

    // MARK: - Clips

    @discardableResult
    func addClip(trackID: UUID, start: Double, length: Double? = nil) -> UUID? {
        guard let ti = project.tracks.firstIndex(where: { $0.id == trackID }) else { return nil }
        pushUndo()
        let c = Clip(name: "Pattern \(project.tracks[ti].clips.count + 1)", start: start, length: length ?? project.beatsPerBar * 2)
        modify { $0.tracks[ti].clips.append(c) }
        selectedTrackID = trackID; selectedClipID = c.id; selectedNoteIDs = []
        return c.id
    }

    func deleteClip(trackID: UUID, clipID: UUID) {
        edit { p in
            if let ti = p.tracks.firstIndex(where: { $0.id == trackID }) { p.tracks[ti].clips.removeAll { $0.id == clipID } }
        }
        if selectedClipID == clipID { selectedClipID = nil; selectedNoteIDs = [] }
    }

    func duplicateClip(trackID: UUID, clipID: UUID) {
        guard let ti = project.tracks.firstIndex(where: { $0.id == trackID }),
              var c = project.tracks[ti].clips.first(where: { $0.id == clipID }) else { return }
        c.id = UUID(); c.start = c.end
        c.notes = c.notes.map { var n = $0; n.id = UUID(); return n }
        c.volume = c.volume.map { var a = $0; a.id = UUID(); return a }
        edit { $0.tracks[ti].clips.append(c) }
        selectedClipID = c.id
    }

    func findClip(_ id: UUID) -> (track: Int, clip: Int)? {
        for (ti, t) in project.tracks.enumerated() { if let ci = t.clips.firstIndex(where: { $0.id == id }) { return (ti, ci) } }
        return nil
    }

    /// Option-drag: leave a copy behind and keep dragging the original's identity on a fresh clip.
    func duplicateClipInPlace(trackID: UUID, clipID: UUID) {
        guard let ti = project.tracks.firstIndex(where: { $0.id == trackID }),
              let ci = project.tracks[ti].clips.firstIndex(where: { $0.id == clipID }) else { return }
        pushUndo()
        var copy = project.tracks[ti].clips[ci]
        copy.id = UUID()
        copy.notes = copy.notes.map { var n = $0; n.id = UUID(); return n }
        copy.volume = copy.volume.map { var a = $0; a.id = UUID(); return a }
        modify { $0.tracks[ti].clips.append(copy) }
        selectedClipID = copy.id
    }

    func moveClip(id: UUID, toTrackIndex tj: Int, start: Double) {
        guard let loc = findClip(id), tj >= 0, tj < project.tracks.count else { return }
        modify { p in
            var c = p.tracks[loc.track].clips.remove(at: loc.clip)
            c.start = start
            p.tracks[tj].clips.append(c)
        }
        selectedTrackID = project.tracks[tj].id
    }

    func splitClip(trackID: UUID, clipID: UUID, at beat: Double) {
        guard let ti = project.tracks.firstIndex(where: { $0.id == trackID }),
              let ci = project.tracks[ti].clips.firstIndex(where: { $0.id == clipID }) else { return }
        let c = project.tracks[ti].clips[ci]
        let rel = beat - c.start
        guard rel > 0.01, rel < c.length - 0.01 else { return }
        var left = c, right = c
        right.id = UUID(); right.name = c.name + " B"
        right.start = beat; right.length = c.length - rel
        left.length = rel
        left.notes = c.notes.filter { $0.start < rel }.map { var n = $0; n.length = min(n.length, rel - n.start); return n }
        right.notes = c.notes.filter { $0.end > rel }.map { var n = $0; n.id = UUID(); let s = max(n.start, rel); n.length = n.end - s; n.start = s - rel; return n }
        left.volume = c.volume.filter { $0.beat <= rel }
        right.volume = c.volume.filter { $0.beat >= rel }.map { var a = $0; a.id = UUID(); a.beat -= rel; return a }
        edit { $0.tracks[ti].clips[ci] = left; $0.tracks[ti].clips.insert(right, at: ci + 1) }
    }

    // MARK: - Transport

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        if engine.offlineBusy { return }
        if engine.isPlaying {
            let b = engine.position
            transport.beat = b
            engine.applyMix(project, beat: b)
            engine.updateHostTransport(bpm: project.bpm(at: b), beat: b, playing: true)
        }
        if transport.isPlaying != engine.isPlaying { transport.isPlaying = engine.isPlaying }
    }

    func togglePlay() {
        if engine.isPlaying { stop() } else { play() }
    }

    func play(from beat: Double? = nil) {
        if let b = beat { engine.position = b; transport.beat = b }
        flushSequence()
        engine.position = transport.beat
        engine.play()
        transport.isPlaying = true
    }

    func stop() {
        if recorder != nil { finishAudioRecording(); return }
        if transport.isRecording { finishRecording() }
        engine.stop()
        transport.isPlaying = false
        transport.beat = engine.position
        applyMix()
    }

    func rewind() {
        let wasPlaying = engine.isPlaying
        if wasPlaying { engine.stop() }
        engine.position = project.loopEnabled ? project.loopStart : 0
        transport.beat = engine.position
        if wasPlaying { engine.play() }
    }

    func seek(to beat: Double) {
        let b = max(0, beat)
        engine.position = b
        transport.beat = b
    }

    func toggleRecord() {
        if recorder != nil { finishAudioRecording(); return }
        if transport.isRecording { finishRecording(); transport.isRecording = false; return }
        if selectedTrack?.kind == .audio { startAudioRecording(); return }
        guard selectedTrack != nil else { return }
        transport.isRecording = true
        if !engine.isPlaying { play() }
    }

    func toggleLoop() {
        edit { p in
            p.loopEnabled.toggle()
            // First time on: loop the selected pattern, or the first four bars.
            if p.loopEnabled && p.loopEnd <= p.loopStart {
                if let loc = selectedClipLocation {
                    let c = p.tracks[loc.track].clips[loc.clip]
                    p.loopStart = c.start; p.loopEnd = c.end
                } else { p.loopStart = 0; p.loopEnd = p.beatsPerBar * 4 }
            }
        }
    }

    func setTempo(_ bpm: Double) {
        let v = min(300, max(20, bpm))
        edit { $0.tempo = v }
    }

    func tapTempo() {
        let now = Date()
        tapTimes = tapTimes.filter { now.timeIntervalSince($0) < 2.5 }
        tapTimes.append(now)
        guard tapTimes.count >= 3 else { return }
        let intervals = zip(tapTimes.dropFirst(), tapTimes).map { $0.timeIntervalSince($1) }
        let avg = intervals.reduce(0, +) / Double(intervals.count)
        if avg > 0 { setTempo((60 / avg).rounded()) }
    }

    // MARK: - Live playing & recording

    func liveNoteOn(_ pitch: Int, _ vel: Int) {
        guard let t = selectedTrack else { return }
        engine.noteOn(trackID: t.id, pitch: pitch, velocity: vel)
        if transport.isRecording && engine.isPlaying { recording[pitch] = (engine.position, vel) }
    }

    func liveNoteOff(_ pitch: Int) {
        guard let t = selectedTrack else { return }
        engine.noteOff(trackID: t.id, pitch: pitch)
        guard let on = recording.removeValue(forKey: pitch), transport.isRecording else { return }
        let endBeat = max(engine.position, on.beat + 0.0625)
        addRecordedNote(trackID: t.id, pitch: pitch, start: on.beat, end: endBeat, vel: on.vel)
    }

    private func addRecordedNote(trackID: UUID, pitch: Int, start: Double, end: Double, vel: Int) {
        guard let ti = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let bar = project.beatsPerBar
        var ci = project.tracks[ti].clips.firstIndex { start >= $0.start - 1e-6 && start < $0.end }
        if ci == nil {
            let s = (start / bar).rounded(.down) * bar
            let c = Clip(name: "Recording", start: s, length: bar)
            modify { $0.tracks[ti].clips.append(c) }
            ci = project.tracks[ti].clips.count - 1
        }
        guard let idx = ci else { return }
        modify { p in
            let cs = p.tracks[ti].clips[idx].start
            let n = Note(pitch: pitch, start: start - cs, length: max(0.0625, end - start), velocity: vel)
            p.tracks[ti].clips[idx].notes.append(n)
            p.tracks[ti].clips[idx].fitLengthToNotes(minBeats: bar, quantum: bar)
        }
        selectedClipID = project.tracks[ti].clips[idx].id
    }

    private func finishRecording() {
        guard let t = selectedTrack else { return }
        let now = engine.position
        for (pitch, on) in recording { addRecordedNote(trackID: t.id, pitch: pitch, start: on.beat, end: now, vel: on.vel) }
        recording.removeAll()
        transport.isRecording = false
    }

    // MARK: - Keyboard

    private static let typingMap: [UInt16: Int] = [
        0: 0, 13: 1, 1: 2, 14: 3, 2: 4, 3: 5, 17: 6, 5: 7, 16: 8, 4: 9, 32: 10, 38: 11,
        40: 12, 31: 13, 37: 14, 35: 15, 41: 16, 39: 17,
    ]

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            if let r = NSApp.keyWindow?.firstResponder, r is NSTextView { return event }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false { return event }
            guard NSApp.keyWindow?.identifier?.rawValue == "main" else { return event }
            if event.type == .keyDown {
                if event.keyCode == 49 && !event.isARepeat { self.togglePlay(); return nil }   // space
                if !self.musicalTyping, !event.isARepeat {
                    switch event.charactersIgnoringModifiers {
                    case "r": self.toggleRecord(); return nil
                    case "l": self.toggleLoop(); return nil
                    case "c": self.metronome.toggle(); return nil
                    case "t" where self.selectedAudioClipID != nil && self.bottomPanel == .tune: self.toggleTuneForSelection(); return nil
                    case "\r", "\u{3}": self.rewind(); return nil
                    default: break
                    }
                }
                if self.musicalTyping {
                    if event.charactersIgnoringModifiers == "z" { self.typingOctave = max(0, self.typingOctave - 1); return nil }
                    if event.charactersIgnoringModifiers == "x" { self.typingOctave = min(8, self.typingOctave + 1); return nil }
                    if let off = Self.typingMap[event.keyCode] {
                        if !event.isARepeat {
                            let pitch = (self.typingOctave + 1) * 12 + off
                            self.heldKeys[event.keyCode] = pitch
                            self.liveNoteOn(pitch, 100)
                        }
                        return nil
                    }
                }
            } else if let pitch = self.heldKeys.removeValue(forKey: event.keyCode) {
                self.liveNoteOff(pitch); return nil
            }
            return event
        }
    }

    // MARK: - Files

    /// Brief confirmation shown over the window (imports, installs…).
    func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in if self?.toast == text { self?.toast = nil } }
    }

    private func alert(_ title: String, _ detail: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = detail; a.runModal()
    }

    func captureStates() {
        for ti in project.tracks.indices {
            if var p = project.tracks[ti].instrument.plugin, let d = engine.captureState(of: p.id) {
                p.state = d; project.tracks[ti].instrument.plugin = p
            }
            for si in project.tracks[ti].inserts.indices {
                if let d = engine.captureState(of: project.tracks[ti].inserts[si].id) { project.tracks[ti].inserts[si].state = d }
            }
        }
    }

    func encodeProject() throws -> Data {
        captureStates()
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return try enc.encode(project)
    }

    func newProject() {
        guard confirmDiscard() else { return }
        stop(); PluginWindows.shared.closeAll()
        var p = Project()
        var t = Track(name: "Piano", colorIndex: 0)
        t.clips = [Clip(name: "Pattern 1", start: 0, length: p.beatsPerBar * 4)]
        p.tracks = [t]
        clearRecoveryFile()
        load(p, url: nil)
        lastAutoSave = nil
    }

    private func confirmDiscard() -> Bool {
        guard isDirty else { return true }
        let a = NSAlert()
        a.messageText = "Save changes to “\(project.name)”?"
        a.informativeText = "Your changes will be lost if you don't save them."
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Don't Save"); a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: save(); return !isDirty
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func load(_ p: Project, url: URL?) {
        project = p; fileURL = url; isDirty = false
        undoStack.removeAll(); redoStack.removeAll()
        selectedTrackID = p.tracks.first?.id
        selectedClipID = p.tracks.first?.clips.first?.id
        selectedNoteIDs = []
        transport.beat = 0; engine.position = 0
        engine.syncTracks(p.tracks)
        applyMix()
        sequenceDirty = true; flushSequence()
        restoreAudioAssets(for: p.tracks, near: url)
    }

    func save() {
        if let url = fileURL { write(to: url) } else { saveAs() }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "macband") ?? .json]
        panel.nameFieldStringValue = project.name + ".macband"
        panel.title = "Export Band Project"
        if panel.runModal() == .OK, let url = panel.url {
            project.name = url.deletingPathExtension().lastPathComponent
            write(to: url)
        }
    }

    func write(to url: URL) {
        do { try encodeProject().write(to: url, options: .atomic); fileURL = url; isDirty = false; saveAudioAssets(for: url); lastAutoSave = nil; clearRecoveryFile() }
        catch { errorMessage = "Couldn't save: \(error.localizedDescription)" }
    }

    func openProject() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "macband") ?? .json]
        panel.title = "Open Band Project"
        if panel.runModal() == .OK, let url = panel.url { openProject(url: url) }
    }

    func openProject(url: URL) {
        do {
            let p = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
            stop(); PluginWindows.shared.closeAll()
            load(p, url: url)
        } catch { errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)" }
    }

    /// Import a band project by merging its tracks into the current project.
    func importBandProject() {
        let panel = NSOpenPanel()
        // .macband is ours; .json and GarageBand's .band are allowed so picking them gives a clear answer instead of a greyed-out file
        panel.allowedContentTypes = ["macband", "json", "band"].compactMap { UTType(filenameExtension: $0) }
        panel.title = "Import Band Project"
        if panel.runModal() == .OK, let url = panel.url { importBandProject(url: url) }
    }

    func importBandProject(url: URL) {
        if url.pathExtension.lowercased() == "band" {
            errorMessage = "“\(url.lastPathComponent)” is a GarageBand project, which uses Apple's private format and can't be imported directly.\n\nIn GarageBand, drag a track's region to the Finder (or use File ▸ Export) to save it as a MIDI file, then use Import ▸ MIDI File here."
            return
        }
        do {
            let other = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
            pushUndo()
            let wasEmpty = project.tracks.allSatisfy { $0.clips.allSatisfy { $0.notes.isEmpty } }
            let tracks = other.tracks.map { t -> Track in
                var t = t; t.id = UUID()
                t.colorIndex = project.tracks.count + t.colorIndex
                if var p = t.instrument.plugin { p.id = UUID(); t.instrument.plugin = p }
                t.inserts = t.inserts.map { var p = $0; p.id = UUID(); return p }
                return t
            }
            guard !tracks.isEmpty else { errorMessage = "“\(url.lastPathComponent)” doesn't contain any tracks."; return }
            restoreAudioAssets(for: tracks, near: url)
            modify {
                if wasEmpty {
                    $0.tempo = other.tempo; $0.tempoPoints = other.tempoPoints; $0.timeSigNum = other.timeSigNum; $0.timeSigDen = other.timeSigDen
                    $0.tracks.removeAll { $0.clips.allSatisfy { $0.notes.isEmpty } && $0.instrument.plugin == nil }   // drop the empty starter track
                }
                $0.tracks.append(contentsOf: tracks)
            }
            selectedTrackID = tracks.first?.id
            selectedClipID = tracks.first?.clips.first?.id
            seek(to: 0)
            showToast("Imported \(tracks.count) track\(tracks.count == 1 ? "" : "s") from “\(url.deletingPathExtension().lastPathComponent)”")
        } catch { errorMessage = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)" }
    }

    func importMIDI() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .midi, UTType(filenameExtension: "midi") ?? .midi]
        panel.title = "Import MIDI File"
        if panel.runModal() == .OK, let url = panel.url { importMIDI(url: url) }
    }

    /// What to do with a MIDI file's tempo changes and time signature when the project already has music in it.
    enum TempoChoice { case ask, useFile, keepProject }

    func importMIDI(url: URL, tempo choice: TempoChoice = .ask) {
        do {
            let imp = try MIDIFile.parse(Data(contentsOf: url))
            guard !imp.tracks.isEmpty else { errorMessage = "That MIDI file doesn't contain any notes."; return }
            let name = url.deletingPathExtension().lastPathComponent
            let wasEmpty = project.tracks.allSatisfy { $0.clips.allSatisfy { $0.notes.isEmpty } }
            // An empty project simply takes the file's tempo map. Otherwise the file's timing is only used if asked for,
            // so importing a second file doesn't silently rewrite the first one's tempo.
            var useFileTiming = wasEmpty
            let differs = !imp.tempoPoints.isEmpty || abs(imp.tempo - project.tempo) > 0.01
                || imp.timeSigNum != project.timeSigNum || imp.timeSigDen != project.timeSigDen
            if !wasEmpty && differs {
                switch choice {
                case .useFile: useFileTiming = true
                case .keepProject: useFileTiming = false
                case .ask: useFileTiming = askToUseFileTempo(imp, fileName: name)
                }
            }
            pushUndo()
            var bar = project.beatsPerBar
            if useFileTiming { bar = Double(imp.timeSigNum) * 4.0 / Double(imp.timeSigDen) }
            let tracks = MIDIFile.makeTracks(imp, beatsPerBar: bar, firstColor: project.tracks.count)
            modify {
                if wasEmpty {
                    $0.tracks.removeAll { $0.clips.allSatisfy { $0.notes.isEmpty } }
                    $0.name = name
                }
                if useFileTiming {
                    $0.tempo = imp.tempo; $0.tempoPoints = imp.tempoPoints
                    $0.timeSigNum = imp.timeSigNum; $0.timeSigDen = imp.timeSigDen
                }
                $0.tracks.append(contentsOf: tracks)
            }
            selectedTrackID = tracks.first?.id
            selectedClipID = tracks.first?.clips.first?.id
            seek(to: 0)
            var msg = "Imported \(tracks.count) track\(tracks.count == 1 ? "" : "s") from “\(name)”"
            if useFileTiming && !imp.tempoPoints.isEmpty { msg += " with \(imp.tempoPoints.count) tempo change\(imp.tempoPoints.count == 1 ? "" : "s")" }
            else if !useFileTiming && differs { msg += " (kept the project's tempo)" }
            if imp.sustainedNotes > 0 { msg += " · sustain pedal held \(imp.sustainedNotes) notes" }
            showToast(msg)
        } catch { errorMessage = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)" }
    }

    private func askToUseFileTempo(_ imp: MIDIFile.Imported, fileName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Use the tempo from “\(fileName)”?"
        var detail = "The file starts at \(String(format: "%g", imp.tempo)) BPM"
        if !imp.tempoPoints.isEmpty { detail += " and has \(imp.tempoPoints.count) tempo change\(imp.tempoPoints.count == 1 ? "" : "s")" }
        detail += " in \(imp.timeSigNum)/\(imp.timeSigDen). This project is at \(String(format: "%g", project.tempo)) BPM"
        detail += project.tempoPoints.isEmpty ? "." : " with its own tempo changes."
        detail += "\n\nUsing the file's tempo replaces this project's tempo map; the notes already here keep their positions in bars and beats."
        alert.informativeText = detail
        alert.addButton(withTitle: "Use File's Tempo")
        alert.addButton(withTitle: "Keep Project Tempo")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func exportMIDI() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .midi]
        panel.nameFieldStringValue = project.name + ".mid"
        panel.title = "Export MIDI File"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try MIDIFile.build(project, forExport: true).write(to: url, options: .atomic) }
        catch { errorMessage = "Couldn't export: \(error.localizedDescription)" }
    }

    func exportAudio() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = project.name + ".wav"
        panel.title = "Export Audio (WAV)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        stop()
        busyMessage = "Rendering audio…"
        let proj = project
        // Offline rendering drives the live engine, so run it on the main thread after the overlay appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            do {
                try self.engine.bounce(proj, to: url) { _ in }
                self.busyMessage = nil
                self.sequenceDirty = true; self.flushSequence()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self.busyMessage = nil
                self.errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func handleDrop(_ urls: [URL]) {
        for u in urls {
            switch u.pathExtension.lowercased() {
            case "mid", "midi": importMIDI(url: u)
            case "macband": if project.tracks.isEmpty || !isDirty { openProject(url: u) } else { importBandProject(url: u) }
            case "wav", "wave", "aif", "aiff", "mp3", "m4a", "caf", "flac", "aac", "ogg", "mp4": importAudio(url: u)
            case "component", "vst3", "vst": installPlugins([u])
            default: break
            }
        }
    }

    func installPlugins(_ urls: [URL]) {
        let results = library.install(urls) { name in
            let a = NSAlert(); a.messageText = "Replace “\(name)”?"
            a.informativeText = "A plugin with this name is already installed. The old copy will be moved to the Trash."
            a.addButton(withTitle: "Replace"); a.addButton(withTitle: "Skip")
            return a.runModal() == .alertFirstButtonReturn
        }
        var failures: [String] = []
        for r in results { if case .failed(let m) = r { failures.append(m) } }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        // AU registration can lag behind the copy by a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.library.rescan() }
    }
}
