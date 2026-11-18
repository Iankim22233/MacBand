import Foundation

/// MusicXML reader (`.musicxml`, `.xml`, and compressed `.mxl`). It produces the same `MIDIFile.Imported` the MIDI
/// importer does, so tempo handling, track creation and undo are shared with MIDI import.
///
/// Handled: partwise and timewise scores, chords, ties, transposing instruments, drum parts (`<unpitched>`),
/// tempo marks (`<sound tempo>` or a metronome mark), dynamics, repeats with 1st/2nd endings and pickup bars.
/// Not handled: D.C./D.S./coda jumps, grace notes (they take no time and are skipped) and gradual tempo changes.
enum MusicXML {
    enum ParseError: Error, LocalizedError {
        case notMusicXML, badArchive, malformed(String)
        var errorDescription: String? {
            switch self {
            case .notMusicXML: return "This isn't a MusicXML score."
            case .badArchive: return "Couldn't find a score inside this compressed MusicXML (.mxl) file."
            case .malformed(let why): return "The MusicXML file is damaged (\(why))."
            }
        }
    }

    static func load(url: URL) throws -> MIDIFile.Imported {
        if url.pathExtension.lowercased() == "mxl" { return try parse(try unpack(url)) }
        return try parse(try Data(contentsOf: url))
    }

    static func parse(_ data: Data) throws -> MIDIFile.Imported {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        guard reader.isMusicXML else { throw ParseError.notMusicXML }
        guard ok else { throw ParseError.malformed(parser.parserError?.localizedDescription ?? "unreadable XML") }
        return reader.build()
    }

    // MARK: Compressed .mxl

    /// `.mxl` is a zip whose META-INF/container.xml names the score file.
    private static func unpack(_ url: URL) throws -> Data {
        var root: String?
        if let c = unzip(url, "META-INF/container.xml"), let s = String(data: c, encoding: .utf8),
           let r = s.range(of: #"full-path\s*=\s*"[^"]+""#, options: .regularExpression) {
            let parts = s[r].split(separator: "\"")
            if parts.count >= 2 { root = String(parts[1]) }
        }
        if root == nil, let list = unzip(url, nil).flatMap({ String(data: $0, encoding: .utf8) }) {
            root = list.split(whereSeparator: \.isNewline).map(String.init)
                .first { !$0.hasPrefix("META-INF") && ($0.hasSuffix(".xml") || $0.hasSuffix(".musicxml")) }
        }
        guard let root, let data = unzip(url, root) else { throw ParseError.badArchive }
        return data
    }

    /// Reads one member of a zip (or lists the members when `member` is nil) with the system `unzip`.
    private static func unzip(_ archive: URL, _ member: String?) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = member.map { ["-p", archive.path, $0] } ?? ["-Z1", archive.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    /// A General MIDI program guessed from a part's name, for files that don't say which sound they want.
    static func guessProgram(_ name: String) -> Int? {
        let n = name.lowercased()
        let table: [(String, Int)] = [
            ("harpsichord", 6), ("piano", 0), ("klavier", 0), ("organ", 19), ("accordion", 21),
            ("electric bass", 33), ("bass guitar", 33), ("double bass", 43), ("contrabass", 43), ("contrebasse", 43),
            ("guitar", 25), ("viola", 41), ("violin", 40), ("cello", 42), ("harp", 46), ("timpani", 47), ("string", 48),
            ("english horn", 69), ("french horn", 60), ("horn", 60), ("trumpet", 56), ("trombone", 57), ("tuba", 58),
            ("sax", 65), ("oboe", 68), ("bassoon", 70), ("clarinet", 71), ("piccolo", 72), ("flute", 73), ("recorder", 74),
            ("glockenspiel", 9), ("vibraphone", 11), ("marimba", 12), ("xylophone", 13),
            ("choir", 52), ("vocal", 52), ("voice", 52), ("soprano", 52), ("alto", 52), ("tenor", 52), ("synth", 80),
            ("bass", 32),
        ]
        return table.first { n.contains($0.0) }?.1
    }

    // MARK: Reader

    private final class Reader: NSObject, XMLParserDelegate {
        struct PartInfo {
            var id: String
            var name = ""
            var firstInstrument: String?
            var divisions = 1.0
            var velocity = 80
            var transpose = 0
            var sawUnpitched = false
        }
        struct InstrumentInfo { var program: Int?; var channel: Int?; var unpitched: Int? }
        struct RawNote {
            var part: Int, staff: Int, voice: Int, pitch: Int
            var start: Double, length: Double
            var velocity: Int
            var tieStart: Bool, tieStop: Bool
        }
        struct Measure {
            var notes: [RawNote] = []
            var tempos: [(beat: Double, bpm: Double)] = []
            var contentEnd = 0.0
            var sigLen: Double?
            var implicit = false
            var forwardRepeat = false, backwardRepeat = false, times = 2
            var endings: Set<Int>?
        }
        struct NoteAcc {
            var chord = false, rest = false, grace = false, cue = false, unpitched = false
            var step: String?, alter: Double?, octave: Int?
            var displayStep: String?, displayOctave: Int?
            var duration = 0.0
            var tieStart = false, tieStop = false
            var voice = 1, staff = 1
            var instrumentID: String?
            var dynamics: Double?
        }

        static let stepBase: [String: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        static let dynamicMarks: [String: Int] = [
            "pppp": 12, "ppp": 22, "pp": 36, "p": 50, "mp": 65, "mf": 80, "f": 96, "ff": 112, "fff": 124, "ffff": 127,
            "fp": 96, "sf": 112, "sfp": 112, "sfz": 112, "sffz": 124, "fz": 112, "rfz": 112, "rf": 104,
        ]

        var isMusicXML = false
        var timewise = false
        var stack: [String] = []
        var text = ""

        var parts: [PartInfo] = []
        var instruments: [String: InstrumentInfo] = [:]
        var scorePart = -1
        var currentInstrument: String?

        var measures: [Measure] = []
        var mi = -1
        var curPart = 0
        var leadPart: Int?
        var cursor = 0.0, lastStart = 0.0
        var acc: NoteAcc?

        var inDirection = false, sawSoundTempo = false
        var metroUnit = "quarter", metroDots = 0, metroPerMinute: Double?, metroBPM: Double?

        var currentEnding: Set<Int>?
        var lastSigLen: Double?
        var sigNum = 4, sigDen = 4, sawSig = false
        var beatsText = "", beatTypeText = ""
        var chromatic = 0, octaveChange = 0

        var isLead: Bool { curPart == leadPart }

        // MARK: XMLParserDelegate

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            if stack.isEmpty {
                guard name == "score-partwise" || name == "score-timewise" else { isMusicXML = false; parser.abortParsing(); return }
                isMusicXML = true
                timewise = name == "score-timewise"
            }
            let parent = stack.last ?? ""
            stack.append(name)
            text = ""

            switch name {
            case "score-part":
                parts.append(PartInfo(id: a["id"] ?? "P\(parts.count + 1)"))
                scorePart = parts.count - 1
                currentInstrument = nil
            case "midi-instrument":
                currentInstrument = a["id"]
                if let id = currentInstrument {
                    instruments[id] = instruments[id] ?? InstrumentInfo()
                    if scorePart >= 0, parts[scorePart].firstInstrument == nil { parts[scorePart].firstInstrument = id }
                }
            case "part" where parent.hasPrefix("score-"):
                let id = a["id"] ?? ""
                if let i = parts.firstIndex(where: { $0.id == id }) { curPart = i }
                else { parts.append(PartInfo(id: id)); curPart = parts.count - 1 }
                if leadPart == nil { leadPart = curPart }
                cursor = 0; lastStart = 0
                if !timewise { mi = -1; currentEnding = nil }
            case "measure":
                mi += 1
                cursor = 0; lastStart = 0
                if mi >= measures.count {
                    var m = Measure()
                    m.sigLen = lastSigLen
                    m.implicit = a["implicit"] == "yes" || a["number"] == "0"
                    m.endings = currentEnding
                    measures.append(m)
                }
            case "note":
                var n = NoteAcc()
                n.dynamics = a["dynamics"].flatMap { Double($0) }
                acc = n
            case "chord": acc?.chord = true
            case "rest": if parent == "note" { acc?.rest = true }
            case "grace": acc?.grace = true
            case "cue": acc?.cue = true
            case "unpitched": acc?.unpitched = true
            case "tie", "tied":
                if acc != nil {
                    let type = a["type"] ?? ""
                    if type == "start" || type == "continue" { acc?.tieStart = true }
                    if type == "stop" || type == "continue" { acc?.tieStop = true }
                }
            case "instrument": if parent == "note" { acc?.instrumentID = a["id"] }
            case "transpose": chromatic = 0; octaveChange = 0
            case "time": beatsText = ""; beatTypeText = ""
            case "direction": inDirection = true; sawSoundTempo = false; metroBPM = nil
            case "metronome": metroUnit = "quarter"; metroDots = 0; metroPerMinute = nil
            case "sound":
                guard mi >= 0 else { break }
                if let t = a["tempo"].flatMap({ Double($0) }) {
                    addTempo(t)
                    if inDirection { sawSoundTempo = true }
                }
                if let d = a["dynamics"].flatMap({ Double($0) }), curPart < parts.count {
                    parts[curPart].velocity = max(1, min(127, Int((d / 100 * 90).rounded())))
                }
            case "repeat":
                guard mi >= 0, isLead else { break }
                if a["direction"] == "forward" { measures[mi].forwardRepeat = true }
                else if a["direction"] == "backward" {
                    measures[mi].backwardRepeat = true
                    measures[mi].times = max(2, min(9, Int(a["times"] ?? "") ?? 2))
                }
            case "ending":
                guard mi >= 0, isLead else { break }
                let nums = Set((a["number"] ?? "").split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) })
                switch a["type"] {
                case "start":
                    currentEnding = nums.isEmpty ? nil : nums
                    measures[mi].endings = currentEnding
                case "stop", "discontinue":
                    if measures[mi].endings == nil, !nums.isEmpty { measures[mi].endings = nums }
                    currentEnding = nil
                default: break
                }
            default:
                if parent == "dynamics", curPart < parts.count, let v = Reader.dynamicMarks[name] { parts[curPart].velocity = v }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let parent = stack.count >= 2 ? stack[stack.count - 2] : ""
            stack.removeLast()
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""

            switch name {
            case "part-name": if parent == "score-part", scorePart >= 0 { parts[scorePart].name = t }
            case "midi-channel": if let id = currentInstrument { instruments[id]?.channel = Int(t) }
            case "midi-program": if let id = currentInstrument { instruments[id]?.program = Int(t) }
            case "midi-unpitched": if let id = currentInstrument { instruments[id]?.unpitched = Int(t) }
            case "midi-instrument": currentInstrument = nil
            case "divisions": if let d = Double(t), d > 0, curPart < parts.count { parts[curPart].divisions = d }
            case "step": if parent == "pitch" { acc?.step = t }
            case "alter": if parent == "pitch" { acc?.alter = Double(t) }
            case "octave": if parent == "pitch" { acc?.octave = Int(t) }
            case "display-step": if parent == "unpitched" { acc?.displayStep = t }
            case "display-octave": if parent == "unpitched" { acc?.displayOctave = Int(t) }
            case "voice": if parent == "note" { acc?.voice = Int(t) ?? 1 }
            case "staff": if parent == "note" { acc?.staff = Int(t) ?? 1 }
            case "duration":
                let d = Double(t) ?? 0
                guard curPart < parts.count else { break }
                switch parent {
                case "note": acc?.duration = d
                case "backup": cursor = max(0, cursor - d / parts[curPart].divisions)
                case "forward": cursor += d / parts[curPart].divisions; touch()
                default: break
                }
            case "chromatic": chromatic = Int(t) ?? 0
            case "octave-change": octaveChange = Int(t) ?? 0
            case "transpose": if parent == "attributes", curPart < parts.count { parts[curPart].transpose = chromatic + 12 * octaveChange }
            case "beats": beatsText = t
            case "beat-type": beatTypeText = t
            case "time": endTime()
            case "beat-unit": if parent == "metronome" { metroUnit = t }
            case "beat-unit-dot": metroDots += 1
            case "per-minute":
                let digits = t.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
                metroPerMinute = Double(digits)
            case "metronome":
                if let pm = metroPerMinute {
                    let unit: [String: Double] = ["whole": 4, "half": 2, "quarter": 1, "eighth": 0.5, "16th": 0.25, "32nd": 0.125, "64th": 0.0625]
                    metroBPM = pm * (unit[metroUnit] ?? 1) * (2 - pow(0.5, Double(metroDots)))
                }
            case "direction":
                if !sawSoundTempo, let b = metroBPM, mi >= 0 { addTempo(b) }
                inDirection = false
            case "note": finishNote()
            default: break
            }
        }

        // MARK: Pieces

        func touch() { if mi >= 0 { measures[mi].contentEnd = max(measures[mi].contentEnd, cursor) } }

        func addTempo(_ bpm: Double) {
            guard mi >= 0, bpm >= 10, bpm <= 600 else { return }
            if measures[mi].tempos.contains(where: { abs($0.beat - cursor) < 1e-6 }) { return }
            measures[mi].tempos.append((cursor, bpm))
        }

        func endTime() {
            guard mi >= 0, isLead else { return }
            let nums = beatsText.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard !nums.isEmpty, let den = Int(beatTypeText.split(whereSeparator: { !$0.isNumber }).first ?? ""), den > 0 else { return }
            let num = nums.reduce(0, +)
            let len = Double(num) * 4 / Double(den)
            measures[mi].sigLen = len
            lastSigLen = len
            if !sawSig { sawSig = true; sigNum = num; sigDen = den }
        }

        func finishNote() {
            guard let n = acc, mi >= 0, curPart < parts.count else { acc = nil; return }
            acc = nil
            if n.grace { return }
            let dur = n.duration / parts[curPart].divisions
            let start = n.chord ? lastStart : cursor
            if !n.chord { lastStart = cursor; cursor += dur }
            touch()
            if n.rest || n.cue || dur <= 0 { return }

            var pitch: Int
            if n.unpitched {
                parts[curPart].sawUnpitched = true
                let id = n.instrumentID ?? parts[curPart].firstInstrument
                if let id, let u = instruments[id]?.unpitched { pitch = u - 1 }
                else if let s = n.displayStep, let o = n.displayOctave, let base = Reader.stepBase[s] { pitch = (o + 1) * 12 + base }
                else { pitch = 38 }
            } else if let s = n.step, let o = n.octave, let base = Reader.stepBase[s] {
                pitch = (o + 1) * 12 + base + Int((n.alter ?? 0).rounded()) + parts[curPart].transpose
            } else { return }
            pitch = max(0, min(127, pitch))

            let velocity = n.dynamics.map { max(1, min(127, Int(($0 / 100 * 90).rounded()))) } ?? parts[curPart].velocity
            measures[mi].notes.append(RawNote(part: curPart, staff: n.staff, voice: n.voice, pitch: pitch, start: start, length: dur,
                                              velocity: velocity, tieStart: n.tieStart, tieStop: n.tieStop))
        }

        // MARK: Result

        /// The order the measures are played in once repeats and 1st/2nd endings are unrolled.
        func playOrder() -> [Int] {
            var order: [Int] = []
            var i = 0, start = 0, pass = 1
            while i < measures.count {
                let m = measures[i]
                if m.forwardRepeat && !(i == start && pass > 1) { start = i; pass = 1 }
                if let e = m.endings, !e.contains(pass) { i += 1; continue }
                order.append(i)
                if m.backwardRepeat {
                    if pass < m.times { pass += 1; i = start; continue }
                    pass = 1; start = i + 1
                } else if m.endings != nil, i + 1 >= measures.count || measures[i + 1].endings == nil {
                    pass = 1; start = i + 1                      // end of a 1st/2nd-ending group
                }
                i += 1
            }
            return order
        }

        func length(of i: Int) -> Double {
            let m = measures[i]
            if m.implicit { return m.contentEnd > 0 ? m.contentEnd : (m.sigLen ?? 4) }
            return max(m.sigLen ?? 4, m.contentEnd)
        }

        func build() -> MIDIFile.Imported {
            var imp = MIDIFile.Imported()
            imp.timeSigNum = sigNum; imp.timeSigDen = sigDen

            let order = playOrder()
            // A pickup bar is moved so that it ends on a bar line and the first full bar lands on beat 0 of a bar.
            var offset = 0.0
            if let f = order.first, measures[f].implicit, let sig = measures[f].sigLen, length(of: f) < sig { offset = sig - length(of: f) }

            var notes = [[MIDIFile.Imported.Raw]](repeating: [], count: parts.count)
            var tempos: [(beat: Double, bpm: Double)] = []
            var open: [[Int]: Int] = [:]                    // (part, pitch, staff, voice) -> index into notes[part]
            for i in order {
                for n in measures[i].notes {
                    let at = offset + n.start
                    let key = [n.part, n.pitch, n.staff, n.voice]
                    if n.tieStop, let idx = open[key], Swift.abs(at - notes[n.part][idx].end) < 0.01 {
                        notes[n.part][idx].length += n.length
                        if !n.tieStart { open[key] = nil }
                        continue
                    }
                    notes[n.part].append(MIDIFile.Imported.Raw(pitch: n.pitch, start: at, length: n.length, velocity: n.velocity))
                    open[key] = n.tieStart ? notes[n.part].count - 1 : nil
                }
                for t in measures[i].tempos { tempos.append((offset + t.beat, t.bpm)) }
                offset += length(of: i)
            }

            for (p, raw) in notes.enumerated() where !raw.isEmpty {
                let info = parts[p]
                let inst = info.firstInstrument.flatMap { instruments[$0] }
                let drums = info.sawUnpitched || inst?.channel == 10
                let name = info.name.isEmpty ? "Part \(p + 1)" : info.name
                let program = drums ? 0 : (inst?.program.map { max(0, min(127, $0 - 1)) } ?? MusicXML.guessProgram(name) ?? 0)
                let sorted = raw.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
                imp.tracks.append(MIDIFile.ImportedTrack(
                    name: name, channel: drums ? 9 : 0, program: program,
                    notes: sorted.map { Note(pitch: $0.pitch, start: $0.start, length: $0.length, velocity: $0.velocity) },
                    volume: []))
            }

            tempos.sort { $0.beat < $1.beat }
            if let first = tempos.first { imp.tempo = first.bpm }
            var last = imp.tempo
            for t in tempos where t.beat > 1e-6 && abs(t.bpm - last) > 0.01 {
                imp.tempoPoints.append(TempoPoint(beat: t.beat, bpm: t.bpm))
                last = t.bpm
            }
            return imp
        }
    }
}

extension MIDIFile.Imported {
    /// A note while a MusicXML score is being unrolled and its ties joined.
    struct Raw {
        var pitch: Int
        var start: Double
        var length: Double
        var velocity: Int
        var end: Double { start + length }
    }
}
