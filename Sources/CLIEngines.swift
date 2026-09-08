// Choir — made by Sam De Herdt for MakeWaves.
import Foundation

/// Bridges to locally installed agent CLIs. These are the only backends that
/// run on the user's *subscription* rather than a metered API key, because the
/// CLI holds the OAuth session. Everything is stateless: Choir replays the whole
/// transcript every turn, which is what lets a thread change model mid-way.
enum CLI {
    /// A GUI app inherits a minimal PATH, so the usual install locations are
    /// searched explicitly before falling back to `env`.
    static func resolve(_ name: String, override: String) -> String? {
        if !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.bun/bin/\(name)",
            "\(home)/.npm-global/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func isInstalled(_ name: String, override: String = "") -> Bool { resolve(name, override: override) != nil }

    /// A neutral working directory: no repo, so no CLAUDE.md / AGENTS.md from
    /// the user's projects leaks into a chat that was never about code.
    static var workspace: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Choir/workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Both CLIs are agents that assume a repository. Without this they mention
    /// their working directory and offer to edit files, which is exactly the
    /// terminal feel the app exists to remove.
    static let chatFraming = "You are answering inside Choir, a chat app — not a terminal and not a code repository. Do not mention your working directory, sandbox, tools or session; do not offer to read or edit files. Just answer."

    /// The whole conversation as one prompt. Named speakers matter in rooms,
    /// where a model must be able to tell its own earlier turn from a rival's.
    static func transcript(_ turns: [WireTurn]) -> String {
        guard turns.count > 1 else { return turns.first?.text ?? "" }
        var out = ""
        for turn in turns.dropLast() {
            out += turn.role == "user" ? "User:\n\(turn.text)\n\n" : "Assistant:\n\(turn.text)\n\n"
        }
        out += "User:\n\(turns.last?.text ?? "")"
        return out
    }

    // MARK: Claude profiles

    /// Claude Code keeps one login per CLAUDE_CONFIG_DIR, and this Mac has more
    /// than one (~/.claude-personal, ~/.claude-work, with ~/.claude a symlink
    /// that moves between them). The credentials live in the Keychain under a
    /// per-profile hash, so the only reliable test is asking the CLI itself.
    /// Answers are cached; a failed turn clears the cache.
    enum ClaudeProfile {
        struct Info: Hashable { let dir: String; let signedIn: Bool; let email: String }
        private static var cache: (at: Date, infos: [Info])?

        static func candidates(pinned: String?) -> [String] {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var dirs: [String] = []
            if let pinned, !pinned.isEmpty { dirs.append(pinned) }
            if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty { dirs.append(env) }
            dirs += ["\(home)/.claude", "\(home)/.claude-personal", "\(home)/.claude-work"]
            var seen = Set<String>()
            return dirs.compactMap { dir in
                let real = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
                guard FileManager.default.fileExists(atPath: real), seen.insert(real).inserted else { return nil }
                return real
            }
        }

        static func invalidate() { cache = nil }

        /// Every known profile with its sign-in state. Blocking (~0.2 s per
        /// profile on first call); call off the main actor.
        static func all(executable: String, pinned: String?) -> [Info] {
            if let cache, Date().timeIntervalSince(cache.at) < 300 { return cache.infos }
            let infos = candidates(pinned: pinned).map { dir -> Info in
                let (signedIn, email) = probe(executable: executable, dir: dir)
                return Info(dir: dir, signedIn: signedIn, email: email)
            }
            cache = (Date(), infos)
            return infos
        }

        /// The profile a turn should run under: the pinned one if it is signed
        /// in, else the first signed-in profile, else the default so the CLI's
        /// own "not logged in" message comes back.
        static func resolve(executable: String, pinned: String?) -> Info? {
            let infos = all(executable: executable, pinned: pinned)
            if let pinned, !pinned.isEmpty,
               let hit = infos.first(where: { URL(fileURLWithPath: pinned).resolvingSymlinksInPath().path == $0.dir }), hit.signedIn {
                return hit
            }
            return infos.first(where: \.signedIn) ?? infos.first
        }

        private static func probe(executable: String, dir: String) -> (Bool, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = ["auth", "status"]
            var env = ProcessInfo.processInfo.environment
            env["CLAUDE_CONFIG_DIR"] = dir
            env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            p.environment = env
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            do { try p.run() } catch { return (false, "") }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (false, "") }
            return (obj["loggedIn"] as? Bool == true, (obj["email"] as? String) ?? "")
        }
    }

    /// What a failed CLI run should say. The last stderr line is usually noise
    /// ("Reading prompt from stdin…"), so pick the first line that carries
    /// meaning, and translate the two failures people actually hit.
    static func explain(stderr: String, exitCode: Int32, tool: String, profileDir: String?) -> String {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Reading") && !$0.contains("rmcp::transport") && !$0.hasPrefix("20") }
        let joined = lines.joined(separator: " ")
        if joined.localizedCaseInsensitiveContains("not logged in") || joined.localizedCaseInsensitiveContains("/login")
            || joined.localizedCaseInsensitiveContains("please run") && joined.localizedCaseInsensitiveContains("login") {
            let which = profileDir.map { " (profile \($0.replacingOccurrences(of: NSHomeDirectory(), with: "~")))" } ?? ""
            return "\(tool) is not signed in\(which). Open Terminal, run `\(tool) login`, then try again — or pick a signed-in profile in Settings › Connections."
        }
        if let first = lines.first { return first.count > 300 ? String(first.prefix(300)) + "…" : first }
        return "\(tool) exited with code \(exitCode) and said nothing. Try it once in Terminal to see why."
    }

    /// Runs a process, yielding each stdout line. stderr is collected separately so
    /// a crash can be reported with its actual message.
    static func run(executable: String, arguments: [String], stdin: String,
                    extraEnvironment: [String: String] = [:],
                    continuation: AsyncThrowingStream<Chunk, Error>.Continuation,
                    handleLine: @escaping (String) -> Void) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workspace

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for (k, v) in extraEnvironment { env[k] = v }
        // Keep the CLIs out of interactive/TUI mode.
        env["CI"] = "1"
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        process.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        // Feed the prompt on stdin so no shell quoting can mangle it.
        if let data = stdin.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        try? inPipe.fileHandleForWriting.close()

        let errorTask = Task<String, Never>.detached {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }

        var buffer = Data()
        let handle = outPipe.fileHandleForReading
        while true {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8) {
                    handleLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
            handleLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        process.waitUntilExit()
        let stderrText = await errorTask.value
        if process.terminationStatus != 0 {
            let tool = URL(fileURLWithPath: executable).lastPathComponent
            throw EngineError(message: explain(stderr: stderrText, exitCode: process.terminationStatus, tool: tool,
                                               profileDir: extraEnvironment["CLAUDE_CONFIG_DIR"]))
        }
        continuation.yield(.done)
    }
}

// MARK: - Claude Code

/// Token-by-token streaming, via `--output-format stream-json --include-partial-messages`.
struct ClaudeCLIEngine: ChatEngine {
    let executable: String

    func stream(system: String, turns: [WireTurn], model: ModelSpec, settings: AppSettings) -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    guard let bin = CLI.resolve("claude", override: executable) else {
                        throw EngineError(message: "The `claude` CLI was not found. Install Claude Code, or set its path in Settings › Connections.")
                    }
                    var args = [
                        "-p",
                        "--model", model.id,
                        "--output-format", "stream-json",
                        "--include-partial-messages",
                        "--verbose",
                        // A chat window is not an agent session: no tools, no
                        // hooks, no MCP servers, no project settings.
                        "--allowed-tools", "",
                        "--setting-sources", "",
                        "--strict-mcp-config",
                        "--disable-slash-commands",
                    ]
                    args += ["--append-system-prompt", system.isEmpty ? CLI.chatFraming : "\(CLI.chatFraming)\n\n\(system)"]

                    // Which login to use. Resolved off the main actor; cached.
                    let profile = CLI.ClaudeProfile.resolve(executable: bin, pinned: settings.connection(for: .claudeCLI).configDir)
                    var env: [String: String] = [:]
                    if let profile { env["CLAUDE_CONFIG_DIR"] = profile.dir }

                    continuation.yield(.status("Claude is starting…"))
                    var sawText = false
                    var fatal: String?
                    do {
                    try await CLI.run(executable: bin, arguments: args, stdin: CLI.transcript(turns), extraEnvironment: env, continuation: continuation) { line in
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                        switch obj["type"] as? String {
                        case "stream_event":
                            guard let event = obj["event"] as? [String: Any],
                                  event["type"] as? String == "content_block_delta",
                                  let delta = event["delta"] as? [String: Any] else { return }
                            if let t = delta["text"] as? String { sawText = true; continuation.yield(.text(t)) }
                            if let t = delta["thinking"] as? String { continuation.yield(.reasoning(t)) }
                        case "result":
                            // Only used as a fallback: partial messages already
                            // delivered the text unless the run failed.
                            if obj["is_error"] as? Bool == true {
                                fatal = (obj["result"] as? String) ?? "Claude Code reported an error."
                            } else if !sawText, let result = obj["result"] as? String {
                                continuation.yield(.text(result))
                            }
                        default: return
                        }
                    }
                    } catch {
                        CLI.ClaudeProfile.invalidate()
                        throw EngineError(message: fatal ?? error.localizedDescription)
                    }
                    if let fatal { CLI.ClaudeProfile.invalidate(); throw EngineError(message: fatal) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Codex

/// Codex reports whole items rather than token deltas, so the UI shows a live
/// status line and then the finished answer in one go. That difference is real
/// and visible; pretending otherwise would mean faking a typewriter.
struct CodexCLIEngine: ChatEngine {
    let executable: String

    func stream(system: String, turns: [WireTurn], model: ModelSpec, settings: AppSettings) -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    guard let bin = CLI.resolve("codex", override: executable) else {
                        throw EngineError(message: "The `codex` CLI was not found. Install Codex, or set its path in Settings › Connections.")
                    }
                    var args = ["exec", "--json", "--skip-git-repo-check", "-s", "read-only", "--color", "never"]
                    if !model.id.isEmpty { args += ["-m", model.id] }

                    var prompt = CLI.transcript(turns)
                    // Codex has no system-prompt flag, so instructions ride at
                    // the top of the prompt instead.
                    let instructions = system.isEmpty ? CLI.chatFraming : "\(CLI.chatFraming)\n\n\(system)"
                    prompt = "<instructions>\n\(instructions)\n</instructions>\n\n\(prompt)"

                    continuation.yield(.status("ChatGPT is thinking…"))
                    var fatal: String?
                    do {
                    try await CLI.run(executable: bin, arguments: args, stdin: prompt, continuation: continuation) { line in
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                        switch obj["type"] as? String {
                        case "item.completed":
                            guard let item = obj["item"] as? [String: Any] else { return }
                            switch item["type"] as? String {
                            case "agent_message":
                                if let t = item["text"] as? String { continuation.yield(.text(t)) }
                            case "reasoning":
                                if let t = item["text"] as? String { continuation.yield(.reasoning(t)) }
                            case "error":
                                // Codex emits advisory notices as error items;
                                // they are status, not failure.
                                if let m = item["message"] as? String { continuation.yield(.status(m)) }
                            default: return
                            }
                        case "turn.failed":
                            let err = obj["error"] as? [String: Any]
                            fatal = (err?["message"] as? String) ?? "Codex failed."
                        case "error":
                            if fatal == nil, let m = obj["message"] as? String { fatal = m }
                        default: return
                        }
                    }
                    } catch {
                        throw EngineError(message: fatal ?? error.localizedDescription)
                    }
                    if let fatal { throw EngineError(message: fatal) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Any other CLI

/// Gemini CLI, a Copilot CLI, an internal wrapper — anything that takes a prompt
/// and prints an answer. The command line is configured in Settings rather than
/// hardcoded, because inventing another tool's flags is how an app ships a
/// connection that has never once worked.
struct CustomCLIEngine: ChatEngine {
    let executable: String
    let arguments: String
    let jsonTextKey: String

    func stream(system: String, turns: [WireTurn], model: ModelSpec, settings: AppSettings) -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    guard !executable.isEmpty, FileManager.default.isExecutableFile(atPath: executable) else {
                        throw EngineError(message: "Set the path to this CLI in Settings › Connections.")
                    }
                    var prompt = CLI.transcript(turns)
                    if !system.isEmpty { prompt = "<instructions>\n\(system)\n</instructions>\n\n\(prompt)" }

                    var stdin = prompt
                    var args = arguments
                        .split(separator: " ", omittingEmptySubsequences: true)
                        .map { $0.replacingOccurrences(of: "{model}", with: model.id) }
                    if let index = args.firstIndex(where: { $0.contains("{prompt}") }) {
                        args[index] = args[index].replacingOccurrences(of: "{prompt}", with: prompt)
                        stdin = ""
                    }
                    args.removeAll { $0.isEmpty }

                    continuation.yield(.status("Running \(URL(fileURLWithPath: executable).lastPathComponent)…"))
                    var first = true
                    try await CLI.run(executable: executable, arguments: args, stdin: stdin, continuation: continuation) { line in
                        if jsonTextKey.isEmpty {
                            guard !line.isEmpty || !first else { return }
                            continuation.yield(.text(first ? line : "\n" + line))
                            first = false
                        } else {
                            guard let data = line.data(using: .utf8),
                                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  let text = value(for: jsonTextKey, in: obj) else { return }
                            continuation.yield(.text(text))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Dotted paths, so `item.text` reaches into a nested object.
    private func value(for path: String, in object: [String: Any]) -> String? {
        var node: Any = object
        for part in path.split(separator: ".") {
            guard let dict = node as? [String: Any], let next = dict[String(part)] else { return nil }
            node = next
        }
        return node as? String
    }
}
