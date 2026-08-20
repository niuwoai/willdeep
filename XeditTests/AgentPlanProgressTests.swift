//
//  AgentPlanProgressTests.swift
//  WillDeepTests
//
//  Covers AgentPlanParser.extract step→Step conversion plus
//  applyProgress(to:from:) — the model-driven progress reporting that
//  flips per-step status as the agent works.
//

import Testing
import AppKit
import Foundation
import SwiftUI
@testable import WillDeep

@Suite
struct AgentPlanProgressTests {
    @MainActor
    @Test("窄计划卡中的状态徽标保持单行")
    func compactPlanStatusRemainsSingleLine() throws {
        // Reproduce the compressed width seen in the floating plan card. The
        // pill may overflow this artificial slot horizontally, but it must not
        // turn a two-character label into a two-line vertical badge.
        let fixture = PlanStatusPill(status: .executing)
            .frame(width: 24)
            .fixedSize(horizontal: false, vertical: true)
            .preferredColorScheme(.light)

        let hostingView = NSHostingView(rootView: fixture)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.frame = NSRect(x: 0, y: 0, width: 24, height: 1)
        hostingView.layoutSubtreeIfNeeded()
        let height = ceil(hostingView.fittingSize.height)

        #expect(height <= 20)
    }

    @Test("计划步骤图标用分层灰，不靠红绿区分完成与否")
    func planStepGlyphsUseLayeredGray() {
        // 红绿正是红绿色盲分不开的那条轴，完成与否不能只靠它。
        #expect(AgentPlanStepRow.glyphColor(for: .done) == AgentComposerChrome.iconSecondary)
        #expect(AgentPlanStepRow.glyphColor(for: .done) != .green)
        // 未开始比已完成更淡，形成层次；跳过同样退到最淡一档。
        #expect(AgentPlanStepRow.glyphColor(for: .pending) == AgentComposerChrome.iconMuted)
        #expect(AgentPlanStepRow.glyphColor(for: .skipped) == AgentComposerChrome.iconMuted)
        #expect(AgentPlanStepRow.glyphColor(for: .pending) != AgentPlanStepRow.glyphColor(for: .done))
        // 仍要你注意的两个状态保留颜色。
        #expect(AgentPlanStepRow.glyphColor(for: .inProgress) == .orange)
        #expect(AgentPlanStepRow.glyphColor(for: .failed) == .red)
    }

    @Test("已完成徽章走安静灰，待办与失败保留颜色")
    func donePlanPillStaysQuiet() {
        let doneFill = PlanStatusPill.fillColor(status: .done, isInterrupted: false)
        #expect(doneFill != .blue)
        #expect(doneFill != .green)
        // 灰底上白字会糊掉，文字随之换成次级墨色。
        #expect(PlanStatusPill.textColor(status: .done, isInterrupted: false) == .secondary)
        #expect(PlanStatusPill.fillColor(status: .executing, isInterrupted: false) == .green)
        #expect(PlanStatusPill.fillColor(status: .rejected, isInterrupted: false) == .red)
        #expect(PlanStatusPill.textColor(status: .rejected, isInterrupted: false) == .white)
        // 中断优先于状态，且同样是安静灰。
        #expect(PlanStatusPill.fillColor(status: .executing, isInterrupted: true) == doneFill)
        #expect(PlanStatusPill.textColor(status: .executing, isInterrupted: true) == .secondary)
    }

    @Test("产物与 Dev Server 活动卡统一使用 Composer 灰阶图标")
    func activityCardsUseMonochromeIcons() {
        #expect(AgentActivityCardChrome.artifactIcon == AgentComposerChrome.iconSecondary)
        #expect(AgentActivityCardChrome.artifactIcon != .accentColor)
        #expect(AgentActivityCardChrome.devServerIcon == AgentComposerChrome.iconSecondary)
        #expect(AgentActivityCardChrome.devServerIcon != .green)
    }

    @MainActor
    @Test("渲染折叠计划与产物卡用于设计验收")
    func rendersCompactActivityOverlayForDesignQA() throws {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.currentPlan = AgentPlan(
            status: .executing,
            steps: [.init(text: "修复窄卡片布局", status: .inProgress)]
        )
        runtime.goalRoadmap = AgentGoalRoadmap(
            phases: [
                .init(id: "PHASE-1", title: "定位", acceptanceCriteria: [], status: .completed),
                .init(id: "PHASE-2", title: "修复", acceptanceCriteria: [], status: .executing),
                .init(id: "PHASE-3", title: "验收", acceptanceCriteria: []),
            ],
            activePhaseIndex: 1
        )
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        runtime.agentArtifactPaths = [
            repositoryRoot.appendingPathComponent("CHANGELOG.md").path
        ]

        let fixture = ZStack(alignment: .topTrailing) {
            Color(nsColor: .windowBackgroundColor)
            AgentConversationActivityOverlay()
                .environmentObject(appState)
                .padding(.top, 8)
                .padding(.trailing, 8)
        }
        .frame(width: 306, height: 142)
        .preferredColorScheme(.light)

        let outputURL = URL(fileURLWithPath: "/tmp/Xedit-plan-activity-overlay-rc4.png")
        try renderPNG(fixture, size: NSSize(width: 306, height: 142), to: outputURL)
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
    }

    @MainActor
    @Test("渲染带播放按钮的吸附目标条用于设计验收")
    func rendersPinnedGoalExecutionControlForDesignQA() throws {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.interactionMode = .goal
        runtime.currentGoal = AgentGoal(
            statement: "记录请求流量分级 trace；调整 retention 删除批处理缓解 MGR 3100",
            checklist: [
                .init(text: "完成请求流量分级", done: true),
                .init(text: "验证 retention 批处理", done: false),
            ]
        )
        runtime.goalRoadmap = AgentGoalRoadmap(
            phases: [
                .init(id: "PHASE-1", title: "定位", acceptanceCriteria: [], status: .completed),
                .init(id: "PHASE-2", title: "实现", acceptanceCriteria: [], status: .executing),
                .init(id: "PHASE-3", title: "验收", acceptanceCriteria: []),
            ],
            activePhaseIndex: 1
        )
        let goal = try #require(runtime.currentGoal)

        let fixture = ZStack {
            Color(nsColor: .windowBackgroundColor)
            AgentComposerGoalCard(goal: goal)
                .environmentObject(appState)
                .padding(.horizontal, 2)
        }
        .frame(width: 1_040, height: 32)
        .preferredColorScheme(.light)

        let outputURL = URL(fileURLWithPath: "/tmp/Xedit-pinned-goal-control-rc4.png")
        try renderPNG(fixture, size: NSSize(width: 1_040, height: 32), to: outputURL)
        #expect(FileManager.default.fileExists(atPath: outputURL.path))

        runtime.isResponding = true
        let activeFixture = ZStack {
            Color(nsColor: .windowBackgroundColor)
            AgentComposerGoalCard(goal: goal)
                .environmentObject(appState)
                .padding(.horizontal, 2)
        }
        .frame(width: 1_040, height: 32)
        .preferredColorScheme(.light)
        let activeOutputURL = URL(
            fileURLWithPath: "/tmp/Xedit-pinned-goal-control-active-rc4.png"
        )
        try renderPNG(
            activeFixture,
            size: NSSize(width: 1_040, height: 32),
            to: activeOutputURL
        )
        #expect(FileManager.default.fileExists(atPath: activeOutputURL.path))
    }

    @MainActor
    private func renderPNG<V: View>(_ view: V, size: NSSize, to outputURL: URL) throws {
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try #require(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: outputURL, options: .atomic)
    }

    @Test("查看完整计划直接打开计划侧边栏")
    func viewFullPlanOpensPlanSidePanelDirectly() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let transcriptSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Xedit/AgentChatTranscript.swift"),
            encoding: .utf8
        )

        let directOpen = "appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .plan)"
        #expect(transcriptSource.components(separatedBy: directOpen).count - 1 == 2)
        #expect(!transcriptSource.contains("agentPlanOverlayExpandRequestToken"))
    }

    /// Initial extract turns numbered lines into Steps with .pending status.
    @Test
    func extractProducesPendingSteps() {
        let content = """
        Sure, here's the plan:

        ```plan
        We'll do it in three passes.
        1. Read the file
        2. Edit it
        3. Run the tests
        ```
        """
        let plan = AgentPlanParser.extract(from: content)
        #expect(plan != nil)
        #expect(plan?.steps.count == 3)
        #expect(plan?.steps.map(\.status) == [.pending, .pending, .pending])
        #expect(plan?.steps.first?.text == "Read the file")
        #expect(plan?.summary == "We'll do it in three passes.")
    }

    @Test("Goal 阶段计划在下一个 Phase 标题前停止")
    func firstPhaseExtractionStopsBeforeLaterPhaseSteps() {
        let content = """
        ```plan
        ## MySQL 迁移 + 后端核心认证服务开发

        ### Phase 1: 数据库迁移到 MySQL
        1. 修改 go.mod
        2. 重写迁移脚本
        3. 更新 models.go
        4. 更新文档

        ### Phase 2: 后端核心代码
        5. 配置管理
        6. 数据库连接
        ```
        """

        let phasePlan = AgentPlanParser.extract(from: content, scope: .firstPhase)
        #expect(phasePlan?.summary.contains("Phase 1") == true)
        #expect(phasePlan?.summary.contains("Phase 2") == false)
        #expect(phasePlan?.steps.map(\.text) == [
            "修改 go.mod",
            "重写迁移脚本",
            "更新 models.go",
            "更新文档",
        ])

        let ordinaryPlan = AgentPlanParser.extract(from: content)
        #expect(ordinaryPlan?.steps.count == 6)
    }

    /// A progress block flips matched step indexes to the new status and
    /// promotes the plan to .executing once any step is touched.
    @Test
    func applyProgressFlipsStatuses() {
        var plan = AgentPlan(
            status: .approved,
            steps: [
                AgentPlan.Step(text: "A"),
                AgentPlan.Step(text: "B"),
                AgentPlan.Step(text: "C")
            ],
            summary: ""
        )
        let reply = """
        Working on it.

        ```progress
        1: done
        2: in_progress
        ```
        """
        let next = AgentPlanParser.applyProgress(to: plan, from: reply)
        #expect(next != nil)
        plan = next!
        #expect(plan.status == .executing)
        #expect(plan.steps[0].status == .done)
        #expect(plan.steps[1].status == .inProgress)
        #expect(plan.steps[2].status == .pending)
    }

    /// All steps terminal ⇒ plan flips to .done.
    @Test
    func allTerminalStepsCompletesPlan() {
        let plan = AgentPlan(
            status: .approved,
            steps: [
                AgentPlan.Step(text: "A", status: .done),
                AgentPlan.Step(text: "B")
            ],
            summary: ""
        )
        let reply = """
        ```progress
        2: done
        ```
        """
        let next = AgentPlanParser.applyProgress(to: plan, from: reply)
        #expect(next?.status == .done)
        #expect(next?.steps[1].status == .done)
    }

    /// Some providers emit one progress block around every large section.
    /// The parser must fold the whole reply, with later statuses winning.
    @Test
    func multipleProgressBlocksAreMergedInOrder() {
        let plan = AgentPlan(
            status: .approved,
            steps: [
                AgentPlan.Step(text: "Draft"),
                AgentPlan.Step(text: "Write"),
                AgentPlan.Step(text: "Verify")
            ],
            summary: ""
        )
        let reply = """
        ```progress
        1: in_progress
        ```
        Drafting is complete.
        ```progress
        1: done
        2: in_progress
        ```
        Writing and verification are complete.
        ```progress
        2: done
        3: done
        ```
        """

        let next = AgentPlanParser.applyProgress(to: plan, from: reply)

        #expect(next?.status == .done)
        #expect(next?.steps.map(\.status) == [.done, .done, .done])
    }

    /// Unknown status tokens are dropped — the rest of the block still applies.
    @Test
    func unknownStatusTokensIgnored() {
        let plan = AgentPlan(
            status: .approved,
            steps: [
                AgentPlan.Step(text: "A"),
                AgentPlan.Step(text: "B")
            ],
            summary: ""
        )
        let reply = """
        ```progress
        1: warp-speed
        2: done
        ```
        """
        let next = AgentPlanParser.applyProgress(to: plan, from: reply)
        #expect(next?.steps[0].status == .pending)
        #expect(next?.steps[1].status == .done)
    }

    /// Out-of-range step indexes don't crash and don't corrupt other steps.
    @Test
    func outOfRangeIndexesIgnored() {
        let plan = AgentPlan(
            status: .approved,
            steps: [AgentPlan.Step(text: "A")],
            summary: ""
        )
        let reply = """
        ```progress
        99: done
        1: in_progress
        ```
        """
        let next = AgentPlanParser.applyProgress(to: plan, from: reply)
        #expect(next?.steps.count == 1)
        #expect(next?.steps[0].status == .inProgress)
    }

    /// No ```progress block → returns nil so the caller leaves the plan alone.
    @Test
    func noProgressBlockReturnsNil() {
        let plan = AgentPlan(
            status: .approved,
            steps: [AgentPlan.Step(text: "A")],
            summary: ""
        )
        let reply = "Just prose, no progress block here."
        #expect(AgentPlanParser.applyProgress(to: plan, from: reply) == nil)
    }

    @MainActor
    @Test("a completed ordinary plan does not create a planning gate")
    func completedOrdinaryPlanDoesNotGateLaterWork() {
        let plan = AgentPlan(
            status: .done,
            steps: [AgentPlan.Step(text: "Ship previous request", status: .done)],
            summary: ""
        )
        let runtime = AgentRuntime(session: AgentSession(title: "Done plan"))
        runtime.interactionMode = .normal
        runtime.currentPlan = plan

        #expect(runtime.isPlanGateActive == false)

        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: nil,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            interactionMode: .normal,
            currentPlan: plan
        )
        #expect(prompt.contains("=== ORDINARY MODE — PLAN WHEN USEFUL, THEN EXECUTE ==="))
        #expect(!prompt.contains("=== ACTIVE PLAN — CONTINUE, DO NOT RE-PLAN ==="))
    }

    @MainActor
    @Test("leaving Goal mode preserves its active execution plan")
    func leavingGoalModePreservesActivePlan() {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        let runtime = appState.agentRuntimes[session.id]
        runtime?.interactionMode = .goal
        runtime?.currentPlan = AgentPlan(
            status: .approved,
            steps: [AgentPlan.Step(text: "Execute")],
            summary: ""
        )

        appState.setAgentInteractionMode(.normal)

        #expect(appState.agentInteractionMode == .normal)
        #expect(appState.agentCurrentPlan?.status == .approved)
    }

    @MainActor
    @Test("Normal mode applies progress blocks to a carried-over approved plan")
    func normalModeAppliesProgressToCarriedOverPlan() {
        let appState = AppState()
        appState.startNewAgentSession()
        appState.agentInteractionMode = .normal
        appState.agentCurrentPlan = AgentPlan(
            status: .approved,
            steps: [
                AgentPlan.Step(text: "A"),
                AgentPlan.Step(text: "B")
            ],
            summary: ""
        )
        appState.agentMessages = [
            AgentMessage(role: .user, content: "Plan approved. Execute the complete plan step by step."),
            AgentMessage(
                role: .assistant,
                content: """
                Working on it.
                ```progress
                1: done
                2: in_progress
                ```
                """
            )
        ]

        appState.captureAgentPlanFromLatestMessage()

        #expect(appState.agentCurrentPlan?.status == .executing)
        #expect(appState.agentCurrentPlan?.steps[0].status == .done)
        #expect(appState.agentCurrentPlan?.steps[1].status == .inProgress)
    }

    @MainActor
    @Test("same session later plan block replaces completed plan")
    func laterPlanBlockReplacesCompletedPlan() {
        let appState = AppState()
        appState.startNewAgentSession()
        appState.agentInteractionMode = .normal
        appState.agentCurrentPlan = AgentPlan(
            status: .done,
            steps: [AgentPlan.Step(text: "Finish the first request", status: .done)],
            summary: ""
        )
        appState.agentMessages = [
            AgentMessage(role: .user, content: "Now do another thing"),
            AgentMessage(
                role: .assistant,
                content: """
                ```plan
                1. Inspect the follow-up request
                2. Patch the follow-up behavior
                ```
                """
            )
        ]

        appState.captureAgentPlanFromLatestMessage()

        #expect(appState.agentCurrentPlan?.status == .approved)
        #expect(appState.agentCurrentPlan?.steps.map(\.text) == [
            "Inspect the follow-up request",
            "Patch the follow-up behavior"
        ])
    }

    /// Accepts a variety of separator + status token forms — the agent
    /// shouldn't have to be pedantic.
    @Test
    func parserToleratesAlternateFormatting() {
        let plan = AgentPlan(
            status: .approved,
            steps: [
                AgentPlan.Step(text: "A"),
                AgentPlan.Step(text: "B"),
                AgentPlan.Step(text: "C"),
                AgentPlan.Step(text: "D")
            ],
            summary: ""
        )
        let reply = """
        ```progress
        - 1. complete
          2) running
        step 3: failed
        4 skipped
        ```
        """
        let next = AgentPlanParser.applyProgress(to: plan, from: reply)
        #expect(next?.steps[0].status == .done)
        #expect(next?.steps[1].status == .inProgress)
        #expect(next?.steps[2].status == .failed)
        #expect(next?.steps[3].status == .skipped)
    }

    @Test("plan step text renders inline Markdown instead of delimiters")
    func planStepTextRendersInlineMarkdown() {
        let attributed = MarkdownInline.attributedString(
            from: "**`AgentPlan.swift`**: keep *status* synchronized"
        )

        #expect(String(attributed.characters) == "AgentPlan.swift: keep status synchronized")
        #expect(attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        #expect(attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.code) == true
        })
        let codeRun = attributed.runs.first { run in
            run.inlinePresentationIntent?.contains(.code) == true
        }
        #expect(codeRun?.baselineOffset == MarkdownInline.inlineCodeBaselineOffset)
    }

    @Test("plan step index column fits double-digit numbering")
    func planStepIndexColumnFitsDoubleDigits() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        ]
        let doubleDigitWidth = ("10." as NSString).size(withAttributes: attributes).width

        #expect(AgentPlanStepLayoutMetrics.indexColumnWidth >= ceil(doubleDigitWidth))
    }

    @Test("full plan Markdown keeps every step and its live status")
    func fullPlanMarkdownKeepsEveryStepAndStatus() {
        let plan = AgentPlan(
            status: .executing,
            steps: [
                AgentPlan.Step(text: "Inspect **all** call sites", status: .done),
                AgentPlan.Step(text: "Implement the long description without truncating it", status: .inProgress),
                AgentPlan.Step(text: "Run focused tests", status: .failed),
            ],
            summary: "Keep the compact card readable."
        )

        let markdown = AgentPlanMarkdownFormatter.markdown(from: plan)
        let blocks = MarkdownPreviewParser.blocks(from: markdown)
        let listBlockCount = blocks.reduce(into: 0) { count, block in
            if case .unorderedList = block.kind {
                count += 1
            }
        }

        #expect(markdown.contains("# \(L10n.PlanCard.header)"))
        #expect(markdown.contains("- ✓ **1.** Inspect **all** call sites"))
        #expect(markdown.contains("- ◉ **2.** Implement the long description without truncating it"))
        #expect(markdown.contains("- ! **3.** Run focused tests"))
        #expect(listBlockCount == plan.steps.count)
        #expect(blocks.contains { $0.text.contains("without truncating it") })
    }

    @Test("plan card opens for newly planned work and collapses during execution")
    func planCardInitialExpansionFollowsExecutionState() {
        #expect(AgentPlanCardExpansionPolicy.initiallyExpanded(for: .proposed))
        #expect(AgentPlanCardExpansionPolicy.initiallyExpanded(for: .approved))
        #expect(!AgentPlanCardExpansionPolicy.initiallyExpanded(for: .executing))
        #expect(!AgentPlanCardExpansionPolicy.initiallyExpanded(for: .done))
        #expect(!AgentPlanCardExpansionPolicy.showsStatus(.approved, isInterrupted: false))
        #expect(AgentPlanCardExpansionPolicy.showsStatus(.executing, isInterrupted: false))
        #expect(AgentPlanCardExpansionPolicy.showsStatus(.approved, isInterrupted: true))

        let active = AgentPlan(status: .executing, summary: "", stepTexts: ["Work"])
        let done = AgentPlan(status: .done, summary: "", stepTexts: ["Work"])
        #expect(AgentPlanCardExpansionPolicy.shouldDisplay(active))
        #expect(AgentPlanCardExpansionPolicy.allowsRevision(active))
        #expect(!AgentPlanCardExpansionPolicy.shouldDisplay(done))
        #expect(!AgentPlanCardExpansionPolicy.allowsRevision(done))
    }

    @Test("plan card collapses only when a new assistant round appears")
    func planCardCollapsesForNewAssistantRound() {
        let previousID = UUID()
        let nextID = UUID()

        #expect(!AgentPlanCardExpansionPolicy.shouldCollapseForAssistantRound(
            previousMessageID: previousID,
            currentMessageID: nil
        ))
        #expect(!AgentPlanCardExpansionPolicy.shouldCollapseForAssistantRound(
            previousMessageID: previousID,
            currentMessageID: previousID
        ))
        #expect(AgentPlanCardExpansionPolicy.shouldCollapseForAssistantRound(
            previousMessageID: previousID,
            currentMessageID: nextID
        ))
        #expect(AgentPlanCardExpansionPolicy.shouldCollapseForAssistantRound(
            previousMessageID: nil,
            currentMessageID: nextID
        ))
    }

    @Test("approved plan with unfinished work continues automatically")
    func unfinishedApprovedPlanContinuesAutomatically() {
        let plan = AgentPlan(
            status: .executing,
            steps: [
                AgentPlan.Step(text: "A", status: .done),
                AgentPlan.Step(text: "B", status: .inProgress)
            ],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: 0,
            consecutiveNoProgressReplies: 0,
            hasQueuedUserMessages: false
        )

        #expect(decision == .continueExecution)
    }

    @Test("automatic continuation yields to queued user input")
    func automaticContinuationYieldsToQueuedUserInput() {
        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "A", status: .inProgress)],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: 0,
            consecutiveNoProgressReplies: 0,
            hasQueuedUserMessages: true
        )

        #expect(decision == .stop)
    }

    @Test("planning-only request never auto-executes a captured plan")
    func planningOnlyRequestStopsAutomaticContinuation() {
        let plan = AgentPlan(
            status: .approved,
            steps: [AgentPlan.Step(text: "A")],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: 0,
            consecutiveNoProgressReplies: 0,
            hasQueuedUserMessages: false,
            allowsAutomaticExecution: false
        )

        #expect(decision == .stop)
    }

    @Test("automatic continuation stops for terminal plans")
    func automaticContinuationStopsForTerminalPlans() {
        let plan = AgentPlan(
            status: .done,
            steps: [AgentPlan.Step(text: "A", status: .done)],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: 0,
            consecutiveNoProgressReplies: 0,
            hasQueuedUserMessages: false
        )

        #expect(decision == .stop)
    }

    @Test("automatic continuation pauses after repeated no-progress replies")
    func automaticContinuationPausesAfterRepeatedNoProgress() {
        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "A", status: .inProgress)],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: 2,
            consecutiveNoProgressReplies: 3,
            hasQueuedUserMessages: false
        )

        #expect(decision == .pauseAfterNoProgress)
    }

    @Test("automatic continuation requests one status-only reconciliation before pausing")
    func automaticContinuationReconcilesMissingProgressBeforePausing() {
        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "Deploy", status: .inProgress)],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: 2,
            consecutiveNoProgressReplies: 2,
            hasQueuedUserMessages: false
        )
        let notice = AgentPlanAutoContinuationPolicy.progressReconciliationNotice(
            finishReason: "stop"
        )

        #expect(decision == .reconcileProgress)
        #expect(notice.contains("minimum necessary read-only status or inspection tools"))
        #expect(notice.contains("write, danger, and user-input tools are blocked"))
        #expect(notice.contains("repeat the plan"))
        #expect(notice.contains("exactly one closed `progress` fenced block"))
        #expect(notice.contains("Do not infer completion without evidence"))
        #expect(AgentPlanAutoContinuationPolicy.allowsToolRiskDuringProgressReconciliation(.read))
        #expect(!AgentPlanAutoContinuationPolicy.allowsToolRiskDuringProgressReconciliation(.write))
        #expect(!AgentPlanAutoContinuationPolicy.allowsToolRiskDuringProgressReconciliation(.danger))
        #expect(!AgentPlanAutoContinuationPolicy.allowsToolRiskDuringProgressReconciliation(.userInput))
    }

    @Test("a run that is still executing tools keeps reconciling instead of pausing")
    func automaticContinuationKeepsReconcilingWhileToolsRun() {
        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "A", status: .inProgress)],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: 2,
            consecutiveNoProgressReplies: 3,
            hasQueuedUserMessages: false,
            evidence: .init(didExecuteTools: true)
        )

        #expect(decision == .reconcileProgress)
    }

    @Test("an incomplete Goal keeps executing after status reconciliation is missed")
    func incompleteGoalDoesNotPauseForMissingPlanStatus() {
        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "Finish the Goal", status: .inProgress)],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: 3,
            consecutiveNoProgressReplies: 3,
            hasQueuedUserMessages: false,
            requiresGoalCompletion: true
        )

        #expect(decision == .continueExecution)
    }

    @Test("Goal execution receives a larger bounded continuation budget")
    func incompleteGoalUsesGoalContinuationLimit() {
        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "Finish the Goal", status: .inProgress)],
            summary: ""
        )

        let continues = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: AgentPlanAutoContinuationPolicy.maximumAutomaticContinuations,
            consecutiveNoProgressReplies: 3,
            hasQueuedUserMessages: false,
            requiresGoalCompletion: true
        )
        let eventuallyPauses = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: AgentPlanAutoContinuationPolicy.maximumGoalAutomaticContinuations,
            consecutiveNoProgressReplies: 3,
            hasQueuedUserMessages: false,
            requiresGoalCompletion: true
        )

        #expect(continues == .continueExecution)
        #expect(eventuallyPauses == .pauseAfterLimit)
    }

    @MainActor
    @Test("吸附目标控制在运行与空闲之间切换播放图标")
    func pinnedGoalExecutionControlUsesPlayPauseSymbols() {
        #expect(AgentGoalExecutionControlPolicy.systemImage(isActive: false) == "play.fill")
        #expect(AgentGoalExecutionControlPolicy.systemImage(isActive: true) == "pause.fill")
        let prompt = AgentGoalExecutionControlPolicy.resumePrompt(
            remainingAcceptance: ["实现剩余目标"]
        )
        #expect(prompt.contains("Do not restart Goal Teams"))
        #expect(prompt.contains("实现剩余目标"))
        #expect(prompt.contains("`progress`"))
        #expect(prompt.contains("`goal-check`"))
        #expect(AgentGoalExecutionControlPolicy.resumePrompt(
            remainingAcceptance: []
        ).contains("establish its acceptance checklist"))
    }

    @Test("a live background job keeps reconciling and says so in the notice")
    func automaticContinuationKeepsReconcilingWhileBackgroundJobRuns() {
        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "A", status: .inProgress)],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: 2,
            consecutiveNoProgressReplies: 4,
            hasQueuedUserMessages: false,
            evidence: .init(hasRunningBackgroundJobs: true)
        )
        let notice = AgentPlanAutoContinuationPolicy.progressReconciliationNotice(
            finishReason: "stop",
            hasRunningBackgroundJobs: true
        )

        #expect(decision == .reconcileProgress)
        #expect(notice.contains("background job started by this conversation is still running"))
        #expect(notice.contains("keep that step `in_progress`"))
        // Still the full reconciliation contract, not a weaker variant.
        #expect(notice.contains("exactly one closed `progress` fenced block"))
        #expect(notice.contains("write, danger, and user-input tools are blocked"))
    }

    @Test("no-progress evidence never overrides the hard safety limit")
    func progressEvidenceDoesNotOverrideSafetyLimit() {
        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "A", status: .inProgress)],
            summary: ""
        )

        // The 8-round cap is what keeps the evidence path from spinning
        // forever, so it must win over every activity signal.
        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: AgentPlanAutoContinuationPolicy.maximumAutomaticContinuations,
            consecutiveNoProgressReplies: 9,
            hasQueuedUserMessages: false,
            evidence: .init(didExecuteTools: true, hasRunningBackgroundJobs: true)
        )

        #expect(decision == .pauseAfterLimit)
    }

    @Test("an idle stalled run still pauses")
    func automaticContinuationStillPausesWithoutEvidence() {
        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "A", status: .inProgress)],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: 2,
            consecutiveNoProgressReplies: 3,
            hasQueuedUserMessages: false,
            evidence: .none
        )

        #expect(decision == .pauseAfterNoProgress)
        #expect(!AgentPlanAutoContinuationPolicy.ProgressEvidence.none.hasAny)
    }

    @Test("the plain reconciliation notice omits the background-job sentence")
    func progressReconciliationNoticeOmitsBackgroundJobsWhenNoneRun() {
        let notice = AgentPlanAutoContinuationPolicy.progressReconciliationNotice(
            finishReason: "stop"
        )

        #expect(!notice.contains("background job"))
    }

    @Test("automatic continuation has a hard safety limit")
    func automaticContinuationHasHardSafetyLimit() {
        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "A", status: .inProgress)],
            summary: ""
        )

        let decision = AgentPlanAutoContinuationPolicy.decision(
            for: plan,
            automaticContinuationCount: AgentPlanAutoContinuationPolicy.maximumAutomaticContinuations,
            consecutiveNoProgressReplies: 0,
            hasQueuedUserMessages: false
        )

        #expect(decision == .pauseAfterLimit)
    }

    @Test("ordinary prompt creates one plan and immediately executes it")
    func ordinaryPromptDoesNotPauseAtPlanning() {
        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: nil,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            interactionMode: .normal,
            currentPlan: nil
        )

        #expect(prompt.contains("=== ORDINARY MODE — PLAN WHEN USEFUL, THEN EXECUTE ==="))
        #expect(prompt.contains("emit exactly one complete numbered `plan` fenced block"))
        #expect(prompt.contains("continue executing it in the same turn"))
        #expect(prompt.contains("Do not plan again on later tool rounds"))
        #expect(prompt.contains("explicitly asks only for analysis or a plan"))
        #expect(prompt.contains("privately preflight the complete request"))
        #expect(prompt.contains("Once execution starts, continue as an unattended run"))
        #expect(prompt.contains("ordinary Git/worktree"))

        let executionPrompt = AgentContextBuilder.systemPrompt(
            rootDirectory: nil,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            interactionMode: .normal,
            currentPlan: AgentPlan(
                status: .approved,
                steps: [AgentPlan.Step(text: "Run the tests")],
                summary: ""
            )
        )
        #expect(executionPrompt.contains("=== ACTIVE PLAN — CONTINUE, DO NOT RE-PLAN ==="))
        #expect(executionPrompt.contains("refresh the visible checklist immediately"))
        #expect(executionPrompt.contains("Only lines in exactly that shape update WillDeep's visible checklist"))
        #expect(executionPrompt.contains("Do not emit a replacement `plan` block"))
        #expect(executionPrompt.contains("The plan is now in unattended execution"))
        #expect(executionPrompt.contains("ordinary Git/worktree conflicts"))
        #expect(executionPrompt.contains("Re-contact the user only for missing authority or credentials"))
    }

    @Test("中断计划的提示词带上与活跃计划同一份 progress 格式合同")
    func interruptedPlanPromptCarriesProgressFormatContract() {
        // 回归：格式合同过去只写在活跃分支。用户按 Stop 后每回合注入的是
        // 中断分支，只说“发一个 progress 块”不给格式，模型于是发人类可读的
        // ✓ 清单 → 解析出 0 条 → interruptedAt 清不掉 → 下回合仍是无格式的
        // 中断提示词，自锁死循环。两个分支必须带同一份格式说明和示例。
        var interrupted = AgentPlan(
            status: .approved,
            steps: [AgentPlan.Step(text: "Run the tests")],
            summary: ""
        )
        interrupted.interruptedAt = Date()
        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: nil,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            interactionMode: .normal,
            currentPlan: interrupted
        )
        #expect(prompt.contains("=== INTERRUPTED PLAN — USER DECIDES WHAT'S NEXT ==="))
        #expect(prompt.contains("1: done"))
        #expect(prompt.contains("2: in_progress"))
        #expect(prompt.contains("Status tokens:"))
        #expect(prompt.contains("Only lines in exactly that shape update WillDeep's visible checklist"))
        // 恢复前先对账：历史显示做完、状态却仍是 pending 的步骤应补登记而非重做。
        #expect(prompt.contains("Reconcile before you resume"))
        // 没有违规时不得出现纠偏段落。
        #expect(!prompt.contains("CORRECTION — REQUIRED"))
    }

    @Test("progress 块解析为零时下一轮注入纠偏，正常时不打扰")
    func unparsableProgressBlockTriggersCorrectionNotice() {
        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "Run the tests")],
            summary: ""
        )
        let corrected = AgentContextBuilder.systemPrompt(
            rootDirectory: nil,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            interactionMode: .normal,
            currentPlan: plan,
            planProgressFormatViolation: true
        )
        #expect(corrected.contains("CORRECTION — REQUIRED"))
        #expect(corrected.contains("stale step counter"))

        let clean = AgentContextBuilder.systemPrompt(
            rootDirectory: nil,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            interactionMode: .normal,
            currentPlan: plan,
            planProgressFormatViolation: false
        )
        #expect(!clean.contains("CORRECTION — REQUIRED"))
    }

    @Test("containsProgressBlock 认围栏本身，与其中的行能否解析无关")
    func containsProgressBlockDetectsUnparsableBodies() {
        // 取自实际卡死会话：模型把 ```progress 当成状态展示框使用。
        let humanReadable = """
        进展如下：

        ```progress
        Phase 1: 基础管理 API
        ✓ 租户管理：GET/POST/PATCH/DELETE /api/v1/tenants
        ✓ 机房管理：/api/v1/tenants/:tenant_id/regions
        ```
        """
        #expect(AgentPlanParser.containsProgressBlock(humanReadable))

        let plan = AgentPlan(
            status: .executing,
            steps: [AgentPlan.Step(text: "A"), AgentPlan.Step(text: "B")],
            summary: ""
        )
        // 围栏在、但一行都解析不出——正是静默失败的形态。
        #expect(AgentPlanParser.applyProgress(to: plan, from: humanReadable) == nil)

        // 没有围栏就不该报“违规”，避免打扰只写散文的回合。
        #expect(!AgentPlanParser.containsProgressBlock("已完成租户管理，继续下一项。"))
    }
}
