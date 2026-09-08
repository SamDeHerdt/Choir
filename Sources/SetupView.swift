// Choir — made by Sam De Herdt for MakeWaves.
import SwiftUI
import AppKit

/// First run: three things to connect, each with the one Terminal line that
/// does it and a live tick that turns green when it worked. Opens by itself
/// the first time nothing is connected; always under Help › Set Up Connections.
struct SetupView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var claude: Status = .checking
    @State private var codex: Status = .checking
    @State private var ollama: Status = .checking
    @State private var checking = false
    @State private var copied: String?

    enum Status: Equatable { case checking, missing, installedNotSignedIn, ready }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect the AIs you already pay for").font(.system(size: 18, weight: .semibold))
                Text("Choir talks to each provider's own free command-line tool, signed in with your normal account. No API keys, no credits. Open Terminal (⌘ Space, type Terminal) and paste one line at a time.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            step(status: claude, name: "Claude", plan: "Claude Pro or Max",
                 install: ("Install Claude Code", "curl -fsSL https://claude.ai/install.sh | bash"),
                 signIn: ("Sign in (a browser window opens)", "claude login"))
            step(status: codex, name: "ChatGPT", plan: "ChatGPT Plus, Pro or Team",
                 install: ("Install Codex (needs Node from nodejs.org)", "npm install -g @openai/codex"),
                 signIn: ("Sign in (a browser window opens)", "codex login"))
            step(status: ollama, name: "Local models", plan: "free, offline, optional",
                 install: ("Install Ollama from ollama.com, open it once, then pull a model", "ollama pull llama3.2"),
                 signIn: nil)

            HStack(spacing: 10) {
                Button {
                    check()
                } label: {
                    HStack(spacing: 6) {
                        if checking { ProgressView().controlSize(.small) }
                        Text(checking ? "Checking…" : "Check again")
                    }
                }
                .plainGlassButton().disabled(checking)
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(readyCount > 0 ? "Done" : "Skip for now") {
                    store.settings.setupSeen = true
                    store.scheduleSave()
                    dismiss()
                    if readyCount > 0 { Task { _ = await ModelDiscovery.refresh(store: store) } }
                }
                .prominentGlassButton().keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear { check() }
    }

    private var readyCount: Int { [claude, codex, ollama].filter { $0 == .ready }.count }
    private var summary: String {
        switch readyCount {
        case 0: return "Nothing connected yet — that's fine, you can come back from Help."
        case 1: return "One connection ready. Two is where rooms get interesting."
        default: return "\(readyCount) connections ready."
        }
    }

    // MARK: Rows

    private func step(status: Status, name: String, plan: String, install: (String, String), signIn: (String, String)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusMark(status)
                Text(name).font(.system(size: 13, weight: .semibold))
                Text(plan).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Text(statusText(status, hasSignIn: signIn != nil)).font(.system(size: 11)).foregroundStyle(status == .ready ? Color.green : Color.secondary)
            }
            if status != .ready {
                VStack(alignment: .leading, spacing: 6) {
                    if status == .missing || status == .checking {
                        commandRow(label: install.0, command: install.1)
                    }
                    if let signIn, status != .checking {
                        commandRow(label: signIn.0, command: signIn.1)
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(12)
    }

    private func commandRow(label: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(command).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
                    withAnimation(Motion.on(Motion.bounce(Motion.fast))) { copied = command }
                } label: {
                    Label(copied == command ? "Copied" : "Copy", systemImage: copied == command ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(copied == command ? Color.green : Color.secondary)
                Button("Open Terminal") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                }
                .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    private func statusMark(_ status: Status) -> some View {
        switch status {
        case .checking: ProgressView().controlSize(.small).frame(width: 16)
        case .missing: Image(systemName: "circle").foregroundStyle(.tertiary).frame(width: 16)
        case .installedNotSignedIn: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).frame(width: 16)
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 16)
        }
    }

    private func statusText(_ status: Status, hasSignIn: Bool) -> String {
        switch status {
        case .checking: return "checking…"
        case .missing: return "not installed"
        case .installedNotSignedIn: return hasSignIn ? "installed — sign in" : "installed"
        case .ready: return "ready"
        }
    }

    // MARK: Detection

    /// Real checks, off the main actor: is the tool there, and is it signed in.
    private func check() {
        checking = true
        let claudeBin = CLI.resolve("claude", override: store.settings.connection(for: .claudeCLI).executablePath)
        let codexBin = CLI.resolve("codex", override: store.settings.connection(for: .codexCLI).executablePath)
        let pinned = store.settings.connection(for: .claudeCLI).configDir
        let ollamaHost = store.settings.connection(for: .ollama).endpoint
        Task.detached {
            let c: Status
            if let claudeBin {
                CLI.ClaudeProfile.invalidate()
                c = CLI.ClaudeProfile.all(executable: claudeBin, pinned: pinned).contains(where: \.signedIn) ? .ready : .installedNotSignedIn
            } else { c = .missing }

            let x: Status
            if codexBin != nil {
                let home = NSHomeDirectory()
                let authFiles = ["\(home)/.codex/auth.json", "\(home)/.codex-personal/auth.json", "\(home)/.codex-work/auth.json"]
                x = authFiles.contains { FileManager.default.fileExists(atPath: $0) } ? .ready : .installedNotSignedIn
            } else { x = .missing }

            var o: Status = .missing
            if let url = URL(string: "\(ollamaHost)/api/tags"), let (data, _) = try? await URLSession.shared.data(from: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let models = obj["models"] as? [[String: Any]] {
                o = models.isEmpty ? .installedNotSignedIn : .ready
            }
            await MainActor.run { claude = c; codex = x; ollama = o; checking = false }
        }
    }
}
