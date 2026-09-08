// Choir — made by Sam De Herdt for MakeWaves.
import Foundation

/// A wire payload: role plus text. Reasoning is never sent back up.
struct WireTurn {
    let role: String
    let text: String
}

protocol ChatEngine {
    func stream(system: String, turns: [WireTurn], model: ModelSpec, settings: AppSettings) -> AsyncThrowingStream<Chunk, Error>
}

enum EngineFactory {
    static func engine(for backend: Backend, settings: AppSettings, apiKey: @escaping (Backend) -> String) -> ChatEngine {
        let conn = settings.connection(for: backend)
        switch backend {
        case .anthropic: return AnthropicEngine(endpoint: conn.endpoint, key: apiKey(.anthropic))
        case .openai: return OpenAIEngine(endpoint: conn.endpoint, key: apiKey(.openai))
        case .openaiCompatible: return OpenAIEngine(endpoint: conn.endpoint, key: apiKey(.openaiCompatible))
        case .google: return GoogleEngine(base: conn.endpoint, key: apiKey(.google))
        case .ollama: return OllamaEngine(base: conn.endpoint)
        case .claudeCLI: return ClaudeCLIEngine(executable: conn.executablePath)
        case .codexCLI: return CodexCLIEngine(executable: conn.executablePath)
        case .customCLI: return CustomCLIEngine(executable: conn.executablePath, arguments: conn.arguments, jsonTextKey: conn.jsonTextKey)
        }
    }
}

// MARK: - HTTP plumbing

enum HTTP {
    /// One place where a bad status becomes a readable error instead of an
    /// empty stream. Returns the byte stream only when the server said 2xx.
    static func lines(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EngineError(message: "No HTTP response from \(request.url?.host ?? "server").")
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 1200 { break }
            }
            throw EngineError(message: "HTTP \(http.statusCode) — \(body.isEmpty ? "no detail returned" : body)")
        }
        return bytes
    }

    /// Strips the `data: ` prefix; returns nil for comments, blanks and [DONE].
    static func sseJSON(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    static func body(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict)
    }
}

// MARK: - Anthropic

struct AnthropicEngine: ChatEngine {
    let endpoint: String
    let key: String

    func stream(system: String, turns: [WireTurn], model: ModelSpec, settings: AppSettings) -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    guard !key.isEmpty else { throw EngineError(message: "No Anthropic API key. Add one in Settings › Connections.") }
                    guard let url = URL(string: endpoint) else { throw EngineError(message: "Invalid Anthropic endpoint.") }
                    var body: [String: Any] = [
                        "model": model.id,
                        "max_tokens": settings.maxTokens,
                        "stream": true,
                        "messages": turns.map { ["role": $0.role, "content": $0.text] },
                    ]
                    if !system.isEmpty { body["system"] = system }
                    if settings.temperature != 1.0 { body["temperature"] = settings.temperature }

                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.setValue(key, forHTTPHeaderField: "x-api-key")
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    req.httpBody = try HTTP.body(body)

                    for try await line in try await HTTP.lines(req).lines {
                        try Task.checkCancellation()
                        guard let obj = HTTP.sseJSON(line) else { continue }
                        switch obj["type"] as? String {
                        case "content_block_delta":
                            guard let delta = obj["delta"] as? [String: Any] else { break }
                            if let t = delta["text"] as? String { continuation.yield(.text(t)) }
                            if let t = delta["thinking"] as? String { continuation.yield(.reasoning(t)) }
                        case "error":
                            let err = obj["error"] as? [String: Any]
                            throw EngineError(message: (err?["message"] as? String) ?? "Anthropic returned an error.")
                        default: break
                        }
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - OpenAI and compatible endpoints

struct OpenAIEngine: ChatEngine {
    let endpoint: String
    let key: String

    func stream(system: String, turns: [WireTurn], model: ModelSpec, settings: AppSettings) -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    guard !key.isEmpty else { throw EngineError(message: "No API key for this endpoint. Add one in Settings › Connections.") }
                    guard let url = URL(string: endpoint) else { throw EngineError(message: "Invalid endpoint URL.") }
                    var messages: [[String: Any]] = []
                    if !system.isEmpty { messages.append(["role": "system", "content": system]) }
                    messages += turns.map { ["role": $0.role, "content": $0.text] }
                    var body: [String: Any] = ["model": model.id, "stream": true, "messages": messages]
                    if settings.temperature != 1.0 { body["temperature"] = settings.temperature }

                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
                    req.httpBody = try HTTP.body(body)

                    for try await line in try await HTTP.lines(req).lines {
                        try Task.checkCancellation()
                        guard let obj = HTTP.sseJSON(line) else { continue }
                        if let err = obj["error"] as? [String: Any] {
                            throw EngineError(message: (err["message"] as? String) ?? "The endpoint returned an error.")
                        }
                        guard let choices = obj["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any] else { continue }
                        // OpenRouter and others expose reasoning on the same delta.
                        if let r = delta["reasoning"] as? String, !r.isEmpty { continuation.yield(.reasoning(r)) }
                        if let c = delta["content"] as? String, !c.isEmpty { continuation.yield(.text(c)) }
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Google

struct GoogleEngine: ChatEngine {
    let base: String
    let key: String

    func stream(system: String, turns: [WireTurn], model: ModelSpec, settings: AppSettings) -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    guard !key.isEmpty else { throw EngineError(message: "No Google API key. Add one in Settings › Connections.") }
                    let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
                    guard let url = URL(string: "\(trimmed)/models/\(model.id):streamGenerateContent?alt=sse") else {
                        throw EngineError(message: "Invalid Google endpoint.")
                    }
                    var body: [String: Any] = [
                        "contents": turns.map { turn in
                            ["role": turn.role == "assistant" ? "model" : "user",
                             "parts": [["text": turn.text]]]
                        }
                    ]
                    if !system.isEmpty {
                        body["systemInstruction"] = ["parts": [["text": system]]]
                    }
                    if settings.temperature != 1.0 {
                        body["generationConfig"] = ["temperature": settings.temperature]
                    }

                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                    req.httpBody = try HTTP.body(body)

                    for try await line in try await HTTP.lines(req).lines {
                        try Task.checkCancellation()
                        guard let obj = HTTP.sseJSON(line) else { continue }
                        guard let candidates = obj["candidates"] as? [[String: Any]],
                              let content = candidates.first?["content"] as? [String: Any],
                              let parts = content["parts"] as? [[String: Any]] else { continue }
                        for part in parts {
                            guard let text = part["text"] as? String, !text.isEmpty else { continue }
                            if part["thought"] as? Bool == true {
                                continuation.yield(.reasoning(text))
                            } else {
                                continuation.yield(.text(text))
                            }
                        }
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Ollama (local, NDJSON rather than SSE)

struct OllamaEngine: ChatEngine {
    let base: String

    func stream(system: String, turns: [WireTurn], model: ModelSpec, settings: AppSettings) -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
                    guard let url = URL(string: "\(trimmed)/api/chat") else { throw EngineError(message: "Invalid Ollama URL.") }
                    var messages: [[String: Any]] = []
                    if !system.isEmpty { messages.append(["role": "system", "content": system]) }
                    messages += turns.map { ["role": $0.role, "content": $0.text] }
                    var options: [String: Any] = ["num_predict": settings.maxTokens]
                    if settings.temperature != 1.0 { options["temperature"] = settings.temperature }
                    let body: [String: Any] = ["model": model.id, "stream": true, "messages": messages, "options": options]

                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.httpBody = try HTTP.body(body)

                    for try await line in try await HTTP.lines(req).lines {
                        try Task.checkCancellation()
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let err = obj["error"] as? String { throw EngineError(message: err) }
                        if let msg = obj["message"] as? [String: Any] {
                            if let t = msg["thinking"] as? String, !t.isEmpty { continuation.yield(.reasoning(t)) }
                            if let c = msg["content"] as? String, !c.isEmpty { continuation.yield(.text(c)) }
                        }
                        if obj["done"] as? Bool == true { break }
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch let error as URLError where error.code == .cannotConnectToHost {
                    continuation.finish(throwing: EngineError(message: "Ollama is not running. Start it with `ollama serve`."))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
