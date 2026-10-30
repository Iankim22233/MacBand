import Foundation

/// Moving the sung words sideways across the notes.
extension Session {
    /// Put the word of `from` on `to`. If `to` already has a word, the two exchange places.
    func moveWord(_ clipID: UUID, from: UUID, to: UUID) {
        guard from != to, let loc = findAudioClip(clipID),
              let t = project.tracks[loc.track].audioClips[loc.clip].tune,
              t.notes.contains(where: { $0.id == from }), t.notes.contains(where: { $0.id == to }) else { return }
        pushUndo()
        editTune(clipID) { d in
            guard let a = d.notes.firstIndex(where: { $0.id == from }), let b = d.notes.firstIndex(where: { $0.id == to }) else { return }
            let w = d.notes[a].word
            d.notes[a].word = d.notes[b].word
            d.notes[b].word = w
        }
        selectedTuneNoteIDs = [to]
    }

    /// Slide words along the notes by `steps` (positive = later notes).
    /// With no selection the whole lyric line moves; with a selection only those notes' words move, trading places with their neighbours.
    func shiftWords(_ clipID: UUID, by steps: Int, noteIDs: Set<UUID>) {
        guard steps != 0, let loc = findAudioClip(clipID), let tune = project.tracks[loc.track].audioClips[loc.clip].tune, !tune.notes.isEmpty else { return }
        pushUndo()
        editTune(clipID) { d in
            let order = d.notes.indices.sorted { d.notes[$0].start < d.notes[$1].start }       // note indices in time order
            let n = order.count
            var words = order.map { d.notes[$0].word }
            if noteIDs.isEmpty {
                // the whole line slides; words pushed past the ends pile onto the last/first note
                var out = [String](repeating: "", count: n)
                for (i, w) in words.enumerated() where !w.isEmpty {
                    let j = min(n - 1, max(0, i + steps))
                    out[j] = out[j].isEmpty ? w : (steps > 0 ? out[j] + " " + w : w + " " + out[j])
                }
                words = out
            } else {
                let selected = Set(order.indices.filter { noteIDs.contains(d.notes[order[$0]].id) })
                let sequence = steps > 0 ? Array(order.indices.reversed()) : Array(order.indices)
                for _ in 0..<abs(steps) {
                    for i in sequence where selected.contains(i) {
                        let j = i + (steps > 0 ? 1 : -1)
                        guard j >= 0, j < n else { continue }
                        words.swapAt(i, j)
                    }
                }
            }
            for (pos, idx) in order.enumerated() { d.notes[idx].word = words[pos] }
        }
    }

    func clearWords(_ clipID: UUID, noteIDs: Set<UUID>) {
        pushUndo()
        editTune(clipID) { d in for i in d.notes.indices where noteIDs.isEmpty || noteIDs.contains(d.notes[i].id) { d.notes[i].word = "" } }
    }
}
