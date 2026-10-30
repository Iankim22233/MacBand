import Foundation
import AppKit
import AVFoundation

/// Headless checks of the audio pipeline (run with `MacBand --selftest`).
@MainActor enum SelfTest {
    static func pump(_ seconds: Double, until: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    static func analyze(_ url: URL) -> (rms: [Float], sr: Double, samples: [Float]) {
        let f = try! AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try! f.read(into: buf)
        let ch = buf.floatChannelData![0]
        let n = Int(buf.frameLength)
        let samples = Array(UnsafeBufferPointer(start: ch, count: n))
        let win = Int(f.processingFormat.sampleRate / 20)
        var rms: [Float] = []
        var i = 0
        while i + win <= n { var s: Float = 0; for k in i..<i+win { s += samples[k] * samples[k] }; rms.append((s / Float(win)).squareRoot()); i += win }
        return (rms, f.processingFormat.sampleRate, samples)
    }

    static func freq(_ s: [Float], sr: Double, from t0: Double, len: Double) -> Double {
        let a = Int(t0 * sr), b = min(s.count - 1, a + Int(len * sr))
        guard b > a + 10 else { return 0 }
        var crossings = 0
        for i in a+1..<b where s[i-1] < 0 && s[i] >= 0 { crossings += 1 }
        return Double(crossings) / len
    }

    static func run() {
        _ = NSApplication.shared
        print("== MacBand self test ==")
        // 1. MIDI roundtrip
        var p = Project()
        p.tempo = 120
        p.tempoPoints = [TempoPoint(beat: 4, bpm: 60)]
        var t = Track(name: "Piano", colorIndex: 0)
        var clip = Clip(name: "A", start: 0, length: 16)
        clip.notes = [
            Note(pitch: 60, start: 0, length: 2),
            Note(pitch: 67, start: 1, length: 1, isSlide: true),   // slide C4 → G4
            Note(pitch: 72, start: 8, length: 1),
        ]
        clip.volume = [AutoPoint(beat: 0, value: 0.75), AutoPoint(beat: 8, value: 0.375)]
        t.clips = [clip]; t.bendRange = 12
        p.tracks = [t]
        let smf = MIDIFile.build(p, forExport: true)
        let back = try! MIDIFile.parse(smf)
        print("midi roundtrip: tracks=\(back.tracks.count) notes=\(back.tracks.first?.notes.count ?? 0) tempo=\(back.tempo) changes=\(back.tempoPoints.map { "\($0.beat)@\($0.bpm)" })")

        // 2. Engine + sequencer layout
        let engine = AudioEngine()
        engine.onError = { print("ENGINE ERROR:", $0) }
        engine.syncTracks(p.tracks)
        pump(15) { engine.strips[t.id]?.instrument != nil }
        print("instrument loaded:", engine.strips[t.id]?.instrument != nil)
        engine.reloadSequence(p, metronome: true)
        print("sequencer tracks:", engine.sequencer.tracks.count, "(project tracks \(p.tracks.count) + click 1)")

        // 3. Offline bounce
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-selftest.wav")
        try? FileManager.default.removeItem(at: out)
        do { try engine.bounce(p, to: out) { _ in } } catch { print("bounce failed:", error); return }
        let r = analyze(out)
        let secs = Double(r.rms.count) / 20
        print(String(format: "bounced %.1fs, peak rms %.3f", secs, r.rms.max() ?? 0))
        // note 1 starts at 0s; note 3 (beat 8) should start at 4*0.5 + 4*1.0 = ... tempo 120 for 4 beats = 2s, then 60 bpm 4 beats = 4s → 6s
        func onset(after t0: Double) -> Double? {
            for (i, v) in r.rms.enumerated() where Double(i) / 20 >= t0 && v > 0.01 { return Double(i) / 20 }
            return nil
        }
        print("first onset:", onset(after: 0) as Any)
        print("onset near beat 8 (expect ≈6.0s):", onset(after: 4.5) as Any)
        // slide: C4 (261 Hz) bending up toward G4 (392 Hz) during beat 1–2 (0.5–1.0s)
        print(String(format: "pitch @0.2s %.0f Hz, @1.2s %.0f Hz (a real piano reads about twice its pitch here; the slide should rise by ×1.5)", freq(r.samples, sr: r.sr, from: 0.2, len: 0.2), freq(r.samples, sr: r.sr, from: 1.2, len: 0.2)))

        // 3b. isolate start-of-song behaviour
        func case_(_ label: String, notes: [Note], bend: Int = 12) {
            var q = Project(); q.tempo = 120
            var tt = Track(name: "T", colorIndex: 0); tt.bendRange = bend
            var cc = Clip(name: "c", start: 0, length: 8); cc.notes = notes; tt.clips = [cc]; q.tracks = [tt]
            engine.syncTracks(q.tracks)
            pump(15) { engine.strips[tt.id]?.instrument != nil && engine.strips[tt.id]?.loading == false }
            let o = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-case.wav")
            try? FileManager.default.removeItem(at: o)
            try? engine.bounce(q, to: o) { _ in }
            let a = analyze(o)
            let on = a.rms.enumerated().first { $0.element > 0.01 }.map { Double($0.offset) / 20 }
            print("case \(label): onset=\(on as Any) peak=\(a.rms.max() ?? 0) f(0.1)=\(Int(freq(a.samples, sr: a.sr, from: 0.1, len: 0.2))) f(0.8)=\(Int(freq(a.samples, sr: a.sr, from: 0.8, len: 0.2))) f(1.3)=\(Int(freq(a.samples, sr: a.sr, from: 1.3, len: 0.2)))")
            engine.syncTracks([])
        }
        case_("plain note at 0", notes: [Note(pitch: 60, start: 0, length: 2)])
        case_("plain note at 1", notes: [Note(pitch: 60, start: 1, length: 2)])
        case_("slide 60→67 (bend 12)", notes: [Note(pitch: 60, start: 0, length: 3), Note(pitch: 67, start: 0.5, length: 1, isSlide: true)])
        case_("slide 60→72 (bend 12)", notes: [Note(pitch: 60, start: 0, length: 3), Note(pitch: 72, start: 0.5, length: 1, isSlide: true)])

        // 3c. loop wrap: a note on the loop's first beat must retrigger every pass (2 beats = 1s)
        do {
            var q = Project(); q.tempo = 120; q.loopEnabled = true; q.loopStart = 0; q.loopEnd = 2
            var tt = Track(name: "T", colorIndex: 0)
            var cc = Clip(name: "c", start: 0, length: 8); cc.notes = [Note(pitch: 60, start: 0, length: 0.5)]; tt.clips = [cc]; q.tracks = [tt]
            engine.syncTracks(q.tracks)
            pump(15) { engine.strips[tt.id]?.instrument != nil && engine.strips[tt.id]?.loading == false }
            let o = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-loop.wav")
            try? FileManager.default.removeItem(at: o)
            try? engine.bounce(q, to: o, honorLoop: true, testSeconds: 4.2) { _ in }
            let a = analyze(o)
            var onsets: [Double] = []
            for i in 0..<a.rms.count where a.rms[i] > 0.01 && (i == 0 || a.rms[i-1] <= 0.01) { onsets.append(Double(i) / 20) }
            print("loop onsets (expect ≈0, 1, 2, 3, 4):", onsets)
            engine.syncTracks([])
        }

        // 3d. real-time loop playback (uses the live output device); sample the master meter
        do {
            var q = Project(); q.tempo = 120; q.loopEnabled = true; q.loopStart = 0; q.loopEnd = 2
            var tt = Track(name: "T", colorIndex: 0)
            var cc = Clip(name: "c", start: 0, length: 8); cc.notes = [Note(pitch: 60, start: 0, length: 0.5)]; tt.clips = [cc]; q.tracks = [tt]
            engine.syncTracks(q.tracks)
            pump(15) { engine.strips[tt.id]?.instrument != nil && engine.strips[tt.id]?.loading == false }
            engine.applyMix(q, beat: nil)
            engine.reloadSequence(q, metronome: false)
            engine.position = 0
            engine.play()
            let t0 = Date()
            var onsets: [Double] = []
            var wasOn = false
            var posMax = 0.0
            while Date().timeIntervalSince(t0) < 4.6 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                let on = engine.masterPeak > 0.02
                if on && !wasOn { onsets.append((Date().timeIntervalSince(t0) * 10).rounded() / 10) }
                wasOn = on
                posMax = max(posMax, engine.position)
            }
            engine.stop()
            print("realtime loop onsets (expect ≈0, 1, 2, 3, 4):", onsets, "max position", posMax, "(loop end 2)")
            engine.syncTracks([])
        }

        // 4. Plugins
        let lib = PluginLibrary.shared
        lib.rescan()
        pump(60) { !lib.scanning && !lib.plugins.isEmpty }
        pump(1)
        print("plugins found: AU=\(lib.plugins.filter { $0.spec.format == .au }.count) VST3=\(lib.plugins.filter { $0.spec.format == .vst3 }.count)")
        print("VST3:", lib.plugins.filter { $0.spec.format == .vst3 }.map { "\($0.spec.name)\($0.spec.isInstrument ? " (inst)" : " (fx)")" }.joined(separator: ", "))
        print("skipped:", lib.skipped)
        for arg in CommandLine.arguments.dropFirst(2) {
            let wantVST3 = arg.hasPrefix("vst3:")
            var name = wantVST3 ? String(arg.dropFirst(5)) : arg
            var maker: UInt32? = nil
            if let at = name.firstIndex(of: "@") { maker = PluginHost.fourCC(String(name[name.index(after: at)...])); name = String(name[..<at]) }
            guard let lp = lib.plugins.first(where: { $0.spec.name.lowercased().contains(name.lowercased()) && $0.spec.isInstrument && (!wantVST3 || $0.spec.format == .vst3) && (maker == nil || $0.spec.auManufacturer == maker!) }) else { print("plugin \(name): not found"); continue }
            var pt = Track(name: lp.spec.name, colorIndex: 1)
            var s = lp.spec; s.id = UUID()
            pt.instrument = InstrumentSpec(plugin: s)
            var c2 = Clip(name: "x", start: 0, length: 8)
            c2.notes = [Note(pitch: 60, start: 0, length: 2), Note(pitch: 64, start: 0, length: 2), Note(pitch: 67, start: 0, length: 2)]
            pt.clips = [c2]
            var p2 = Project(); p2.tracks = [pt]
            engine.syncTracks(p2.tracks)
            pump(20) { engine.strips[pt.id]?.instrument != nil }
            guard engine.strips[pt.id]?.instrument != nil else { print("plugin \(lp.spec.name) [\(lp.spec.format)]: FAILED to load"); continue }
            engine.reloadSequence(p2, metronome: false)
            let o2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-plugin.wav")
            try? FileManager.default.removeItem(at: o2)
            try? engine.bounce(p2, to: o2) { _ in }
            let a = analyze(o2)
            print("plugin \(lp.spec.name) [\(lp.spec.format)]: loaded, peak rms \(a.rms.max() ?? 0)")
            if lp.spec.name.lowercased().contains("meow") {
                // brightness (high-frequency share of the signal) per 100 ms across the first chord: should rise then fall
                var out: [String] = []
                let win = Int(a.sr * 0.1)
                var i = 0
                while i + win < min(a.samples.count, Int(a.sr * 1.6)) {
                    var e: Float = 0, d: Float = 0
                    for k in i+1..<i+win { e += a.samples[k] * a.samples[k]; let df = a.samples[k] - a.samples[k-1]; d += df * df }
                    out.append(String(format: "%.2f", e > 1e-9 ? (d / e).squareRoot() : 0))
                    i += win
                }
                print("   brightness per 100ms:", out.joined(separator: " "))
            }
            if let st = engine.captureState(of: s.id) {
                // restore into a fresh instance of the same plugin
                var s2 = lp.spec; s2.id = UUID(); s2.state = st
                var t2 = pt; t2.id = UUID(); t2.instrument = InstrumentSpec(plugin: s2)
                engine.syncTracks([t2])
                pump(20) { engine.strips[t2.id]?.instrument != nil && engine.strips[t2.id]?.loading == false }
                let st2 = engine.captureState(of: s2.id)
                print("   state: captured \(st.count) bytes; restored instance re-captures \(st2?.count ?? 0) bytes")
            } else { print("   state: none captured") }
            engine.syncTracks([])
        }
    }
}
