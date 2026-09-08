// Choir — made by Sam De Herdt for MakeWaves.
import SwiftUI
import AppKit

// MARK: - Motion tokens

/// One scale for the whole app, so every animation reads as one system:
/// open slightly slower than close, smooth-out easing for movement,
/// bounce reserved for emphasis.
enum Motion {
    static let stagger = 0.04
    static let micro = 0.08
    static let quick = 0.15
    static let fast = 0.25
    static let medium = 0.35
    static let slow = 0.40

    /// cubic-bezier(0.22, 1, 0.36, 1) — movement and resize.
    static func smoothOut(_ duration: Double) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }

    /// cubic-bezier(0.34, 1.36, 0.64, 1) — pop-in emphasis only.
    static func bounce(_ duration: Double) -> Animation {
        .timingCurve(0.34, 1.36, 0.64, 1, duration: duration)
    }

    /// Every animation in the app goes through here, so one switch in Settings
    /// (and the system's own Reduce Motion) turns the whole thing off.
    @MainActor static var disabled = false

    @MainActor static func on(_ animation: Animation) -> Animation? { disabled ? nil : animation }
}

extension View {
    /// Motion-token aware `.animation`, honouring the app's reduce-motion switch.
    @MainActor func motion<V: Equatable>(_ animation: Animation, value: V) -> some View {
        self.animation(Motion.disabled ? nil : animation, value: value)
    }
}

// MARK: - Palette

enum Palette {
    /// Project accents. Muted enough to sit under glass without shouting.
    static let accents: [Color] = [
        Color(red: 0.36, green: 0.45, blue: 0.95),
        Color(red: 0.85, green: 0.45, blue: 0.28),
        Color(red: 0.25, green: 0.65, blue: 0.52),
        Color(red: 0.65, green: 0.36, blue: 0.78),
        Color(red: 0.90, green: 0.66, blue: 0.20),
        Color(red: 0.88, green: 0.36, blue: 0.52),
    ]

    static func accent(_ index: Int) -> Color { accents[abs(index) % accents.count] }

    /// A stable colour per model, so the same voice looks the same everywhere.
    /// Continuous hue rather than six buckets: two models in one room must
    /// never share a colour, which six buckets could not guarantee.
    static func voice(_ key: String) -> Color {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let hue = Double(hash % 360) / 360
        return Color(hue: hue, saturation: 0.58, brightness: 0.78)
    }
}

// MARK: - Liquid Glass

/// True Liquid Glass on macOS 26; a material fallback below it. Every use is
/// gated because the deployment target is macOS 14.
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 18
    var interactive = false

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.10))
                )
        }
    }
}

struct GlassTint: ViewModifier {
    var color: Color
    var cornerRadius: CGFloat = 18

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(color.opacity(0.55)).interactive(),
                                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(color.opacity(0.22), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(color.opacity(0.35)))
        }
    }
}

struct ProminentGlassButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.buttonStyle(.glassProminent) }
        else { content.buttonStyle(.borderedProminent) }
    }
}

struct PlainGlassButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.buttonStyle(.glass) }
        else { content.buttonStyle(.bordered) }
    }
}

extension View {
    func glassPanel(_ cornerRadius: CGFloat = 18, interactive: Bool = false) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, interactive: interactive))
    }
    func glassTint(_ color: Color, cornerRadius: CGFloat = 18) -> some View {
        modifier(GlassTint(color: color, cornerRadius: cornerRadius))
    }
    func prominentGlassButton() -> some View { modifier(ProminentGlassButton()) }
    func plainGlassButton() -> some View { modifier(PlainGlassButton()) }
}

// MARK: - Small shared pieces

/// The dot that marks a model. Colour is derived from the model key, so the
/// same model is the same colour in the sidebar, the picker and a room.
struct VoiceDot: View {
    let key: String
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Palette.voice(key))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }
}

/// A pill for anything small and labelled — model names, applied library items.
struct Chip: View {
    let text: String
    var symbol: String?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// One panel with a title and an explainer, used across the library and settings screens.
struct Card<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(16)
    }
}


extension Color {
    init?(hex: String?) {
        guard var h = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexString: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

/// Reads a view's width without forcing its height, unlike a bare GeometryReader.
struct WidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    func readWidth(_ width: Binding<CGFloat>) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: WidthKey.self, value: g.size.width) })
            .onPreferenceChange(WidthKey.self) { width.wrappedValue = $0 }
    }
}


/// A 14 pt dot that opens the system colour panel. The native ColorPicker
/// well is a fat capsule that fights a toolbar; this is the size of a chip.
struct ColorSwatch: View {
    let color: Color
    let isCustom: Bool
    let onPick: (String?) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button {
                ColorPanelBridge.shared.open(current: NSColor(color)) { picked in onPick(Color(nsColor: picked).hexString) }
            } label: {
                Circle()
                    .fill(color)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                    .overlay(Circle().strokeBorder(color.opacity(0.5), lineWidth: 1).padding(-2))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(isCustom ? "Colour — click to change" : "Colour follows the model — click to choose one")
            if isCustom {
                Button { onPick(nil) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Back to the model's own colour")
            }
        }
    }
}

/// NSColorPanel needs an Objective-C target; this is the one object that plays it.
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((NSColor) -> Void)?

    func open(current: NSColor, onChange: @escaping (NSColor) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = current
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.isContinuous = true
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func changed(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}


import PDFKit

/// Text out of a dropped file, or nil when there is none to take.
enum FileText {
    static func extract(_ url: URL) -> ProjectFile? {
        let text: String?
        if url.pathExtension.lowercased() == "pdf" {
            text = PDFDocument(url: url)?.string
        } else {
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ProjectFile(name: url.lastPathComponent, text: text)
    }
}


/// A vertical scroll view whose indicator is a thin capsule in a colour of
/// your choosing — the system one cannot be tinted. The thumb tracks the
/// content offset through a preference key; no indicator when it all fits.
private struct ScrollMetrics: Equatable { var height: CGFloat; var minY: CGFloat }
private struct ScrollMetricsKey: PreferenceKey {
    static var defaultValue = ScrollMetrics(height: 0, minY: 0)
    static func reduce(value: inout ScrollMetrics, nextValue: () -> ScrollMetrics) { value = nextValue() }
}

struct TintedScrollView<Content: View>: View {
    let color: Color
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 0
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { outer in
            let visible = outer.size.height
            ScrollView(.vertical) {
                content
                    .background(
                        GeometryReader { inner in
                            Color.clear.preference(key: ScrollMetricsKey.self,
                                                   value: ScrollMetrics(height: inner.size.height,
                                                                        minY: inner.frame(in: .named("tinted-scroll")).minY))
                        }
                    )
            }
            .coordinateSpace(name: "tinted-scroll")
            .scrollIndicators(.hidden)
            .onPreferenceChange(ScrollMetricsKey.self) { m in
                contentHeight = m.height
                offset = -m.minY
            }
            .overlay(alignment: .topTrailing) {
                if contentHeight > visible + 1 {
                    let ratio = visible / contentHeight
                    let thumb = max(24, visible * ratio)
                    let travel = visible - thumb
                    let progress = min(max(offset / (contentHeight - visible), 0), 1)
                    Capsule()
                        .fill(color.opacity(0.55))
                        .frame(width: 3, height: thumb)
                        .offset(x: -2, y: travel * progress)
                        .animation(nil, value: progress)
                }
            }
        }
    }
}
