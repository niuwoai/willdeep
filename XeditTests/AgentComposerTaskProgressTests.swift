//
//  AgentComposerTaskProgressTests.swift
//  WillDeepTests
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WillDeep

@Suite("Agent composer 任务进度")
struct AgentComposerTaskProgressTests {
    @Test("执行中计划显示真实当前步骤与完整状态")
    func executingPlanUsesExplicitActiveStep() throws {
        let plan = AgentPlan(
            status: .executing,
            steps: [
                .init(text: "审查现有改动", status: .done),
                .init(text: "推送提交与版本标签", status: .inProgress),
                .init(text: "修正任务队列状态展示", status: .pending),
                .init(text: "调整搜索超时策略", status: .skipped),
                .init(text: "验证并说明下载机制", status: .pending),
            ]
        )

        let snapshot = try #require(
            AgentComposerTaskProgressSnapshot.make(plan: plan, isResponding: true)
        )

        #expect(snapshot.kind == .plan)
        #expect(snapshot.currentIndex == 2)
        #expect(snapshot.completedCount == 2)
        #expect(snapshot.totalCount == 5)
        #expect(snapshot.items.map(\.status) == [.done, .active, .pending, .skipped, .pending])
        #expect(!snapshot.isComplete)
        #expect(!snapshot.isBlocked)
    }

    @Test("后端尚未上报 in-progress 时推断首个待办为当前步骤")
    func infersFirstPendingStepWhileResponding() throws {
        let plan = AgentPlan(
            status: .approved,
            steps: [
                .init(text: "第一步"),
                .init(text: "第二步"),
            ]
        )

        let active = try #require(
            AgentComposerTaskProgressSnapshot.make(plan: plan, isResponding: true)
        )
        let idle = try #require(
            AgentComposerTaskProgressSnapshot.make(plan: plan, isResponding: false)
        )

        #expect(active.currentIndex == 1)
        #expect(active.items.map(\.status) == [.active, .pending])
        #expect(idle.items.map(\.status) == [.pending, .pending])
    }

    @Test("失败步骤成为当前步骤并标记阻塞")
    func failedStepBecomesCurrentAndBlocked() throws {
        let plan = AgentPlan(
            status: .executing,
            steps: [
                .init(text: "已完成", status: .done),
                .init(text: "验证失败", status: .failed),
                .init(text: "等待处理", status: .pending),
            ]
        )

        let snapshot = try #require(
            AgentComposerTaskProgressSnapshot.make(plan: plan, isResponding: false)
        )

        #expect(snapshot.currentIndex == 2)
        #expect(snapshot.currentItem?.text == "验证失败")
        #expect(snapshot.isBlocked)
    }

    @Test("提议中与已拒绝计划不占用 composer 进度位")
    func hidesNonExecutablePlans() {
        let steps = [AgentPlan.Step(text: "等待确认")]

        #expect(
            AgentComposerTaskProgressSnapshot.make(
                plan: AgentPlan(status: .proposed, steps: steps),
                isResponding: false
            ) == nil
        )
        #expect(
            AgentComposerTaskProgressSnapshot.make(
                plan: AgentPlan(status: .rejected, steps: steps),
                isResponding: false
            ) == nil
        )
    }

    @Test("Goal 清单把第一个未完成项映射为当前步骤")
    func goalUsesFirstOpenItem() throws {
        let goal = AgentGoal(
            statement: "完成发版",
            checklist: [
                .init(text: "修复", done: true),
                .init(text: "测试"),
                .init(text: "发布"),
            ]
        )

        let snapshot = try #require(
            AgentComposerTaskProgressSnapshot.make(goal: goal, isResponding: true)
        )

        #expect(snapshot.kind == .goal)
        #expect(snapshot.currentIndex == 2)
        #expect(snapshot.completedCount == 1)
        #expect(snapshot.items.map(\.status) == [.done, .active, .pending])
    }

    @Test("计划优先于 Goal 清单显示")
    func prefersPlanOverGoal() throws {
        let plan = AgentPlan(
            status: .executing,
            steps: [.init(text: "计划步骤", status: .inProgress)]
        )
        let goal = AgentGoal(
            statement: "目标",
            checklist: [.init(text: "目标步骤")]
        )

        let snapshot = try #require(
            AgentComposerTaskProgressSnapshot.preferred(
                plan: plan,
                goal: goal,
                isResponding: true
            )
        )

        #expect(snapshot.kind == .plan)
        #expect(snapshot.currentItem?.text == "计划步骤")
    }

    @Test("渲染参考状态用于设计验收")
    @MainActor
    func rendersReferenceStateForDesignQA() throws {
        let outputDirectory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment[
                "WILLDEEP_COMPOSER_PROGRESS_QA_OUTPUT"
            ] ?? "/tmp/Xedit-composer-progress-design-qa",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.system.id
        let appState = AppState(editorSettings: settings)
        let plan = AgentPlan(
            status: .executing,
            steps: [
                .init(text: "审查并提交现有改动", status: .inProgress),
                .init(text: "推送提交与版本标签"),
                .init(text: "修正任务队列状态展示"),
                .init(text: "调整搜索超时策略"),
                .init(text: "验证并说明下载机制"),
            ]
        )
        let snapshot = try #require(
            AgentComposerTaskProgressSnapshot.make(
                plan: plan,
                isResponding: true
            )
        )
        let focusedFixture = VStack(spacing: 5) {
            AgentComposerTaskProgressPanel(snapshot: snapshot)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.10), radius: 7, x: 0, y: 3)
            AgentComposerTaskProgressControl(snapshot: snapshot)
        }
        .environmentObject(appState)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.light)

        let focusedSize = try render(
            focusedFixture,
            width: 420,
            outputURL: outputDirectory.appendingPathComponent(
                "composer-progress-expanded.png"
            )
        )

        let session = AgentSession(title: "任务进度视觉验收")
        let runtime = AgentRuntime(session: session)
        runtime.currentPlan = plan
        appState.agentSessions = [session]
        appState.agentRuntimes = [session.id: runtime]
        appState.activeAgentSessionID = session.id
        let fullFixture = AgentChatComposer()
            .environmentObject(appState)
            .frame(width: 779)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.light)
        let fullSize = try render(
            fullFixture,
            width: 779,
            outputURL: outputDirectory.appendingPathComponent(
                "composer-progress-full.png"
            )
        )

        #expect(focusedSize.width == 420)
        #expect(focusedSize.height > 190)
        #expect(fullSize.width == 779)
        #expect(fullSize.height > 150)
    }

    @MainActor
    private func render<V: View>(
        _ view: V,
        width: CGFloat,
        outputURL: URL
    ) throws -> NSSize {
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        hostingView.layoutSubtreeIfNeeded()
        let fittingHeight = max(1, ceil(hostingView.fittingSize.height))
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: fittingHeight)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: outputURL, options: .atomic)
        return hostingView.frame.size
    }
}
