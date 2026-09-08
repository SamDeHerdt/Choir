// Choir — made by Sam De Herdt for MakeWaves.
import SwiftUI
import AppKit

/// Home: what is connected, where to start, and the tour. Reached from the
/// brand block in the sidebar and shown on first launch.
struct HomeView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var usage: UsageMonitor
    @Binding var route: Route?
    @Binding var showTour: Bool
    @Binding var setupShown: Bool
    @State private var refreshing = false
    @State private var found: Int?

    private var claudeOK: Bool { CLI.isInstalled("claude", override: store.settings.connection(for: .claudeCLI).executablePath) }
    private var codexOK: Bool { CLI.isInstalled("codex", override: store.settings.connection(for: .codexCLI).executablePath) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(greeting).font(.system(size: 26, weight: .semibold))
                    Text("Every model you already pay for, in one thread — with the same projects, library and history behind all of them.")
                        .font(.system(size: 13.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if setupShown {
                    SetupView(isShown: $setupShown)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    quick("New chat", "square.and.pencil") { route = .conversation(store.newConversation().id) }
                    quick("New room", "person.3.fill") { route = .conversation(store.newConversation(room: true).id) }
                    quick("New project", "folder.badge.plus") { route = .project(store.newProject().id) }
                    if !(claudeOK && codexOK) {
                        quick("Set up connections", "link") { withAnimation(Motion.on(Motion.smoothOut(Motion.fast))) { setupShown = true } }
                    }
                    quick("Show me around", "sparkles") { showTour = true }
                }

                // Setup is three yes/no lines. Anything missing gets the one
                // action that fixes it; nothing asks for a key.
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(usage.available ? "Accounts" : "Setup").font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        Button {
                            refreshing = true
                            Task { found = await ModelDiscovery.refresh(store: store); refreshing = false }
                        } label: {
                            Label(refreshing ? "Looking…" : "Find models", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 11, weight: .medium))
                        }
                        .plainGlassButton().controlSize(.small).disabled(refreshing)
                        if let found { Text(found == 0 ? "nothing new" : "+\(found)").font(.system(size: 10.5)).foregroundStyle(.tertiary) }
                    }
                    if usage.available, !usage.accounts.isEmpty {
                        // Live meters from AI Profiles: what each subscription has left, per account.
                        ForEach([Backend.claudeCLI, .codexCLI], id: \.self) { backend in
                            let list = usage.accounts(for: backend)
                            if !list.isEmpty {
                                HStack(alignment: .top, spacing: 12) {
                                    HStack(spacing: 8) {
                                        Image(systemName: (backend == .claudeCLI ? claudeOK : codexOK) ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .font(.system(size: 12)).foregroundStyle((backend == .claudeCLI ? claudeOK : codexOK) ? .green : .orange)
                                        Text(backend == .claudeCLI ? "Claude" : "ChatGPT").font(.system(size: 12.5, weight: .medium))
                                    }
                                    .frame(width: 96, alignment: .leading).onAppear { usage.refresh() }
            .padding(.top, 1)
                                    HStack(alignment: .top, spacing: 16) {
                                        ForEach(list) { account in UsageMeter(account: account, compact: true).frame(width: 200) }
                                    }
                                    Spacer()
                                }
                            }
                        }
                    } else {
                        connection("Claude", "your Claude subscription, through Claude Code", ok: claudeOK,
                                   fix: "Install Claude Code and sign in once — Choir finds it by itself.", url: "https://claude.com/claude-code", button: "Get Claude Code")
                        connection("ChatGPT", "your ChatGPT subscription, through Codex", ok: codexOK,
                                   fix: "Install Codex and sign in once — Choir finds it by itself.", url: "https://github.com/openai/codex", button: "Get Codex")
                    }
                    connection("Local models", "Ollama on this Mac — free, offline",
                               ok: store.enabledModels.contains { $0.backend == .ollama },
                               fix: "Install Ollama, pull a model, then press Find models.", url: "https://ollama.com", button: "Get Ollama")
                    HStack(spacing: 8) {
                        Text("\(store.enabledModels.count) models ready · nothing here spends credits.")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                        Spacer()
                        Button("All connections…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                }

                let recent = Array(store.conversations.prefix(6))
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent").font(.system(size: 12.5, weight: .semibold)).padding(.bottom, 4)
                        ForEach(recent) { c in
                            Button { route = .conversation(c.id) } label: {
                                HStack(spacing: 10) {
                                    if c.isRoom { Image(systemName: "person.3.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                                    else { VoiceDot(key: c.modelKey, size: 7) }
                                    Text(c.title).font(.system(size: 13)).lineLimit(1)
                                    Spacer()
                                    Text(c.updatedAt.formatted(.relative(presentation: .named))).font(.system(size: 11)).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(
            RadialGradient(colors: [Palette.accent(0).opacity(0.09), .clear], center: .topLeading, startRadius: 0, endRadius: 900)
                .ignoresSafeArea()
        )
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning."
        case 12..<18: return "Good afternoon."
        default: return "Good evening."
        }
    }

    private func quick(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 12.5, weight: .medium))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassPanel(14, interactive: true)
    }

    private func connection(_ name: String, _ detail: String, ok: Bool, fix: String, url: String, button: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 14))
                .foregroundStyle(ok ? Color.green : Color.secondary.opacity(0.5))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 12.5, weight: .medium))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                if !ok { Text(fix).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer()
            if !ok, let link = URL(string: url) {
                Button(button) { NSWorkspace.shared.open(link) }
                    .plainGlassButton().controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The tour: six short pages. Shown once on first launch, and from Help.
struct TourView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Page { let symbol: String; let title: String; let body: String }
    private var pages: [Page] {
        [
            Page(symbol: "waveform", title: "Welcome to Choir",
                 body: "One window for every model you already pay for. Claude and ChatGPT run through their own signed-in command-line tools, so nothing here buys credits. Local models run through Ollama."),
            Page(symbol: "arrow.left.arrow.right", title: "One thread, any model",
                 body: "Pick the model under the composer — per message. Switch mid-conversation and the whole history, the project's files and the library go with you. ⌘⇧1…9 jumps between models."),
            Page(symbol: "person.3.fill", title: "Rooms",
                 body: "Ask several models at once. They answer as participants in one group chat. Mark the answer you prefer and from then on every model builds on it. Compare side by side when you want to."),
            Page(symbol: "folder.fill", title: "Projects",
                 body: "Instructions, knowledge files and library items in one container. Every chat inside a project — whatever model answers — gets all of it. Drop PDFs, docs or code onto the project page."),
            Page(symbol: "books.vertical.fill", title: "Library",
                 body: "Prompts, skills and knowhow written once. Your existing Claude Code and Codex skills import in one click, and Choir's skills can be shared back as SKILL.md folders every agent reads."),
            Page(symbol: "arrow.triangle.branch", title: "MCP bridge",
                 body: "Claude Code and Codex can read this library, your history and your projects through MCP — and write knowhow or projects back. Settings › MCP bridge has the one-line setup."),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, p in
                    if index == page {
                        VStack(spacing: 14) {
                            TourScene(index: index)
                                .frame(height: 96)
                            Text(p.title).font(.system(size: 20, weight: .semibold))
                            Text(p.body)
                                .font(.system(size: 13.5)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 420)
                        }
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)),
                                                removal: .opacity.combined(with: .offset(x: -24))))
                    }
                }
            }
            .frame(height: 280)
            .padding(.horizontal, 32)
            .padding(.top, 24)

            HStack(spacing: 6) {
                ForEach(0..<pages.count, id: \.self) { i in
                    Circle().fill(i == page ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.25))
                        .frame(width: i == page ? 7 : 5, height: i == page ? 7 : 5)
                }
            }
            .padding(.top, 6)

            HStack {
                Button("Skip") { finish() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                if page > 0 {
                    Button("Back") { withAnimation(Motion.on(Motion.smoothOut(Motion.fast))) { page -= 1 } }.plainGlassButton()
                }
                Button(page == pages.count - 1 ? "Start" : "Next") {
                    if page == pages.count - 1 { finish() }
                    else { withAnimation(Motion.on(Motion.smoothOut(Motion.fast))) { page += 1 } }
                }
                .prominentGlassButton()
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520)
        .motion(Motion.smoothOut(Motion.fast), value: page)
    }

    private func finish() {
        store.settings.hasSeenTour = true
        store.scheduleSave()
        dismiss()
    }
}


/// One small animated scene per tour page. Each loops quietly; all of them
/// respect the reduce-motion switch by simply not animating.
struct TourScene: View {
    let index: Int
    @State private var on = false

    private let voices = [Palette.accent(0), Palette.accent(1), Palette.accent(2)]

    var body: some View {
        Group {
            switch index {
            case 0: welcome
            case 1: oneThread
            case 2: rooms
            case 3: projects
            case 4: library
            default: bridge
            }
        }
        .onAppear {
            on = false
            guard !Motion.disabled else { on = true; return }
            withAnimation(Motion.smoothOut(Motion.slow).delay(0.15)) { on = true }
        }
    }

    // 0 — the bubbles, breathing
    private var welcome: some View {
        ZStack {
            bubble(voices[2], w: 74, h: 54).offset(x: -34, y: -14).scaleEffect(on ? 1.04 : 0.98)
                .animation(loop(2.6), value: on)
            bubble(voices[1], w: 70, h: 52).offset(x: 34, y: -10).scaleEffect(on ? 0.98 : 1.04)
                .animation(loop(2.2), value: on)
            bubble(voices[0], w: 78, h: 56).offset(x: -26, y: 22).scaleEffect(on ? 1.03 : 0.99)
                .animation(loop(3.0), value: on)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .frame(width: 92, height: 60)
                .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
                .overlay(ThinkingDots().scaleEffect(1.6))
                .offset(y: 6)
        }
        .opacity(on ? 1 : 0)
    }

    private func bubble(_ color: Color, w: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(color.opacity(0.75)).frame(width: w, height: h)
    }

    // 1 — one thread, the ring hops between models
    private var oneThread: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.8))
                .frame(width: 200, height: 30)
                .overlay(alignment: .leading) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.25)).frame(width: 110, height: 6)
                    }.padding(.leading, 12)
                }
            HStack(spacing: 26) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(voices[i]).frame(width: 18, height: 18)
                        .overlay(
                            Circle().strokeBorder(voices[i], lineWidth: 2)
                                .frame(width: 30, height: 30)
                                .opacity(ringIndex == i ? 1 : 0)
                                .scaleEffect(ringIndex == i ? 1 : 0.7)
                        )
                }
            }
            .animation(Motion.disabled ? nil : Motion.smoothOut(Motion.medium), value: ringIndex)
        }
        .opacity(on ? 1 : 0)
        .task {
            guard !Motion.disabled else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                ringIndex = (ringIndex + 1) % 3
            }
        }
    }
    @State private var ringIndex = 0

    // 2 — rooms: three participants slide in, one gets the star
    private var rooms: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 8) {
                    Circle().fill(voices[i].opacity(0.25)).frame(width: 18, height: 18)
                        .overlay(Circle().fill(voices[i]).frame(width: 7, height: 7))
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(voices[i].opacity(0.12))
                        .frame(width: i == 1 ? 150 : 120, height: 20)
                        .overlay(alignment: .trailing) {
                            if i == 1 {
                                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(voices[1])
                                    .padding(.trailing, 7)
                                    .scaleEffect(on ? 1 : 0.2).opacity(on ? 1 : 0)
                                    .animation(Motion.disabled ? nil : Motion.bounce(Motion.slow).delay(0.9), value: on)
                            }
                        }
                }
                .offset(x: on ? 0 : -30).opacity(on ? 1 : 0)
                .animation(Motion.disabled ? nil : Motion.smoothOut(Motion.slow).delay(Double(i) * 0.18 + 0.1), value: on)
            }
        }
    }

    // 3 — projects: files fly into the folder
    private var projects: some View {
        ZStack {
            Image(systemName: "folder.fill").font(.system(size: 54)).foregroundStyle(Palette.accent(3).opacity(0.85))
            ForEach(0..<3, id: \.self) { i in
                Image(systemName: ["doc.text.fill", "doc.richtext.fill", "doc.plaintext.fill"][i])
                    .font(.system(size: 18))
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    .offset(x: on ? CGFloat(i - 1) * 12 : CGFloat(i - 1) * 60, y: on ? -4 : -60)
                    .rotationEffect(.degrees(on ? Double(i - 1) * 6 : Double(i - 1) * 25))
                    .opacity(on ? 1 : 0)
                    .animation(Motion.disabled ? nil : Motion.smoothOut(Motion.slow).delay(Double(i) * 0.14 + 0.1), value: on)
            }
        }
    }

    // 4 — library: three cards fan out
    private var library: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let symbol = [LibraryItem.Kind.prompt, .skill, .knowhow][i].symbol
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .frame(width: 56, height: 72)
                    .shadow(color: .black.opacity(0.10), radius: 8, y: 4)
                    .overlay(Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Palette.accent(i + 3)))
                    .rotationEffect(.degrees(on ? Double(i - 1) * 14 : 0), anchor: .bottom)
                    .offset(x: on ? CGFloat(i - 1) * 40 : 0, y: on ? abs(CGFloat(i - 1)) * 6 : 0)
                    .animation(Motion.disabled ? nil : Motion.smoothOut(Motion.slow).delay(0.15), value: on)
            }
        }
        .opacity(on ? 1 : 0)
    }

    // 5 — bridge: the link between Choir and the terminals pulses
    private var bridge: some View {
        HStack(spacing: 14) {
            node("waveform", Palette.accent(0))
            ZStack {
                Capsule().fill(Color.secondary.opacity(0.2)).frame(width: 90, height: 3)
                Circle().fill(Palette.accent(0)).frame(width: 8, height: 8)
                    .offset(x: on ? 42 : -42)
                    .animation(Motion.disabled ? nil : .easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: on)
            }
            node("bubble.left.and.bubble.right.fill", Palette.accent(1))
        }
        .opacity(on ? 1 : 0)
    }

    private func node(_ symbol: String, _ color: Color) -> some View {
        Circle().fill(color.opacity(0.16)).frame(width: 46, height: 46)
            .overlay(Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(color))
    }

    private func loop(_ seconds: Double) -> Animation? {
        Motion.disabled ? nil : .easeInOut(duration: seconds).repeatForever(autoreverses: true)
    }
}
