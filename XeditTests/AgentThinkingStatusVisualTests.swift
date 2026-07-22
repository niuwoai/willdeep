import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WillDeep

@Suite
struct AgentThinkingStatusVisualTests {
    @MainActor
    @Test("render stable thinking text and empty user-decision status for design QA")
    func renderThinkingStatusForDesignQA() throws {
        let outputPath = ProcessInfo.processInfo.environment[
            "XEDIT_THINKING_STATUS_QA_OUTPUT"
        ] ?? "/tmp/Xedit-thinking-status-design-qa/implementation.png"

        let activeState = makeActiveState()
        let decisionState = makeDecisionState()
        let paneWidth: CGFloat = 478
        let paneHeight: CGFloat = 96
        let root = HStack(spacing: 0) {
            statusPane(appState: activeState, width: paneWidth, height: paneHeight)
            statusPane(appState: decisionState, width: paneWidth, height: paneHeight)
        }
        .frame(width: paneWidth * 2, height: paneHeight)
        .preferredColorScheme(.light)

        let hostingView = NSHostingView(rootView: root)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: paneWidth * 2,
            height: paneHeight
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

        #expect(bitmap.size.width == paneWidth * 2)
        #expect(bitmap.size.height == paneHeight)
        #expect(bitmap.pixelsWide >= Int(paneWidth * 2))
        #expect(bitmap.pixelsHigh >= Int(paneHeight))
    }

    @MainActor
    private func makeActiveState() -> AppState {
        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.ricePaper.id
        let appState = AppState(editorSettings: settings)
        appState.startNewAgentSession()
        appState.isAgentResponding = true
        appState.agentTurnStartedAt = Date(timeIntervalSinceNow: -275)
        appState.agentMessages = [
            AgentMessage(role: .assistant, content: "Streaming response")
        ]
        return appState
    }

    @MainActor
    private func makeDecisionState() -> AppState {
        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.ricePaper.id
        let appState = AppState(editorSettings: settings)
        appState.startNewAgentSession()
        appState.isAgentResponding = true
        appState.agentTurnStartedAt = Date(timeIntervalSinceNow: -275)
        appState.agentMessages = [
            AgentMessage(role: .assistant, content: "Waiting for approval")
        ]
        appState.agentToolCalls = [
            AgentToolCall(
                messageID: UUID(),
                externalID: UUID().uuidString,
                toolName: "run_command",
                arguments: [:],
                risk: .write,
                status: .pendingApproval
            ),
            AgentToolCall(
                messageID: UUID(),
                externalID: UUID().uuidString,
                toolName: "background_build",
                arguments: [:],
                risk: .read,
                status: .running
            )
        ]
        #expect(appState.agentRunningTaskCount == 1)
        return appState
    }

    @MainActor
    private func statusPane(
        appState: AppState,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            appState.editorSettings.interfaceSkin.windowBackground
            AgentTurnActivityStatusView(
                leadingInset: AgentChatHistoryLayoutMetrics.assistantContentHeadIndent,
                trailingInset: AgentChatHistoryLayoutMetrics.assistantContentTailInset
            )
                .environmentObject(appState)
                .padding(.top, 18)
        }
        .frame(width: width, height: height)
    }
}
