import Foundation
import AppKit
import AVFoundation

/// `--tempochange file.mid`
@MainActor
enum TempoChangeTest {
    static func tempoRun(_ path: String) {
        _ = NSApplication.shared
        let s = Session()
        func pump(_ sec: Double, until: () -> Bool = { false }) { let e = Date().addingTimeInterval(sec); while Date() < e && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }
        pump(1)
        s.importMIDI(url: URL(fileURLWithPath: path), tempo: .useFile)
        pump(0.5)
        let n = s.project.tracks.count
        pump(40) { s.engine.strips.values.allSatisfy { !$0.loading && $0.instrument != nil } && s.engine.strips.count == n }
        func secs() -> Double { s.engine.sequencer.seconds(forBeats: 100) }
        s.flushSequence()
        print(String(format: "project tempo %g: 100 beats take %.2f s (expect %.2f)", s.project.tempo, secs(), 6000 / s.project.tempo))
        s.setTempo(200); pump(1)
        print(String(format: "after setTempo(200), stopped: project %g, 100 beats take %.2f s (expect 30.00)", s.project.tempo, secs()))
        s.setTempo(90); pump(1)
        print(String(format: "after setTempo(90), stopped: 100 beats take %.2f s (expect 66.67)", secs()))
        s.setTempo(200); pump(0.5)
        s.play(); pump(1.5)
        let b1 = s.engine.position; pump(2); let b2 = s.engine.position
        print(String(format: "playing at 200: %.2f beats in 2 s = %.0f BPM (expect ~200); sequencer says 100 beats = %.2f s", b2 - b1, (b2 - b1) * 30, secs()))
        s.setTempo(120); pump(1.5)
        let c1 = s.engine.position; pump(2); let c2 = s.engine.position
        print(String(format: "changed to 120 while playing: %.2f beats in 2 s = %.0f BPM (expect ~120); 100 beats = %.2f s", c2 - c1, (c2 - c1) * 30, secs()))
        s.stop()
    }
}
