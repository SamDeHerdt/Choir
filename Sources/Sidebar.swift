// Choir — made by Sam De Herdt for MakeWaves.
import SwiftUI
import AppKit

enum Route: Hashable {
    case conversation(UUID)
    case project(UUID)
    /// One kind of library item, or all of them when nil.
    case library(LibraryItem.Kind?)
}

struct Sidebar: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var conductor: Conductor
    @Binding var route: Route?
    @Binding var showTour: Bool
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            // The brand block is Home. It sits above the search, on its own.
            Button {
                withAnimation(Motion.on(Motion.smoothOut(Motion.fast))) { route = nil }
            } label: {
                HStack(spacing: 10) {
                    // The app's own icon, not a stand-in glyph.
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Choir").font(.system(size: 15, weight: .semibold))
                        Text("Every model, one thread.").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "house").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(route == nil ? Color.primary : Color.secondary.opacity(0.6))
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(route == nil ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Home")
            .padding(.horizontal, 8)
            .padding(.top, 2)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
                TextField("Search every model's history", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12))
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .glassPanel(9)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            List(selection: $route) {
                Section("Library") {
                    ForEach(LibraryItem.Kind.allCases, id: \.self) { kind in
                        // .badge before .tag — the other order makes the row unselectable on macOS 26.
                        Label(kind.plural, systemImage: kind.symbol)
                            .badge(store.library.filter { $0.kind == kind }.count)
                            .tag(Route.library(kind))
                    }
                }

                Section("Projects") {
                    ForEach(store.projects) { project in
                        ProjectRow(project: project)
                            .tag(Route.project(project.id))
                            .contextMenu {
                                Button("New chat here") { newChat(in: project.id) }
                                Divider()
                                Button("Delete project", role: .destructive) { store.deleteProject(project.id) }
                            }
                    }
                    Button {
                        let project = store.newProject()
                        route = .project(project.id)
                    } label: {
                        Label("Add project", systemImage: "plus")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Section(chatSectionTitle) {
                    ForEach(visibleConversations) { conversation in
                        ConversationRow(conversation: conversation, running: conductor.isRunning(conversation.id))
                            .tag(Route.conversation(conversation.id))
                            .contextMenu {
                                Button(conversation.pinned ? "Unpin" : "Pin") { togglePin(conversation.id) }
                                Button("Use the model's colour") { setAccent(conversation.id, nil) }
                                Menu("Move to project") {
                                    Button("None") { move(conversation.id, to: nil) }
                                    ForEach(store.projects) { project in
                                        Button(project.name) { move(conversation.id, to: project.id) }
                                    }
                                }
                                Divider()
                                Button("Delete", role: .destructive) { store.delete(conversation.id) }
                            }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider().opacity(0.4)

            HStack(spacing: 8) {
                Button {
                    let c = store.newConversation()
                    route = .conversation(c.id)
                } label: {
                    Label("Chat", systemImage: "square.and.pencil").font(.system(size: 11, weight: .medium))
                }
                .plainGlassButton()

                Button {
                    let c = store.newConversation(room: true)
                    route = .conversation(c.id)
                } label: {
                    Label("Room", systemImage: "person.3.fill").font(.system(size: 11, weight: .medium))
                }
                .plainGlassButton()
                .help("Ask several models the same thing at once.")

                Spacer()
            }
            .padding(10)
        }
    }

    private var chatSectionTitle: String {
        search.isEmpty ? "Chats" : "Matches"
    }

    /// Every chat, always — a project page lists its own under Recents, and
    /// hiding the rest while one is open only made them look lost.
    /// Search runs over every message, not just titles — the history is shared,
    /// so finding "what did Gemini say about the pricing page" has to work.
    private var visibleConversations: [Conversation] {
        let scoped = store.conversations
        guard !search.isEmpty else { return scoped }
        return scoped.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(search)
                || conversation.messages.contains { $0.text.localizedCaseInsensitiveContains(search) }
        }
    }

    private func newChat(in projectID: UUID) {
        let c = store.newConversation(projectID: projectID)
        route = .conversation(c.id)
    }

    private func togglePin(_ id: UUID) {
        guard let i = store.index(of: id) else { return }
        store.conversations[i].pinned.toggle()
        store.touch(id)
    }

    private func setAccent(_ id: UUID, _ accent: Int?) {
        guard let i = store.index(of: id) else { return }
        store.conversations[i].accent = accent
        store.conversations[i].colorHex = nil
        store.scheduleSave()
    }

    private func move(_ id: UUID, to projectID: UUID?) {
        guard let i = store.index(of: id) else { return }
        store.conversations[i].projectID = projectID
        store.scheduleSave()
    }
}

struct ProjectRow: View {
    @EnvironmentObject var store: Store
    let project: Project

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(store.color(of: project))
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name).font(.system(size: 12.5))
                if !project.files.isEmpty {
                    Text("\(project.files.count) file\(project.files.count == 1 ? "" : "s")")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct ConversationRow: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var conductor: Conductor
    let conversation: Conversation
    let running: Bool

    var body: some View {
        HStack(spacing: 8) {
            if conversation.isRoom {
                // Overlapping voice dots — a facepile, small and calm.
                HStack(spacing: -3) {
                    ForEach(Array(conversation.roomModelKeys.prefix(4)), id: \.self) { key in
                        Circle().fill(Palette.voice(key)).frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                    }
                }
                .frame(width: 18, alignment: .leading)
            } else if conversation.colorHex != nil || conversation.accent != nil {
                Circle().fill(store.color(of: conversation)).frame(width: 7, height: 7)
            } else {
                VoiceDot(key: conversation.modelKey, size: 7)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Text(conversation.preview)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if conversation.pinned {
                Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            if running {
                ThinkingDots()
            } else if conductor.finishedWhileAway.contains(conversation.id) {
                // Finished while you were elsewhere — unread until opened.
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    .help("Finished while you were in another chat")
            }
        }
        .padding(.vertical, 1)
    }
}
