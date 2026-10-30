import Foundation

/// Splitting vocals into sections: a note into parts (to give each part its own pitch), and a whole audio clip.
extension Session {
    private static let minPart = 0.04

    /// Cut one note into two at `time` (file seconds). The first part keeps the word and the marker moves to the second.
    func splitNote(_ clipID: UUID, noteID: UUID, at time: Double) {
        guard let loc = findAudioClip(clipID),
              let n = project.tracks[loc.track].audioClips[loc.clip].tune?.notes.first(where: { $0.id == noteID }),
              time > n.start + Session.minPart, time < n.end - Session.minPart else { return }
        pushUndo()
        var newID: UUID?
        editTune(clipID) { t in
            guard let i = t.notes.firstIndex(where: { $0.id == noteID }) else { return }
            var b = t.notes[i]; b.id = UUID(); b.start = time; b.word = ""; b.edited = true
            t.notes[i].end = time; t.notes[i].marker = nil; t.notes[i].edited = true
            t.notes.insert(b, at: i + 1)
            newID = b.id
        }
        if let id = newID { selectedTuneNoteIDs = [noteID, id] }
    }

    /// Cut notes into `parts` equal sections (chord voices are copied to every section).
    func splitNotes(_ clipID: UUID, noteIDs: Set<UUID>, parts: Int) {
        guard parts >= 2, findAudioClip(clipID) != nil else { return }
        pushUndo()
        var created: Set<UUID> = []
        editTune(clipID) { t in
            var result: [TuneNote] = []
            for n in t.notes {
                guard noteIDs.contains(n.id) else { result.append(n); continue }
                let count = max(1, min(parts, Int(n.length / Session.minPart)))
                if count < 2 { result.append(n); continue }
                let step = n.length / Double(count)
                for k in 0..<count {
                    var p = n
                    if k > 0 { p.id = UUID(); p.word = ""; created.insert(p.id) }
                    p.start = n.start + step * Double(k); p.end = k == count - 1 ? n.end : n.start + step * Double(k + 1)
                    p.marker = k == count - 1 ? n.marker : nil
                    p.edited = true
                    result.append(p)
                }
            }
            t.notes = result
        }
        selectedTuneNoteIDs.formUnion(created)
    }

    /// Cut the selected notes where the playhead is; notes the playhead isn't in are halved.
    func splitNotesAtPlayhead(_ clipID: UUID, noteIDs: Set<UUID>) {
        guard let loc = findAudioClip(clipID) else { return }
        let c = project.tracks[loc.track].audioClips[loc.clip]
        let t = project.seconds(atBeat: transport.beat) - project.seconds(atBeat: c.start) + c.offset
        guard let notes = c.tune?.notes else { return }
        var halve: Set<UUID> = []
        pushUndo()
        var created: Set<UUID> = []
        editTune(clipID) { d in
            for i in d.notes.indices.reversed() where noteIDs.contains(d.notes[i].id) {
                let n = d.notes[i]
                if t > n.start + Session.minPart, t < n.end - Session.minPart {
                    var b = n; b.id = UUID(); b.start = t; b.word = ""; b.edited = true
                    d.notes[i].end = t; d.notes[i].marker = nil; d.notes[i].edited = true
                    d.notes.insert(b, at: i + 1); created.insert(b.id)
                } else if n.length > 2 * Session.minPart { halve.insert(n.id) }
            }
        }
        _ = notes
        if !halve.isEmpty { splitNotes(clipID, noteIDs: halve, parts: 2) }
        selectedTuneNoteIDs.formUnion(created)
    }

    /// Join the selected notes (in time order) into one: takes the first note's pitch and the words are combined.
    func mergeNotes(_ clipID: UUID, noteIDs: Set<UUID>) {
        guard noteIDs.count >= 2, findAudioClip(clipID) != nil else { return }
        pushUndo()
        editTune(clipID) { t in
            let sel = t.notes.filter { noteIDs.contains($0.id) }.sorted { $0.start < $1.start }
            guard var first = sel.first, let last = sel.last else { return }
            first.end = last.end; first.marker = last.marker; first.edited = true
            first.word = sel.map { $0.word }.filter { !$0.isEmpty }.joined(separator: " ")
            t.notes.removeAll { noteIDs.contains($0.id) }
            t.notes.append(first); t.notes.sort { $0.start < $1.start }
        }
        selectedTuneNoteIDs = Set(noteIDs.prefix(1))
    }

    // MARK: Audio clips

    /// Cut a vocal clip in two at `beat`. Each half keeps its own tuning settings, so sections can differ.
    func splitAudioClip(_ clipID: UUID, atBeat beat: Double) {
        guard let loc = findAudioClip(clipID) else { return }
        let c = project.tracks[loc.track].audioClips[loc.clip]
        let cutSec = project.seconds(atBeat: beat) - project.seconds(atBeat: c.start)       // seconds into the clip
        guard cutSec > 0.05, cutSec < c.length - 0.05 else { return }
        let cutFile = c.offset + cutSec                                                       // position in the file
        pushUndo()
        var left = c, right = c
        left.length = cutSec
        right.id = UUID(); right.name = c.name + " B"; right.start = beat; right.offset = cutFile; right.length = c.length - cutSec
        if var t = c.tune {
            var lt = t, rt = t
            lt.notes = []; rt.notes = []
            for n in t.notes {
                if n.end <= cutFile { lt.notes.append(n) }
                else if n.start >= cutFile { rt.notes.append(n) }
                else {                                                                        // a note straddling the cut becomes two
                    var a = n; a.end = cutFile; a.marker = nil
                    var b = n; b.id = UUID(); b.start = cutFile; b.word = ""
                    lt.notes.append(a); rt.notes.append(b)
                }
            }
            t = lt; left.tune = t; right.tune = rt
        }
        modify { p in p.tracks[loc.track].audioClips[loc.clip] = left; p.tracks[loc.track].audioClips.insert(right, at: loc.clip + 1) }
        for id in [left.id, right.id] { if left.tune?.enabled == true { scheduleRetune(id, immediately: true) } }
        selectedAudioClipID = right.id
    }
}
