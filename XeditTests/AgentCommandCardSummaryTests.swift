//
//  AgentCommandCardSummaryTests.swift
//  WillDeepTests
//

import Foundation
import Testing

@testable import WillDeep

@Suite("长命令的卡片摘要")
nonisolated struct AgentCommandCardSummaryTests {
    /// 短命令一眼看得完，加摘要只是噪声。
    @Test("短命令不给摘要", arguments: [
        "ls -la",
        "git status",
        "kubectl -n tokenhub get pods",
    ])
    func shortCommandsGetNoSummary(command: String) {
        #expect(AgentCommandCardSummary.summary(for: command) == nil)
    }

    /// 单步命令再长也没有「几步」可言。
    @Test("单步命令不给摘要")
    func singleStepCommandGetsNoSummary() {
        let command = "kubectl -n tokenhub get deployment tokenhub "
            + "-o jsonpath='{.spec.template.spec.containers[0].image}{\"\\n\"}{.metadata.annotations}' "
            + "--request-timeout=30s --context production-cluster"
        #expect(AgentCommandCardSummary.summary(for: command) == nil)
    }

    /// 取自 2026-09-15 的真实审批：多步只读排查。
    @Test("多步只读命令报全部只读")
    func readOnlyChainReportsReadOnly() {
        let command = "kubectl -n tokenhub get pods -l app=tokenhub; "
            + "echo '--- deploy ---'; "
            + "kubectl -n tokenhub get deploy tokenhub -o wide; "
            + "echo '--- events ---'; "
            + "kubectl -n tokenhub get events --sort-by=.lastTimestamp"
        let summary = AgentCommandCardSummary.summary(for: command)
        #expect(summary?.contains("共 5 步") == true)
    }

    /// 混着写操作时，写的那几步必须单独点出来——这正是用户要判断的东西。
    @Test("含写操作时点出会改动的步数")
    func destructiveStepsAreCounted() {
        let command = "echo 'start'; "
            + "kubectl -n tokenhub get pods; "
            + "rm -rf /tmp/build-cache; "
            + "echo 'done'"
        let summary = AgentCommandCardSummary.summary(for: command)
        #expect(summary?.contains("共 4 步") == true)
        #expect(summary?.contains("改动或删除") == true)
    }

    /// 拆不出结构就不给摘要，绝不编。
    @Test("解析不出结构时不给摘要")
    func unparsableCommandGetsNoSummary() {
        let command = String(repeating: "'unbalanced quote and more text here ", count: 6)
        #expect(AgentCommandCardSummary.summary(for: command) == nil)
    }

    // MARK: - 正文预览

    @Test("短脚本原样显示")
    func shortScriptPreviewIsUnchanged() {
        let command = "echo a\necho b"
        #expect(AgentCommandCardSummary.preview(for: command) == command)
    }

    /// 长脚本只摆前几行，剩下折叠成一句交代——不隐藏、也不铺满整张卡。
    @Test("长脚本折叠尾部并交代剩余行数")
    func longScriptPreviewIsFolded() {
        let command = (1...20).map { "echo line \($0)" }.joined(separator: "\n")
        let preview = AgentCommandCardSummary.preview(for: command)
        #expect(preview.contains("echo line 1"))
        #expect(preview.contains("echo line 6"))
        #expect(!preview.contains("echo line 7"))
        #expect(preview.contains("另有 14 行"))
    }
}
