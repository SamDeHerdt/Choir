// Choir — made by Sam De Herdt for MakeWaves.
import Foundation
import Security
import SwiftUI

// MARK: - Keychain

/// API keys never touch the JSON on disk. One generic-password item per backend.
enum Keychain {
    private static let service = "com.makewaves.choir"

    static func set(_ value: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var projects: [Project] = []
    @Published var library: [LibraryItem] = []
    /// nil = "All chats"; otherwise the project being browsed.
    @Published var activeProjectID: UUID?
    @Published var settings = AppSettings()
    @Published var selection: UUID?
    /// Non-fatal problems surfaced in the UI rather than swallowed.
    @Published var banner: String?
    /// The search hit being opened: the thread scrolls to that message and
    /// lights it, instead of dropping the reader at the top of the history.
    @Published var jump: SearchJump?
    /// What is in the search box. Kept here so the open thread can paint the
    /// phrase wherever it appears, for as long as the search is running.
    @Published var searchTerm: String = ""

    private let dir: URL
    private var saveWork: Task<Void, Never>?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("Choir", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    // MARK: Persistence

    private var conversationsURL: URL { dir.appendingPathComponent("conversations.json") }
    private var libraryURL: URL { dir.appendingPathComponent("library.json") }
    private var settingsURL: URL { dir.appendingPathComponent("settings.json") }
    private var projectsURL: URL { dir.appendingPathComponent("projects.json") }

    private func load() {
        let dec = JSONDecoder()
        if let d = try? Data(contentsOf: settingsURL) {
            do {
                settings = try dec.decode(AppSettings.self, from: d)
            } catch {
                // Never silently fall back to defaults: say so, and keep the
                // unreadable file next to the new one.
                try? d.write(to: settingsURL.appendingPathExtension("unreadable"))
                banner = "Settings could not be read (\(error.localizedDescription)); defaults loaded. The old file is kept as settings.json.unreadable."
            }
        }
        if true {
            // A newly added backend must still appear after an upgrade.
            for b in Backend.allCases where !settings.connections.contains(where: { $0.backend == b }) {
                settings.connections.append(Connection(backend: b, endpoint: b.defaultEndpoint))
            }
        }
        if let d = try? Data(contentsOf: libraryURL), let l = try? dec.decode([LibraryItem].self, from: d) {
            var seen = Set<String>()
            library = l.filter { seen.insert("\($0.kind.rawValue)|\($0.name.lowercased())").inserted }
        } else {
            library = LibraryItem.starters()
        }
        if let d = try? Data(contentsOf: projectsURL), let p = try? dec.decode([Project].self, from: d) {
            projects = p
        }
        if let d = try? Data(contentsOf: conversationsURL), let c = try? dec.decode([Conversation].self, from: d) {
            conversations = c
        }
        // Never resume mid-stream state from a crash.
        for i in conversations.indices {
            for j in conversations[i].messages.indices where conversations[i].messages[j].isStreaming {
                conversations[i].messages[j].isStreaming = false
                if conversations[i].messages[j].text.isEmpty { conversations[i].messages[j].error = "Interrupted" }
            }
        }
        selection = conversations.first?.id
    }

    /// Debounced: streaming mutates the model dozens of times a second.
    func scheduleSave() {
        saveWork?.cancel()
        saveWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    func save() {
        mergeExternalWrites()
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        do {
            try enc.encode(conversations).write(to: conversationsURL, options: .atomic)
            try enc.encode(projects).write(to: projectsURL, options: .atomic)
            try enc.encode(library).write(to: libraryURL, options: .atomic)
            try enc.encode(settings).write(to: settingsURL, options: .atomic)
            syncSkillsFolder()
        } catch {
            banner = "Could not save: \(error.localizedDescription)"
        }
    }

    // MARK: Skills as files

    /// Every library skill is also a real `<slug>/SKILL.md` folder under
    /// Application Support — the format Claude Code, Codex and the other agents
    /// already read. Publishing symlinks those folders into their skill roots,
    /// so a skill written once in Choir is native everywhere, not just injected
    /// into Choir's own prompts.
    var skillsFolder: URL { dir.appendingPathComponent("skills", isDirectory: true) }

    static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch); lastDash = false }
            else if !lastDash && !out.isEmpty { out.append("-"); lastDash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "skill" : out
    }

    func syncSkillsFolder() {
        let fm = FileManager.default
        try? fm.createDirectory(at: skillsFolder, withIntermediateDirectories: true)
        let wanted = library.filter { $0.kind == .skill }
        var keep = Set<String>()
        for skill in wanted {
            let slug = Self.slug(skill.name)
            keep.insert(slug)
            let folder = skillsFolder.appendingPathComponent(slug, isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let description = skill.summary.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
            let text = "---\nname: \(slug)\ndescription: \"\(description)\"\n---\n\n\(skill.body)\n"
            let file = folder.appendingPathComponent("SKILL.md")
            if (try? String(contentsOf: file, encoding: .utf8)) != text {
                try? text.write(to: file, atomically: true, encoding: .utf8)
            }
        }
        // Folders for skills that no longer exist go away, and so do the
        // symlinks that pointed at them — a dangling skill is worse than none.
        for entry in (try? fm.contentsOfDirectory(at: skillsFolder, includingPropertiesForKeys: nil)) ?? [] {
            let slug = entry.lastPathComponent
            guard !keep.contains(slug) else { continue }
            try? fm.removeItem(at: entry)
            for root in SkillRoots.all() {
                let link = root.url.appendingPathComponent(slug)
                if (try? fm.destinationOfSymbolicLink(atPath: link.path))?.hasPrefix(skillsFolder.path) == true {
                    try? fm.removeItem(at: link)
                }
            }
        }
    }

    /// Symlinks every Choir skill into one agent's skill root. Existing folders
    /// there are never touched — a real skill always wins over a link.
    func publishSkills(to root: SkillRoots.Root) -> (linked: Int, skipped: Int) {
        syncSkillsFolder()
        let fm = FileManager.default
        try? fm.createDirectory(at: root.url, withIntermediateDirectories: true)
        var linked = 0, skipped = 0
        for skill in library where skill.kind == .skill {
            let slug = Self.slug(skill.name)
            let target = skillsFolder.appendingPathComponent(slug, isDirectory: true)
            let link = root.url.appendingPathComponent(slug)
            if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                if dest == target.path { continue }
                skipped += 1; continue
            }
            if fm.fileExists(atPath: link.path) { skipped += 1; continue }
            do { try fm.createSymbolicLink(at: link, withDestinationURL: target); linked += 1 }
            catch { skipped += 1 }
        }
        return (linked, skipped)
    }

    /// True when at least one agent root links to this skill's folder.
    func isShared(_ item: LibraryItem) -> Bool {
        guard item.kind == .skill else { return false }
        let target = skillsFolder.appendingPathComponent(Self.slug(item.name), isDirectory: true).path
        return SkillRoots.all().contains { root in
            let link = root.url.appendingPathComponent(Self.slug(item.name)).path
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link) { return dest == target }
            return FileManager.default.fileExists(atPath: link)
        }
    }

    func isPublished(to root: SkillRoots.Root) -> Bool {
        let skills = library.filter { $0.kind == .skill }
        guard !skills.isEmpty else { return false }
        return skills.allSatisfy { skill in
            let link = root.url.appendingPathComponent(Self.slug(skill.name))
            let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            return dest?.hasPrefix(skillsFolder.path) == true || FileManager.default.fileExists(atPath: link.path)
        }
    }

    // MARK: Colours

    func color(of project: Project) -> Color {
        Color(hex: project.colorHex) ?? Palette.accent(project.accent)
    }

    /// The chat's own colour if set, else its project's, else the model's.
    func color(of conversation: Conversation) -> Color {
        if let c = Color(hex: conversation.colorHex) { return c }
        if let i = conversation.accent { return Palette.accent(i) }
        if let p = self.project(conversation.projectID) { return color(of: p) }
        return Palette.voice(conversation.modelKey)
    }

    // MARK: Export

    /// The thread as Markdown — every voice named, rooms included.
    func markdown(for conversation: Conversation) -> String {
        var out = "# \(conversation.title)\n\n"
        if let p = project(conversation.projectID) { out += "_Project: \(p.name)_\n\n" }
        for m in conversation.messages {
            switch m.role {
            case .user:
                out += "**You**\n\n\(m.text)\n\n"
                for a in m.attachments ?? [] { out += "_Attached: \(a.name)_\n\n" }
            case .assistant:
                guard !m.text.isEmpty else { continue }
                out += "**\(m.modelLabel ?? "Assistant")**\(m.isPreferred ? " ★" : "")\n\n\(m.text)\n\n"
            case .system:
                continue
            }
        }
        return out
    }

    // MARK: Editing a previous prompt

    /// Removes the message and everything after it. The edited text is then
    /// sent as a fresh turn by the caller — the same thing "edit" means in
    /// every other chat app.
    func truncate(from messageID: UUID, in conversationID: UUID) {
        guard let i = index(of: conversationID),
              let at = conversations[i].messages.firstIndex(where: { $0.id == messageID }) else { return }
        conversations[i].messages.removeSubrange(at...)
        scheduleSave()
    }

    /// The messages that belong to the round a user message starts: itself and
    /// every answer up to the next user message.
    private func roundRange(of messageID: UUID, in conversation: Conversation) -> Range<Int>? {
        guard let at = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        let end = conversation.messages[(at + 1)...].firstIndex(where: { $0.role == .user }) ?? conversation.messages.count
        return at..<end
    }

    /// "Go back to this point": keep this round, drop everything after it.
    func rewind(to messageID: UUID, in conversationID: UUID) {
        guard let i = index(of: conversationID), let range = roundRange(of: messageID, in: conversations[i]) else { return }
        conversations[i].messages.removeSubrange(range.upperBound...)
        touch(conversationID)
    }

    /// A new thread that ends at this round — same project, model, room setup
    /// and library — so two directions can be explored from one point.
    @discardableResult
    func forkThread(at messageID: UUID, in conversationID: UUID) -> Conversation? {
        guard let i = index(of: conversationID), let range = roundRange(of: messageID, in: conversations[i]) else { return nil }
        let source = conversations[i]
        var c = Conversation(modelKey: source.modelKey)
        c.projectID = source.projectID
        c.libraryIDs = source.libraryIDs
        c.isRoom = source.isRoom
        c.roomModelKeys = source.roomModelKeys
        c.roomMode = source.roomMode
        c.synthesis = source.synthesis
        c.colorHex = source.colorHex
        c.messages = Array(source.messages[..<range.upperBound]).map { m in var copy = m; copy.id = UUID(); return copy }
        c.title = source.title + " — fork"
        conversations.insert(c, at: 0)
        selection = c.id
        scheduleSave()
        return c
    }

    func deleteRound(of messageID: UUID, in conversationID: UUID) {
        guard let i = index(of: conversationID), let range = roundRange(of: messageID, in: conversations[i]) else { return }
        conversations[i].messages.removeSubrange(range)
        touch(conversationID)
    }

    // MARK: Preferring an answer in a room

    /// One preferred answer per round. Picking again on the same answer clears it.
    func prefer(_ answerID: UUID, in conversationID: UUID) {
        guard let i = index(of: conversationID) else { return }
        let messages = conversations[i].messages
        guard let at = messages.firstIndex(where: { $0.id == answerID }) else { return }
        // The round spans from the previous user turn to the next one.
        let roundStart = messages[..<at].lastIndex(where: { $0.role == .user }) ?? 0
        let roundEnd = messages[(at + 1)...].firstIndex(where: { $0.role == .user }) ?? messages.count
        let wasPreferred = messages[at].isPreferred
        for j in roundStart..<roundEnd where conversations[i].messages[j].role == .assistant {
            conversations[i].messages[j].preferred = (j == at && !wasPreferred) ? true : nil
        }
        scheduleSave()
    }

    // MARK: Forking

    /// "Continue in chat": one answer from a room becomes the start of a
    /// single-model thread, in the same project, with that model.
    @discardableResult
    func fork(prompt: Message, answer: Message, from room: Conversation) -> Conversation {
        var c = Conversation(modelKey: answer.modelKey ?? settings.defaultModelKey)
        c.projectID = room.projectID
        c.libraryIDs = room.libraryIDs
        var user = prompt; user.id = UUID()
        var reply = answer; reply.id = UUID(); reply.isStreaming = false
        c.messages = [user, reply]
        c.title = String(prompt.text.prefix(48)).replacingOccurrences(of: "\n", with: " ")
        conversations.insert(c, at: 0)
        selection = c.id
        scheduleSave()
        return c
    }

    // MARK: Conversations

    var current: Conversation? {
        get { conversations.first(where: { $0.id == selection }) }
        set {
            guard let newValue, let i = conversations.firstIndex(where: { $0.id == newValue.id }) else { return }
            conversations[i] = newValue
        }
    }

    func index(of id: UUID) -> Int? { conversations.firstIndex(where: { $0.id == id }) }

    @discardableResult
    func newConversation(room: Bool = false, projectID: UUID? = nil) -> Conversation {
        let project = projects.first { $0.id == (projectID ?? activeProjectID) }
        var c = Conversation(modelKey: project?.defaultModelKey ?? settings.defaultModelKey)
        c.projectID = projectID ?? activeProjectID
        c.isRoom = room
        if room {
            c.title = "New room"
            c.roomModelKeys = Array(enabledModels.prefix(3).map(\.key))
        }
        conversations.insert(c, at: 0)
        selection = c.id
        scheduleSave()
        return c
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if selection == id { selection = conversations.first?.id }
        scheduleSave()
    }

    func touch(_ id: UUID) {
        guard let i = index(of: id) else { return }
        conversations[i].updatedAt = Date()
        // First user line names the thread; the user can still rename it.
        if conversations[i].title == "New chat" || conversations[i].title == "New room",
           let first = conversations[i].messages.first(where: { $0.role == .user })?.text, !first.isEmpty {
            conversations[i].title = String(first.prefix(48)).replacingOccurrences(of: "\n", with: " ")
        }
        // Newest thread first, pinned above everything.
        conversations.sort { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.updatedAt > b.updatedAt
        }
        scheduleSave()
    }

    var sortedConversations: [Conversation] { conversations }

    // MARK: Models

    var enabledModels: [ModelSpec] {
        settings.models.filter { spec in
            spec.enabled && settings.connection(for: spec.backend).enabled
        }
    }

    func label(forKey key: String) -> String {
        settings.model(key: key)?.label ?? key
    }

    func backend(forKey key: String) -> Backend? {
        settings.model(key: key)?.backend
    }

    // MARK: Library

    /// Everything a model is told before the first user word, in one place:
    /// the global preamble, the project's instructions and knowledge files,
    /// then the library items attached to the project and to this thread.
    /// Identical for every backend — that is what makes a thread portable.
    func systemPrompt(for conversation: Conversation) -> String {
        var parts: [String] = []
        let global = settings.globalSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !global.isEmpty { parts.append(global) }

        let project = conversation.projectID.flatMap { id in projects.first { $0.id == id } }
        if let project {
            let instructions = project.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if !instructions.isEmpty { parts.append("## Project: \(project.name)\n\(instructions)") }
            for file in project.files {
                parts.append("## Project file: \(file.name)\n\(file.text)")
            }
        }

        var seen = Set<UUID>()
        let ids = (project?.libraryIDs ?? []) + conversation.libraryIDs
        for id in ids where seen.insert(id).inserted {
            if let item = library.first(where: { $0.id == id }) { parts.append(item.rendered()) }
        }
        return parts.joined(separator: "\n\n---\n\n")
    }

    /// Names of everything in force, for the "what is loaded" chip under the composer.
    func appliedNames(for conversation: Conversation) -> [String] {
        let project = conversation.projectID.flatMap { id in projects.first { $0.id == id } }
        var names: [String] = []
        if let project {
            if !project.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { names.append(project.name) }
            names += project.files.map(\.name)
        }
        var seen = Set<UUID>()
        for id in (project?.libraryIDs ?? []) + conversation.libraryIDs where seen.insert(id).inserted {
            if let item = library.first(where: { $0.id == id }) { names.append(item.name) }
        }
        return names
    }

    // MARK: Projects

    @discardableResult
    func newProject() -> Project {
        var p = Project()
        p.accent = projects.count % Palette.accents.count
        p.defaultModelKey = settings.defaultModelKey
        projects.insert(p, at: 0)
        activeProjectID = p.id
        scheduleSave()
        return p
    }

    func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func update(_ project: Project) {
        guard let i = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[i] = project
        scheduleSave()
    }

    /// Deleting a project keeps its conversations; they fall back to All chats.
    func deleteProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        for i in conversations.indices where conversations[i].projectID == id {
            conversations[i].projectID = nil
        }
        if activeProjectID == id { activeProjectID = nil }
        scheduleSave()
    }

    func conversations(in projectID: UUID?) -> [Conversation] {
        guard let projectID else { return conversations }
        return conversations.filter { $0.projectID == projectID }
    }

    /// The MCP bridge runs in its own process and can add knowhow or projects
    /// while the app is open. Anything on disk that this process has never seen
    /// is adopted, so a save from the app cannot overwrite what a CLI just wrote.
    func mergeExternalWrites() {
        let dec = JSONDecoder()
        if let d = try? Data(contentsOf: libraryURL), let items = try? dec.decode([LibraryItem].self, from: d) {
            for item in items where !library.contains(where: { $0.id == item.id }) { library.append(item) }
        }
        if let d = try? Data(contentsOf: projectsURL), let items = try? dec.decode([Project].self, from: d) {
            for item in items where !projects.contains(where: { $0.id == item.id }) { projects.append(item) }
        }
    }

    func reloadLibraryFromDisk() { mergeExternalWrites() }

    func apiKey(for backend: Backend) -> String { Keychain.get(backend.rawValue) }
    func setAPIKey(_ value: String, for backend: Backend) { Keychain.set(value, for: backend.rawValue) }
}

extension LibraryItem {
    /// Two examples that show what the library is for without being noise.
    static func starters() -> [LibraryItem] {
        [
            LibraryItem(kind: .prompt, name: "House voice",
                        summary: "Tone for anything client-facing",
                        body: "Write in plain Belgian-Dutch business register. Short sentences. No filler openings, no closing summaries. Lead with the conclusion."),
            LibraryItem(kind: .skill, name: "Second opinion",
                        summary: "The user asks whether a plan or claim holds up",
                        body: "State the weakest link in the argument first. Give the concrete scenario in which it fails. Then say what you would do instead, and pick one option rather than listing trade-offs."),
        ]
    }
}
