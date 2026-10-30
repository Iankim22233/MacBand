import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MacBandApp: App {
    @StateObject private var session = Session()

    var body: some Scene {
        Window("MacBand", id: "main") {
            ContentView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
                .frame(minWidth: 980, minHeight: 620)
                .onOpenURL { url in session.handleDrop([url]) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { session.newProject() }.keyboardShortcut("n")
                Button("Open…") { session.openProject() }.keyboardShortcut("o")
                Divider()
                Button("Save") { session.save() }.keyboardShortcut("s")
                Toggle("Auto Save", isOn: Binding(get: { session.autoSaveEnabled }, set: { session.autoSaveEnabled = $0 }))
                Button("Export Band Project…") { session.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Menu("Import") {
                    Button("MIDI File…") { session.importMIDI() }.keyboardShortcut("i")
                    Button("Audio File…") { session.importAudio() }.keyboardShortcut("i", modifiers: [.command, .shift])
                    Button("Band Project…") { session.importBandProject() }
                }
                Menu("Export") {
                    Button("MIDI File…") { session.exportMIDI() }.keyboardShortcut("e")
                    Button("Audio (WAV)…") { session.exportAudio() }.keyboardShortcut("e", modifiers: [.command, .shift])
                    Button("Band Project…") { session.saveAs() }
                }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { session.undo() }.keyboardShortcut("z").disabled(!session.canUndo)
                Button("Redo") { session.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!session.canRedo)
            }
            CommandMenu("Track") {
                Button("New Instrument Track") { session.addTrack() }.keyboardShortcut("t")
                Button("Duplicate Track") { if let t = session.selectedTrackID { session.duplicateTrack(t) } }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Delete Track") { if let t = session.selectedTrackID { session.deleteTrack(t) } }
                Divider()
                Button("Plugin Manager…") { session.showPluginManager = true }.keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandMenu("Transport") {
                Button("Play / Stop") { session.togglePlay() }
                Button("Go to Start") { session.rewind() }
                Button("Record") { session.toggleRecord() }
                Button("Loop") { session.toggleLoop() }
                Button("Metronome") { session.metronome.toggle() }
                Divider()
                Button("Musical Typing") { session.musicalTyping.toggle() }.keyboardShortcut("k")
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var session: Session
    @State private var editorHeight: CGFloat = 400
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            TransportBar()
            Divider().overlay(Theme.line)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ArrangementView()
                    if session.showEditor {
                        ResizeHandle(height: $editorHeight)
                        BottomPanelView().frame(height: editorHeight)
                    }
                }
                if session.showInspector {
                    Divider().overlay(Theme.line)
                    InspectorView().frame(width: 264)
                }
            }
        }
        .background(Theme.window)
        .background(WindowConfigurator())
        .overlay { if let m = session.busyMessage { BusyOverlay(message: m) } }
        .overlay(alignment: .bottom) {
            if let t = session.toast {
                Text(t).font(.system(size: 12, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Capsule().fill(Theme.raised)).overlay(Capsule().stroke(Theme.line))
                    .padding(.bottom, 24).transition(.opacity).allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.toast)
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 8).stroke(Theme.accent, lineWidth: 2).padding(4).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { session.handleDrop([url]) } }
                }
            }
            return true
        }
        .sheet(isPresented: $session.showPluginManager) { PluginManagerView().environmentObject(session) }
        .alert("MacBand", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK") { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
    }
}

struct BusyOverlay: View {
    let message: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 12) { ProgressView(); Text(message).font(.system(size: 13)) }
                .padding(28).background(RoundedRectangle(cornerRadius: 12).fill(Theme.raised))
        }
    }
}

struct ResizeHandle: View {
    @Binding var height: CGFloat
    @State private var start: CGFloat?
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1)
            .overlay(Color.clear.frame(height: 9).contentShape(Rectangle()).onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }.gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if start == nil { start = height }
                    height = min(640, max(200, start! - v.translation.height))
                }.onEnded { _ in start = nil }))
    }
}

struct BottomPanelView: View {
    @EnvironmentObject var session: Session
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(BottomPanel.allCases) { p in
                    Button { session.bottomPanel = p } label: {
                        Text(p.rawValue).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(session.bottomPanel == p ? Theme.text : Theme.faint)
                            .padding(.horizontal, 14).frame(height: 28)
                            .overlay(alignment: .bottom) { if session.bottomPanel == p { Rectangle().fill(Theme.accent).frame(height: 2) } }
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            .background(Theme.panel)
            Divider().overlay(Theme.line)
            switch session.bottomPanel {
            case .editor: PianoRollContainer()
            case .tune: TuneContainer()
            case .mixer: MixerView()
            }
        }
        .background(Theme.panel)
    }
}
