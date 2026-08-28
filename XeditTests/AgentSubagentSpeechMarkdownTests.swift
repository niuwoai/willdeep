import Foundation
import SwiftUI
import Testing
@testable import WillDeep

/// A Worker reporting a build writes Markdown — tables of steps, fenced
/// commands, `**bold**` verdicts. The card used to print all of that raw,
/// so the most information-dense thing a Worker ever says was the least
/// readable thing on screen.
///
/// Everything here also defends the constraint the renderer exists under:
/// the output is one attributed string, so none of these cases can turn
/// into a SwiftUI view tree on a surface that repaints every heartbeat.
@Suite
@MainActor
struct AgentSubagentSpeechMarkdownTests {
    private func plainText(_ rendered: AttributedString) -> String {
        String(rendered.characters)
    }

    @Test("inline markers are consumed, not printed")
    func inlineMarkersAreBaked() {
        let rendered = AgentSubagentSpeechMarkdown.attributed(
            from: "**`gofmt -l` 退出码为 0**，其余文件格式已正确。",
            baseSize: 10
        )
        let text = plainText(rendered)

        #expect(!text.contains("**"))
        #expect(text.contains("gofmt -l"))
        #expect(text.contains("退出码为 0"))
    }

    /// The case from the report that started this: a four-row step table
    /// arriving as `| Step | Command | Result |` pipe rows.
    @Test("a markdown table becomes aligned columns instead of pipe rows")
    func tablesAreLaidOut() {
        let raw = """
        | Step | Command | Result |
        |---|---|---|
        | 1 | `go build ./...` | 编译成功 |
        | 2 | `go test ./internal/gateway/` | ok 0.605s |
        """
        let rendered = AgentSubagentSpeechMarkdown.attributed(from: raw, baseSize: 10)
        let text = plainText(rendered)

        #expect(!text.contains("|---|"))
        #expect(text.contains("│"))
        #expect(text.contains("─┼─"))
        #expect(text.contains("go build ./..."))
        #expect(text.contains("ok 0.605s"))

        // Columns only line up if the table runs are monospaced.
        let monospaced = rendered.runs.contains { run in
            run.font == .system(size: 9.5, design: .monospaced)
        }
        #expect(monospaced)
    }

    @Test("headings and list markers become structure, not literal # and -")
    func blockMarkersAreConsumed() {
        let rendered = AgentSubagentSpeechMarkdown.attributed(
            from: "## 结论\n- 编译通过\n- 单测通过",
            baseSize: 10
        )
        let text = plainText(rendered)

        #expect(!text.contains("## "))
        #expect(text.contains("结论"))
        #expect(text.contains("•"))
        #expect(!text.contains("- 编译通过"))
    }

    @Test("a fenced block keeps its contents verbatim in monospace")
    func fencedCodeKeepsItsText() {
        let rendered = AgentSubagentSpeechMarkdown.attributed(
            from: "先跑这个：\n```bash\nyarn test --watch=false\n```",
            baseSize: 10
        )
        let text = plainText(rendered)

        #expect(text.contains("yarn test --watch=false"))
        #expect(!text.contains("```"))
    }

    /// Most rounds are one sentence. That path must stay exactly as cheap
    /// as the plain `Text` it replaced — same characters, one run.
    @Test("plain prose survives unchanged")
    func proseIsUntouched() {
        let raw = "问题出在配置文件包含中文字符，默认编码无法处理。"
        let rendered = AgentSubagentSpeechMarkdown.attributed(from: raw, baseSize: 10)

        #expect(plainText(rendered) == raw)
    }

    @Test("empty input renders nothing rather than crashing")
    func emptyInputIsSafe() {
        #expect(plainText(AgentSubagentSpeechMarkdown.attributed(from: "", baseSize: 10)).isEmpty)
    }

    /// A round's text is clamped to 600 characters before it ever reaches
    /// here, so the renderer is regularly handed a table whose last row was
    /// cut mid-cell. It has to lay that out, not throw it away.
    @Test("a table truncated mid-row still lays out")
    func truncatedTableStillRenders() {
        let raw = """
        | Step | Result |
        |---|---|
        | 1 | ok |
        | 2 | ok tokenhub/interna
        """
        let text = plainText(AgentSubagentSpeechMarkdown.attributed(from: raw, baseSize: 10))

        #expect(text.contains("ok tokenhub/interna"))
        #expect(!text.contains("|---|"))
    }
}
