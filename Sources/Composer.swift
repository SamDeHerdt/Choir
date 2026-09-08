// Choir — made by Sam De Herdt for MakeWaves.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The one control that carries the app's whole argument: the model is chosen
/// here, per message, and everything else about the thread stays put.
struct Composer: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var conductor: Conductor
    let conversationID: UUID
    @Binding var draft: String
    @Binding var showLibrarySheet: Bool
    @FocusState.Binding var focused: Bool

    @State private var showModelPicker = false
    @State private var attachments: [ProjectFile] = []
    @State private var dropTargeted = false

    private var conversation: Conversation? { store.conversations.first { $0.id == conversationID } }
    private var running: Bool { conductor.isRunning(conversationID) }

    var body: some View {
        VStack(spacing: 8) {
            if let conversation {
                let names = store.appliedNames(for: conversation)
                if !names.isEmpty || !attachments.isEmpty {
                    HStack(spacing: 6) {
                        if !names.isEmpty { FlowChips(names: names) }
                        if !attachments.isEmpty { attachmentChips }
                        Spacer()
                    }
                    .transition(.opacity)
                }
                inputRow(conversation)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in attach([url]) }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .padding(.horizontal, 16).padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .motion(Motion.smoothOut(Motion.quick), value: dropTargeted)
        .motion(Motion.smoothOut(Motion.fast), value: attachments.count)
    }

    // MARK: Attachments

    /// Files that go with the next message. Only their text is sent, so a PDF
    /// costs what its words cost.
    private var attachmentChips: some View {
        HStack(spacing: 6) {
            ForEach(attachments) { file in
                HStack(spacing: 5) {
                    Image(systemName: "doc.text").font(.system(size: 9, weight: .semibold))
                    Text(file.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text("~\(file.approxTokens.formatted())").font(.system(size: 9.5)).foregroundStyle(.tertiary).monospacedDigit()
                    Button {
                        withAnimation(Motion.on(Motion.smoothOut(Motion.quick))) { attachments.removeAll { $0.id == file.id } }
                    } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .glassPanel(9)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
    }

    private func attach(_ urls: [URL]) {
        for url in urls {
            guard let file = FileText.extract(url) else {
                store.banner = "Could not read text from \(url.lastPathComponent)."
                continue
            }
            attachments.removeAll { $0.name == file.name }
            attachments.append(file)
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in attach(panel.urls) }
        }
    }

    // MARK: Input row

    private func inputRow(_ conversation: Conversation) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                openPanel()
            } label: {
                Image(systemName: "paperclip").font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Attach a file — text, Markdown, code, CSV, JSON or PDF. Or drop it here.")

            Button {
                showLibrarySheet = true
            } label: {
                Image(systemName: "books.vertical").font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Attach prompts, skills or knowhow from the library to this thread")

            if conversation.isRoom {
                RoomModelBar(conversationID: conversationID)
            } else {
                ModelMenu(conversationID: conversationID)
            }

            TextField(conversation.isRoom ? "Ask the room…" : "Ask \(store.label(forKey: conversation.modelKey))…",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .lineLimit(1...8)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    // Return sends; Shift-Return makes a new line.
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    send()
                    return .handled
                }
                .onKeyPress(.escape) {
                    // Esc stops whatever is still writing.
                    guard running else { return .ignored }
                    conductor.stop(conversationID)
                    return .handled
                }

            let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
            SendButton(mode: running ? (hasDraft ? .queue : .stop) : .send, enabled: hasDraft) {
                if running && !hasDraft { conductor.stop(conversationID) } else { send() }
            }
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassPanel(20)
        .motion(Motion.smoothOut(Motion.quick), value: running)
    }

    /// While a turn is running, sending queues instead — the message waits as
    /// a pending bubble and goes out the moment the current answer finishes.
    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        let files = attachments
        draft = ""
        attachments = []
        if running {
            conductor.enqueue(text, attachments: files, conversationID: conversationID)
        } else {
            conductor.send(text, attachments: files, conversationID: conversationID, store: store)
        }
    }
}

// MARK: - Model picker

struct ModelMenu: View {
    @EnvironmentObject var store: Store
    let conversationID: UUID
    @State private var showCustom = false
    @State private var refreshing = false

    private var conversation: Conversation? { store.conversations.first { $0.id == conversationID } }

    var body: some View {
        Menu {
            ForEach(Backend.allCases, id: \.self) { backend in
                let models = store.enabledModels.filter { $0.backend == backend }
                if !models.isEmpty {
                    Section(backend.displayName) {
                        ForEach(models) { model in
                            Button {
                                pick(model.key)
                            } label: {
                                if model.key == conversation?.modelKey {
                                    Label(model.label, systemImage: "checkmark")
                                } else {
                                    Text(model.label)
                                }
                            }
                        }
                    }
                }
            }
            if store.enabledModels.isEmpty {
                Text("No models enabled — open Settings")
            }
            Divider()
            Button {
                refreshing = true
                Task { _ = await ModelDiscovery.refresh(store: store); refreshing = false }
            } label: {
                Label(refreshing ? "Looking…" : "Find every available model", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(refreshing)
            Button {
                showCustom = true
            } label: {
                Label("Use a model id of my own…", systemImage: "pencil")
            }
        } label: {
            HStack(spacing: 6) {
                Text(shortLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 150, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch model. The conversation, project files and library stay exactly as they are.")
        .sheet(isPresented: $showCustom) {
            CustomModelSheet { spec in
                if !store.settings.models.contains(where: { $0.key == spec.key }) {
                    store.settings.models.append(spec)
                }
                pick(spec.key)
            }
            .environmentObject(store)
        }
    }

    private var shortLabel: String {
        guard let key = conversation?.modelKey else { return "Pick a model" }
        return store.settings.model(key: key)?.label ?? "Pick a model"
    }

    private func pick(_ key: String) {
        guard let i = store.index(of: conversationID) else { return }
        withAnimation(Motion.on(Motion.smoothOut(Motion.fast))) {
            store.conversations[i].modelKey = key
        }
        store.settings.defaultModelKey = key
        store.scheduleSave()
    }
}

/// A room's panel of voices, editable in place.
struct RoomModelBar: View {
    @EnvironmentObject var store: Store
    let conversationID: UUID

    private var conversation: Conversation? { store.conversations.first { $0.id == conversationID } }

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Section("Mode") {
                    ForEach(RoomMode.allCases, id: \.self) { mode in
                        Button {
                            setMode(mode)
                        } label: {
                            if conversation?.roomMode == mode {
                                Label(mode.label, systemImage: "checkmark")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                }
                Section("Voices") {
                    ForEach(store.enabledModels) { model in
                        let seated = conversation?.roomModelKeys.contains(model.key) == true
                        let familyTaken = !seated && (conversation?.roomModelKeys ?? []).contains { key in
                            store.settings.model(key: key)?.family == model.family
                        }
                        Button {
                            toggle(model.key)
                        } label: {
                            if seated {
                                Label(model.label, systemImage: "checkmark")
                            } else if familyTaken {
                                Text("\(model.label) — same model already seated")
                            } else {
                                Text(model.label)
                            }
                        }
                        .disabled(familyTaken)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.3.fill")
                    Text("\(conversation?.roomModelKeys.count ?? 0) voices · \(conversation?.roomMode.label ?? "")")
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(conversation?.roomMode.explainer ?? "")
        }
    }

    private func setMode(_ mode: RoomMode) {
        guard let i = store.index(of: conversationID) else { return }
        store.conversations[i].roomMode = mode
        store.scheduleSave()
    }

    private func toggle(_ key: String) {
        guard let i = store.index(of: conversationID) else { return }
        withAnimation(Motion.on(Motion.smoothOut(Motion.fast))) {
            if let at = store.conversations[i].roomModelKeys.firstIndex(of: key) {
                store.conversations[i].roomModelKeys.remove(at: at)
            } else {
                store.conversations[i].roomModelKeys.append(key)
            }
        }
        store.scheduleSave()
    }
}

// MARK: - Attach library items to a thread

struct LibraryPicker: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let conversationID: UUID

    private var conversation: Conversation? { store.conversations.first { $0.id == conversationID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Attach to this thread").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.prominentGlassButton()
            }
            .padding(16)

            Divider()

            if store.library.isEmpty {
                VStack(spacing: 8) {
                    Text("The library is empty.").font(.system(size: 13, weight: .medium))
                    Text("Add prompts, skills and knowhow in the Library tab — they work with every model.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
                .padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(store.library) { item in
                            let on = conversation?.libraryIDs.contains(item.id) == true
                            Button {
                                toggle(item.id)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.5))
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Image(systemName: item.kind.symbol).font(.system(size: 9)).foregroundStyle(.tertiary)
                                            Text(item.name).font(.system(size: 12.5, weight: .medium))
                                        }
                                        if !item.summary.isEmpty {
                                            Text(item.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(on ? Color.accentColor.opacity(0.08) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 460, height: 420)
    }

    private func toggle(_ id: UUID) {
        guard let i = store.index(of: conversationID) else { return }
        withAnimation(Motion.on(Motion.smoothOut(Motion.quick))) {
            if let at = store.conversations[i].libraryIDs.firstIndex(of: id) {
                store.conversations[i].libraryIDs.remove(at: at)
            } else {
                store.conversations[i].libraryIDs.append(id)
            }
        }
        store.scheduleSave()
    }
}


// MARK: - A model id typed by hand

/// For the model that shipped this morning and is in no list yet.
struct CustomModelSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let onPick: (ModelSpec) -> Void

    @State private var backend: Backend = .claudeCLI
    @State private var id = ""
    @State private var label = ""

    private var usable: [Backend] {
        Backend.allCases.filter { store.settings.connection(for: $0).enabled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Use a model id of my own").font(.system(size: 14, weight: .semibold))

            Picker("Through", selection: $backend) {
                ForEach(usable, id: \.self) { Text($0.displayName).tag($0) }
            }

            TextField("Model id — exactly as the tool expects it", text: $id)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit(commit)

            TextField("Label (optional)", text: $label)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            Text(hint)
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use it") { commit() }
                    .prominentGlassButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(id.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { backend = usable.first ?? .claudeCLI }
    }

    private var hint: String {
        switch backend {
        case .claudeCLI: return "Anything `claude --model` accepts: an alias like sonnet, or a full name."
        case .codexCLI: return "Anything `codex -m` accepts. Your Codex keeps its own list in ~/.codex/models_cache.json."
        case .customCLI: return "Substituted for {model} in the arguments you set under Connections."
        case .ollama: return "A tag you have pulled, e.g. qwen3:30b."
        default: return "The vendor's model id. If it is wrong the first message will say so."
        }
    }

    private func commit() {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let name = label.trimmingCharacters(in: .whitespaces)
        onPick(ModelSpec(backend: backend, id: trimmed, label: name.isEmpty ? trimmed : name))
        dismiss()
    }
}
