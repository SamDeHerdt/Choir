// Choir — made by Sam De Herdt for MakeWaves.
import Foundation

// MARK: - Providers

/// How Choir reaches a model. Two families with very different billing:
/// `.http` backends bill per token against an API key; `.cli` backends shell out
/// to a locally installed agent CLI and therefore run on the user's own
/// subscription. `.ollama` costs nothing and runs offline.
enum Backend: String, Codable, Hashable, CaseIterable {
    /// Ordered by what costs nothing extra first: the CLIs run on subscriptions
    /// you already pay for, Ollama runs locally, and only the last three bill
    /// per token against an API key.
    case claudeCLI, codexCLI, customCLI, ollama, anthropic, openai, google, openaiCompatible

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .google: return "Google"
        case .ollama: return "Ollama"
        case .openaiCompatible: return "OpenAI-compatible"
        case .claudeCLI: return "Claude — via Claude Code"
        case .codexCLI: return "ChatGPT — via Codex"
        case .customCLI: return "Another CLI"
        }
    }

    /// Shown in Settings so nobody has to guess what a connection actually costs.
    var billing: String {
        switch self {
        case .anthropic, .openai, .google, .openaiCompatible: return "API key — billed per token"
        case .ollama: return "Local — free, offline"
        case .claudeCLI: return "Your Claude subscription — no credits"
        case .codexCLI: return "Your ChatGPT subscription — no credits"
        case .customCLI: return "Whatever that CLI is signed in to"
        }
    }

    var needsAPIKey: Bool {
        switch self {
        case .anthropic, .openai, .google, .openaiCompatible: return true
        case .ollama, .claudeCLI, .codexCLI, .customCLI: return false
        }
    }

    var symbol: String {
        switch self {
        case .anthropic: return "a.circle.fill"
        case .openai: return "circle.hexagongrid.fill"
        case .google: return "sparkle"
        case .ollama: return "desktopcomputer"
        case .openaiCompatible: return "point.3.connected.trianglepath.dotted"
        case .claudeCLI: return "sparkle"
        case .codexCLI: return "bubble.left.and.bubble.right.fill"
        case .customCLI: return "point.3.connected.trianglepath.dotted"
        }
    }

    /// Sensible defaults; every one is editable in Settings because model ids move.
    var defaultEndpoint: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com/v1/messages"
        case .openai: return "https://api.openai.com/v1/chat/completions"
        case .google: return "https://generativelanguage.googleapis.com/v1beta"
        case .ollama: return "http://127.0.0.1:11434"
        case .openaiCompatible: return "https://openrouter.ai/api/v1/chat/completions"
        case .claudeCLI, .codexCLI, .customCLI: return ""
        }
    }
}

/// One selectable model. `id` is what the backend expects on the wire.
struct ModelSpec: Codable, Hashable, Identifiable {
    var backend: Backend
    var id: String
    var label: String
    var supportsReasoning: Bool = false
    var enabled: Bool = true

    var key: String { "\(backend.rawValue)/\(id)" }

    /// Two ids that are really the same model — `opus` and `claude-opus-5`,
    /// say — share a family, so a room never seats the same voice twice.
    var family: String {
        let lowered = id.lowercased()
        for tier in ["fable", "opus", "sonnet", "haiku"] where lowered.contains(tier) {
            return "claude-\(tier)"
        }
        return lowered.isEmpty ? backend.rawValue : lowered
    }

    /// Only subscription and local models are seeded. Anything that would
    /// spend credits has to be added deliberately in Settings › Models.
    static func seed() -> [ModelSpec] {
        [
            ModelSpec(backend: .claudeCLI, id: "opus", label: "Claude Opus (latest)", supportsReasoning: true),
            ModelSpec(backend: .claudeCLI, id: "sonnet", label: "Claude Sonnet (latest)", supportsReasoning: true),
            ModelSpec(backend: .claudeCLI, id: "haiku", label: "Claude Haiku (latest)"),
            ModelSpec(backend: .codexCLI, id: "", label: "ChatGPT (Codex default)"),
        ]
    }
}

// MARK: - Conversation

enum Role: String, Codable { case user, assistant, system }

struct Message: Codable, Hashable, Identifiable {
    var id = UUID()
    var role: Role
    var text: String
    var reasoning: String = ""
    /// Which model produced this. Nil for user turns.
    var modelKey: String?
    var modelLabel: String?
    var createdAt = Date()
    var isStreaming = false
    var error: String?
    /// Names of library items that were in force for this turn — so a thread
    /// stays readable after the library changes underneath it.
    var appliedLibrary: [String] = []
    /// Rooms: the answer the user picked in this round. From then on every
    /// model in the room sees it and is asked to go further from it.
    /// Optional so conversations saved before this field existed still decode.
    var preferred: Bool?
    /// Files dropped onto this message. Only their text travels to the model.
    /// Optional so older threads still decode.
    var attachments: [ProjectFile]?
    /// When the model started, first spoke, and finished — for the work line.
    var startedAt: Date?
    var firstTokenAt: Date?
    var finishedAt: Date?

    var isPreferred: Bool { preferred == true }
}

/// A file dropped into a project. Only the extracted text travels to a model,
/// so a 40 MB PDF costs what its words cost and nothing more.
struct ProjectFile: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var text: String
    var addedAt = Date()

    var approxTokens: Int { max(1, text.count / 4) }
}

/// The container every platform has under a different name — Claude Projects,
/// ChatGPT Projects, Gemini Gems — except here one project serves every model.
/// Instructions, knowledge files, library items and conversations live together
/// and are replayed to whichever model is answering.
struct Project: Codable, Hashable, Identifiable {
    var id = UUID()
    var name = "New project"
    var summary = ""
    var instructions = ""
    var libraryIDs: [UUID] = []
    var files: [ProjectFile] = []
    var defaultModelKey: String?
    /// Index into `Palette.accents`, so projects are told apart at a glance.
    var accent = 0
    /// Free colour from the picker, as #RRGGBB. Wins over `accent`.
    var colorHex: String?
    var createdAt = Date()

    var knowledgeTokens: Int { files.reduce(0) { $0 + $1.approxTokens } }
}

struct Conversation: Codable, Hashable, Identifiable {
    var id = UUID()
    var projectID: UUID?
    var title = "New chat"
    var messages: [Message] = []
    var modelKey: String
    /// Library item ids attached to this thread. They travel with the thread,
    /// not with the model — switching model mid-conversation keeps them.
    var libraryIDs: [UUID] = []
    var createdAt = Date()
    var updatedAt = Date()
    var isRoom = false
    /// Rooms only: the panel of models answering.
    var roomModelKeys: [String] = []
    var roomMode: RoomMode = .parallel
    var pinned = false
    /// Optional colour override; nil means "the model's colour" (chat) or the
    /// project's colour. Optional so saved threads without it still decode.
    var accent: Int?
    /// Free colour from the picker, as #RRGGBB. Wins over `accent`.
    var colorHex: String?
    /// Rooms: run the synthesis pass after each round. nil means yes.
    var synthesis: Bool?

    var preview: String {
        messages.last(where: { $0.role == .user })?.text.replacingOccurrences(of: "\n", with: " ") ?? "Empty"
    }
}

enum RoomMode: String, Codable, CaseIterable {
    /// Every model answers the same prompt, blind to the others.
    case parallel
    /// Models answer in order, each reading what came before.
    case relay
    /// Relay, then one model writes the synthesis.
    case debate

    var label: String {
        switch self {
        case .parallel: return "Parallel"
        case .relay: return "Relay"
        case .debate: return "Debate"
        }
    }

    var explainer: String {
        switch self {
        case .parallel: return "Every model answers the same prompt, blind to the others. Best for comparing."
        case .relay: return "Each model answers in turn, reading everything said before it. Best for building."
        case .debate: return "A relay round, then one model writes the synthesis. Best for deciding."
        }
    }
}

// MARK: - Shared library

/// A prompt or skill stored once and usable by every model. This is the part
/// that makes the app more than a model switcher: the instructions live with
/// the user, not inside one vendor's account.
struct LibraryItem: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        /// A reusable instruction block. `skill` adds a when-to-use header so a
        /// model can judge whether it applies; `knowhow` is standing context —
        /// facts about the company, the client, the stack.
        case prompt, skill, knowhow

        var label: String {
            switch self {
            case .prompt: return "Prompt"
            case .skill: return "Skill"
            case .knowhow: return "Knowhow"
            }
        }

        var symbol: String {
            switch self {
            case .prompt: return "text.quote"
            case .skill: return "wand.and.stars"
            case .knowhow: return "books.vertical.fill"
            }
        }

        var plural: String {
            switch self {
            case .prompt: return "Prompts"
            case .skill: return "Skills"
            case .knowhow: return "Knowhow"
            }
        }
    }

    var id = UUID()
    var kind: Kind = .prompt
    var name: String = "Untitled"
    var summary: String = ""
    var body: String = ""
    var updatedAt = Date()

    /// How the item is handed to a model. Skills get a name + when-to-use
    /// header so a model can decide whether it applies; prompts are injected raw.
    func rendered() -> String {
        switch kind {
        case .prompt:
            return body
        case .skill:
            var out = "## Skill: \(name)\n"
            if !summary.isEmpty { out += "Use this when: \(summary)\n" }
            out += "\n\(body)"
            return out
        case .knowhow:
            var out = "## Knowhow: \(name)\n"
            if !summary.isEmpty { out += "\(summary)\n" }
            out += "\n\(body)"
            return out
        }
    }
}

// MARK: - Settings

struct Connection: Codable, Hashable {
    var backend: Backend
    var endpoint: String
    /// Only for CLI backends; empty means "find it in the usual places".
    var executablePath: String = ""
    /// `customCLI` only. Space-separated arguments; `{model}` is substituted,
    /// and `{prompt}` if present — otherwise the prompt is written to stdin.
    /// Left configurable on purpose: guessing another tool's flags is how an
    /// app ships a feature that has never worked.
    var arguments: String = ""
    /// `customCLI` only. Empty means the CLI prints plain text. Otherwise every
    /// stdout line is parsed as JSON and this key is read from it.
    var jsonTextKey: String = ""
    var enabled: Bool = true
    /// `claudeCLI` only: a pinned CLAUDE_CONFIG_DIR. Nil = use whichever
    /// profile on this Mac is signed in.
    var configDir: String?
}

struct AppSettings: Codable {
    var connections: [Connection] = Backend.allCases.map { Connection(backend: $0, endpoint: $0.defaultEndpoint) }
    var models: [ModelSpec] = ModelSpec.seed()
    var defaultModelKey: String = "claudeCLI/sonnet"

    var globalSystemPrompt: String = ""
    var temperature: Double = 1.0
    var maxTokens: Int = 4096
    var showReasoning: Bool = true
    var reduceMotion: Bool = false
    /// Where the window was when Choir last quit: "conversation:<uuid>",
    /// "project:<uuid>" or "library".
    var lastRoute: String = ""
    /// Where "Report a problem" files issues. Nil = Choir's own repo.
    var bugRepo: String?
    /// The first-run connection guide has been shown (or skipped).
    var setupSeen: Bool?
    var tourSeen: Bool?
    /// First launch shows the tour once. Optional so older settings decode.
    var hasSeenTour: Bool?

    func connection(for backend: Backend) -> Connection {
        connections.first(where: { $0.backend == backend }) ?? Connection(backend: backend, endpoint: backend.defaultEndpoint)
    }

    func model(key: String) -> ModelSpec? { models.first(where: { $0.key == key }) }
}

// MARK: - Streaming

enum Chunk {
    case text(String)
    case reasoning(String)
    /// A status line the UI can show while nothing is streaming yet.
    case status(String)
    case done
}

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
