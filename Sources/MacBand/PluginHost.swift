import Foundation
import AVFoundation
import AudioToolbox
import CoreAudioKit
import AppKit
import SwiftUI

/// Where plugins live and get installed.
enum PluginFolders {
    static let userRoot = URL(fileURLWithPath: "/Users/user/Library/Audio/Plug-Ins", isDirectory: true)
    static let systemRoot = URL(fileURLWithPath: "/Library/Audio/Plug-Ins", isDirectory: true)
    static var components: URL { userRoot.appendingPathComponent("Components", isDirectory: true) }
    static var vst3: URL { userRoot.appendingPathComponent("VST3", isDirectory: true) }
    static var vst2: URL { userRoot.appendingPathComponent("VST", isDirectory: true) }

    /// Destination subfolder for a plugin bundle, based on its extension.
    static func destination(for url: URL) -> URL? {
        switch url.pathExtension.lowercased() {
        case "component": return components
        case "vst3": return vst3
        case "vst": return vst2
        default: return nil
        }
    }
}

enum PluginHost {
    static func isQuarantined(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Bundle path of an installed plugin, used to refuse loading anything macOS has quarantined.
    static func bundlePath(for spec: PluginSpec) -> String? {
        switch spec.format {
        case .vst3: return spec.vst3Path
        case .au:
            let d = AudioComponentDescription(componentType: spec.auType, componentSubType: spec.auSubtype,
                                              componentManufacturer: spec.auManufacturer, componentFlags: 0, componentFlagsMask: 0)
            return AVAudioUnitComponentManager.shared().components(matching: d).first?.componentURL?.path
        }
    }

    static func fourCC(_ s: String) -> UInt32 { s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) } }

    static func instantiate(_ spec: PluginSpec) async throws -> AVAudioUnit {
        // Loading a quarantined plugin makes macOS pop up a "Not Opened" dialog with a Move to Trash button.
        if let path = bundlePath(for: spec), isQuarantined(path) {
            throw EngineError.message("\(spec.name) is blocked by macOS because it was downloaded from the internet. Open the Plugin Manager and choose Allow next to it.")
        }
        let unit: AVAudioUnit
        switch spec.format {
        case .au:
            let desc = AudioComponentDescription(componentType: spec.auType, componentSubType: spec.auSubtype,
                                                 componentManufacturer: spec.auManufacturer, componentFlags: 0, componentFlagsMask: 0)
            await primeOnMainThread(desc)
            do {
                unit = try await AVAudioUnit.instantiate(with: desc, options: [])
            } catch {
                // Intel-only plugins on Apple silicon can still run out of process.
                do { unit = try await AVAudioUnit.instantiate(with: desc, options: [.loadOutOfProcess]) }
                catch { throw EngineError.message("\(spec.name) failed to load (\(error.localizedDescription))") }
            }
        case .vst3:
            unit = try await VST3Support.instantiate(spec)
        }
        if let data = spec.state { restoreState(unit, data) }
        return unit
    }

    /// JUCE-based plugins remember the thread that first created them as their "message thread", but
    /// AVAudioUnit.instantiate builds the plugin on a background queue. Menus inside such editors then
    /// highlight but never commit a choice. One idle instance created on the main thread (and kept alive,
    /// since JUCE tears its state down with the last instance) makes the main thread the message thread.
    @MainActor private static var primers: [String: AudioComponentInstance] = [:]
    @MainActor private static func primeOnMainThread(_ d: AudioComponentDescription) async {
        guard d.componentManufacturer != fourCC("appl") else { return }
        let key = "\(d.componentType)-\(d.componentSubType)-\(d.componentManufacturer)"
        guard primers[key] == nil else { return }
        var desc = d
        guard let comp = AudioComponentFindNext(nil, &desc) else { return }
        var inst: AudioComponentInstance?
        if AudioComponentInstanceNew(comp, &inst) == noErr, let inst { primers[key] = inst }
    }

    static func captureState(_ unit: AVAudioUnit) -> Data? {
        guard let st = unit.auAudioUnit.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: st, format: .binary, options: 0)
    }

    static func restoreState(_ unit: AVAudioUnit, _ data: Data) {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { return }
        unit.auAudioUnit.fullState = dict
    }
}

// MARK: - Plugin library

struct LibraryPlugin: Identifiable, Hashable {
    var spec: PluginSpec
    var path: String
    var id: String { spec.key }
}

@MainActor
final class PluginLibrary: ObservableObject {
    static let shared = PluginLibrary()
    @Published var plugins: [LibraryPlugin] = []
    @Published var scanning = false
    @Published var skipped: [String] = []     // VST2 and unreadable bundles
    @Published var blocked: [URL] = []        // downloaded plugins macOS has quarantined

    var instruments: [LibraryPlugin] { plugins.filter { $0.spec.isInstrument } }
    var effects: [LibraryPlugin] { plugins.filter { !$0.spec.isInstrument } }

    private let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacBand", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vst3-cache.json")
    }()

    func rescan() {
        guard !scanning else { return }
        scanning = true
        Task {
            var found: [LibraryPlugin] = []
            found += scanAU()
            let (vst3, skipped) = await scanVST3()
            found += vst3
            found.sort { ($0.spec.name.lowercased(), $0.spec.format.rawValue) < ($1.spec.name.lowercased(), $1.spec.format.rawValue) }
            self.plugins = found
            self.skipped = skipped
            self.blocked = PluginLibrary.findQuarantined()
            self.scanning = false
        }
    }

    private func scanAU() -> [LibraryPlugin] {
        let mgr = AVAudioUnitComponentManager.shared()
        let all = mgr.components(matching: AudioComponentDescription())
        var out: [LibraryPlugin] = []
        for c in all {
            let d = c.audioComponentDescription
            let isInst = d.componentType == kAudioUnitType_MusicDevice
            let isFx = d.componentType == kAudioUnitType_Effect || d.componentType == kAudioUnitType_MusicEffect
            guard isInst || isFx else { continue }
            if PluginHost.isQuarantined(c.componentURL?.path ?? "") { continue }
            let spec = PluginSpec(format: .au, name: c.name, vendor: c.manufacturerName, isInstrument: isInst,
                                  auType: d.componentType, auSubtype: d.componentSubType, auManufacturer: d.componentManufacturer)
            out.append(LibraryPlugin(spec: spec, path: c.componentURL?.path ?? ""))
        }
        // Drop duplicate registrations
        var seen = Set<String>()
        return out.filter { seen.insert($0.spec.key).inserted }
    }

    /// VST3 bundles are probed in a child process so a misbehaving plugin can't take the app down.
    private func scanVST3() async -> ([LibraryPlugin], [String]) {
        var bundles: [URL] = []
        var skipped: [String] = []
        let fm = FileManager.default
        // .vst3 bundles are also found in the VST folders, where installers sometimes drop them
        let roots = [PluginFolders.vst3, PluginFolders.systemRoot.appendingPathComponent("VST3"),
                     PluginFolders.vst2, PluginFolders.systemRoot.appendingPathComponent("VST")]
        var scanRoots = roots
        if let extra = ProcessInfo.processInfo.environment["MACBAND_EXTRA_PLUGIN_DIR"] { scanRoots.append(URL(fileURLWithPath: extra)) }   // developer aid
        for root in scanRoots {
            if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                while let u = e.nextObject() as? URL {
                    if u.pathExtension.lowercased() == "vst3" {
                        e.skipDescendants()
                        if !PluginHost.isQuarantined(u.path) { bundles.append(u) }   // blocked ones are listed separately
                    }
                }
            }
        }
        for root in [PluginFolders.vst2, PluginFolders.systemRoot.appendingPathComponent("VST")] {
            if let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                for u in items where u.pathExtension.lowercased() == "vst" { skipped.append("\(u.lastPathComponent) (VST2 isn't supported; use its AU or VST3 version)") }
            }
        }
        var results: [LibraryPlugin] = []
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        await withTaskGroup(of: [LibraryPlugin].self) { group in
            var next = 0
            func launch() -> Bool {
                guard next < bundles.count else { return false }
                let b = bundles[next]; next += 1
                group.addTask { await PluginLibrary.probe(bundle: b, exe: exe) }
                return true
            }
            for _ in 0..<4 { _ = launch() }
            for await r in group {
                results += r
                _ = launch()
            }
        }
        for b in bundles where !results.contains(where: { $0.path == b.path }) {
            let archs = Bundle(url: b)?.executableArchitectures?.map { $0.intValue } ?? []
            let hasARM = archs.contains(NSBundleExecutableArchitectureARM64)
            let why = (!archs.isEmpty && !hasARM)
                ? "Intel-only, can't run in this Apple-silicon app — use its AU version if it has one"
                : "couldn't be loaded"
            skipped.append("\(b.lastPathComponent) (\(why))")
        }
        return (results, skipped.sorted())
    }

    /// Plugin bundles carrying macOS's download quarantine flag; Gatekeeper refuses to load these.
    nonisolated static func findQuarantined() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for root in [PluginFolders.components, PluginFolders.vst3, PluginFolders.vst2,
                     PluginFolders.systemRoot.appendingPathComponent("Components"),
                     PluginFolders.systemRoot.appendingPathComponent("VST3"),
                     PluginFolders.systemRoot.appendingPathComponent("VST")] {
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for u in items where getxattr(u.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 { out.append(u) }
        }
        return out
    }

    /// Clears the quarantine flag on one plugin after the user confirms.
    func allow(_ url: URL) -> Bool {
        let a = NSAlert()
        a.messageText = "Allow “\(url.lastPathComponent)”?"
        a.informativeText = "macOS blocked this plugin because it was downloaded from the internet and hasn't been checked by Apple. Only continue if you trust where it came from. MacBand will clear the download flag on this one plugin."
        a.addButton(withTitle: "Allow Plugin"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", url.path]
        do { try p.run(); p.waitUntilExit() } catch { return false }
        rescan()
        return p.terminationStatus == 0
    }

    nonisolated static func probe(bundle: URL, exe: String) async -> [LibraryPlugin] {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = ["--scan-vst3", bundle.path]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: []); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { cont.resume(returning: []); return }
                let plugins: [LibraryPlugin] = arr.compactMap { d in
                    guard let name = d["name"] as? String, let cid = d["classID"] as? String else { return nil }
                    var spec = PluginSpec(format: .vst3, name: name, vendor: d["vendor"] as? String ?? "", isInstrument: d["instrument"] as? Bool ?? false)
                    spec.vst3Path = bundle.path; spec.vst3ClassID = cid
                    return LibraryPlugin(spec: spec, path: bundle.path)
                }
                cont.resume(returning: plugins)
            }
        }
    }

    // MARK: Install ("transfer") into ~/Library/Audio/Plug-Ins

    enum InstallResult { case installed(URL), failed(String) }

    func install(_ urls: [URL], replace: (String) -> Bool) -> [InstallResult] {
        let fm = FileManager.default
        var results: [InstallResult] = []
        for src in urls {
            guard let destDir = PluginFolders.destination(for: src) else {
                results.append(.failed("\(src.lastPathComponent): not a .component, .vst3 or .vst plugin")); continue
            }
            do {
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                let dst = destDir.appendingPathComponent(src.lastPathComponent)
                if fm.fileExists(atPath: dst.path) {
                    guard replace(src.lastPathComponent) else { results.append(.failed("\(src.lastPathComponent): skipped (already installed)")); continue }
                    try fm.trashItem(at: dst, resultingItemURL: nil)
                }
                try fm.copyItem(at: src, to: dst)
                results.append(.installed(dst))
            } catch { results.append(.failed("\(src.lastPathComponent): \(error.localizedDescription)")) }
        }
        return results
    }
}

// MARK: - Plugin windows

@MainActor
final class PluginWindows: NSObject, NSWindowDelegate {
    static let shared = PluginWindows()
    private var windows: [UUID: NSWindow] = [:]
    private var pending: Set<UUID> = []
    private var tagged = Set<Int>()

    /// While MacBand is fullscreen, plugin windows must be allowed into that Space and stay above it; in a normal
    /// window they behave like any other window. Windows a plugin creates itself (its popup menus, tooltips, drop-downs)
    /// are never modified: changing them breaks menu tracking in some plugins.
    func installFullscreenSupport() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if (n.object as? NSWindow)?.identifier?.rawValue == "main" { self?.applyLevels() } }
        }
        nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if (n.object as? NSWindow)?.identifier?.rawValue == "main" { self?.applyLevels() } }
        }
        // Titled dialogs (a plugin's nag screen or file panel) may need to join the fullscreen Space too.
        nc.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tagDialogs() }
        }
    }

    private var mainIsFullscreen: Bool {
        NSApp.windows.first { $0.identifier?.rawValue == "main" }?.styleMask.contains(.fullScreen) ?? false
    }

    private func applyLevels() {
        for w in windows.values { w.level = mainIsFullscreen ? .floating : .normal }
    }

    private func tagDialogs() {
        guard mainIsFullscreen else { return }
        let mine = Set(windows.values.map { $0.windowNumber })
        for w in NSApp.windows where !tagged.contains(w.windowNumber) && w.windowNumber > 0 && !mine.contains(w.windowNumber) {
            tagged.insert(w.windowNumber)
            guard w.identifier?.rawValue != "main", w.styleMask.contains(.titled) else { continue }
            w.collectionBehavior.insert(.fullScreenAuxiliary)
        }
    }

    func window(for key: UUID) -> NSWindow? { windows[key] }

    /// Shows the editor. The view is created once and then just hidden/shown, because many plugin
    /// editors misbehave when a second view is made for the same plugin instance.
    func open(unit: AVAudioUnit, title: String, key: UUID) {
        if let w = windows[key] { show(w); return }
        guard !pending.contains(key) else { return }
        pending.insert(key)
        NSLog("MacBand: requesting editor for \(title)")
        unit.auAudioUnit.requestViewController { [weak self] vc in
            NSLog("MacBand: editor for \(title) → \(vc.map { String(describing: type(of: $0)) } ?? "nil (using generic view)")")
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(key)
                let controller: NSViewController = vc ?? NSHostingController(rootView: GenericPluginView(unit: unit))
                let w = NSWindow(contentViewController: controller)
                w.title = title
                w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
                w.isReleasedWhenClosed = false
                w.delegate = self
                w.collectionBehavior.insert(.fullScreenAuxiliary)
                w.level = self.mainIsFullscreen ? .floating : .normal
                w.hidesOnDeactivate = false
                w.center()
                self.windows[key] = w
                self.show(w)
            }
        }
    }

    private func show(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.orderFrontRegardless()
        w.makeKeyAndOrderFront(nil)
    }

    // Closing hides the window; the editor stays alive for the next open.
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { sender.orderOut(nil) }
        return false
    }

    /// Really close editors whose plugin instance is going away.
    func discard(_ keys: some Sequence<UUID>) {
        for k in keys { if let w = windows.removeValue(forKey: k) { w.delegate = nil; w.close() } }
    }

    /// Developer aid: render one plugin window's contents to a PNG (captures only that window).
    func snapshot(key: UUID, to path: String) {
        guard let v = windows[key]?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
    }

    func closeAll() { discard(Array(windows.keys)) }
}

/// Fallback editor for plugins without their own UI: a slider per parameter.
struct GenericPluginView: View {
    let unit: AVAudioUnit
    var body: some View {
        let params = Array((unit.auAudioUnit.parameterTree?.allParameters ?? []).prefix(96))
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if params.isEmpty { Text("This plugin has no adjustable parameters.").foregroundStyle(.secondary) }
                ForEach(params, id: \.address) { p in ParamRow(param: p) }
            }.padding(16)
        }
        .frame(minWidth: 380, minHeight: 240, idealHeight: 420)
    }
}

private struct ParamRow: View {
    let param: AUParameter
    @State private var value: Float
    init(param: AUParameter) { self.param = param; _value = State(initialValue: param.value) }
    var body: some View {
        HStack {
            Text(param.displayName).frame(width: 150, alignment: .leading).lineLimit(1)
            Slider(value: Binding(get: { value }, set: { value = $0; param.value = $0 }), in: param.minValue...max(param.maxValue, param.minValue + 0.0001))
            Text(String(format: "%.2f", value)).monospacedDigit().frame(width: 56, alignment: .trailing).foregroundStyle(.secondary)
        }
    }
}

/// Dev aid (`--eventlog`): logs every mouse event with the window that receives it, to
/// ~/Library/Logs/MacBand-events.log, to diagnose plugin popup menus.
@MainActor enum EventLog {
    private static var monitor: Any?
    private static var handle: FileHandle?
    static func installIfRequested() {
        guard CommandLine.arguments.contains("--eventlog"), monitor == nil else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacBand-events.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        let t0 = Date()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged]) { ev in
            let w = ev.window
            let line = String(format: "%.3f %@ win=%@ cls=%@ level=%d key=%d num=%d btns=%lu active=%d keyWin=%@ loc=(%.0f,%.0f)\n",
                              Date().timeIntervalSince(t0), "\(ev.type.rawValue)",
                              w?.title ?? "-", w.map { String(describing: type(of: $0)) } ?? "nil", w?.level.rawValue ?? -1,
                              (w?.isKeyWindow ?? false) ? 1 : 0, w?.windowNumber ?? -1, NSEvent.pressedMouseButtons,
                              NSApp.isActive ? 1 : 0, NSApp.keyWindow?.title ?? "-", ev.locationInWindow.x, ev.locationInWindow.y)
            handle?.write(line.data(using: .utf8)!)
            return ev
        }
    }
}
