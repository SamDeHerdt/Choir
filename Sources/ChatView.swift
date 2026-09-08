// Choir — made by Sam De Herdt for MakeWaves.
import SwiftUI
import AppKit

/// A user turn and every answer it drew. In a chat that is one answer; in a
/// room it is one per model, which is why the thread is grouped rather than flat.
struct Round: Identifiable {
    var id: UUID { prompt?.id ?? answers.first?.id ?? UUID() }
    var prompt: Message?
    var answers: [Message]
}

extension Conversation {
    var rounds: [Round] {
        var out: [Round] = []
        var current = Round(prompt: nil, answers: [])
        for m in messages {
            if m.role == .user {
                if current.prompt != nil || !current.answers.isEmpty { out.append(current) }
                current = Round(prompt: m, answers: [])
            } else if m.role == .assistant {
                current.answers.append(m)
            }
        }
        if current.prompt != nil || !current.answers.isEmpty { out.append(current) }
        return out
    }
}

struct ChatView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var conductor: Conductor
    let conversationID: UUID

    @State private var draft = ""
    @State private var showLibrarySheet = false
    @State private var atBottom = true
    @FocusState private var composerFocused: Bool

    /// Changes as any streaming answer grows — not only the last message,
    /// because in a room three of them grow at once.
    private func streamingFingerprint(_ c: Conversation) -> Int {
        c.messages.suffix(6).reduce(0) { $0 &+ $1.text.count &+ $1.reasoning.count }
    }

    private var conversation: Conversation? {
        store.conversations.first { $0.id == conversationID }
    }

    var body: some View {
        if let conversation {
            VStack(spacing: 0) {
                ThreadHeader(conversation: conversation)
                Divider().opacity(0.4)
                transcript(conversation)
                Composer(
                    conversationID: conversationID,
                    draft: $draft,
                    showLibrarySheet: $showLibrarySheet,
                    focused: $composerFocused
                )
            }
            .background(BackdropWash(conversation: conversation))
            .sheet(isPresented: $showLibrarySheet) {
                LibraryPicker(conversationID: conversationID)
                    .environmentObject(store)
            }
            .onAppear { composerFocused = true }
        } else {
            EmptyThreadState()
        }
    }

    private func transcript(_ conversation: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if conversation.messages.isEmpty {
                        StarterState(conversationID: conversationID, draft: $draft)
                            .padding(.top, 40)
                    }
                    ForEach(conversation.rounds) { round in
                        RoundView(round: round, conversation: conversation)
                            .id(round.id)
                    }
                    ForEach(conductor.queued(for: conversationID)) { pending in
                        QueuedBubble(pending: pending, conversationID: conversationID)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                    // Scroll anchor: keeps the newest text in view while streaming.
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: conversation.isRoom ? 1100 : 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            // Streaming: follow only if the reader is already at the bottom, and
            // without animation — an animated scroll on every token is the
            // "screen moves on its own" feeling.
            .onChange(of: streamingFingerprint(conversation)) { _, _ in
                guard atBottom else { return }
                var tx = Transaction(); tx.disablesAnimations = true
                withTransaction(tx) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: conversation.messages.count) { _, _ in
                withAnimation(Motion.on(Motion.smoothOut(Motion.fast))) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: conductor.queued(for: conversationID).count) { _, _ in
                withAnimation(Motion.on(Motion.smoothOut(Motion.fast))) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

// MARK: - Backdrop

/// A soft wash in the project's colour. Glass needs something behind it or it
/// reads as flat grey.
struct BackdropWash: View {
    let conversation: Conversation
    @EnvironmentObject var store: Store

    var body: some View {
        let accent = store.color(of: conversation)
        // A hint of the colour, not a wash: strongest in one corner, gone by the middle.
        RadialGradient(colors: [accent.opacity(0.09), .clear], center: .topLeading, startRadius: 0, endRadius: 900)
            .ignoresSafeArea()
            .motion(Motion.smoothOut(Motion.slow), value: conversation.colorHex)
    }
}

// MARK: - Header

struct ThreadHeader: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var conductor: Conductor
    @EnvironmentObject var usage: UsageMonitor
    let conversation: Conversation
    @State private var renaming = false
    @State private var title = ""

    var body: some View {
        HStack(spacing: 10) {
            if conversation.isRoom {
                VoiceCluster(keys: conversation.roomModelKeys, size: 16)
            }
            if let project = store.project(conversation.projectID) {
                Chip(text: project.name, symbol: "folder.fill", color: store.color(of: project))
            }
            if renaming {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .onSubmit { commit() }
                    .frame(maxWidth: 320)
            } else {
                Text(conversation.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .onTapGesture(count: 2) { title = conversation.title; renaming = true }
            }

            if conversation.isRoom {
                Chip(text: conversation.roomMode.label, symbol: "person.3.fill", color: .secondary)
            }

            Spacer()

            ColorSwatch(color: store.color(of: conversation), isCustom: conversation.colorHex != nil) { hex in
                guard let i = store.index(of: conversation.id) else { return }
                withAnimation(Motion.on(Motion.smoothOut(Motion.fast))) {
                    store.conversations[i].colorHex = hex
                    if hex == nil { store.conversations[i].accent = nil }
                }
                store.scheduleSave()
            }

            Menu {
                Button("Rename") { title = conversation.title; renaming = true }
                Button(conversation.pinned ? "Unpin" : "Pin") {
                    guard let i = store.index(of: conversation.id) else { return }
                    store.conversations[i].pinned.toggle(); store.touch(conversation.id)
                }
                Menu("Move to project") {
                    Button("None") { move(nil) }
                    ForEach(store.projects) { project in Button(project.name) { move(project.id) } }
                }
                Divider()
                Button("Copy as Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.markdown(for: conversation), forType: .string)
                }
                Button("Save as Markdown…") { saveMarkdown(conversation) }
                Divider()
                Button("Delete conversation", role: .destructive) { store.delete(conversation.id) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

            // What the current subscription has left, from AI Profiles.
            if !conversation.isRoom, let backend = store.backend(forKey: conversation.modelKey),
               let account = usage.active(for: backend) {
                let left = account.left
                Chip(text: left.map { "\(account.profile) · \($0)% left" } ?? "\(account.profile) · no meter",
                     symbol: "gauge.with.dots.needle.33percent",
                     color: (left ?? 100) == 0 ? .orange : .secondary)
                    .help(account.resetLine.map { "\(account.plan) · \($0)" } ?? account.plan)
            }

            if conductor.isRunning(conversation.id) {
                Button {
                    conductor.stop(conversation.id)
                } label: {
                    Label("Stop", systemImage: "stop.fill").font(.system(size: 11, weight: .medium))
                }
                .plainGlassButton()
                .transition(.scale.combined(with: .opacity))
            } else if conversation.messages.contains(where: { $0.role == .assistant }) {
                Button {
                    conductor.regenerate(conversationID: conversation.id, store: store)
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).frame(width: 18, height: 18)
                }
                .plainGlassButton()
                .help("Ask again — drops the last answer. Useful right after switching model.")
            }
        }
        .motion(Motion.smoothOut(Motion.fast), value: conductor.isRunning(conversation.id))
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func commit() {
        guard let i = store.index(of: conversation.id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { store.conversations[i].title = trimmed }
        renaming = false
        store.scheduleSave()
    }

    private func move(_ projectID: UUID?) {
        guard let i = store.index(of: conversation.id) else { return }
        store.conversations[i].projectID = projectID
        store.scheduleSave()
    }

    private func saveMarkdown(_ conversation: Conversation) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Store.slug(conversation.title) + ".md"
        panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? store.markdown(for: conversation).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Rounds and messages

struct RoundView: View {
    @EnvironmentObject var store: Store
    let round: Round
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let prompt = round.prompt {
                UserBubble(message: prompt, conversationID: conversation.id)
            }
            if conversation.isRoom && round.answers.count > 1 {
                RoomStage(round: round, conversation: conversation)
            } else {
                ForEach(round.answers) { answer in
                    AssistantBlock(message: answer)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)),
                            removal: .opacity))
                }
            }
        }
    }
}

struct UserBubble: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var conductor: Conductor
    let message: Message
    var conversationID: UUID? = nil
    @State private var hovering = false
    @State private var confirmingDelete = false
    @State private var editing = false
    @State private var editText = ""
    @FocusState private var editFocused: Bool

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: editing ? 40 : 60)
            VStack(alignment: .trailing, spacing: 4) {
                if editing {
                    editor
                } else {
                Text(message.text)
                    .font(.system(size: 13.5))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassPanel(16)
                    .contextMenu {
                        if let conversationID {
                            Button("Edit") { beginEdit() }
                            Button("Rewind to here") { store.rewind(to: message.id, in: conversationID) }
                            Button("Fork from here") { store.forkThread(at: message.id, in: conversationID) }
                            Divider()
                            Button("Delete this round", role: .destructive) { store.deleteRound(of: message.id, in: conversationID) }
                        }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        }
                    }
                }
                if let files = message.attachments, !files.isEmpty, !editing {
                    HStack(spacing: 5) {
                        ForEach(files) { file in
                            Chip(text: file.name, symbol: "doc.text")
                        }
                    }
                }
                // One reserved line under the bubble: what was attached, and —
                // on hover — the round's actions rising in one after another.
                if !editing {
                    HStack(spacing: 8) {
                        if !message.appliedLibrary.isEmpty {
                            Text(message.appliedLibrary.joined(separator: " · "))
                                .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        if let conversationID {
                            actionRow(conversationID)
                        }
                    }
                    .frame(height: 22)
                }
            }
            .frame(maxWidth: editing ? 720 : nil)
        }
        .onHover { over in
            hovering = over
            if !over { confirmingDelete = false }
        }
        .motion(Motion.smoothOut(Motion.fast), value: editing)
    }

    // MARK: Editing in place

    /// The bubble itself becomes the editor — same place, same width — with
    /// Cancel and Send underneath, the way ChatGPT and Claude do it. Send drops
    /// this message and everything after it, then sends the new text.
    private var editor: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $editText)
                .font(.system(size: 13.5))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 40, maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
                .focused($editFocused)
                .onKeyPress(.return, phases: .down) { press in
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    commitEdit(); return .handled
                }
                .onKeyPress(.escape) { cancelEdit(); return .handled }
            HStack(spacing: 8) {
                Button("Cancel") { cancelEdit() }
                    .plainGlassButton()
                    .keyboardShortcut(.cancelAction)
                Button {
                    commitEdit()
                } label: {
                    Label("Send", systemImage: "arrow.up").font(.system(size: 12, weight: .semibold))
                }
                .prominentGlassButton()
                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 360, maxWidth: 720, alignment: .trailing)
        .glassPanel(16)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1))
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .onAppear { editFocused = true }
    }

    private func beginEdit() {
        guard let conversationID, !conductor.isRunning(conversationID) else { return }
        editText = message.text
        withAnimation(Motion.on(Motion.smoothOut(Motion.fast))) { editing = true }
    }

    private func cancelEdit() {
        withAnimation(Motion.on(Motion.smoothOut(Motion.quick))) { editing = false }
    }

    private func commitEdit() {
        guard let conversationID else { return }
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        withAnimation(Motion.on(Motion.smoothOut(Motion.medium))) {
            editing = false
            store.truncate(from: message.id, in: conversationID)
        }
        conductor.send(text, conversationID: conversationID, store: store)
    }

    private struct RoundAction: Identifiable {
        let id: String
        let symbol: String
        let help: String
        let destructive: Bool
        let run: () -> Void
    }

    private func actions(_ conversationID: UUID) -> [RoundAction] {
        [
            RoundAction(id: "edit", symbol: "pencil", help: "Edit this message — sending it again replaces everything after it", destructive: false) {
                beginEdit()
            },
            RoundAction(id: "retry", symbol: "arrow.clockwise", help: "Retry all — ask this again with every voice; everything after it is replaced", destructive: false) {
                conductor.regenerate(fromPrompt: message.id, conversationID: conversationID, store: store)
            },
            RoundAction(id: "rewind", symbol: "arrow.uturn.backward", help: "Rewind to here — keep this round, drop everything after it", destructive: false) {
                withAnimation(Motion.on(Motion.smoothOut(Motion.medium))) { store.rewind(to: message.id, in: conversationID) }
            },
            RoundAction(id: "fork", symbol: "arrow.triangle.branch", help: "Fork from here — a new thread that ends at this round", destructive: false) {
                store.forkThread(at: message.id, in: conversationID)
            },
            RoundAction(id: "delete", symbol: confirmingDelete ? "trash.fill" : "trash",
                        help: confirmingDelete ? "Click again to delete this round" : "Delete this round", destructive: true) {
                if confirmingDelete {
                    withAnimation(Motion.on(Motion.smoothOut(Motion.medium))) { store.deleteRound(of: message.id, in: conversationID) }
                } else {
                    withAnimation(Motion.on(Motion.bounce(Motion.fast))) { confirmingDelete = true }
                }
            },
        ]
    }

    /// Hover reveal from the motion scale: in at `fast` with a 40 ms stagger,
    /// out at `quick` all at once. Opacity and a 4 pt rise only — no layout.
    private func actionRow(_ conversationID: UUID) -> some View {
        let visible = hovering && !conductor.isRunning(conversationID)
        let list = actions(conversationID)
        return HStack(spacing: 2) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, action in
                Button(action: action.run) {
                    Image(systemName: action.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(action.destructive && confirmingDelete ? Color.red : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(action.destructive && confirmingDelete ? Color.red.opacity(0.12) : Color.clear)
                )
                .help(action.help)
                .opacity(visible ? 1 : 0)
                .offset(y: visible ? 0 : 4)
                .allowsHitTesting(visible)
                .animation(
                    Motion.disabled ? nil : (visible
                        ? Motion.smoothOut(Motion.fast).delay(Double(index) * Motion.stagger)
                        : Motion.smoothOut(Motion.quick)),
                    value: visible)
            }
        }
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(visible ? 0.6 : 0))
                .animation(Motion.disabled ? nil : Motion.smoothOut(visible ? Motion.fast : Motion.quick), value: visible)
        )
    }
}

struct AssistantBlock: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var conductor: Conductor
    @EnvironmentObject var usage: UsageMonitor
    let message: Message
    var showHeader = true
    @State private var showReasoning = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showHeader { header }
            bodyContent
        }
        .motion(Motion.smoothOut(Motion.quick), value: message.text.isEmpty)
    }

    private var header: some View {
            HStack(spacing: 7) {
                VoiceDot(key: message.modelKey ?? "")
                Text(message.modelLabel ?? "Assistant")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if message.isStreaming && !message.text.isEmpty { ThinkingDots() }
                Spacer()
                if !message.text.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                        withAnimation(Motion.on(Motion.bounce(Motion.fast))) { copied = true }
                        Task { try? await Task.sleep(nanoseconds: 1_400_000_000)
                               withAnimation(Motion.on(Motion.smoothOut(Motion.quick))) { copied = false } }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? Color.green : Color.secondary.opacity(0.7))
                }
            }
    }

    @ViewBuilder
    private var bodyContent: some View {
            if message.isStreaming && message.text.isEmpty && message.error == nil {
                // Working: the burst and a word, in the voice's colour.
                HStack(spacing: 8) {
                    BurstSpinner(color: Palette.voice(message.modelKey ?? ""), size: 15)
                    WorkingWord(backendStatus: conductor.status[message.id])
                }
                .padding(.vertical, 2)
                .transition(.opacity)
            }

            if store.settings.showReasoning, !message.reasoning.isEmpty || message.finishedAt != nil {
                WorkLine(message: message, expanded: $showReasoning)
            }

            if let error = message.error {
                HStack(alignment: .top, spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let id = store.conversations.first(where: { $0.messages.contains { $0.id == message.id } })?.id,
                       !conductor.isRunning(id) {
                        if error.localizedCaseInsensitiveContains("usage limit"),
                           let backend = message.modelKey.flatMap({ store.backend(forKey: $0) }),
                           let other = usage.accounts(for: backend).first(where: { !$0.running && !$0.exhausted }) {
                            Button("Use \(other.profile) account") {
                                Task {
                                    let note = await usage.switchAccount(provider: other.provider, profile: other.profile)
                                    store.banner = note
                                    usage.refresh(force: true)
                                    conductor.regenerate(conversationID: id, store: store)
                                }
                            }
                            .prominentGlassButton().controlSize(.small)
                            .help("\(other.email) — \(other.left.map { "\($0)% left" } ?? "meter unknown"). Switches the live ChatGPT/Claude slot through AI Profiles.")
                        }
                        Button("Retry") { conductor.regenerate(conversationID: id, store: store) }
                            .plainGlassButton().controlSize(.small)
                        Button("Report") { NotificationCenter.default.post(name: .choirReportProblem, object: String(error.prefix(80))) }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .help("File this as a bug, with a screenshot")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if !message.text.isEmpty {
                MarkdownText(source: message.text)
                    .font(.system(size: 13.5))
            }
    }
}

/// The line Claude puts under its work — "Thought for 4 s · answered in 12 s" —
/// opening into the reasoning when the model exposed any. Only facts we have:
/// timings from this run and the model's own thinking text. Nothing invented.
struct WorkLine: View {
    let message: Message
    @Binding var expanded: Bool

    private var summary: String {
        var parts: [String] = []
        if let start = message.startedAt {
            let thought = (message.firstTokenAt ?? message.finishedAt ?? Date()).timeIntervalSince(start)
            if !message.reasoning.isEmpty || thought >= 2 { parts.append("Thought for \(seconds(thought))") }
            if let end = message.finishedAt { parts.append("answered in \(seconds(end.timeIntervalSince(start)))") }
        }
        if message.isStreaming && parts.isEmpty { return "Reasoning" }
        return parts.isEmpty ? "Reasoning" : parts.joined(separator: " · ").prefix(1).uppercased() + parts.joined(separator: " · ").dropFirst()
    }

    private func seconds(_ t: TimeInterval) -> String {
        t < 60 ? "\(max(1, Int(t.rounded()))) s" : "\(Int(t / 60)) min \(Int(t.truncatingRemainder(dividingBy: 60))) s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.on(Motion.smoothOut(expanded ? Motion.quick : Motion.fast))) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(summary).font(.system(size: 10.5, weight: .medium))
                    if !message.reasoning.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(message.reasoning.isEmpty)

            if expanded, !message.reasoning.isEmpty {
                Text(message.reasoning)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().frame(width: 2).foregroundStyle(.secondary.opacity(0.25))
                    }
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
    }
}

/// A message waiting its turn. Cancel drops it before it is ever sent.
struct QueuedBubble: View {
    @EnvironmentObject var conductor: Conductor
    let pending: Conductor.QueuedMessage
    let conversationID: UUID

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                Text(pending.text.isEmpty ? "(attachments only)" : pending.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            .foregroundStyle(.secondary.opacity(0.5))
                    )
                HStack(spacing: 8) {
                    Label("Queued — sends when the current answer finishes", systemImage: "clock")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Button("Cancel") {
                        withAnimation(Motion.on(Motion.smoothOut(Motion.quick))) { conductor.dequeue(pending.id, conversationID: conversationID) }
                    }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct RoomStage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var conductor: Conductor
    let round: Round
    let conversation: Conversation

    /// Side by side while the voices are writing (nothing pushes anything);
    /// the user can stack them into a chat afterwards, or the other way round.
    @State private var comparing: Bool?
    @State private var sawStreaming = false
    private var anyStreaming: Bool { voices.contains { $0.isStreaming } }
    private var sideBySide: Bool { comparing ?? (anyStreaming || sawStreaming) }
    @State private var width: CGFloat = 0
    @Namespace private var slots

    private var voices: [Message] { round.answers.filter { !($0.modelLabel ?? "").hasPrefix("Synthesis") } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if sideBySide && width >= 700 && voices.count > 1 {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(voices) { answer in
                        participant(answer, compact: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .matchedGeometryEffect(id: answer.id, in: slots)
                    }
                }
                .onAppear { if anyStreaming { sawStreaming = true } }
                .onChange(of: anyStreaming) { _, now in if now { sawStreaming = true } }
            } else {
                // A group chat: one participant after another, each bubble
                // hugging its own text, staggered like people talking.
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(voices) { answer in
                        participant(answer, compact: false)
                            .matchedGeometryEffect(id: answer.id, in: slots)
                    }
                }
            }
            systemLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .readWidth($width)
        .motion(Motion.smoothOut(Motion.medium), value: sideBySide)
        .motion(Motion.smoothOut(Motion.fast), value: round.answers.count)
    }

    // MARK: A participant's turn

    private func participant(_ answer: Message, compact: Bool) -> some View {
        ParticipantTurn(answer: answer, compact: compact, round: round, conversation: conversation, columnWidth: width)
    }

    // MARK: System line

    /// Between rounds, like a system message in a group chat: where the voices
    /// landed, and the switch to lay them side by side.
    /// Under the round: the switch between chat and side by side. Nothing else.
    @ViewBuilder
    private var systemLine: some View {
        if voices.count > 1, width >= 700 {
            HStack {
                Spacer(minLength: 0)
                Button {
                    withAnimation(Motion.on(Motion.smoothOut(Motion.medium))) { comparing = !sideBySide }
                } label: {
                    Label(sideBySide ? "Stack as chat" : "Side by side",
                          systemImage: sideBySide ? "rectangle.stack" : "rectangle.split.3x1")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .plainGlassButton()
                .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
    }

    private func shortName(_ answer: Message) -> String {
        (answer.modelLabel ?? "Model")
            .replacingOccurrences(of: " (ChatGPT)", with: "")
            .replacingOccurrences(of: " (local)", with: "")
            .replacingOccurrences(of: " (latest)", with: "")
            .replacingOccurrences(of: " (Codex default)", with: "")
    }
}

// MARK: - Empty states

struct EmptyThreadState: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No conversation selected")
                .font(.system(size: 15, weight: .medium))
            Button("New chat") { store.newConversation() }
                .prominentGlassButton()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What the user sees in a brand-new thread: what is loaded, and three ways in.
struct StarterState: View {
    @EnvironmentObject var store: Store
    let conversationID: UUID
    @Binding var draft: String

    private let openers = [
        "Answer this, then tell me what you would have asked me first.",
        "Compare the options and pick one. Justify the pick in three lines.",
        "Read the project files and tell me what is missing.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("One thread, any model.")
                    .font(.system(size: 20, weight: .semibold))
                Text("Switch model mid-conversation and the history, project files and library come along.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            if let conversation = store.conversations.first(where: { $0.id == conversationID }) {
                let names = store.appliedNames(for: conversation)
                if !names.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("In force for this thread")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        FlowChips(names: names)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(openers, id: \.self) { opener in
                    Button {
                        withAnimation(Motion.on(Motion.smoothOut(Motion.fast))) { draft = opener }
                    } label: {
                        HStack {
                            Text(opener).font(.system(size: 12.5)).multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.left").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 13).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .glassPanel(12, interactive: true)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
    }
}

/// Chips that wrap. `LazyVGrid` would align them into columns; these read as prose.
struct FlowChips: View {
    let names: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(names.prefix(6), id: \.self) { name in
                Chip(text: name, symbol: "paperclip")
            }
            if names.count > 6 {
                Chip(text: "+\(names.count - 6)")
            }
        }
    }
}


/// One model's turn in a group chat: avatar, name line, bubble, and the
/// actions that rise in while the pointer is anywhere over the turn.
struct ParticipantTurn: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var conductor: Conductor
    @EnvironmentObject var usage: UsageMonitor
    let answer: Message
    let compact: Bool
    let round: Round
    let conversation: Conversation
    let columnWidth: CGFloat
    @State private var hovering = false
    @State private var reasoningOpen = false

    private var color: Color { Palette.voice(answer.modelKey ?? "") }
    private var name: String {
        (answer.modelLabel ?? "Model")
            .replacingOccurrences(of: " (ChatGPT)", with: "")
            .replacingOccurrences(of: " (local)", with: "")
            .replacingOccurrences(of: " (latest)", with: "")
            .replacingOccurrences(of: " (Codex default)", with: "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.18)).frame(width: 30, height: 30)
                Image(systemName: store.backend(forKey: answer.modelKey ?? "")?.symbol ?? "sparkle")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                if answer.isPreferred {
                    Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(color)
                        .padding(2).background(Color(nsColor: .textBackgroundColor), in: Circle())
                        .offset(x: 11, y: -11)
                }
            }
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 12, weight: .semibold))
                    Text(answer.modelKey.flatMap { store.settings.model(key: $0)?.backend.displayName } ?? "")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    if answer.isStreaming { ThinkingDots() }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 4)

                bubble

                ParticipantActions(answer: answer, color: color, conversation: conversation, prompt: round.prompt, revealed: hovering)
            }
            .frame(maxWidth: compact ? .infinity : min(max(columnWidth * 0.78, 320), 760), alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var bubble: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: 18, style: .continuous)
        return Group {
            if let error = answer.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if !conductor.isRunning(conversation.id) {
                        HStack(spacing: 6) {
                            Button("Retry \(name)") { conductor.retryVoice(answer.id, conversationID: conversation.id, store: store) }
                                .prominentGlassButton().controlSize(.small)
                            Button("Retry all") { conductor.regenerate(conversationID: conversation.id, store: store) }
                                .plainGlassButton().controlSize(.small)
                            Button("Report") { NotificationCenter.default.post(name: .choirReportProblem, object: String(error.prefix(80))) }
                                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            if error.localizedCaseInsensitiveContains("usage limit"),
                               let backend = answer.modelKey.flatMap({ store.backend(forKey: $0) }),
                               let other = usage.accounts(for: backend).first(where: { !$0.running && !$0.exhausted }) {
                                Button("Use \(other.profile) account") {
                                    Task {
                                        store.banner = await usage.switchAccount(provider: other.provider, profile: other.profile)
                                        usage.refresh(force: true)
                                        conductor.retryVoice(answer.id, conversationID: conversation.id, store: store)
                                    }
                                }
                                .plainGlassButton().controlSize(.small)
                                .help("\(other.email) — \(other.left.map { "\($0)% left" } ?? "meter unknown")")
                            }
                        }
                    }
                }
            } else if answer.text.isEmpty {
                HStack(spacing: 8) {
                    BurstSpinner(color: color, size: 15)
                    WorkingWord(backendStatus: conductor.status[answer.id])
                }
                .frame(minHeight: 18)
            } else if compact {
                // Equal heights side by side: the card never grows past the
                // row; a long answer scrolls inside it, in its own colour.
                TintedScrollView(color: color) {
                    VStack(alignment: .leading, spacing: 8) {
                        MarkdownText(source: answer.text).font(.system(size: 13.5))
                        if store.settings.showReasoning, !answer.reasoning.isEmpty || answer.finishedAt != nil {
                            WorkLine(message: answer, expanded: $reasoningOpen)
                        }
                    }
                    .padding(.trailing, 8)
                }
                .frame(height: 300)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    MarkdownText(source: answer.text).font(.system(size: 13.5))
                    if store.settings.showReasoning, !answer.reasoning.isEmpty || answer.finishedAt != nil {
                        WorkLine(message: answer, expanded: $reasoningOpen)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .fixedSize(horizontal: false, vertical: true)
        .background(shape.fill(Color(nsColor: .textBackgroundColor).opacity(0.72)))
        .background(shape.fill(color.opacity(0.10)))
        .overlay(shape.strokeBorder(answer.isPreferred ? color.opacity(0.7) : color.opacity(0.18), lineWidth: answer.isPreferred ? 1.4 : 1))
    }
}

/// Icons under a participant's bubble: rise in while the turn is hovered,
/// with the same stagger as the user's row. A preferred answer keeps its star.
struct ParticipantActions: View {
    @EnvironmentObject var store: Store
    let answer: Message
    let color: Color
    let conversation: Conversation
    let prompt: Message?
    let revealed: Bool
    @State private var copied = false

    private struct Item: Identifiable {
        let id: String
        let symbol: String
        let label: String
        let help: String
        let alwaysVisible: Bool
        let tint: Color?
        let run: () -> Void
    }

    private var items: [Item] {
        [
            Item(id: "prefer", symbol: answer.isPreferred ? "star.fill" : "star",
                 label: answer.isPreferred ? "Preferred" : "",
                 help: answer.isPreferred ? "The room builds on this answer from the next message. Click to un-prefer."
                                          : "Prefer — from the next message on, every model sees this answer and goes further from it.",
                 alwaysVisible: answer.isPreferred, tint: answer.isPreferred ? color : nil) {
                withAnimation(Motion.on(Motion.bounce(Motion.fast))) { store.prefer(answer.id, in: conversation.id) }
            },
            Item(id: "continue", symbol: "arrow.right", label: "", help: "Continue in a normal chat with this model, from this answer",
                 alwaysVisible: false, tint: nil) {
                guard let prompt else { return }
                store.fork(prompt: prompt, answer: answer, from: conversation)
            },
            Item(id: "copy", symbol: copied ? "checkmark" : "doc.on.doc", label: "", help: "Copy this answer",
                 alwaysVisible: false, tint: copied ? .green : nil) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer.text, forType: .string)
                withAnimation(Motion.on(Motion.bounce(Motion.fast))) { copied = true }
                Task { try? await Task.sleep(nanoseconds: 1_200_000_000); withAnimation(Motion.on(Motion.smoothOut(Motion.quick))) { copied = false } }
            },
        ]
    }

    var body: some View {
        let ready = !answer.text.isEmpty && !answer.isStreaming
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let visible = ready && (revealed || item.alwaysVisible)
                Button(action: item.run) {
                    HStack(spacing: 4) {
                        Image(systemName: item.symbol).font(.system(size: 11, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                        if !item.label.isEmpty { Text(item.label).font(.system(size: 10.5, weight: .medium)) }
                    }
                    .padding(.horizontal, item.label.isEmpty ? 0 : 6)
                    .frame(minWidth: 24, minHeight: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(item.tint ?? .secondary)
                .help(item.help)
                .opacity(visible ? 1 : 0)
                .offset(y: visible ? 0 : 4)
                .allowsHitTesting(visible)
                .animation(
                    Motion.disabled ? nil : (visible
                        ? Motion.smoothOut(Motion.fast).delay(Double(index) * Motion.stagger)
                        : Motion.smoothOut(Motion.quick)),
                    value: visible)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 22)
        .padding(.leading, 6)
    }
}
