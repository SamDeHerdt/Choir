// Choir — made by Sam De Herdt for MakeWaves.
import SwiftUI
import AppKit

/// Prompts, skills and knowhow, written once. Nothing here belongs to a vendor:
/// the same text is handed to Claude, GPT, Gemini or a local model, and the MCP
/// bridge serves it back out to the CLIs.
struct LibraryView: View {
    @EnvironmentObject var store: Store
    /// The sidebar opens one kind at a time; nil shows everything.
    var kind: LibraryItem.Kind?
    @State private var selected: UUID?
    @State private var search = ""
    @State private var kindFilter: LibraryItem.Kind?
    @State private var showImport = false
    @State private var note: String?

    private var scoped: [LibraryItem] { store.library.filter { kind == nil || $0.kind == kind } }

    private func items(_ kind: LibraryItem.Kind) -> [LibraryItem] {
        store.library
            .filter { $0.kind == kind }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.summary.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    if let kind {
                        HStack(spacing: 8) {
                            Image(systemName: kind.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            Text(kind.plural).font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Text("\(scoped.count)").font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        .padding(.horizontal, 4)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
                        TextField("Search", text: $search).textFieldStyle(.plain).font(.system(size: 12))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .glassPanel(9)
                }
                .padding(10)

                List(selection: $selected) {
                    ForEach(LibraryItem.Kind.allCases, id: \.self) { rowKind in
                        let rows = (kind == nil || kind == rowKind) ? items(rowKind) : []
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows) { item in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                        if !item.summary.isEmpty {
                                            Text(item.summary).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    .padding(.vertical, 1)
                                    .tag(item.id)
                                    .contextMenu {
                                        Button("Duplicate") { duplicate(item) }
                                        Button("Delete", role: .destructive) { delete(item.id) }
                                    }
                                }
                            } header: {
                                if kind == nil {
                                    Text(rowKind.plural).font(.system(size: 10.5, weight: .semibold))
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider().opacity(0.4)

                HStack {
                    Menu {
                        if let kind {
                            Button { add(kind) } label: { Label("New \(kind.label.lowercased())", systemImage: kind.symbol) }
                        } else {
                            ForEach(LibraryItem.Kind.allCases, id: \.self) { k in
                                Button { add(k) } label: { Label("New \(k.label.lowercased())", systemImage: k.symbol) }
                            }
                        }
                        if kind == nil || kind == .skill {
                        Divider()
                        Button {
                            showImport = true
                        } label: { Label("Import skills from this Mac…", systemImage: "square.and.arrow.down") }
                        Menu("Share skills with") {
                            ForEach(SkillRoots.all()) { root in
                                Button {
                                    let result = store.publishSkills(to: root)
                                    note = "\(root.name): \(result.linked) linked\(result.skipped > 0 ? ", \(result.skipped) already there" : "")."
                                } label: {
                                    if store.isPublished(to: root) { Label(root.name, systemImage: "checkmark") } else { Text(root.name) }
                                }
                            }
                        }
                        Button("Show skills folder") {
                            store.syncSkillsFolder()
                            NSWorkspace.shared.open(store.skillsFolder)
                        }
                        }
                    } label: {
                        Label(kind.map { "New \($0.label.lowercased())" } ?? "New", systemImage: "plus").font(.system(size: 11.5, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer()
                    if let note {
                        Text(note).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            .transition(.opacity)
                            .task { try? await Task.sleep(nanoseconds: 3_500_000_000); withAnimation { self.note = nil } }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .motion(Motion.smoothOut(Motion.quick), value: note)
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            .sheet(isPresented: $showImport) {
                SkillImportSheet { imported in
                    for item in imported where !store.library.contains(where: { $0.kind == .skill && $0.name == item.name }) {
                        store.library.append(item)
                    }
                    store.scheduleSave()
                    selected = imported.first.flatMap { first in store.library.first { $0.name == first.name }?.id } ?? selected
                }
                .environmentObject(store)
            }

            Group {
                if let selected, let index = store.library.firstIndex(where: { $0.id == selected }) {
                    LibraryEditor(index: index)
                } else {
                    LibraryOverview(kind: kind, onImport: { showImport = true }, onNew: { add($0) })
                }
            }
        }
        .onAppear { if selected == nil { selected = scoped.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.first?.id } }
    }

    private func add(_ kind: LibraryItem.Kind) {
        var item = LibraryItem(kind: kind)
        item.name = "New \(kind.label.lowercased())"
        withAnimation(Motion.on(Motion.smoothOut(Motion.fast))) { store.library.insert(item, at: 0) }
        selected = item.id
        store.scheduleSave()
    }

    private func duplicate(_ item: LibraryItem) {
        var copy = item
        copy.id = UUID()
        copy.name += " copy"
        store.library.insert(copy, at: 0)
        selected = copy.id
        store.scheduleSave()
    }

    private func delete(_ id: UUID) {
        withAnimation(Motion.on(Motion.smoothOut(Motion.quick))) {
            store.library.removeAll { $0.id == id }
        }
        for i in store.projects.indices { store.projects[i].libraryIDs.removeAll { $0 == id } }
        for i in store.conversations.indices { store.conversations[i].libraryIDs.removeAll { $0 == id } }
        if selected == id { selected = store.library.first?.id }
        store.scheduleSave()
    }
}

/// The item as a document: title, one-line description, the text. Facts and
/// housekeeping stay out of the way — one line of meta, one ⋯ menu.
struct LibraryEditor: View {
    @EnvironmentObject var store: Store
    let index: Int
    @State private var previewing = false
    @State private var showRaw = false
    @State private var confirmingDelete = false

    private var item: LibraryItem { store.library[index] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Title block
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        TextField("Name", text: binding(\.name))
                            .textFieldStyle(.plain)
                            .font(.system(size: 24, weight: .semibold))
                        Spacer()
                        more
                    }
                    TextField(summaryPrompt, text: binding(\.summary))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Menu {
                            ForEach(LibraryItem.Kind.allCases, id: \.self) { kind in
                                Button { binding(\.kind).wrappedValue = kind } label: {
                                    if kind == item.kind { Label(kind.label, systemImage: "checkmark") } else { Label(kind.label, systemImage: kind.symbol) }
                                }
                            }
                        } label: {
                            Label(item.kind.label, systemImage: item.kind.symbol).font(.system(size: 11, weight: .medium))
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        Text("·").foregroundStyle(.quaternary)
                        Text(kindExplainer).font(.system(size: 11)).foregroundStyle(.tertiary)
                        Text("·").foregroundStyle(.quaternary)
                        Text("edited \(item.updatedAt.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                        if item.kind == .skill, store.isShared(item) {
                            Text("·").foregroundStyle(.quaternary)
                            Text("visible to the CLIs").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                    .lineLimit(1)
                }

                // Body
                VStack(alignment: .leading, spacing: 6) {
                    if previewing {
                        Group {
                            if item.body.isEmpty { Text("Nothing written yet.").font(.system(size: 13)).foregroundStyle(.tertiary) }
                            else { MarkdownText(source: item.body).font(.system(size: 13.5)) }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        TextEditor(text: binding(\.body))
                            .font(.system(size: 13.5))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: bodyHeight, maxHeight: bodyHeight)
                            .padding(10)
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(alignment: .topLeading) {
                                if item.body.isEmpty {
                                    Text(bodyPlaceholder).font(.system(size: 13.5)).foregroundStyle(.tertiary)
                                        .allowsHitTesting(false).padding(.leading, 15).padding(.top, 11)
                                }
                            }
                    }
                    HStack {
                        Button(previewing ? "Edit" : "Preview") {
                            withAnimation(Motion.on(Motion.smoothOut(Motion.quick))) { previewing.toggle() }
                        }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        Text("~\(max(1, item.body.count / 4).formatted()) tokens")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    .padding(.horizontal, 4)
                }

                Divider().opacity(0.4)

                // Where it applies
                VStack(alignment: .leading, spacing: 8) {
                    Text("Used in").font(.system(size: 12.5, weight: .semibold))
                    if store.projects.isEmpty {
                        Text("No projects yet. Attach this to a project and every chat there inherits it.")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    ForEach(store.projects) { project in
                        Toggle(isOn: Binding(
                            get: { project.libraryIDs.contains(item.id) },
                            set: { on in
                                var copy = project
                                copy.libraryIDs.removeAll { $0 == item.id }
                                if on { copy.libraryIDs.append(item.id) }
                                withAnimation(Motion.on(Motion.smoothOut(Motion.quick))) { store.update(copy) }
                            })) {
                            HStack(spacing: 8) {
                                Image(systemName: "folder.fill").font(.system(size: 10)).foregroundStyle(store.color(of: project))
                                Text(project.name).font(.system(size: 12.5))
                                let n = store.conversations(in: project.id).count
                                if n > 0 { Text("\(n) chat\(n == 1 ? "" : "s")").font(.system(size: 10.5)).foregroundStyle(.tertiary) }
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                    let chats = store.conversations.filter { $0.libraryIDs.contains(item.id) }
                    if !chats.isEmpty {
                        Text("Also attached directly in \(chats.count) chat\(chats.count == 1 ? "" : "s").")
                            .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 2)
                    }
                }

                DisclosureGroup(isExpanded: $showRaw) {
                    Text(item.rendered())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.top, 6)
                } label: {
                    Text("What a model receives").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 26)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: item.id) { _, _ in confirmingDelete = false; previewing = false }
    }

    private var more: some View {
        Menu {
            Button {
                var copy = item; copy.id = UUID(); copy.name += " copy"; copy.updatedAt = Date()
                store.library.insert(copy, at: index + 1)
                store.scheduleSave()
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            if item.kind == .skill {
                Button {
                    store.syncSkillsFolder()
                    NSWorkspace.shared.activateFileViewerSelecting([store.skillsFolder.appendingPathComponent(Store.slug(item.name))])
                } label: { Label("Show SKILL.md folder", systemImage: "folder") }
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.rendered(), forType: .string)
            } label: { Label("Copy as text", systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive) {
                let id = item.id
                withAnimation(Motion.on(Motion.smoothOut(Motion.medium))) {
                    store.library.removeAll { $0.id == id }
                    for i in store.projects.indices { store.projects[i].libraryIDs.removeAll { $0 == id } }
                    for i in store.conversations.indices { store.conversations[i].libraryIDs.removeAll { $0 == id } }
                }
                store.scheduleSave()
            } label: { Label("Delete", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private var bodyHeight: CGFloat {
        let lines = item.body.split(separator: "\n", omittingEmptySubsequences: false).count
        let wrapped = item.body.count / 90
        return min(max(CGFloat(lines + wrapped) * 19 + 30, 140), 480)
    }

    private var summaryPrompt: String {
        switch item.kind {
        case .prompt: return "What is this prompt for? One line."
        case .skill: return "What does this skill do, and when? One line."
        case .knowhow: return "What is this about? One line."
        }
    }

    private var kindExplainer: String {
        switch item.kind {
        case .prompt: return "injected as written"
        case .skill: return "sent with its when-to-use line; also a SKILL.md folder"
        case .knowhow: return "standing context"
        }
    }

    private var bodyPlaceholder: String {
        switch item.kind {
        case .prompt: return "Write in plain business Dutch. Lead with the conclusion…"
        case .skill: return "Step by step, what to do when this applies…"
        case .knowhow: return "The client is… The stack is… We never…"
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<LibraryItem, T>) -> Binding<T> {
        Binding(
            get: { store.library[index][keyPath: keyPath] },
            set: {
                store.library[index][keyPath: keyPath] = $0
                store.library[index].updatedAt = Date()
                store.scheduleSave()
            }
        )
    }
}

/// What the Library is for, with the numbers, when nothing is selected.
struct LibraryOverview: View {
    @EnvironmentObject var store: Store
    var kind: LibraryItem.Kind?
    let onImport: () -> Void
    let onNew: (LibraryItem.Kind) -> Void

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text(kind.map { $0.plural } ?? "Write it once. Every model reads it.")
                    .font(.system(size: 18, weight: .semibold))
                Text(kind.map(longExplainer) ?? "What lives here is yours, not a vendor's — the same text goes to Claude, ChatGPT, Gemini or a local model, and the CLIs can read it back.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            HStack(spacing: 12) {
                ForEach(kind.map { [$0] } ?? LibraryItem.Kind.allCases, id: \.self) { kind in
                    let n = store.library.filter { $0.kind == kind }.count
                    Button { onNew(kind) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: kind.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(n)").font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                            }
                            Text(kind.plural).font(.system(size: 13, weight: .semibold))
                            Text(explainer(kind)).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(width: 176, alignment: .topLeading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .glassPanel(14, interactive: true)
                }
            }
            if kind == nil || kind == .skill {
                Button { onImport() } label: {
                    Label("Import the skills on this Mac", systemImage: "square.and.arrow.down")
                }
                .prominentGlassButton()
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func longExplainer(_ kind: LibraryItem.Kind) -> String {
        switch kind {
        case .prompt: return "Reusable instructions injected as written — voice, format, rules. Attach one to a project or a single chat."
        case .skill: return "A job and when it applies. Every skill is also a SKILL.md folder, so Claude Code and Codex can read it natively."
        case .knowhow: return "Standing context — the client, the stack, the conventions. Facts that stay true between conversations."
        }
    }

    private func explainer(_ kind: LibraryItem.Kind) -> String {
        switch kind {
        case .prompt: return "Set the voice, the format, the rules."
        case .skill: return "A job and when it applies."
        case .knowhow: return "Facts that stay true between chats."
        }
    }
}

// MARK: - Import the skills already on this Mac

struct SkillImportSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let onImport: ([LibraryItem]) -> Void

    @State private var candidates: [SkillImporter.Candidate] = []
    @State private var chosen: Set<String> = []

    private func alreadyIn(_ c: SkillImporter.Candidate) -> Bool {
        store.library.contains { $0.kind == .skill && $0.name == c.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Import skills").font(.system(size: 14, weight: .semibold))
                Text("Found in the folders Claude Code, Codex and other agents read from. Imported copies are Choir's own — editing them here does not touch the originals.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            Divider()

            if candidates.isEmpty {
                Text("No SKILL.md files found in ~/.claude, ~/.codex or ~/.agents.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(candidates) { c in
                            let present = alreadyIn(c)
                            Button {
                                if chosen.contains(c.id) { chosen.remove(c.id) } else { chosen.insert(c.id) }
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: present ? "checkmark.circle" : (chosen.contains(c.id) ? "checkmark.circle.fill" : "circle"))
                                        .foregroundStyle(present ? Color.secondary.opacity(0.4) : (chosen.contains(c.id) ? Color.accentColor : Color.secondary.opacity(0.5)))
                                        .padding(.top, 1)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(c.name).font(.system(size: 12.5, weight: .medium))
                                            Chip(text: c.source)
                                            if present { Text("already in library").font(.system(size: 10)).foregroundStyle(.tertiary) }
                                        }
                                        if !c.summary.isEmpty {
                                            Text(c.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(present)
                        }
                    }
                    .padding(10)
                }
            }

            Divider()

            HStack {
                Button("Select all new") {
                    chosen = Set(candidates.filter { !alreadyIn($0) }.map(\.id))
                }
                .controlSize(.small)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(chosen.count)") {
                    let items = candidates.filter { chosen.contains($0.id) }.map { c in
                        LibraryItem(kind: .skill, name: c.name, summary: c.summary, body: c.body)
                    }
                    onImport(items)
                    dismiss()
                }
                .prominentGlassButton()
                .disabled(chosen.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 560, height: 520)
        .onAppear { candidates = SkillImporter.scan() }
    }
}
