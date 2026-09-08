// Choir — made by Sam De Herdt for MakeWaves.
import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            ConnectionsTab().tabItem { Label("Connections", systemImage: "link") }
            ModelsTab().tabItem { Label("Models", systemImage: "cpu") }
            BridgeTab().tabItem { Label("MCP bridge", systemImage: "arrow.triangle.branch") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 640, height: 520)
    }
}

// MARK: - Connections

struct ConnectionsTab: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("No third-party app can call Claude Pro or ChatGPT Plus directly — a subscription has no API. What it does have is a signed-in command-line tool on this Mac, and Choir talks to that. Nothing below spends credits.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Backend.allCases.filter { !$0.needsAPIKey }, id: \.self) { backend in
                    ConnectionCard(backend: backend)
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Only if you actually want to buy tokens. Left empty, these never appear in the model picker.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(Backend.allCases.filter { $0.needsAPIKey }, id: \.self) { backend in
                            ConnectionCard(backend: backend)
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    Text("Pay-per-token connections").font(.system(size: 12, weight: .semibold))
                }
                .padding(.top, 4)
            }
            .padding(18)
        }
    }
}

struct ConnectionCard: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var usage: UsageMonitor
    let backend: Backend
    @State private var key = ""
    @State private var probe: String?
    @State private var probing = false
    @State private var profiles: [CLI.ClaudeProfile.Info] = []

    private var connection: Connection { store.settings.connection(for: backend) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: backend.symbol).font(.system(size: 13)).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(backend.displayName).font(.system(size: 12.5, weight: .semibold))
                    Text(backend.billing).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: enabledBinding).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }

            if backend.needsAPIKey {
                HStack(spacing: 8) {
                    SecureField("API key", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .onSubmit { store.setAPIKey(key, for: backend) }
                    Button("Save") { store.setAPIKey(key, for: backend) }
                        .controlSize(.small)
                }
                TextField("Endpoint", text: endpointBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10.5, design: .monospaced))
            } else if backend == .ollama {
                TextField("Ollama host", text: endpointBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10.5, design: .monospaced))
            } else if backend == .customCLI {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Path to the tool, e.g. /opt/homebrew/bin/gemini", text: pathBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10.5, design: .monospaced))
                        Button("Choose…") { choosePath() }.controlSize(.small)
                    }
                    TextField("Arguments — {model} and {prompt} are filled in", text: argumentsBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10.5, design: .monospaced))
                    TextField("Leave blank if it prints plain text; otherwise the JSON key to read", text: jsonKeyBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10.5, design: .monospaced))
                    Text("Without {prompt}, the conversation is written to the tool's standard input. Choir does not assume any tool's flags — check its --help once and paste them here.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    TextField("Path to the executable (leave blank to find it automatically)", text: pathBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10.5, design: .monospaced))
                    let name = backend == .claudeCLI ? "claude" : "codex"
                    let found = CLI.isInstalled(name, override: connection.executablePath)
                    Chip(text: found ? "installed" : "not installed",
                         symbol: found ? "checkmark" : "xmark",
                         color: found ? .green : .orange)
                }
                if backend == .claudeCLI {
                    // One login per profile; show which are signed in and let
                    // the user pin one. Auto = first signed-in profile.
                    HStack(spacing: 8) {
                        Text("Profile").font(.system(size: 11)).foregroundStyle(.secondary)
                        Picker("", selection: profileBinding) {
                            Text("Automatic — first signed-in").tag("")
                            ForEach(profiles, id: \.dir) { info in
                                Text("\(info.dir.replacingOccurrences(of: NSHomeDirectory(), with: "~")) — \(info.signedIn ? (info.email.isEmpty ? "signed in" : info.email) : "not signed in")")
                                    .tag(info.dir)
                            }
                        }
                        .labelsHidden().controlSize(.small).frame(maxWidth: 360)
                        if profiles.isEmpty {
                            Text("checking…").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        } else if !profiles.contains(where: \.signedIn) {
                            Text("No profile is signed in — run `claude login` in Terminal.")
                                .font(.system(size: 10.5)).foregroundStyle(.orange)
                        }
                    }
                    .task {
                        guard let bin = CLI.resolve("claude", override: connection.executablePath) else { return }
                        let pinned = connection.configDir
                        profiles = await Task.detached { CLI.ClaudeProfile.all(executable: bin, pinned: pinned) }.value
                    }
                }
            }

            if backend == .claudeCLI || backend == .codexCLI, usage.available {
                let list = usage.accounts(for: backend)
                if !list.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(list) { account in UsageMeter(account: account) }
                        Text("Meters from AI Profiles. Switch the live account there, or from a limit error in a chat.")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .padding(.top, 2)
                }
            }

            HStack(spacing: 8) {
                Button(probing ? "Checking…" : "Test") { test() }
                    .controlSize(.small)
                    .disabled(probing)
                if let probe {
                    Text(probe)
                        .font(.system(size: 10.5))
                        .foregroundStyle(probe.hasPrefix("OK") ? Color.green : Color.orange)
                        .transition(.opacity)
                }
                Spacer()
            }
            .motion(Motion.smoothOut(Motion.quick), value: probe)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(14)
        .onAppear { if backend.needsAPIKey { key = store.apiKey(for: backend) }; usage.refresh() }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { connection.enabled },
            set: { value in
                guard let i = store.settings.connections.firstIndex(where: { $0.backend == backend }) else { return }
                store.settings.connections[i].enabled = value
                store.scheduleSave()
            })
    }

    private var endpointBinding: Binding<String> {
        Binding(
            get: { connection.endpoint },
            set: { value in
                guard let i = store.settings.connections.firstIndex(where: { $0.backend == backend }) else { return }
                store.settings.connections[i].endpoint = value
                store.scheduleSave()
            })
    }

    private var argumentsBinding: Binding<String> {
        Binding(
            get: { connection.arguments },
            set: { value in
                guard let i = store.settings.connections.firstIndex(where: { $0.backend == backend }) else { return }
                store.settings.connections[i].arguments = value
                store.scheduleSave()
            })
    }

    private var jsonKeyBinding: Binding<String> {
        Binding(
            get: { connection.jsonTextKey },
            set: { value in
                guard let i = store.settings.connections.firstIndex(where: { $0.backend == backend }) else { return }
                store.settings.connections[i].jsonTextKey = value
                store.scheduleSave()
            })
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in pathBinding.wrappedValue = url.path }
        }
    }

    private var profileBinding: Binding<String> {
        Binding(
            get: { connection.configDir ?? "" },
            set: { value in
                guard let i = store.settings.connections.firstIndex(where: { $0.backend == backend }) else { return }
                store.settings.connections[i].configDir = value.isEmpty ? nil : value
                CLI.ClaudeProfile.invalidate()
                store.scheduleSave()
            })
    }

    private var pathBinding: Binding<String> {
        Binding(
            get: { connection.executablePath },
            set: { value in
                guard let i = store.settings.connections.firstIndex(where: { $0.backend == backend }) else { return }
                store.settings.connections[i].executablePath = value
                store.scheduleSave()
            })
    }

    /// A real one-token round trip. A green light that only checks whether a
    /// key is non-empty is worse than no light at all.
    private func test() {
        probing = true
        probe = nil
        Task {
            guard let spec = store.settings.models.first(where: { $0.backend == backend })
                    ?? (backend == .customCLI ? ModelSpec(backend: .customCLI, id: "", label: "Custom CLI") : nil) else {
                probe = "Add a model for this connection first, under Models."
                probing = false
                return
            }
            let engine = EngineFactory.engine(for: backend, settings: store.settings) { store.apiKey(for: $0) }
            var got = ""
            do {
                for try await chunk in engine.stream(system: "Reply with the single word: ok",
                                                     turns: [WireTurn(role: "user", text: "ping")],
                                                     model: spec, settings: store.settings) {
                    if case .text(let t) = chunk { got += t }
                    if got.count > 20 { break }
                }
                probe = got.isEmpty ? "Connected, but nothing came back." : "OK — \(spec.label) answered."
            } catch {
                probe = error.localizedDescription
            }
            probing = false
        }
    }
}

// MARK: - Models

struct ModelsTab: View {
    @EnvironmentObject var store: Store
    @State private var newID = ""
    @State private var newBackend: Backend = .anthropic
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model names change faster than any app can ship. Add whatever your account can reach; the list is yours.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)

            List {
                ForEach(Backend.allCases, id: \.self) { backend in
                    let models = store.settings.models.filter { $0.backend == backend }
                    if !models.isEmpty {
                        Section(backend.displayName) {
                            ForEach(models) { model in
                                HStack(spacing: 9) {
                                    Toggle("", isOn: enabled(model)).labelsHidden().controlSize(.mini)
                                    VoiceDot(key: model.key)
                                    Text(model.label).font(.system(size: 12))
                                    Text(model.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                    Spacer()
                                    Button {
                                        store.settings.models.removeAll { $0.key == model.key }
                                        store.scheduleSave()
                                    } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Picker("", selection: $newBackend) {
                    ForEach(Backend.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().frame(width: 160)
                TextField("Model id, e.g. gemini-2.5-flash", text: $newID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
                Button("Add") { add() }.disabled(newID.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Find every available model") { refreshAll() }
            }

            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).transition(.opacity)
            }
        }
        .padding(18)
        .motion(Motion.smoothOut(Motion.quick), value: note)
    }

    private func enabled(_ model: ModelSpec) -> Binding<Bool> {
        Binding(
            get: { model.enabled },
            set: { value in
                guard let i = store.settings.models.firstIndex(where: { $0.key == model.key }) else { return }
                store.settings.models[i].enabled = value
                store.scheduleSave()
            })
    }

    private func add() {
        let id = newID.trimmingCharacters(in: .whitespaces)
        guard !store.settings.models.contains(where: { $0.backend == newBackend && $0.id == id }) else {
            note = "That model is already in the list."
            return
        }
        store.settings.models.append(ModelSpec(backend: newBackend, id: id, label: id))
        newID = ""
        store.scheduleSave()
    }

    private func refreshAll() {
        note = "Looking…"
        Task {
            let added = await ModelDiscovery.refresh(store: store)
            note = added == 0 ? "Nothing new. Every model the enabled connections expose is already listed." : "Added \(added) model\(added == 1 ? "" : "s")."
        }
    }

    /// Kept for the Ollama-only case; the general path is `refreshAll`.
    private func fetchOllama() {
        Task {
            let base = store.settings.connection(for: .ollama).endpoint
            guard let url = URL(string: "\(base)/api/tags") else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let models = obj["models"] as? [[String: Any]] else { return }
                var added = 0
                for entry in models {
                    guard let name = entry["name"] as? String else { continue }
                    guard !store.settings.models.contains(where: { $0.backend == .ollama && $0.id == name }) else { continue }
                    store.settings.models.append(ModelSpec(backend: .ollama, id: name, label: name))
                    added += 1
                }
                store.scheduleSave()
                note = added == 0 ? "Ollama had nothing new." : "Added \(added) local model\(added == 1 ? "" : "s")."
            } catch {
                note = "Ollama is not reachable at \(base)."
            }
        }
    }
}

// MARK: - MCP bridge

/// The other half of "let them read each other's material": Choir serves its
/// own library and history over MCP, so the CLIs can reach back into it.
struct BridgeTab: View {
    @EnvironmentObject var store: Store
    @State private var copied: String?

    private var executable: String {
        Bundle.main.executableURL?.path ?? "/Applications/Choir.app/Contents/MacOS/Choir"
    }

    private var claudeCommand: String {
        "claude mcp add choir -- \"\(executable)\" --mcp-server"
    }

    private var codexConfig: String {
        """
        [mcp_servers.choir]
        command = "\(executable)"
        args = ["--mcp-server"]
        """
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choir can serve its library and history to any MCP client. Connect it to Claude Code or Codex and those tools can list the shared prompts, read a skill, search what any model said before, and write new knowhow back.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Card(title: "Claude Code", subtitle: "Run this once in Terminal.") {
                    Snippet(text: claudeCommand, copied: $copied)
                }

                Card(title: "Codex", subtitle: "Add this to ~/.codex/config.toml.") {
                    Snippet(text: codexConfig, copied: $copied)
                }

                Card(title: "What it exposes", subtitle: "Five tools, read-mostly.") {
                    VStack(alignment: .leading, spacing: 5) {
                        ToolLine("list_library", "Every prompt, skill and knowhow entry.")
                        ToolLine("get_library_item", "The full text of one of them.")
                        ToolLine("search_history", "Any phrase, across every conversation and model.")
                        ToolLine("get_conversation", "One thread in full, with who said what.")
                        ToolLine("save_knowhow", "Write a fact back into the shared library.")
                    }
                }
            }
            .padding(18)
        }
    }
}

struct ToolLine: View {
    let name: String
    let explainer: String
    init(_ name: String, _ explainer: String) { self.name = name; self.explainer = explainer }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(.system(size: 11, weight: .medium, design: .monospaced))
            Text(explainer).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct Snippet: View {
    let text: String
    @Binding var copied: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                withAnimation(Motion.on(Motion.bounce(Motion.fast))) { copied = text }
            } label: {
                Image(systemName: copied == text ? "checkmark" : "doc.on.doc").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied == text ? Color.green : Color.secondary)
        }
        .padding(10)
        .background(.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - General

struct GeneralTab: View {
    @EnvironmentObject var store: Store
    @State private var githubToken = Keychain.get("github")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card(title: "Global instructions", subtitle: "Sent to every model, in every project. Keep it short — projects are the better place for detail.") {
                    TextEditor(text: Binding(
                        get: { store.settings.globalSystemPrompt },
                        set: { store.settings.globalSystemPrompt = $0; store.scheduleSave() }))
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 90)
                }

                Card(title: "Generation", subtitle: "The token cap applies to Anthropic and Ollama; the others use their own default.") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Temperature").font(.system(size: 12))
                            Slider(value: Binding(
                                get: { store.settings.temperature },
                                set: { store.settings.temperature = $0; store.scheduleSave() }), in: 0...1.5, step: 0.1)
                            Text(store.settings.temperature.formatted(.number.precision(.fractionLength(1))))
                                .font(.system(size: 11, design: .monospaced)).monospacedDigit().frame(width: 30)
                        }
                        Stepper("Maximum tokens: \(store.settings.maxTokens)", value: Binding(
                            get: { store.settings.maxTokens },
                            set: { store.settings.maxTokens = $0; store.scheduleSave() }), in: 512...32768, step: 512)
                            .font(.system(size: 12))
                    }
                }

                Card(title: "Interface", subtitle: "") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Show reasoning when a model exposes it", isOn: Binding(
                            get: { store.settings.showReasoning },
                            set: { store.settings.showReasoning = $0; store.scheduleSave() }))
                        Toggle("Reduce motion", isOn: Binding(
                            get: { store.settings.reduceMotion },
                            set: { store.settings.reduceMotion = $0; Motion.disabled = $0; store.scheduleSave() }))
                    }
                    .font(.system(size: 12))
                }

                Card(title: "Problems", subtitle: "Report a problem files a GitHub issue with a screenshot and what you typed — never your messages. Uses your gh login, or a token you paste here.") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            TextField("owner/repo", text: Binding(
                                get: { store.settings.bugRepo ?? BugReporter.defaultRepo },
                                set: { store.settings.bugRepo = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0; store.scheduleSave() }))
                                .textFieldStyle(.roundedBorder).font(.system(size: 11.5, design: .monospaced)).frame(maxWidth: 260)
                            SecureField("GitHub token (optional if gh is signed in)", text: $githubToken)
                                .textFieldStyle(.roundedBorder).font(.system(size: 11.5, design: .monospaced))
                                .onSubmit { Keychain.set(githubToken, for: "github") }
                            Button("Save") { Keychain.set(githubToken, for: "github") }.controlSize(.small)
                        }
                        HStack(spacing: 8) {
                            Button {
                                NotificationCenter.default.post(name: .choirReportProblem, object: nil)
                            } label: { Label("Report a problem…", systemImage: "ladybug") }
                                .plainGlassButton().controlSize(.small)
                            Text(BugReporter.token() == nil ? "No GitHub login found yet." : "GitHub login found.")
                                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        }
                    }
                }

                Card(title: "Data", subtitle: "Conversations, projects and the library are plain JSON on this Mac. API keys live in the Keychain.") {
                    Button("Reveal in Finder") {
                        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        NSWorkspace.shared.open(base.appendingPathComponent("Choir"))
                    }
                    .controlSize(.small)
                }
            }
            .padding(18)
        }
    }
}
