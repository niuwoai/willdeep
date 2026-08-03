import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WillDeep

@Suite
struct AgentThinkingStatusVisualTests {
    @Test("full transcript omits duplicate thinking status")
    func fullTranscriptOmitsDuplicateThinkingStatus() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Xedit/AgentChatTranscript.swift"),
            encoding: .utf8
        )

        #expect(!source.contains("AgentTurnActivityStatusView("))
    }

    @Test("composer status stays visible for the whole responding turn")
    func composerStatusStaysVisibleWhileResponding() {
        // rc6 曾在纯响应期隐藏这条状态——不产出可识别动作标题的模型
        // （glm-5.2 等）在工具卡片结算后就再无任何"正在做什么"的反馈。
        // 回合进行中 composer 上方必须始终有活动状态条。
        #expect(AgentComposerActivityStatusPolicy.shouldShow(
            isResponding: true,
            isCompressingContext: false,
            runningTaskCount: 0,
            isWaitingForUserDecision: false
        ))
        #expect(!AgentComposerActivityStatusPolicy.shouldShow(
            isResponding: false,
            isCompressingContext: false,
            runningTaskCount: 0,
            isWaitingForUserDecision: false
        ))
        #expect(AgentComposerActivityStatusPolicy.shouldShow(
            isResponding: false,
            isCompressingContext: true,
            runningTaskCount: 0,
            isWaitingForUserDecision: false
        ))
        #expect(AgentComposerActivityStatusPolicy.shouldShow(
            isResponding: false,
            isCompressingContext: false,
            runningTaskCount: 1,
            isWaitingForUserDecision: false
        ))
        #expect(AgentComposerActivityStatusPolicy.shouldShow(
            isResponding: false,
            isCompressingContext: false,
            runningTaskCount: 0,
            isWaitingForUserDecision: true
        ))
    }

    @Test("dispatch takeover composer exposes active and provider-waiting states")
    func dispatchTakeoverComposerActivityPolicy() {
        #expect(AgentDispatchTakeoverActivityStatus.resolve(
            isResponding: false,
            isAwaitingProviderSlot: false
        ) == .hidden)
        #expect(AgentDispatchTakeoverActivityStatus.resolve(
            isResponding: true,
            isAwaitingProviderSlot: false
        ) == .active)
        #expect(AgentDispatchTakeoverActivityStatus.resolve(
            isResponding: false,
            isAwaitingProviderSlot: true
        ) == .waitingForProvider)
        #expect(AgentDispatchTakeoverActivityStatus.resolve(
            isResponding: true,
            isAwaitingProviderSlot: true
        ) == .waitingForProvider)
    }

    @Test("composer keeps a generic thinking fallback while the rail stays explicit")
    func composerThinkingFallbackScopedToComposerStyle() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Xedit/AgentTaskMonitorRail.swift"),
            encoding: .utf8
        )

        // 泛化"思考中"兜底必须存在（composer 条在纯响应期的反馈），
        // 且必须被 style == .composer 守卫——任务监督栏维持 rc6 的
        // "只显示明确状态"约束，不得跟着兜底。
        let fallback = try #require(
            source.range(of: #"AgentActivityPhase(label: "思考中""#)
        )
        let guardRange = try #require(
            source.range(of: "guard style == .composer else { return nil }")
        )
        #expect(guardRange.lowerBound < fallback.lowerBound)
        #expect(source.distance(from: guardRange.lowerBound, to: fallback.lowerBound) < 120)
    }

    @MainActor
    @Test("current action has exactly one transcript owner")
    func currentActionHasOneTranscriptOwner() {
        let appState = AppState()
        appState.startNewAgentSession()
        appState.isAgentResponding = true
        appState.agentMessages = [
            AgentMessage(role: .user, content: "继续"),
            AgentMessage(
                role: .assistant,
                content: "",
                reasoningContent: "Planning Swift enum extensions"
            ),
        ]

        #expect(appState.shouldShowDetachedAgentCurrentActivityIndicator)

        appState.agentMessages[1].content = "Planning Swift enum extensions"
        #expect(appState.agentCurrentActivityHeadline != nil)
        #expect(!appState.shouldShowDetachedAgentCurrentActivityIndicator)

        appState.agentMessages[1].content = "普通回答正文"
        #expect(appState.agentCurrentActivityHeadline == nil)
        #expect(!appState.shouldShowDetachedAgentCurrentActivityIndicator)
    }

    @MainActor
    @Test("unrecognized reasoning still surfaces a live current action")
    func unrecognizedReasoningKeepsLiveCurrentAction() {
        let appState = AppState()
        appState.startNewAgentSession()
        appState.isAgentResponding = true
        appState.agentMessages = [
            AgentMessage(role: .user, content: "更新 tokenhub"),
            AgentMessage(
                role: .assistant,
                content: "",
                reasoningContent: "先前的推理片段\n先核对镜像 tag，再决定是否回滚"
            ),
        ]

        let headline = appState.agentCurrentActivityHeadline
        #expect(headline?.title == L10n.AgentActivity.thinking)
        #expect(headline?.liveTitle == "先核对镜像 tag，再决定是否回滚")
        #expect(appState.shouldShowDetachedAgentCurrentActivityIndicator)

        // 正文首个 token 到达后 reasoning 预览消失,live 行让位给正文,
        // 可见回复文本永远不会被当成状态扫光。
        appState.agentMessages[1].content = "开始执行。"
        #expect(appState.agentCurrentActivityHeadline == nil)
        #expect(!appState.shouldShowDetachedAgentCurrentActivityIndicator)
    }

    @Test("task monitor has no generic provider fallback")
    func taskMonitorHasNoGenericProviderFallback() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Xedit/AgentTaskMonitorRail.swift"),
            encoding: .utf8
        )

        #expect(!source.contains("agentCurrentActivityHeadline ?? .analyzing"))
    }

    @MainActor
    @Test("render current action sweep phases for design QA")
    func renderCurrentActionSweepForDesignQA() throws {
        let outputPath = ProcessInfo.processInfo.environment[
            "XEDIT_THINKING_STATUS_QA_OUTPUT"
        ] ?? "/tmp/Xedit-activity-sweep-design-qa/implementation.png"

        let presentation = try #require(AgentActivityHeadlinePresentation.make(
            from: "Planning Swift enum extensions"
        ))
        #expect(presentation.liveTitle == "Planning Swift enum extensions")

        let paneWidth: CGFloat = 744
        let paneHeight: CGFloat = 70
        let root = VStack(spacing: 0) {
            sweepPane(presentation: presentation, progress: 0.05)
            sweepPane(presentation: presentation, progress: 0.50)
            sweepPane(presentation: presentation, progress: 0.95)
        }
        .frame(width: paneWidth, height: paneHeight * 3)
        .preferredColorScheme(.light)

        let hostingView = NSHostingView(rootView: root)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: paneWidth,
            height: paneHeight * 3
        )
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: outputURL, options: .atomic)

        #expect(bitmap.size.width == paneWidth)
        #expect(bitmap.size.height == paneHeight * 3)
        #expect(bitmap.pixelsWide >= Int(paneWidth))
        #expect(bitmap.pixelsHigh >= Int(paneHeight * 3))
    }

    private func sweepPane(
        presentation: AgentActivityHeadlinePresentation,
        progress: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            EditorInterfaceSkin.ricePaper.windowBackground
            AgentActivityHeadlineView(
                presentation: presentation,
                baseFontSize: 14,
                isActive: true,
                sweepProgressOverride: progress
            )
            .padding(.horizontal, 18)
            .padding(.top, 22)
        }
        .frame(width: 744, height: 70)
    }
}
