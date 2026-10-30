import Foundation
import AppKit
import AVFoundation

/// `--soundtest-after`: instruments must still sound like themselves after an offline render and after the engine is paused.
@MainActor enum InstrumentTest {
    static func run() -> Int32 {
        _ = NSApplication.shared
        print("== Instruments after offline render ==")
        var fails = 0
        func check(_ ok: Bool, _ m: String) { print(ok ? "  ok    \(m)" : "  FAIL  \(m)"); if !ok { fails += 1 } }
        let engine = AudioEngine()
        engine.onError = { print("ENGINE ERROR:", $0) }
        var t = Track(name: "Piano", colorIndex: 0); t.instrument = InstrumentSpec(gmProgram: 0)
        var c = Clip(name: "c", start: 0, length: 4); c.notes = [Note(pitch: 60, start: 0, length: 1)]; t.clips = [c]
        var p = Project(); p.tracks = [t]
        engine.syncTracks(p.tracks)
        SelfTest.pump(30) { engine.strips[t.id]?.instrument != nil && engine.strips[t.id]?.loading == false }
        SelfTest.pump(0.5)
        /// How much a played piano note has decayed after a second (a real piano dies away; the default sine tone doesn't).
        func decay() -> Double {
            engine.noteOn(trackID: t.id, pitch: 60, velocity: 110)
            var peaks: [Float] = []
            for _ in 0..<26 { SelfTest.pump(0.06); peaks.append(engine.masterPeak) }
            engine.noteOff(trackID: t.id, pitch: 60)
            SelfTest.pump(2)
            let early = peaks[2...5].reduce(0, +) / 4, late = peaks[18...24].reduce(0, +) / 7
            return early > 0 ? Double(late / early) : 1
        }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-after.caf")
        check(decay() < 0.5, "before anything: the piano note dies away")
        engine.engine.pause(); engine.startEngine(); SelfTest.pump(0.5)
        check(decay() < 0.5, "after pausing and restarting the engine")
        try? engine.bounce(p, to: out, testSeconds: 2) { _ in }; SelfTest.pump(0.5)
        check(decay() < 0.5, "after an offline render (Export Audio) the piano still dies away")
        try? engine.bounce(p, to: out, testSeconds: 2) { _ in }; SelfTest.pump(0.5)
        check(decay() < 0.5, "and after a second render")
        print(fails == 0 ? "ALL INSTRUMENT CHECKS PASSED" : "\(fails) INSTRUMENT CHECK(S) FAILED")
        return fails == 0 ? 0 : 1
    }
}
