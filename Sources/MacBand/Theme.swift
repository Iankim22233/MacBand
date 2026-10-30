import SwiftUI
import AppKit

enum Theme {
    static let ns = (
        window: NSColor(red: 0.105, green: 0.110, blue: 0.125, alpha: 1),
        panel: NSColor(red: 0.135, green: 0.140, blue: 0.158, alpha: 1),
        raised: NSColor(red: 0.175, green: 0.182, blue: 0.205, alpha: 1),
        well: NSColor(red: 0.085, green: 0.088, blue: 0.100, alpha: 1),
        line: NSColor(white: 1, alpha: 0.07),
        lineStrong: NSColor(white: 1, alpha: 0.14),
        text: NSColor(white: 0.92, alpha: 1),
        dim: NSColor(white: 0.58, alpha: 1),
        faint: NSColor(white: 0.38, alpha: 1),
        accent: NSColor.controlAccentColor
    )
    static let window = Color(nsColor: ns.window)
    static let panel = Color(nsColor: ns.panel)
    static let raised = Color(nsColor: ns.raised)
    static let well = Color(nsColor: ns.well)
    static let line = Color(nsColor: ns.line)
    static let text = Color(nsColor: ns.text)
    static let dim = Color(nsColor: ns.dim)
    static let faint = Color(nsColor: ns.faint)
    /// The app's main colour follows the system accent (System Settings ▸ Appearance ▸ Accent color).
    static var accentNS: NSColor { NSColor.controlAccentColor }
    static var accent: Color { Color(nsColor: NSColor.controlAccentColor) }
    static let lcd = Font.system(size: 20, weight: .medium, design: .monospaced)
    static let small = Font.system(size: 11)
    static let label = Font.system(size: 10, weight: .semibold)
}

/// Flat icon button used across the UI.
struct IconButton: View {
    let symbol: String
    var active = false
    var tint: Color? = nil
    var help = ""
    var size: CGFloat = 28
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? (tint ?? Theme.accent) : (hover ? Theme.text : Theme.dim))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? (tint ?? Theme.accent).opacity(0.16) : (hover ? Color.white.opacity(0.06) : .clear)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct SmallTag: View {
    let text: String
    var active = false
    var color: Color = Theme.accent
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(active ? Color.black.opacity(0.85) : Theme.dim)
            .frame(width: 22, height: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(active ? color : Color.white.opacity(0.07)))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(Theme.label).tracking(0.8).foregroundStyle(Theme.faint)
    }
}

/// Makes the hosting window look like the rest of the app and tags it for key handling.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.identifier = NSUserInterfaceItemIdentifier("main")
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = false
            w.backgroundColor = Theme.ns.window
            w.minSize = NSSize(width: 980, height: 620)
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}
