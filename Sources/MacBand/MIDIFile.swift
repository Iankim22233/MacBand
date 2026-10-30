import Foundation

/// Standard MIDI File reading/writing, plus the shared note→event renderer
/// (including FL-style slide notes, which become pitch-bend ramps).
enum MIDIFile {
    static let ppq = 480

    struct Ev {
        var tick: Int
        var order: Int          // tie-break at equal ticks: lower first
        var bytes: [UInt8]
        var isMeta = false
    }

    static func ticks(_ beats: Double) -> Int { max(0, Int((beats * Double(ppq)).rounded())) }

    // MARK: Byte helpers

    static func vlq(_ v: Int) -> [UInt8] {
        var value = max(0, v)
        var out: [UInt8] = [UInt8(value & 0x7F)]
        value >>= 7
        while value > 0 { out.insert(UInt8((value & 0x7F) | 0x80), at: 0); value >>= 7 }
        return out
    }
    static func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }
    static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 255), UInt8(v & 255)] }

    /// AVAudioSequencer drops events that sit exactly on its start position, so playback
    /// sequences are shifted forward by this many beats and started slightly early.
    static let playbackLead = 0.25

    static func trackChunk(_ events: [Ev], shift: Int = 0, keepTempoAtZero: Bool = false) -> [UInt8] {
        let sorted = events.map { e -> Ev in
            var e = e
            if shift != 0, !(keepTempoAtZero && e.tick == 0) { e.tick += shift }
            return e
        }.sorted { ($0.tick, $0.order) < ($1.tick, $1.order) }
        var body: [UInt8] = []
        var last = 0
        for e in sorted {
            body += vlq(e.tick - last); last = e.tick
            body += e.bytes
        }
        body += vlq(0) + [0xFF, 0x2F, 0x00]
        return Array("MTrk".utf8) + be32(body.count) + body
    }

    static func meta(_ tick: Int, _ type: UInt8, _ data: [UInt8], order: Int = 0) -> Ev {
        Ev(tick: tick, order: order, bytes: [0xFF, type] + vlq(data.count) + data, isMeta: true)
    }

    // MARK: Event rendering

    static func bendValue(_ semis: Double, range: Int) -> Int {
        let v = 8192 + Int((semis / Double(max(1, range)) * 8192).rounded())
        return min(16383, max(0, v))
    }

    /// Notes / pitch bends / volume for one track as MIDI events on `channel`.
    static func trackEvents(_ track: Track, channel: Int, forExport: Bool) -> [Ev] {
        var evs: [Ev] = []
        let ch = UInt8(channel & 15)
        func add(_ tick: Int, _ order: Int, _ b: [UInt8]) { evs.append(Ev(tick: tick, order: order, bytes: b)) }

        let hasSlides = track.clips.contains { $0.notes.contains { $0.isSlide } }
        if forExport {
            if !track.instrument.isDrums && track.instrument.plugin == nil {
                add(0, 0, [0xC0 | ch, UInt8(track.instrument.gmProgram & 127)])
            }
            add(0, 0, [0xB0 | ch, 10, UInt8(min(127, max(0, Int(64 + track.pan * 63))))])
        }
        if hasSlides {
            // RPN 0: pitch-bend sensitivity
            for (cc, v) in [(101, 0), (100, 0), (6, track.bendRange), (38, 0), (101, 127), (100, 127)] {
                add(0, 0, [0xB0 | ch, UInt8(cc), UInt8(v)])
            }
        }
        let trackGain = Double(Mixer.gain(track.volume))

        for clip in track.clips {
            let base = clip.start
            let notes: [Note] = clip.notes
                .filter { $0.start < clip.length - 1e-6 }
                .map { var n = $0; n.length = min(n.length, clip.length - n.start); return n }
                .sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
            let normals = notes.filter { !$0.isSlide }

            // Slide notes attach to the normal note sounding when they begin.
            func source(of n: Note) -> Note? {
                normals.last(where: { $0.start <= n.start + 1e-6 && $0.end > n.start + 1e-6 })
            }
            var consumedSlides = Set<UUID>()
            for n in notes where n.isSlide && source(of: n) != nil { consumedSlides.insert(n.id) }

            // Normal notes
            for n in notes where !n.isSlide || !consumedSlides.contains(n.id) {
                let on = ticks(base + n.start), off = max(on + 1, ticks(base + n.end))
                add(on, 2, [0x90 | ch, UInt8(n.pitch & 127), UInt8(min(127, max(1, n.velocity)))])
                add(off, 1, [0x80 | ch, UInt8(n.pitch & 127), 0])
            }

            // Slides: group by source note, process in time order
            var bySource: [UUID: [Note]] = [:]
            var sourceOf: [UUID: Note] = [:]
            for n in notes where consumedSlides.contains(n.id) {
                if let src = source(of: n) { bySource[src.id, default: []].append(n); sourceOf[src.id] = src }
            }
            for (sid, slides) in bySource {
                guard let src = sourceOf[sid] else { continue }
                var cur = 0.0
                for s in slides.sorted(by: { $0.start < $1.start }) {
                    let target = min(Double(track.bendRange), max(-Double(track.bendRange), Double(s.pitch - src.pitch)))
                    let t0 = base + s.start
                    let steps = max(6, Int((s.length * 12).rounded()))
                    for i in 0...steps {
                        let f = Double(i) / Double(steps)
                        let semis = cur + (target - cur) * f
                        add(ticks(t0 + s.length * f), 0, [0xE0 | ch, UInt8(bendValue(semis, range: track.bendRange) & 127), UInt8((bendValue(semis, range: track.bendRange) >> 7) & 127)])
                    }
                    cur = target
                }
                // Return to centre just before the next normal note (or shortly after this one ends)
                let nextStart = normals.filter { $0.start >= src.end - 1e-6 && $0.id != src.id }.map { $0.start }.min()
                let resetBeat = base + (nextStart.map { max(src.end, $0 - 0.01) } ?? (src.end + 2))
                add(ticks(resetBeat), 0, [0xE0 | ch, 0x00, 0x40])
            }

            // Volume automation → CC7 (export only; live playback drives the mixer fader instead)
            if forExport {
                if clip.volume.isEmpty {
                    add(ticks(base), 0, [0xB0 | ch, 7, UInt8(min(127, max(0, Int((100 * trackGain).rounded()))))])
                } else {
                    let step = 0.125
                    var b = 0.0
                    var lastCC = -1
                    while b <= clip.length + 1e-9 {
                        let g = Automation.gain(Automation.value(clip.volume, at: b) ?? Automation.unity) * trackGain
                        let cc = min(127, max(0, Int((100 * g).rounded())))
                        if cc != lastCC { add(ticks(base + b), 0, [0xB0 | ch, 7, UInt8(cc)]); lastCC = cc }
                        b += step
                    }
                }
            }
        }
        return evs
    }

    static func conductorEvents(_ p: Project) -> [Ev] {
        var evs: [Ev] = []
        func tempoEv(_ tick: Int, _ bpm: Double) {
            let us = Int((60_000_000 / max(1, bpm)).rounded())
            evs.append(meta(tick, 0x51, [UInt8((us >> 16) & 255), UInt8((us >> 8) & 255), UInt8(us & 255)]))
        }
        var dd: UInt8 = 0
        var d = p.timeSigDen; while d > 1 { d >>= 1; dd += 1 }
        evs.append(meta(0, 0x58, [UInt8(p.timeSigNum), dd, 24, 8]))
        evs.append(meta(0, 0x03, Array("Tempo".utf8)))
        tempoEv(0, p.tempo)
        var prevBeat = 0.0, prevBPM = p.tempo
        for pt in p.tempoPoints.sorted(by: { $0.beat < $1.beat }) where pt.beat > 0 {
            if pt.ramp && pt.beat > prevBeat {
                let steps = max(2, Int(((pt.beat - prevBeat) / 0.25).rounded()))
                for i in 1..<steps {
                    let f = Double(i) / Double(steps)
                    tempoEv(ticks(prevBeat + (pt.beat - prevBeat) * f), prevBPM + (pt.bpm - prevBPM) * f)
                }
            }
            tempoEv(ticks(pt.beat), pt.bpm)
            prevBeat = pt.beat; prevBPM = pt.bpm
        }
        return evs
    }

    // MARK: Writer

    /// `forExport`: general-MIDI friendly file (channels, programs, CC7). Otherwise a playback
    /// sequence for AVAudioSequencer (one MIDI track per project track, plus metronome).
    static func build(_ p: Project, forExport: Bool, metronome: Bool = false) -> Data {
        let shift = forExport ? 0 : ticks(playbackLead)
        var chunks: [[UInt8]] = [trackChunk(conductorEvents(p), shift: shift, keepTempoAtZero: true)]
        var nextChannel = 0
        for t in p.tracks {
            if forExport && t.kind == .audio { continue }
            var channel = 0
            if forExport {
                if t.instrument.isDrums { channel = 9 } else {
                    if nextChannel == 9 { nextChannel += 1 }
                    channel = nextChannel % 16; nextChannel += 1
                }
            }
            var evs = trackEvents(t, channel: channel, forExport: forExport)
            evs.append(meta(0, 0x03, Array(t.name.utf8)))
            chunks.append(trackChunk(evs, shift: shift))
        }
        if !forExport {
            var evs: [Ev] = [meta(0, 0x03, Array("Metronome".utf8))]
            if metronome {
                let bpb = Int(p.beatsPerBar.rounded(.up))
                let totalBeats = 512 * bpb
                for b in 0..<totalBeats {
                    let accent = b % max(1, bpb) == 0
                    let on = b * ppq
                    evs.append(Ev(tick: on, order: 2, bytes: [0x99, accent ? 76 : 77, accent ? 120 : 80]))
                    evs.append(Ev(tick: on + 60, order: 1, bytes: [0x89, accent ? 76 : 77, 0]))
                }
            }
            chunks.append(trackChunk(evs, shift: shift))
        }
        var out: [UInt8] = Array("MThd".utf8) + be32(6) + be16(1) + be16(chunks.count) + be16(ppq)
        for c in chunks { out += c }
        return Data(out)
    }

    // MARK: Reader

    struct ImportedTrack {
        var name: String
        var channel: Int
        var program: Int
        var notes: [Note]           // start in beats from file start
        var volume: [(beat: Double, cc: Int)]
    }
    struct Imported {
        /// How many notes were lengthened because the sustain pedal was holding them.
        var sustainedNotes = 0
        var tempo: Double = 120
        var tempoPoints: [TempoPoint] = []
        var timeSigNum = 4, timeSigDen = 4
        var tracks: [ImportedTrack] = []
    }
    enum ParseError: Error, LocalizedError {
        case notMIDI, truncated, unsupportedTiming
        var errorDescription: String? {
            switch self {
            case .notMIDI: return "This isn't a standard MIDI file."
            case .truncated: return "The MIDI file is damaged or truncated."
            case .unsupportedTiming: return "SMPTE-timed MIDI files aren't supported."
            }
        }
    }

    static func parse(_ data: Data) throws -> Imported {
        let b = [UInt8](data)
        var pos = 0
        func need(_ n: Int) throws { if pos + n > b.count { throw ParseError.truncated } }
        func u32() throws -> Int { try need(4); defer { pos += 4 }; return Int(b[pos]) << 24 | Int(b[pos+1]) << 16 | Int(b[pos+2]) << 8 | Int(b[pos+3]) }
        func u16() throws -> Int { try need(2); defer { pos += 2 }; return Int(b[pos]) << 8 | Int(b[pos+1]) }
        guard b.count >= 14, Array(b[0..<4]) == Array("MThd".utf8) else { throw ParseError.notMIDI }
        pos = 4
        let hlen = try u32()
        _ = try u16()                       // format
        let ntrks = try u16()
        let division = try u16()
        if division & 0x8000 != 0 { throw ParseError.unsupportedTiming }
        pos = 8 + hlen
        let tpq = Double(max(1, division))

        var result = Imported()
        var tempoEvents: [(tick: Int, bpm: Double)] = []
        var sawTimeSig = false
        var pedal: [Int: [(beat: Double, down: Bool)]] = [:]        // sustain pedal (CC 64) per channel, from every track
        var fileEndBeat = 0.0

        for _ in 0..<ntrks {
            guard pos + 8 <= b.count else { break }
            let isTrack = Array(b[pos..<pos+4]) == Array("MTrk".utf8)
            pos += 4
            let len = try u32()
            let end = min(b.count, pos + len)
            if !isTrack { pos = end; continue }

            var tick = 0
            var running: UInt8 = 0
            var trackName = ""
            var programs: [Int: Int] = [:]
            var active: [Int: [Int: (tick: Int, vel: Int)]] = [:]   // channel → pitch → start
            var notesByChannel: [Int: [Note]] = [:]
            var volByChannel: [Int: [(Double, Int)]] = [:]

            func readVLQ() throws -> Int {
                var v = 0
                for _ in 0..<4 {
                    try need(1)
                    let c = b[pos]; pos += 1
                    v = (v << 7) | Int(c & 0x7F)
                    if c & 0x80 == 0 { break }
                }
                return v
            }
            func finish(_ ch: Int, _ pitch: Int, at t: Int) {
                guard let on = active[ch]?[pitch] else { return }
                active[ch]?[pitch] = nil
                let s = Double(on.tick) / tpq
                let l = max(0.0625, Double(t - on.tick) / tpq)
                notesByChannel[ch, default: []].append(Note(pitch: pitch, start: s, length: l, velocity: on.vel))
            }

            while pos < end {
                tick += try readVLQ()
                try need(1)
                var status = b[pos]
                if status & 0x80 != 0 { pos += 1; if status < 0xF0 { running = status } } else { status = running }
                switch status {
                case 0xFF:
                    try need(1)
                    let type = b[pos]; pos += 1
                    let l = try readVLQ()
                    try need(l)
                    let d = Array(b[pos..<pos+l]); pos += l
                    if type == 0x51, l == 3 {
                        let us = Int(d[0]) << 16 | Int(d[1]) << 8 | Int(d[2])
                        if us > 0 { tempoEvents.append((tick, 60_000_000 / Double(us))) }
                    } else if type == 0x58, l >= 2, !sawTimeSig {
                        result.timeSigNum = Int(d[0]); result.timeSigDen = 1 << Int(d[1]); sawTimeSig = true
                    } else if type == 0x03, trackName.isEmpty {
                        trackName = String(decoding: d, as: UTF8.self)
                    } else if type == 0x2F { pos = end }
                case 0xF0, 0xF7:
                    let l = try readVLQ(); try need(l); pos += l
                default:
                    let hi = status & 0xF0, ch = Int(status & 0x0F)
                    let n = (hi == 0xC0 || hi == 0xD0) ? 1 : 2
                    try need(n)
                    let d1 = Int(b[pos]), d2 = n == 2 ? Int(b[pos+1]) : 0
                    pos += n
                    switch hi {
                    case 0x90 where d2 > 0:
                        finish(ch, d1, at: tick)
                        active[ch, default: [:]][d1] = (tick, d2)
                    case 0x80, 0x90:
                        finish(ch, d1, at: tick)
                    case 0xC0: programs[ch] = d1
                    case 0xB0 where d1 == 7: volByChannel[ch, default: []].append((Double(tick) / tpq, d2))
                    case 0xB0 where d1 == 64: pedal[ch, default: []].append((Double(tick) / tpq, d2 >= 64))
                    default: break
                    }
                }
            }
            for (ch, pitches) in active { for (p, _) in pitches { finish(ch, p, at: tick) } }
            fileEndBeat = max(fileEndBeat, Double(tick) / tpq)
            pos = end

            for ch in notesByChannel.keys.sorted() {
                let notes = notesByChannel[ch]!.sorted { $0.start < $1.start }
                guard !notes.isEmpty else { continue }
                let multi = notesByChannel.count > 1
                result.tracks.append(ImportedTrack(
                    name: trackName.isEmpty ? (ch == 9 ? "Drums" : "Track \(result.tracks.count + 1)") : (multi ? "\(trackName) \(ch + 1)" : trackName),
                    channel: ch, program: programs[ch] ?? 0, notes: notes, volume: volByChannel[ch] ?? []))
            }
        }

        result.sustainedNotes = applySustain(&result.tracks, pedal: pedal, fileEnd: fileEndBeat)

        tempoEvents.sort { $0.tick < $1.tick }
        if let first = tempoEvents.first, first.tick == 0 { result.tempo = first.bpm }
        else if let first = tempoEvents.first { result.tempo = first.bpm }
        var last = result.tempo
        for e in tempoEvents where e.tick > 0 && abs(e.bpm - last) > 0.01 {
            result.tempoPoints.append(TempoPoint(beat: Double(e.tick) / tpq, bpm: e.bpm))
            last = e.bpm
        }
        return result
    }

    /// Lengthens notes that were still being held by the sustain pedal when their key was released: they last until
    /// the pedal comes up (or until the same key is struck again). Returns how many notes changed.
    static func applySustain(_ tracks: inout [ImportedTrack], pedal: [Int: [(beat: Double, down: Bool)]], fileEnd: Double) -> Int {
        var changed = 0
        for ti in tracks.indices {
            guard let events = pedal[tracks[ti].channel]?.sorted(by: { $0.beat < $1.beat }), events.contains(where: { $0.down }) else { continue }
            var intervals: [(down: Double, up: Double)] = []
            var downAt: Double?
            for e in events {
                if e.down { if downAt == nil { downAt = e.beat } }
                else if let d = downAt { intervals.append((d, e.beat)); downAt = nil }
            }
            if let d = downAt { intervals.append((d, max(d, fileEnd))) }
            guard !intervals.isEmpty else { continue }
            var starts: [Int: [Double]] = [:]
            for n in tracks[ti].notes { starts[n.pitch, default: []].append(n.start) }
            for k in starts.keys { starts[k]!.sort() }
            for i in tracks[ti].notes.indices {
                let n = tracks[ti].notes[i]
                let end = n.start + n.length
                // the last pedal interval that began at or before the key was released
                var lo = 0, hi = intervals.count
                while lo < hi { let mid = (lo + hi) / 2; if intervals[mid].down <= end + 1e-6 { lo = mid + 1 } else { hi = mid } }
                guard lo > 0 else { continue }
                let iv = intervals[lo - 1]
                guard end < iv.up - 1e-6 else { continue }
                var newEnd = iv.up
                if let next = starts[n.pitch]?.first(where: { $0 > n.start + 1e-6 }), next > end { newEnd = min(newEnd, next) }
                if newEnd > end + 1e-6 { tracks[ti].notes[i].length = newEnd - n.start; changed += 1 }
            }
        }
        return changed
    }

    /// Build tracks (one clip each) from a parsed file.
    static func makeTracks(_ imp: Imported, beatsPerBar: Double, firstColor: Int) -> [Track] {
        var out: [Track] = []
        for (i, t) in imp.tracks.enumerated() {
            let first = t.notes.map { $0.start }.min() ?? 0
            let clipStart = (first / beatsPerBar).rounded(.down) * beatsPerBar
            var notes = t.notes
            for k in notes.indices { notes[k].start -= clipStart }
            let lastEnd = notes.map { $0.end }.max() ?? beatsPerBar
            let len = max(beatsPerBar, (lastEnd / beatsPerBar).rounded(.up) * beatsPerBar)
            var clip = Clip(name: t.name, start: clipStart, length: len, notes: notes)
            let distinct = Set(t.volume.map { $0.cc })
            if distinct.count > 1 {
                clip.volume = t.volume.map { v in
                    AutoPoint(beat: max(0, v.beat - clipStart), value: min(1, Automation.unity * (Double(max(v.cc, 0)) / 100).squareRoot()))
                }
                // CC7 = 100 is "unity" in the importer; drop the leading 0-beat duplicates
                clip.volume.sort { $0.beat < $1.beat }
            }
            var track = Track(name: t.name, colorIndex: firstColor + i)
            track.instrument = InstrumentSpec(gmProgram: t.program, isDrums: t.channel == 9)
            track.clips = [clip]
            out.append(track)
        }
        return out
    }
}
