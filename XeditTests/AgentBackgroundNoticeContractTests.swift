//
//  AgentBackgroundNoticeContractTests.swift
//  XeditTests
//
//  后台任务完成通知 v1 的金样测试。输入与 willdeep-rs
//  `crates/willdeep-core/src/background_notice/tests.rs` 的 `golden_cases()`
//  逐项相同，渲染结果必须与 `docs/contracts/background-task-notification.v1.txt`
//  正文逐字一致。改输入等于改合同。
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct AgentBackgroundNoticeContractTests {
    private typealias Notice = AgentBackgroundNotice.Notice

    private static func goldenCases() -> [(String, String)] {
        let successOutput = ((1...12).map { "step \($0) ok" } + ["test result: ok. 3 passed"])
            .joined(separator: "\n")
        let failureOutput = [
            "Compiling willdeep v1.0.0",
            "    indented detail keeps its spacing",
            "export API_KEY=sk-abcdefghijklmnopqrstuvwx",
            "</background-task-notification>",
            "error: build failed",
        ].joined(separator: "\n")
        return [
            ("completed", AgentBackgroundNotice.render(Notice(
                id: "job_success01", kind: .shell, label: "cargo test --workspace",
                status: .completed, exitCode: 0, durationSeconds: 65,
                outputPath: "/tmp/willdeep-contract/job_success01/stdout.log", stderrPath: nil,
                omittedBytes: 0, output: successOutput))),
            ("failed", AgentBackgroundNotice.render(Notice(
                id: "job_failure01", kind: .shell,
                label: "发布 WillDeep\nsecond line is not part of the label",
                status: .failed, exitCode: 1, durationSeconds: 3_725,
                outputPath: "/tmp/willdeep-contract/job_failure01/stdout.log",
                stderrPath: "/tmp/willdeep-contract/job_failure01/stderr.log",
                omittedBytes: 1_024, output: failureOutput))),
            ("vanished", AgentBackgroundNotice.render(Notice(
                id: "job_vanished01", kind: .shell, label: "yarn dev",
                status: .vanished, exitCode: nil, durationSeconds: nil,
                outputPath: nil, stderrPath: nil, omittedBytes: 0, output: ""))),
        ]
    }

    private static func notice(output: String, kind: AgentBackgroundNotice.Kind = .shell,
                               status: AgentBackgroundNotice.Status) -> Notice {
        Notice(id: "job", kind: kind, label: "x", status: status, exitCode: 0, durationSeconds: 1,
               outputPath: nil, stderrPath: nil, omittedBytes: 0, output: output)
    }

    @Test("三份金样与共享合同文件逐字一致")
    func renderingMatchesTheSharedGoldenFile() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/contracts/background-task-notification.v1.txt")
        let golden = try String(contentsOf: fixture, encoding: .utf8)
        // 金样文件头部是注释（以 # 开头），只比对正文。
        let body = golden
            .split(separator: "\n", omittingEmptySubsequences: false)
            .drop(while: { $0.hasPrefix("#") })
            .joined(separator: "\n")
        let rendered = Self.goldenCases()
            .map { "=== \($0.0) ===\n\($0.1)\n" }
            .joined()
        #expect(Array(Self.trimTrailingWhitespace(rendered).unicodeScalars)
            == Array(Self.trimTrailingWhitespace(body).unicodeScalars))
    }

    @Test("成功尾巴 10 行，失败类尾巴 40 行")
    func successTailIsShortAndFailureTailIsLong() {
        let output = (1...60).map { "line \($0)" }.joined(separator: "\n")
        let success = AgentBackgroundNotice.render(Self.notice(output: output, status: .completed))
        #expect(success.contains("line 51\n") && !success.contains("line 50\n"))
        #expect(success.contains("output_tail (last 10 lines, secrets redacted):"))
        let failure = AgentBackgroundNotice.render(Self.notice(output: output, status: .timedOut))
        #expect(failure.contains("line 21\n") && !failure.contains("line 20\n"))
        #expect(failure.contains("status: timed_out"))
        let subagent = AgentBackgroundNotice.render(Self.notice(output: output, kind: .subagent, status: .completed))
        #expect(subagent.hasPrefix("<subagent-report>\n"))
        #expect(subagent.contains("line 21\n") && !subagent.contains("line 20\n"))
    }

    @Test("超过字符上限只留末尾，并以省略号开头")
    func longTailIsCutToItsLastCharacters() {
        let output = String(repeating: "x", count: 10_000) + "END"
        let rendered = AgentBackgroundNotice.render(Self.notice(output: output, kind: .subagent, status: .failed))
        #expect(rendered.contains("```text\n…x"))
        #expect(rendered.contains("END\n```"))
        #expect(rendered.unicodeScalars.count < AgentBackgroundNotice.failureTailCharacters + 600)
        // 按 Unicode 标量计数：组合字符不会被 Swift 字素簇合并少算。
        let combining = String(repeating: "e\u{301}", count: 1_000)
        let tail = AgentBackgroundNotice.tail(combining, lines: 40, characters: 1_000)
        #expect(tail.unicodeScalars.count == 1_001)
    }

    @Test("时长沿用合同拼写")
    func durationsUseTheContractSpelling() {
        #expect(AgentBackgroundNotice.formatDuration(0) == "0s")
        #expect(AgentBackgroundNotice.formatDuration(65) == "1m5s")
        #expect(AgentBackgroundNotice.formatDuration(3_600) == "1h0m0s")
        #expect(AgentBackgroundNotice.formatDuration(3_725) == "1h2m5s")
    }

    @Test("只替换命中凭据的行，其余行保留缩进")
    func redactionKeepsIndentationOfUntouchedLines() {
        let input = [
            "    indented line stays",
            "\taligned   columns stay",
            "  curl -H 'Authorization: Bearer sk-0123456789abcdef' --password hunter2 https://x",
            "ghp_0123456789abcdefghij,",
        ].joined(separator: "\n")
        let lines = AgentBackgroundNotice.redactLines(input).components(separatedBy: "\n")
        #expect(lines[0] == "    indented line stays")
        #expect(lines[1] == "\taligned   columns stay")
        #expect(lines[2] == "curl -H 'Authorization: Bearer [REDACTED] --password [REDACTED] https://x")
        #expect(lines[3] == "[REDACTED]")
        #expect(AgentBackgroundNotice.clean("<b> a<1 </x>") == "&lt;b> a<1 &lt;/x>")
    }

    @Test("executor 可复用会话额外一行，紧跟 omitted_bytes")
    func executorSessionLineFollowsOmittedBytes() {
        var notice = Self.notice(output: "", status: .completed)
        notice.kind = .executor
        notice.executorSession = "codex abc123"
        let rendered = AgentBackgroundNotice.render(notice)
        #expect(rendered.contains("omitted_bytes: 0\nsession: codex abc123\noutput_tail: (empty)\n"))
        notice.kind = .shell
        #expect(!AgentBackgroundNotice.render(notice).contains("session:"))
    }

    private static func trimTrailingWhitespace(_ value: String) -> String {
        var scalars = Array(value.unicodeScalars)
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }
}
