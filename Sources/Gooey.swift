// Choir — made by Sam De Herdt for MakeWaves.
import SwiftUI

/// Liquid silhouettes, the way liquid-gooey does it on the web: blur the
/// blobs, then clamp alpha so the soft edge snaps back into a hard one —
/// neighbours bridge once the blur reaches across the gap. The silhouette is
/// drawn on its own layer; anything that must stay crisp sits on top of it.
struct GooeySilhouette: View {
    struct Blob { var center: CGPoint; var radius: CGFloat }
    var blobs: [Blob]
    var color: Color
    /// Reach of the merge. Pieces bridge roughly once blur ≳ the gap between them.
    var blur: CGFloat = 4

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            context.addFilter(.alphaThreshold(min: 0.5, color: color))
            context.addFilter(.blur(radius: blur))
            context.drawLayer { layer in
                for blob in blobs {
                    let rect = CGRect(x: blob.center.x - blob.radius, y: blob.center.y - blob.radius,
                                      width: blob.radius * 2, height: blob.radius * 2)
                    layer.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
    }
}

/// "Thinking": three drops sliding through each other. Under reduce-motion it
/// is three still dots — same footprint, no movement.
struct ThinkingDots: View {
    var color: Color = .secondary
    private let width: CGFloat = 26, height: CGFloat = 10

    var body: some View {
        if Motion.disabled {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 5, height: 5) }
            }
            .foregroundStyle(color.opacity(0.7))
            .frame(width: width, height: height)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                GooeySilhouette(blobs: blobs(at: t), color: color.opacity(0.75), blur: 2.2)
            }
            .frame(width: width, height: height)
            .accessibilityLabel("Thinking")
        }
    }

    /// Two outer drops swing toward the middle one and pass through it; the
    /// middle one breathes. Period 1.6 s — unhurried, like the CSS loaders.
    private func blobs(at t: TimeInterval) -> [GooeySilhouette.Blob] {
        let mid = CGPoint(x: width / 2, y: height / 2)
        let phase = (t.truncatingRemainder(dividingBy: 1.6)) / 1.6 * .pi * 2
        let swing = CGFloat(sin(phase)) * 8
        return [
            .init(center: CGPoint(x: mid.x - swing, y: mid.y), radius: 2.6),
            .init(center: mid, radius: 2.4 + CGFloat(cos(phase * 2)) * 0.5),
            .init(center: CGPoint(x: mid.x + swing, y: mid.y), radius: 2.6),
        ]
    }
}

/// A room's voices as one liquid cluster: the merged silhouette underneath,
/// each voice's coloured dot crisp on top. Reads as the app icon in miniature.
struct VoiceCluster: View {
    let keys: [String]
    var size: CGFloat = 18
    @State private var breathe = false

    private var shown: [String] { Array(keys.prefix(4)) }

    var body: some View {
        let step = size * 0.42
        let total = size + step * CGFloat(max(shown.count - 1, 0))
        ZStack {
            GooeySilhouette(
                blobs: shown.indices.map { i in
                    .init(center: CGPoint(x: size / 2 + step * CGFloat(i), y: size / 2 + (breathe ? sway(i) : 0)),
                          radius: size * 0.52)
                },
                color: Color(nsColor: .textBackgroundColor).opacity(0.9),
                blur: size * 0.22
            )
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            HStack(spacing: step - size * 0.62) {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, key in
                    Circle()
                        .fill(Palette.voice(key))
                        .frame(width: size * 0.62, height: size * 0.62)
                        .offset(y: breathe ? sway(i) : 0)
                }
            }
        }
        .frame(width: total, height: size + 4)
        .onAppear {
            guard !Motion.disabled else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathe = true }
        }
    }

    /// Alternate voices drift up and down by a pixel or two, so the cluster
    /// feels alive without ever looking busy.
    private func sway(_ i: Int) -> CGFloat { i.isMultiple(of: 2) ? -1.2 : 1.2 }
}


/// The working mark: a burst whose rays breathe between a star and a soft
/// flower while it turns — the shape Claude uses while it thinks, drawn here
/// in the voice's colour.
struct BurstSpinner: View {
    var color: Color
    var size: CGFloat = 16

    var body: some View {
        if Motion.disabled {
            Image(systemName: "asterisk").font(.system(size: size * 0.8, weight: .semibold)).foregroundStyle(color)
                .frame(width: size, height: size)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Burst(morph: (sin(t * 1.7) + 1) / 2)
                    .fill(color)
                    .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 12) / 12 * 360))
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }

    /// morph 0 → thin eight-ray star, 1 → plump eight-petal flower.
    struct Burst: Shape {
        var morph: Double
        var animatableData: Double { get { morph } set { morph = newValue } }

        func path(in rect: CGRect) -> Path {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let outer = min(rect.width, rect.height) / 2
            let inner = outer * (0.28 + 0.34 * morph)
            let rays = 8
            var p = Path()
            for i in 0..<(rays * 2) {
                let a = Double(i) / Double(rays * 2) * .pi * 2 - .pi / 2
                let r = i.isMultiple(of: 2) ? outer : inner
                let pt = CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r)
                if i == 0 { p.move(to: pt) } else {
                    // Flower: round the valleys with a curve toward the next tip.
                    let prev = Double(i - 1) / Double(rays * 2) * .pi * 2 - .pi / 2
                    let pr = (i - 1).isMultiple(of: 2) ? outer : inner
                    let control = CGPoint(x: c.x + CGFloat(cos((a + prev) / 2)) * ((r + pr) / 2) * CGFloat(1 + 0.35 * morph),
                                          y: c.y + CGFloat(sin((a + prev) / 2)) * ((r + pr) / 2) * CGFloat(1 + 0.35 * morph))
                    p.addQuadCurve(to: pt, control: control)
                }
            }
            p.closeSubpath()
            return p
        }
    }
}

/// The word next to the burst. Rotates every few seconds; each a small,
/// truthful verb for waiting — never a fake step the model is not doing.
struct WorkingWord: View {
    var backendStatus: String?
    @State private var index = Int.random(in: 0..<WorkingWord.words.count)

    static let words = [
        "Thinking", "Pondering", "Mulling", "Weighing", "Composing", "Considering",
        "Drafting", "Reflecting", "Sifting", "Untangling", "Chewing on it", "Lining it up",
        "Turning it over", "Musing", "Working", "Reasoning", "Brewing", "Piecing it together",
    ]

    var body: some View {
        Text(backendStatus ?? "\(WorkingWord.words[index])…")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .contentTransition(.opacity)
            .id(index)
            .transition(.opacity)
            .task {
                guard backendStatus == nil, !Motion.disabled else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_600_000_000)
                    withAnimation(Motion.smoothOut(Motion.fast)) { index = (index + Int.random(in: 1..<WorkingWord.words.count)) % WorkingWord.words.count }
                }
            }
    }
}

/// Send / stop / queue in one round button. Busy = a soft ring pulsing around
/// a stop square; queue = the arrow with a small "+".
struct SendButton: View {
    enum Mode { case send, stop, queue }
    let mode: Mode
    let enabled: Bool
    let action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(mode == .stop ? Color.secondary.opacity(0.18) : Color.accentColor.opacity(enabled ? 1 : 0.35))
                    .frame(width: 30, height: 30)
                if mode == .stop {
                    Circle().strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5)
                        .frame(width: pulse ? 38 : 30, height: pulse ? 38 : 30)
                        .opacity(pulse ? 0 : 0.9)
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Color.primary.opacity(0.75)).frame(width: 10, height: 10)
                } else {
                    Image(systemName: mode == .queue ? "text.badge.plus" : "arrow.up")
                        .font(.system(size: mode == .queue ? 12 : 13, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled && mode == .send)
        .onAppear { startPulse() }
        .onChange(of: mode) { _, _ in startPulse() }
        .motion(Motion.smoothOut(Motion.fast), value: mode)
        .help(mode == .stop ? "Stop (Esc)" : mode == .queue ? "Queue — sent as soon as the current answer finishes" : "Send (Return)")
    }

    private func startPulse() {
        pulse = false
        guard mode == .stop, !Motion.disabled else { return }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
    }
}
