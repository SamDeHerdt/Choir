// Choir — made by Sam De Herdt for MakeWaves.
import SwiftUI
import AppKit

/// A small block-level Markdown renderer. Enough for what models actually
/// emit — headings, lists, quotes, fenced code, inline emphasis and links —
/// without taking on a dependency for it.
enum MD {
    enum Block: Identifiable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet([String])
        case numbered([String])
        case quote(String)
        case code(language: String, body: String)
        case table(header: [String], rows: [[String]])
        case rule

        var id: String {
            switch self {
            case .heading(let l, let t): return "h\(l)-\(t.hashValue)"
            case .paragraph(let t): return "p-\(t.hashValue)"
            case .bullet(let items): return "u-\(items.joined().hashValue)"
            case .numbered(let items): return "o-\(items.joined().hashValue)"
            case .quote(let t): return "q-\(t.hashValue)"
            case .code(let l, let b): return "c-\(l)-\(b.hashValue)"
            case .table(let h, let r): return "t-\(h.joined().hashValue)-\(r.count)"
            case .rule: return "hr-\(UUID().uuidString)"
            }
        }
    }

    static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        // "\r\n" is one Character in Swift, so split on both endings explicitly.
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i]); i += 1
                }
                i += 1  // closing fence, or the end of a stream mid-block
                blocks.append(.code(language: language, body: body.joined(separator: "\n")))
                continue
            }

            if trimmed.hasPrefix("|"), i + 1 < lines.count, isSeparatorRow(lines[i + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                if hashes <= 6, trimmed.dropFirst(hashes).hasPrefix(" ") {
                    flushParagraph()
                    blocks.append(.heading(level: hashes, text: String(trimmed.dropFirst(hashes + 1))))
                    i += 1
                    continue
                }
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph(); blocks.append(.rule); i += 1; continue
            }

            if trimmed.hasPrefix("> ") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            if isBullet(trimmed) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, isBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst(2)))
                    i += 1
                }
                blocks.append(.bullet(items))
                continue
            }

            if let _ = numberedPrefix(trimmed) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, let n = numberedPrefix(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst(n)))
                    i += 1
                }
                blocks.append(.numbered(items))
                continue
            }

            if trimmed.isEmpty { flushParagraph() } else { paragraph.append(line) }
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func isSeparatorRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.contains("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var t = line
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isBullet(_ s: String) -> Bool {
        s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ")
    }

    /// Length of a `12. ` prefix, or nil.
    private static func numberedPrefix(_ s: String) -> Int? {
        let digits = s.prefix(while: \.isNumber)
        guard !digits.isEmpty, s.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return digits.count + 2
    }

    /// Inline emphasis, code spans and links. Falls back to plain text rather
    /// than dropping a half-streamed line.
    static func inline(_ source: String) -> AttributedString {
        (try? AttributedString(markdown: source, options: .init(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        ))) ?? AttributedString(source)
    }
}

struct MarkdownText: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MD.parse(source)) { block in
                switch block {
                case .heading(let level, let text):
                    Text(MD.inline(text))
                        .font(.system(size: level <= 1 ? 19 : level == 2 ? 16 : 14, weight: .semibold))
                        .padding(.top, 2)
                case .paragraph(let text):
                    Text(MD.inline(text))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .bullet(let items):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(.secondary)
                                Text(MD.inline(item)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case .numbered(let items):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                                Text(MD.inline(item)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case .quote(let text):
                    HStack(alignment: .top, spacing: 10) {
                        Rectangle().frame(width: 2).foregroundStyle(.secondary.opacity(0.4))
                        Text(MD.inline(text)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .code(let language, let body):
                    CodeBlock(language: language, code: body)
                case .table(let header, let rows):
                    MarkdownTable(header: header, rows: rows)
                case .rule:
                    Divider().padding(.vertical, 2)
                }
            }
        }
        .textSelection(.enabled)
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    withAnimation(Motion.on(Motion.bounce(Motion.fast))) { copied = true }
                    Task { try? await Task.sleep(nanoseconds: 1_400_000_000); withAnimation(Motion.on(Motion.smoothOut(Motion.quick))) { copied = false } }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? .green : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Divider().opacity(0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}


/// A pipe table as a real grid: header row emphasised, hairlines between rows,
/// scrolls sideways when it is wider than the bubble.
struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(MD.inline(cell)).font(.system(size: 12, weight: .semibold))
                            .padding(.vertical, 6)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(MD.inline(cell)).font(.system(size: 12.5))
                                .padding(.vertical, 5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if index < rows.count - 1 { Divider().opacity(0.5) }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.10)))
    }
}
