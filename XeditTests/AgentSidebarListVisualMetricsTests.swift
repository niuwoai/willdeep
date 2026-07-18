import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WillDeep

struct AgentSidebarListVisualMetricsTests {
    @Test("conversation sidebar follows the Codex typography and vertical rhythm")
    func codexReferenceMetricsStaySynchronized() {
        #expect(AgentDesign.sidebarRowFontSize == 14)
        #expect(AgentDesign.sidebarRowHeight == 31)
        #expect(AgentDesign.sidebarTodoRowHeight == 47)
        #expect(AgentDesign.sidebarSelectionCornerRadius == 10)
        #expect(AgentDesign.sidebarWorkspaceGroupSpacing == 6)
        #expect(AgentDesign.sidebarAutomationFontSize == AgentDesign.sidebarRowFontSize)
    }

    @Test("workspace and conversation titles share the Codex text column")
    func titleColumnsAlign() {
        let workspaceTitleX = AgentDesign.sidebarWorkspaceHorizontalInset
            + AgentDesign.sidebarWorkspaceIconSize
            + AgentDesign.sidebarWorkspaceIconToTitleSpacing
        let sessionTitleX = AgentDesign.sidebarSelectionHorizontalInset
            + AgentDesign.sidebarSessionContentHorizontalInset

        #expect(workspaceTitleX == 40)
        #expect(sessionTitleX == workspaceTitleX)
        #expect(
            AgentDesign.sidebarSelectionHorizontalInset
                + AgentDesign.sidebarPinnedSessionContentHorizontalInset
                == 12
        )
    }

    @Test("render the production conversation sidebar for design QA")
    @MainActor
    func renderProductionSidebarForDesignQA() throws {
        let outputPath = ProcessInfo.processInfo.environment["WILLDEEP_SIDEBAR_QA_OUTPUT"]
            ?? "/tmp/Xedit-sidebar-design-qa.png"

        AgentSidebarWorkspaceStateStore.save([], kind: .expandedWorkspaces)
        AgentSidebarWorkspaceStateStore.save([], kind: .collapsedWorkspaces)
        AgentSidebarWorkspaceStateStore.save([], kind: .expandedArchivedGroups)

        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.ricePaper.id
        let appState = AppState(editorSettings: settings)
        appState.agentRoutines = [
            AgentRoutine(
                name: "检查 some.im 线上日志",
                prompt: "检查线上日志并汇总异常。",
                workspaceRootPath: "/tmp/Xedit",
                schedule: .dailyAt(hour: 22, minute: 0)
            ),
            AgentRoutine(
                name: "自动发版",
                prompt: "执行自动发版检查。",
                workspaceRootPath: "/tmp/Xedit",
                schedule: .interval(minutes: 45)
            ),
            AgentRoutine(
                name: "每日简报",
                prompt: "整理工作日简报。",
                workspaceRootPath: "/tmp/Xedit",
                schedule: .weekdaysAt(hour: 9, minute: 0)
            ),
        ]
        let now = Date(timeIntervalSince1970: 1_784_070_000)
        appState.agentSessions = [
            makeSession(
                title: "调整图层面板展开方式",
                workspace: "/tmp/83d",
                updatedAt: now.addingTimeInterval(-900),
                pinnedAt: now.addingTimeInterval(-120)
            ),
            makeSession(title: "更新版本号", workspace: "/tmp/83d", updatedAt: now.addingTimeInterval(-800)),
            makeSession(title: "83d-go 里，帮我检查接口", workspace: "/tmp/83d", updatedAt: now.addingTimeInterval(-700)),
            makeSession(
                title: "完善版本控制文档",
                workspace: "/tmp/agentrules",
                updatedAt: now.addingTimeInterval(-600),
                pinnedAt: now.addingTimeInterval(-60)
            ),
            makeSession(title: "我们 wdtq,在同一个项目", workspace: "/tmp/aistaff", updatedAt: now.addingTimeInterval(-500)),
            makeSession(title: "hello,列一下我们当前功能", workspace: "/tmp/metaserver", updatedAt: now.addingTimeInterval(-400)),
        ]
        appState.activeAgentSessionID = nil
        appState.hiddenWorkspaceKeys = []

        let size = NSSize(width: 228, height: 606)
        let root = AgentSessionsSidebar()
            .environmentObject(appState)
            .frame(width: size.width, height: size.height)
            .background(appState.editorSettings.interfaceSkin.sidebarBackground)
            .preferredColorScheme(.light)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    @MainActor
    private func makeSession(
        title: String,
        workspace: String,
        updatedAt: Date,
        pinnedAt: Date? = nil
    ) -> AgentSession {
        AgentSession(
            title: title,
            workspaceRootPath: workspace,
            updatedAt: updatedAt,
            messages: [AgentMessage(role: .user, content: title, createdAt: updatedAt)],
            pinnedAt: pinnedAt
        )
    }
}
