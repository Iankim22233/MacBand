import Foundation
import Accelerate

/// Applies tuned notes to a vocal: builds a target pitch curve per voice (main + chord voices) and
/// re-synthesizes the recording with TD-PSOLA, which keeps the timing and the vowel character.
enum Retuner {
    static let hop = PitchAnalyzer.hop

    // MARK: Target curves

    struct Curve { var target: [Float]; var gate: [Float] }   // MIDI target per frame (0 = leave alone) and 0…1 voice activity

    /// `voice` 0 is the main (tuned) voice; 1… are the extra chord voices.
    /// `amount` is the strength: 0 leaves the voice as sung, 1 pulls every frame onto the note (flat, robotic).
    static func curve(frames: Int, detected: [Float], notes: [TuneNote], voice: Int, amount: Double, defaultGlide: Double) -> Curve {
        let lk = locked(frames: frames, notes: notes, voice: voice, defaultGlide: defaultGlide)
        let raw = lk.target, gate = lk.gate
        var target = raw
        let main = voice == 0 ? raw : locked(frames: frames, notes: notes, voice: 0, defaultGlide: defaultGlide).target
        for i in 0..<frames where raw[i] > 0 {
            guard detected[i] > 0 else { if voice == 0 { target[i] = 0 }; continue }
            if voice == 0 {
                target[i] = detected[i] + (raw[i] - detected[i]) * Float(amount)
            } else if main[i] > 0 {
                // harmony voices keep the singer's inflection in proportion to (1 − strength)
                target[i] = raw[i] + (detected[i] - main[i]) * Float(1 - amount)
            }
        }
        return Curve(target: target, gate: gate)
    }

    /// The pitch each voice is locked to over time (notes, glides, pauses), before the strength is applied.
    private static func locked(frames: Int, notes: [TuneNote], voice: Int, defaultGlide: Double) -> Curve {
        var target = [Float](repeating: 0, count: frames)
        var gate = [Float](repeating: voice == 0 ? 1 : 0, count: frames)
        let ns = notes.sorted { $0.start < $1.start }
        func pitch(_ n: TuneNote) -> Int? { voice == 0 ? n.pitch : (voice - 1 < n.extra.count ? n.extra[voice - 1] : nil) }
        func smooth(_ x: Double) -> Double { let c = max(0, min(1, x)); return c * c * (3 - 2 * c) }
        func frameRange(_ t0: Double, _ t1: Double) -> Range<Int> {
            let a = max(0, Int((t0 / hop).rounded())), b = min(frames, Int((t1 / hop).rounded()))
            return a..<max(a, b)
        }
        for (idx, n) in ns.enumerated() {
            guard let p = pitch(n) else { continue }
            var holdEnd = n.end
            var glide: (g0: Double, g1: Double, to: Int)? = nil
            if idx + 1 < ns.count, ns[idx + 1].start - n.end < 0.25, let q = pitch(ns[idx + 1]) {
                let m = ns[idx + 1]
                let g0 = max(n.start + 0.02, n.marker ?? n.end)
                var g1 = g0 < m.start ? m.start : g0 + defaultGlide
                g1 = max(g1, g0 + 0.012)
                g1 = min(g1, g0 + 1.2)
                glide = (g0, g1, q)
                holdEnd = max(n.end, g0)
            }
            for i in frameRange(n.start, holdEnd) { target[i] = Float(p); gate[i] = 1 }
            if let g = glide {
                for i in frameRange(g.g0, g.g1) {
                    let t = Double(i) * hop
                    target[i] = Float(Double(p) + (Double(g.to) - Double(p)) * smooth((t - g.g0) / max(0.001, g.g1 - g.g0)))
                    gate[i] = 1
                }
            }
        }
        return Curve(target: target, gate: gate)
    }

    // MARK: PSOLA

    /// Re-synthesize `channels` following `curve`. For voice 0 the untouched audio is kept wherever the voice
    /// isn't corrected; for harmony voices only the shifted (voiced) material is returned.
    static func render(channels: [[Float]], rate: Double, detected: [Float], curve: Curve, voice: Int) -> [[Float]] {
        guard let first = channels.first else { return [] }
        let n = first.count
        let frames = detected.count
        var ref = [Float](repeating: 0, count: n)
        for c in channels { vDSP_vadd(ref, 1, c, 1, &ref, 1, vDSP_Length(n)) }

        var out = voice == 0 ? channels : channels.map { [Float](repeating: 0, count: $0.count) }
        var acc = channels.map { _ in [Float](repeating: 0, count: n) }
        var wsum = [Float](repeating: 0, count: n)
        var mask = [Float](repeating: 0, count: n)

        func f0(at s: Int) -> Double {
            let fi = min(frames - 1, max(0, Int((Double(s) / rate) / hop)))
            let m = detected[fi]; return m > 0 ? 440 * pow(2, (Double(m) - 69) / 12) : 0
        }

        var fi = 0
        while fi < frames {
            guard detected[fi] > 0 else { fi += 1; continue }
            var fj = fi; while fj < frames && detected[fj] > 0 { fj += 1 }
            // does anything in this voiced run need shifting?
            var active = false
            for k in fi..<fj where curve.target[k] > 0 && curve.gate[k] > 0 && (voice > 0 || abs(curve.target[k] - detected[k]) > 0.02) { active = true; break }
            if active {
                let a = max(0, Int(Double(fi) * hop * rate)), b = min(n, Int(Double(fj) * hop * rate))
                synthesize(ref: ref, channels: channels, rate: rate, a: a, b: b, f0: f0, ratioAt: { s in
                    let k = min(frames - 1, max(0, Int((Double(s) / rate) / hop)))
                    guard curve.target[k] > 0, curve.gate[k] > 0, detected[k] > 0 else { return 1.0 }
                    return pow(2, (Double(curve.target[k]) - Double(detected[k])) / 12)
                }, acc: &acc, wsum: &wsum)
                // mix mask: where this voice is active (with short ramps)
                for k in fi..<fj {
                    let g = (curve.target[k] > 0 ? curve.gate[k] : 0)
                    let s0 = Int(Double(k) * hop * rate), s1 = min(n, Int(Double(k + 1) * hop * rate))
                    if s0 < s1 { for s in s0..<s1 { mask[s] = g } }
                }
            }
            fi = fj
        }
        // short crossfades at mask edges
        let ramp = max(8, Int(rate * 0.006))
        var fwd = mask, bwd = mask
        var run: Float = 0
        for s in 0..<n { run += (mask[s] - run) / Float(ramp); fwd[s] = run }
        run = 0
        for s in stride(from: n - 1, through: 0, by: -1) { run += (mask[s] - run) / Float(ramp); bwd[s] = run }
        var smoothMask = mask
        for s in 0..<n { smoothMask[s] = min(fwd[s], bwd[s]) }
        for c in 0..<channels.count {
            for s in 0..<n where smoothMask[s] > 0 && wsum[s] > 1e-3 {
                let shifted = acc[c][s] / wsum[s]
                out[c][s] = voice == 0 ? channels[c][s] * (1 - smoothMask[s]) + shifted * smoothMask[s] : shifted * smoothMask[s]
            }
        }
        return out
    }

    private static func synthesize(ref: [Float], channels: [[Float]], rate: Double, a: Int, b: Int, f0: (Int) -> Double,
                                   ratioAt: (Int) -> Double, acc: inout [[Float]], wsum: inout [Float]) {
        let n = ref.count
        // 1. analysis pitch marks
        var marks: [Int] = []
        let T0 = rate / max(60, f0(a))
        let firstEnd = min(b, a + Int(T0 * 1.3) + 1)
        guard firstEnd > a + 4 else { return }
        var pos = 0.0, neg = 0.0
        for s in a..<firstEnd { pos = max(pos, Double(ref[s])); neg = max(neg, Double(-ref[s])) }
        let sign: Float = pos >= neg ? 1 : -1
        var m = a
        var best: Float = -.infinity
        for s in a..<firstEnd where ref[s] * sign > best { best = ref[s] * sign; m = s }
        marks.append(m)
        while true {
            let T = rate / max(60, f0(m))
            let lo = m + Int(0.75 * T), hi = m + Int(1.25 * T)
            if lo >= b || lo >= n - 2 { break }
            var bm = lo; var bv: Float = -.infinity
            for s in lo...min(hi, min(b, n) - 1) where ref[s] * sign > bv { bv = ref[s] * sign; bm = s }
            if bm <= m { break }
            marks.append(bm); m = bm
            if m >= b - 2 { break }
        }
        guard marks.count >= 3 else { return }

        // 2. synthesis: place grains at target-period spacing
        var ts = Double(marks[0])
        var lastIdx = 0
        while ts < Double(b) {
            // nearest analysis mark (marks are ascending; search forward from the last one)
            var idx = lastIdx
            while idx + 1 < marks.count && abs(Double(marks[idx + 1]) - ts) <= abs(Double(marks[idx]) - ts) { idx += 1 }
            while idx > 0 && abs(Double(marks[idx - 1]) - ts) < abs(Double(marks[idx]) - ts) { idx -= 1 }
            lastIdx = idx
            let am = marks[idx]
            let left = idx > 0 ? am - marks[idx - 1] : (idx + 1 < marks.count ? marks[idx + 1] - am : Int(T0))
            let right = idx + 1 < marks.count ? marks[idx + 1] - am : left
            let half = max(8, (left + right) / 2)
            let r = ratioAt(Int(ts))
            // grain: 2 periods, Hann
            let c0 = Int(ts.rounded())
            let len = 2 * half
            for j in 0..<len {
                let si = am - half + j, di = c0 - half + j
                if si < 0 || si >= n || di < 0 || di >= n { continue }
                let w = Float(0.5 - 0.5 * cos(2 * Double.pi * (Double(j) + 0.5) / Double(len)))
                wsum[di] += w
                for c in 0..<channels.count { acc[c][di] += channels[c][si] * w }
            }
            ts += Double(half) / max(0.25, min(4, r))
        }
    }
}
