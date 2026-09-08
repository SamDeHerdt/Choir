// Choir — made by Sam De Herdt for MakeWaves.
import Foundation
import SwiftUI
import AppKit

/// Runs turns. Everything a backend needs is assembled here — never inside a
/// view — so a chat, a room round and a regenerate all take the same path and
/// a thread can change model between any two turns.
@MainActor
final class Conductor: ObservableObject {
    @Published private(set) var running: Set<UUID> = []
    /// Conversations that finished while another one was open. Cleared when
    /// the conversation is shown; the sidebar marks them and a toast offers a jump.
    @Published var finishedWhileAway: Set<UUID> = []
    @Published var lastFinished: (id: UUID, title: String)?

    func markSeen(_ conversationID: UUID) {
        finishedWhileAway.remove(conversationID)
        if lastFinished?.id == conversationID { lastFinished = nil }
    }

    private func noteFinished(_ conversationID: UUID, store: Store) {
        guard store.selection != conversationID || !NSApp.isActive,
              let c = store.conversations.first(where: { $0.id == conversationID }) else { return }
        finishedWhileAway.insert(conversationID)
        lastFinished = (conversationID, c.title)
    }
    /// Per-message status text, shown while a backend has started but not spoken.
    @Published private(set) var status: [UUID: String] = [:]
    /// Messages typed while a turn was still running. They go out one by one,
    /// in order, each as its own turn — so you can keep thinking ahead.
    @Published private(set) var queue: [UUID: [QueuedMessage]] = [:]

    struct QueuedMessage: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var attachments: [ProjectFile]
    }

    func queued(for conversationID: UUID) -> [QueuedMessage] { queue[conversationID] ?? [] }

    func enqueue(_ text: String, attachments: [ProjectFile], conversationID: UUID) {
        queue[conversationID, default: []].append(QueuedMessage(text: text, attachments: attachments))
    }

    func dequeue(_ id: UUID, conversationID: UUID) {
        queue[conversationID]?.removeAll { $0.id == id }
    }

    private func sendNextQueued(conversationID: UUID, store: Store) {
        guard var list = queue[conversationID], !list.isEmpty else { return }
        let next = list.removeFirst()
        queue[conversationID] = list.isEmpty ? nil : list
        send(next.text, attachments: next.attachments, conversationID: conversationID, store: store)
    }

    private var tasks: [UUID: Task<Void, Never>] = [:]

    func isRunning(_ conversationID: UUID) -> Bool { running.contains(conversationID) }

    func stop(_ conversationID: UUID) {
        tasks[conversationID]?.cancel()
        tasks[conversationID] = nil
        running.remove(conversationID)
        queue[conversationID] = nil
    }

    // MARK: - Sending

    func send(_ text: String, attachments: [ProjectFile] = [], conversationID: UUID, store: Store) {
        guard let i = store.index(of: conversationID) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        var user = Message(role: .user, text: trimmed.isEmpty ? "See the attached file\(attachments.count == 1 ? "" : "s")." : trimmed)
        if !attachments.isEmpty { user.attachments = attachments }
        user.appliedLibrary = store.appliedNames(for: store.conversations[i])
        store.conversations[i].messages.append(user)
        store.touch(conversationID)

        run(conversationID: conversationID, store: store)
    }

    /// Retry all from a given question: everything after it goes, and the
    /// round runs again with every voice.
    func regenerate(fromPrompt promptID: UUID, conversationID: UUID, store: Store) {
        guard let i = store.index(of: conversationID),
              let at = store.conversations[i].messages.firstIndex(where: { $0.id == promptID }) else { return }
        stop(conversationID)
        store.conversations[i].messages.removeSubrange((at + 1)...)
        run(conversationID: conversationID, store: store)
    }

    /// Drops the last assistant answer (or answers, in a room) and asks again.
    func regenerate(conversationID: UUID, store: Store) {
        guard let i = store.index(of: conversationID) else { return }
        while let last = store.conversations[i].messages.last, last.role == .assistant {
            store.conversations[i].messages.removeLast()
        }
        run(conversationID: conversationID, store: store)
    }

    /// Re-asks one voice in a room without touching the others. The answer
    /// keeps its place; in relay/debate modes the voice still reads what the
    /// other voices said in that round.
    func retryVoice(_ messageID: UUID, conversationID: UUID, store: Store) {
        guard !isRunning(conversationID),
              let i = store.index(of: conversationID),
              let at = store.conversations[i].messages.firstIndex(where: { $0.id == messageID }),
              let key = store.conversations[i].messages[at].modelKey,
              let spec = store.settings.model(key: key) else { return }
        let conversation = store.conversations[i]
        let messages = conversation.messages
        let roundStart = messages[..<at].lastIndex(where: { $0.role == .user }) ?? 0
        let roundEnd = messages[(at + 1)...].firstIndex(where: { $0.role == .user }) ?? messages.count
        let heard: [(String, String)] = messages[roundStart..<roundEnd].compactMap { m in
            guard m.role == .assistant, m.id != messageID, !m.text.isEmpty, m.error == nil else { return nil }
            return (m.modelLabel ?? "another model", m.text)
        }
        var placeholder = placeholderMessage(for: spec)
        placeholder.id = messageID  // keep identity so the bubble stays in place
        withAnimation(Motion.on(Motion.smoothOut(Motion.fast))) {
            store.conversations[i].messages[at] = placeholder
        }
        running.insert(conversationID)
        let task = Task { [weak self] in
            guard let self, let conv = store.conversations.first(where: { $0.id == conversationID }) else { return }
            let context = conv.roomMode == .parallel ? nil : self.relayContext(heard)
            let turns = self.wireTurns(conv, perspective: conv.isRoom ? key : nil, extraContext: context)
            await self.stream(spec: spec, turns: turns, conversationID: conversationID, store: store, into: messageID)
            self.running.remove(conversationID)
            self.tasks[conversationID] = nil
            store.touch(conversationID)
            store.save()
            self.noteFinished(conversationID, store: store)
        }
        tasks[conversationID] = task
    }

    private func run(conversationID: UUID, store: Store) {
        stop(conversationID)
        running.insert(conversationID)
        let task = Task { [weak self] in
            guard let self else { return }
            guard let conversation = store.conversations.first(where: { $0.id == conversationID }) else { return }
            if conversation.isRoom {
                await self.runRoom(conversationID: conversationID, store: store)
            } else {
                await self.runSingle(conversationID: conversationID, store: store, modelKey: conversation.modelKey)
            }
            self.running.remove(conversationID)
            self.tasks[conversationID] = nil
            store.touch(conversationID)
            store.save()
            // A long room round finishing while you are elsewhere: one bounce,
            // a mark in the sidebar, and a toast with a way back.
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            self.noteFinished(conversationID, store: store)
            if !Task.isCancelled { self.sendNextQueued(conversationID: conversationID, store: store) }
        }
        tasks[conversationID] = task
    }

    // MARK: - One model

    private func runSingle(conversationID: UUID, store: Store, modelKey: String) async {
        guard let conversation = store.conversations.first(where: { $0.id == conversationID }) else { return }
        guard let spec = store.settings.model(key: modelKey) else {
            appendFailure("No model selected. Pick one under the composer.", conversationID: conversationID, store: store, modelKey: modelKey)
            return
        }
        let turns = wireTurns(conversation, perspective: nil, extraContext: nil)
        await stream(spec: spec, turns: turns, conversationID: conversationID, store: store)
    }

    // MARK: - Rooms

    private func runRoom(conversationID: UUID, store: Store) async {
        guard let conversation = store.conversations.first(where: { $0.id == conversationID }) else { return }
        var seenFamilies = Set<String>()
        let keys = conversation.roomModelKeys.filter { key in
            guard let spec = store.settings.model(key: key) else { return false }
            return seenFamilies.insert(spec.family).inserted
        }
        guard !keys.isEmpty else {
            appendFailure("This room has no models. Add some in the room header.", conversationID: conversationID, store: store, modelKey: "")
            return
        }

        switch conversation.roomMode {
        case .parallel:
            // Every model gets its own placeholder up front so the columns
            // appear together rather than popping in one by one.
            var ids: [(String, UUID)] = []
            for key in keys {
                guard let spec = store.settings.model(key: key) else { continue }
                ids.append((key, placeholder(for: spec, conversationID: conversationID, store: store)))
            }
            await withTaskGroup(of: Void.self) { group in
                for (key, messageID) in ids {
                    guard let spec = store.settings.model(key: key),
                          let conv = store.conversations.first(where: { $0.id == conversationID }) else { continue }
                    let turns = wireTurns(conv, perspective: key, extraContext: nil)
                    group.addTask { @MainActor in
                        await self.stream(spec: spec, turns: turns, conversationID: conversationID, store: store, into: messageID)
                    }
                }
            }

        case .relay, .debate:
            var heard: [(String, String)] = []
            for key in keys {
                if Task.isCancelled { return }
                guard let spec = store.settings.model(key: key),
                      let conv = store.conversations.first(where: { $0.id == conversationID }) else { continue }
                let turns = wireTurns(conv, perspective: key, extraContext: relayContext(heard))
                let messageID = placeholder(for: spec, conversationID: conversationID, store: store)
                await stream(spec: spec, turns: turns, conversationID: conversationID, store: store, into: messageID)
                if let text = message(messageID, conversationID: conversationID, store: store)?.text, !text.isEmpty {
                    heard.append((spec.label, text))
                }
            }
        }
    }

    private func relayContext(_ heard: [(String, String)]) -> String? {
        guard !heard.isEmpty else { return nil }
        return """
        Other models have already answered this question. Read them, then give your own answer: agree, disagree, or add what they missed. Do not repeat what is already said well.

        \(heard.map { "### \($0.0)\n\($0.1)" }.joined(separator: "\n\n"))
        """
    }

    // MARK: - Wire assembly

    /// Turns the stored thread into what a backend sees.
    /// `perspective` (rooms only) hides other models' answers, so a parallel
    /// round really is blind. `extraContext` is appended to the last user turn.
    private func wireTurns(_ conversation: Conversation, perspective: String?, extraContext: String?, replaceLastUser: Bool = false) -> [WireTurn] {
        var turns: [WireTurn] = []
        var preferredByOthers: [String] = []
        for m in conversation.messages {
            guard m.error == nil, !m.text.isEmpty else { continue }
            switch m.role {
            case .user:
                var text = m.text
                for a in m.attachments ?? [] {
                    text += "\n\n[Attached file: \(a.name)]\n\(a.text)"
                }
                turns.append(WireTurn(role: "user", text: text))
            case .assistant:
                if let perspective, m.modelKey != perspective {
                    // Blind to rivals — except the answer the user picked.
                    // That one becomes shared ground for everybody.
                    guard m.isPreferred else { continue }
                    let label = m.modelLabel ?? "another model"
                    preferredByOthers.append(label)
                    turns.append(WireTurn(role: "user",
                                          text: "[The user preferred this answer, by \(label):]\n\(m.text)"))
                    continue
                }
                turns.append(WireTurn(role: "assistant", text: m.text))
            case .system:
                continue
            }
        }
        // Consecutive user turns confuse some backends; fold them together.
        turns = turns.reduce(into: [WireTurn]()) { acc, turn in
            if let last = acc.last, last.role == "user", turn.role == "user" {
                acc[acc.count - 1] = WireTurn(role: "user", text: "\(last.text)\n\n\(turn.text)")
            } else {
                acc.append(turn)
            }
        }
        var context = extraContext
        if !preferredByOthers.isEmpty {
            let nudge = "The user preferred the answer marked above (by \(preferredByOthers.last!)). Take it as the agreed starting point and go further from it — do not restate it, and do not re-argue your earlier position unless it changes the outcome."
            context = context.map { "\($0)\n\n\(nudge)" } ?? nudge
        }
        if let context, let last = turns.lastIndex(where: { $0.role == "user" }) {
            let base = replaceLastUser ? turns[last].text : turns[last].text
            turns[last] = WireTurn(role: "user", text: "\(base)\n\n---\n\(context)")
        }
        // A backend that receives no user turn has nothing to answer.
        if turns.isEmpty { turns = [WireTurn(role: "user", text: "Hello")] }
        return turns
    }

    // MARK: - Message plumbing

    private func placeholderMessage(for spec: ModelSpec) -> Message {
        var m = Message(role: .assistant, text: "")
        m.modelKey = spec.key
        m.modelLabel = spec.label
        m.isStreaming = true
        m.startedAt = Date()
        return m
    }

    private func placeholder(for spec: ModelSpec, conversationID: UUID, store: Store) -> UUID {
        insert(placeholderMessage(for: spec), conversationID: conversationID, store: store)
    }

    @discardableResult
    private func insert(_ message: Message, conversationID: UUID, store: Store) -> UUID {
        guard let i = store.index(of: conversationID) else { return message.id }
        withAnimation(Motion.on(Motion.smoothOut(Motion.fast))) {
            store.conversations[i].messages.append(message)
        }
        return message.id
    }

    private func message(_ id: UUID, conversationID: UUID, store: Store) -> Message? {
        guard let i = store.index(of: conversationID) else { return nil }
        return store.conversations[i].messages.first { $0.id == id }
    }

    private func appendFailure(_ text: String, conversationID: UUID, store: Store, modelKey: String) {
        guard let i = store.index(of: conversationID) else { return }
        var m = Message(role: .assistant, text: "")
        m.modelKey = modelKey
        m.modelLabel = store.settings.model(key: modelKey)?.label
        m.error = text
        store.conversations[i].messages.append(m)
    }

    // MARK: - The stream itself

    private func stream(spec: ModelSpec, turns: [WireTurn], conversationID: UUID, store: Store, into existing: UUID? = nil) async {
        guard let conversation = store.conversations.first(where: { $0.id == conversationID }) else { return }
        let messageID = existing ?? placeholder(for: spec, conversationID: conversationID, store: store)
        let system = store.systemPrompt(for: conversation)
        let engine = EngineFactory.engine(for: spec.backend, settings: store.settings) { store.apiKey(for: $0) }

        var text = ""
        var reasoning = ""
        var pending = ""
        var pendingReasoning = ""
        var lastFlush = Date()

        /// Streaming can arrive a token at a time; committing to @Published on
        /// every one makes the whole list redraw. Flush on size or on a beat.
        func flush(force: Bool = false) {
            guard force || pending.count > 16 || pendingReasoning.count > 40 || Date().timeIntervalSince(lastFlush) > 0.06 else { return }
            guard !pending.isEmpty || !pendingReasoning.isEmpty else { return }
            text += pending; reasoning += pendingReasoning
            pending = ""; pendingReasoning = ""
            lastFlush = Date()
            update(messageID, conversationID: conversationID, store: store) {
                $0.text = text
                $0.reasoning = reasoning
            }
        }

        do {
            for try await chunk in engine.stream(system: system, turns: turns, model: spec, settings: store.settings) {
                if Task.isCancelled { break }
                switch chunk {
                case .text(let t):
                    if status[messageID] != nil { status[messageID] = nil }
                    if text.isEmpty && pending.isEmpty {
                        update(messageID, conversationID: conversationID, store: store) { $0.firstTokenAt = Date() }
                    }
                    pending += t
                    flush()
                case .reasoning(let t):
                    pendingReasoning += t
                    flush()
                case .status(let s):
                    status[messageID] = s
                case .done:
                    flush(force: true)
                }
            }
            flush(force: true)
            status[messageID] = nil
            update(messageID, conversationID: conversationID, store: store) {
                $0.isStreaming = false
                $0.finishedAt = Date()
                if $0.text.isEmpty && $0.error == nil {
                    $0.error = Task.isCancelled ? "Stopped." : "\(spec.label) returned nothing."
                }
            }
        } catch is CancellationError {
            flush(force: true)
            status[messageID] = nil
            update(messageID, conversationID: conversationID, store: store) {
                $0.isStreaming = false
                $0.finishedAt = Date()
                if $0.text.isEmpty { $0.error = "Stopped." }
            }
        } catch {
            flush(force: true)
            status[messageID] = nil
            update(messageID, conversationID: conversationID, store: store) {
                $0.isStreaming = false
                $0.finishedAt = Date()
                $0.error = error.localizedDescription
            }
        }
        store.scheduleSave()
    }

    private func update(_ id: UUID, conversationID: UUID, store: Store, _ change: (inout Message) -> Void) {
        guard let i = store.index(of: conversationID),
              let j = store.conversations[i].messages.firstIndex(where: { $0.id == id }) else { return }
        change(&store.conversations[i].messages[j])
    }
}
