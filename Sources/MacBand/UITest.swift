import AppKit
import Foundation

/// Drives the real AppKit views with synthesized mouse/key events and checks the project afterwards
/// (run with `MacBand --uitest`).
@MainActor enum UITest {
    static var failures = 0

    /// The sustain pedal (CC 64) in a MIDI file keeps notes sounding after their keys are released.
    static func sustainImport() {
        print("-- sustain pedal on MIDI import")
        func vlq(_ n: Int) -> [UInt8] {
            var out = [UInt8(n & 0x7F)]; var v = n >> 7
            while v > 0 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
            return out.reversed()
        }
        let events: [(Int, [UInt8])] = [
            (0, [0xB0, 64, 127]), (0, [0x90, 60, 100]), (480, [0x80, 60, 0]), (480, [0x90, 64, 100]), (960, [0x80, 64, 0]),
            (1920, [0xB0, 64, 0]),
            (2400, [0x90, 67, 100]), (2880, [0x80, 67, 0]),
            (3840, [0xB0, 64, 127]), (3840, [0x90, 60, 100]), (4320, [0x80, 60, 0]),
            (4800, [0x90, 60, 100]), (5280, [0x80, 60, 0]),
            (5760, [0xB0, 64, 0]),
        ]
        var track: [UInt8] = []
        var last = 0
        for (tick, bytes) in events { track += vlq(tick - last) + bytes; last = tick }
        track += [0x00, 0xFF, 0x2F, 0x00]
        var file: [UInt8] = Array("MThd".utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0]
        file += Array("MTrk".utf8) + [UInt8((track.count >> 24) & 0xFF), UInt8((track.count >> 16) & 0xFF), UInt8((track.count >> 8) & 0xFF), UInt8(track.count & 0xFF)] + track
        guard let imp = try? MIDIFile.parse(Data(file)), let notes = imp.tracks.first?.notes.sorted(by: { $0.start < $1.start }) else { check(false, "the test file parses"); return }
        let lengths = notes.map { $0.length }
        check(lengths == [4, 3, 1, 2, 2], "notes held by the pedal last until it lifts (lengths \(lengths))")
        check(imp.sustainedNotes == 4, "four notes were lengthened (\(imp.sustainedNotes))")
        check(notes[2].length == 1, "a note played with the pedal up keeps its length")
        check(notes[3].length == 2, "re-striking a key cuts the held note off at the new strike")
    }

    /// SwiftUI owns each view's state object and frees it when a tab is switched away, while the AppKit view can outlive it for a
    /// moment and keeps getting playhead updates during playback. That used to abort with "unowned reference" in the piano roll.
    static func orphanedViews(_ s: Session) {
        print("-- views outliving their state")
        // the playhead code only runs when a pattern is selected
        if s.selectedClipLocation == nil, let t = s.project.tracks.first, let c = t.clips.first { s.selectedTrackID = t.id; s.selectedClipID = c.id }
        var roll: PianoRollView?, lane: LaneView?, timeline: TimelineView?
        do {
            // each view gets a state object of its own, as when SwiftUI creates one per tab
            roll = PianoRollView(session: s, state: RollState()); roll!.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
            lane = LaneView(session: s, state: RollState()); lane!.frame = NSRect(x: 0, y: 0, width: 800, height: 90)
            timeline = TimelineView(session: s, state: ArrangementState()); timeline!.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        }                                                    // the state objects are released here
        s.transport.beat = 2.5
        s.transport.beat = 3.25
        SelfTest.pump(0.1)
        roll!.needsDisplay = true; lane!.needsDisplay = true; timeline!.needsDisplay = true
        SelfTest.pump(0.1)
        check(roll != nil && lane != nil && timeline != nil, "piano roll, lane and timeline survive their state being released")
        s.transport.beat = 0
    }

    /// MIDI import must carry the file's tempo changes across, including into a project that already has music.
    static func tempoImport() {
        print("-- tempo changes on MIDI import")
        var src = Project()
        src.tempo = 100
        src.tempoPoints = [TempoPoint(beat: 4, bpm: 140), TempoPoint(beat: 8, bpm: 80), TempoPoint(beat: 12, bpm: 180)]
        var srcTrack = Track(name: "Lead", colorIndex: 0)
        var srcClip = Clip(name: "A", start: 0, length: 16)
        for i in 0..<16 { srcClip.notes.append(Note(pitch: 60 + i % 5, start: Double(i), length: 0.5)) }
        srcTrack.clips = [srcClip]; src.tracks = [srcTrack]
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-tempo-import.mid")
        try! MIDIFile.build(src, forExport: true).write(to: url)

        func fresh() -> Session { let s = Session(); SelfTest.pump(0.2); return s }
        func points(_ s: Session) -> String {
            let sorted = s.project.tempoPoints.sorted { $0.beat < $1.beat }
            return sorted.map { p in "\(Int(p.bpm.rounded()))@\(Int(p.beat.rounded()))" }.joined(separator: " ")
        }
        let want = "140@4 80@8 180@12"

        let s1 = fresh(); s1.importMIDI(url: url)
        let t1 = Int(s1.project.tempo.rounded()), p1 = points(s1)
        check(t1 == 100 && p1 == want, "empty project: the file's tempo and 3 changes come across (\(t1) BPM, \(p1))")

        let s2 = fresh(); s2.importMIDI(url: url, tempo: .useFile)
        s2.project.tempoPoints = []; s2.project.tempo = 120          // pretend the user changed the tempo meanwhile
        s2.importMIDI(url: url, tempo: .useFile)
        check(points(s2) == want && s2.project.tracks.count == 2, "a second import into a project with music brings the tempo map across with 'use file'")

        var other = Project(); other.tempo = 90
        var ot = Track(name: "Existing", colorIndex: 0)
        var oc = Clip(name: "E", start: 0, length: 8)
        oc.notes = [Note(pitch: 60, start: 0, length: 1)]
        ot.clips = [oc]; other.tracks = [ot]

        let s3 = fresh(); s3.project = other; s3.importMIDI(url: url, tempo: .keepProject)
        check(s3.project.tempo == 90 && s3.project.tempoPoints.isEmpty && s3.project.tracks.count == 2, "keep project: the project's own tempo isn't changed")

        let s4 = fresh(); s4.project = other; s4.importMIDI(url: url, tempo: .useFile)
        let t4 = Int(s4.project.tempo.rounded())
        check(t4 == 100 && points(s4) == want, "use file: a project with its own tempo takes the file's tempo map")

        // the imported tempo map is what plays: beats 0–4 at 100, 4–8 at 140, 8–12 at 80
        let secs = s4.project.seconds(atBeat: 12)
        let expected: Double = 240.0 / 100.0 + 240.0 / 140.0 + 240.0 / 80.0
        check(abs(secs - expected) < 1e-3, String(format: "beat 12 lands at %.3f s (expected %.3f)", secs, expected))
        try? FileManager.default.removeItem(at: url)
    }
    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  ok   " : "  FAIL ", what)
        if !ok { failures += 1 }
    }

    static func event(_ type: NSEvent.EventType, _ view: NSView, _ p: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
        let win = view.window!
        return NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    static func click(_ v: NSView, _ p: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        v.mouseDown(with: event(.leftMouseDown, v, p, flags: flags, clicks: clicks))
        v.mouseUp(with: event(.leftMouseUp, v, p, flags: flags, clicks: clicks))
    }
    static func drag(_ v: NSView, from a: CGPoint, to b: CGPoint, flags: NSEvent.ModifierFlags = []) {
        v.mouseDown(with: event(.leftMouseDown, v, a, flags: flags))
        for i in 1...6 {
            let t = CGFloat(i) / 6
            v.mouseDragged(with: event(.leftMouseDragged, v, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), flags: flags))
        }
        v.mouseUp(with: event(.leftMouseUp, v, b, flags: flags))
    }
    static func key(_ v: NSView, _ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: v.window!.windowNumber,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        v.keyDown(with: e)
    }

    static func run() {
        _ = NSApplication.shared
        print("== MacBand UI test ==")
        let s = Session()
        UITest.pumpBrief()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        let rs = RollState(); rs.topPitch = 72; rs.ppb = 100; rs.rowH = 16
        let roll = PianoRollView(session: s, state: rs)
        roll.frame = NSRect(x: 0, y: 0, width: 1000, height: 340)
        let lane = LaneView(session: s, state: rs)
        lane.frame = NSRect(x: 0, y: 340, width: 1000, height: 92)
        let a = ArrangementState()
        let tl = TimelineView(session: s, state: a)
        tl.frame = NSRect(x: 0, y: 440, width: 1000, height: 200)
        for v in [roll, lane, tl] { win.contentView!.addSubview(v) }
        win.contentView!.layoutSubtreeIfNeeded()

        let keysW = RollState.keysW, rulerH = RollState.rulerH
        func rx(_ beat: Double) -> CGFloat { keysW + CGFloat(beat) * rs.ppb }
        func ry(_ pitch: Int) -> CGFloat { rulerH + (rs.topPitch - CGFloat(pitch)) * rs.rowH + rs.rowH / 2 }
        func notes() -> [Note] { s.selectedClipLocation.map { s.project.tracks[$0.track].clips[$0.clip].notes } ?? [] }

        print("piano roll")
        s.snap = 0.25
        click(roll, CGPoint(x: rx(1) + 3, y: ry(60)))
        check(notes().count == 1, "click draws a note")
        check(notes().first?.pitch == 60 && abs((notes().first?.start ?? -1) - 1) < 1e-6, "note lands on beat 1, pitch C4")
        drag(roll, from: CGPoint(x: rx(1) + 3, y: ry(64)), to: CGPoint(x: rx(3) + 3, y: ry(64)))
        check(notes().count == 2, "drag draws a second note")
        check(abs((notes().last?.length ?? 0) - 2) < 0.3, "drag stretches the new note to ~2 beats (\(notes().last?.length ?? 0))")
        let firstID = notes()[0].id
        // move first note up 2 semitones and right 1 beat
        drag(roll, from: CGPoint(x: rx(1.25), y: ry(60)), to: CGPoint(x: rx(2.25), y: ry(62)))
        let moved = notes().first { $0.id == firstID }!
        check(moved.pitch == 62 && abs(moved.start - 2) < 0.01, "dragging a note moves it (pitch \(moved.pitch), start \(moved.start))")
        // resize via right edge
        let n0 = notes().first { $0.id == firstID }!
        drag(roll, from: CGPoint(x: rx(n0.end) - 2, y: ry(62)), to: CGPoint(x: rx(n0.end) + 98, y: ry(62)))
        let resized = notes().first { $0.id == firstID }!
        check(resized.length > n0.length + 0.5, "dragging the right edge resizes (\(n0.length) → \(resized.length))")
        // slide mode
        s.slideMode = true
        click(roll, CGPoint(x: rx(5) + 3, y: ry(67)))
        s.slideMode = false
        check(notes().last?.isSlide == true, "slide mode creates a slide note")
        // toggle slide with S
        s.selectedNoteIDs = [firstID]
        key(roll, "s", code: 1)
        check(notes().first { $0.id == firstID }?.isSlide == true, "S toggles slide on the selection")
        key(roll, "s", code: 1)
        // undo
        let before = notes().count
        s.selectedNoteIDs = [firstID]
        key(roll, "\u{7F}", code: 51)
        check(notes().count == before - 1, "Delete removes selected note")
        s.undo()
        check(notes().count == before, "Undo restores it")
        // right click delete
        let target = notes().first { $0.id == firstID }!
        roll.rightMouseDown(with: event(.rightMouseDown, roll, CGPoint(x: rx(target.start) + 4, y: ry(target.pitch))))
        check(notes().count == before - 1, "right-click deletes a note")
        s.undo()
        // marquee select
        s.tool = .select
        drag(roll, from: CGPoint(x: rx(0.2), y: ry(70)), to: CGPoint(x: rx(8), y: ry(55)))
        check(s.selectedNoteIDs.count == notes().count, "select tool marquee selects all (\(s.selectedNoteIDs.count)/\(notes().count))")
        s.tool = .draw
        // copy/paste/duplicate
        key(roll, "d", code: 2, flags: .command)
        check(notes().count == before * 2, "⌘D duplicates the selection")
        s.undo()
        // clip auto-extends
        click(roll, CGPoint(x: rx(20), y: ry(70)))
        check((s.selectedClipLocation.map { s.project.tracks[$0.track].clips[$0.clip].length } ?? 0) >= 20, "drawing past the end extends the pattern")

        print("velocity lane")
        s.lane = .velocity
        let vn = notes().first!
        let vx = keysW + CGFloat(vn.start) * rs.ppb + 1
        click(lane, CGPoint(x: vx, y: 12))
        check((notes().first { $0.id == vn.id }?.velocity ?? 0) > 110, "clicking high in the lane sets high velocity")
        click(lane, CGPoint(x: vx, y: 80))
        check((notes().first { $0.id == vn.id }?.velocity ?? 127) < 30, "clicking low sets low velocity")

        print("volume automation")
        s.lane = .volume
        let ti = s.selectedClipLocation!
        click(lane, CGPoint(x: rx(0) + 10, y: 40))
        click(lane, CGPoint(x: rx(4), y: 70))
        drag(lane, from: CGPoint(x: rx(8), y: 20), to: CGPoint(x: rx(8), y: 20))
        var vol = s.project.tracks[ti.track].clips[ti.clip].volume
        check(vol.count == 3, "clicks add automation points (\(vol.count))")
        check(zip(vol, vol.dropFirst()).allSatisfy { $0.beat <= $1.beat }, "points stay sorted by time")
        check(Automation.value(vol, at: 2) != nil, "automation interpolates")
        let dragged = vol[1]
        drag(lane, from: CGPoint(x: rx(dragged.beat), y: lane.bounds.height - 8 - CGFloat(dragged.value) * (lane.bounds.height - 16)), to: CGPoint(x: rx(5), y: 12))
        vol = s.project.tracks[ti.track].clips[ti.clip].volume
        check(vol.contains { abs($0.beat - 5) < 0.3 && $0.value > 0.85 }, "dragging a point moves it")
        lane.rightMouseDown(with: event(.rightMouseDown, lane, CGPoint(x: rx(5), y: lane.bounds.height - 8 - CGFloat(vol.first { abs($0.beat - 5) < 0.3 }!.value) * (lane.bounds.height - 16))))
        check(s.project.tracks[ti.track].clips[ti.clip].volume.count == 2, "right-click deletes a point")
        // gain applies to the mixer while "playing" at beat 4
        s.engine.applyMix(s.project, beat: s.selectedClipLocation.map { s.project.tracks[$0.track].clips[$0.clip].start + 4 })
        print("   (mixer gain at beat 4 =", s.engine.strips[s.project.tracks[ti.track].id]?.mixer.outputVolume ?? -1, ")")

        print("timeline")
        let headerH = a.headerH
        // tempo lane: click adds a point
        click(tl, CGPoint(x: 4 * a.ppb * 1 + 4 * 0 + (CGFloat(4) * a.ppb), y: ArrangementState.rulerH + 20))
        check(s.project.tempoPoints.count == 1, "clicking the tempo lane adds a tempo change (\(s.project.tempoPoints.count))")
        let tp0 = s.project.tempoPoints[0]
        let ty = ArrangementState.rulerH + 20
        drag(tl, from: CGPoint(x: CGFloat(tp0.beat) * a.ppb, y: ty), to: CGPoint(x: CGFloat(tp0.beat) * a.ppb, y: ty - 18))
        check((s.project.tempoPoints.first?.bpm ?? 0) != tp0.bpm, "dragging a tempo point changes bpm (\(tp0.bpm) → \(s.project.tempoPoints.first?.bpm ?? 0))")
        let secs = s.project.seconds(atBeat: 16)
        check(secs > 0 && secs != 16 * 60 / 120, "tempo map changes elapsed time (\(secs)s for 16 beats)")
        // clips: double-click empty area creates, drag moves
        let rowY = headerH + a.rowH * 0.5
        let clipsBefore = s.project.tracks[0].clips.count
        click(tl, CGPoint(x: 80 * a.ppb, y: rowY), clicks: 2)
        check(s.project.tracks[0].clips.count == clipsBefore + 1, "double-click on empty track space creates a pattern")
        let c0 = s.project.tracks[0].clips[0]
        drag(tl, from: CGPoint(x: (CGFloat(c0.start) + 1) * a.ppb, y: rowY + 20), to: CGPoint(x: (CGFloat(c0.start) + 9) * a.ppb, y: rowY + 20))
        check(abs((s.project.tracks[0].clips.first { $0.id == c0.id }?.start ?? 0) - 8) < 1.01, "dragging a pattern moves it")
        let cc = s.project.tracks[0].clips.first { $0.id == c0.id }!
        drag(tl, from: CGPoint(x: CGFloat(cc.end) * a.ppb - 3, y: rowY + 20), to: CGPoint(x: (CGFloat(cc.end) + 4) * a.ppb - 3, y: rowY + 20))
        check((s.project.tracks[0].clips.first { $0.id == c0.id }?.length ?? 0) > cc.length + 3, "dragging the right edge resizes a pattern")
        // track height: ⌘-scroll / slider make tracks taller, hit-testing follows
        let startH = a.rowH
        tl.resizeTracks(by: 1.5, anchorY: headerH + 10)
        check(abs(a.rowH - startH * 1.5) < 0.01, "⌘-scroll makes the tracks taller (\(startH) → \(a.rowH))")
        tl.resizeTracks(by: 100, anchorY: headerH + 10)
        check(a.rowH == ArrangementState.maxRowH, "…up to a maximum (\(a.rowH))")
        tl.resizeTracks(by: 0.001, anchorY: headerH + 10)
        check(a.rowH == ArrangementState.minRowH, "…and down to a minimum (\(a.rowH))")
        a.rowH = 120
        let addedTrack = s.project.tracks.count < 2
        if addedTrack { s.addTrack(name: "Height test") }
        let firstId = s.project.tracks[0].id
        let secondId = s.project.tracks[1].id
        click(tl, CGPoint(x: 200 * a.ppb, y: headerH + 120 * 1.5))
        check(s.selectedTrackID == secondId, "with taller tracks a click lands on the right track")
        click(tl, CGPoint(x: 200 * a.ppb, y: headerH + 60))
        check(s.selectedTrackID == firstId, "…and the first track is still hit near the top")
        if addedTrack { s.deleteTrack(secondId); s.selectedTrackID = firstId }
        a.rowH = ArrangementState.defaultRowH; a.scrollY = 0
        // loop strip
        drag(tl, from: CGPoint(x: 2 * a.ppb, y: 6), to: CGPoint(x: 6 * a.ppb, y: 6))
        check(s.project.loopEnabled && abs(s.project.loopStart - 2) < 0.1 && abs(s.project.loopEnd - 6) < 0.1, "dragging the loop strip sets the loop")
        // ruler seeks
        click(tl, CGPoint(x: 10 * a.ppb, y: ArrangementState.loopH + 10))
        check(abs(s.transport.beat - 10) < 0.3, "clicking the ruler moves the playhead (\(s.transport.beat))")

        print("tracks & files")
        s.addTrack(instrument: InstrumentSpec(gmProgram: 33), name: "Bass")
        check(s.project.tracks.count == 2, "add track")
        // export + import MIDI round trip
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("uitest.mid")
        try? MIDIFile.build(s.project, forExport: true).write(to: url)
        let back = try? MIDIFile.parse(Data(contentsOf: url))
        let want = s.project.tracks.flatMap { $0.clips.flatMap { $0.notes } }.filter { !$0.isSlide }.count
        check((back?.tracks.reduce(0) { $0 + $1.notes.count } ?? -1) >= want - 1, "MIDI export → import keeps the notes (\(back?.tracks.reduce(0) { $0 + $1.notes.count } ?? -1) of \(want))")
        // project round trip
        let pj = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("uitest.macband")
        let data = try! JSONEncoder().encode(s.project)
        try! data.write(to: pj)
        let p2 = try? JSONDecoder().decode(Project.self, from: Data(contentsOf: pj))
        check(p2?.tracks.count == s.project.tracks.count && p2?.tempoPoints.count == s.project.tempoPoints.count, "band project save → load round trip")

        tempoImport()
        sustainImport()
        orphanedViews(s)
        tuneCanvas(s)
        print(failures == 0 ? "ALL UI CHECKS PASSED" : "\(failures) UI CHECK(S) FAILED")
    }
    /// `--importtest file.mid|file.macband`: import into a fresh session, then render and report whether it makes sound.
    static func importTest(_ path: String) {
        _ = NSApplication.shared
        let s = Session()
        let url = URL(fileURLWithPath: path)
        func pump(_ sec: Double, until: () -> Bool = { false }) { let e = Date().addingTimeInterval(sec); while Date() < e && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }
        pump(1)
        let ext = url.pathExtension.lowercased()
        // `--importtest file.mid --after other.mid` first fills the project with another file, so the import
        // below happens into a project that already has music (and takes the file's tempo).
        if let i = CommandLine.arguments.firstIndex(of: "--after"), i + 1 < CommandLine.arguments.count {
            s.importMIDI(url: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            pump(0.2)
            print("project before the import: tempo", s.project.tempo, "| tracks", s.project.tracks.count)
        }
        if ext == "mid" || ext == "midi" { s.importMIDI(url: url, tempo: .useFile) } else { s.importBandProject(url: url) }
        pump(0.2)
        let p = s.project
        print("tracks:", p.tracks.count, "tempo:", p.tempo, "tempo changes:", p.tempoPoints.count, "timesig:", p.timeSigNum, "/", p.timeSigDen, "error:", s.errorMessage ?? "none")
        for t in p.tracks.prefix(6) { print("  ", t.name, "| clips:", t.clips.map { "\($0.start)+\($0.length) (\($0.notes.count) notes)" }.joined(separator: ", ")) }
        let totalNotes = p.tracks.reduce(0) { $0 + $1.clips.reduce(0) { $0 + $1.notes.count } }
        print("total notes:", totalNotes, "| last clip end (beats):", p.contentEnd)
        pump(30) { s.engine.strips.values.allSatisfy { !$0.loading && $0.instrument != nil } && s.engine.strips.count == p.tracks.count }
        print("instruments loaded:", s.engine.strips.values.filter { $0.instrument != nil }.count, "of", p.tracks.count, "| strips:", s.engine.strips.count)
        s.flushSequence()
        print("sequencer tracks:", s.engine.sequencer.tracks.count, "(expected \(p.tracks.count + 2) incl. conductor + click) | error after reload:", s.errorMessage ?? "none")
        let wired = s.engine.sequencer.tracks.filter { $0.destinationAudioUnit != nil }.count
        print("tracks with a destination:", wired)
        for t in p.tracks.prefix(8) {
            let pts = t.clips.first?.volume ?? []
            print("   vol", t.name, "| points:", pts.count, "| first:", pts.prefix(3).map { String(format: "%.2f@%.1f", $0.value, $0.beat) }.joined(separator: " "), "| fader:", t.volume, "| mute:", t.mute, "| gm:", t.instrument.gmProgram, "drums:", t.instrument.isDrums)
        }
        for t in p.tracks.prefix(6) {
            let ns = t.clips.flatMap { $0.notes }
            guard !ns.isEmpty else { continue }
            let vel = ns.map { $0.velocity }, len = ns.map { $0.length }, pit = ns.map { $0.pitch }
            print(String(format: "   notes %@ | vel %d–%d | len %.3f–%.2f (avg %.3f) | pitch %d–%d | first start %.2f", t.name, vel.min()!, vel.max()!, len.min()!, len.max()!, len.reduce(0, +) / Double(len.count), pit.min()!, pit.max()!, ns.map { $0.start }.min()! + (t.clips.first?.start ?? 0)))
        }
        if let i = CommandLine.arguments.firstIndex(of: "--only"), i + 1 < CommandLine.arguments.count {
            let idx = CommandLine.arguments[i + 1].split(separator: ",").compactMap { Int($0) }
            let full = s.project
            s.modify { $0.tracks = idx.compactMap { $0 < full.tracks.count ? full.tracks[$0] : nil } }
            pump(4); s.flushSequence()
            print("only tracks \(idx): sequencer tracks =", s.engine.sequencer.tracks.count, "wired =", s.engine.sequencer.tracks.filter { $0.destinationAudioUnit != nil }.count)
        }
        if CommandLine.arguments.contains("--pertrack") {
            let full = s.project
            for (i, t) in full.tracks.enumerated().prefix(14) {
                s.modify { $0.tracks = [t] }
                pump(3); s.flushSequence()
                let o = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pt.wav")
                try? FileManager.default.removeItem(at: o)
                var q = s.project; q.loopEnabled = false
                try? s.engine.bounce(q, to: o) { _ in }
                let r = SelfTest.analyze(o)
                print(String(format: "   solo %2d %-22@ peak rms %.4f  (prog %d drums %d, %d notes)", i, t.name as NSString, r.rms.max() ?? 0, t.instrument.gmProgram, t.instrument.isDrums ? 1 : 0, t.clips.flatMap { $0.notes }.count))
            }
            s.modify { $0.tracks = full.tracks }
        }
        if CommandLine.arguments.contains("--graph") {
            let eng = s.engine.engine
            print("engine running:", eng.isRunning, "| attached nodes (approx):", eng.attachedNodes.count, "| main mixer inputs:", eng.outputConnectionPoints(for: eng.mainMixerNode, outputBus: 0).count)
            for t in s.project.tracks.prefix(4) {
                guard let st = s.engine.strips[t.id], let inst = st.instrument else { print("  strip missing instrument:", t.name); continue }
                let cp = eng.outputConnectionPoints(for: inst, outputBus: 0)
                let mcp = eng.outputConnectionPoints(for: st.mixer, outputBus: 0)
                print("  GRAPH \(t.name): instrument→mixer=\(cp.count) mixer→master=\(mcp.count)")
            }
        }
        if CommandLine.arguments.contains("--noteprobe") {
            func probe(_ label: String, _ idx: Int) {
                let t = s.project.tracks[idx]
                s.engine.masterPeak = 0
                s.engine.noteOn(trackID: t.id, pitch: 64, velocity: 110)
                pump(0.5)
                let pk = s.engine.masterPeak
                s.engine.noteOff(trackID: t.id, pitch: 64)
                pump(0.3)
                print(String(format: "  PROBE %@ — track %d (%@): master peak %.4f  mixer vol %.2f", label, idx, t.name, pk, s.engine.strips[t.id]?.mixer.outputVolume ?? -1))
            }
            probe("original strip (vibraphone)", 6)
            probe("original strip (vibraphone)", 7)
            s.modify { $0.tracks[7].instrument.gmProgram = 12 }      // forces track 7's instrument to be rebuilt (marimba)
            pump(4)
            probe("rebuilt strip  (marimba)   ", 7)
            probe("original strip (vibraphone)", 6)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--saveband"), i + 1 < CommandLine.arguments.count {
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            try? enc.encode(s.project).write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            print("saved band project to", CommandLine.arguments[i + 1])
        }
        let nilIdx = s.engine.sequencer.tracks.enumerated().filter { $0.element.destinationAudioUnit == nil }.map { $0.offset }
        print("sequencer track indices without destination:", nilIdx)
        if let i = CommandLine.arguments.firstIndex(of: "--first"), i + 1 < CommandLine.arguments.count, let n = Int(CommandLine.arguments[i + 1]) {
            s.modify { $0.tracks = Array($0.tracks.prefix(n)) }
            pump(5); s.flushSequence()
            print("truncated to first \(n) tracks")
        }
        if CommandLine.arguments.contains("--nocc") { s.modify { for i in $0.tracks.indices { for j in $0.tracks[i].clips.indices { $0.tracks[i].clips[j].volume = [] } } } }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("importtest.wav")
        try? FileManager.default.removeItem(at: out)
        var q = s.project; q.loopEnabled = false
        do { try s.engine.bounce(q, to: out) { _ in } } catch { print("bounce failed:", error); return }
        let r = SelfTest.analyze(out)
        if CommandLine.arguments.contains("--twice") {
            for attempt in 2...3 {
                try? FileManager.default.removeItem(at: out)
                try? s.engine.bounce(q, to: out) { _ in }
                let r2 = SelfTest.analyze(out)
                print(String(format: "   render #%d: peak rms %.4f", attempt, r2.rms.max() ?? 0))
            }
        }
        print(String(format: "rendered %.1fs, peak rms %.3f", Double(r.rms.count) / 20, r.rms.max() ?? 0), (r.rms.max() ?? 0) > 0.002 ? "→ SOUND" : "→ SILENT")
        // and the live path used by the Play button
        s.play(from: 0)
        pump(2.5)
        print("live play: engine.isPlaying =", s.engine.isPlaying, " position =", String(format: "%.2f", s.engine.position), " master peak =", String(format: "%.3f", s.engine.masterPeak))
        s.stop()
    }
    /// `--manytracks N`: N identical piano tracks added in one go (like a big MIDI import); does it still make sound?
    static func manyTracks(_ n: Int) {
        _ = NSApplication.shared
        let s = Session()
        func pump(_ sec: Double, until: () -> Bool = { false }) { let e = Date().addingTimeInterval(sec); while Date() < e && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }
        pump(1)
        var tracks: [Track] = []
        for i in 0..<n {
            var t = Track(name: "T\(i)", colorIndex: i)
            t.instrument = InstrumentSpec(gmProgram: (i * 3) % 40)
            var c = Clip(name: "c", start: 0, length: 8)
            c.notes = (0..<8).map { Note(pitch: 48 + (($0 * 3 + i) % 24), start: Double($0) * 0.5, length: 0.4, velocity: 100) }
            t.clips = [c]; tracks.append(t)
        }
        s.modify { $0.tracks = tracks }
        pump(60) { s.engine.strips.count == n && s.engine.strips.values.allSatisfy { !$0.loading && $0.instrument != nil } }
        pump(1)
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("many.wav")
        try? FileManager.default.removeItem(at: out)
        try? s.engine.bounce(s.project, to: out) { _ in }
        let r = SelfTest.analyze(out)
        print(String(format: "  %2d tracks created at once: loaded %d, peak rms %.4f %@", n, s.engine.strips.values.filter { $0.instrument != nil }.count, r.rms.max() ?? 0, (r.rms.max() ?? 0) > 0.01 ? "SOUND" : "SILENT"))
    }
    /// `--truncimport path tracks notesPerTrack`: parse a MIDI file, keep a slice of it, and see if it makes sound.
    static func truncImport(_ path: String, tracks k: Int, notes m: Int) {
        _ = NSApplication.shared
        let s = Session()
        func pump(_ sec: Double, until: () -> Bool = { false }) { let e = Date().addingTimeInterval(sec); while Date() < e && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }
        pump(1)
        guard let imp = try? MIDIFile.parse(Data(contentsOf: URL(fileURLWithPath: path))) else { print("parse failed"); return }
        var tr = MIDIFile.makeTracks(imp, beatsPerBar: 4, firstColor: 0)
        tr = Array(tr.prefix(k))
        for i in tr.indices { for j in tr[i].clips.indices { tr[i].clips[j].notes = Array(tr[i].clips[j].notes.prefix(m)) } }
        if let i = CommandLine.arguments.firstIndex(of: "--keep"), i + 1 < CommandLine.arguments.count {
            let keep = CommandLine.arguments[i + 1].split(separator: ",").compactMap { Int($0) }
            tr = keep.compactMap { $0 < tr.count ? tr[$0] : nil }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--skip"), i + 1 < CommandLine.arguments.count, let sk = Int(CommandLine.arguments[i + 1]), sk < tr.count { tr.remove(at: sk) }
        if CommandLine.arguments.contains("--describe") {
            for (i, t) in tr.enumerated().suffix(4) {
                let ns = t.clips.flatMap { $0.notes }
                print("  track \(i): \(t.name) | prog \(t.instrument.gmProgram) drums \(t.instrument.isDrums) | notes \(ns.count) | clips \(t.clips.map { "\($0.start)+\($0.length)" }) | pitch \(ns.map { $0.pitch }.min() ?? 0)-\(ns.map { $0.pitch }.max() ?? 0) | max len \(ns.map { $0.length }.max() ?? 0)")
            }
        }
        let keepStarter = CommandLine.arguments.contains("--keepstarter")
        s.modify { $0.tempo = imp.tempo; if keepStarter { $0.tracks.append(contentsOf: tr) } else { $0.tracks = tr } }
        let expected = keepStarter ? tr.count + 1 : tr.count
        pump(60) { s.engine.strips.count == expected && s.engine.strips.values.allSatisfy { !$0.loading && $0.instrument != nil } }
        pump(1)
        if let i = CommandLine.arguments.firstIndex(of: "--dumpsmf"), i + 1 < CommandLine.arguments.count {
            try? MIDIFile.build(s.project.loopUnrolled(), forExport: false, metronome: true).write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
        s.flushSequence()
        for (i, t) in s.engine.sequencer.tracks.enumerated() {
            print(String(format: "   seqtrack %d: length %.1f beats | muted %d solo %d | dest %@", i, t.lengthInBeats, t.isMuted ? 1 : 0, t.isSoloed ? 1 : 0, t.destinationAudioUnit.map { String(describing: type(of: $0)) } ?? "none"))
        }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("trunc.wav")
        try? FileManager.default.removeItem(at: out)
        try? s.engine.bounce(s.project, to: out) { _ in }
        let r = SelfTest.analyze(out)
        for t in s.project.tracks { print(String(format: "   per-track peak: %@ → %.4f", t.name as NSString, s.engine.renderPeaks[t.id] ?? -1)) }
        print(String(format: "  tracks %2d × notes %5d: peak rms %.4f %@", k, m, r.rms.max() ?? 0, (r.rms.max() ?? 0) > 0.005 ? "SOUND" : "SILENT"))
    }
    /// Interaction checks for the Vocal Tune canvas.
    static func tuneCanvas(_ s: Session) {
        print("vocal tune canvas")
        var t = Track(name: "Vox", colorIndex: 1, kind: .audio)
        var clip = AudioClip(name: "vox", start: 0, file: "none.caf", duration: 6, length: 6)
        var td = TuneData(); td.analyzed = true
        td.notes = [TuneNote(start: 0.5, end: 1.3, pitch: 60, detected: 60.2, word: "hel"), TuneNote(start: 1.35, end: 2.1, pitch: 64, detected: 63.8, word: "lo"), TuneNote(start: 3.0, end: 3.8, pitch: 67, detected: 67.1, word: "world")]
        td.pitch = Data(count: 4 * 600)
        clip.tune = td; t.audioClips = [clip]
        s.modify { $0.tracks.append(t) }
        s.selectedTrackID = t.id; s.selectedAudioClipID = clip.id
        let st = TuneState(); st.topPitch = 72; st.pps = 120; st.rowH = 22
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let v = TuneCanvas(session: s, state: st)
        v.frame = NSRect(x: 0, y: 0, width: 1000, height: 400)
        win.contentView!.addSubview(v)
        let top = TuneState.rulerH + TuneState.waveH, keysW = TuneState.keysW
        func tx(_ sec: Double) -> CGFloat { keysW + CGFloat(sec) * st.pps }
        func ty(_ pitch: Int) -> CGFloat { top + (st.topPitch - CGFloat(pitch)) * st.rowH + st.rowH / 2 }
        func notes() -> [TuneNote] { s.findAudioClip(clip.id).flatMap { s.project.tracks[$0.track].audioClips[$0.clip].tune?.notes } ?? [] }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        // select & change the pitch by dragging up 2 semitones
        drag(v, from: CGPoint(x: tx(0.9), y: ty(60)), to: CGPoint(x: tx(0.9), y: ty(62)))
        check(notes()[0].pitch == 62, "dragging a note up changes its target pitch (\(notes()[0].pitch))")
        check(notes()[0].edited, "a changed note is marked edited")
        // resize its end bar
        drag(v, from: CGPoint(x: tx(1.3) - 2, y: ty(62)), to: CGPoint(x: tx(1.3) + 18, y: ty(62)))
        check(notes()[0].end > 1.4, String(format: "dragging the end bar lengthens the note (%.2f s)", notes()[0].end))
        // transition marker: pull it earlier → clock (slower glide)
        let n1 = notes()[1]
        s.selectedTuneNoteIDs = [n1.id]     // the creation ring shows beside a selected note's end
        drag(v, from: CGPoint(x: tx(n1.end) + 12, y: ty(64)), to: CGPoint(x: tx(n1.end) - 50, y: ty(64)))
        check((notes()[1].marker ?? 9) < notes()[1].end - 0.1, "dragging the marker before the end starts the glide earlier (clock)")
        // push it past the end → pause
        let m = notes()[1].marker ?? n1.end
        drag(v, from: CGPoint(x: tx(m), y: ty(64)), to: CGPoint(x: tx(n1.end) + 25, y: ty(64)))
        check((notes()[1].marker ?? 0) > notes()[1].end + 0.05, "dragging the marker past the end makes the correction wait (pause)")
        // a short note: pressing its centre must move the pitch, not create a marker
        s.modify { _ in }
        if let ci = s.findAudioClip(clip.id) {
            s.project.tracks[ci.track].audioClips[ci.clip].tune?.notes.append(TuneNote(start: 5.0, end: 5.2, pitch: 58, detected: 58))
            s.project.tracks[ci.track].audioClips[ci.clip].tune?.notes.sort { $0.start < $1.start }
        }
        let short = notes().first { $0.start == 5.0 }!
        s.selectedTuneNoteIDs = [short.id]
        drag(v, from: CGPoint(x: tx(5.1), y: ty(58)), to: CGPoint(x: tx(5.1), y: ty(60)))
        let movedShort = notes().first { $0.id == short.id }!
        check(movedShort.pitch == 60 && movedShort.marker == nil, "dragging the middle of a short note changes its pitch, not a marker (\(movedShort.pitch))")
        drag(v, from: CGPoint(x: tx(5.2) - 1, y: ty(60)), to: CGPoint(x: tx(5.2) - 1, y: ty(62)))
        check(notes().first { $0.id == short.id }?.pitch == 62, "a vertical drag from a note's edge also changes its pitch")
        // a very small note can be grabbed a few points off-centre
        if let ci = s.findAudioClip(clip.id) {
            s.project.tracks[ci.track].audioClips[ci.clip].tune?.notes.append(TuneNote(start: 5.5, end: 5.58, pitch: 55, detected: 55))
            s.project.tracks[ci.track].audioClips[ci.clip].tune?.notes.sort { $0.start < $1.start }
        }
        let tiny = notes().first { $0.start == 5.5 }!
        s.selectedTuneNoteIDs = [tiny.id]
        drag(v, from: CGPoint(x: tx(5.5) - 6, y: ty(55)), to: CGPoint(x: tx(5.5) - 6, y: ty(57)))      // pressed just left of a 9-point-wide note
        check(notes().first { $0.id == tiny.id }?.pitch == 57, "a tiny note can be dragged from a few points beside it")
        // two selected notes move together
        let a0 = notes()[0], a1 = notes()[1]
        s.selectedTuneNoteIDs = [a0.id, a1.id]
        drag(v, from: CGPoint(x: tx((a0.start + a0.end) / 2), y: ty(a0.pitch)), to: CGPoint(x: tx((a0.start + a0.end) / 2), y: ty(a0.pitch + 3)))
        check(notes()[0].pitch == a0.pitch + 3 && notes()[1].pitch == a1.pitch + 3, "dragging one selected note moves every selected note (\(a0.pitch),\(a1.pitch) → \(notes()[0].pitch),\(notes()[1].pitch))")
        check(notes()[2].pitch == 69 || notes().first { $0.start == 3.0 } != nil, "unselected notes stay put")
        // marquee, then drag
        drag(v, from: CGPoint(x: tx(0.2), y: ty(75)), to: CGPoint(x: tx(2.5), y: ty(55)))
        check(s.selectedTuneNoteIDs.count >= 2, "a marquee selects several notes (\(s.selectedTuneNoteIDs.count))")
        // double-click on the empty area adds a note
        let before = notes().count
        v.mouseDown(with: event(.leftMouseDown, v, CGPoint(x: tx(4.6), y: ty(65)), clicks: 2)); v.mouseUp(with: event(.leftMouseUp, v, CGPoint(x: tx(4.6), y: ty(65)), clicks: 2))
        check(notes().count == before + 1, "double-clicking empty space adds a note")
        // chord: select a note and press +
        s.selectedTuneNoteIDs = [notes()[2].id]
        key(v, "+", code: 24)
        check(notes()[2].extra.count == 1, "pressing + gives the word a second pitch (\(notes()[2].voices))")
        s.applyChord(clip.id, noteIDs: [notes()[2].id], intervals: [4, 7])
        check(notes()[2].voices == [67, 71, 74], "chord presets stack extra pitches \(notes()[2].voices)")
        // dragging the main voice moves the whole chord
        drag(v, from: CGPoint(x: tx(3.4), y: ty(67)), to: CGPoint(x: tx(3.4), y: ty(69)))
        check(notes()[2].voices == [69, 73, 76], "dragging the word moves its chord with it \(notes()[2].voices)")
        // dragging only an upper voice changes just that pitch (scroll up so it is visible)
        st.topPitch = 82
        drag(v, from: CGPoint(x: tx(3.4), y: ty(73)), to: CGPoint(x: tx(3.4), y: ty(72)))
        check(notes()[2].voices == [69, 72, 76], "dragging an upper voice changes only that pitch \(notes()[2].voices)")
        // delete, undo
        s.selectedTuneNoteIDs = [notes()[0].id]
        key(v, "\u{7F}", code: 51)
        check(notes().count == before, "Delete removes the selected note")
        s.undo(); settle()
        check(notes().count == before + 1, "Undo brings it back")
        // splitting a note into sections
        let w0 = notes().count
        let longNote = notes().first { $0.word == "world" }!
        s.splitNotes(clip.id, noteIDs: [longNote.id], parts: 3)
        let parts = notes().filter { $0.start >= longNote.start - 0.001 && $0.end <= longNote.end + 0.001 && $0.pitch == longNote.pitch }
        check(notes().count == w0 + 2, "splitting into 3 sections adds two notes (\(notes().count - w0))")
        check(parts.count >= 3 && abs(parts.map { $0.length }.reduce(0, +) - longNote.length) < 1e-6, "the sections exactly cover the original note")
        check(parts.first?.word == "world" && parts.dropFirst().allSatisfy { $0.word.isEmpty }, "the first section keeps the word")
        // give the middle section its own pitch
        if let mid = parts.sorted(by: { $0.start < $1.start })[safe: 1] {
            drag(v, from: CGPoint(x: tx((mid.start + mid.end) / 2), y: ty(mid.pitch)), to: CGPoint(x: tx((mid.start + mid.end) / 2), y: ty(mid.pitch + 2)))
            check(notes().first { $0.id == mid.id }?.pitch == mid.pitch + 2, "each section can be given its own pitch")
        }
        // split tool: click a note to cut it where you click
        let target = notes().first { $0.word == "hel" }!
        let count0 = notes().count
        s.tuneSplitTool = true
        v.mouseDown(with: event(.leftMouseDown, v, CGPoint(x: tx((target.start + target.end) / 2), y: ty(target.pitch)), clicks: 1)); v.mouseUp(with: event(.leftMouseUp, v, CGPoint(x: tx((target.start + target.end) / 2), y: ty(target.pitch)), clicks: 1))
        s.tuneSplitTool = false
        check(notes().count == count0 + 1, "the split tool cuts the note where you click")
        // S splits at the playhead
        let toCut = notes().first { $0.word == "lo" }!
        s.seek(to: s.project.beat(atSeconds: (toCut.start + toCut.end) / 2))
        s.selectedTuneNoteIDs = [toCut.id]
        let count1 = notes().count
        key(v, "s", code: 1)
        check(notes().count == count1 + 1, "pressing S splits the selected note at the playhead")
        // merge them back
        let pieces = notes().filter { $0.start >= toCut.start - 0.001 && $0.end <= toCut.end + 0.001 && $0.pitch == toCut.pitch }
        s.mergeNotes(clip.id, noteIDs: Set(pieces.map { $0.id }))
        check(notes().count == count1, "merging joins the sections back into one note")
        // dragging notes sideways in time
        if let ci = s.findAudioClip(clip.id) {
            var t = s.project.tracks[ci.track].audioClips[ci.clip].tune!
            t.notes.removeAll { $0.start >= 5.9 }
            t.notes.append(TuneNote(start: 5.9, end: 6.4, pitch: 60, detected: 60, word: "move"))
            t.notes.append(TuneNote(start: 6.8, end: 7.3, pitch: 62, detected: 62, word: "me"))
            t.notes.sort { $0.start < $1.start }
            s.project.tracks[ci.track].audioClips[ci.clip].tune = t
            s.project.tracks[ci.track].audioClips[ci.clip].length = 9; s.project.tracks[ci.track].audioClips[ci.clip].duration = 9
        }
        st.topPitch = 72; st.scrollX = 4.0
        func tx2(_ sec: Double) -> CGFloat { keysW + CGFloat(sec - Double(st.scrollX)) * st.pps }
        let mv = notes().first { $0.word == "move" }!, me = notes().first { $0.word == "me" }!
        s.selectedTuneNoteIDs = [mv.id]
        drag(v, from: CGPoint(x: tx2((mv.start + mv.end) / 2), y: ty(60)), to: CGPoint(x: tx2((mv.start + mv.end) / 2) + 30, y: ty(60)))
        let slid = notes().first { $0.id == mv.id }!
        check(abs(slid.start - (mv.start + 0.25)) < 0.02 && abs(slid.length - mv.length) < 1e-6, String(format: "dragging a note sideways moves it in time (%.2f → %.2f s, same length)", mv.start, slid.start))
        check(slid.pitch == 60 && slid.word == "move", "a sideways drag keeps the pitch and the word")
        // it stops at the next note
        drag(v, from: CGPoint(x: tx2((slid.start + slid.end) / 2), y: ty(60)), to: CGPoint(x: tx2((slid.start + slid.end) / 2) + 400, y: ty(60)))
        let stopped = notes().first { $0.id == mv.id }!
        check(stopped.end <= me.start + 1e-6 && stopped.end > me.start - 0.05, String(format: "it stops at the neighbouring note (ends %.2f, next starts %.2f)", stopped.end, me.start))
        // two selected notes slide together
        s.selectedTuneNoteIDs = [mv.id, me.id]
        let beforeStarts = (notes().first { $0.id == mv.id }!.start, notes().first { $0.id == me.id }!.start)
        drag(v, from: CGPoint(x: tx2((stopped.start + stopped.end) / 2), y: ty(60)), to: CGPoint(x: tx2((stopped.start + stopped.end) / 2) + 24, y: ty(60)))
        let afterStarts = (notes().first { $0.id == mv.id }!.start, notes().first { $0.id == me.id }!.start)
        check(abs((afterStarts.0 - beforeStarts.0) - (afterStarts.1 - beforeStarts.1)) < 0.011 && afterStarts.0 > beforeStarts.0 + 0.1, "several selected notes slide together by the same amount")
        s.selectedTuneNoteIDs = []
        st.scrollX = 0

        // moving words sideways
        let hel = notes().first { $0.word == "hel" }!, lo = notes().first { $0.word == "lo" }!
        s.selectedTuneNoteIDs = [hel.id]
        drag(v, from: CGPoint(x: tx((hel.start + hel.end) / 2), y: ty(hel.pitch)), to: CGPoint(x: tx((lo.start + lo.end) / 2), y: ty(hel.pitch)), flags: .command)
        check(notes().first { $0.id == lo.id }?.word == "hel" && notes().first { $0.id == hel.id }?.word == "lo", "⌘-dragging a word onto another note moves it there (the two exchange)")
        check(notes().first { $0.id == hel.id }?.pitch == hel.pitch, "a sideways drag doesn't change the pitch")
        let words0 = notes().map { $0.word }
        s.shiftWords(clip.id, by: 1, noteIDs: [])
        let words1 = notes().map { $0.word }
        var moved = true
        for (i, w) in words0.enumerated() where !w.isEmpty && i + 1 < words1.count { if !words1[i + 1].contains(w) { moved = false } }
        check(moved, "Move Words Right slides every word one note along")
        s.undo()
        check(notes().map { $0.word } == words0, "undo puts the words back")
        // ⌥→ moves just the selected note's word
        let first = notes().first { !$0.word.isEmpty }!
        let idx = notes().firstIndex { $0.id == first.id }!
        s.selectedTuneNoteIDs = [first.id]
        let optRight = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: v.window!.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!
        v.keyDown(with: optRight)
        check(idx + 1 < notes().count && notes()[idx + 1].word == first.word, "⌥→ moves the selected note's word to the next note")
        // strength slider data path
        s.editTune(clip.id) { $0.amount = 0.4 }
        let amt = s.findAudioClip(clip.id).flatMap { s.project.tracks[$0.track].audioClips[$0.clip].tune?.amount } ?? 0
        check(abs(amt - 0.4) < 1e-9, "strength is stored per clip")
    }

    static func pumpBrief() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
