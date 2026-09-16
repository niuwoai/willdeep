//
//  AgentTerminalSnapshotPayloadTests.swift
//  WillDeepTests
//
//  终端快照返回给模型的体积约束：每次快照都会进上下文，重复段落会被逐轮放大。
//

import Testing
import Foundation
@testable import WillDeep

@Suite("Agent terminal snapshot payload size")
struct AgentTerminalSnapshotPayloadTests {
    @Test("recent commands keep only the newest few, truncated")
    func recentCommandsAreCappedAndTruncated() {
        let long = "kubectl -n tokenhub get deploy tokenhub " + String(repeating: "-o jsonpath='{.status}' ", count: 20)
        let commands = [long, "echo two", "echo three", "echo four", "echo five"]

        let summary = AgentTerminalTools.recentCommandsSummary(commands)
        let lines = summary.components(separatedBy: "\n")

        #expect(lines.count == AgentTerminalTools.recentCommandsSnapshotLimit + 1)
        #expect(lines[0].hasPrefix("kubectl -n tokenhub"))
        #expect(lines[0].hasSuffix("…[\(long.count) chars]"))
        #expect(lines[0].count < long.count)
        #expect(lines[1] == "echo two")
        #expect(!summary.contains("echo four"))
        #expect(lines.last == "(2 older omitted)")
    }

    @Test("host identity probe is not reported as a recent command")
    func hostIdentityProbeIsHidden() {
        let probe = AgentTerminalTab.hostIdentityProbeCommand
        #expect(AgentTerminalTools.recentCommandsSummary([probe]) == "none")
        #expect(AgentTerminalTools.recentCommandsSummary([probe, "ls"]) == "ls")
        #expect(AgentTerminalTools.recentCommandsSummary([]) == "none")
    }
}
