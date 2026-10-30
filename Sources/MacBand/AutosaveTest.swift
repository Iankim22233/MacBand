import Foundation
import AppKit

/// `--autosavetest`: edits are saved to the project file by themselves, with backups; untitled projects come back after a crash.
@MainActor enum AutosaveTest {
    static var failures = 0
    static func check(_ ok: Bool, _ m: String) { print(ok ? "  ok    \(m)" : "  FAIL  \(m)"); if !ok { failures += 1 } }

    static func run() -> Int32 {
        _ = NSApplication.shared
        print("== Auto Save test ==")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-autosave-test-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AutosaveStore.folderOverride = root.appendingPathComponent("support", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root); AutosaveStore.folderOverride = nil; UserDefaults.standard.removeObject(forKey: "autoSave") }
        UserDefaults.standard.removeObject(forKey: "autoSave")

        // when to save
        let t0 = Date(timeIntervalSince1970: 1000)
        check(AutosaveStore.shouldSave(enabled: true, dirty: true, dirtySince: t0, now: t0.addingTimeInterval(11), delay: 10), "changes pending for 10 s are saved")
        check(!AutosaveStore.shouldSave(enabled: true, dirty: true, dirtySince: t0, now: t0.addingTimeInterval(4), delay: 10), "…but not straight away (a burst of edits is one save)")
        check(!AutosaveStore.shouldSave(enabled: false, dirty: true, dirtySince: t0, now: t0.addingTimeInterval(60), delay: 10), "nothing is saved when Auto Save is off")
        check(!AutosaveStore.shouldSave(enabled: true, dirty: false, dirtySince: nil, now: t0.addingTimeInterval(60), delay: 10), "…or when there is nothing to save")

        func addNote(_ s: Session, _ pitch: Int) {
            s.edit { p in p.tracks[0].clips[0].notes.append(Note(pitch: pitch, start: 0, length: 1)) }
        }
        func noteCount(_ url: URL) -> Int {
            guard let p = try? JSONDecoder().decode(Project.self, from: Data(contentsOf: url)) else { return -1 }
            return p.tracks.flatMap { $0.clips }.reduce(0) { $0 + $1.notes.count }
        }

        // a project with a file
        let file = root.appendingPathComponent("Song.macband")
        let s = Session()
        s.write(to: file)
        check(noteCount(file) == 0 && !s.isDirty, "a fresh project is saved")
        addNote(s, 60)
        check(s.isDirty, "an edit makes it unsaved")
        s.autosaver.save(s)
        check(noteCount(file) == 1 && !s.isDirty, "auto save writes the edit to the project file and clears the unsaved mark")
        check(s.lastAutoSave != nil && s.lastAutoSaveText.hasPrefix("Auto-saved"), "…and the menu shows when (\(s.lastAutoSaveText))")
        let backups = AutosaveStore.backupFolder(for: "Song")
        let first = (try? FileManager.default.contentsOfDirectory(atPath: backups.path))?.filter { $0.hasSuffix(".macband") } ?? []
        check(first.count == 1 && noteCount(backups.appendingPathComponent(first[0])) == 0, "the version it overwrote was kept as a backup")
        addNote(s, 62); s.autosaver.save(s)
        let again = (try? FileManager.default.contentsOfDirectory(atPath: backups.path))?.filter { $0.hasSuffix(".macband") } ?? []
        check(noteCount(file) == 2 && again.count == 1, "saving again soon after doesn't pile up backups")
        for i in 1...14 { s.autosaver.backUpIfDue(file, projectName: "Song", now: Date().addingTimeInterval(Double(i) * 700)) }
        let rotated = (try? FileManager.default.contentsOfDirectory(atPath: backups.path))?.filter { $0.hasSuffix(".macband") } ?? []
        check(rotated.count == AutosaveStore.backupsKept, "only the last \(AutosaveStore.backupsKept) backups are kept (\(rotated.count))")

        // by itself, on the timer
        s.autosaver.delay = 0.4; s.autosaver.pollInterval = 0.1; s.autosaver.restart()
        addNote(s, 64)
        SelfTest.pump(2.0) { !s.isDirty }
        check(noteCount(file) == 3 && !s.isDirty, "left alone, the edit reaches the file by itself")
        // switched off
        s.autoSaveEnabled = false
        addNote(s, 65)
        SelfTest.pump(1.5)
        check(noteCount(file) == 3 && s.isDirty, "with Auto Save off the file isn't touched")
        s.autoSaveEnabled = true
        SelfTest.pump(2.0) { !s.isDirty }
        check(noteCount(file) == 4, "switching it back on saves what was pending")

        // an untitled project: recovery copy, then restore
        let u = Session()
        check(u.fileURL == nil, "a new project has no file")
        u.edit { p in p.name = "Sketch"; p.tracks[0].clips[0].notes.append(Note(pitch: 67, start: 0, length: 1)) }
        u.autosaver.save(u)
        check(FileManager.default.fileExists(atPath: AutosaveStore.recoveryFile.path), "an untitled project gets a recovery copy")
        check(u.isDirty && u.fileURL == nil, "…and still counts as unsaved")
        let recovered = try? JSONDecoder().decode(Project.self, from: Data(contentsOf: AutosaveStore.recoveryFile))
        check(recovered?.name == "Sketch" && recovered?.tracks.first?.clips.first?.notes.count == 1, "the recovery copy holds the work")
        let fresh = Session()
        fresh.restoreRecovered(recovered!)
        check(fresh.project.name == "Sketch" && fresh.project.tracks[0].clips[0].notes.count == 1 && fresh.isDirty && fresh.fileURL == nil, "restoring brings the project back, still needing a Save")
        let saved = root.appendingPathComponent("Sketch.macband")
        fresh.write(to: saved)
        check(!FileManager.default.fileExists(atPath: AutosaveStore.recoveryFile.path), "saving it for real removes the recovery copy")

        print(failures == 0 ? "ALL AUTO SAVE CHECKS PASSED" : "\(failures) AUTO SAVE CHECK(S) FAILED")
        return failures == 0 ? 0 : 1
    }
}
