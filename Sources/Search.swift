// Choir — made by Sam De Herdt for MakeWaves.
import SwiftUI

/// A hit the reader clicked: which chat, which message inside it, and the
/// phrase to light up. Opening the chat is not enough — a search that drops
/// you at the top of a two-hundred-turn thread has not answered the question.
/// `token` is fresh on every jump, so clicking the same match twice scrolls
/// there again.
struct SearchJump: Equatable {
    let conversationID: UUID
    let messageID: UUID
    let term: String
    let token = UUID()
}

/// One matching message, with enough text around the match to recognise it
/// from the sidebar.
struct SearchHit {
    let messageID: UUID
    let snippet: String
}

extension Conversation {
    /// Messages are scanned in order, so the first hit is the earliest one —
    /// which is what "where did this start" is asking for.
    func firstHit(for term: String) -> SearchHit? {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        for message in messages where message.text.localizedCaseInsensitiveContains(term) {
            return SearchHit(messageID: message.id, snippet: SearchSnippet.around(term, in: message.text))
        }
        return nil
    }

    /// Every message that contains the phrase, in thread order — what the
    /// header steps through.
    func hits(for term: String) -> [SearchHit] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        return messages
            .filter { $0.text.localizedCaseInsensitiveContains(term) }
            .map { SearchHit(messageID: $0.id, snippet: SearchSnippet.around(term, in: $0.text)) }
    }

    /// Messages that contain the phrase, not occurrences — the sidebar counts
    /// places to jump to, not repetitions.
    func matchCount(for term: String) -> Int {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return 0 }
        return messages.filter { $0.text.localizedCaseInsensitiveContains(term) }.count
    }

    func matches(_ term: String) -> Bool {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(term)
            || messages.contains { $0.text.localizedCaseInsensitiveContains(term) }
    }
}

enum SearchSnippet {
    /// One line centred on the match: a little before it so you know where you
    /// are, cut at word boundaries so it does not read as gibberish.
    static func around(_ term: String, in text: String, before: Int = 28, after: Int = 72) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard let match = flat.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(flat.prefix(before + after))
        }

        var start = flat.index(match.lowerBound, offsetBy: -before, limitedBy: flat.startIndex) ?? flat.startIndex
        var end = flat.index(match.upperBound, offsetBy: after, limitedBy: flat.endIndex) ?? flat.endIndex

        // Snap outwards-in to whole words, never past the match itself.
        if start > flat.startIndex, let space = flat[start..<match.lowerBound].firstIndex(of: " ") {
            start = flat.index(after: space)
        }
        if end < flat.endIndex, let space = flat[match.upperBound..<end].lastIndex(of: " ") {
            end = space
        }

        var snippet = String(flat[start..<end])
        if start > flat.startIndex { snippet = "…" + snippet }
        if end < flat.endIndex { snippet += "…" }
        return snippet
    }
}

/// Scroll anchors for single messages. The wrapper keeps them out of the round
/// ids' namespace — a round is tagged with its prompt's id, and two views in
/// one scroll view must not share an id.
struct MessageAnchor: Hashable {
    let id: UUID
}

// MARK: - The flash on arrival

private struct SearchHitKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

private struct SearchTermKey: EnvironmentKey {
    static let defaultValue: String = ""
}

extension EnvironmentValues {
    /// The message the reader was just taken to, while it is still lit.
    var searchHitID: UUID? {
        get { self[SearchHitKey.self] }
        set { self[SearchHitKey.self] = newValue }
    }

    /// What is in the search box right now. The thread paints it wherever it
    /// appears, so the match is visible in the words and not only by position.
    var searchTerm: String {
        get { self[SearchTermKey.self] }
        set { self[SearchTermKey.self] = newValue }
    }
}

extension AttributedString {
    /// Paint every occurrence of the phrase. Two characters minimum — one
    /// letter would light up half the thread.
    func highlightingSearch(_ term: String) -> AttributedString {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { return self }
        var out = self
        var cursor = out.startIndex
        while cursor < out.endIndex,
              let range = out[cursor...].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
            out[range].backgroundColor = Color.yellow.opacity(0.45)
            cursor = range.upperBound
        }
        return out
    }
}

extension View {
    /// Highlights the current search phrase inside any `MarkdownText` below.
    func searchHighlighted(_ term: String) -> some View {
        environment(\.searchTerm, term)
    }
}

/// Scrolling alone leaves you guessing which turn matched. A ring that fades
/// in on arrival and out a couple of seconds later points at it without
/// leaving a permanent mark on the thread.
struct SearchFlash: ViewModifier {
    @Environment(\.searchHitID) private var hitID
    let messageID: UUID

    func body(content: Content) -> some View {
        let lit = hitID == messageID
        return content
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.accentColor.opacity(lit ? 0.10 : 0))
                    .padding(-10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(lit ? 0.5 : 0), lineWidth: 1.5)
                    .padding(-10)
            )
            .motion(Motion.smoothOut(Motion.medium), value: lit)
    }
}

extension View {
    func searchFlash(_ messageID: UUID) -> some View {
        modifier(SearchFlash(messageID: messageID))
    }
}
