import Foundation

/// Works out when each piece of an audio track must start, given the tempo map and the loop.
enum AudioSchedule {
    struct Item { var file: String; var startFrame: Int64; var frames: Int64; var delay: Double }

    /// Which file to play for a clip: the tuned render when tuning is on and the render exists.
    static func playbackFile(_ c: AudioClip) -> String {
        if let t = c.tune, t.enabled {
            let tuned = AudioStore.tunedName(for: c.file, clipID: c.id)
            if FileManager.default.fileExists(atPath: AudioStore.url(tuned).path) { return tuned }
        }
        return c.file
    }

    /// `delay0`: seconds between the transport starting and `startBeat` being reached.
    static func items(_ p: Project, track: Track, startBeat: Double, delay0: Double, maxItems: Int = 3000) -> [Item] {
        guard !track.audioClips.isEmpty else { return [] }
        let sr = AudioStore.rate
        let secStart = p.seconds(atBeat: startBeat)
        var out: [Item] = []

        func add(_ c: AudioClip, window w0: Double, _ w1: Double, raw: Double) {
            let cs = p.seconds(atBeat: c.start)
            let a = max(cs, w0), b = min(cs + c.length, w1)
            guard b > a else { return }
            let frames = Int64(((b - a) * sr).rounded())
            let startFrame = Int64(((a - cs + c.offset) * sr).rounded())
            out.append(Item(file: playbackFile(c), startFrame: startFrame, frames: frames, delay: delay0 + raw + (a - w0)))
        }

        let loopOn = p.loopEnabled && p.loopEnd > p.loopStart && startBeat < p.loopEnd
        if !loopOn {
            for c in track.audioClips { add(c, window: secStart, 1e9, raw: 0) }
            return out
        }
        let ls = p.seconds(atBeat: p.loopStart), le = p.seconds(atBeat: p.loopEnd)
        for c in track.audioClips { add(c, window: secStart, le, raw: 0) }
        let L = max(0.05, le - ls)
        var raw = le - secStart
        var pass = 0
        while out.count < maxItems && pass < 2000 && raw < 20 * 60 {
            for c in track.audioClips { add(c, window: ls, le, raw: raw) }
            raw += L; pass += 1
        }
        return out
    }
}
