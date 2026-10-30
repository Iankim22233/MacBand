import SwiftUI
import UniformTypeIdentifiers

struct PluginManagerView: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var lib = PluginLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Plugins").font(.system(size: 16, weight: .semibold))
                if lib.scanning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Rescan") { lib.rescan() }.disabled(lib.scanning)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Plugin folder")
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(Theme.dim)
                    Text(PluginFolders.userRoot.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([PluginFolders.userRoot]) }
                    Button("Install Plugin…") { chooseAndInstall() }
                }
                Text("Drop .component (AU) or .vst3 plugins here, or use Install, and MacBand copies them into the matching subfolder (Components, VST3). Plugins in /Library/Audio/Plug-Ins are found too.")
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(dropTargeted ? Theme.accent : Color.clear, lineWidth: 2).padding(6))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                var urls: [URL] = []
                let group = DispatchGroup()
                for p in providers {
                    group.enter()
                    _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { urls.append(u) }; group.leave() }
                }
                group.notify(queue: .main) { session.installPlugins(urls) }
                return true
            }
            Divider()

            List {
                if !lib.blocked.isEmpty {
                    Section("Blocked by macOS") {
                        Text("These were downloaded from the internet, so macOS won't let any app load them until you allow them.")
                            .font(.system(size: 11)).foregroundStyle(Theme.faint)
                        ForEach(lib.blocked, id: \.path) { url in
                            HStack {
                                Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
                                Text(url.lastPathComponent).font(.system(size: 12.5))
                                Spacer()
                                Button("Allow…") { _ = lib.allow(url) }
                            }
                        }
                    }
                }
                Section("Instruments (\(lib.instruments.count))") {
                    ForEach(lib.instruments) { PluginRow(plugin: $0) }
                }
                Section("Effects (\(lib.effects.count))") {
                    ForEach(lib.effects) { PluginRow(plugin: $0) }
                }
                if !lib.skipped.isEmpty {
                    Section("Not usable") {
                        ForEach(lib.skipped, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(Theme.faint) }
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 640, height: 640)
        .background(Theme.panel)
    }

    private func chooseAndInstall() {
        let panel = NSOpenPanel()
        panel.title = "Choose plugins to install"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = ["component", "vst3", "vst"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { session.installPlugins(panel.urls) }
    }
}

private struct PluginRow: View {
    let plugin: LibraryPlugin
    var body: some View {
        HStack {
            Text(plugin.spec.name).font(.system(size: 12.5))
            Text(plugin.spec.vendor).font(.system(size: 11)).foregroundStyle(Theme.faint)
            Spacer()
            Text(plugin.spec.format == .au ? "AU" : "VST3")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.dim)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
        }
    }
}
