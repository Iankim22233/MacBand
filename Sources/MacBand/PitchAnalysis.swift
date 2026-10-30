import Foundation
import Accelerate

/// Monophonic pitch tracking (YIN) and note segmentation for vocals.
enum PitchAnalyzer {
    static let hop = 0.01          // seconds per analysis frame
    static let analysisRate = 22050.0

    /// MIDI pitch (fractional) per 10 ms frame; 0 where the voice isn't pitched.
    static func track(_ x: [Float], sampleRate sr: Double) -> [Float] {
        let hopS = Int((sr * hop).rounded())
        let tauMin = max(2, Int(sr / 1000)), tauMax = Int(sr / 70)
        let W = max(Int(sr * 0.03), tauMax)
        let total = W + tauMax
        let frames = x.count / hopS
        guard frames > 2 else { return [] }

        // level gate relative to the loudest part of the recording
        var rmsPerFrame = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let a = i * hopS, b = min(x.count, a + hopS * 2)
            guard b > a else { continue }
            var r: Float = 0
            x.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + a, 1, &r, vDSP_Length(b - a)) }
            rmsPerFrame[i] = r
        }
        let sortedRMS = rmsPerFrame.sorted()
        let loud = sortedRMS[min(frames - 1, Int(Double(frames) * 0.95))]
        let gate = max(0.0015, loud * 0.06)

        var out = [Float](repeating: 0, count: frames)
        var frame = [Float](repeating: 0, count: total)
        var d = [Float](repeating: 0, count: tauMax + 1)
        var cmnd = [Float](repeating: 1, count: tauMax + 1)
        var prefix = [Float](repeating: 0, count: total + 1)

        for i in 0..<frames {
            if rmsPerFrame[i] < gate { continue }
            let start = i * hopS - total / 2
            for j in 0..<total { let k = start + j; frame[j] = (k >= 0 && k < x.count) ? x[k] : 0 }
            for j in 0..<total { prefix[j + 1] = prefix[j] + frame[j] * frame[j] }
            let e0 = prefix[W]
            frame.withUnsafeBufferPointer { fp in
                for tau in 1...tauMax {
                    var r: Float = 0
                    vDSP_dotpr(fp.baseAddress!, 1, fp.baseAddress! + tau, 1, &r, vDSP_Length(W))
                    d[tau] = e0 + (prefix[tau + W] - prefix[tau]) - 2 * r
                }
            }
            var running: Float = 0
            cmnd[0] = 1
            for tau in 1...tauMax { running += d[tau]; cmnd[tau] = running > 0 ? d[tau] * Float(tau) / running : 1 }
            // first dip under the threshold, then follow it down to its minimum
            var best = -1
            var tau = tauMin
            while tau < tauMax {
                if cmnd[tau] < 0.15 {
                    while tau + 1 < tauMax && cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                    best = tau; break
                }
                tau += 1
            }
            if best < 0 {
                var m: Float = 1, mi = -1
                for t in tauMin..<tauMax where cmnd[t] < m { m = cmnd[t]; mi = t }
                if m < 0.22 { best = mi }
            }
            guard best > 1, best < tauMax else { continue }
            // parabolic refinement
            let a = cmnd[best - 1], b = cmnd[best], c = cmnd[best + 1]
            let den = a - 2 * b + c
            let shift: Float = abs(den) > 1e-9 ? 0.5 * (a - c) / den : 0
            let period = Float(best) + max(-1, min(1, shift))
            let f0 = Float(sr) / period
            out[i] = 69 + 12 * log2(f0 / 440)
        }
        return clean(out)
    }

    /// Median smoothing, octave-jump repair and removal of one-frame blips.
    static func clean(_ m: [Float]) -> [Float] {
        var x = m
        // octave jumps inside a voiced run
        for i in 1..<x.count where x[i] > 0 && x[i - 1] > 0 {
            for k in [12, -12, 24, -24] where abs(x[i] - Float(k) - x[i - 1]) < 1.0 && abs(x[i] - x[i - 1]) > 5 { x[i] -= Float(k); break }
        }
        // median of 5 over voiced neighbours
        var y = x
        for i in 2..<max(2, x.count - 2) where x[i] > 0 {
            var w = [x[i - 2], x[i - 1], x[i], x[i + 1], x[i + 2]].filter { $0 > 0 }.sorted()
            if w.count >= 3 { y[i] = w[w.count / 2] }
            w.removeAll()
        }
        // drop runs shorter than 3 frames
        var i = 0
        while i < y.count {
            if y[i] > 0 {
                var j = i; while j < y.count && y[j] > 0 { j += 1 }
                if j - i < 3 { for k in i..<j { y[k] = 0 } }
                i = j
            } else { i += 1 }
        }
        return y
    }

    /// Split the pitch track into notes locked to the nearest semitone (or scale degree).
    static func segment(_ track: [Float], scale: Set<Int>?, keyRoot: Int) -> [TuneNote] {
        var notes: [TuneNote] = []
        var i = 0
        let n = track.count
        func lockPitch(_ f: Double) -> Int {
            if let scale = scale, scale.count < 12 {
                var best = Int(f.rounded()), bestD = 99.0
                for cand in Int(f) - 3...Int(f) + 4 where scale.contains(((cand - keyRoot) % 12 + 12) % 12) {
                    let dd = abs(Double(cand) - f); if dd < bestD { bestD = dd; best = cand }
                }
                return max(0, min(127, best))
            }
            return max(0, min(127, Int(f.rounded())))
        }
        while i < n {
            guard track[i] > 0 else { i += 1; continue }
            var start = i, vals: [Float] = [], gap = 0, outliers = 0
            var j = i
            while j < n {
                if track[j] <= 0 { gap += 1; if gap > 6 { break }; j += 1; continue }
                gap = 0
                let ref = vals.isEmpty ? track[j] : vals.sorted()[vals.count / 2]
                if abs(track[j] - ref) > 0.7 {
                    outliers += 1
                    if outliers >= 4 { j -= 3; break }       // pitch moved to a new note
                } else { outliers = 0 }
                vals.append(track[j]); j += 1
            }
            // trim trailing outlier frames
            var end = min(n, j)
            while end > start, track[end - 1] <= 0 { end -= 1 }
            let used = vals
            if used.count >= 7 && end - start >= 7 {
                let med = Double(used.sorted()[used.count / 2])
                notes.append(TuneNote(start: Double(start) * hop, end: Double(end) * hop, pitch: lockPitch(med), detected: med))
            }
            i = max(end, i + 1)
            start = i
        }
        return notes
    }
}
