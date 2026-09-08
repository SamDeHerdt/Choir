// Choir — made by Sam De Herdt for MakeWaves.
import Foundation
import SwiftUI

/// Live subscription meters, read from AI Profiles' CLI (`aiapps status --json`)
/// when it is installed. Choir does not talk to the providers' usage endpoints
/// itself — aiapps already owns the tokens, the refreshes and the quirks.
/// Numbers are shown as % LEFT, the way AI Profiles shows them.
@MainActor
final class UsageMonitor: ObservableObject {
    struct Account: Identifiable, Hashable {
        let provider: String   // "chatgpt" | "claude"
        let profile: String    // "personal" | "work"
        let email: String
        let plan: String
        let fiveUsed: Int?
        let weekUsed: Int?
        let fiveResets: Date?
        let weekResets: Date?
        let usageAuth: String
        let running: Bool

        var id: String { "\(provider)/\(profile)" }
        var fiveLeft: Int? { fiveUsed.map { max(0, 100 - $0) } }
        var weekLeft: Int? { weekUsed.map { max(0, 100 - $0) } }
        /// The tighter of the two windows — what actually gates the next message.
        var left: Int? { [fiveLeft, weekLeft].compactMap { $0 }.min() }
        var exhausted: Bool { (left ?? 100) == 0 }
        var meterAvailable: Bool { usageAuth == "ok" && left != nil }
        var backend: Backend { provider == "chatgpt" ? .codexCLI : .claudeCLI }

        /// "resets 01:41" / "resets Mon 09:08" — whichever window is empty or
        /// nearer to empty.
        var resetLine: String? {
            let f = DateFormatter(); f.locale = .current
            let pick: Date?
            if let five = fiveLeft, let week = weekLeft {
                pick = five <= week ? fiveResets : weekResets
            } else {
                pick = fiveResets ?? weekResets
            }
            guard let date = pick else { return nil }
            f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
            return "resets \(f.string(from: date))"
        }
    }

    @Published private(set) var accounts: [Account] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var refreshing = false
    /// Nil when aiapps is not on this Mac; the meters simply do not appear.
    let executable: String? = {
        let path = "\(NSHomeDirectory())/.local/bin/aiapps"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()

    var available: Bool { executable != nil }

    func accounts(for backend: Backend) -> [Account] {
        accounts.filter { $0.backend == backend }
    }

    /// The account the CLI is signed in as right now (aiapps marks it `running`
    /// for the app; for the CLI slot we match on the Claude profile dir when known).
    func active(for backend: Backend, claudeProfileDir: String? = nil) -> Account? {
        let list = accounts(for: backend)
        if backend == .claudeCLI, let dir = claudeProfileDir {
            if let hit = list.first(where: { dir.hasSuffix(".claude-\($0.profile)") }) { return hit }
        }
        return list.first(where: \.running) ?? list.first
    }

    func refresh(force: Bool = false) {
        guard let executable, !refreshing else { return }
        if !force, let last = lastRefresh, Date().timeIntervalSince(last) < 120 { return }
        refreshing = true
        Task.detached(priority: .utility) { [weak self] in
            let parsed = UsageMonitor.read(executable: executable)
            await MainActor.run { [weak self] in
                guard let monitor = self else { return }
                if let parsed { monitor.accounts = parsed; monitor.lastRefresh = Date() }
                monitor.refreshing = false
            }
        }
    }

    /// Flips the live ChatGPT / Claude slot to another account through aiapps
    /// (`aiapps switch <provider> <profile> --no-relaunch`). Returns aiapps'
    /// own message so a failure is shown as it happened.
    func switchAccount(provider: String, profile: String) async -> String {
        guard let executable else { return "AI Profiles is not installed." }
        return await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = ["switch", provider, profile, "--no-relaunch"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = UsageMonitor.toolPath
            p.environment = env
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            do { try p.run() } catch { return "Could not run aiapps: \(error.localizedDescription)" }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return p.terminationStatus == 0 ? (text.isEmpty ? "Switched to \(profile)." : text) : (text.isEmpty ? "aiapps exited with code \(p.terminationStatus)." : text)
        }.value
    }

    nonisolated static var toolPath: String {
        "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }

    nonisolated private static func read(executable: String) -> [Account]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["status", "--json"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolPath
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter(); isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ s: Any?) -> Date? {
            guard let s = s as? String, !s.isEmpty else { return nil }
            return iso.date(from: s) ?? isoFrac.date(from: s)
        }
        return items.compactMap { item in
            guard let provider = item["provider"] as? String, let profile = item["profile"] as? String else { return nil }
            return Account(provider: provider, profile: profile,
                           email: item["detail"] as? String ?? "",
                           plan: item["plan"] as? String ?? "",
                           fiveUsed: item["five_used"] as? Int, weekUsed: item["week_used"] as? Int,
                           fiveResets: date(item["five_resets"]), weekResets: date(item["week_resets"]),
                           usageAuth: item["usage_auth"] as? String ?? "",
                           running: item["running"] as? Bool ?? false)
        }
    }
}

/// One account's meter: name, plan, a % LEFT bar and the reset time.
/// Blue on purpose — it is information, not the app's accent.
struct UsageMeter: View {
    let account: UsageMonitor.Account
    var compact = false

    private var barColor: Color {
        guard let left = account.left else { return .secondary }
        return left == 0 ? .orange : Color(red: 0.36, green: 0.55, blue: 0.95)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(spacing: 6) {
                Text(account.profile.capitalized).font(.system(size: compact ? 11 : 12, weight: .semibold))
                if !account.plan.isEmpty { Text(account.plan).font(.system(size: 10.5)).foregroundStyle(.tertiary) }
                if !compact, !account.email.isEmpty { Text(account.email).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1) }
                Spacer(minLength: 4)
                if let left = account.left {
                    Text("\(left)% left").font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(left == 0 ? Color.orange : Color.primary)
                } else {
                    Text(account.usageAuth == "ok" ? "no meter" : "no usage token").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.14))
                    Capsule().fill(barColor)
                        .frame(width: geo.size.width * CGFloat(account.left ?? 0) / 100)
                }
            }
            .frame(height: compact ? 4 : 6)
            if let line = account.resetLine, (account.left ?? 100) < 100 {
                Text(line).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }
}
