//
//  AgentExecutorOpenCodeTests.swift
//  WillDeepTests
//
//  opencode 执行器的启动参数与事件解码。
//
//  解码那半边刻意不写手编的 JSON：样本是真的跑 `opencode run --format json`
//  抓下来的，存在 `Fixtures/opencode-stream.jsonl`。照文档猜出来的事件形状
//  能让用例全绿而线上一条都解不出，这类假绿在执行器接入里格外常见——宿主
//  拿不到事件时的表现是「执行器沉默」，跟真的没输出长得一模一样。
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentExecutorOpenCodeTests {
    private func fixtureLines() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/opencode-stream.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - 启动参数

    @Test
    func thePromptIsTheLastArgumentSoLeadingDashesSurvive() {
        let spec = AgentExecutorProcessFactory.openCode(
            executable: "/opt/homebrew/bin/opencode",
            prompt: "--not-a-flag 请修好这个",
            permissionMode: "default",
            model: nil,
            workspacePath: "/tmp/ws",
            imagePaths: [],
            workingDirectory: nil,
            environment: [:],
            sandboxMode: .workspaceWrite
        )
        #expect(spec.arguments.first == "run")
        #expect(spec.arguments.contains(["--format", "json"].joined(separator: " ")) == false)
        #expect(spec.arguments[1] == "--format" && spec.arguments[2] == "json")
        #expect(spec.arguments.contains("--dir"))
        // 正文以 `-` 开头，排在选项中间会被当成选项吃掉
        #expect(spec.arguments.last == "--not-a-flag 请修好这个")
        // 提示词走 argv，stdin 必须是空的，否则 opencode 会等输入
        #expect(spec.standardInput.isEmpty)
        #expect(spec.executor == .openCode)
    }

    @Test
    func autoApprovalIsOptInOnly() {
        func arguments(mode: String) -> [String] {
            AgentExecutorProcessFactory.openCode(
                executable: "opencode",
                prompt: "p",
                permissionMode: mode,
                model: nil,
                workspacePath: nil,
                imagePaths: [],
                workingDirectory: nil,
                environment: [:],
                sandboxMode: .workspaceWrite
            ).arguments
        }
        // opencode 自己把 --auto 标成 "(dangerous!)"，默认档不能带上它
        #expect(!arguments(mode: "default").contains("--auto"))
        #expect(arguments(mode: "auto").contains("--auto"))
    }

    @Test
    func resumeAndModelAndImagesAreForwarded() {
        let spec = AgentExecutorProcessFactory.openCode(
            executable: "opencode",
            prompt: "p",
            permissionMode: "default",
            model: "some-im/deepseek-v4-pro",
            sessionID: "ses_abc",
            workspacePath: nil,
            imagePaths: ["/tmp/a.png", "/tmp/b.png"],
            workingDirectory: nil,
            environment: [:],
            sandboxMode: .workspaceWrite
        )
        #expect(spec.arguments.contains("--session"))
        #expect(spec.arguments.contains("ses_abc"))
        #expect(spec.arguments.contains("some-im/deepseek-v4-pro"))
        #expect(spec.arguments.filter { $0 == "--file" }.count == 2)
    }

    // MARK: - 事件解码

    @Test
    func everyRecordedLineDecodesToSomethingBetterThanRaw() throws {
        let decoder = OpenCodeStreamEventDecoder()
        let lines = try fixtureLines()
        #expect(!lines.isEmpty)
        for line in lines {
            let events = decoder.decode(line: line)
            #expect(events.count == 1)
            // 一条都不该掉进 .raw——掉进去就说明这个事件形状没被认出来
            #expect(events.first?.kind != .raw, "未识别的事件: \(line.prefix(120))")
        }
    }

    @Test
    func aToolCallCarriesItsNameStatusAndFilePath() throws {
        let decoder = OpenCodeStreamEventDecoder()
        let events = try fixtureLines().flatMap { decoder.decode(line: $0) }
        let tool = try #require(events.first { $0.toolName != nil })
        #expect(tool.toolName == "read")
        #expect(tool.status == .completed)
        #expect(tool.kind == .toolUpdated)
        #expect(tool.filePath == "/private/tmp/octest/sample.txt")
        #expect(tool.itemID?.isEmpty == false)
    }

    @Test
    func assistantTextArrivesAsAMessage() throws {
        let decoder = OpenCodeStreamEventDecoder()
        let events = try fixtureLines().flatMap { decoder.decode(line: $0) }
        let message = try #require(events.last { $0.kind == .message })
        #expect(message.detail?.contains("alpha beta") == true)
        #expect(message.sessionID?.hasPrefix("ses_") == true)
    }

    /// `reason == "tool-calls"` 是「这一步去调工具了」，不是回合结束。
    /// 判成 finished 会让宿主提前收尾，后面的正文就没人接了。
    @Test
    func aToolCallPauseIsNotTreatedAsTheEndOfTheTurn() throws {
        let decoder = OpenCodeStreamEventDecoder()
        let events = try fixtureLines().flatMap { decoder.decode(line: $0) }
        let toolPause = try #require(events.first { $0.detail == "tool-calls" })
        #expect(toolPause.kind == .usage)
        #expect(toolPause.status == .running)
        #expect(toolPause.usage?.inputTokens != nil)
        #expect(toolPause.usage?.cachedInputTokens != nil)
    }

    @Test
    func unknownEventShapesArePreservedRatherThanDropped() {
        let decoder = OpenCodeStreamEventDecoder()
        let events = decoder.decode(line: #"{"type":"something_new","part":{}}"#)
        // 执行器升级加了新事件时，这条原始行是唯一的线索，不能吞
        #expect(events.first?.kind == .raw)
        #expect(events.first?.detail?.contains("something_new") == true)
    }
}
