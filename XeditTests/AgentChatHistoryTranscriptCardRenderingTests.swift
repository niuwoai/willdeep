//
//  AgentChatHistoryTranscriptCardRenderingTests.swift
//  WillDeepTests
//
//  定时任务卡片(.scheduledTask)与设计门卡片(.specProposal)进 TextKit 历史
//  后的渲染。两种角色的 content 恒为空,全部展示数据挂在各自的字段上。
//  1.405.0-rc10 之前 formatter 没有专门的正文分支,历史里只剩一个
//  「TSK / DSN」头像行,卡片整体不可见——设计门等着用户做的那个决定,
//  用户根本看不见(与 1.155.0-rc4 的 workflow 卡片同一种病)。
//
//  修复前本文件头两条用例在未修改的渲染器上 8 个断言全红(1.405.0-rc9,
//  2026-09-27 本机实跑),这就是「不可见」的坐实。
//

import AppKit
import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentChatHistoryTranscriptCardRenderingTests {
    private static let scheduledTaskTitle = "继续发布 WillDeep 1.234.0-rc8"
    private static let scheduledTaskSchedule = "每 30 分钟"
    private static let scheduledTaskGoal = "把最新版本发出去"
    private static let proposalDocumentPath = "docs/SESSION_ARCHIVE_DESIGN.md"
    private static let proposalEvidence = "先出个方案"

    private static func scheduledTaskMessage(
        id: UUID = UUID(),
        title: String = scheduledTaskTitle,
        goal: String? = scheduledTaskGoal
    ) -> AgentMessage {
        AgentMessage(
            role: .scheduledTask,
            content: "",
            scheduledTask: AgentScheduledTaskCard(
                id: id,
                title: title,
                scheduleSummary: scheduledTaskSchedule,
                goal: goal,
                prompt: "继续检查并发布最新版本。"
            )
        )
    }

    private static func specProposalMessage(
        id: UUID = UUID(),
        choice: AgentSpecProposalChoice?,
        signals: [AgentSpecGateSignal] = [
            AgentSpecGateSignal(kind: .explicitRequest, evidence: proposalEvidence),
        ]
    ) -> AgentMessage {
        var message = AgentMessage(role: .specProposal, content: "")
        message.specProposal = AgentSpecProposal(
            id: id,
            documentPath: proposalDocumentPath,
            signals: signals,
            choice: choice
        )
        return message
    }

    /// `.link` 属性在这段 range 起点上的值(链接值是 String,不是 URL)。
    private static func linkValue(at range: NSRange, in attributed: NSAttributedString) -> String? {
        attributed.attribute(.link, at: range.location, effectiveRange: nil) as? String
    }

    // MARK: - 复现:两种卡片在 TextKit 历史里只剩头像行

    @Test("定时任务卡片进 TextKit 历史后标题、调度摘要与目标可见")
    func scheduledTaskCardBakesTitleScheduleAndGoal() {
        let rendered = AgentChatHistoryRenderer.render(
            messages: [Self.scheduledTaskMessage()],
            isDark: false
        )
        #expect(rendered.string.contains(Self.scheduledTaskTitle))
        #expect(rendered.string.contains(Self.scheduledTaskSchedule))
        #expect(rendered.string.contains(Self.scheduledTaskGoal))
    }

    @Test("已裁决的设计提案进 TextKit 历史后文档路径、依据与结论可见")
    func decidedSpecProposalBakesDocumentSignalsAndVerdict() {
        let accepted = AgentChatHistoryRenderer.render(
            messages: [Self.specProposalMessage(choice: .accepted)],
            isDark: false
        )
        #expect(accepted.string.contains(Self.proposalDocumentPath))
        #expect(accepted.string.contains(Self.proposalEvidence))
        #expect(accepted.string.contains(L10n.SpecGateCard.accepted))
        #expect(!accepted.string.contains(L10n.SpecGateCard.dismissed))

        let dismissed = AgentChatHistoryRenderer.render(
            messages: [Self.specProposalMessage(choice: .dismissed)],
            isDark: false
        )
        #expect(dismissed.string.contains(Self.proposalDocumentPath))
        #expect(dismissed.string.contains(L10n.SpecGateCard.dismissed))
        #expect(!dismissed.string.contains(L10n.SpecGateCard.accepted))
    }

    // MARK: - 定时任务:动作 / 状态行

    @Test("例程还在:「打开」是带例程 id 的内部链接")
    func activeScheduledTaskBakesOpenLinkCarryingRoutineID() throws {
        let taskID = UUID()
        let rendered = AgentChatHistoryRenderer.render(
            messages: [Self.scheduledTaskMessage(id: taskID)],
            isDark: false,
            activeScheduledTaskIDs: [taskID]
        )
        #expect(rendered.string.contains(L10n.ScheduledTaskCard.open))
        #expect(!rendered.string.contains(L10n.ScheduledTaskCard.completed))
        let range = try #require(firstAttributeRange(
            .agentChatHistoryScheduledTaskID,
            value: taskID.uuidString,
            in: rendered
        ))
        #expect(Self.linkValue(at: range, in: rendered) == AgentChatHistoryScheduledTaskLink.value)
        // 目标既在正文里,也作为链接的提示;prompt 不进正文。
        #expect(rendered.string.contains(L10n.ScheduledTaskCard.goalPrefix + Self.scheduledTaskGoal))
        #expect(!rendered.string.contains("继续检查并发布最新版本。"))
    }

    @Test("例程已自完成:只画「已完成」,没有可点的链接")
    func completedScheduledTaskBakesDoneStatusWithoutLink() {
        let taskID = UUID()
        let rendered = AgentChatHistoryRenderer.render(
            messages: [Self.scheduledTaskMessage(id: taskID)],
            isDark: false,
            activeScheduledTaskIDs: []
        )
        #expect(rendered.string.contains(L10n.ScheduledTaskCard.completed))
        #expect(!rendered.string.contains(L10n.ScheduledTaskCard.open))
        #expect(attributeCount(.agentChatHistoryScheduledTaskID, in: rendered) == 0)
    }

    @Test("调用方不知道例程还在不在(阅读窗口):正文照烘焙,动作与状态都不画")
    func scheduledTaskWithoutRoutineKnowledgeKeepsBodyOnly() {
        let rendered = AgentChatHistoryRenderer.render(
            messages: [Self.scheduledTaskMessage()],
            isDark: false
        )
        #expect(rendered.string.contains(Self.scheduledTaskTitle))
        #expect(!rendered.string.contains(L10n.ScheduledTaskCard.open))
        #expect(!rendered.string.contains(L10n.ScheduledTaskCard.completed))
        #expect(attributeCount(.agentChatHistoryScheduledTaskID, in: rendered) == 0)
    }

    @Test("没有目标的定时任务不留一行空的「目标:」")
    func scheduledTaskWithoutGoalOmitsGoalLine() {
        let rendered = AgentChatHistoryRenderer.render(
            messages: [Self.scheduledTaskMessage(goal: nil)],
            isDark: false
        )
        #expect(rendered.string.contains(Self.scheduledTaskTitle))
        #expect(!rendered.string.contains(L10n.ScheduledTaskCard.goalPrefix))
    }

    // MARK: - 设计提案:文档链接、依据折叠、待裁决判定

    @Test("提案里的文档路径是可点的路径 chip")
    func specProposalDocumentPathIsFilePathLink() throws {
        let rendered = AgentChatHistoryRenderer.render(
            messages: [Self.specProposalMessage(choice: .accepted)],
            isDark: false
        )
        let range = try #require(firstAttributeRange(
            .agentChatHistoryFilePath,
            value: Self.proposalDocumentPath,
            in: rendered
        ))
        #expect(Self.linkValue(at: range, in: rendered) == AgentChatHistoryFilePathLink.value)
    }

    @Test("依据超过卡片上限的部分折成「还有 N 条」")
    func specProposalCollapsesSignalsBeyondCardLimit() {
        let limit = AgentSpecProposalCardLayout.visibleSignalLimit
        let signals = (0..<(limit + 2)).map {
            AgentSpecGateSignal(kind: .crossModuleKeywords, evidence: "依据\($0)")
        }
        let rendered = AgentChatHistoryRenderer.render(
            messages: [Self.specProposalMessage(choice: .dismissed, signals: signals)],
            isDark: false
        )
        for index in 0..<limit {
            #expect(rendered.string.contains("依据\(index)"))
        }
        #expect(!rendered.string.contains("依据\(limit)"))
        #expect(rendered.string.contains(L10n.SpecGateCard.moreSignals(2)))
    }

    @Test("待裁决的提案不进 TextKit 历史,裁决后进;别的角色一律进")
    func pendingProposalNeedsLiveSurfaceUntilDecided() {
        #expect(AgentTranscriptCardHistoryRenderer.needsLiveSurface(Self.specProposalMessage(choice: nil)))
        #expect(AgentTranscriptCardHistoryRenderer.needsLiveSurface(Self.specProposalMessage(choice: .deferred)))
        #expect(!AgentTranscriptCardHistoryRenderer.needsLiveSurface(Self.specProposalMessage(choice: .accepted)))
        #expect(!AgentTranscriptCardHistoryRenderer.needsLiveSurface(Self.specProposalMessage(choice: .dismissed)))
        #expect(!AgentTranscriptCardHistoryRenderer.needsLiveSurface(Self.scheduledTaskMessage()))
        #expect(!AgentTranscriptCardHistoryRenderer.needsLiveSurface(AgentMessage(role: .assistant, content: "hi")))
        // 角色对、字段缺(坏数据):进历史,只剩头像行,总好过卡在看不见的表面上。
        #expect(!AgentTranscriptCardHistoryRenderer.needsLiveSurface(AgentMessage(role: .specProposal, content: "")))
    }

    @Test("待裁决的提案万一进了历史(阅读窗口),有记录但没有结论")
    func pendingProposalInHistoryHasNoVerdictLine() {
        let rendered = AgentChatHistoryRenderer.render(
            messages: [Self.specProposalMessage(choice: nil)],
            isDark: false
        )
        #expect(rendered.string.contains(Self.proposalDocumentPath))
        #expect(rendered.string.contains(Self.proposalEvidence))
        #expect(!rendered.string.contains(L10n.SpecGateCard.accepted))
        #expect(!rendered.string.contains(L10n.SpecGateCard.dismissed))
    }

    // MARK: - 渲染缓存:展示字段都在缓存键里

    @Test("同 id 的定时任务换标题不会命中旧渲染")
    func scheduledTaskTitleChangeInvalidatesRenderCache() {
        let taskID = UUID()
        let before = AgentChatHistoryRenderer.render(
            messages: [Self.scheduledTaskMessage(id: taskID, title: "旧标题")],
            isDark: false
        )
        let after = AgentChatHistoryRenderer.render(
            messages: [Self.scheduledTaskMessage(id: taskID, title: "新标题")],
            isDark: false
        )
        #expect(before.string.contains("旧标题"))
        #expect(after.string.contains("新标题"))
        #expect(!after.string.contains("旧标题"))
    }

    @Test("例程从「还在」变「已自完成」不会命中旧渲染")
    func scheduledTaskActivityFlipInvalidatesRenderCache() {
        let taskID = UUID()
        let message = Self.scheduledTaskMessage(id: taskID)
        let active = AgentChatHistoryRenderer.render(
            messages: [message],
            isDark: false,
            activeScheduledTaskIDs: [taskID]
        )
        let completed = AgentChatHistoryRenderer.render(
            messages: [message],
            isDark: false,
            activeScheduledTaskIDs: []
        )
        #expect(active.string.contains(L10n.ScheduledTaskCard.open))
        #expect(completed.string.contains(L10n.ScheduledTaskCard.completed))
        #expect(!completed.string.contains(L10n.ScheduledTaskCard.open))
    }

    @Test("同 id 的提案从待裁决变已采纳不会命中旧渲染")
    func specProposalChoiceChangeInvalidatesRenderCache() {
        let proposalID = UUID()
        let pending = AgentChatHistoryRenderer.render(
            messages: [Self.specProposalMessage(id: proposalID, choice: nil)],
            isDark: false
        )
        let accepted = AgentChatHistoryRenderer.render(
            messages: [Self.specProposalMessage(id: proposalID, choice: .accepted)],
            isDark: false
        )
        #expect(!pending.string.contains(L10n.SpecGateCard.accepted))
        #expect(accepted.string.contains(L10n.SpecGateCard.accepted))
    }
}
