import Foundation
import AppKit
import SwiftUI

/// Where auto-save keeps its recovery copy and backups: the app's own support folder.
enum AutosaveStore {
    /// Tests point this somewhere else so they never touch real data.
    nonisolated(unsafe) static var folderOverride: URL?
    static var root: URL {
        if let o = folderOverride { return o }
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "MacBand"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(name, isDirectory: true)
    }
    static var recoveryFile: URL { root.appendingPathComponent("Autosave/Untitled recovery.macband") }
    static func backupFolder(for project: String) -> URL {
        let safe = project.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return root.appendingPathComponent("Backups/\(safe)", isDirectory: true)
    }
    static let backupsKept = 10
    static let backupEvery: TimeInterval = 10 * 60

    /// Auto-save fires once the project has had unsaved changes for `delay` seconds (so a burst of edits is one save).
    static func shouldSave(enabled: Bool, dirty: Bool, dirtySince: Date?, now: Date, delay: TimeInterval) -> Bool {
        enabled && dirty && (dirtySince.map { now.timeIntervalSince($0) >= delay } ?? false)
    }
}

/// Saves the project in the background: to its file when it has one (with rolling backups of what it overwrites),
/// otherwise to a recovery copy that is offered back after a crash or an unsaved quit.
@MainActor
final class Autosaver {
    private weak var session: Session?
    private var timer: Timer?
    private var dirtySince: Date?
    private var lastBackup: [String: Date] = [:]
    /// Seconds of pending changes before a save, and how often to check. (Tests shorten both.)
    var delay: TimeInterval = 10
    var pollInterval: TimeInterval = 2
    private var failedBefore = false

    func start(_ session: Session) {
        self.session = session
        // The developer test modes (--uitest …) make lots of throw-away projects: they must never write to the real folders.
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) { return }
        restart()
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNowIfNeeded() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willTerminate() }
        }
    }

    func restart() {
        timer?.invalidate()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        guard let s = session else { return }
        if s.isDirty { if dirtySince == nil { dirtySince = Date() } } else { dirtySince = nil }
        guard AutosaveStore.shouldSave(enabled: s.autoSaveEnabled, dirty: s.isDirty, dirtySince: dirtySince, now: Date(), delay: delay) else { return }
        // not in the middle of a recording or an offline render
        guard s.recorder == nil, s.busyMessage == nil, !s.engine.offlineBusy else { return }
        saveNowIfNeeded()
    }

    /// Saves right now if there is anything unsaved (also called when the app goes to the background).
    func saveNowIfNeeded() {
        guard let s = session, s.autoSaveEnabled, s.isDirty, s.recorder == nil, !s.engine.offlineBusy else { return }
        save(s)
    }

    private func willTerminate() {
        guard let s = session else { return }
        if s.isDirty && s.autoSaveEnabled { save(s) }
        else if s.fileURL == nil { try? FileManager.default.removeItem(at: AutosaveStore.recoveryFile) }     // clean, or auto save is off
    }

    func save(_ s: Session) {
        do {
            if let url = s.fileURL {
                backUpIfDue(url, projectName: s.project.name)
                try s.encodeProject().write(to: url, options: .atomic)
                s.isDirty = false
                s.saveAudioAssets(for: url)
            } else {
                try FileManager.default.createDirectory(at: AutosaveStore.recoveryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try s.encodeProject().write(to: AutosaveStore.recoveryFile, options: .atomic)     // still "unsaved": the project has no file yet
            }
            dirtySince = nil
            s.lastAutoSave = Date()
            failedBefore = false
        } catch {
            if !failedBefore { s.showToast("Auto Save couldn't save: \(error.localizedDescription)") }
            failedBefore = true
        }
    }

    /// Before overwriting a project file, keep a copy of what is on disk (at most one every ten minutes, last ten kept).
    func backUpIfDue(_ url: URL, projectName: String, now: Date = Date()) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let key = url.path
        if let last = lastBackup[key], now.timeIntervalSince(last) < AutosaveStore.backupEvery { return }
        let dir = AutosaveStore.backupFolder(for: url.deletingPathExtension().lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
            try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(f.string(from: now) + ".macband"))
            lastBackup[key] = now
            let all = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "macband" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for old in all.dropLast(AutosaveStore.backupsKept) { try? FileManager.default.removeItem(at: old) }
        } catch { /* a missing backup must never stop the save itself */ }
    }
}

extension Session {
    var autoSaveEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "autoSave") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoSave"); objectWillChange.send(); if newValue { autosaver.saveNowIfNeeded() } }
    }

    var lastAutoSaveText: String {
        guard let d = lastAutoSave else { return autoSaveEnabled ? "Auto Save is on" : "Auto Save is off" }
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return "Auto-saved \(f.string(from: d))"
    }

    /// An untitled project that was never saved (a crash, or a quit without saving) comes back after the next launch.
    func offerRecovery() {
        let url = AutosaveStore.recoveryFile
        guard fileURL == nil, !isDirty, FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(Project.self, from: data),
              p.tracks.contains(where: { $0.clips.contains { !$0.notes.isEmpty } || !$0.audioClips.isEmpty }) else { return }
        let when = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date) ?? Date()
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        let alert = NSAlert()
        alert.messageText = "Restore your unsaved project?"
        alert.informativeText = "“\(p.name)” was open and had not been saved when MacBand last closed (last auto-saved \(f.string(from: when)))."
        alert.addButton(withTitle: "Restore"); alert.addButton(withTitle: "Discard")
        if alert.runModal() == .alertFirstButtonReturn { restoreRecovered(p) } else { try? FileManager.default.removeItem(at: url) }
    }

    func restoreRecovered(_ p: Project) {
        stop(); PluginWindows.shared.closeAll()
        load(p, url: nil)
        isDirty = true                                      // it still needs a real Save
        showToast("Restored “\(p.name)”. Use Save to keep it.")
    }

    func clearRecoveryFile() { try? FileManager.default.removeItem(at: AutosaveStore.recoveryFile) }
}
