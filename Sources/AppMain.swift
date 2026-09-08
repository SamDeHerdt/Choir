// Choir — made by Sam De Herdt for MakeWaves.
import SwiftUI
import AppKit

/// Two entry points share one binary: the window, and the MCP bridge that the
/// CLIs spawn. The bridge must not touch AppKit, so the branch happens before
/// SwiftUI is ever started.
@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--mcp-server") {
            MCPServer().run()
            return
        }
        ChoirApp.main()
    }
}

struct ChoirApp: App {
    @StateObject private var store = Store()
    @StateObject private var conductor = Conductor()
    @StateObject private var usage = UsageMonitor()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(conductor)
                .environmentObject(usage)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { Motion.disabled = store.settings.reduceMotion }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { store.newConversation() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Room") { store.newConversation(room: true) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Project") { store.newProject() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Divider()
                Button("Home") { NotificationCenter.default.post(name: .choirGoHome, object: nil) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Jump to…") { NotificationCenter.default.post(name: .choirQuickSwitch, object: nil) }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(after: .help) {
                Button("Report a Problem…") { NotificationCenter.default.post(name: .choirReportProblem, object: nil) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            CommandMenu("Model") {
                ForEach(Array(store.enabledModels.prefix(9).enumerated()), id: \.element.key) { index, model in
                    Button(model.label) { NotificationCenter.default.post(name: .choirPickModel, object: index) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .shift])
                }
                if store.enabledModels.isEmpty { Text("No models enabled") }
            }
            CommandGroup(replacing: .help) {
                Button("Show Me Around") { NotificationCenter.default.post(name: .choirShowTour, object: nil) }
                Button("Set Up Connections…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            }
        }

        Settings {
            SettingsView().environmentObject(store).environmentObject(usage)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var conductor: Conductor
    @EnvironmentObject var usage: UsageMonitor
    @State private var route: Route?
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var showTour = false
    @State private var showSwitcher = false
    @State private var bugReport: BugReporter.Report?

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar(route: $route, showTour: $showTour)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .overlay(alignment: .top) { banner }
        .onAppear {
            restoreRoute()
            // Populate the picker with whatever the signed-in tools can reach.
            Task { _ = await ModelDiscovery.refresh(store: store) }
        }
        .sheet(isPresented: $showTour) { TourView().environmentObject(store) }
        .sheet(isPresented: $showSwitcher) { QuickSwitcher(route: $route).environmentObject(store) }
        .sheet(item: $bugReport) { report in BugReportSheet(report: report).environmentObject(store) }
        .onReceive(NotificationCenter.default.publisher(for: .choirReportProblem)) { note in
            // Capture first, while the window is still what the user sees.
            let shot = BugReporter.capture()
            bugReport = BugReporter.Report(
                title: (note.object as? String) ?? "",
                whatHappened: "", expected: "",
                screenshot: shot,
                diagnostics: BugReporter.diagnostics(store: store, conductor: conductor, usage: usage))
        }
        .onReceive(NotificationCenter.default.publisher(for: .choirQuickSwitch)) { _ in showSwitcher = true }
        .onReceive(NotificationCenter.default.publisher(for: .choirShowTour)) { _ in showTour = true }
        .onReceive(NotificationCenter.default.publisher(for: .choirGoHome)) { _ in
            withAnimation(Motion.on(Motion.smoothOut(Motion.fast))) { route = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .choirPickModel)) { note in
            guard let index = note.object as? Int, case .conversation(let id) = route,
                  let i = store.index(of: id), index < store.enabledModels.count else { return }
            store.conversations[i].modelKey = store.enabledModels[index].key
            store.scheduleSave()
        }
        .onChange(of: route) { _, newValue in
            // Browsing a project scopes the sidebar's chat list to it.
            if case .project(let id) = newValue { store.activeProjectID = id }
            if case .conversation(let id) = newValue { store.selection = id; conductor.markSeen(id) }
            store.settings.lastRoute = encode(newValue)
            store.scheduleSave()
        }
        .onChange(of: store.selection) { _, newValue in
            guard let id = newValue else { return }
            if case .conversation(let current) = route, current == id { return }
            withAnimation(Motion.on(Motion.smoothOut(Motion.fast))) { route = .conversation(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The MCP bridge runs in another process and may have added knowhow.
            store.reloadLibraryFromDisk()
            usage.refresh()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch route {
        case .conversation(let id):
            ChatView(conversationID: id)
                .id(id)
                .transition(.opacity)
        case .project(let id):
            ProjectView(route: $route, projectID: id)
                .id(id)
                .transition(.opacity)
        case .library(let kind):
            LibraryView(kind: kind)
                .id(kind)
        case .none:
            HomeView(route: $route, showTour: $showTour)
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let done = conductor.lastFinished, store.selection != done.id {
            // "That room finished" — one line, one button, goes away by itself.
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("“\(done.title)” is done").font(.system(size: 12)).lineLimit(1)
                Button("View") {
                    withAnimation(Motion.on(Motion.smoothOut(Motion.fast))) { route = .conversation(done.id) }
                }
                .prominentGlassButton().controlSize(.small)
                Button {
                    withAnimation(Motion.on(Motion.smoothOut(Motion.quick))) { conductor.lastFinished = nil }
                } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassPanel(12)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: done.id) {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                withAnimation(Motion.on(Motion.smoothOut(Motion.quick))) { if conductor.lastFinished?.id == done.id { conductor.lastFinished = nil } }
            }
        } else if let message = store.banner {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.system(size: 12))
                Button {
                    withAnimation(Motion.on(Motion.smoothOut(Motion.quick))) { store.banner = nil }
                } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassPanel(12)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func restoreRoute() {
        if store.settings.lastRoute == "home" { route = nil; return }
        if let saved = decode(store.settings.lastRoute) {
            route = saved
        } else if let id = store.selection ?? store.conversations.first?.id {
            route = .conversation(id)
        }
    }

    private func encode(_ route: Route?) -> String {
        switch route {
        case .conversation(let id): return "conversation:\(id.uuidString)"
        case .project(let id): return "project:\(id.uuidString)"
        case .library(let kind): return "library:\(kind?.rawValue ?? "all")"
        case .none: return "home"
        }
    }

    private func decode(_ raw: String) -> Route? {
        if raw == "library" { return .library(nil) }
        if raw.hasPrefix("library:") { return .library(LibraryItem.Kind(rawValue: String(raw.dropFirst(8)))) }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "conversation": return store.conversations.contains { $0.id == id } ? .conversation(id) : nil
        case "project": return store.projects.contains { $0.id == id } ? .project(id) : nil
        default: return nil
        }
    }
}


extension Notification.Name {
    static let choirShowTour = Notification.Name("choirShowTour")
    static let choirGoHome = Notification.Name("choirGoHome")
    static let choirPickModel = Notification.Name("choirPickModel")
    static let choirQuickSwitch = Notification.Name("choirQuickSwitch")
    static let choirReportProblem = Notification.Name("choirReportProblem")
}
