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

    @Test("plan progress badge keeps its intrinsic width under hover-sized pressure")
    @MainActor
    func planProgressBadgeResistsHorizontalCompression() {
        var session = AgentSession(title: "A deliberately long conversation title")
        session.currentPlan = AgentPlan(
            status: .executing,
            steps: [
                .init(text: "Inspect", status: .done),
                .init(text: "Fix", status: .inProgress),
                .init(text: "Verify"),
            ]
        )

        let hostingController = NSHostingController(rootView: AgentSessionModeBadges(session: session))
        let unconstrained = hostingController.sizeThatFits(
            in: NSSize(width: 1_000, height: AgentDesign.sidebarRowHeight)
        )
        let constrained = hostingController.sizeThatFits(
            in: NSSize(width: 1, height: AgentDesign.sidebarRowHeight)
        )

        #expect(unconstrained.width > 1)
        #expect(abs(constrained.width - unconstrained.width) < 0.5)
    }

    @Test("scheduled-task search covers name, prompt, and workspace without reordering")
    @MainActor
    func scheduledTaskSearchUsesUserVisibleFields() {
        let release = AgentRoutine(
            name: "每周发版检查",
            prompt: "检查 changelog 和签名状态",
            workspaceRootPath: "/tmp/WillDeep",
            schedule: .weeklyAt(weekday: 6, hour: 17, minute: 0)
        )
        let monitor = AgentRoutine(
            name: "Service Monitor",
            prompt: "Inspect deployment health",
            workspaceRootPath: "/tmp/backend",
            schedule: .interval(minutes: 30)
        )
        let routines = [release, monitor]

        #expect(AgentScheduledTasksFilter.routines(routines, matching: "  ") == routines)
        #expect(AgentScheduledTasksFilter.routines(routines, matching: "changelog") == [release])
        #expect(AgentScheduledTasksFilter.routines(routines, matching: "BACKEND") == [monitor])
        #expect(AgentScheduledTasksFilter.routines(routines, matching: "不存在").isEmpty)
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

    @Test("render the production scheduled-tasks page for design QA")
    @MainActor
    func renderScheduledTasksPageForDesignQA() throws {
        let outputPath = ProcessInfo.processInfo.environment["WILLDEEP_SCHEDULED_QA_OUTPUT"]
            ?? "/tmp/Xedit-scheduled-tasks-design-qa.png"

        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.ricePaper.id
        let appState = AppState(editorSettings: settings)
        appState.agentPrimaryDestination = .scheduledTasks
        appState.agentRoutines = [
            AgentRoutine(
                name: "每日产品简报",
                prompt: "检查昨天的改动、风险和今天最重要的行动项。",
                workspaceRootPath: "/tmp/Xedit",
                schedule: .weekdaysAt(hour: 9, minute: 0)
            ),
            AgentRoutine(
                name: "版本发布检查",
                prompt: "检查版本号、变更记录、签名与公证准备情况。",
                workspaceRootPath: "/tmp/Xedit",
                schedule: .weeklyAt(weekday: 6, hour: 17, minute: 0)
            ),
            AgentRoutine(
                name: "服务健康监控",
                prompt: "检查线上服务健康状态并汇总需要关注的问题。",
                workspaceRootPath: "/tmp/backend",
                schedule: .interval(minutes: 120),
                isEnabled: false
            ),
        ]

        let size = NSSize(width: 838, height: 606)
        let root = AgentScheduledTasksPage()
            .environmentObject(appState)
            .frame(width: size.width, height: size.height)
            .background(appState.editorSettings.interfaceSkin.windowBackground)
            .preferredColorScheme(.light)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    @Test("render scheduled navigation and page together at the reference viewport")
    @MainActor
    func renderScheduledTasksFullLayoutForDesignQA() throws {
        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.ricePaper.id
        let appState = AppState(editorSettings: settings)
        appState.agentPrimaryDestination = .scheduledTasks
        appState.agentRoutines = [
            AgentRoutine(
                name: "每日产品简报",
                prompt: "检查昨天的改动、风险和今天最重要的行动项。",
                workspaceRootPath: "/tmp/Xedit",
                schedule: .weekdaysAt(hour: 9, minute: 0)
            ),
            AgentRoutine(
                name: "服务健康监控",
                prompt: "检查线上服务健康状态并汇总需要关注的问题。",
                workspaceRootPath: "/tmp/backend",
                schedule: .interval(minutes: 120)
            ),
        ]

        let size = NSSize(width: 1066, height: 462)
        let root = HStack(spacing: 0) {
            AgentSessionsSidebar()
                .frame(width: 230)
                .background(appState.editorSettings.interfaceSkin.sidebarBackground)
            Divider()
            AgentScheduledTasksPage()
        }
        .environmentObject(appState)
        .frame(width: size.width, height: size.height)
        .background(appState.editorSettings.interfaceSkin.windowBackground)
        .preferredColorScheme(.light)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(
            to: URL(fileURLWithPath: "/tmp/Xedit-scheduled-tasks-full-design-qa.png"),
            options: .atomic
        )
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
