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
        #expect(AgentDesign.sidebarSelectionCornerRadius == 10)
        #expect(AgentDesign.sidebarWorkspaceGroupSpacing == 6)
        #expect(AgentDesign.sidebarAutomationFontSize == AgentDesign.sidebarRowFontSize)
        #expect(AgentScheduledTaskCardLayout.maximumWidth == 460)
        #expect(AgentScheduledTaskCardLayout.minimumHeight == 64)
        #expect(AgentScheduledTaskCardLayout.iconTileSize == 36)
        #expect(AgentScheduledTaskCardLayout.cornerRadius == 12)
        #expect(AgentDesign.sidebarSessionTrailingActionsWidth == 40)
        #expect(AgentDesign.liveActivityTopSpacing == 6)
        #expect(AgentDesign.liveActivityTopSpacing < AgentDesign.messageVerticalSpacing)
        #expect(AgentDesign.reviewPanelPreferredWidth == 520)
        #expect(AgentDesign.chatSupportingFontSize(baseFontSize: 14, visualMinimum: 9) == 13)
        #expect(AgentDesign.chatSupportingFontSize(baseFontSize: 18, visualMinimum: 15) == 15)
        #expect(AgentDesign.chatSupportingFontSize(baseFontSize: 11) == 11)
        #expect(AgentModelUsageTableLayout.horizontalInset == 8)
        #expect(AgentModelUsageTableLayout.columnSpacing == 8)
        #expect(AgentModelUsageTableLayout.tokensWidth == 120)
        #expect(AgentModelUsageTableLayout.cacheWidth == 56)
        #expect(AgentModelUsageTableLayout.costWidth == 72)
        #expect(AgentStatsDashboardTypography.body == 14)
        #expect(AgentStatsDashboardTypography.sectionTitle == 14)
        #expect(AgentStatsDashboardTypography.metricValue == 15)
        #expect(AgentStatsDashboardTypography.metricLabel == 13)
        #expect(AgentStatsDashboardTypography.profileName == 22)
        #expect(AgentStatsDashboardTypography.profileMeta == 13)
        #expect(AgentStatsDashboardTypography.heroValue == 34)
        #expect(AgentStatsDashboardTypography.heroLabel == 16)
        #expect(AgentStatsDashboardTypography.modelSummaryValue == 24)
        #expect(AgentStatsDashboardTypography.compactBadge == AgentStatsDashboardTypography.body)
        #expect(AgentStatsDashboardLayout.panelPadding == 0)
        #expect(AgentStatsDashboardLayout.profileAvatarSize == 80)
        #expect(AgentStatsDashboardLayout.summaryCornerRadius == 15)
        #expect(AgentStatsDashboardLayout.metricStripHeight == 61)
        #expect(AgentStatsDashboardLayout.heatmapCellSize == 8)
        #expect(AgentStatsDashboardLayout.heatmapCellSpacing == 3)
        #expect(AgentStatsDashboardLayout.maximumHeatmapWeeks == 52)
    }

    @Test("longest task duration uses compact day, hour, and minute units")
    func longestTaskDurationUsesCompactUnits() {
        #expect(AgentStatsDashboardFormatting.duration(59) == "0m")
        #expect(AgentStatsDashboardFormatting.duration(60) == "1m")
        #expect(AgentStatsDashboardFormatting.duration(3_600) == "1h0m")
        #expect(AgentStatsDashboardFormatting.duration(24 * 3_600) == "1d0h0m")
        #expect(AgentStatsDashboardFormatting.duration((103 * 60 + 27) * 60) == "4d7h27m")
        #expect(AgentStatsDashboardFormatting.duration((9 * 24 * 60 + 10 * 60 + 3) * 60) == "9d10h3m")
    }

    @Test("idle pinned session rows return the full trailing lane to the title")
    func idleSessionRowsUseAvailableSidebarWidth() {
        #expect(
            AgentSidebarSessionTrailingLayout.reservedActionsWidth(
                isHovered: false
            ) == 0
        )
        #expect(
            AgentSidebarSessionTrailingLayout.reservedActionsWidth(
                isHovered: true
            ) == AgentDesign.sidebarSessionTrailingActionsWidth
        )
    }

    @Test("Token activity tooltip includes the hovered day, request count, and Token usage")
    func tokenActivityTooltipCarriesDailyUsage() {
        let tooltip = L10n.HeatmapCell.tooltip("7月10日", "42", "10.3亿")

        #expect(tooltip.contains("7月10日"))
        #expect(tooltip.contains("42"))
        #expect(tooltip.contains("10.3亿"))
    }

    @Test("truncated tooltip labels remain free of hover-driven layout work")
    func truncatedTooltipLabelsStayLayoutInert() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let planSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Xedit/AgentPlanGoalCards.swift"),
            encoding: .utf8
        )
        let sidebarSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Xedit/AgentSessionsSidebar.swift"),
            encoding: .utf8
        )
        let componentStart = try #require(
            planSource.range(of: "struct TruncatedTooltipText: View")
        )
        let componentSuffix = planSource[componentStart.lowerBound...]
        let componentEnd = try #require(
            componentSuffix.range(of: "/// One row of the plan card")
        )
        let componentSource = String(componentSuffix[..<componentEnd.lowerBound])

        #expect(componentSource.contains(".truncationMode(.tail)"))
        #expect(componentSource.contains(".help(tooltip ?? \"\")"))
        #expect(!componentSource.contains("@State"))
        #expect(!componentSource.contains("GeometryReader"))
        #expect(!componentSource.contains("PreferenceKey"))
        #expect(!componentSource.contains(".onHover"))
        #expect(!componentSource.contains("repeatForever"))
        #expect(sidebarSource.contains("tooltip: session.title"))
    }

    @Test("conversation sidebar avoids the unstable SwiftUI lazy-stack cache")
    func conversationSidebarKeepsWorkspaceLayoutEager() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sidebarSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Xedit/AgentSessionsSidebar.swift"),
            encoding: .utf8
        )

        #expect(sidebarSource.contains("ForEach(workspaceGroups)"))
        #expect(sidebarSource.contains("VStack(alignment: .leading, spacing: 0)"))
        #expect(!sidebarSource.contains("LazyVStack"))
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

    @Test("legacy plan progress no longer renders a sidebar mode badge")
    @MainActor
    func legacyPlanProgressBadgeStaysHidden() {
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

        #expect(unconstrained.width == 0)
        #expect(abs(constrained.width - unconstrained.width) < 0.5)
    }

    @Test("goal mode shows one labeled progress summary even when a transient plan exists")
    @MainActor
    func goalModeDoesNotStackPlanAndGoalProgress() {
        var goalOnly = AgentSession(title: "Goal")
        goalOnly.interactionMode = .goal
        goalOnly.currentGoal = AgentGoal(
            statement: "Ship",
            checklist: [.init(text: "Verify")]
        )

        var goalWithPlan = goalOnly
        goalWithPlan.currentPlan = AgentPlan(
            status: .executing,
            steps: [.init(text: "Implement", status: .inProgress)]
        )

        let goalWidth = NSHostingController(rootView: AgentSessionModeBadges(session: goalOnly))
            .sizeThatFits(in: NSSize(width: 1_000, height: AgentDesign.sidebarRowHeight)).width
        let combinedWidth = NSHostingController(rootView: AgentSessionModeBadges(session: goalWithPlan))
            .sizeThatFits(in: NSSize(width: 1_000, height: AgentDesign.sidebarRowHeight)).width

        #expect(abs(combinedWidth - goalWidth) < 0.5)
        #expect(AgentSessionTodoSummaryLogic.summary(for: goalWithPlan)?.kind == .goal)
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
        var plannedSession = makeSession(
            title: "调整图层面板展开方式",
            workspace: "/tmp/83d",
            updatedAt: now.addingTimeInterval(-900),
            pinnedAt: now.addingTimeInterval(-120)
        )
        plannedSession.currentPlan = AgentPlan(
            status: .executing,
            steps: [
                .init(text: "检查侧栏与聊天字号", status: .done),
                .init(text: "统一状态提示字号", status: .done),
                .init(text: "完成设计验收", status: .inProgress),
            ]
        )
        plannedSession.interactionMode = .goal
        plannedSession.currentGoal = AgentGoal(
            statement: "完成侧边栏视觉收敛",
            checklist: [
                .init(text: "只保留一行低对比度进度", done: false),
            ]
        )
        appState.agentSessions = [
            plannedSession,
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

    @Test("render production new-chat typography surfaces for design QA")
    @MainActor
    func renderNewChatTypographyForDesignQA() throws {
        let outputPath = ProcessInfo.processInfo.environment["WILLDEEP_TYPOGRAPHY_QA_OUTPUT"]
            ?? "/tmp/Xedit-new-chat-typography-design-qa.png"

        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.ricePaper.id
        let appState = AppState(editorSettings: settings)
        appState.agentChatBaseFontSize = 14
        appState.agentSessions = [
            makeSession(
                title: "统一聊天界面的辅助字号",
                workspace: "/tmp/Xedit",
                updatedAt: Date(timeIntervalSince1970: 1_784_070_000)
            )
        ]
        appState.hasLoadedAgentUsageSnapshots = true
        appState.agentUsageSnapshots = typographyUsageSnapshots()

        let size = NSSize(width: 700, height: 780)
        let root = VStack(spacing: 24) {
            AgentChatEmptyState()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                AgentComposerRunContextBar()
                Text(L10n.Composer.inputPlaceholder)
                    .font(AgentDesign.chatSupportingFont(
                        baseFontSize: appState.agentChatBaseFontSize
                    ))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(appState.editorSettings.interfaceSkin.palette.panelFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(appState.editorSettings.interfaceSkin.palette.hairline, lineWidth: 1)
            )
        }
        .padding(32)
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

    @Test("render aligned production model-usage table for design QA")
    @MainActor
    func renderAlignedModelUsageTableForDesignQA() throws {
        let outputPath = ProcessInfo.processInfo.environment["WILLDEEP_MODEL_TABLE_QA_OUTPUT"]
            ?? "/tmp/Xedit-model-usage-table-design-qa.png"

        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.ricePaper.id
        let appState = AppState(editorSettings: settings)
        appState.agentChatBaseFontSize = 14
        appState.hasLoadedAgentUsageSnapshots = true
        appState.agentUsageSnapshots = typographyUsageSnapshots()

        let size = NSSize(width: 700, height: 410)
        let root = AgentStatsDashboard(initialTab: .models)
            .environmentObject(appState)
            .padding(24)
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

    @Test("render readable production stats overview for design QA")
    @MainActor
    func renderReadableStatsOverviewForDesignQA() throws {
        let outputPath = ProcessInfo.processInfo.environment["WILLDEEP_STATS_OVERVIEW_QA_OUTPUT"]
            ?? "/tmp/Xedit-stats-overview-design-qa.png"

        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.ricePaper.id
        let appState = AppState(editorSettings: settings)
        appState.agentChatBaseFontSize = 14
        appState.hasLoadedAgentUsageSnapshots = true
        appState.agentUsageSnapshots = typographyUsageSnapshots()

        // 608pt outer width minus the 20pt test padding on both sides leaves
        // the production 568pt dashboard width used by AgentChatEmptyState.
        let size = NSSize(width: 608, height: 740)
        let root = AgentStatsDashboard()
            .environmentObject(appState)
            .padding(EdgeInsets(top: 44, leading: 20, bottom: 0, trailing: 20))
            .frame(width: size.width, height: size.height, alignment: .top)
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

    @Test("render the production monthly usage calendar for design QA")
    @MainActor
    func renderMonthlyUsageCalendarForDesignQA() throws {
        let outputPath = ProcessInfo.processInfo.environment["WILLDEEP_USAGE_CALENDAR_QA_OUTPUT"]
            ?? "/tmp/Xedit-usage-calendar-1.246.0-rc1.png"

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 60 * 60))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 11,
            hour: 12
        )))

        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.system.id
        let appState = AppState(editorSettings: settings)
        appState.agentChatBaseFontSize = 14
        appState.hasLoadedAgentUsageSnapshots = true
        appState.agentUsageSnapshots = usageCalendarSnapshots(now: now, calendar: calendar)

        let size = NSSize(width: 700, height: 650)
        let root = AgentStatsDashboard(initialTab: .calendar, now: now)
            .environmentObject(appState)
            .padding(24)
            .frame(width: size.width, height: size.height, alignment: .top)
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

    @Test("render the production live activity timeline for design QA")
    @MainActor
    func renderLiveActivityTimelineForDesignQA() throws {
        let outputPath = ProcessInfo.processInfo.environment["WILLDEEP_ACTIVITY_TIMELINE_QA_OUTPUT"]
            ?? "/tmp/Xedit-activity-timeline-design-qa.png"

        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.ricePaper.id
        let appState = AppState(editorSettings: settings)
        appState.agentChatBaseFontSize = 14
        let messageID = UUID()
        let calls = [
            AgentToolCall(
                messageID: messageID,
                externalID: "read-1",
                toolName: "read_file",
                arguments: ["path": .string("Xedit/AgentToolCallGrouping.swift")],
                risk: .read,
                status: .succeeded
            ),
            AgentToolCall(
                messageID: messageID,
                externalID: "search-1",
                toolName: "grep_files",
                arguments: ["pattern": .string("agentLiveThinkingPreview")],
                risk: .read,
                status: .succeeded
            ),
            AgentToolCall(
                messageID: messageID,
                externalID: "edit-1",
                toolName: "edit_file",
                arguments: ["path": .string("Xedit/AgentMessageView.swift")],
                risk: .write,
                status: .succeeded
            ),
            AgentToolCall(
                messageID: messageID,
                externalID: "test-1",
                toolName: "run_command",
                arguments: [
                    "cwd": .string("/Users/rocky/Sites/Xedit"),
                    "command": .string("xcodebuild test"),
                ],
                risk: .read,
                status: .running
            ),
        ]

        let size = NSSize(width: 760, height: 360)
        let root = VStack(alignment: .leading, spacing: AgentDesign.liveActivityTopSpacing) {
            Text("我已经确认状态展示的问题来自过度聚合，以及模型原始阶段文案直接混进正文。现在正在收敛渲染层级并补回归测试。")
                .font(.system(size: appState.agentChatBaseFontSize))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            AgentLiveActivityTimeline(calls: calls)
        }
        .padding(32)
        .environmentObject(appState)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
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

    @Test("render the Codex-style transcript scheduled-task card for design QA")
    @MainActor
    func renderTranscriptScheduledTaskCardForDesignQA() throws {
        let outputPath = ProcessInfo.processInfo.environment["WILLDEEP_SCHEDULED_CARD_QA_OUTPUT"]
            ?? "/tmp/Xedit-scheduled-task-card-design-qa.png"

        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.ricePaper.id
        let appState = AppState(editorSettings: settings)
        let taskID = UUID()
        let routine = AgentRoutine(
            id: taskID,
            name: "继续发布 WillDeep 1.234.0-rc8",
            prompt: "继续检查并发布最新版本。",
            workspaceRootPath: "/tmp/Xedit",
            schedule: .interval(minutes: 30)
        )
        appState.agentRoutines = [routine]
        let card = AgentScheduledTaskCard(
            id: taskID,
            title: routine.name,
            scheduleSummary: routine.schedule.summary,
            goal: nil,
            prompt: routine.prompt
        )

        let size = NSSize(width: 520, height: 112)
        let root = AgentScheduledTaskCardView(card: card)
            .environmentObject(appState)
            .padding(24)
            .frame(width: size.width, height: size.height, alignment: .leading)
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

    @Test("scheduled-task card opens its detail in the scheduled-tasks destination")
    @MainActor
    func scheduledTaskCardNavigationTargetsMatchingRoutine() {
        let appState = AppState()
        let taskID = UUID()
        appState.agentSidePanelKind = .preview

        AgentScheduledTaskCardNavigation.open(cardID: taskID, in: appState)

        #expect(appState.pendingRoutineDetailID == taskID)
        #expect(appState.agentPrimaryDestination == .scheduledTasks)
        #expect(appState.agentSidePanelKind == nil)
        #expect(appState.agentSidePanelRequest == nil)
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

    private func typographyUsageSnapshots() -> [AgentUsageSessionSnapshot] {
        let now = Date(timeIntervalSince1970: 1_784_070_000)
        return (0..<18).map { index in
            let createdAt = now.addingTimeInterval(TimeInterval(-index * 43_200))
            return AgentUsageSessionSnapshot(
                id: UUID(),
                modelID: index.isMultiple(of: 2) ? "gpt-5.6-sol" : "deepseek-v4-flash",
                providerID: index.isMultiple(of: 2) ? "some.im" : "deepseek",
                providerDisplayName: index.isMultiple(of: 2) ? "some.im" : "DeepSeek",
                createdAt: createdAt,
                updatedAt: createdAt.addingTimeInterval(1_800),
                messages: [
                    AgentUsageMessageSnapshot(
                        role: .user,
                        contentCharacterCount: 120 + index,
                        usageTokens: 860 + index * 13,
                        promptTokens: 540 + index * 7,
                        completionTokens: 320 + index * 6,
                        createdAt: createdAt
                    ),
                    AgentUsageMessageSnapshot(
                        role: .assistant,
                        contentCharacterCount: 640 + index * 4,
                        reasoningCharacterCount: 180,
                        toolCallNames: [
                            "run_command",
                            "apply_patch",
                            "read_file",
                            "browser_click",
                            "image_generation",
                        ],
                        usageTokens: 2_400 + index * 41,
                        promptTokens: 1_500 + index * 23,
                        completionTokens: 900 + index * 18,
                        createdAt: createdAt.addingTimeInterval(900)
                    ),
                ],
                workspaceIdentifier: index.isMultiple(of: 3) ? "local:/tmp/Xedit" : "local:/tmp/WillDeep",
                editedFileCount: 2 + index % 4,
                artifactCount: index % 3
            )
        }
    }

    private func usageCalendarSnapshots(
        now: Date,
        calendar: Calendar
    ) -> [AgentUsageSessionSnapshot] {
        var snapshots: [AgentUsageSessionSnapshot] = []
        for day in 1...11 {
            let chatsForDay = day <= 9 ? 4 : 3
            for chatIndex in 0..<chatsForDay {
                let createdAt = calendar.date(
                    from: DateComponents(
                        year: 2026,
                        month: 8,
                        day: day,
                        hour: 9 + chatIndex
                    )
                ) ?? now
                let promptTokens = 350_000 + day * 2_000
                let completionTokens = 220_000 + chatIndex * 3_000
                snapshots.append(AgentUsageSessionSnapshot(
                    id: UUID(),
                    modelID: "gpt-5-mini",
                    providerID: "openai",
                    providerDisplayName: "OpenAI",
                    createdAt: createdAt,
                    updatedAt: createdAt.addingTimeInterval(900),
                    messages: [
                        AgentUsageMessageSnapshot(
                            role: .user,
                            contentCharacterCount: 120,
                            createdAt: createdAt
                        ),
                        AgentUsageMessageSnapshot(
                            role: .assistant,
                            contentCharacterCount: 480,
                            usageTokens: promptTokens + completionTokens,
                            promptTokens: promptTokens,
                            completionTokens: completionTokens,
                            createdAt: createdAt.addingTimeInterval(600)
                        ),
                    ]
                ))
            }
        }
        return snapshots
    }
}
