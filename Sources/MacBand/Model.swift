import Foundation
import SwiftUI

// MARK: - Plugins

enum PluginFormat: String, Codable { case au, vst3 }

/// A reference to an installed plugin (AU or VST3) plus its saved state.
struct PluginSpec: Codable, Hashable, Identifiable {
    var id = UUID()
    var format: PluginFormat
    var name: String
    var vendor: String = ""
    var isInstrument: Bool
    // AU
    var auType: UInt32 = 0
    var auSubtype: UInt32 = 0
    var auManufacturer: UInt32 = 0
    // VST3
    var vst3Path: String = ""
    var vst3ClassID: String = ""
    // Saved plugin state (AU fullState plist / VST3 component+controller state)
    var state: Data? = nil
    var bypassed: Bool = false

    /// Identity of the plugin itself (ignores instance id and state).
    var key: String {
        format == .au ? "au:\(auType):\(auSubtype):\(auManufacturer)" : "vst3:\(vst3Path):\(vst3ClassID)"
    }
}

// MARK: - Music data

struct Note: Codable, Identifiable, Hashable {
    var id = UUID()
    var pitch: Int
    var start: Double       // beats, relative to clip start
    var length: Double      // beats
    var velocity: Int = 100
    /// FL-style slide note: glides the currently sounding note to this note's pitch,
    /// taking this note's length to get there.
    var isSlide: Bool = false
    var end: Double { start + length }
}

struct AutoPoint: Codable, Identifiable, Hashable {
    var id = UUID()
    var beat: Double        // relative to clip start
    var value: Double       // 0...1, 0.75 == 0 dB
}

enum Automation {
    static let unity = 0.75
    static func gain(_ v: Double) -> Double {
        if v <= 0 { return 0 }
        let g = v / unity
        return g * g
    }
    /// Value of a point list at `beat`; nil when there is no automation.
    static func value(_ pts: [AutoPoint], at beat: Double) -> Double? {
        guard let first = pts.first else { return nil }
        if beat <= first.beat { return first.value }
        for i in 1..<pts.count where beat <= pts[i].beat {
            let a = pts[i - 1], b = pts[i]
            let span = b.beat - a.beat
            if span <= 0 { return b.value }
            return a.value + (b.value - a.value) * (beat - a.beat) / span
        }
        return pts.last!.value
    }
}

struct Clip: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = "Pattern"
    var start: Double       // beats on the timeline
    var length: Double      // beats
    var notes: [Note] = []
    var volume: [AutoPoint] = []   // volume automation, sorted by beat
    var end: Double { start + length }

    mutating func fitLengthToNotes(minBeats: Double, quantum: Double) {
        let last = notes.map { $0.end }.max() ?? 0
        let needed = max(minBeats, (last / quantum).rounded(.up) * quantum)
        length = max(length, needed)
    }
}

struct InstrumentSpec: Codable, Hashable {
    var gmProgram: Int = 0          // General MIDI program (built-in sampler)
    var isDrums: Bool = false
    var plugin: PluginSpec? = nil   // overrides the built-in sampler when set
    var displayName: String {
        if let p = plugin { return p.name }
        return isDrums ? "Drum Kit" : GM.programs[min(max(gmProgram, 0), 127)]
    }
}

enum TrackKind: String, Codable { case instrument, audio }

struct Track: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var colorIndex: Int
    var kind: TrackKind = .instrument
    var instrument = InstrumentSpec()
    var inserts: [PluginSpec] = []
    var volume: Double = 0.8        // fader 0...1 (see Mixer.gain)
    var pan: Double = 0             // -1...1
    var mute = false
    var solo = false
    var bendRange: Int = 12         // semitones, used for slide notes
    var clips: [Clip] = []
    var audioClips: [AudioClip] = []

    init(name: String, colorIndex: Int, kind: TrackKind = .instrument) {
        self.name = name; self.colorIndex = colorIndex; self.kind = kind
    }

    /// Tolerant decoding so projects saved before audio tracks existed still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Track"
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        kind = try c.decodeIfPresent(TrackKind.self, forKey: .kind) ?? .instrument
        instrument = try c.decodeIfPresent(InstrumentSpec.self, forKey: .instrument) ?? InstrumentSpec()
        inserts = try c.decodeIfPresent([PluginSpec].self, forKey: .inserts) ?? []
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 0.8
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        mute = try c.decodeIfPresent(Bool.self, forKey: .mute) ?? false
        solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        bendRange = try c.decodeIfPresent(Int.self, forKey: .bendRange) ?? 12
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        audioClips = try c.decodeIfPresent([AudioClip].self, forKey: .audioClips) ?? []
    }
}

// MARK: - Audio & vocal tuning

/// A note transcribed from a vocal: locked to the nearest pitch, with the word sung on it.
struct TuneNote: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: Double               // seconds in the audio file
    var end: Double
    var pitch: Int                  // target MIDI note the voice is tuned to
    var detected: Double = 0        // average detected pitch (MIDI, fractional)
    var word: String = ""
    /// Where the glide into the next note begins (seconds in the file). nil = at the note's end.
    /// Earlier than the end = a slower glide (“speed”), later = the correction waits (“pause”).
    var marker: Double? = nil
    var edited = false
    /// Additional target pitches for the same word (chord / harmony voices). The voice is shifted to
    /// each of them and mixed in, so one sung word becomes a chord.
    var extra: [Int] = []
    var voices: [Int] { [pitch] + extra }
    var length: Double { end - start }
}

struct TuneData: Codable, Hashable {
    var enabled = false             // tuning applied to playback
    var amount = 1.0                // 0…1 how far toward the target the voice is pulled
    var defaultGlide = 0.04         // seconds
    var snapToScale = true
    var analyzed = false
    var notes: [TuneNote] = []
    var pitch = Data()              // detected pitch, Float32 MIDI per 10 ms frame, 0 = unvoiced
    var transcript = ""
    var status = ""                 // e.g. why words are missing
    var revision = 0                // bumps when the tuned audio needs re-rendering
}

struct AudioClip: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var start: Double               // beats on the timeline
    var file: String                // file name inside the managed audio folder
    var sourceName = ""
    var duration: Double            // seconds in the file
    var offset: Double = 0          // seconds trimmed from the file start
    var length: Double              // seconds shown/played
    var peaks = Data()              // 100 values per second (0…255)
    var tune: TuneData? = nil
}

enum Mixer {
    /// Fader position 0...1 → linear gain; 0.8 is unity.
    static func gain(_ f: Double) -> Float {
        if f <= 0 { return 0 }
        let g = f / 0.8
        return Float(g * g)
    }
}

struct TempoPoint: Codable, Identifiable, Hashable {
    var id = UUID()
    var beat: Double
    var bpm: Double
    var ramp: Bool = false      // glide from the previous tempo to this one
}

struct Project: Codable {
    var version = 1
    var name = "Untitled"
    var tempo: Double = 120                 // tempo at beat 0
    var tempoPoints: [TempoPoint] = []      // changes after beat 0, sorted
    var timeSigNum = 4
    var timeSigDen = 4
    var loopEnabled = false
    var loopStart: Double = 0
    var loopEnd: Double = 0                 // empty until a loop range is set
    var keyRoot = 0                         // 0 = C
    var scale: ScaleKind = .chromatic
    var masterVolume: Double = 0.8
    var tracks: [Track] = []

    var beatsPerBar: Double { Double(timeSigNum) * 4.0 / Double(timeSigDen) }

    init() {}

    /// Tolerant decoding: projects saved by older versions (fields that didn't exist yet) still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        tempo = try c.decodeIfPresent(Double.self, forKey: .tempo) ?? 120
        tempoPoints = try c.decodeIfPresent([TempoPoint].self, forKey: .tempoPoints) ?? []
        timeSigNum = try c.decodeIfPresent(Int.self, forKey: .timeSigNum) ?? 4
        timeSigDen = try c.decodeIfPresent(Int.self, forKey: .timeSigDen) ?? 4
        loopEnabled = try c.decodeIfPresent(Bool.self, forKey: .loopEnabled) ?? false
        loopStart = try c.decodeIfPresent(Double.self, forKey: .loopStart) ?? 0
        loopEnd = try c.decodeIfPresent(Double.self, forKey: .loopEnd) ?? 0
        keyRoot = try c.decodeIfPresent(Int.self, forKey: .keyRoot) ?? 0
        scale = try c.decodeIfPresent(ScaleKind.self, forKey: .scale) ?? .chromatic
        masterVolume = try c.decodeIfPresent(Double.self, forKey: .masterVolume) ?? 0.8
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
    }

    /// Beat where the last clip ends (at least 4 bars).
    var contentEnd: Double {
        let midi = tracks.flatMap { $0.clips }.map { $0.end }.max() ?? 0
        let audio = tracks.flatMap { $0.audioClips }.map { c in beat(atSeconds: seconds(atBeat: c.start) + c.length) }.max() ?? 0
        return max(max(midi, audio), beatsPerBar * 4)
    }

    // MARK: Tempo map

    /// Piecewise tempo segments: (startBeat, startBPM, endBPM) where endBPM differs when ramping.
    func tempoSegments(upTo limit: Double) -> [(beat: Double, from: Double, to: Double)] {
        var segs: [(Double, Double, Double)] = []
        var curBeat = 0.0, curBPM = tempo
        for p in tempoPoints.sorted(by: { $0.beat < $1.beat }) where p.beat > 0 {
            if p.ramp {
                segs.append((curBeat, curBPM, p.bpm)); // ramp spans previous point → this point
            } else {
                segs.append((curBeat, curBPM, curBPM))
            }
            curBeat = p.beat; curBPM = p.bpm
        }
        segs.append((curBeat, curBPM, curBPM))
        return segs
    }

    func bpm(at beat: Double) -> Double {
        let pts = tempoPoints.sorted(by: { $0.beat < $1.beat })
        var prevBeat = 0.0, prevBPM = tempo
        for p in pts {
            if beat < p.beat {
                if p.ramp, p.beat > prevBeat {
                    return prevBPM + (p.bpm - prevBPM) * (beat - prevBeat) / (p.beat - prevBeat)
                }
                return prevBPM
            }
            prevBeat = p.beat; prevBPM = p.bpm
        }
        return prevBPM
    }

    /// Inverse of `seconds(atBeat:)`.
    func beat(atSeconds t: Double) -> Double {
        if t <= 0 { return 0 }
        var lo = 0.0, hi = max(16, t * 4)
        while seconds(atBeat: hi) < t && hi < 1e7 { hi *= 2 }
        for _ in 0..<60 { let mid = (lo + hi) / 2; if seconds(atBeat: mid) < t { lo = mid } else { hi = mid } }
        return (lo + hi) / 2
    }

    /// Wall-clock seconds from beat 0 to `beat`.
    func seconds(atBeat beat: Double) -> Double {
        var t = 0.0, prevBeat = 0.0, prevBPM = tempo
        let pts = tempoPoints.sorted(by: { $0.beat < $1.beat })
        func seg(_ b0: Double, _ b1: Double, _ bpm0: Double, _ bpm1: Double) -> Double {
            guard b1 > b0 else { return 0 }
            if abs(bpm1 - bpm0) < 1e-9 { return (b1 - b0) * 60 / bpm0 }
            return (b1 - b0) * 60 * log(bpm1 / bpm0) / (bpm1 - bpm0)   // ∫ 60/bpm(b) db, linear bpm
        }
        for p in pts {
            if beat <= p.beat {
                let endBPM = p.ramp ? bpm(at: beat) : prevBPM
                return t + seg(prevBeat, beat, prevBPM, endBPM)
            }
            t += seg(prevBeat, p.beat, prevBPM, p.ramp ? p.bpm : prevBPM)
            prevBeat = p.beat; prevBPM = p.bpm
        }
        return t + seg(prevBeat, beat, prevBPM, prevBPM)
    }
}

// MARK: - Music theory helpers

enum ScaleKind: String, Codable, CaseIterable, Identifiable {
    case chromatic = "Chromatic", major = "Major", minor = "Minor"
    case dorian = "Dorian", mixolydian = "Mixolydian"
    case pentatonicMajor = "Major Pentatonic", pentatonicMinor = "Minor Pentatonic", blues = "Blues"
    var id: String { rawValue }
    var intervals: Set<Int> {
        switch self {
        case .chromatic: return Set(0..<12)
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .minor: return [0, 2, 3, 5, 7, 8, 10]
        case .dorian: return [0, 2, 3, 5, 7, 9, 10]
        case .mixolydian: return [0, 2, 4, 5, 7, 9, 10]
        case .pentatonicMajor: return [0, 2, 4, 7, 9]
        case .pentatonicMinor: return [0, 3, 5, 7, 10]
        case .blues: return [0, 3, 5, 6, 7, 10]
        }
    }
}

enum Pitch {
    static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static func name(_ p: Int) -> String { "\(names[((p % 12) + 12) % 12])\(p / 12 - 1)" }
    static func isBlack(_ p: Int) -> Bool { [1, 3, 6, 8, 10].contains(((p % 12) + 12) % 12) }
}

// MARK: - Palette

enum Palette {
    static let trackColors: [Color] = [
        Color(red: 0.96, green: 0.52, blue: 0.22),  // orange
        Color(red: 0.30, green: 0.69, blue: 0.95),  // blue
        Color(red: 0.55, green: 0.82, blue: 0.42),  // green
        Color(red: 0.90, green: 0.40, blue: 0.60),  // pink
        Color(red: 0.70, green: 0.55, blue: 0.95),  // violet
        Color(red: 0.95, green: 0.80, blue: 0.30),  // yellow
        Color(red: 0.35, green: 0.82, blue: 0.78),  // teal
        Color(red: 0.92, green: 0.45, blue: 0.40),  // red
    ]
    /// Colour 0 follows the system accent colour; the rest are fixed.
    static func nsColor(_ i: Int) -> NSColor { i % trackColors.count == 0 ? NSColor.controlAccentColor : NSColor(trackColors[i % trackColors.count]) }
    static func color(_ i: Int) -> Color { i % trackColors.count == 0 ? Color(nsColor: NSColor.controlAccentColor) : trackColors[i % trackColors.count] }
}

// MARK: - General MIDI

enum GM {
    static let programs: [String] = [
        "Acoustic Grand Piano", "Bright Acoustic Piano", "Electric Grand Piano", "Honky-tonk Piano",
        "Electric Piano 1", "Electric Piano 2", "Harpsichord", "Clavinet",
        "Celesta", "Glockenspiel", "Music Box", "Vibraphone", "Marimba", "Xylophone", "Tubular Bells", "Dulcimer",
        "Drawbar Organ", "Percussive Organ", "Rock Organ", "Church Organ", "Reed Organ", "Accordion", "Harmonica", "Tango Accordion",
        "Nylon Guitar", "Steel Guitar", "Jazz Guitar", "Clean Guitar", "Muted Guitar", "Overdriven Guitar", "Distortion Guitar", "Guitar Harmonics",
        "Acoustic Bass", "Finger Bass", "Pick Bass", "Fretless Bass", "Slap Bass 1", "Slap Bass 2", "Synth Bass 1", "Synth Bass 2",
        "Violin", "Viola", "Cello", "Contrabass", "Tremolo Strings", "Pizzicato Strings", "Orchestral Harp", "Timpani",
        "String Ensemble 1", "String Ensemble 2", "Synth Strings 1", "Synth Strings 2", "Choir Aahs", "Voice Oohs", "Synth Voice", "Orchestra Hit",
        "Trumpet", "Trombone", "Tuba", "Muted Trumpet", "French Horn", "Brass Section", "Synth Brass 1", "Synth Brass 2",
        "Soprano Sax", "Alto Sax", "Tenor Sax", "Baritone Sax", "Oboe", "English Horn", "Bassoon", "Clarinet",
        "Piccolo", "Flute", "Recorder", "Pan Flute", "Blown Bottle", "Shakuhachi", "Whistle", "Ocarina",
        "Square Lead", "Saw Lead", "Calliope Lead", "Chiff Lead", "Charang Lead", "Voice Lead", "Fifths Lead", "Bass + Lead",
        "New Age Pad", "Warm Pad", "Polysynth Pad", "Choir Pad", "Bowed Pad", "Metallic Pad", "Halo Pad", "Sweep Pad",
        "Rain FX", "Soundtrack FX", "Crystal FX", "Atmosphere FX", "Brightness FX", "Goblins FX", "Echoes FX", "Sci-Fi FX",
        "Sitar", "Banjo", "Shamisen", "Koto", "Kalimba", "Bagpipe", "Fiddle", "Shanai",
        "Tinkle Bell", "Agogo", "Steel Drums", "Woodblock", "Taiko Drum", "Melodic Tom", "Synth Drum", "Reverse Cymbal",
        "Guitar Fret Noise", "Breath Noise", "Seashore", "Bird Tweet", "Telephone Ring", "Helicopter", "Applause", "Gunshot",
    ]
    static let families: [(String, ClosedRange<Int>)] = [
        ("Piano", 0...7), ("Chromatic Percussion", 8...15), ("Organ", 16...23), ("Guitar", 24...31),
        ("Bass", 32...39), ("Strings", 40...47), ("Ensemble", 48...55), ("Brass", 56...63),
        ("Reed", 64...71), ("Pipe", 72...79), ("Synth Lead", 80...87), ("Synth Pad", 88...95),
        ("Synth FX", 96...103), ("Ethnic", 104...111), ("Percussive", 112...119), ("Sound FX", 120...127),
    ]
}
