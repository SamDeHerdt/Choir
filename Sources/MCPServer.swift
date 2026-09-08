// Choir — made by Sam De Herdt for MakeWaves.
import Foundation

/// `Choir.app/Contents/MacOS/Choir --mcp-server` speaks MCP over stdio, serving
/// the same library and history the app shows. That is the bridge the models use
/// to reach each other's material: Claude Code, Codex or any MCP client can list
/// the shared prompts, read a skill, search past conversations, and file new
/// knowhow back into the library.
///
/// It is a separate short-lived process reading the same JSON on disk, so the
/// app reloads from disk whenever it becomes active.
struct MCPServer {
    private let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Choir", isDirectory: true)
    }()

    private var libraryURL: URL { dir.appendingPathComponent("library.json") }
    private var conversationsURL: URL { dir.appendingPathComponent("conversations.json") }
    private var projectsURL: URL { dir.appendingPathComponent("projects.json") }

    private func loadProjects() -> [Project] {
        guard let d = try? Data(contentsOf: projectsURL),
              let items = try? JSONDecoder().decode([Project].self, from: d) else { return [] }
        return items
    }

    private func writeProjects(_ items: [Project]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        try enc.encode(items).write(to: projectsURL, options: .atomic)
    }

    // MARK: Disk

    private func loadLibrary() -> [LibraryItem] {
        guard let d = try? Data(contentsOf: libraryURL),
              let items = try? JSONDecoder().decode([LibraryItem].self, from: d) else { return [] }
        return items
    }

    private func loadConversations() -> [Conversation] {
        guard let d = try? Data(contentsOf: conversationsURL),
              let items = try? JSONDecoder().decode([Conversation].self, from: d) else { return [] }
        return items
    }

    private func writeLibrary(_ items: [LibraryItem]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        try enc.encode(items).write(to: libraryURL, options: .atomic)
    }

    // MARK: Loop

    func run() {
        let stdin = FileHandle.standardInput
        var buffer = Data()
        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = Data(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !lineData.isEmpty else { continue }
                handle(lineData)
            }
        }
    }

    private func handle(_ data: Data) {
        guard let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = req["method"] as? String else { return }
        let id = req["id"]
        let params = req["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let version = (params["protocolVersion"] as? String) ?? "2025-06-18"
            respond(id: id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "choir", "version": "1.0"],
            ])
        case "notifications/initialized", "notifications/cancelled":
            return  // notifications carry no id and take no reply
        case "ping":
            respond(id: id, result: [:])
        case "tools/list":
            respond(id: id, result: ["tools": toolDefinitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                respond(id: id, result: ["content": [["type": "text", "text": try call(name, args)]]])
            } catch {
                respond(id: id, result: [
                    "isError": true,
                    "content": [["type": "text", "text": error.localizedDescription]],
                ])
            }
        default:
            guard id != nil else { return }
            respond(id: id, error: ["code": -32601, "message": "Unknown method \(method)"])
        }
    }

    private func respond(id: Any?, result: [String: Any]? = nil, error: [String: Any]? = nil) {
        var payload: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull()]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    // MARK: Tools

    private var toolDefinitions: [[String: Any]] {
        [
            [
                "name": "list_library",
                "description": "List the shared prompts, skills and knowhow stored in Choir. These are written once and used by every model.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["kind": ["type": "string", "enum": ["prompt", "skill", "knowhow"], "description": "Optional filter."]],
                ] as [String: Any],
            ],
            [
                "name": "get_library_item",
                "description": "Read the full text of one prompt, skill or knowhow entry by name.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["name": ["type": "string", "description": "The item's name, as returned by list_library."]],
                    "required": ["name"],
                ] as [String: Any],
            ],
            [
                "name": "search_history",
                "description": "Search every past Choir conversation — across all models — for a phrase. Use this to recall what was already decided or tried, whichever model was talking at the time.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "limit": ["type": "integer", "description": "Maximum matches to return. Default 8."],
                    ],
                    "required": ["query"],
                ] as [String: Any],
            ],
            [
                "name": "get_conversation",
                "description": "Read a full Choir conversation by its title, including which model wrote each turn.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["title": ["type": "string"]],
                    "required": ["title"],
                ] as [String: Any],
            ],
            [
                "name": "list_projects",
                "description": "List Choir projects — each is a container of instructions, knowledge files, library items and conversations shared by every model.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]] as [String: Any],
            ],
            [
                "name": "get_project",
                "description": "Everything a project holds: its instructions, the names and sizes of its knowledge files, the library items attached, and its conversations. Pass include_files to get the file text too.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "include_files": ["type": "boolean", "description": "Return the full text of knowledge files. Default false."],
                    ],
                    "required": ["name"],
                ] as [String: Any],
            ],
            [
                "name": "create_project",
                "description": "Create a Choir project. Give it instructions now if you know what it is for; files and library items can be attached in the app later.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "summary": ["type": "string", "description": "One line on what the project is for."],
                        "instructions": ["type": "string", "description": "Standing instructions every model gets inside this project."],
                    ],
                    "required": ["name"],
                ] as [String: Any],
            ],
            [
                "name": "update_project",
                "description": "Change a project's summary or instructions, or add a text note as a knowledge file.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Which project."],
                        "summary": ["type": "string"],
                        "instructions": ["type": "string", "description": "Replaces the current instructions."],
                        "add_file_name": ["type": "string", "description": "Name for a note to add as a knowledge file."],
                        "add_file_text": ["type": "string", "description": "Its text."],
                    ],
                    "required": ["name"],
                ] as [String: Any],
            ],
            [
                "name": "save_knowhow",
                "description": "Write a durable fact or convention into Choir's shared library so every other model can read it later.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "summary": ["type": "string", "description": "One line on when this matters."],
                        "body": ["type": "string"],
                    ],
                    "required": ["name", "body"],
                ] as [String: Any],
            ],
        ]
    }

    private func call(_ name: String, _ args: [String: Any]) throws -> String {
        switch name {
        case "list_library":
            let kindFilter = (args["kind"] as? String).flatMap(LibraryItem.Kind.init(rawValue:))
            let items = loadLibrary().filter { kindFilter == nil || $0.kind == kindFilter }
            guard !items.isEmpty else { return "The library is empty." }
            return items.map { "- [\($0.kind.label)] \($0.name)\($0.summary.isEmpty ? "" : " — \($0.summary)")" }
                .joined(separator: "\n")

        case "get_library_item":
            guard let wanted = args["name"] as? String else { throw EngineError(message: "name is required.") }
            guard let item = loadLibrary().first(where: { $0.name.lowercased() == wanted.lowercased() }) else {
                throw EngineError(message: "No library item named \"\(wanted)\".")
            }
            return item.rendered()

        case "search_history":
            guard let query = args["query"] as? String, !query.isEmpty else { throw EngineError(message: "query is required.") }
            let limit = (args["limit"] as? Int) ?? 8
            var hits: [String] = []
            for c in loadConversations() {
                for m in c.messages where m.text.localizedCaseInsensitiveContains(query) {
                    let who = m.role == .user ? "You" : (m.modelLabel ?? "Assistant")
                    hits.append("### \(c.title) — \(who)\n\(excerpt(m.text, around: query))")
                    if hits.count >= limit { break }
                }
                if hits.count >= limit { break }
            }
            return hits.isEmpty ? "No conversation mentions \"\(query)\"." : hits.joined(separator: "\n\n")

        case "get_conversation":
            guard let title = args["title"] as? String else { throw EngineError(message: "title is required.") }
            guard let c = loadConversations().first(where: { $0.title.localizedCaseInsensitiveContains(title) }) else {
                throw EngineError(message: "No conversation titled \"\(title)\".")
            }
            return c.messages.map { m in
                let who = m.role == .user ? "You" : (m.modelLabel ?? "Assistant")
                return "**\(who)**\n\(m.text)"
            }.joined(separator: "\n\n")

        case "list_projects":
            let projects = loadProjects()
            guard !projects.isEmpty else { return "There are no projects yet." }
            let conversations = loadConversations()
            return projects.map { p in
                let n = conversations.filter { $0.projectID == p.id }.count
                return "- \(p.name)\(p.summary.isEmpty ? "" : " — \(p.summary)") · \(p.files.count) file(s), \(n) conversation(s)"
            }.joined(separator: "\n")

        case "get_project":
            guard let wanted = args["name"] as? String else { throw EngineError(message: "name is required.") }
            guard let p = loadProjects().first(where: { $0.name.localizedCaseInsensitiveContains(wanted) }) else {
                throw EngineError(message: "No project named \"\(wanted)\".")
            }
            let includeFiles = (args["include_files"] as? Bool) ?? false
            let library = loadLibrary().filter { p.libraryIDs.contains($0.id) }
            let conversations = loadConversations().filter { $0.projectID == p.id }
            var out = "# \(p.name)\n"
            if !p.summary.isEmpty { out += "\(p.summary)\n" }
            out += "\n## Instructions\n\(p.instructions.isEmpty ? "(none)" : p.instructions)\n"
            out += "\n## Knowledge files\n"
            out += p.files.isEmpty ? "(none)\n" : p.files.map { f in
                includeFiles ? "### \(f.name)\n\(f.text)\n" : "- \(f.name) (~\(f.approxTokens) tokens)"
            }.joined(separator: "\n") + "\n"
            out += "\n## Library attached\n"
            out += library.isEmpty ? "(none)\n" : library.map { "- [\($0.kind.label)] \($0.name)" }.joined(separator: "\n") + "\n"
            out += "\n## Conversations\n"
            out += conversations.isEmpty ? "(none)" : conversations.map { "- \($0.title) (\($0.messages.count) messages)" }.joined(separator: "\n")
            return out

        case "create_project":
            guard let projectName = args["name"] as? String, !projectName.isEmpty else { throw EngineError(message: "name is required.") }
            var projects = loadProjects()
            guard !projects.contains(where: { $0.name.lowercased() == projectName.lowercased() }) else {
                throw EngineError(message: "A project named \"\(projectName)\" already exists.")
            }
            var p = Project()
            p.name = projectName
            p.summary = (args["summary"] as? String) ?? ""
            p.instructions = (args["instructions"] as? String) ?? ""
            p.accent = projects.count % 6
            projects.insert(p, at: 0)
            try writeProjects(projects)
            return "Created project \"\(projectName)\". It appears in Choir's sidebar the next time the app is in front."

        case "update_project":
            guard let wanted = args["name"] as? String else { throw EngineError(message: "name is required.") }
            var projects = loadProjects()
            guard let i = projects.firstIndex(where: { $0.name.localizedCaseInsensitiveContains(wanted) }) else {
                throw EngineError(message: "No project named \"\(wanted)\".")
            }
            var changes: [String] = []
            if let v = args["summary"] as? String { projects[i].summary = v; changes.append("summary") }
            if let v = args["instructions"] as? String { projects[i].instructions = v; changes.append("instructions") }
            if let fileName = args["add_file_name"] as? String, let text = args["add_file_text"] as? String, !text.isEmpty {
                projects[i].files.removeAll { $0.name == fileName }
                projects[i].files.append(ProjectFile(name: fileName, text: text))
                changes.append("file \(fileName)")
            }
            guard !changes.isEmpty else { return "Nothing to change." }
            try writeProjects(projects)
            return "Updated \(projects[i].name): \(changes.joined(separator: ", "))."

        case "save_knowhow":
            guard let itemName = args["name"] as? String, let body = args["body"] as? String else {
                throw EngineError(message: "name and body are required.")
            }
            var items = loadLibrary()
            let summary = (args["summary"] as? String) ?? ""
            if let i = items.firstIndex(where: { $0.name.lowercased() == itemName.lowercased() && $0.kind == .knowhow }) {
                items[i].body = body
                items[i].summary = summary
                items[i].updatedAt = Date()
            } else {
                items.append(LibraryItem(kind: .knowhow, name: itemName, summary: summary, body: body))
            }
            try writeLibrary(items)
            return "Saved \"\(itemName)\" to the shared library."

        default:
            throw EngineError(message: "Unknown tool \(name).")
        }
    }

    /// Enough context around the hit to judge relevance without dumping the turn.
    private func excerpt(_ text: String, around query: String) -> String {
        guard let range = text.range(of: query, options: .caseInsensitive) else { return String(text.prefix(400)) }
        let start = text.index(range.lowerBound, offsetBy: -200, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 200, limitedBy: text.endIndex) ?? text.endIndex
        let lead = start == text.startIndex ? "" : "…"
        let tail = end == text.endIndex ? "" : "…"
        return lead + String(text[start..<end]) + tail
    }
}
