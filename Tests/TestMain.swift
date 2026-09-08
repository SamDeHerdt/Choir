// Choir — headless checks. Run with: bash run-tests.sh
import Foundation

@main
struct TestMain {
    static var failures = 0

    static func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        print(condition ? "  ok   \(label)" : "  FAIL \(label) \(detail)")
        if !condition { failures += 1 }
    }

    static func main() async {
        print("Markdown")
        let blocks = MD.parse("# Title\n\nSome *text*.\n\n- one\n- two\n\n```swift\nlet x = 1\n```\n")
        check("parses five blocks", blocks.count == 4, "got \(blocks.count)")
        if case .code(let language, let body) = blocks[3] {
            check("fenced code keeps its language", language == "swift")
            check("fenced code keeps its body", body == "let x = 1")
        } else {
            check("last block is code", false)
        }
        let unterminated = MD.parse("text\n\n```\nstill streaming")
        check("an unclosed fence still parses", unterminated.count == 2)

        print("Transcript assembly")
        let turns = [
            WireTurn(role: "user", text: "first"),
            WireTurn(role: "assistant", text: "answer"),
            WireTurn(role: "user", text: "second"),
        ]
        let transcript = CLI.transcript(turns)
        check("earlier turns are labelled", transcript.contains("Assistant:\nanswer"))
        check("the live question ends the prompt", transcript.hasSuffix("User:\nsecond"))
        check("a single turn is passed through bare", CLI.transcript([WireTurn(role: "user", text: "solo")]) == "solo")

        print("Library rendering")
        let skill = LibraryItem(kind: .skill, name: "Review", summary: "code lands", body: "Read the diff.")
        check("a skill gets a when-to-use header", skill.rendered().contains("Use this when: code lands"))
        let prompt = LibraryItem(kind: .prompt, name: "Voice", body: "Be short.")
        check("a prompt is passed through raw", prompt.rendered() == "Be short.")

        print("Skill import")
        let (front, body) = SkillImporter.splitFrontmatter("---\nname: demo\ndescription: \"When testing\"\n---\n\n# Demo\nBody here")
        check("frontmatter name parsed", front["name"] == "demo")
        check("quoted description unquoted", front["description"] == "When testing")
        check("body excludes frontmatter", body.hasPrefix("# Demo"))
        let candidates = SkillImporter.scan()
        check("finds the skills on this Mac", !candidates.isEmpty, "found \(candidates.count)")
        check("de-duplicates symlinked skill folders", Set(candidates.map(\.path)).count == candidates.count)
        check("fable-thinking is among them", candidates.contains { $0.name == "fable-thinking" })

        print("CLI discovery")
        check("claude is resolvable", CLI.isInstalled("claude"))
        check("codex is resolvable", CLI.isInstalled("codex"))

        print("Claude bridge — live round trip")
        await roundTrip(
            label: "claude",
            engine: ClaudeCLIEngine(executable: ""),
            model: ModelSpec(backend: .claudeCLI, id: "haiku", label: "Haiku"),
            expect: "ok"
        )

        print("Codex bridge — live round trip")
        await roundTrip(
            label: "codex",
            engine: CodexCLIEngine(executable: ""),
            model: ModelSpec(backend: .codexCLI, id: "", label: "Codex"),
            expect: "ok"
        )

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }

    static func roundTrip(label: String, engine: ChatEngine, model: ModelSpec, expect: String) async {
        var text = ""
        var statuses: [String] = []
        var thrown: String?
        var settings = AppSettings()
        settings.maxTokens = 256
        do {
            for try await chunk in engine.stream(
                system: "Answer with the single word ok, lowercase, nothing else.",
                turns: [WireTurn(role: "user", text: "ping")],
                model: model, settings: settings
            ) {
                switch chunk {
                case .text(let t): text += t
                case .status(let s): statuses.append(s)
                case .reasoning, .done: break
                }
            }
        } catch {
            thrown = error.localizedDescription
        }
        check("\(label) did not throw", thrown == nil, thrown ?? "")
        check("\(label) reported a status while working", !statuses.isEmpty)
        check("\(label) answered \"\(expect)\"", text.lowercased().contains(expect), "got: \(text.prefix(120))")
    }
}
