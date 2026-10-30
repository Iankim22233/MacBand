import Foundation
import AVFoundation
import AudioToolbox
import AppKit
import CVST3Host

/// One mixer channel: instrument → inserts → fader/pan mixer → master.
final class TrackStrip {
    let id: UUID
    var instrument: AVAudioUnitMIDIInstrument?
    var effects: [AVAudioUnit] = []
    let mixer = AVAudioMixerNode()
    var instrumentKey = ""
    var insertKeys: [UUID] = []
    var generation = 0
    var loading = false
    var peak: Float = 0
    var slot = -1                   // which master-mixer input this strip feeds
    var player: AVAudioPlayerNode?  // audio tracks
    var gmSound: (program: Int, drums: Bool)?   // what the built-in sampler was loaded with
    /// plugin-spec id → live unit (for state capture & editor windows)
    var units: [UUID: AVAudioUnit] = [:]
    init(id: UUID) { self.id = id }
}

enum EngineError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

final class AudioEngine {
    static let dlsURL = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")

    let engine = AVAudioEngine()
    private(set) var sequencer: AVAudioSequencer!
    private(set) var strips: [UUID: TrackStrip] = [:]
    private let click = AVAudioUnitSampler()
    /// Keeps big arrangements (dozens of tracks summing) from clipping the output.
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))

    // Every `connect(a, to: mixer)` without an explicit bus lands on input 0 and *replaces* whatever was
    // there, so each track needs its own input. 60 inputs on the master, then overflow submixers.
    private static let directSlots = 60, clickBus = 63, overflowSlots = 60
    private var freeSlots = Array((0..<(AudioEngine.directSlots + 3 * AudioEngine.overflowSlots)).reversed())
    private var overflowMixers: [Int: AVAudioMixerNode] = [:]

    private func connectToMaster(_ s: TrackStrip) {
        guard let slot = freeSlots.popLast() else { onError?("Too many tracks: MacBand supports up to 240."); return }
        s.slot = slot
        if slot < Self.directSlots {
            engine.connect(s.mixer, to: engine.mainMixerNode, fromBus: 0, toBus: slot, format: nil)
        } else {
            let group = (slot - Self.directSlots) / Self.overflowSlots
            let sub: AVAudioMixerNode
            if let m = overflowMixers[group] { sub = m } else {
                sub = AVAudioMixerNode(); engine.attach(sub)
                engine.connect(sub, to: engine.mainMixerNode, fromBus: 0, toBus: Self.directSlots + group, format: nil)
                overflowMixers[group] = sub
            }
            engine.connect(s.mixer, to: sub, fromBus: 0, toBus: (slot - Self.directSlots) % Self.overflowSlots, format: nil)
        }
    }
    private var clickLoaded = false
    var masterPeak: Float = 0
    /// Loudest level each track reached during the last offline render (diagnostics).
    var renderPeaks: [UUID: Float] = [:]
    var metronomeOn = false { didSet { click.volume = metronomeOn ? 1 : 0 } }
    var onError: ((String) -> Void)?
    var onGraphChanged: (() -> Void)?
    private(set) var offlineBusy = false

    init() {
        engine.attach(limiter)
        engine.connect(engine.mainMixerNode, to: limiter, format: nil)
        engine.connect(limiter, to: engine.outputNode, format: nil)
        engine.attach(click)
        click.volume = 0
        engine.connect(click, to: engine.mainMixerNode, fromBus: 0, toBus: Self.clickBus, format: nil)
        sequencer = AVAudioSequencer(audioEngine: engine)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            self?.masterPeak = AudioEngine.peak(buf)
        }
        engine.prepare()
        startEngine()
        loadClick()
    }

    static func peak(_ buf: AVAudioPCMBuffer) -> Float {
        guard let ch = buf.floatChannelData else { return 0 }
        var p: Float = 0
        for c in 0..<Int(buf.format.channelCount) {
            let d = ch[c]
            for i in 0..<Int(buf.frameLength) { p = max(p, abs(d[i])) }
        }
        return p
    }

    func startEngine() {
        guard !engine.isRunning else { return }
        do { try engine.start() } catch { onError?("Audio engine failed to start: \(error.localizedDescription)") }
    }

    private func loadClick() {
        DispatchQueue.global().async { [self] in
            do {
                try click.loadSoundBankInstrument(at: Self.dlsURL, program: 0, bankMSB: UInt8(kAUSampler_DefaultPercussionBankMSB), bankLSB: 0)
                clickLoaded = true
            } catch { NSLog("click load failed: \(error)") }
        }
    }

    // MARK: - Strips

    func syncTracks(_ tracks: [Track]) {
        let ids = Set(tracks.map { $0.id })
        for (id, strip) in strips where !ids.contains(id) {
            Task { @MainActor in PluginWindows.shared.discard(Array(strip.units.keys)) }
            remove(strip); strips[id] = nil
        }
        for t in tracks {
            let strip = strips[t.id] ?? makeStrip(t.id)
            let key = Self.trackKey(t)
            let inserts = t.inserts.map { $0.id }
            if strip.instrumentKey != key || strip.insertKeys != inserts { rebuild(strip, track: t) }
        }
    }

    static func trackKey(_ t: Track) -> String { t.kind == .audio ? "audio" : instrumentKey(t.instrument) }

    static func instrumentKey(_ i: InstrumentSpec) -> String {
        if let p = i.plugin { return "plug:\(p.id)" }
        return i.isDrums ? "gm:drums" : "gm:\(i.gmProgram)"
    }

    private func makeStrip(_ id: UUID) -> TrackStrip {
        let s = TrackStrip(id: id)
        engine.attach(s.mixer)
        connectToMaster(s)
        s.mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak s] buf, _ in s?.peak = AudioEngine.peak(buf) }
        strips[id] = s
        return s
    }

    private func remove(_ s: TrackStrip) {
        s.mixer.removeTap(onBus: 0)
        if let i = s.instrument { engine.disconnectNodeOutput(i); engine.detach(i) }
        for e in s.effects { engine.disconnectNodeOutput(e); engine.detach(e) }
        engine.disconnectNodeOutput(s.mixer)
        engine.detach(s.mixer)
        if s.slot >= 0 { freeSlots.append(s.slot); freeSlots.sort(by: >) }
    }

    /// Instantiate instrument + inserts for a track off the main thread, then splice them in.
    private func rebuild(_ s: TrackStrip, track: Track) {
        s.generation += 1
        let gen = s.generation
        s.loading = true
        if track.kind == .audio { rebuildAudio(s, track: track, gen: gen); return }
        let instSpec = track.instrument
        let insertSpecs = track.inserts
        Task { @MainActor in
            var newInst: AVAudioUnitMIDIInstrument?
            var newFx: [AVAudioUnit] = []
            var units: [UUID: AVAudioUnit] = [:]
            var gmSound: (program: Int, drums: Bool)?
            do {
                if let p = instSpec.plugin {
                    let u = try await PluginHost.instantiate(p)
                    guard let mi = u as? AVAudioUnitMIDIInstrument else { throw EngineError.message("\(p.name) is not an instrument.") }
                    newInst = mi; units[p.id] = u
                } else {
                    let sampler = AVAudioUnitSampler()
                    self.engine.attach(sampler)
                    try await Self.loadSampler(sampler, program: instSpec.gmProgram, drums: instSpec.isDrums)
                    newInst = sampler
                    gmSound = (instSpec.gmProgram, instSpec.isDrums)
                }
            } catch {
                self.onError?("Couldn't load instrument: \(error.localizedDescription)")
            }
            for p in insertSpecs {
                do {
                    let u = try await PluginHost.instantiate(p)
                    newFx.append(u); units[p.id] = u
                } catch { self.onError?("Couldn't load \(p.name): \(error.localizedDescription)") }
            }
            guard s.generation == gen, self.strips[s.id] === s else {
                for u in units.values where u.engine != nil { self.engine.detach(u) }
                return
            }
            // Tear down the old chain (and any editor windows that belonged to it)
            PluginWindows.shared.discard(Array(s.units.keys))
            if let i = s.instrument { self.engine.disconnectNodeOutput(i); self.engine.detach(i) }
            for e in s.effects { self.engine.disconnectNodeOutput(e); self.engine.detach(e) }
            self.engine.disconnectNodeInput(s.mixer)

            if let ni = newInst, ni.engine == nil { self.engine.attach(ni) }
            for fx in newFx { self.engine.attach(fx) }
            if let ni = newInst {
                var prev: AVAudioNode = ni
                for fx in newFx { self.engine.connect(prev, to: fx, format: nil); prev = fx }
                self.engine.connect(prev, to: s.mixer, format: nil)
            }
            s.instrument = newInst
            s.gmSound = gmSound
            s.effects = newFx
            s.units = units
            s.instrumentKey = Self.instrumentKey(instSpec)
            s.insertKeys = insertSpecs.map { $0.id }
            for (i, p) in insertSpecs.enumerated() where i < newFx.count { newFx[i].auAudioUnit.shouldBypassEffect = p.bypassed }
            s.loading = false
            self.startEngine()
            self.onGraphChanged?()
        }
    }

    /// Apple's sampler loads from the shared DLS bank aren't safe to run concurrently (a bulk import of
    /// dozens of tracks produced silent or failed instruments), so they go through one serial queue.
    private static let samplerQueue = DispatchQueue(label: "macband.sampler-load", qos: .userInitiated)

    /// Audio tracks: player → inserts → mixer.
    private func rebuildAudio(_ s: TrackStrip, track: Track, gen: Int) {
        let insertSpecs = track.inserts
        Task { @MainActor in
            var newFx: [AVAudioUnit] = []
            var units: [UUID: AVAudioUnit] = [:]
            for p in insertSpecs {
                do { let u = try await PluginHost.instantiate(p); newFx.append(u); units[p.id] = u }
                catch { self.onError?("Couldn't load \(p.name): \(error.localizedDescription)") }
            }
            guard s.generation == gen, self.strips[s.id] === s else { return }
            PluginWindows.shared.discard(Array(s.units.keys))
            if let pl = s.player { pl.stop(); self.engine.disconnectNodeOutput(pl); self.engine.detach(pl) }
            for e in s.effects { self.engine.disconnectNodeOutput(e); self.engine.detach(e) }
            self.engine.disconnectNodeInput(s.mixer)
            let player = AVAudioPlayerNode()
            self.engine.attach(player)
            for fx in newFx { self.engine.attach(fx) }
            var prev: AVAudioNode = player
            var fmt: AVAudioFormat? = AudioStore.format
            for fx in newFx { self.engine.connect(prev, to: fx, format: fmt); prev = fx; fmt = nil }
            self.engine.connect(prev, to: s.mixer, format: fmt)
            s.player = player; s.instrument = nil; s.effects = newFx; s.units = units
            s.instrumentKey = "audio"; s.insertKeys = insertSpecs.map { $0.id }
            for (i, p) in insertSpecs.enumerated() where i < newFx.count { newFx[i].auAudioUnit.shouldBypassEffect = p.bypassed }
            s.loading = false
            self.startEngine()
            self.onGraphChanged?()
        }
    }

    // MARK: - Audio playback

    private var audioFiles: [String: AVAudioFile] = [:]
    private func audioFile(_ name: String) -> AVAudioFile? {
        if let f = audioFiles[name] { return f }
        guard let f = try? AVAudioFile(forReading: AudioStore.url(name)) else { return nil }
        audioFiles[name] = f; return f
    }
    /// Forget cached handles (after a tuned render replaced a file).
    func invalidateAudioCache() { audioFiles.removeAll() }

    func stopAudio() { for s in strips.values { s.player?.stop() } }

    /// Queue every audio clip from `songBeat` on and start the players. Call right after the sequencer starts.
    func startAudio(_ project: Project, songBeat: Double, delay0: Double) {
        for t in project.tracks where t.kind == .audio {
            guard let player = strips[t.id]?.player else { continue }
            player.stop()
            let items = AudioSchedule.items(project, track: t, startBeat: songBeat, delay0: delay0)
            guard !items.isEmpty else { continue }
            for it in items {
                guard let f = audioFile(it.file), it.frames > 0 else { continue }
                let at = AVAudioTime(sampleTime: AVAudioFramePosition((it.delay * AudioStore.rate).rounded()), atRate: AudioStore.rate)
                player.scheduleSegment(f, startingFrame: it.startFrame, frameCount: AVAudioFrameCount(it.frames), at: at, completionHandler: nil)
            }
            player.play()
        }
    }

    private static func playbackDelay(_ project: Project, at beat: Double) -> Double { 0.06 * 60 / max(20, project.bpm(at: beat)) }

    private static func loadSampler(_ s: AVAudioUnitSampler, program: Int, drums: Bool) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            samplerQueue.async {
                do { try loadSamplerSync(s, program: program, drums: drums); c.resume() } catch { c.resume(throwing: error) }
            }
        }
    }

    static func loadSamplerSync(_ s: AVAudioUnitSampler, program: Int, drums: Bool) throws {
        func load(_ prog: Int) throws {
            try s.loadSoundBankInstrument(
                at: dlsURL, program: UInt8(min(max(prog, 0), 127)),
                bankMSB: UInt8(drums ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB),
                bankLSB: UInt8(kAUSampler_DefaultBankLSB))
        }
        do { try load(program) }
        catch {
            // MIDI files often name drum kits / patches the built-in sound bank doesn't have
            // (e.g. kit 24+); fall back to the standard kit or piano rather than failing the track.
            try load(0)
        }
    }

    /// Replace an insert's bypass flag live.
    func setBypass(trackID: UUID, specID: UUID, bypass: Bool) {
        strips[trackID]?.units[specID]?.auAudioUnit.shouldBypassEffect = bypass
    }

    func unit(trackID: UUID, specID: UUID) -> AVAudioUnit? { strips[trackID]?.units[specID] }

    /// Snapshot the live state of every plugin so it can be stored in the project.
    func captureState(of specID: UUID) -> Data? {
        for s in strips.values {
            if let u = s.units[specID] { return PluginHost.captureState(u) }
        }
        return nil
    }

    // MARK: - Mix

    func applyMix(_ project: Project, beat: Double?) {
        engine.mainMixerNode.outputVolume = Mixer.gain(project.masterVolume)
        let anySolo = project.tracks.contains { $0.solo }
        for t in project.tracks {
            guard let s = strips[t.id] else { continue }
            let audible = !t.mute && (!anySolo || t.solo)
            var gain = audible ? Mixer.gain(t.volume) : 0
            if audible, let b = beat {
                for c in t.clips where b >= c.start && b < c.end {
                    if let v = Automation.value(c.volume, at: b - c.start) { gain *= Float(Automation.gain(v)) }
                }
            }
            s.mixer.outputVolume = gain
            s.mixer.pan = Float(t.pan)
        }
    }

    // MARK: - Sequencer

    var isPlaying: Bool { sequencer.isPlaying }
    /// Song position in beats (the sequence itself is offset by `MIDIFile.playbackLead`).
    var position: Double {
        get { loopSource.loopWrapped(max(0, sequencer.currentPositionInBeats - MIDIFile.playbackLead)) }
        set { sequencer.currentPositionInBeats = max(0, newValue) + MIDIFile.playbackLead }
    }
    /// Project whose loop settings define how raw sequence time maps back onto the song.
    private var loopSource = Project()

    /// Let hosted VST3 plugins see the tempo and song position (arpeggiators, tempo-synced delays…).
    func updateHostTransport(bpm: Double, beat: Double, playing: Bool) {
        for s in strips.values {
            for u in s.units.values { (u.auAudioUnit as? MBVST3AudioUnit)?.setHostTempo(bpm, beat: beat, playing: playing) }
        }
    }

    func allNotesOff() {
        for s in strips.values {
            guard let i = s.instrument else { continue }
            for ch: UInt8 in 0..<1 {
                i.sendController(123, withValue: 0, onChannel: ch)
                i.sendController(120, withValue: 0, onChannel: ch)
                i.sendPitchBend(8192, onChannel: ch)
            }
        }
        if clickLoaded { click.sendController(123, withValue: 0, onChannel: 9) }
    }

    /// Re-render the project into the sequencer, keeping position and play state.
    func reloadSequence(_ project: Project, metronome: Bool) {
        whileRenderPaused { reloadSequenceNow(project, metronome: metronome) }
    }

    private func reloadSequenceNow(_ project: Project, metronome: Bool) {
        let wasPlaying = sequencer.isPlaying
        let songPos = position
        sequencer.stop()
        stopAudio()
        allNotesOff()
        loopSource = project
        let data = MIDIFile.build(project.loopUnrolled(), forExport: false, metronome: metronome)
        // The sequencer keeps the tempo events of whatever it loaded before and adds the new ones to them, so a tempo change
        // that was moved or deleted would still sound. Start from an empty tempo track every time.
        let tempoLength = sequencer.tempoTrack.lengthInBeats
        if tempoLength > 0 { sequencer.tempoTrack.clearEvents(in: AVBeatRange(start: 0, length: tempoLength + 1)) }
        do { try sequencer.load(from: data, options: []) } catch {
            onError?("Sequencer load failed: \(error.localizedDescription)"); return
        }
        let tracks = sequencer.tracks
        // The conductor (tempo) track is included in `tracks` ahead of the music tracks.
        let offset = max(0, tracks.count - (project.tracks.count + 1))
        for (i, t) in project.tracks.enumerated() {
            let idx = i + offset
            if idx < tracks.count { tracks[idx].destinationAudioUnit = strips[t.id]?.instrument }
        }
        let clickIdx = project.tracks.count + offset
        if clickIdx < tracks.count { tracks[clickIdx].destinationAudioUnit = click }
        for t in tracks { t.isLoopingEnabled = false }
        sequencer.currentPositionInBeats = songPos + MIDIFile.playbackLead
        sequencer.prepareToPlay()
        if wasPlaying { try? sequencer.start(); startAudio(project, songBeat: songPos, delay0: 0) }
    }

    /// Apple's sequencer talks to the plugins it feeds whenever it starts, stops or is reloaded. For a plugin running
    /// in another process (an AUv3 extension, an Intel-only AU) that call swaps callbacks the audio thread is using
    /// at that moment, which crashed the app in `AUAudioUnit_XPC`'s render block. While such a plugin is present the
    /// audio hardware is paused for the few milliseconds the call takes.
    var hasRemoteUnits: Bool {
        strips.values.contains { s in
            (s.instrument.map { !$0.auAudioUnit.isLoadedInProcess } ?? false) || s.effects.contains { !$0.auAudioUnit.isLoadedInProcess }
        }
    }

    func whileRenderPaused(_ body: () -> Void) {
        guard !offlineBusy, engine.isRunning, hasRemoteUnits else { body(); return }
        engine.pause()
        body()
        startEngine()
    }

    func play() {
        startEngine()
        // Start a hair early so events exactly on the start position aren't skipped.
        sequencer.currentPositionInBeats = max(0, sequencer.currentPositionInBeats - 0.06)
        sequencer.prepareToPlay()
        let startBeat = position
        whileRenderPaused {
            do { try sequencer.start() } catch { onError?("Couldn't start playback: \(error.localizedDescription)") }
        }
        startAudio(loopSource, songBeat: startBeat, delay0: Self.playbackDelay(loopSource, at: startBeat))
    }

    func stop() {
        whileRenderPaused {
            sequencer.stop()
            stopAudio()
            allNotesOff()
        }
    }

    // MARK: - Live notes

    func noteOn(trackID: UUID, pitch: Int, velocity: Int) {
        strips[trackID]?.instrument?.startNote(UInt8(pitch & 127), withVelocity: UInt8(min(127, max(1, velocity))), onChannel: 0)
    }
    func noteOff(trackID: UUID, pitch: Int) {
        strips[trackID]?.instrument?.stopNote(UInt8(pitch & 127), onChannel: 0)
    }

    // MARK: - Bounce

    /// Render the project to a WAV/AIFF/CAF file faster than real time.
    func bounce(_ project: Project, to url: URL, honorLoop: Bool = false, testSeconds: Double? = nil, progress: @escaping (Double) -> Void) throws {
        offlineBusy = true
        defer { offlineBusy = false }
        let wasPlaying = sequencer.isPlaying
        whileRenderPaused { sequencer.stop(); allNotesOff() }
        engine.stop()
        engine.mainMixerNode.removeTap(onBus: 0)

        let sr = 44100.0
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false)!
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 512)
        // Switching to offline rendering re-initialises the samplers, which drops what they had loaded
        // (every sound turned into the same default tone), so load each one again.
        for st in strips.values {
            if let sam = st.instrument as? AVAudioUnitSampler, let g = st.gmSound { try? Self.loadSamplerSync(sam, program: g.program, drums: g.drums) }
        }
        defer {
            engine.disableManualRenderingMode()
            // Leaving offline mode re-initialises the samplers again and they fall back to the default sine tone,
            // so load their sounds once more before playback resumes.
            for st in strips.values {
                if let sam = st.instrument as? AVAudioUnitSampler, let g = st.gmSound { try? Self.loadSamplerSync(sam, program: g.program, drums: g.drums) }
            }
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
                self?.masterPeak = AudioEngine.peak(buf)
            }
            startEngine()
        }
        var p = project
        if !honorLoop { p.loopEnabled = false }
        try engine.start()
        reloadSequence(p, metronome: false)
        sequencer.currentPositionInBeats = (honorLoop ? p.loopStart : 0) + MIDIFile.playbackLead - 0.06
        sequencer.prepareToPlay()
        try sequencer.start()
        startAudio(p, songBeat: 0, delay0: Self.playbackDelay(p, at: 0))

        let seconds = testSeconds ?? (p.seconds(atBeat: p.contentEnd) + 3)
        let totalFrames = AVAudioFramePosition(seconds * sr)
        let out = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: url.pathExtension.lowercased() == "aif" || url.pathExtension.lowercased() == "aiff",
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var lastReport = 0.0
        renderPeaks = [:]
        while engine.manualRenderingSampleTime < totalFrames {
            applyMix(p, beat: position)
            let n = AVAudioFrameCount(min(Int64(buf.frameCapacity), totalFrames - engine.manualRenderingSampleTime))
            let status = try engine.renderOffline(n, to: buf)
            for (id, st) in strips { renderPeaks[id] = max(renderPeaks[id] ?? 0, st.peak) }
            switch status {
            case .success: try out.write(from: buf)
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext: continue
            case .error: throw EngineError.message("Offline render failed.")
            @unknown default: break
            }
            let f = Double(engine.manualRenderingSampleTime) / Double(totalFrames)
            if f - lastReport > 0.02 { lastReport = f; progress(f) }
        }
        sequencer.stop()
        allNotesOff()
        engine.stop()
        _ = wasPlaying
    }
}
