import SwiftUI

struct TransportBar: View {
    @EnvironmentObject var session: Session

    var body: some View {
        HStack(spacing: 14) {
            // leaves room for the window buttons
            Color.clear.frame(width: 64, height: 1)

            Menu {
                Button("New Project") { session.newProject() }
                Button("Open…") { session.openProject() }
                Button("Save") { session.save() }
                Toggle("Auto Save", isOn: Binding(get: { session.autoSaveEnabled }, set: { session.autoSaveEnabled = $0 }))
                Text(session.lastAutoSaveText)
                Divider()
                Button("Import MIDI File…") { session.importMIDI() }
                Button("Import Band Project…") { session.importBandProject() }
                Divider()
                Button("Export MIDI File…") { session.exportMIDI() }
                Button("Export Band Project…") { session.saveAs() }
                Button("Export Audio (WAV)…") { session.exportAudio() }
            } label: {
                HStack(spacing: 5) {
                    Text(session.project.name + (session.isDirty ? " •" : "")).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }.foregroundStyle(Theme.text).frame(maxWidth: 170, alignment: .leading)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                IconButton(symbol: "backward.end.fill", help: "Go to start (Return)") { session.rewind() }
                PlayButton()
                RecordButton()
                LoopButton()
                IconButton(symbol: "metronome", active: session.metronome, help: "Metronome (C)") { session.metronome.toggle() }
            }

            LCDView()
            TempoControl()
            TimeSigControl()

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                if !session.lastMIDIDevice.isEmpty {
                    Image(systemName: "pianokeys").font(.system(size: 12)).foregroundStyle(Theme.dim).help("MIDI in: \(session.lastMIDIDevice)").padding(.trailing, 4)
                }
                IconButton(symbol: "keyboard", active: session.musicalTyping, help: "Musical typing (⌘K): A–L play notes, Z/X change octave") { session.musicalTyping.toggle() }
                IconButton(symbol: "puzzlepiece.extension", help: "Plugins (⇧⌘P)") { session.showPluginManager = true }
                IconButton(symbol: "pianokeys.inverse", active: session.showEditor, help: "Editor & mixer") { session.showEditor.toggle() }
                IconButton(symbol: "sidebar.right", active: session.showInspector, help: "Inspector") { session.showInspector.toggle() }
            }
            .padding(.trailing, 10)
        }
        .frame(height: 52)
        .background(Theme.panel)
    }
}

private struct PlayButton: View {
    @EnvironmentObject var session: Session
    var body: some View { Inner(transport: session.transport) }
    struct Inner: View {
        @EnvironmentObject var session: Session
        @ObservedObject var transport: Transport
        var body: some View {
            IconButton(symbol: transport.isPlaying ? "pause.fill" : "play.fill", active: transport.isPlaying, tint: .green, help: "Play / Stop (Space)") { session.togglePlay() }
        }
    }
}

private struct RecordButton: View {
    @EnvironmentObject var session: Session
    var body: some View { Inner(transport: session.transport) }
    struct Inner: View {
        @EnvironmentObject var session: Session
        @ObservedObject var transport: Transport
        var body: some View {
            IconButton(symbol: "record.circle", active: transport.isRecording, tint: .red, help: "Record notes from a MIDI keyboard or musical typing (R)") { session.toggleRecord() }
        }
    }
}

private struct LoopButton: View {
    @EnvironmentObject var session: Session
    var body: some View {
        IconButton(symbol: "repeat", active: session.project.loopEnabled, help: "Loop (L) — drag in the loop strip above the ruler to set the range") { session.toggleLoop() }
    }
}

/// Bars · beats · ticks and minutes:seconds.
struct LCDView: View {
    @EnvironmentObject var session: Session
    var body: some View { Inner(transport: session.transport) }
    struct Inner: View {
        @EnvironmentObject var session: Session
        @ObservedObject var transport: Transport
        var body: some View {
            let p = session.project
            let b = transport.beat
            let bpb = p.beatsPerBar
            let bar = Int(b / bpb) + 1
            let beat = Int(b.truncatingRemainder(dividingBy: bpb)) + 1
            let tick = Int((b - b.rounded(.down)) * 100)
            let secs = p.seconds(atBeat: b)
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(String(format: "%03d.%d.%02d", bar, beat, tick)).font(Theme.lcd)
                }
                Text(String(format: "%02d:%04.1f", Int(secs) / 60, secs.truncatingRemainder(dividingBy: 60)))
                    .font(.system(size: 13, weight: .regular, design: .monospaced)).foregroundStyle(Theme.dim)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
        }
    }
}

struct TempoControl: View {
    @EnvironmentObject var session: Session
    var body: some View { Inner(transport: session.transport) }
    struct Inner: View {
        @EnvironmentObject var session: Session
        @ObservedObject var transport: Transport
        @State private var text = ""
        @State private var editing = false
        @FocusState private var focused: Bool
        var body: some View {
            let auto = !session.project.tempoPoints.isEmpty
            let shown = auto ? session.project.bpm(at: transport.beat) : session.project.tempo
            HStack(spacing: 6) {
                if editing && !auto {
                    TextField("", text: $text)
                        .textFieldStyle(.plain).font(Theme.lcd).frame(width: 64).multilineTextAlignment(.trailing)
                        .focused($focused)
                        .onSubmit { if let v = Double(text) { session.setTempo(v) }; editing = false }
                        .onExitCommand { editing = false }
                } else {
                    Text(auto ? String(format: "%.1f", shown) : String(format: "%g", shown))
                        .font(Theme.lcd).frame(minWidth: 64, alignment: .trailing)
                        .onTapGesture(count: 2) { if !auto { text = String(format: "%g", shown); editing = true; focused = true } }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("BPM").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint)
                    if auto { Text("AUTO").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent) }
                }
                if !auto {
                    VStack(spacing: 0) {
                        Button { session.setTempo(session.project.tempo + 1) } label: { Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold)).frame(width: 16, height: 14) }.buttonStyle(.plain)
                        Button { session.setTempo(session.project.tempo - 1) } label: { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).frame(width: 16, height: 14) }.buttonStyle(.plain)
                    }.foregroundStyle(Theme.dim)
                }
                Button("Tap") { session.tapTempo() }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.dim)
                    .padding(.horizontal, 7).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))
                    .help("Tap three or more times to set the tempo")
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            .help(auto ? "Tempo follows the tempo lane under the ruler" : "Double-click to type a tempo")
        }
    }
}

struct TimeSigControl: View {
    @EnvironmentObject var session: Session
    var body: some View {
        Menu {
            ForEach([(4, 4), (3, 4), (2, 4), (5, 4), (6, 8), (7, 8), (12, 8), (6, 4)], id: \.0) { (n, d) in
                Button("\(n)/\(d)") { session.edit { $0.timeSigNum = n; $0.timeSigDen = d } }
            }
        } label: {
            Text("\(session.project.timeSigNum)/\(session.project.timeSigDen)")
                .font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(Theme.text)
                .frame(width: 52, height: 36)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.well))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}
