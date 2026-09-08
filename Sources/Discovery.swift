// Choir — made by Sam De Herdt for MakeWaves.
import Foundation

/// Finds every model each connection can reach, without asking the user to
/// know model ids. Each source is something that actually exists on this Mac
/// or on the wire; nothing is guessed from a memory of what a vendor once shipped.
///
/// - Claude Code: the CLI documents its aliases in `--help`; those are used.
/// - Codex: keeps `~/.codex/models_cache.json`, refreshed by the CLI itself.
/// - Ollama: `GET /api/tags`.
/// - API backends: `/models` on the endpoint — only when a key is present.
enum ModelDiscovery {
    struct Found { let backend: Backend; let id: String; let label: String; let reasoning: Bool }

    /// Merges discoveries into settings. Existing entries keep their enabled
    /// state and label; nothing the user added by hand is ever removed.
    @MainActor
    static func refresh(store: Store) async -> Int {
        var found: [Found] = []
        for connection in store.settings.connections where connection.enabled {
            found += await discover(connection, apiKey: store.apiKey(for: connection.backend))
        }
        var added = 0
        for f in found {
            guard !store.settings.models.contains(where: { $0.backend == f.backend && $0.id == f.id }) else { continue }
            store.settings.models.append(ModelSpec(backend: f.backend, id: f.id, label: f.label, supportsReasoning: f.reasoning))
            added += 1
        }
        if added > 0 { store.scheduleSave() }
        return added
    }

    static func discover(_ connection: Connection, apiKey: String) async -> [Found] {
        switch connection.backend {
        case .claudeCLI:
            guard CLI.isInstalled("claude", override: connection.executablePath) else { return [] }
            // Aliases from `claude --help` track the newest model of each tier;
            // the explicit ids were each confirmed to answer on a subscription
            // login (2026-09-08). Fable is metered separately by Anthropic, so
            // it is listed but says so.
            return [
                Found(backend: .claudeCLI, id: "opus", label: "Claude Opus (latest)", reasoning: true),
                Found(backend: .claudeCLI, id: "sonnet", label: "Claude Sonnet (latest)", reasoning: true),
                Found(backend: .claudeCLI, id: "haiku", label: "Claude Haiku (latest)", reasoning: false),
                Found(backend: .claudeCLI, id: "claude-opus-5", label: "Claude Opus 5", reasoning: true),
                Found(backend: .claudeCLI, id: "claude-sonnet-5", label: "Claude Sonnet 5", reasoning: true),
                Found(backend: .claudeCLI, id: "claude-haiku-4-5-20251001", label: "Claude Haiku 4.5", reasoning: false),
                Found(backend: .claudeCLI, id: "fable", label: "Claude Fable (metered — uses credits)", reasoning: true),
            ]

        case .codexCLI:
            guard CLI.isInstalled("codex", override: connection.executablePath) else { return [] }
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = obj["models"] as? [[String: Any]] else { return [] }
            return models.compactMap { m in
                guard let slug = m["slug"] as? String, (m["visibility"] as? String) != "hide" else { return nil }
                let name = (m["display_name"] as? String) ?? slug
                let levels = (m["supported_reasoning_levels"] as? [[String: Any]]) ?? []
                return Found(backend: .codexCLI, id: slug, label: "\(name) (ChatGPT)", reasoning: !levels.isEmpty)
            }

        case .ollama:
            let base = connection.endpoint.hasSuffix("/") ? String(connection.endpoint.dropLast()) : connection.endpoint
            guard let url = URL(string: "\(base)/api/tags"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = obj["models"] as? [[String: Any]] else { return [] }
            return models.compactMap { m in
                guard let name = m["name"] as? String else { return nil }
                return Found(backend: .ollama, id: name, label: "\(name) (local)", reasoning: false)
            }

        case .openai, .openaiCompatible:
            guard !apiKey.isEmpty, let url = modelsURL(from: connection.endpoint, replacing: "/chat/completions", with: "/models") else { return [] }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["data"] as? [[String: Any]] else { return [] }
            return list.compactMap { m in
                guard let id = m["id"] as? String else { return nil }
                return Found(backend: connection.backend, id: id, label: id, reasoning: false)
            }

        case .anthropic:
            guard !apiKey.isEmpty, let url = modelsURL(from: connection.endpoint, replacing: "/messages", with: "/models") else { return [] }
            var req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["data"] as? [[String: Any]] else { return [] }
            return list.compactMap { m in
                guard let id = m["id"] as? String else { return nil }
                return Found(backend: .anthropic, id: id, label: (m["display_name"] as? String) ?? id, reasoning: true)
            }

        case .google:
            guard !apiKey.isEmpty else { return [] }
            let base = connection.endpoint.hasSuffix("/") ? String(connection.endpoint.dropLast()) : connection.endpoint
            guard let url = URL(string: "\(base)/models") else { return [] }
            var req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["models"] as? [[String: Any]] else { return [] }
            return list.compactMap { m in
                guard let name = m["name"] as? String else { return nil }
                let methods = (m["supportedGenerationMethods"] as? [String]) ?? []
                guard methods.contains("generateContent") else { return nil }
                let id = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
                return Found(backend: .google, id: id, label: (m["displayName"] as? String) ?? id, reasoning: false)
            }

        case .customCLI:
            return []
        }
    }

    private static func modelsURL(from endpoint: String, replacing suffix: String, with replacement: String) -> URL? {
        guard endpoint.hasSuffix(suffix) else { return nil }
        return URL(string: String(endpoint.dropLast(suffix.count)) + replacement)
    }
}

// MARK: - Where the agents look for skills

enum SkillRoots {
    struct Root: Identifiable, Hashable {
        let name: String
        let url: URL
        var id: String { url.path }
    }

    /// Only roots that exist are offered; Choir does not invent a config layout
    /// for a tool that is not installed. `~/.claude/skills` is created on demand
    /// because Claude Code reads it whether or not it exists yet.
    static func all() -> [Root] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [(String, String)] = [
            ("Claude Code", ".claude/skills"),
            ("Shared skills (~/.claude-shared)", ".claude-shared/skills"),
            ("Codex", ".codex/skills"),
            ("Agents (~/.agents)", ".agents/skills"),
        ]
        return candidates.compactMap { name, rel in
            let url = home.appendingPathComponent(rel, isDirectory: true)
            let parent = url.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: parent.path) else { return nil }
            return Root(name: name, url: url)
        }
    }
}

// MARK: - Skills already on this Mac

/// The skills the user has written for Claude Code and Codex are the same kind
/// of thing as a Choir skill — a name, a when-to-use line, and a body. Import
/// them once and every model in Choir can use them, not only the CLI they were
/// written for.
enum SkillImporter {
    struct Candidate: Identifiable, Hashable {
        var id: String { path }
        let name: String
        let summary: String
        let body: String
        let path: String
        let source: String
    }

    /// The directories the CLIs read skills from. Several are symlinks of one
    /// another, so results are de-duplicated on the resolved path.
    static var roots: [(String, URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            ("Claude Code", home.appendingPathComponent(".claude/skills")),
            ("Claude Code", home.appendingPathComponent(".claude-shared/skills")),
            ("Claude Code", home.appendingPathComponent(".claude-personal/skills")),
            ("Claude Code", home.appendingPathComponent(".claude-work/skills")),
            ("Codex", home.appendingPathComponent(".codex/skills")),
            ("Agents", home.appendingPathComponent(".agents/skills")),
        ]
    }

    static func scan() -> [Candidate] {
        var seen = Set<String>()
        var out: [Candidate] = []
        let fm = FileManager.default
        for (source, root) in roots {
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for dir in entries {
                let file = dir.appendingPathComponent("SKILL.md")
                let resolved = file.resolvingSymlinksInPath().path
                guard fm.fileExists(atPath: resolved), seen.insert(resolved).inserted,
                      let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let (front, body) = splitFrontmatter(text)
                let name = front["name"] ?? dir.lastPathComponent
                out.append(Candidate(name: name, summary: front["description"] ?? "", body: body, path: resolved, source: source))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// YAML frontmatter, the two keys skills actually use. Quoted values lose
    /// their quotes; anything more exotic is left as written.
    static func splitFrontmatter(_ text: String) -> ([String: String], String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([:], text)
        }
        var front: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            front[key] = value
        }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (front, body)
    }
}
