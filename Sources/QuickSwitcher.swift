// Choir — made by Sam De Herdt for MakeWaves.
import SwiftUI

/// ⌘K: type, arrow, return. Chats, projects, library items and models in one
/// list, so nothing in the app is more than a few keystrokes away.
struct QuickSwitcher: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @Binding var route: Route?

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private struct Hit: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let subtitle: String
        let color: Color?
        let run: () -> Void
    }

    private var hits: [Hit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        func match(_ s: String) -> Bool { q.isEmpty || s.localizedCaseInsensitiveContains(q) }
        var out: [Hit] = []

        for c in store.conversations where match(c.title) || (!q.isEmpty && c.firstHit(for: q) != nil) {
            // A body match shows the line it found and, on return, takes you
            // to that message instead of the top of the thread.
            let hit = q.isEmpty ? nil : c.firstHit(for: q)
            out.append(Hit(id: "c-\(c.id)", symbol: c.isRoom ? "person.3.fill" : "bubble.left",
                           title: c.title,
                           subtitle: hit?.snippet ?? (c.isRoom ? "Room" : store.label(forKey: c.modelKey)),
                           color: store.color(of: c)) {
                if let hit {
                    store.searchTerm = q
                    store.jump = SearchJump(conversationID: c.id, messageID: hit.messageID, term: q)
                }
                route = .conversation(c.id)
            })
            if out.count >= 8 { break }
        }
        for p in store.projects where match(p.name) {
            out.append(Hit(id: "p-\(p.id)", symbol: "folder.fill", title: p.name, subtitle: "Project", color: store.color(of: p)) { route = .project(p.id) })
        }
        for item in store.library where match(item.name) || match(item.summary) {
            out.append(Hit(id: "l-\(item.id)", symbol: item.kind.symbol, title: item.name, subtitle: item.kind.label, color: nil) { route = .library(item.kind) })
            if out.count >= 18 { break }
        }
        if case .conversation(let id) = route {
            for m in store.enabledModels where match(m.label) {
                out.append(Hit(id: "m-\(m.key)", symbol: "arrow.left.arrow.right", title: m.label, subtitle: "Switch this chat to \(m.backend.displayName)", color: Palette.voice(m.key)) {
                    guard let i = store.index(of: id) else { return }
                    store.conversations[i].modelKey = m.key
                    store.scheduleSave()
                })
            }
        }
        out.append(Hit(id: "new-chat", symbol: "square.and.pencil", title: "New chat", subtitle: "⌘N", color: nil) { route = .conversation(store.newConversation().id) })
        out.append(Hit(id: "new-room", symbol: "person.3.fill", title: "New room", subtitle: "⌘⇧N", color: nil) { route = .conversation(store.newConversation(room: true).id) })
        return Array(out.prefix(24))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(.secondary)
                TextField("Jump to a chat, project, skill or model…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { pick(highlighted) }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                Text("esc").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(.horizontal, 16).padding(.vertical, 14)

            Divider().opacity(0.5)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                            Button { pick(index) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: hit.symbol)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(hit.color ?? .secondary)
                                        .frame(width: 18)
                                    Text(hit.title).font(.system(size: 13)).lineLimit(1)
                                    Spacer()
                                    Text(hit.subtitle).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                                    if index == highlighted {
                                        Image(systemName: "return").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(index == highlighted ? Color.accentColor.opacity(0.14) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(index)
                            .onHover { if $0 { highlighted = index } }
                        }
                        if hits.isEmpty {
                            Text("Nothing matches.").font(.system(size: 12)).foregroundStyle(.tertiary).padding(20)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: highlighted) { _, new in proxy.scrollTo(new, anchor: .center) }
            }
            .frame(height: 340)
        }
        .frame(width: 560)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func move(_ delta: Int) {
        guard !hits.isEmpty else { return }
        highlighted = min(max(highlighted + delta, 0), hits.count - 1)
    }

    private func pick(_ index: Int) {
        guard hits.indices.contains(index) else { return }
        let run = hits[index].run
        dismiss()
        run()
    }
}
