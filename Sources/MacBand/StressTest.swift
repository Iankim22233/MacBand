import Foundation
import AppKit
import AVFoundation

/// `--stresstest <plugin name> [rounds]`: starts and stops playback over and over on a track using that plugin.
/// Out-of-process plugins used to crash the app when playback was stopped (a race inside Apple's sequencer).
@MainActor enum StressTest {
    static func run(_ name: String, rounds: Int) {
        _ = NSApplication.shared
        let s = Session()
        SelfTest.pump(60) { !PluginLibrary.shared.scanning && !PluginLibrary.shared.plugins.isEmpty }
        guard let lp = PluginLibrary.shared.instruments.first(where: { $0.spec.name.lowercased().contains(name.lowercased()) && $0.spec.format == .au }) else {
            print("no AU instrument matching \(name)"); return
        }
        var spec = lp.spec; spec.id = UUID()
        s.addTrack(instrument: InstrumentSpec(plugin: spec))
        let tid = s.selectedTrackID!
        s.modify { p in
            let ti = p.tracks.firstIndex { $0.id == tid }!
            for i in 0..<32 { p.tracks[ti].clips[0].notes.append(Note(pitch: 48 + (i * 5) % 24, start: Double(i) * 0.5, length: 0.4, velocity: 100)) }
            p.tracks[ti].clips[0].length = 16
        }
        SelfTest.pump(60) { s.engine.strips[tid]?.instrument != nil }
        guard let unit = s.engine.strips[tid]?.instrument else { print("plugin didn't load"); return }
        print("loaded \(lp.spec.name); in process: \(unit.auAudioUnit.isLoadedInProcess)")
        for i in 0..<rounds {
            s.togglePlay()
            SelfTest.pump(Double.random(in: 0.05...0.5))
            if i % 5 == 0 { s.modify { $0.tempo += 0 } }     // an edit while playing reloads the sequence
            s.togglePlay()
            SelfTest.pump(0.03)
            if i % 10 == 0 { print("round \(i)") }
        }
        print("survived \(rounds) play/stop rounds")
    }
}
