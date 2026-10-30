import Foundation
import AppKit

/// Audio tracks, vocal analysis and tuning.
extension Session {
    var selectedAudioLocation: (track: Int, clip: Int)? {
        guard let id = selectedAudioClipID else { return nil }
        for (ti, t) in project.tracks.enumerated() { if let ci = t.audioClips.firstIndex(where: { $0.id == id }) { return (ti, ci) } }
        return nil
    }
    func findAudioClip(_ id: UUID) -> (track: Int, clip: Int)? {
        for (ti, t) in project.tracks.enumerated() { if let ci = t.audioClips.firstIndex(where: { $0.id == id }) { return (ti, ci) } }
        return nil
    }

    // MARK: Tracks & import

    func addAudioTrack() {
        pushUndo()
        let t = Track(name: "Audio \(project.tracks.filter { $0.kind == .audio }.count + 1)", colorIndex: project.tracks.count, kind: .audio)
        modify { $0.tracks.append(t) }
        selectedTrackID = t.id
        showEditor = true
    }

    func importAudio() {
        let panel = NSOpenPanel()
        panel.title = "Import Audio"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK { for u in panel.urls { importAudio(url: u) } }
    }

    /// Adds an audio clip at the playhead (on the selected audio track, or a new one) and analyzes it.
    func importAudio(url: URL, analyze: Bool = true) {
        busyMessage = "Importing “\(url.lastPathComponent)”…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<AudioStore.Imported, Error> in
                do { return .success(try AudioStore.importFile(url)) } catch { return .failure(error) }
            }.value
            self.busyMessage = nil
            switch result {
            case .failure(let e): self.errorMessage = e.localizedDescription
            case .success(let imp):
                self.pushUndo()
                var trackID = self.selectedTrack?.kind == .audio ? self.selectedTrackID : nil
                if trackID == nil {
                    let t = Track(name: url.deletingPathExtension().lastPathComponent, colorIndex: self.project.tracks.count, kind: .audio)
                    self.modify { $0.tracks.append(t) }
                    trackID = t.id
                }
                let clip = AudioClip(name: url.deletingPathExtension().lastPathComponent, start: (self.transport.beat * 4).rounded() / 4,
                                     file: imp.file, sourceName: url.lastPathComponent, duration: imp.duration, length: imp.duration, peaks: imp.peaks)
                self.modify { p in if let ti = p.tracks.firstIndex(where: { $0.id == trackID }) { p.tracks[ti].audioClips.append(clip) } }
                self.selectedTrackID = trackID
                self.selectedAudioClipID = clip.id
                self.selectedClipID = nil
                self.showEditor = true
                if analyze { self.bottomPanel = .tune; self.analyzeClip(clip.id) }
                self.showToast("Imported “\(url.lastPathComponent)”")
            }
        }
    }

    func deleteAudioClip(_ id: UUID) {
        guard let loc = findAudioClip(id) else { return }
        pushUndo()
        modify { $0.tracks[loc.track].audioClips.remove(at: loc.clip) }
        if selectedAudioClipID == id { selectedAudioClipID = nil; selectedTuneNoteIDs = [] }
    }

    func moveAudioClip(_ id: UUID, toTrackIndex tj: Int, start: Double) {
        guard let loc = findAudioClip(id), tj >= 0, tj < project.tracks.count, project.tracks[tj].kind == .audio else { return }
        modify { p in
            var c = p.tracks[loc.track].audioClips.remove(at: loc.clip)
            c.start = max(0, start)
            p.tracks[tj].audioClips.append(c)
        }
        selectedTrackID = project.tracks[tj].id
    }

    // MARK: Keeping audio with saved projects

    /// Audio lives in MacBand's own folder; saving a project also copies its audio next to the file so the pair can be moved or shared.
    func assetsFolder(for projectURL: URL) -> URL {
        projectURL.deletingLastPathComponent().appendingPathComponent(projectURL.deletingPathExtension().lastPathComponent + " Audio", isDirectory: true)
    }

    func saveAudioAssets(for projectURL: URL) {
        let files = Set(project.tracks.flatMap { $0.audioClips.map { $0.file } })
        guard !files.isEmpty else { return }
        let dir = assetsFolder(for: projectURL)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files {
            let dst = dir.appendingPathComponent(f)
            if !FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.copyItem(at: AudioStore.url(f), to: dst) }
        }
    }

    /// Bring a project's audio back into the store if it isn't there (project opened on another Mac/location),
    /// and rebuild tuned renders that don't exist yet.
    func restoreAudioAssets(for tracks: [Track], near projectURL: URL?) {
        let dir = projectURL.map { assetsFolder(for: $0) }
        var missing: [String] = []
        for c in tracks.flatMap({ $0.audioClips }) {
            if !FileManager.default.fileExists(atPath: AudioStore.url(c.file).path) {
                if let d = dir, FileManager.default.fileExists(atPath: d.appendingPathComponent(c.file).path) {
                    try? FileManager.default.copyItem(at: d.appendingPathComponent(c.file), to: AudioStore.url(c.file))
                } else { missing.append(c.name) }
            }
            if c.tune?.enabled == true { scheduleRetune(c.id, immediately: true) }
        }
        if !missing.isEmpty { errorMessage = "Some audio couldn't be found: \(missing.joined(separator: ", ")). Keep the “… Audio” folder next to the project file." }
    }

    // MARK: Recording

    /// Record from the microphone onto the selected audio track, starting at the playhead.
    func startAudioRecording() {
        guard recorder == nil, selectedTrack?.kind == .audio else { return }
        let rec = AudioRecorder()
        recorder = rec
        Task {
            do {
                recordStartBeat = transport.beat
                try await rec.start()
                transport.isRecording = true
                if !engine.isPlaying { play() }
            } catch {
                self.recorder = nil; self.transport.isRecording = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func finishAudioRecording() {
        guard let rec = recorder else { return }
        recorder = nil
        transport.isRecording = false
        guard let url = rec.stop() else { return }
        if engine.isPlaying { stop() }
        let startBeat = recordStartBeat
        let trackID = selectedTrackID
        busyMessage = "Saving the recording…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<AudioStore.Imported, Error> in
                do { return .success(try AudioStore.importFile(url)) } catch { return .failure(error) }
            }.value
            try? FileManager.default.removeItem(at: url)
            self.busyMessage = nil
            guard case .success(let imp) = result else { self.errorMessage = "Couldn't save the recording."; return }
            self.pushUndo()
            let n = (self.project.tracks.first { $0.id == trackID }?.audioClips.count ?? 0) + 1
            let clip = AudioClip(name: "Take \(n)", start: startBeat, file: imp.file, sourceName: "Recording", duration: imp.duration, length: imp.duration, peaks: imp.peaks)
            self.modify { p in if let ti = p.tracks.firstIndex(where: { $0.id == trackID }) { p.tracks[ti].audioClips.append(clip) } }
            self.selectedAudioClipID = clip.id; self.selectedClipID = nil
            self.bottomPanel = .tune; self.showEditor = true
            self.analyzeClip(clip.id)
        }
    }

    // MARK: Analysis (pitch → notes → words)

    func analyzeClip(_ clipID: UUID) {
        guard let loc = findAudioClip(clipID) else { return }
        let clip = project.tracks[loc.track].audioClips[loc.clip]
        let scale: Set<Int>? = (clip.tune?.snapToScale ?? true) && project.scale != .chromatic ? project.scale.intervals : nil
        let keyRoot = project.keyRoot
        tuneWorking.insert(clipID)
        updateTune(clipID) { $0 = TuneData(enabled: $0.enabled, amount: $0.amount, defaultGlide: $0.defaultGlide, snapToScale: $0.snapToScale, status: "Analyzing the voice…") }
        Task {
            let analysis = await Task.detached(priority: .userInitiated) { () -> (pitch: [Float], notes: [TuneNote])? in
                guard let mono = try? AudioStore.loadMono(clip.file, rate: PitchAnalyzer.analysisRate) else { return nil }
                let track = PitchAnalyzer.track(mono, sampleRate: PitchAnalyzer.analysisRate)
                return (track, PitchAnalyzer.segment(track, scale: scale, keyRoot: keyRoot))
            }.value
            guard let a = analysis else {
                self.updateTune(clipID) { $0.status = "Couldn't read the audio file." }
                self.tuneWorking.remove(clipID); return
            }
            self.updateTune(clipID) {
                $0.analyzed = true; $0.notes = a.notes
                $0.pitch = a.pitch.withUnsafeBufferPointer { Data(buffer: $0) }
                $0.status = a.notes.isEmpty ? "No pitched singing was found in this recording." : "Reading the words…"
            }
            if a.notes.isEmpty { self.tuneWorking.remove(clipID); return }
            // words
            do {
                var words = try await Transcriber.transcribe(fileURL: AudioStore.url(clip.file))
                for i in words.indices { words[i].text = words[i].text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) }
                words.removeAll { $0.text.isEmpty }
                self.updateTune(clipID) {
                    Transcriber.assign(words, to: &$0.notes)
                    $0.transcript = words.map { $0.text }.joined(separator: " ")
                    $0.status = words.isEmpty ? "No words were recognized (the notes are still tuned)." : ""
                }
            } catch {
                self.updateTune(clipID) { $0.status = "Words unavailable: \(error.localizedDescription)" }
            }
            self.tuneWorking.remove(clipID)
            if self.findAudioClip(clipID).flatMap({ self.project.tracks[$0.track].audioClips[$0.clip].tune?.enabled }) == true { self.scheduleRetune(clipID, immediately: true) }
        }
    }

    /// Change tune data without an undo step (callers push undo at the start of a user gesture).
    func updateTune(_ clipID: UUID, _ body: (inout TuneData) -> Void) {
        guard let loc = findAudioClip(clipID) else { return }
        var t = project.tracks[loc.track].audioClips[loc.clip].tune ?? TuneData()
        body(&t)
        project.tracks[loc.track].audioClips[loc.clip].tune = t
        isDirty = true
    }

    /// An edit the user made: updates the notes and re-renders the tuned audio shortly after.
    func editTune(_ clipID: UUID, _ body: (inout TuneData) -> Void) {
        updateTune(clipID, body)
        scheduleRetune(clipID)
    }

    // MARK: Tuning on/off

    func setTuneEnabled(_ clipID: UUID, _ on: Bool) {
        pushUndo()
        updateTune(clipID) { $0.enabled = on }
        if on { scheduleRetune(clipID, immediately: true) } else { audioContentChanged() }
    }

    func toggleTuneForSelection() {
        guard let id = selectedAudioClipID, let loc = findAudioClip(id) else { return }
        setTuneEnabled(id, !(project.tracks[loc.track].audioClips[loc.clip].tune?.enabled ?? false))
    }

    /// Re-render the tuned audio in the background (debounced while the user is dragging things).
    func scheduleRetune(_ clipID: UUID, immediately: Bool = false) {
        guard let loc = findAudioClip(clipID), project.tracks[loc.track].audioClips[loc.clip].tune?.enabled == true else { return }
        tuneRenderWork[clipID]?.cancel()
        let gen = (tuneRenderGeneration[clipID] ?? 0) + 1
        tuneRenderGeneration[clipID] = gen
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.renderTuned(clipID, generation: gen) } }
        tuneRenderWork[clipID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0.01 : 0.35), execute: work)
    }

    private func renderTuned(_ clipID: UUID, generation: Int) {
        guard let loc = findAudioClip(clipID) else { return }
        let clip = project.tracks[loc.track].audioClips[loc.clip]
        guard let tune = clip.tune, tune.analyzed else { return }
        tuneWorking.insert(clipID)
        Task {
            let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
                (try? Session.renderTunedFile(clip: clip, tune: tune)) != nil
            }.value
            guard self.tuneRenderGeneration[clipID] == generation else { return }   // a newer edit superseded this render
            self.tuneWorking.remove(clipID)
            if !ok { self.errorMessage = "Couldn't render the tuned audio."; return }
            self.audioContentChanged()
        }
    }

    /// Tuned audio changed on disk: drop cached files and, if playing, restart from the playhead so it's heard.
    func audioContentChanged() {
        engine.invalidateAudioCache()
        if engine.isPlaying { sequenceDirty = true; flushSequence() }
    }

    /// Render every voice (main + chord voices) of a clip into its tuned file.
    nonisolated static func renderTunedFile(clip: AudioClip, tune: TuneData) throws -> Bool {
        let (channels, rate) = try AudioStore.loadChannels(clip.file)
        guard !channels.isEmpty else { return false }
        let detected: [Float] = tune.pitch.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard !detected.isEmpty else { return false }
        // the analysis ran at 10 ms hops regardless of sample rate, so frames line up with the file
        let voices = 1 + (tune.notes.map { $0.extra.count }.max() ?? 0)
        var mix: [[Float]] = []
        for v in 0..<voices {
            let curve = Retuner.curve(frames: detected.count, detected: detected, notes: tune.notes, voice: v, amount: tune.amount, defaultGlide: tune.defaultGlide)
            let rendered = Retuner.render(channels: channels, rate: rate, detected: detected, curve: curve, voice: v)
            let gain: Float = v == 0 ? 1 : 0.75
            if mix.isEmpty { mix = rendered.map { $0.map { $0 * gain } } }
            else { for c in 0..<mix.count { for i in 0..<min(mix[c].count, rendered[c].count) { mix[c][i] += rendered[c][i] * gain } } }
        }
        // keep stacked voices from clipping
        let peak = mix.flatMap { $0 }.reduce(0) { max($0, abs($1)) }
        if peak > 0.98 { let k = 0.98 / peak; for c in 0..<mix.count { for i in 0..<mix[c].count { mix[c][i] *= k } } }
        try AudioStore.write(mix, rate: rate, to: AudioStore.tunedName(for: clip.file, clipID: clip.id))
        return true
    }

    // MARK: Note editing

    func chordIntervals(_ name: String) -> [Int] {
        switch name {
        case "Major": return [4, 7]
        case "Minor": return [3, 7]
        case "Power": return [7, 12]
        case "Sus2": return [2, 7]
        case "Sus4": return [5, 7]
        case "Major 7": return [4, 7, 11]
        case "Minor 7": return [3, 7, 10]
        case "Dominant 7": return [4, 7, 10]
        case "Octave": return [12]
        default: return []
        }
    }

    /// Stack `intervals` (semitones above each note's main pitch) as extra voices on the given notes.
    func applyChord(_ clipID: UUID, noteIDs: Set<UUID>, intervals: [Int]) {
        pushUndo()
        editTune(clipID) { t in
            for i in t.notes.indices where noteIDs.contains(t.notes[i].id) {
                t.notes[i].extra = intervals.map { min(127, t.notes[i].pitch + $0) }
                t.notes[i].edited = true
            }
        }
    }

    /// Add one more pitch to a word (above its highest voice, or at `pitch` when given).
    func addVoice(_ clipID: UUID, noteID: UUID, pitch: Int? = nil) {
        pushUndo()
        editTune(clipID) { t in
            guard let i = t.notes.firstIndex(where: { $0.id == noteID }) else { return }
            let top = t.notes[i].voices.max() ?? t.notes[i].pitch
            let p = pitch ?? min(127, top + 4)
            if !t.notes[i].voices.contains(p) { t.notes[i].extra.append(p) }
            t.notes[i].edited = true
        }
    }

    func removeVoice(_ clipID: UUID, noteID: UUID, pitch: Int) {
        pushUndo()
        editTune(clipID) { t in
            guard let i = t.notes.firstIndex(where: { $0.id == noteID }) else { return }
            if pitch == t.notes[i].pitch, let first = t.notes[i].extra.first {   // removing the main voice promotes the next one
                t.notes[i].pitch = first; t.notes[i].extra.removeFirst()
            } else { t.notes[i].extra.removeAll { $0 == pitch } }
            t.notes[i].edited = true
        }
    }
}

// MARK: - Keys

struct KeyGuess { var root: Int; var minor: Bool; var confidence: Double
    var name: String { "\(Pitch.names[root]) \(minor ? "minor" : "major")" }
}

extension ScaleKind {
    /// Minor-flavoured scales are compared against the minor key profile.
    var isMinorFamily: Bool { [.minor, .dorian, .pentatonicMinor, .blues].contains(self) }
}

extension Session {
    /// Krumhansl–Schmuckler key finding on the notes, weighted by how long each is held.
    static func detectKey(_ notes: [TuneNote]) -> KeyGuess? {
        var hist = [Double](repeating: 0, count: 12)
        for n in notes { hist[((n.pitch % 12) + 12) % 12] += max(0.05, n.length) }
        guard hist.reduce(0, +) > 0 else { return nil }
        let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        func corr(_ a: [Double], _ b: [Double]) -> Double {
            let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
            var num = 0.0, da = 0.0, db = 0.0
            for i in 0..<12 { num += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb) }
            return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
        }
        var best: KeyGuess? = nil
        for root in 0..<12 {
            let rotated = (0..<12).map { hist[($0 + root) % 12] }
            for (profile, isMinor) in [(major, false), (minor, true)] {
                let c = corr(rotated, profile)
                if best == nil || c > best!.confidence { best = KeyGuess(root: root, minor: isMinor, confidence: c) }
            }
        }
        return best
    }

    private static func snap(_ pitch: Int, root: Int, scale: Set<Int>) -> Int {
        if scale.count >= 12 { return pitch }
        var best = pitch, bestD = 99
        for cand in (pitch - 6)...(pitch + 6) where scale.contains((((cand - root) % 12) + 12) % 12) {
            let d = abs(cand - pitch); if d < bestD || (d == bestD && cand < best) { bestD = d; best = cand }
        }
        return max(0, min(127, best))
    }

    /// Move every note (and its chord voices) into `root` `scale`: shifted by the distance from the detected key,
    /// then any note still outside the scale is moved to its nearest scale note.
    func transposeToKey(_ clipID: UUID, root: Int, scale: ScaleKind) {
        guard let loc = findAudioClip(clipID), let tune = project.tracks[loc.track].audioClips[loc.clip].tune, !tune.notes.isEmpty else { return }
        let source = Session.detectKey(tune.notes)
        var delta = 0
        if let src = source { delta = ((root - src.root + 6) % 12 + 12) % 12 - 6 }
        pushUndo()
        let set = scale.intervals
        editTune(clipID) { t in
            for i in t.notes.indices {
                let moved = max(0, min(127, t.notes[i].pitch + delta))
                let snapped = Session.snap(moved, root: root, scale: set)
                let shift = snapped - t.notes[i].pitch
                t.notes[i].pitch = snapped
                t.notes[i].extra = t.notes[i].extra.map { max(0, min(127, $0 + shift)) }
                t.notes[i].edited = true
            }
        }
        project.keyRoot = root; project.scale = scale; isDirty = true
        let from = source.map { "\($0.name) → " } ?? ""
        showToast("\(from)\(Pitch.names[root]) \(scale.rawValue)  (\(delta >= 0 ? "+" : "")\(delta) semitones)")
    }

    /// Keep the notes where they are but move any out-of-key note to the nearest note of the scale.
    func snapNotesToKey(_ clipID: UUID, root: Int, scale: ScaleKind) {
        guard findAudioClip(clipID) != nil else { return }
        pushUndo()
        let set = scale.intervals
        var changed = 0
        editTune(clipID) { t in
            for i in t.notes.indices {
                let s = Session.snap(t.notes[i].pitch, root: root, scale: set)
                if s != t.notes[i].pitch {
                    let shift = s - t.notes[i].pitch
                    t.notes[i].pitch = s; t.notes[i].extra = t.notes[i].extra.map { max(0, min(127, $0 + shift)) }; t.notes[i].edited = true; changed += 1
                }
            }
        }
        project.keyRoot = root; project.scale = scale; isDirty = true
        showToast(changed == 0 ? "All notes were already in \(Pitch.names[root]) \(scale.rawValue)" : "Moved \(changed) note\(changed == 1 ? "" : "s") into \(Pitch.names[root]) \(scale.rawValue)")
    }
}
