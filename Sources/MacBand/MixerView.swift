import SwiftUI
import Combine

@MainActor
final class MeterBank: ObservableObject {
    @Published var levels: [UUID: Float] = [:]
    @Published var master: Float = 0
    private var timer: Timer?
    private weak var engine: AudioEngine?

    func start(_ engine: AudioEngine) {
        self.engine = engine
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func update() {
        guard let e = engine else { return }
        var next: [UUID: Float] = [:]
        for (id, s) in e.strips {
            let prev = levels[id] ?? 0
            next[id] = max(s.peak, prev * 0.86)
            if s.peak > 0 { s.peak = s.peak * 0.5 }
        }
        levels = next
        master = max(e.masterPeak, master * 0.86)
    }
}

struct MixerView: View {
    @EnvironmentObject var session: Session
    @StateObject private var meters = MeterBank()

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(session.project.tracks) { t in
                        ChannelStrip(track: t, level: meters.levels[t.id] ?? 0, selected: t.id == session.selectedTrackID)
                    }
                }
            }
            Divider().overlay(Theme.line)
            MasterStrip(level: meters.master)
        }
        .background(Theme.panel)
        .onAppear { meters.start(session.engine) }
        .onDisappear { meters.stop() }
    }
}

struct ChannelStrip: View {
    @EnvironmentObject var session: Session
    let track: Track
    let level: Float
    let selected: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text(track.name).font(.system(size: 11, weight: .semibold)).lineLimit(1).frame(maxWidth: .infinity)
                .padding(.top, 8)
            Slider(value: Binding(get: { track.pan }, set: { v in session.modify { p in if let i = p.tracks.firstIndex(where: { $0.id == track.id }) { p.tracks[i].pan = v } } }), in: -1...1) { e in if e { session.pushUndo() } }
                .controlSize(.mini).frame(width: 64).tint(Palette.color(track.colorIndex))
            FaderMeter(value: Binding(get: { track.volume }, set: { v in session.modify { p in if let i = p.tracks.firstIndex(where: { $0.id == track.id }) { p.tracks[i].volume = v } } }),
                       level: level, color: Palette.color(track.colorIndex), onBegin: { session.pushUndo() })
            HStack(spacing: 4) {
                Button { session.edit { p in if let i = p.tracks.firstIndex(where: { $0.id == track.id }) { p.tracks[i].mute.toggle() } } } label: { SmallTag(text: "M", active: track.mute, color: .yellow) }.buttonStyle(.plain)
                Button { session.edit { p in if let i = p.tracks.firstIndex(where: { $0.id == track.id }) { p.tracks[i].solo.toggle() } } } label: { SmallTag(text: "S", active: track.solo, color: Palette.color(1)) }.buttonStyle(.plain)
            }
            Text(track.instrument.displayName).font(.system(size: 9)).foregroundStyle(Theme.faint).lineLimit(1)
                .frame(maxWidth: .infinity).padding(.bottom, 8)
        }
        .padding(.horizontal, 8).frame(width: 92)
        .background(selected ? Color.white.opacity(0.04) : .clear)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture { session.selectedTrackID = track.id }
    }
}

struct MasterStrip: View {
    @EnvironmentObject var session: Session
    let level: Float
    var body: some View {
        VStack(spacing: 8) {
            Text("Master").font(.system(size: 11, weight: .semibold)).padding(.top, 8)
            Spacer().frame(height: 14)
            FaderMeter(value: Binding(get: { session.project.masterVolume }, set: { v in session.modify { $0.masterVolume = v } }),
                       level: level, color: Theme.accent, onBegin: { session.pushUndo() })
            Text(String(format: "%.0f%%", session.project.masterVolume / 0.8 * 100)).font(.system(size: 9)).foregroundStyle(Theme.faint).padding(.bottom, 8)
        }
        .frame(width: 92)
    }
}

/// Vertical fader with a level meter beside it.
struct FaderMeter: View {
    @Binding var value: Double
    let level: Float
    let color: Color
    var onBegin: () -> Void = {}
    @State private var began = false

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let db = level > 0.00001 ? 20 * log10(Double(level)) : -90
            let frac = min(1, max(0, (db + 60) / 66))
            HStack(spacing: 8) {
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.well)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .bottom, endPoint: .top))
                        .mask(alignment: .bottom) { Rectangle().frame(height: h * frac) }
                }.frame(width: 7)
                ZStack(alignment: .top) {
                    Capsule().fill(Theme.well).frame(width: 4).frame(maxHeight: .infinity)
                    // unity tick
                    Rectangle().fill(Color.white.opacity(0.25)).frame(width: 14, height: 1).offset(y: h * (1 - 0.8) - 0.5)
                    RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.88))
                        .frame(width: 26, height: 12)
                        .overlay(Rectangle().fill(color).frame(height: 2))
                        .offset(y: (h - 12) * (1 - value))
                }
                .frame(width: 30).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    if !began { onBegin(); began = true }
                    value = min(1, max(0, 1 - (g.location.y - 6) / (h - 12)))
                }.onEnded { _ in began = false })
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minHeight: 90)
    }
}
