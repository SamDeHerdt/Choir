// Choir — made by Sam De Herdt for MakeWaves.
import SwiftUI
import AppKit

/// "Report a problem": a screenshot of the window, what went wrong, what was
/// expected, a few facts about the setup — filed as a GitHub issue so every
/// report lands in one log. Conversation text is never included.
enum BugReporter {
    static let defaultRepo = "SamDeHerdt/Choir"

    struct Report: Identifiable {
        let id = UUID()
        var title: String
        var whatHappened: String
        var expected: String
        var includeScreenshot = true
        var includeDiagnostics = true
        var screenshot: Data?
        var diagnostics: String
    }

    // MARK: Token

    /// The GitHub token: one saved in Settings (Keychain) wins; otherwise the
    /// `gh` CLI's login on this Mac. Nothing else is tried.
    static func token() -> String? {
        let saved = Keychain.get("github")
        if !saved.isEmpty { return saved }
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "\(NSHomeDirectory())/.local/bin/gh"] where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["auth", "token"]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            guard (try? p.run()) != nil else { continue }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0, let t = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        }
        return nil
    }

    // MARK: Screenshot

    /// Renders the app's own window — no screen-recording permission needed,
    /// because it is our view hierarchy, not the screen.
    @MainActor
    static func capture() -> Data? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let view = window.contentView else { return nil }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [.compressionFactor: 0.9])
    }

    // MARK: Diagnostics

    @MainActor
    static func diagnostics(store: Store, conductor: Conductor, usage: UsageMonitor) -> String {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let backends = Backend.allCases.filter { b in store.enabledModels.contains { $0.backend == b } }.map(\.displayName)
        let current = store.current.map { c -> String in
            c.isRoom ? "room · \(c.roomMode.label) · \(c.roomModelKeys.joined(separator: ", "))" : "chat · \(c.modelKey)"
        } ?? "none"
        // The last few error strings only — never message text.
        let errors = store.conversations.flatMap(\.messages).compactMap(\.error).suffix(3)
        var lines = [
            "Choir \(version) · macOS \(os)",
            "Backends in use: \(backends.joined(separator: ", "))",
            "Open: \(current)",
            "Running: \(conductor.running.count) · queued: \(conductor.queue.values.reduce(0) { $0 + $1.count })",
            "Claude CLI: \(CLI.isInstalled("claude") ? "installed" : "missing") · Codex CLI: \(CLI.isInstalled("codex") ? "installed" : "missing") · AI Profiles: \(usage.available ? "yes" : "no")",
        ]
        if !errors.isEmpty { lines.append("Recent errors: " + errors.joined(separator: " | ")) }
        return lines.joined(separator: "\n")
    }

    // MARK: Submit

    struct Filed { let url: URL; let number: Int }

    /// Uploads the screenshot into the repo (bug-reports/…png), then opens the
    /// issue that embeds it. Returns the issue URL; throws with GitHub's own
    /// message when something is refused.
    static func submit(_ report: Report, repo: String) async throws -> Filed {
        guard let token = token() else {
            throw EngineError(message: "No GitHub login found. Sign in with `gh auth login` in Terminal, or paste a token in Settings › General.")
        }
        let session = URLSession.shared
        func request(_ method: String, _ path: String, body: [String: Any]) throws -> URLRequest {
            var r = URLRequest(url: URL(string: "https://api.github.com/\(path)")!)
            r.httpMethod = method
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            r.setValue("Choir", forHTTPHeaderField: "User-Agent")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            return r
        }
        func send(_ r: URLRequest) async throws -> [String: Any] {
            let (data, response) = try await session.data(for: r)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            guard (200..<300).contains(code) else {
                throw EngineError(message: "GitHub said \(code): \((obj["message"] as? String) ?? "no detail")")
            }
            return obj
        }

        let stamp: String = {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: Date())
        }()

        var imageLine = ""
        if report.includeScreenshot, let png = report.screenshot {
            let path = "bug-reports/\(stamp).png"
            _ = try await send(try request("PUT", "repos/\(repo)/contents/\(path)", body: [
                "message": "Bug report screenshot \(stamp)",
                "content": png.base64EncodedString(),
            ]))
            imageLine = "\n\n![screenshot](https://github.com/\(repo)/blob/main/\(path)?raw=true)"
        }

        var body = "## What happened\n\(report.whatHappened.trimmingCharacters(in: .whitespacesAndNewlines))"
        let expected = report.expected.trimmingCharacters(in: .whitespacesAndNewlines)
        if !expected.isEmpty { body += "\n\n## What I expected\n\(expected)" }
        if report.includeDiagnostics { body += "\n\n## Setup\n```\n\(report.diagnostics)\n```" }
        body += imageLine
        body += "\n\n_Filed from Choir's Report a problem._"

        let issue = try await send(try request("POST", "repos/\(repo)/issues", body: [
            "title": report.title.trimmingCharacters(in: .whitespacesAndNewlines),
            "body": body,
            "labels": ["from-app"],
        ]))
        guard let urlString = issue["html_url"] as? String, let url = URL(string: urlString) else {
            throw EngineError(message: "GitHub created the issue but returned no link.")
        }
        let filed = Filed(url: url, number: issue["number"] as? Int ?? 0)
        appendLog(report, filed: filed)
        return filed
    }

    /// A local copy of every report, so the log survives without the network.
    private static func appendLog(_ report: Report, filed: Filed) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Choir/bug-reports.jsonl")
        let entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "issue": filed.number, "url": filed.url.absoluteString,
            "title": report.title, "whatHappened": report.whatHappened, "expected": report.expected,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); handle.write(Data("\n".utf8)); try? handle.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
    }
}

// MARK: - The sheet

struct BugReportSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var report: BugReporter.Report
    @State private var sending = false
    @State private var filed: BugReporter.Filed?
    @State private var failure: String?
    @FocusState private var focus: Field?
    private enum Field { case title, happened }

    private var repo: String { store.settings.bugRepo ?? BugReporter.defaultRepo }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Report a problem").font(.system(size: 15, weight: .semibold))
                    Text("Becomes an issue in \(repo). Your messages are never sent — only what you type here, the screenshot if you keep it, and the setup facts below.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            if let filed {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Filed as issue #\(filed.number). Thank you.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    HStack {
                        Button("Open on GitHub") { NSWorkspace.shared.open(filed.url) }.prominentGlassButton()
                        Button("Done") { dismiss() }.plainGlassButton()
                    }
                }
                .padding(.vertical, 20)
            } else {
                TextField("One line: what went wrong", text: $report.title)
                    .textFieldStyle(.roundedBorder).font(.system(size: 13)).focused($focus, equals: .title)

                VStack(alignment: .leading, spacing: 4) {
                    Text("What happened").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    TextEditor(text: $report.whatHappened)
                        .font(.system(size: 12.5)).scrollContentBackground(.hidden)
                        .frame(height: 96).padding(8).glassPanel(10).focused($focus, equals: .happened)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("What you expected (optional)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    TextEditor(text: $report.expected)
                        .font(.system(size: 12.5)).scrollContentBackground(.hidden)
                        .frame(height: 56).padding(8).glassPanel(10)
                }

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Include screenshot", isOn: $report.includeScreenshot).font(.system(size: 12))
                            .disabled(report.screenshot == nil)
                        if let png = report.screenshot, let image = NSImage(data: png), report.includeScreenshot {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                .frame(width: 220).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.15)))
                        } else if report.screenshot == nil {
                            Text("No screenshot captured.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Include setup facts", isOn: $report.includeDiagnostics).font(.system(size: 12))
                        if report.includeDiagnostics {
                            Text(report.diagnostics).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.plainGlassButton().keyboardShortcut(.cancelAction)
                    Button {
                        send()
                    } label: {
                        HStack(spacing: 6) {
                            if sending { ProgressView().controlSize(.small) }
                            Text(sending ? "Filing…" : "File the report")
                        }
                    }
                    .prominentGlassButton()
                    .disabled(sending || report.title.trimmingCharacters(in: .whitespaces).isEmpty || report.whatHappened.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 560)
        .onAppear { focus = report.title.isEmpty ? .title : .happened }
    }

    private func send() {
        sending = true; failure = nil
        let snapshot = report, target = repo
        Task {
            do { filed = try await BugReporter.submit(snapshot, repo: target) }
            catch { failure = error.localizedDescription }
            sending = false
        }
    }
}
