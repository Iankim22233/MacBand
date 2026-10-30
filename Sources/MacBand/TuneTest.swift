import Foundation
import AVFoundation
import AppKit

/// Headless checks for the vocal tuning pipeline (`MacBand --tunetest`).
enum TuneTest {
    struct Sung { var midi: Double; var start: Double; var length: Double }

    /// Harmonic "voice" with vibrato, one pitch per note, silence between.
    static func synthVoice(_ notes: [Sung], rate: Double = 44100, vibratoCents: Double = 25, total: Double? = nil) -> [Float] {
        let end = total ?? ((notes.map { $0.start + $0.length }.max() ?? 1) + 0.3)
        var x = [Float](repeating: 0, count: Int(end * rate))
        var phase = 0.0
        for n in notes {
            let i0 = Int(n.start * rate), i1 = min(x.count, Int((n.start + n.length) * rate))
            for i in i0..<i1 {
                let t = Double(i - i0) / rate
                let vib = vibratoCents / 100 * sin(2 * .pi * 5.5 * t) * min(1, t / 0.15)
                let f0 = 440 * pow(2, (n.midi + vib - 69) / 12)
                phase += 2 * .pi * f0 / rate
                var s = 0.0
                var h = 1
                while Double(h) * f0 < 5000 {
                    // gentle vocal-ish spectral tilt with a formant bump near 700 Hz
                    let fh = Double(h) * f0
                    s += sin(Double(h) * phase) / Double(h) * (1 + 2.5 * exp(-pow((fh - 700) / 300, 2)))
                    h += 1
                }
                let env = min(1, t / 0.03) * min(1, (n.length - t) / 0.05)
                x[i] = Float(0.25 * s * env)
            }
        }
        return x
    }

    static func midiOfFrequency(_ f: Double) -> Double { 69 + 12 * log2(f / 440) }

    /// Median detected pitch (MIDI) of the output within [t0, t1].
    static func medianPitch(_ samples: [Float], rate: Double, from t0: Double, to t1: Double) -> Double {
        let track = PitchAnalyzer.track(samples, sampleRate: rate)
        let a = Int(t0 / PitchAnalyzer.hop), b = min(track.count, Int(t1 / PitchAnalyzer.hop))
        let v = track[min(a, track.count)..<max(min(a, track.count), b)].filter { $0 > 0 }.sorted()
        return v.isEmpty ? 0 : Double(v[v.count / 2])
    }

    /// `--transcribetest`: macOS speaks a sentence, we transcribe it and check the words and timings.
    static func transcribeTest() async {
        print("== transcription ==")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let aiff = dir.appendingPathComponent("macband-say.aiff")
        try? FileManager.default.removeItem(at: aiff)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-o", aiff.path, "hello world this is a test"]
        try? p.run(); p.waitUntilExit()
        guard let imp = try? AudioStore.importFile(aiff) else { print("  FAIL could not import speech"); return }
        print("  speech file: \(String(format: "%.2f", imp.duration)) s")
        do {
            let words = try await Transcriber.transcribe(fileURL: AudioStore.url(imp.file))
            print("  words:", words.map { String(format: "%@ [%.2f–%.2f]", $0.text, $0.start, $0.end) }.joined(separator: ", "))
            print(words.count >= 4 ? "  ok    words recognized with timings" : "  FAIL  too few words")
        } catch { print("  FAIL  transcription error:", error.localizedDescription) }
    }

    /// `--audiotest`: import → analyze → tune → export through a real session.
    @MainActor static func sessionTest() {
        _ = NSApplication.shared
        print("== audio tracks, auto-analysis and tuning in a session ==")
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   " : "  FAIL ", what); if !ok { failures += 1 } }
        func pump(_ sec: Double, until: () -> Bool = { false }) { let e = Date().addingTimeInterval(sec); while Date() < e && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }

        // a sung line (out of tune) written as a normal audio file
        let sung = [Sung(midi: 60.30, start: 0.2, length: 0.6), Sung(midi: 63.60, start: 0.95, length: 0.6), Sung(midi: 67.20, start: 1.7, length: 0.6)]
        let mono = synthVoice(sung, rate: AudioStore.rate)
        let wavURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-sung.caf")
        try? FileManager.default.removeItem(at: wavURL)
        try? AudioStore.write([mono, mono], rate: AudioStore.rate, to: "../" + wavURL.lastPathComponent)   // written beside the store, then imported
        let src = AudioStore.folder.deletingLastPathComponent().appendingPathComponent(wavURL.lastPathComponent)

        let s = Session()
        pump(1)
        s.importAudio(url: src)
        pump(20) { s.selectedAudioClipID != nil }
        guard let id = s.selectedAudioClipID, let loc = s.findAudioClip(id) else { print("  FAIL import did not create a clip"); return }
        check(s.project.tracks[loc.track].kind == .audio, "import creates an audio track")
        pump(60) { !s.tuneWorking.contains(id) && (s.project.tracks[loc.track].audioClips[loc.clip].tune?.analyzed ?? false) }
        pump(1)
        var clip = s.project.tracks[loc.track].audioClips[loc.clip]
        check(clip.tune?.analyzed == true, "the clip is analyzed automatically on import")
        check(clip.tune?.notes.map { $0.pitch } == [60, 64, 67], "notes transcribed and locked to the nearest pitch \(clip.tune?.notes.map { $0.pitch } ?? [])")
        check(clip.tune?.enabled == false, "tuning starts off (notes are the transparent preview)")

        // export with tuning off: the singer is still out of tune
        func exportPitch(_ label: String, at n: Int) -> Double {
            s.stop()
            let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audiotest.wav")
            try? FileManager.default.removeItem(at: out)
            try? s.engine.bounce(s.project, to: out) { _ in }
            let r = SelfTest.analyze(out)
            let f = (try? AVAudioFile(forReading: out)).flatMap { f -> [Float]? in
                guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return nil }
                try? f.read(into: b); return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
            } ?? []
            _ = r
            let note = sung[n]
            return medianPitch(f, rate: AudioStore.rate, from: note.start + 0.03 + 0.12, to: note.start + 0.03 + note.length - 0.06)
        }
        let off = exportPitch("off", at: 0)
        check(abs(off - 60.30) < 0.2, String(format: "tuning off: exported voice is as sung (%.2f)", off))

        // tuning on
        s.setTuneEnabled(id, true)
        pump(30) { FileManager.default.fileExists(atPath: AudioStore.url(AudioStore.tunedName(for: clip.file, clipID: id)).path) && !s.tuneWorking.contains(id) }
        pump(0.5)
        let on = [exportPitch("on", at: 0), exportPitch("on", at: 1), exportPitch("on", at: 2)]
        for (i, m) in on.enumerated() { check(abs(m - [60, 64, 67][i].asDouble) < 0.2, String(format: "tuning on: note %d exports at %.2f (target %d)", i + 1, m, [60, 64, 67][i])) }
        // timing: the audio must sit where the clip is (first onset ≈ 0.2 s + start-up offset)
        // strength 0 = untouched
        s.editTune(id) { $0.amount = 0 }
        pump(1.5) { false }
        pump(10) { !s.tuneWorking.contains(id) }
        pump(0.5)
        let weak = exportPitch("strength0", at: 0)
        check(abs(weak - off) < 0.2, String(format: "strength 0%% leaves the voice natural (%.2f)", weak))
        s.editTune(id) { $0.amount = 1 }
        pump(1.5) { false }; pump(10) { !s.tuneWorking.contains(id) }; pump(0.5)

        // editing a note while tuning is ON: drag the first note up two semitones with the mouse
        do {
            let st = TuneState(); st.topPitch = 72; st.pps = 120; st.rowH = 22
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            let v = TuneCanvas(session: s, state: st)
            v.frame = NSRect(x: 0, y: 0, width: 1000, height: 400)
            win.contentView!.addSubview(v)
            let top = TuneState.rulerH + TuneState.waveH
            func tx(_ sec: Double) -> CGFloat { TuneState.keysW + CGFloat(sec) * st.pps }
            func ty(_ pitch: Int) -> CGFloat { top + (st.topPitch - CGFloat(pitch)) * st.rowH + st.rowH / 2 }
            let n0 = s.project.tracks[loc.track].audioClips[loc.clip].tune!.notes[0]
            check(s.project.tracks[loc.track].audioClips[loc.clip].tune?.enabled == true, "tuning is on for this test")
            func ev(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: v.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let a = CGPoint(x: tx((n0.start + n0.end) / 2), y: ty(n0.pitch)), b = CGPoint(x: a.x, y: ty(n0.pitch + 2))
            v.mouseDown(with: ev(.leftMouseDown, a))
            for i in 1...6 { v.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: a.x, y: a.y + (b.y - a.y) * CGFloat(i) / 6))) }
            v.mouseUp(with: ev(.leftMouseUp, b))
            let moved = s.project.tracks[loc.track].audioClips[loc.clip].tune!.notes[0]
            check(moved.pitch == n0.pitch + 2, "dragging a note while tuning is on changes its pitch (\(n0.pitch) → \(moved.pitch))")
            pump(1.5) { false }; pump(15) { !s.tuneWorking.contains(id) }; pump(0.5)
            let edited = exportPitch("edited", at: 0)
            check(abs(edited - Double(n0.pitch + 2)) < 0.25, String(format: "the exported voice follows the edit (%.2f, expected %d)", edited, n0.pitch + 2))
            s.undo(); pump(1.5) { false }; pump(15) { !s.tuneWorking.contains(id) }; pump(0.5)
            let back = exportPitch("undone", at: 0)
            check(abs(back - Double(n0.pitch)) < 0.25, String(format: "undo returns the voice to the original pitch (%.2f)", back))
        }

        // chord: a word with three pitches
        let firstNote = s.project.tracks[loc.track].audioClips[loc.clip].tune!.notes[2].id
        s.applyChord(id, noteIDs: [firstNote], intervals: s.chordIntervals("Major"))
        pump(1.5) { false }; pump(10) { !s.tuneWorking.contains(id) }; pump(0.5)
        clip = s.project.tracks[loc.track].audioClips[loc.clip]
        check(clip.tune?.notes[2].voices == [67, 71, 74], "chord stacked on the word \(clip.tune?.notes[2].voices ?? [])")
        let (chans, _) = (try? AudioStore.loadChannels(AudioSchedule.playbackFile(clip))) ?? ([], 0)
        let seg = chans.first.map { Array($0[Int(1.8 * AudioStore.rate)..<Int(2.2 * AudioStore.rate)]) } ?? []
        let plain = Array(mono[Int(1.8 * AudioStore.rate)..<Int(2.2 * AudioStore.rate)])
        func power(_ x: [Float], hz: Double) -> Double {   // Goertzel
            let w = 2 * Double.pi * hz / AudioStore.rate
            var s1 = 0.0, s2 = 0.0
            for v in x { let s0 = Double(v) + 2 * cos(w) * s1 - s2; s2 = s1; s1 = s0 }
            return s1 * s1 + s2 * s2 - 2 * cos(w) * s1 * s2
        }
        let third = 440 * pow(2, (71.0 - 69) / 12), fifth = 440 * pow(2, (74.0 - 69) / 12)
        check(power(seg, hz: third) > power(plain, hz: third) * 8, "chord note contains the major third (B4) that the single voice lacks")
        check(power(seg, hz: fifth) > power(plain, hz: fifth) * 8, "chord note contains the fifth (D5) that the single voice lacks")
        // transposing into a key: C-E-G (C major) into D major lifts everything by two semitones, chords included
        s.undo(); pump(0.2)   // back to the plain single voices
        s.transposeToKey(id, root: 2, scale: .major)
        let moved = s.project.tracks[loc.track].audioClips[loc.clip].tune!.notes
        check(moved.map { $0.pitch } == [62, 66, 69], "transposing C major → D major moves the notes up 2 \(moved.map { $0.pitch })")
        check(s.project.keyRoot == 2 && s.project.scale == .major, "the project key follows")
        s.snapNotesToKey(id, root: 2, scale: .major)
        s.editTune(id) { $0.notes[0].pitch = 63 }      // an out-of-key note (D♯ in D major)
        s.snapNotesToKey(id, root: 2, scale: .major)
        let fixed = s.project.tracks[loc.track].audioClips[loc.clip].tune!.notes[0].pitch
        check(fixed == 62 || fixed == 64, "an out-of-key note snaps to a neighbouring scale note (\(fixed))")
        s.undo(); s.undo(); s.undo(); pump(0.2)
        // splitting the whole vocal clip into two sections: notes are partitioned and both halves play and tune
        let beforeSplit = s.project.tracks[loc.track].audioClips[loc.clip]
        let cutBeat = s.project.beat(atSeconds: 1.5)
        s.splitAudioClip(id, atBeat: cutBeat)
        pump(1.5) { false }; pump(15) { !s.tuneWorking.isEmpty == false }; pump(1)
        let halves = s.project.tracks[loc.track].audioClips
        check(halves.count == 2 && abs(halves[0].length - 1.5) < 0.01 && abs(halves[1].offset - 1.5) < 0.01, "splitting a clip makes two sections that continue each other")
        check((halves[0].tune?.notes.count ?? 0) + (halves[1].tune?.notes.count ?? 0) >= beforeSplit.tune!.notes.count, "the notes are divided between the sections")
        let thirdAfterSplit = exportPitch("split", at: 2)
        check(abs(thirdAfterSplit - 67) < 0.3, String(format: "after the split, the second section still plays and is tuned (%.2f)", thirdAfterSplit))
        s.undo(); pump(0.3)
        check(s.project.tracks[loc.track].audioClips.count == 1, "undo rejoins the sections")
        // undo/redo round trip on tune data
        s.undo()
        check((s.project.tracks[loc.track].audioClips[loc.clip].tune?.notes[2].extra.count ?? 9) == 0, "undo removes the chord")
        // save → lose the stored audio → reopen: the project brings its audio and tuning back
        s.redo()
        pump(1.5) { false }; pump(10) { !s.tuneWorking.contains(id) }
        let projURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audiotest-\(UUID().uuidString.prefix(6)).macband")
        s.write(to: projURL)
        let saved = s.project.tracks[loc.track].audioClips[loc.clip]
        check(FileManager.default.fileExists(atPath: s.assetsFolder(for: projURL).appendingPathComponent(saved.file).path), "saving copies the audio next to the project")
        try? FileManager.default.removeItem(at: AudioStore.url(saved.file))
        try? FileManager.default.removeItem(at: AudioStore.url(AudioStore.tunedName(for: saved.file, clipID: saved.id)))
        s.openProject(url: projURL)
        pump(30) { FileManager.default.fileExists(atPath: AudioStore.url(AudioStore.tunedName(for: saved.file, clipID: saved.id)).path) }
        let reopened = s.project.tracks.flatMap { $0.audioClips }.first
        check(FileManager.default.fileExists(atPath: AudioStore.url(saved.file).path), "reopening restores the audio file")
        check(reopened?.tune?.notes.count == saved.tune?.notes.count && reopened?.tune?.enabled == true, "tuning, notes and chords survive save and reopen")
        check(FileManager.default.fileExists(atPath: AudioStore.url(AudioStore.tunedName(for: saved.file, clipID: saved.id)).path), "the tuned audio is rebuilt after reopening")
        print(failures == 0 ? "ALL AUDIO CHECKS PASSED" : "\(failures) AUDIO CHECK(S) FAILED")
    }

    @MainActor static func run() {
        print("== vocal tuning pipeline ==")
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   " : "  FAIL ", what); if !ok { failures += 1 } }

        // A short melody sung out of tune: C4 +30c, E4 −40c, G4 +20c, D4 +45c
        let sung = [Sung(midi: 60.30, start: 0.2, length: 0.6), Sung(midi: 63.60, start: 0.95, length: 0.6),
                    Sung(midi: 67.20, start: 1.7, length: 0.6), Sung(midi: 62.45, start: 2.45, length: 0.7)]
        let rate = 44100.0
        let voice = synthVoice(sung, rate: rate)

        // 1. pitch tracking
        let track = PitchAnalyzer.track(voice, sampleRate: rate)
        let voiced = track.filter { $0 > 0 }.count
        print("  voiced frames: \(voiced) of \(track.count)")
        check(voiced > Int(Double(track.count) * 0.55), "most of the sung frames are detected as pitched")
        for s in sung {
            let m = medianPitch(voice, rate: rate, from: s.start + 0.1, to: s.start + s.length - 0.05)
            check(abs(m - s.midi) < 0.15, String(format: "tracked pitch %.2f for a note sung at %.2f", m, s.midi))
        }

        // 2. note segmentation: nearest-semitone locking
        let notes = PitchAnalyzer.segment(track, scale: nil, keyRoot: 0)
        print("  notes:", notes.map { String(format: "%d @%.2f–%.2f", $0.pitch, $0.start, $0.end) }.joined(separator: " | "))
        check(notes.count == 4, "four notes transcribed (got \(notes.count))")
        check(notes.map { $0.pitch } == [60, 64, 67, 62], "each note locked to its nearest semitone \(notes.map { $0.pitch })")
        for (n, s) in zip(notes, sung) { check(abs(n.start - s.start) < 0.08 && abs(n.end - (s.start + s.length)) < 0.12, String(format: "note timing %.2f–%.2f vs %.2f–%.2f", n.start, n.end, s.start, s.start + s.length)) }
        // scale lock: in C major, 63.6 (≈E♭4+) should land on E4 rather than E♭
        let cMajor: Set<Int> = ScaleKind.major.intervals
        let scaled = PitchAnalyzer.segment(track, scale: cMajor, keyRoot: 0)
        check(scaled.map { $0.pitch } == [60, 64, 67, 62], "scale snapping keeps notes inside the key \(scaled.map { $0.pitch })")

        // 3. retune: every note is pulled to its locked pitch and the vibrato/detune disappears
        let tuned = TuneData(enabled: true, amount: 1, defaultGlide: 0.04, snapToScale: false, analyzed: true, notes: notes)
        let chans = [voice]
        let c0 = Retuner.curve(frames: track.count, detected: track, notes: tuned.notes, voice: 0, amount: 1, defaultGlide: tuned.defaultGlide)
        let out0 = Retuner.render(channels: chans, rate: rate, detected: track, curve: c0, voice: 0)[0]
        for n in notes {
            let m = medianPitch(out0, rate: rate, from: n.start + 0.12, to: n.end - 0.06)
            check(abs(m - Double(n.pitch)) < 0.12, String(format: "retuned note lands on %d (measured %.3f)", n.pitch, m))
        }
        // spread of the pitch inside one note before/after (vibrato flattened)
        func spread(_ x: [Float], _ t0: Double, _ t1: Double) -> Double {
            let tr = PitchAnalyzer.track(x, sampleRate: rate)
            let v = tr[Int(t0 / 0.01)..<min(tr.count, Int(t1 / 0.01))].filter { $0 > 0 }.map { Double($0) }
            guard v.count > 4 else { return 99 }
            let mean = v.reduce(0, +) / Double(v.count)
            return (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count)).squareRoot() * 100   // cents
        }
        let before = spread(voice, notes[0].start + 0.15, notes[0].end - 0.05), after = spread(out0, notes[0].start + 0.15, notes[0].end - 0.05)
        check(after < before * 0.5, String(format: "vibrato flattened (%.1f → %.1f cents rms)", before, after))
        check(out0.count == voice.count && (out0.max() ?? 0) < 1.2 && (out0.max() ?? 0) > 0.05, "output keeps its length and level")
        // 4. chord voices: add a major third and a fifth to the third note and render each voice alone
        var chord = notes
        chord[2].extra = [chord[2].pitch + 4, chord[2].pitch + 7]
        let cv1 = Retuner.curve(frames: track.count, detected: track, notes: chord, voice: 1, amount: 1, defaultGlide: 0.04)
        let v1 = Retuner.render(channels: chans, rate: rate, detected: track, curve: cv1, voice: 1)[0]
        let cv2 = Retuner.curve(frames: track.count, detected: track, notes: chord, voice: 2, amount: 1, defaultGlide: 0.04)
        let v2 = Retuner.render(channels: chans, rate: rate, detected: track, curve: cv2, voice: 2)[0]
        let n3 = chord[2]
        check(abs(medianPitch(v1, rate: rate, from: n3.start + 0.12, to: n3.end - 0.06) - Double(n3.pitch + 4)) < 0.2, "chord voice 1 sounds a major third above")
        check(abs(medianPitch(v2, rate: rate, from: n3.start + 0.12, to: n3.end - 0.06) - Double(n3.pitch + 7)) < 0.2, "chord voice 2 sounds a fifth above")
        let silentElsewhere = v1[0..<Int(notes[0].end * rate)].map { abs($0) }.max() ?? 1
        check(silentElsewhere < 0.001, "chord voices are silent on notes that don't have them")
        // 5. strength: 0 leaves the voice alone, 50 halves the error, 100 is flat
        func renderMain(_ amount: Double) -> [Float] {
            let c = Retuner.curve(frames: track.count, detected: track, notes: notes, voice: 0, amount: amount, defaultGlide: 0.04)
            return Retuner.render(channels: chans, rate: rate, detected: track, curve: c, voice: 0)[0]
        }
        let n0 = notes[0]
        let p0 = medianPitch(renderMain(0), rate: rate, from: n0.start + 0.12, to: n0.end - 0.06)
        let p50 = medianPitch(renderMain(0.5), rate: rate, from: n0.start + 0.12, to: n0.end - 0.06)
        let p100 = medianPitch(renderMain(1), rate: rate, from: n0.start + 0.12, to: n0.end - 0.06)
        let orig = medianPitch(voice, rate: rate, from: n0.start + 0.12, to: n0.end - 0.06)
        check(abs(p0 - orig) < 0.03, String(format: "strength 0%%: pitch untouched (%.2f vs sung %.2f)", p0, orig))
        check(abs(p50 - (orig + Double(n0.pitch) ) / 2) < 0.08, String(format: "strength 50%%: halfway to the note (%.2f)", p50))
        check(abs(p100 - Double(n0.pitch)) < 0.08, String(format: "strength 100%%: on the note (%.2f)", p100))
        check(spread(renderMain(0.3), n0.start + 0.15, n0.end - 0.05) > spread(renderMain(1), n0.start + 0.15, n0.end - 0.05), "lower strength keeps more natural vibrato than 100%")
        // 6. key detection and transposing into a chosen key
        func mk(_ ps: [Int]) -> [TuneNote] { ps.enumerated().map { TuneNote(start: Double($0.offset), end: Double($0.offset) + 0.8, pitch: $0.element) } }
        let aMinor = Session.detectKey(mk([57, 60, 64, 62, 60, 59, 57, 64, 60, 57, 59, 60, 57]))
        check(aMinor?.root == 9 && aMinor?.minor == true, "detects A minor from an A-minor melody (\(aMinor?.name ?? "none"))")
        let cMajor2 = Session.detectKey(mk([60, 64, 67, 65, 64, 62, 60, 67, 64, 60, 62, 64, 60]))
        check(cMajor2?.root == 0 && cMajor2?.minor == false, "detects C major from a C-major melody (\(cMajor2?.name ?? "none"))")
        // 7. sliding a note in time changes which part of the voice it corrects
        var slid = notes
        slid[0].start += 0.15; slid[0].end += 0.15      // now covers the later part of the first sung note and the gap after it
        let cs = Retuner.curve(frames: track.count, detected: track, notes: slid, voice: 0, amount: 1, defaultGlide: 0.04)
        let outSlid = Retuner.render(channels: chans, rate: rate, detected: track, curve: cs, voice: 0)[0]
        let early = medianPitch(outSlid, rate: rate, from: notes[0].start + 0.02, to: notes[0].start + 0.12)     // before the slid note begins: untouched
        let late = medianPitch(outSlid, rate: rate, from: slid[0].start + 0.1, to: slid[0].end - 0.1)            // inside it: tuned to 60
        check(abs(early - 60.30) < 0.2, String(format: "the part the note left behind stays as sung (%.2f)", early))
        check(abs(late - 60.0) < 0.15, String(format: "the part the note moved onto is tuned (%.2f)", late))
        print(failures == 0 ? "ALL TUNE CHECKS PASSED" : "\(failures) TUNE CHECK(S) FAILED")
    }
}

private extension Int { var asDouble: Double { Double(self) } }
