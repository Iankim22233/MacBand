import Foundation

/// AVAudioSequencer's own loop support drops passes, so looping is done by unrolling the loop
/// region into the playback sequence: pass 0 is the song up to the loop end, later passes repeat the region.
extension Project {
    /// Number of repeated passes appended after the first.
    private func loopPasses() -> Int {
        let len = loopEnd - loopStart
        let secs = max(0.2, seconds(atBeat: loopEnd) - seconds(atBeat: loopStart))
        var k = Int((20 * 60 / secs).rounded(.up))
        let notesInWindow = tracks.reduce(0) { $0 + $1.clips.reduce(0) { $0 + $1.notes.count } }
        if notesInWindow > 0 { k = min(k, max(2, 60_000 / notesInWindow)) }
        _ = len
        return min(2000, max(2, k))
    }

    func loopUnrolled() -> Project {
        guard loopEnabled, loopEnd > loopStart else { return self }
        let L = loopEnd - loopStart
        let K = loopPasses()
        var q = self
        q.loopEnabled = false

        // Clips
        for ti in tracks.indices {
            var out: [Clip] = []
            for c in tracks[ti].clips {
                for pass in 0...K {
                    let ws = pass == 0 ? 0 : loopStart
                    let we = loopEnd
                    let shift = Double(pass) * L
                    let s = max(c.start, ws), e = min(c.end, we)
                    if e <= s { continue }
                    var nc = Clip(name: c.name, start: s + shift, length: e - s)
                    nc.id = pass == 0 ? c.id : UUID()
                    var notes: [Note] = []
                    for n in c.notes {
                        let abs = c.start + n.start
                        if abs < s - 1e-9 && !(pass == 0) { continue }
                        if abs >= e - 1e-9 { continue }
                        var m = n
                        m.start = abs - s
                        m.length = min(n.length, e - abs)
                        notes.append(m)
                    }
                    if pass > 0 {
                        let normals = notes.filter { !$0.isSlide }
                        notes.removeAll { n in n.isSlide && !normals.contains { $0.start <= n.start + 1e-6 && $0.end > n.start + 1e-6 } }
                    }
                    nc.notes = notes
                    out.append(nc)
                }
            }
            q.tracks[ti].clips = out
        }

        // Tempo map
        var pts: [TempoPoint] = tempoPoints.filter { $0.beat < loopEnd }
        let startBPM = bpm(at: loopStart)
        let inside = tempoPoints.filter { $0.beat > loopStart && $0.beat < loopEnd }
        for pass in 1...K {
            let shift = Double(pass) * L
            pts.append(TempoPoint(beat: loopStart + shift, bpm: startBPM, ramp: false))
            for p in inside { pts.append(TempoPoint(beat: p.beat + shift, bpm: p.bpm, ramp: p.ramp)) }
        }
        q.tempoPoints = pts
        return q
    }

    /// Map a raw sequence beat back onto the song while looping.
    func loopWrapped(_ raw: Double) -> Double {
        guard loopEnabled, loopEnd > loopStart, raw >= loopEnd else { return raw }
        return loopStart + (raw - loopStart).truncatingRemainder(dividingBy: loopEnd - loopStart)
    }
}
