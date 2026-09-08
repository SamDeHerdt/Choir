// Choir — made by Sam De Herdt for MakeWaves.
import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

/// A project page: ask at the top, recents below, and a rail on the right that
/// shows everything a model will know inside this project. The same layout the
/// vendor apps converged on — except here one project serves every model.
struct ProjectView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var conductor: Conductor
    @Binding var route: Route?
    let projectID: UUID

    @State private var draft = ""
    @State private var dropTargeted = false
    @FocusState private var composerFocused: Bool

    private var project: Project? { store.projects.first { $0.id == projectID } }

    var body: some View {
        if let project {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    breadcrumb(project)
                    titleBlock(project)
                    HStack(alignment: .top, spacing: 26) {
                        VStack(alignment: .leading, spacing: 18) {
                            askBox(project)
                            recents(project)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        rail(project)
                            .frame(width: 300)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 22)
                .padding(.bottom, 32)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(
                RadialGradient(colors: [store.color(of: project).opacity(0.09), .clear], center: .topLeading, startRadius: 0, endRadius: 900)
                    .ignoresSafeArea()
            )
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                load(providers: providers); return true
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(store.color(of: project), style: StrokeStyle(lineWidth: 2, dash: [7]))
                        .padding(10)
                        .transition(.opacity)
                }
            }
            .motion(Motion.smoothOut(Motion.quick), value: dropTargeted)
            .onAppear { composerFocused = true }
        } else {
            Text("Project not found").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Top

    private func breadcrumb(_ project: Project) -> some View {
        HStack(spacing: 6) {
            Text("Projects").foregroundStyle(.secondary)
            Text("/").foregroundStyle(.tertiary)
            Text(project.name).foregroundStyle(.primary)
        }
        .font(.system(size: 12))
    }

    private func titleBlock(_ project: Project) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "folder.fill").font(.system(size: 20)).foregroundStyle(store.color(of: project))

            VStack(alignment: .leading, spacing: 3) {
                TextField("Project name", text: binding(\.name))
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .semibold))
                TextField("What is this project for?", text: binding(\.summary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ColorSwatch(color: store.color(of: project), isCustom: project.colorHex != nil) { hex in
                var copy = project; copy.colorHex = hex
                withAnimation(Motion.on(Motion.smoothOut(Motion.fast))) { store.update(copy) }
            }
            Menu {
                Button("New room in this project") {
                    let c = store.newConversation(room: true, projectID: project.id)
                    route = .conversation(c.id)
                }
                Divider()
                Button("Delete project", role: .destructive) {
                    store.deleteProject(project.id)
                    route = nil
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    // MARK: Ask box

    private func askBox(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $draft)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 44, maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .focused($composerFocused)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Ask anything in \(project.name)…")
                            .font(.system(size: 14)).foregroundStyle(.tertiary)
                            .allowsHitTesting(false).padding(.leading, 5).padding(.top, 1)
                    }
                }
                .onKeyPress(.return, phases: .down) { press in
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    start(project); return .handled
                }

            HStack(spacing: 10) {
                Button {
                    openPanel()
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Add a file to this project's context")

                Spacer()

                ProjectModelMenu(project: project)

                Button {
                    start(project)
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).frame(width: 26, height: 26)
                }
                .prominentGlassButton()
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .glassPanel(18)
        .overlay(alignment: .bottomLeading) {
            // What rides along with the first message, at a glance.
            let names = store.appliedNames(for: Conversation(projectID: project.id, modelKey: ""))
            if !names.isEmpty {
                FlowChips(names: names)
                    .offset(y: 30)
            }
        }
        .padding(.bottom, store.appliedNames(for: Conversation(projectID: project.id, modelKey: "")).isEmpty ? 0 : 26)
    }

    private func start(_ project: Project) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        let c = store.newConversation(projectID: project.id)
        route = .conversation(c.id)
        conductor.send(text, conversationID: c.id, store: store)
    }

    // MARK: Recents

    private func recents(_ project: Project) -> some View {
        let list = store.conversations(in: project.id)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Recents").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                .padding(.bottom, 6)
            if list.isEmpty {
                Text("Nothing yet. The first question above starts the first conversation.")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            ForEach(list) { conversation in
                Button {
                    route = .conversation(conversation.id)
                } label: {
                    HStack(spacing: 10) {
                        if conversation.isRoom {
                            Image(systemName: "person.3.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                        } else {
                            VoiceDot(key: conversation.modelKey, size: 7)
                        }
                        Text(conversation.title).font(.system(size: 13.5)).lineLimit(1)
                        Spacer()
                        Text(relative(conversation.updatedAt)).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().opacity(0.3)
            }
        }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Rail

    private func rail(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RailSection(title: "Instructions",
                        empty: project.instructions.isEmpty ? "Tell every model how to behave in this project." : nil,
                        symbol: nil) {
                TextEditor(text: binding(\.instructions))
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 60, maxHeight: 200)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(0.4)

            RailSection(title: "Context",
                        empty: project.files.isEmpty ? "Drop PDFs, documents or text here. Only the words travel to the model." : nil,
                        symbol: "plus", action: openPanel) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(project.files) { file in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(file.name).font(.system(size: 11.5)).lineLimit(1)
                            Spacer()
                            Text("~\(file.approxTokens.formatted())").font(.system(size: 9.5)).foregroundStyle(.tertiary).monospacedDigit()
                            Button {
                                var copy = project
                                copy.files.removeAll { $0.id == file.id }
                                withAnimation(Motion.on(Motion.smoothOut(Motion.quick))) { store.update(copy) }
                            } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                .buttonStyle(.plain).foregroundStyle(.tertiary)
                        }
                        .transition(.opacity)
                    }
                    if !project.files.isEmpty {
                        Text("Roughly \(project.knowledgeTokens.formatted()) tokens per message.")
                            .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 2)
                    }
                }
            }
            Divider().opacity(0.4)

            RailSection(title: "Knowhow", empty: attached(project, .knowhow).isEmpty ? "Standing facts every model should know here." : nil,
                        symbol: "plus", menu: { libraryMenu(project, kinds: [.knowhow]) }) {
                attachedList(project, kinds: [.knowhow])
            }
            Divider().opacity(0.4)

            RailSection(title: "Skills & prompts", empty: attached(project, .skill).isEmpty && attached(project, .prompt).isEmpty ? "Reusable instructions from the library." : nil,
                        symbol: "plus", menu: { libraryMenu(project, kinds: [.skill, .prompt]) }) {
                attachedList(project, kinds: [.skill, .prompt])
            }
        }
        .glassPanel(16)
    }

    private func attached(_ project: Project, _ kind: LibraryItem.Kind) -> [LibraryItem] {
        store.library.filter { $0.kind == kind && project.libraryIDs.contains($0.id) }
    }

    private func attachedList(_ project: Project, kinds: [LibraryItem.Kind]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(store.library.filter { kinds.contains($0.kind) && project.libraryIDs.contains($0.id) }) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.kind.symbol).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(item.name).font(.system(size: 11.5)).lineLimit(1)
                    Spacer()
                    Button {
                        var copy = project
                        copy.libraryIDs.removeAll { $0 == item.id }
                        withAnimation(Motion.on(Motion.smoothOut(Motion.quick))) { store.update(copy) }
                    } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func libraryMenu(_ project: Project, kinds: [LibraryItem.Kind]) -> some View {
        let options = store.library.filter { kinds.contains($0.kind) }
        if options.isEmpty {
            Text("Nothing of this kind in the library yet")
        }
        ForEach(options) { item in
            Button {
                var copy = project
                if let at = copy.libraryIDs.firstIndex(of: item.id) { copy.libraryIDs.remove(at: at) }
                else { copy.libraryIDs.append(item.id) }
                withAnimation(Motion.on(Motion.smoothOut(Motion.quick))) { store.update(copy) }
            } label: {
                if project.libraryIDs.contains(item.id) {
                    Label(item.name, systemImage: "checkmark")
                } else {
                    Text(item.name)
                }
            }
        }
        Divider()
        Button("Open the library") { route = .library(kinds.first) }
    }

    // MARK: Editing helpers

    private func binding<T>(_ keyPath: WritableKeyPath<Project, T>) -> Binding<T> {
        Binding(
            get: { store.projects.first { $0.id == projectID }?[keyPath: keyPath] ?? project![keyPath: keyPath] },
            set: { newValue in
                guard var copy = store.projects.first(where: { $0.id == projectID }) else { return }
                copy[keyPath: keyPath] = newValue
                store.update(copy)
            }
        )
    }

    // MARK: File intake

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in add(urls: panel.urls) }
        }
    }

    private func load(providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in add(urls: [url]) }
            }
        }
    }

    /// Only extractable text is stored. A file Choir cannot read is reported
    /// rather than silently added as an empty attachment.
    private func add(urls: [URL]) {
        guard var copy = store.projects.first(where: { $0.id == projectID }) else { return }
        for url in urls {
            let name = url.lastPathComponent
            var text: String?
            if url.pathExtension.lowercased() == "pdf" {
                text = PDFDocument(url: url)?.string
            } else {
                text = try? String(contentsOf: url, encoding: .utf8)
            }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                store.banner = "Could not read text from \(name)."
                continue
            }
            copy.files.removeAll { $0.name == name }
            copy.files.append(ProjectFile(name: name, text: text))
        }
        withAnimation(Motion.on(Motion.smoothOut(Motion.fast))) { store.update(copy) }
    }
}

// MARK: - Rail section

/// One block of the rail: a title, an optional "+" (a button or a menu), and
/// either its content or a one-line explanation of what would go there.
struct RailSection<Content: View, MenuContent: View>: View {
    let title: String
    let empty: String?
    let symbol: String?
    var action: (() -> Void)? = nil
    @ViewBuilder var menu: MenuContent
    @ViewBuilder var content: Content

    init(title: String, empty: String?, symbol: String?, action: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) where MenuContent == EmptyView {
        self.title = title; self.empty = empty; self.symbol = symbol; self.action = action
        self.menu = EmptyView(); self.content = content()
    }

    init(title: String, empty: String?, symbol: String?,
         @ViewBuilder menu: () -> MenuContent, @ViewBuilder content: () -> Content) {
        self.title = title; self.empty = empty; self.symbol = symbol; self.action = nil
        self.menu = menu(); self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let symbol {
                    if MenuContent.self == EmptyView.self {
                        Button { action?() } label: { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    } else {
                        Menu { menu } label: { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let empty {
                Text(empty).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Instructions is editable even when empty; the rest hide their body.
            if empty == nil || title == "Instructions" {
                content
            }
        }
        .padding(14)
    }
}

/// The model new chats in this project start with. Any chat can still switch.
struct ProjectModelMenu: View {
    @EnvironmentObject var store: Store
    let project: Project

    var body: some View {
        Menu {
            ForEach(Backend.allCases, id: \.self) { backend in
                let models = store.enabledModels.filter { $0.backend == backend }
                if !models.isEmpty {
                    Section(backend.displayName) {
                        ForEach(models) { model in
                            Button {
                                var copy = project; copy.defaultModelKey = model.key; store.update(copy)
                            } label: {
                                if project.defaultModelKey == model.key { Label(model.label, systemImage: "checkmark") }
                                else { Text(model.label) }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                VoiceDot(key: project.defaultModelKey ?? "")
                Text(store.label(forKey: project.defaultModelKey ?? store.settings.defaultModelKey))
                    .font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }
}
