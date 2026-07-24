//
//  AgentToolCallViews.swift
//  WillDeep
//
//  Tool call group and card views used by the agent transcript.
//

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 工具卡片的本地化展示助手。模型给的工具 id 是英文 snake_case
/// （`terminal_send_command` / `ask_user` …），直接糊在卡片上对中文
/// 用户不友好。这里集中维护「工具 id → 中文名」与控制键别名的友好
/// 展示。与本文件里 `已读取 N 个文件` 等中文活动文案保持同一约定
/// （Agent transcript 视图统一硬编码中文，不走 L10n 目录）。
nonisolated enum AgentToolDisplay {
    /// 工具 id → 中文展示名。未收录的工具回退到原始 id，绝不丢信息。
    static func name(for toolName: String) -> String {
        toolNames[toolName] ?? toolName
    }

    /// 带括号原始 id 的展示名，例如「终端执行命令 (terminal_send_command)」，
    /// 既给中文用户读得懂的名字，也保留可检索的原始 id 供排查。
    static func nameWithRawID(for toolName: String) -> String {
        guard let localized = toolNames[toolName] else { return toolName }
        return "\(localized)（\(toolName)）"
    }

    /// `terminal_send_control` 的 control 取值（ctrl_c / enter / escape）
    /// 直接显示原始别名既不直观也容易被误会，这里展开成「人话 + 作用」。
    static func controlLabel(for raw: String) -> String {
        switch raw {
        case "ctrl_c": return "Ctrl-C（中断当前命令 / SIGINT）"
        case "enter": return "Enter（回车提交当前行）"
        case "escape": return "Esc（取消 / 退出终端 UI 模式）"
        default: return raw
        }
    }

    static let toolNames: [String: String] = [
        "search_files": "搜索文件",
        "grep_files": "正则搜索",
        "glob": "通配查找",
        "read_file": "读取文件",
        "list_directory": "浏览目录",
        "git_status": "查看 Git 状态",
        "rename_session": "重命名会话",
        "change_workspace": "更改 Workspace",
        "run_command": "运行命令",
        "terminal_snapshot": "终端快照",
        "terminal_create_shortcut": "生成终端捷径",
        "terminal_list_shortcuts": "终端捷径列表",
        "terminal_edit_shortcut": "编辑终端捷径",
        "terminal_send_command": "终端执行命令",
        "terminal_send_control": "终端控制键",
        "terminal_list_tabs": "终端标签列表",
        "terminal_select_tab": "切换终端标签",
        "create_file": "创建文件",
        "edit_file": "编辑文件",
        "apply_patch": "应用补丁",
        "list_jobs": "查看后台任务",
        "get_job_output": "读取任务输出",
        "kill_job": "终止后台任务",
        "list_skills": "查看技能",
        "read_skill": "读取技能",
        "activate_expert": "激活技能包",
        "add_memory": "记忆要点",
        "create_user_skill": "新建技能",
        "update_user_skill": "更新技能",
        "delete_user_skill": "删除技能",
        "search_mcp_servers": "搜索 MCP 服务",
        "suggest_mcp_server": "推荐 MCP 服务",
        "configure_mcp_server": "配置 MCP 服务",
        "web_search": "联网搜索",
        "web_fetch": "抓取网页",
        "generate_image": "生成图片",
        "design_to_code_acceptance": "界面视觉验收",
        "visual_qa_screenshot": "截图视觉检查",
        "capture_screenshot": "截屏",
        "computer_use_permissions": "电脑操作权限",
        "computer_use_request_permissions": "请求电脑操作权限",
        "computer_use_list_apps": "列出 Mac 应用",
        "computer_use_launch_app": "后台启动 Mac 应用",
        "computer_use_activate_app": "切到 Mac 应用",
        "computer_use_get_app_state": "读取应用界面",
        "computer_use_inspect_app": "检查应用控件",
        "computer_use_wait_for": "等待应用状态",
        "computer_use_click": "点击应用控件",
        "computer_use_secondary_action": "打开应用菜单",
        "computer_use_scroll": "滚动应用界面",
        "computer_use_drag": "拖拽应用界面",
        "computer_use_type_text": "输入应用文本",
        "computer_use_press_key": "发送应用按键",
        "computer_use_set_value": "设置应用控件值",
        "computer_use_focus": "聚焦应用控件",
        "computer_use_hover": "悬停应用控件",
        "computer_use_select_text": "选择应用文本",
        "computer_use_restart_helper": "重启电脑操作 Helper",
        "chrome_status": "Chrome 状态",
        "chrome_read_page": "读取网页",
        "chrome_read_selection": "读取网页选区",
        "chrome_snapshot": "读取网页控件",
        "chrome_list_tabs": "列出 Chrome 标签页",
        "chrome_activate_tab": "切换 Chrome 标签页",
        "chrome_navigate": "打开网页",
        "chrome_history": "浏览器前进后退",
        "chrome_click": "点击页面元素",
        "chrome_type": "输入网页文本",
        "chrome_hover": "悬停网页元素",
        "chrome_select_option": "选择网页选项",
        "chrome_press_key": "发送网页按键",
        "chrome_scroll": "滚动网页",
        "chrome_wait_for": "等待网页状态",
        "chrome_capture_tab": "截取标签页",
        "chrome_debugger_command": "Chrome 调试命令",
        "list_mcp_servers": "MCP 服务列表",
        "list_mcp_tools": "MCP 工具列表",
        "call_mcp_tool": "调用 MCP 工具",
        "lark_cli": "飞书 CLI",
        "claude_code": "Claude Code",
        "codex_cli": "Codex CLI",
        "cursor_agent": "Cursor Agent",
        "cline_cli": "Cline CLI",
        "spawn_agent": "派生子代理",
        "ask_user": "询问你",
        "run_workflow": "运行工作流",
        "show_widget": "展示组件",
    ]
}

/// Approval controls are primary task actions, so their hit targets must not
/// collapse to the compact caption-sized controls used by passive tool rows.
/// Keeping the metrics centralized also makes accidental regressions easy to
/// catch without rendering the full transcript in a unit test.
nonisolated enum AgentApprovalActionMetrics {
    static let spacing: CGFloat = 12
    static let minimumButtonWidth: CGFloat = 112
    static let minimumButtonHeight: CGFloat = 36
    static let cornerRadius: CGFloat = 14
}

private extension View {
    /// The custom-radius overload arrived in macOS 14. Keep the intended
    /// 9pt shape there, and use SwiftUI's system rounded rectangle on the
    /// app's macOS 13.7 deployment floor.
    @ViewBuilder
    func approvalButtonBorderShape(cornerRadius: CGFloat) -> some View {
        if #available(macOS 14.0, *) {
            buttonBorderShape(.roundedRectangle(radius: cornerRadius))
        } else {
            buttonBorderShape(.roundedRectangle)
        }
    }
}

/// Primary approval action rendered as a solid, unfilled outline: a crisp
/// accent-colored border with a transparent interior and accent-tinted label.
/// This gives the "继续 / 允许" call-to-action a deliberate outlined look
/// instead of the system `.borderedProminent` fill or the muddy translucent
/// wash that `.bordered` paints behind its label.
private struct AgentApprovalOutlinedButtonStyle: ButtonStyle {
    let accent: Color
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return configuration.label
            .foregroundStyle(accent)
            .background(shape.fill(Color.clear))
            .overlay(shape.strokeBorder(accent, lineWidth: 1.5))
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Layout contract for the soft, skin-aware authorization notice.
/// The same geometry is shared by commands, web access, visible terminal
/// handoffs, and other tools so confirmations feel like one product system.
nonisolated enum AgentConfirmationReviewMetrics {
    static let contentPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 14
    static let dividerThickness: CGFloat = 1
    static let horizontalMinimumWidth: CGFloat = 700
    /// `ViewThatFits` receives the width after the notice's outer padding has
    /// already been removed. Give the horizontal candidate a real minimum
    /// intrinsic width so flexible Spacers cannot make it falsely claim that
    /// it fits in a narrowed chat column.
    static let horizontalContentMinimumWidth = horizontalMinimumWidth - (contentPadding * 2)
    static let commandViewportHeight: CGFloat = 72
    static let commandVisibleLineCount = 3
    static let actionButtonHeight: CGFloat = 28
    static let actionButtonMaxWidth: CGFloat = 124
    static let actionButtonSpacing: CGFloat = 12
    static let outerCornerRadius: CGFloat = 20
    static let innerCornerRadius: CGFloat = 14
    static let iconTileSize: CGFloat = 44
    static let showsKeyboardShortcutHint = false

    static func usesHorizontalLayout(availableWidth: CGFloat) -> Bool {
        availableWidth >= horizontalMinimumWidth
    }
}

nonisolated enum AgentCompactAuthorizationMetrics {
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 15
    static let contentSpacing: CGFloat = 15
    static let actionSpacing: CGFloat = 8
    static let minimumButtonHeight: CGFloat = 22
    static let cornerRadius: CGFloat = 20
    static let buttonCornerRadius: CGFloat = 14
    static let horizontalMinimumWidth: CGFloat = 520

    static func usesHorizontalActions(availableWidth: CGFloat) -> Bool {
        availableWidth >= horizontalMinimumWidth
    }
}

nonisolated struct AgentCompactAuthorizationDescriptor: Equatable {
    let iconName: String
    let title: String
    let question: String
}

nonisolated enum AgentCompactAuthorizationCopy {
    static func descriptor(toolName: String) -> AgentCompactAuthorizationDescriptor? {
        if toolName.hasPrefix("computer_use_") {
            return AgentCompactAuthorizationDescriptor(
                iconName: "cursorarrow.motionlines",
                title: L10n.ToolCard.computerUseAuthorizationTitle,
                question: L10n.ToolCard.computerUseAuthorizationQuestion
            )
        }
        if toolName.hasPrefix("chrome_") {
            return AgentCompactAuthorizationDescriptor(
                iconName: "globe",
                title: L10n.ToolCard.browserAuthorizationTitle,
                question: L10n.ToolCard.browserChromeAuthorizationQuestion
            )
        }
        if toolName.hasPrefix("embedded_browser_") {
            return AgentCompactAuthorizationDescriptor(
                iconName: "globe",
                title: L10n.ToolCard.browserAuthorizationTitle,
                question: L10n.ToolCard.browserEmbeddedAuthorizationQuestion
            )
        }
        return nil
    }
}

nonisolated struct AgentApprovalNoticeDescriptor: Equatable {
    let iconName: String
    let title: String
    let subtitle: String
    let detailTitle: String
    let metadata: [String]
    let explanationTitle: String?
    let decisionTitle: String
    let decisionSubtitle: String
    let declineTitle: String
    let approveTitle: String
    let usesOutlinedApproveAction: Bool
}

/// Tool-specific copy for the shared authorization notice. Keep this free of
/// SwiftUI types so its user-facing promises can be covered by unit tests.
nonisolated enum AgentApprovalNoticeCopy {
    static func descriptor(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> AgentApprovalNoticeDescriptor {
        switch toolName {
        case "run_command":
            return AgentApprovalNoticeDescriptor(
                iconName: "terminal",
                title: "Agent 准备执行一条命令",
                subtitle: "确认后，Agent 会继续完成当前任务。",
                detailTitle: "命令内容",
                metadata: commandMetadata(arguments: arguments),
                explanationTitle: "查看命令说明",
                decisionTitle: "要继续吗？",
                decisionSubtitle: "你可以随时查看后续执行结果。",
                declineTitle: "暂不执行",
                approveTitle: "继续",
                usesOutlinedApproveAction: false
            )
        case "terminal_send_command":
            return AgentApprovalNoticeDescriptor(
                iconName: "rectangle.rightthird.inset.filled",
                title: "Agent 准备发送命令到终端",
                subtitle: "命令会出现在侧边栏终端中，并在确认后执行。",
                detailTitle: "即将发送",
                metadata: terminalMetadata(arguments: arguments),
                explanationTitle: nil,
                decisionTitle: "发送到这个终端吗？",
                decisionSubtitle: "执行过程和结果会继续显示在侧边栏。",
                declineTitle: "暂不发送",
                approveTitle: "发送到终端",
                usesOutlinedApproveAction: true
            )
        case "terminal_send_control":
            return AgentApprovalNoticeDescriptor(
                iconName: "keyboard",
                title: "Agent 准备向终端发送控制键",
                subtitle: "控制键会立即发送到当前会话绑定的终端。",
                detailTitle: "控制键",
                metadata: ["侧边栏终端", "发送后立即生效"],
                explanationTitle: nil,
                decisionTitle: "发送这个控制键吗？",
                decisionSubtitle: "终端会保持可见，便于你继续操作。",
                declineTitle: "暂不发送",
                approveTitle: "发送",
                usesOutlinedApproveAction: false
            )
        case "web_fetch":
            return AgentApprovalNoticeDescriptor(
                iconName: "globe",
                title: "Agent 想读取一个网页",
                subtitle: "网页内容会用于继续回答当前问题。",
                detailTitle: "访问地址",
                metadata: webMetadata(arguments: arguments),
                explanationTitle: "查看访问说明",
                decisionTitle: "允许这次访问吗？",
                decisionSubtitle: "不会提交表单或修改网页内容。",
                declineTitle: "暂不访问",
                approveTitle: "本次允许",
                usesOutlinedApproveAction: false
            )
        default:
            let displayName = AgentToolDisplay.name(for: toolName)
            return AgentApprovalNoticeDescriptor(
                iconName: "sparkles",
                title: "Agent 准备\(displayName)",
                subtitle: "确认后，Agent 会继续完成当前任务。",
                detailTitle: "操作内容",
                metadata: ["由你确认后继续", displayName],
                explanationTitle: "查看操作说明",
                decisionTitle: "允许这一步吗？",
                decisionSubtitle: "操作结果会继续显示在当前对话中。",
                declineTitle: "暂不允许",
                approveTitle: "允许",
                usesOutlinedApproveAction: false
            )
        }
    }

    private static func commandMetadata(
        arguments: [String: AgentJSONValue]
    ) -> [String] {
        let workspaceName = arguments["cwd"]?.stringValue()
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
        return [
            workspaceName.map { "在 \($0) 工作区运行" } ?? "在当前工作区运行",
            "可能更新工作区文件",
        ]
    }

    private static func terminalMetadata(
        arguments: [String: AgentJSONValue]
    ) -> [String] {
        let target = arguments.keys.contains("terminal_tab_id")
            ? "指定终端标签"
            : "当前会话终端"
        return ["侧边栏可见", target, "可随时按 Ctrl-C 中断"]
    }

    private static func webMetadata(
        arguments: [String: AgentJSONValue]
    ) -> [String] {
        let maxCharacters = arguments["max_chars"]?.intValue() ?? 20_000
        let formattedCount = maxCharacters.formatted(.number.grouping(.automatic))
        return ["仅发送 GET 请求", "公开网页", "最多读取 \(formattedCount) 字符"]
    }
}

struct AgentToolCallGroup: View {
    @EnvironmentObject var appState: AppState
    let calls: [AgentToolCall]
    @State private var isExpanded = false

    @ViewBuilder
    var body: some View {
        if containsAwaitingConfirmation {
            interactiveCallsBody
        } else {
            collapsibleGroupBody
        }
    }

    private var interactiveCallsBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(calls) { call in
                AgentToolCallCard(call: call)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
    }

    private var collapsibleGroupBody: some View {
        let status = statusSummary
        return VStack(alignment: .leading, spacing: detailsVisible ? 8 : 0) {
            Button {
                if canToggleDetails {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    if !status.isEmpty {
                        Text(status)
                            .font(AgentDesign.chatSupportingFont(
                                baseFontSize: appState.agentChatBaseFontSize
                            ))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if let previewSummary {
                        Text(previewSummary)
                            .font(AgentDesign.chatSupportingFont(
                                baseFontSize: appState.agentChatBaseFontSize
                            ))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer(minLength: 0)
                    }
                    Image(systemName: detailsVisible ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(canToggleDetails ? .secondary : Color.clear)
                        .frame(width: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canToggleDetails)
            .help(detailsVisible ? L10n.ToolCard.collapse : L10n.ToolCard.expand)
            .cursor(.arrow)

            if detailsVisible {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(calls) { call in
                        AgentToolCallCard(call: call)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, detailsVisible ? 8 : 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(groupBorderColor, lineWidth: 1)
        )
        .padding(.top, detailsVisible ? 8 : 0)
    }

    private var detailsVisible: Bool {
        // Interactive states (ask_user / pendingApproval / awaitingConfirm)
        // need the user's attention NOW — if the group stayed collapsed
        // the user would have to first hunt down the activity summary
        // header and click it to even see the question / approval prompt.
        // Force-expand whenever any inner call is interactive; respect
        // `isExpanded` otherwise so non-interactive bundles stay tidy.
        isExpanded || containsInteractiveCall
    }

    private var canToggleDetails: Bool {
        // While the group has an interactive call we lock it open. The
        // user can still collapse historic groups (no waiting calls)
        // freely.
        !calls.isEmpty && !containsInteractiveCall
    }

    private var containsInteractiveCall: Bool {
        calls.contains { call in
            switch call.status {
            case .pendingApproval, .awaitingConfirm, .awaitingUserAnswer:
                return true
            case .running, .succeeded, .failed, .denied:
                return false
            }
        }
    }

    private var containsAwaitingConfirmation: Bool {
        calls.contains { $0.status == .awaitingConfirm }
    }

    private var statusSummary: String {
        let waiting = calls.filter {
            $0.status == .pendingApproval || $0.status == .awaitingConfirm || $0.status == .awaitingUserAnswer
        }.count
        let running = calls.filter { $0.status == .running }.count
        let failed = calls.filter { $0.status == .failed }.count
        let denied = calls.filter { $0.status == .denied }.count
        let succeeded = calls.filter { $0.status == .succeeded }.count
        var parts: [String] = []
        // Previously an all-success group returned "" — the single most
        // reassuring state (工具全干成了) rendered as *nothing*, leaving
        // the user staring at a bare intent line. Give it an explicit
        // receipt instead so "done" reads as done.
        if succeeded == calls.count, waiting == 0, running == 0, failed == 0, denied == 0 {
            return "✓ 全部完成"
        }
        if waiting > 0 { parts.append("\(waiting) 待处理") }
        if running > 0 { parts.append("\(running) 运行中") }
        if failed > 0 { parts.append("✗ \(failed) 失败") }
        if denied > 0 { parts.append("✗ \(denied) 已拒绝") }
        if succeeded > 0 { parts.append("✓ \(succeeded) 完成") }
        return parts.joined(separator: " · ")
    }

    private var previewSummary: String? {
        AgentCollapsedToolActivitySummary.text(for: calls)
    }

    private var groupBorderColor: Color {
        if containsInteractiveCall { return appState.editorSettings.interfaceSkin.palette.accent.opacity(0.28) }
        if calls.contains(where: { $0.status == .failed }) { return Color.orange.opacity(0.28) }
        return Color.primary.opacity(0.04)
    }
}

/// Live, phase-aware activity surface for the current assistant turn. The
/// current operation is one quiet disclosure row by default. Expanding it
/// reveals the recent timeline. Interactive approvals keep their full controls.
struct AgentLiveActivityTimeline: View {
    @EnvironmentObject var appState: AppState
    let calls: [AgentToolCall]
    @State private var isExpanded = false

    var body: some View {
        let presentation = AgentLiveActivityTimelinePresentation(calls: calls)
        let detailCallIDs = Set(presentation.detailCalls(isExpanded: isExpanded).map(\.id))
        VStack(alignment: .leading, spacing: 7) {
            if isExpanded, presentation.hiddenOperationCount > 0 {
                AgentActivityTimelineSummaryRow(count: presentation.hiddenOperationCount)
            }
            ForEach(presentation.visibleCalls) { call in
                if call.status.isBlockingForUserDecision {
                    AgentToolCallCard(call: call)
                } else if detailCallIDs.contains(call.id) {
                    if call.status == .failed,
                       call.toolName == "run_command",
                       AgentFailedCommandDetailPresentation(call: call).hasDetails {
                        AgentFailedCommandActivityRow(
                            call: call,
                            expandsTimeline: call.id == presentation.disclosureCall?.id
                                && presentation.hasExpandableDetails,
                            isTimelineExpanded: $isExpanded
                        )
                    } else if call.id == presentation.disclosureCall?.id,
                       presentation.hasExpandableDetails {
                        AgentActivityTimelineDisclosureRow(call: call, isExpanded: $isExpanded)
                    } else {
                        AgentToolActivityTimelineRow(
                            presentation: AgentToolActivityRowPresentation(call: call),
                            errorDetail: call.errorMessage
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("agent-live-activity-timeline")
    }
}

private struct AgentFailedCommandActivityRow: View {
    @EnvironmentObject var appState: AppState
    let call: AgentToolCall
    let expandsTimeline: Bool
    @Binding var isTimelineExpanded: Bool
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: showsDetails ? 7 : 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showsDetails.toggle()
                    if showsDetails, expandsTimeline {
                        isTimelineExpanded = true
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    AgentToolActivityTimelineRow(
                        presentation: AgentToolActivityRowPresentation(call: call),
                        errorDetail: call.errorMessage
                    )
                    Image(systemName: showsDetails ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .frame(width: 12, height: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help(showsDetails ? L10n.ToolCard.collapse : L10n.ToolCard.expand)

            if showsDetails {
                AgentFailedCommandDetailView(
                    presentation: AgentFailedCommandDetailPresentation(call: call)
                )
                .padding(.leading, 23)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AgentFailedCommandDetailView: View {
    let presentation: AgentFailedCommandDetailPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let command = presentation.command {
                detailBlock(title: L10n.ToolCard.command, text: command)
            }
            if let workingDirectory = presentation.workingDirectory {
                detailBlock(title: L10n.ToolCard.arguments, text: "cwd: \(workingDirectory)")
            }
            if let output = presentation.output {
                detailBlock(title: L10n.ToolCard.output, text: output)
            }
            if let error = presentation.error {
                detailBlock(title: L10n.ToolCard.error, text: error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

private struct AgentActivityTimelineDisclosureRow: View {
    let call: AgentToolCall
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                AgentToolActivityTimelineRow(
                    presentation: AgentToolActivityRowPresentation(call: call),
                    errorDetail: call.errorMessage
                )
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 12, height: 12)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .help(isExpanded ? L10n.ToolCard.collapse : L10n.ToolCard.expand)
        .accessibilityLabel(AgentToolActivityRowPresentation(call: call).title)
        .accessibilityHint(isExpanded ? L10n.ToolCard.collapse : L10n.ToolCard.expand)
    }
}

private struct AgentActivityTimelineSummaryRow: View {
    @EnvironmentObject var appState: AppState
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12, weight: .regular))
                .frame(width: 15)
            Text(L10n.AgentActivity.earlierOperations(count))
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize
                ))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
    }
}

private struct AgentToolActivityTimelineRow: View {
    @EnvironmentObject var appState: AppState
    let presentation: AgentToolActivityRowPresentation
    let errorDetail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: presentation.systemImage)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(iconColor)
                .frame(width: 15)
            Text(presentation.title)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    weight: .medium
                ))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if let detail = presentation.detail {
                Text(detail)
                    .font(AgentDesign.chatSupportingFont(
                        baseFontSize: appState.agentChatBaseFontSize
                    ))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if presentation.status == .running {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.58)
                    .frame(width: 13, height: 13)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 20)
        .help(errorDetail ?? presentation.title)
        .accessibilityElement(children: .combine)
    }

    private var iconColor: Color {
        switch presentation.status {
        case .running, .pendingApproval, .awaitingConfirm, .awaitingUserAnswer:
            return appState.editorSettings.interfaceSkin.palette.accent
        case .failed:
            return .orange
        case .succeeded, .denied:
            return Color(nsColor: .secondaryLabelColor)
        }
    }

    private var titleColor: Color {
        switch presentation.status {
        case .running:
            return .primary
        case .failed:
            return .orange
        case .pendingApproval, .awaitingConfirm, .awaitingUserAnswer:
            return appState.editorSettings.interfaceSkin.palette.accent
        case .succeeded, .denied:
            return Color(nsColor: .secondaryLabelColor)
        }
    }
}

struct AgentActivityHeadlineView: View {
    let presentation: AgentActivityHeadlinePresentation
    let baseFontSize: CGFloat
    var isActive = false
    var sweepProgressOverride: CGFloat? = nil

    var body: some View {
        HStack(spacing: 8) {
            if isActive {
                AgentActivitySweepLabel(
                    text: presentation.liveTitle,
                    font: AgentDesign.chatSupportingFont(
                        baseFontSize: baseFontSize,
                        weight: .medium
                    ),
                    isActive: true,
                    progressOverride: sweepProgressOverride
                )
            } else {
                Image(systemName: presentation.systemImage)
                    .font(.system(size: 12, weight: .regular))
                    .frame(width: 15)
                Text(presentation.title)
                    .font(AgentDesign.chatSupportingFont(
                        baseFontSize: baseFontSize,
                        weight: .medium
                    ))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        .accessibilityLabel(isActive ? presentation.liveTitle : presentation.title)
    }
}

struct AgentToolCallCard: View {
    @EnvironmentObject var appState: AppState
    let call: AgentToolCall
    @State private var isExpanded = false
    @State private var answerInput = ""
    @State private var selectedOptions: Set<String> = []
    @State private var protectedInputValues: [String: String] = [:]
    @State private var approvalExplanation: AgentApprovalExplanationResult?
    @State private var approvalExplanationError: String?
    @State private var isLoadingApprovalExplanation = false
    @State private var commandCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: isInteractive ? 6 : 3) {
            if !isAuthorizationNotice {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 14)
                    Text(AgentToolDisplay.name(for: call.toolName))
                        .font(AgentDesign.chatSupportingFont(
                            baseFontSize: appState.agentChatBaseFontSize,
                            visualMinimum: 11,
                            weight: .semibold
                        ))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .help(call.toolName)
                    Text(argumentsSummary)
                        .font(AgentDesign.chatSupportingFont(
                            baseFontSize: appState.agentChatBaseFontSize
                        ))
                        .foregroundStyle(.secondary)
                        .lineLimit(isInteractive ? 2 : 1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(statusText)
                        .font(AgentDesign.chatSupportingFont(
                            baseFontSize: appState.agentChatBaseFontSize
                        ))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if let label = approvalSourceLabel {
                        Text(label)
                            .font(AgentDesign.chatSupportingFont(
                                baseFontSize: appState.agentChatBaseFontSize,
                                visualMinimum: 9,
                                weight: .semibold
                            ))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.12))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                            .help(approvalSourceTooltip ?? "")
                    }
                    if hasExpandableContent {
                        Button {
                            isExpanded.toggle()
                        } label: {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .help(isExpanded ? L10n.ToolCard.collapse : L10n.ToolCard.expand)
                    }
                }
                .frame(minHeight: 20)
                .help("\(riskBadge): \(argumentsSummary)")
            }

            if let badge = subagentBadgeText {
                HStack(spacing: 5) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(badge)
                        .font(AgentDesign.chatSupportingFont(
                            baseFontSize: appState.agentChatBaseFontSize,
                            visualMinimum: 10,
                            weight: .medium
                        ))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            }

            if let images = call.result?.images, !images.isEmpty {
                AgentToolResultImageStrip(images: images)
            }

            if isExpanded {
                if !argumentsLines.isEmpty {
                    expandableBlock(title: L10n.ToolCard.arguments, text: argumentsLines)
                }
                if let payload = call.result?.payload, !payload.isEmpty {
                    expandableBlock(title: L10n.ToolCard.output, text: payload)
                }
                if let errorMessage = call.errorMessage, !errorMessage.isEmpty {
                    expandableBlock(title: L10n.ToolCard.error, text: errorMessage)
                }
            }

            if isAuthorizationNotice {
                if isCompactSurfaceAuthorizationNotice {
                    compactSurfaceAuthorizationNoticeBody
                } else {
                    authorizationNoticeBody
                }
            } else if call.status == .awaitingUserAnswer {
                askUserBody
            } else if call.toolName == "ask_user" {
                askUserResolvedRow
            } else if call.toolName == "terminal_create_shortcut" {
                terminalShortcutProtectedInputsBody
            }
        }
        .padding(.horizontal, isAuthorizationNotice ? 0 : 7)
        .padding(.vertical, isAuthorizationNotice ? 0 : (isInteractive ? 7 : 4))
        .background(cardBackground)
        .clipShape(
            RoundedRectangle(
                cornerRadius: isAuthorizationNotice
                    ? authorizationCornerRadius
                    : 6,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: isAuthorizationNotice
                    ? authorizationCornerRadius
                    : 6,
                style: .continuous
            )
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var approvalDescriptor: AgentApprovalNoticeDescriptor {
        AgentApprovalNoticeCopy.descriptor(toolName: call.toolName, arguments: call.arguments)
    }

    private var compactAuthorizationDescriptor: AgentCompactAuthorizationDescriptor? {
        AgentCompactAuthorizationCopy.descriptor(toolName: call.toolName)
    }

    private var compactSurfaceAuthorizationNoticeBody: some View {
        let descriptor = compactAuthorizationDescriptor
        return VStack(alignment: .leading, spacing: AgentCompactAuthorizationMetrics.contentSpacing) {
            if let descriptor {
                HStack(spacing: 8) {
                    Image(systemName: descriptor.iconName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(appState.editorSettings.interfaceSkin.palette.accent)
                        .frame(width: 18, height: 18)
                    Text(descriptor.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(appState.editorSettings.interfaceSkin.palette.secondaryText)
                }

                Text(descriptor.question)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(appState.editorSettings.interfaceSkin.palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            compactAuthorizationActions
        }
        .padding(.horizontal, AgentCompactAuthorizationMetrics.horizontalPadding)
        .padding(.vertical, AgentCompactAuthorizationMetrics.verticalPadding)
    }

    @ViewBuilder
    private var compactAuthorizationActions: some View {
        if decisionAlreadySubmitted {
            submittedDecisionNotice
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AgentCompactAuthorizationMetrics.actionSpacing) {
                    compactAlwaysAllowButton
                    Spacer(minLength: 16)
                    compactDenyButton
                    compactConversationAllowButton
                }
                VStack(alignment: .leading, spacing: AgentCompactAuthorizationMetrics.actionSpacing) {
                    compactAlwaysAllowButton
                    HStack(spacing: AgentCompactAuthorizationMetrics.actionSpacing) {
                        Spacer(minLength: 0)
                        compactDenyButton
                        compactConversationAllowButton
                    }
                }
            }
            .controlSize(.regular)
        }
    }

    private var compactAlwaysAllowButton: some View {
        Button {
            appState.alwaysAllowAgentToolCall(id: call.id)
        } label: {
            compactAuthorizationActionLabel(L10n.ToolCard.alwaysAllow)
        }
        .buttonStyle(.bordered)
        .approvalButtonBorderShape(cornerRadius: AgentCompactAuthorizationMetrics.buttonCornerRadius)
        .tint(appState.editorSettings.interfaceSkin.palette.accent)
        .cursor(.arrow)
    }

    private var compactDenyButton: some View {
        Button {
            appState.denyAgentToolCall(id: call.id)
        } label: {
            compactAuthorizationActionLabel(L10n.ToolCard.deny)
        }
        .buttonStyle(.bordered)
        .approvalButtonBorderShape(cornerRadius: AgentCompactAuthorizationMetrics.buttonCornerRadius)
        .tint(appState.editorSettings.interfaceSkin.palette.accent)
        .cursor(.arrow)
    }

    private var compactConversationAllowButton: some View {
        Button {
            appState.allowAgentToolFamilyForConversation(id: call.id)
        } label: {
            compactAuthorizationActionLabel(L10n.ToolCard.allowConversation)
        }
        .buttonStyle(
            AgentApprovalOutlinedButtonStyle(
                accent: appState.editorSettings.interfaceSkin.palette.accent,
                cornerRadius: AgentCompactAuthorizationMetrics.buttonCornerRadius
            )
        )
        .tint(appState.editorSettings.interfaceSkin.palette.accent)
        .cursor(.arrow)
    }

    private func compactAuthorizationActionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 2)
            .frame(minHeight: AgentCompactAuthorizationMetrics.minimumButtonHeight)
            .contentShape(
                RoundedRectangle(
                    cornerRadius: AgentCompactAuthorizationMetrics.buttonCornerRadius,
                    style: .continuous
                )
            )
    }

    private var authorizationNoticeBody: some View {
        let descriptor = approvalDescriptor
        let palette = appState.editorSettings.interfaceSkin.palette
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: AgentConfirmationReviewMetrics.sectionSpacing) {
                authorizationHeader(descriptor)
                authorizationDetailSurface(descriptor)
                authorizationMetadata(descriptor)
                authorizationExplanation
            }
            .padding(AgentConfirmationReviewMetrics.contentPadding)

            Rectangle()
                .fill(palette.hairline)
                .frame(height: AgentConfirmationReviewMetrics.dividerThickness)

            authorizationFooter(descriptor)
                .padding(AgentConfirmationReviewMetrics.contentPadding)
        }
    }

    private func authorizationHeader(
        _ descriptor: AgentApprovalNoticeDescriptor
    ) -> some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: AgentConfirmationReviewMetrics.innerCornerRadius,
                    style: .continuous
                )
                .fill(palette.selectionFill)
                Image(systemName: descriptor.iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
            .frame(
                width: AgentConfirmationReviewMetrics.iconTileSize,
                height: AgentConfirmationReviewMetrics.iconTileSize
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("需要你的确认")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.accent)
                Text(descriptor.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(descriptor.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func authorizationDetailSurface(
        _ descriptor: AgentApprovalNoticeDescriptor
    ) -> some View {
        if let detail = approvalDetail {
            let palette = appState.editorSettings.interfaceSkin.palette
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(descriptor.detailTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                    Spacer(minLength: 0)
                    Button {
                        copyApprovalCommand(detail.body)
                    } label: {
                        Label(
                            commandCopied ? "已复制" : "复制",
                            systemImage: commandCopied ? "checkmark" : "doc.on.doc"
                        )
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(
                            commandCopied ? palette.secondaryAccent : palette.secondaryText
                        )
                    }
                    .buttonStyle(.plain)
                    .help(commandCopied ? "内容已复制" : "复制完整内容")
                    .cursor(.arrow)
                }

                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    Text(detail.body)
                        .font(.system(size: 12, design: .monospaced))
                        .lineSpacing(3)
                        .foregroundStyle(palette.primaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(12)
                }
                .frame(
                    minWidth: 0,
                    maxWidth: .infinity,
                    minHeight: AgentConfirmationReviewMetrics.commandViewportHeight,
                    maxHeight: AgentConfirmationReviewMetrics.commandViewportHeight
                )
                .background(palette.controlFill.opacity(0.72))
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: AgentConfirmationReviewMetrics.innerCornerRadius,
                        style: .continuous
                    )
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: AgentConfirmationReviewMetrics.innerCornerRadius,
                        style: .continuous
                    )
                    .stroke(palette.hairline, lineWidth: 1)
                )
            }
        }
    }

    private func authorizationMetadata(
        _ descriptor: AgentApprovalNoticeDescriptor
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                authorizationMetadataChips(descriptor.metadata)
                if let explanationTitle = descriptor.explanationTitle {
                    Spacer(minLength: 4)
                    authorizationExplanationButton(title: explanationTitle)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 10) {
                authorizationMetadataRows(descriptor.metadata)
                if let explanationTitle = descriptor.explanationTitle {
                    authorizationExplanationButton(title: explanationTitle)
                }
            }
        }
    }

    private func authorizationMetadataChips(_ metadata: [String]) -> some View {
        HStack(spacing: 7) {
            ForEach(Array(metadata.enumerated()), id: \.offset) { index, item in
                authorizationMetadataChip(item, index: index)
            }
        }
    }

    private func authorizationMetadataRows(_ metadata: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(metadata.enumerated()), id: \.offset) { index, item in
                authorizationMetadataChip(item, index: index)
            }
        }
    }

    private func authorizationMetadataChip(_ item: String, index: Int) -> some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        return HStack(spacing: 5) {
            Image(systemName: metadataIcon(at: index))
                .font(.system(size: 9, weight: .semibold))
            Text(item)
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(palette.secondaryText)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(palette.selectionFill.opacity(0.68))
        .clipShape(Capsule())
    }

    private func metadataIcon(at index: Int) -> String {
        switch index {
        case 0: return "location"
        case 1: return "bell"
        default: return "text.alignleft"
        }
    }

    private func authorizationExplanationButton(title: String) -> some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        return Button {
            loadApprovalExplanation()
        } label: {
            HStack(spacing: 6) {
                if isLoadingApprovalExplanation {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.64)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(approvalExplanation == nil ? title : "重新查看说明")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(palette.accent)
        }
        .buttonStyle(.plain)
        .disabled(isLoadingApprovalExplanation)
        .help("查看这一步会做什么，以及可能影响哪些内容。")
        .cursor(.arrow)
    }

    @ViewBuilder
    private var authorizationExplanation: some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        if let text = approvalExplanation?.text {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(palette.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.selectionFill.opacity(0.46))
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: AgentConfirmationReviewMetrics.innerCornerRadius,
                        style: .continuous
                    )
                )
        } else if let error = approvalExplanationError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(palette.secondaryAccent)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func authorizationFooter(
        _ descriptor: AgentApprovalNoticeDescriptor
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                authorizationDecisionCopy(descriptor)
                Spacer(minLength: 16)
                authorizationActions(descriptor)
            }
            .frame(
                minWidth: AgentConfirmationReviewMetrics.horizontalContentMinimumWidth,
                alignment: .leading
            )
            VStack(alignment: .leading, spacing: 16) {
                authorizationDecisionCopy(descriptor)
                authorizationActions(descriptor)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func authorizationDecisionCopy(
        _ descriptor: AgentApprovalNoticeDescriptor
    ) -> some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        return VStack(alignment: .leading, spacing: 4) {
            Text(descriptor.decisionTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.primaryText)
            Text(descriptor.decisionSubtitle)
                .font(.system(size: 12))
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func authorizationActions(
        _ descriptor: AgentApprovalNoticeDescriptor
    ) -> some View {
        if decisionAlreadySubmitted {
            submittedDecisionNotice
        } else {
            let palette = appState.editorSettings.interfaceSkin.palette
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: AgentConfirmationReviewMetrics.actionButtonSpacing) {
                    Button {
                        appState.denyAgentToolCall(id: call.id)
                    } label: {
                        approvalActionLabel(descriptor.declineTitle, systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .approvalButtonBorderShape(cornerRadius: AgentApprovalActionMetrics.cornerRadius)
                    .tint(palette.accent)
                    .cursor(.arrow)
                    .frame(maxWidth: AgentConfirmationReviewMetrics.actionButtonMaxWidth)

                    authorizationApproveButton(
                        descriptor,
                        accent: palette.accent
                    )
                }
                .controlSize(.regular)

                if alwaysAllowSignature != nil {
                    Button("以后允许同类操作") {
                        appState.alwaysAllowAgentToolCall(id: call.id)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .cursor(.arrow)
                }
            }
        }
    }

    @ViewBuilder
    private func authorizationApproveButton(
        _ descriptor: AgentApprovalNoticeDescriptor,
        accent: Color
    ) -> some View {
        Button {
            approveAuthorizationNotice()
        } label: {
            approvalActionLabel(descriptor.approveTitle, systemImage: "arrow.right")
        }
        .buttonStyle(
            AgentApprovalOutlinedButtonStyle(
                accent: accent,
                cornerRadius: AgentApprovalActionMetrics.cornerRadius
            )
        )
        .tint(accent)
        .cursor(.arrow)
        .frame(maxWidth: AgentConfirmationReviewMetrics.actionButtonMaxWidth)
    }

    private func approveAuthorizationNotice() {
        if call.status == .awaitingConfirm {
            _ = appState.confirmAgentToolCall(id: call.id, typedConfirmation: "confirm")
        } else {
            appState.approveAgentToolCall(id: call.id)
        }
    }

    private var awaitingConfirmationBody: some View {
        authorizationNoticeBody
    }

    private var confirmationDivider: some View {
        Rectangle()
            .fill(appState.editorSettings.interfaceSkin.palette.hairline)
    }

    private var confirmationReviewColumn: some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        return VStack(alignment: .leading, spacing: AgentConfirmationReviewMetrics.sectionSpacing) {
            Text("命令确认")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondaryText)

            Text("Agent 想执行以下命令")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(palette.primaryText)

            Text("请检查内容是否符合你的预期。")
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryText)

            confirmationCommandViewport
            confirmationMetadata

            if let text = approvalExplanation?.text {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            } else if let error = approvalExplanationError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AgentConfirmationReviewMetrics.contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var confirmationCommandViewport: some View {
        if let detail = approvalDetail {
            let palette = appState.editorSettings.interfaceSkin.palette
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("命令内容")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                    Spacer(minLength: 0)
                    Button {
                        copyApprovalCommand(detail.body)
                    } label: {
                        Image(systemName: commandCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(commandCopied ? palette.secondaryAccent : palette.secondaryText)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(commandCopied ? "已复制" : "复制命令")
                    .cursor(.arrow)
                }

                ScrollView(.vertical, showsIndicators: true) {
                    Text(detail.body)
                        .font(.system(size: 12, design: .monospaced))
                        .lineSpacing(3)
                        .foregroundStyle(palette.primaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: AgentConfirmationReviewMetrics.commandViewportHeight)
                .background(palette.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(palette.hairline, lineWidth: 1)
                )
            }
        }
    }

    private var confirmationMetadata: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) {
                if let directory = approvalWorkingDirectoryName {
                    Text("工作目录：\(directory)")
                        .foregroundStyle(appState.editorSettings.interfaceSkin.palette.secondaryText)
                    Text("·")
                        .foregroundStyle(appState.editorSettings.interfaceSkin.palette.secondaryText)
                }
                confirmationMutationLabel
                Text("·")
                    .foregroundStyle(appState.editorSettings.interfaceSkin.palette.secondaryText)
                confirmationExplanationButton
            }
            VStack(alignment: .leading, spacing: 7) {
                if let directory = approvalWorkingDirectoryName {
                    Text("工作目录：\(directory)")
                        .foregroundStyle(appState.editorSettings.interfaceSkin.palette.secondaryText)
                }
                confirmationMutationLabel
                confirmationExplanationButton
            }
        }
        .font(.system(size: 11))
    }

    private var confirmationMutationLabel: some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        return HStack(spacing: 5) {
            Circle()
                .fill(palette.secondaryAccent)
                .frame(width: 6, height: 6)
            Text("可能修改文件")
                .foregroundStyle(palette.secondaryAccent)
        }
    }

    private var confirmationExplanationButton: some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        return Button {
            loadApprovalExplanation()
        } label: {
            HStack(spacing: 5) {
                if isLoadingApprovalExplanation {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.62)
                        .frame(width: 11, height: 11)
                }
                Text(approvalExplanation == nil ? "查看命令说明" : "重新分析")
            }
            .foregroundStyle(palette.accent)
        }
        .buttonStyle(.plain)
        .disabled(isLoadingApprovalExplanation)
        .help("解释命令影响，并给出允许、拒绝或改用更安全方案的建议。")
        .cursor(.arrow)
    }

    private var confirmationDecisionColumn: some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        return VStack(alignment: .leading, spacing: AgentConfirmationReviewMetrics.sectionSpacing) {
            Text("是否继续？")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.primaryText)

            Text("你的确认将授权 Agent 执行这条命令。")
                .font(.system(size: 12))
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 16)

            if decisionAlreadySubmitted {
                submittedDecisionNotice
            } else {
                HStack(spacing: AgentConfirmationReviewMetrics.actionButtonSpacing) {
                    Button {
                        appState.denyAgentToolCall(id: call.id)
                    } label: {
                        confirmationActionLabel(L10n.ToolCard.deny)
                    }
                    .buttonStyle(.bordered)
                    .approvalButtonBorderShape(cornerRadius: AgentApprovalActionMetrics.cornerRadius)
                    .tint(palette.accent)
                    .cursor(.arrow)
                    .frame(maxWidth: AgentConfirmationReviewMetrics.actionButtonMaxWidth)

                    Button {
                        _ = appState.confirmAgentToolCall(id: call.id, typedConfirmation: "confirm")
                    } label: {
                        confirmationActionLabel(L10n.ToolCard.allow)
                    }
                    .buttonStyle(
                        AgentApprovalOutlinedButtonStyle(
                            accent: palette.accent,
                            cornerRadius: AgentApprovalActionMetrics.cornerRadius
                        )
                    )
                    .tint(palette.accent)
                    .cursor(.arrow)
                    .frame(maxWidth: AgentConfirmationReviewMetrics.actionButtonMaxWidth)
                }
                .controlSize(.regular)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(AgentConfirmationReviewMetrics.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func confirmationActionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .frame(
                maxWidth: .infinity,
                minHeight: AgentConfirmationReviewMetrics.actionButtonHeight
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: AgentApprovalActionMetrics.cornerRadius,
                    style: .continuous
                )
            )
    }

    private func copyApprovalCommand(_ command: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        commandCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            commandCopied = false
        }
    }

    @ViewBuilder
    private var approvalCommandBlock: some View {
        if let detail = approvalDetail {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(detail.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                ScrollView([.horizontal, .vertical]) {
                    Text(detail.body)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // 默认最多约 3 行(12pt 行高 ~16pt × 3 + 上下内边距),更长的
                // 命令在框内纵向/横向滚动查看全部,不再把整张卡撑得老高。
                .frame(minHeight: 42, maxHeight: 62)
                .background(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .textBackgroundColor),
                            appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.45)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(approvalSurfaceBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func approvalReviewHeader(
        title: String,
        subtitle: String,
        tint: Color,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.14))
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(riskBadge)
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .foregroundStyle(tint)
                .background(tint.opacity(0.10))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(approvalSurfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func approvalActionLabel(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .frame(
                minWidth: AgentApprovalActionMetrics.minimumButtonWidth,
                minHeight: AgentApprovalActionMetrics.minimumButtonHeight
            )
            .frame(maxWidth: .infinity)
            .contentShape(
                RoundedRectangle(
                    cornerRadius: AgentApprovalActionMetrics.cornerRadius,
                    style: .continuous
                )
            )
    }

    @ViewBuilder
    private var approvalExplanationSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Button {
                    loadApprovalExplanation()
                } label: {
                    if isLoadingApprovalExplanation {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.62)
                                .frame(width: 12, height: 12)
                            Text("正在查看解释")
                        }
                    } else {
                        Label(approvalExplanation == nil ? "查看解释与解决建议" : "重新解释", systemImage: "lightbulb")
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption2.weight(.semibold))
                .disabled(isLoadingApprovalExplanation)
                .help("用轻量模型解释这次审核项，并给出允许/拒绝/改方案建议。")
                .cursor(.arrow)
                Spacer(minLength: 0)
                if let model = approvalExplanation?.model {
                    Text(model)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let text = approvalExplanation?.text {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.42))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else if let error = approvalExplanationError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(approvalSurfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func loadApprovalExplanation() {
        guard !isLoadingApprovalExplanation else { return }
        isLoadingApprovalExplanation = true
        approvalExplanationError = nil
        Task {
            do {
                let result = try await appState.explainAgentToolApproval(call)
                await MainActor.run {
                    approvalExplanation = result
                    isLoadingApprovalExplanation = false
                }
            } catch {
                await MainActor.run {
                    approvalExplanationError = "解释失败：\(AppState.friendlyMessage(for: error))"
                    isLoadingApprovalExplanation = false
                }
            }
        }
    }

    private var submittedDecisionNotice: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.58)
                .frame(width: 12, height: 12)
            Text("已提交决定，等待执行循环接收")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var askUserBody: some View {
        let question = call.arguments["question"]?.stringValue() ?? ""
        // rc3: option labels are LLM-authored. Defang first so the button
        // the user clicks shows the same string the model gets back as the
        // user's answer — and so options can't smuggle control characters
        // or `<system>` framing through the chat UI.
        let rawOptions = call.arguments["options"]?.stringArrayValue() ?? []
        let options = AgentInjectionDefense.sanitizeAskUserOptions(rawOptions)
        let isMultiSelect = call.arguments["multi_select"]?.boolValue() ?? false

        VStack(alignment: .leading, spacing: 8) {
            if !question.isEmpty {
                Text(question)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if decisionAlreadySubmitted {
                submittedDecisionNotice
            } else {
                if !options.isEmpty {
                    if isMultiSelect {
                        multiSelectChoices(options)
                    } else {
                        singleSelectChoices(options)
                    }
                }

                // Free-form text input is always available — even with preset
                // options, the user may want to write "none of these".
                TextField(options.isEmpty ? L10n.ToolCard.askUserAnswerPlaceholder : L10n.ToolCard.askUserOtherAnswerPlaceholder,
                          text: $answerInput,
                          axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .lineLimit(1...4)

                // rc16:Skip 在左、Send 在右,对齐「正向操作右、误触概率低」的
                // macOS 习惯。Send 的 disabled 状态自然把视觉重心保留在右侧。
                HStack(spacing: 6) {
                    Button(L10n.ToolCard.askUserSkip) {
                        appState.denyAgentToolCall(id: call.id)
                        resetAskUserInputs()
                    }
                    .cursor(.arrow)
                    Spacer(minLength: 0)
                    Button(L10n.ToolCard.askUserSend) {
                        submitAnswer(options: options, isMultiSelect: isMultiSelect)
                    }
                    .disabled(!canSubmitAskUser(isMultiSelect: isMultiSelect))
                    .cursor(.arrow)
                }
                .font(.caption)
            }
        }
    }

    // After the question resolves the interactive card is gone, but the
    // chosen answer used to survive only inside the collapsed "output"
    // expander — so the transcript looked like the user's selection
    // vanished. Echo it back as an always-visible, clearly-attributed row
    // so the conversation reads coherently. (The model still receives the
    // answer via the `<user_answer>` tool message; this is render-only.)
    @ViewBuilder
    private var askUserResolvedRow: some View {
        let answer = (call.result?.payload ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if call.status == .succeeded, !answer.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(askUserSecondaryAccentColor.opacity(0.72))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.ToolCard.askUserAnswered)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(answer)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(askUserAccentColor.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(askUserAccentColor.opacity(0.28), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else if call.status == .denied {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.6))
                Text(L10n.ToolCard.askUserSkipped)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var terminalShortcutProtectedInputsBody: some View {
        switch terminalShortcutProtectedInputState {
        case .some(.pending(let promptSet)):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(askUserSecondaryAccentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.AgentTerminal.shortcutPasswordCardTitle(promptSet.title))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(L10n.AgentTerminal.shortcutPasswordCardDescription)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                ForEach(promptSet.prompts) { prompt in
                    SecureField(prompt.label, text: Binding(
                        get: { protectedInputValues[protectedInputKey(shortcutID: promptSet.shortcutID, eventIndex: prompt.eventIndex)] ?? "" },
                        set: { protectedInputValues[protectedInputKey(shortcutID: promptSet.shortcutID, eventIndex: prompt.eventIndex)] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                }

                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button(L10n.AgentTerminal.shortcutPasswordSave) {
                        let values = promptSet.prompts.reduce(into: [Int: String]()) { result, prompt in
                            let key = protectedInputKey(shortcutID: promptSet.shortcutID, eventIndex: prompt.eventIndex)
                            result[prompt.eventIndex] = protectedInputValues[key] ?? ""
                        }
                        guard appState.fillTerminalShortcutProtectedInputs(
                            shortcutID: promptSet.shortcutID,
                            valuesByEventIndex: values
                        ) else { return }
                        isExpanded = false
                        for prompt in promptSet.prompts {
                            protectedInputValues.removeValue(
                                forKey: protectedInputKey(shortcutID: promptSet.shortcutID, eventIndex: prompt.eventIndex)
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSaveProtectedInputs(promptSet))
                    .cursor(.arrow)
                }
                .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(askUserAccentColor.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(askUserAccentColor.opacity(0.28), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .some(.filled(_)):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(askUserSecondaryAccentColor.opacity(0.72))
                Text(L10n.ToolCard.terminalPasswordEntered)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        case .none:
            EmptyView()
        }
    }

    private func singleSelectChoices(_ options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button {
                    appState.answerAgentToolCall(id: call.id, answer: option)
                    resetAskUserInputs()
                } label: {
                    HStack(spacing: 8) {
                        Text(option)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.turn.down.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(askUserSecondaryAccentColor.opacity(0.72))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.primary)
                    .background(askUserAccentColor.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(askUserAccentColor.opacity(0.28), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .cursor(.arrow)
            }
        }
    }

    private func multiSelectChoices(_ options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { option in
                Toggle(isOn: Binding(
                    get: { selectedOptions.contains(option) },
                    set: { isOn in
                        if isOn { selectedOptions.insert(option) }
                        else { selectedOptions.remove(option) }
                    }
                )) {
                    Text(option)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selectedOptions.contains(option) ? askUserAccentColor.opacity(0.10) : appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.58))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(selectedOptions.contains(option) ? askUserAccentColor.opacity(0.32) : appState.editorSettings.interfaceSkin.palette.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .cursor(.arrow)
            }
        }
    }

    private func canSubmitAskUser(isMultiSelect: Bool) -> Bool {
        if !answerInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if isMultiSelect { return !selectedOptions.isEmpty }
        return false
    }

    private func submitAnswer(options: [String], isMultiSelect: Bool) {
        // Free-form text wins if the user typed anything — gives them an
        // escape hatch from the preset options.
        let typed = answerInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer: String
        if !typed.isEmpty {
            answer = typed
        } else if isMultiSelect {
            // Preserve the order the model offered them so the
            // assistant can correlate.
            answer = options.filter { selectedOptions.contains($0) }.joined(separator: ", ")
        } else {
            return
        }
        appState.answerAgentToolCall(id: call.id, answer: answer)
        resetAskUserInputs()
    }

    private func resetAskUserInputs() {
        answerInput = ""
        selectedOptions = []
    }

    private func protectedInputKey(shortcutID: UUID, eventIndex: Int) -> String {
        "\(call.id.uuidString):\(shortcutID.uuidString):\(eventIndex)"
    }

    private func canSaveProtectedInputs(_ promptSet: TerminalShortcutProtectedPromptSet) -> Bool {
        promptSet.prompts.allSatisfy { prompt in
            protectedInputValues[protectedInputKey(shortcutID: promptSet.shortcutID, eventIndex: prompt.eventIndex)]?.isEmpty == false
        }
    }

    private func expandableBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 96)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    /// spawn_agent-only badge: which model the child runs on plus its live
    /// round/tool progress. `subagentModel` is stamped when the spawn starts;
    /// `subagentProgress` refreshes each round and is cleared on finish, so
    /// after completion this collapses to just the model.
    private var subagentBadgeText: String? {
        guard call.toolName == "spawn_agent" else { return nil }
        var parts: [String] = []
        if let model = call.subagentModel, !model.isEmpty {
            parts.append("模型 \(model)")
        }
        if call.status == .running, let progress = call.subagentProgress, !progress.isEmpty {
            parts.append(progress)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var argumentsSummary: String {
        guard !call.arguments.isEmpty else { return "(no arguments)" }
        // 控制键单独展开成「人话」,别让用户对着 control=ctrl_c 猜。
        if call.toolName == "terminal_send_control",
           let raw = call.arguments["control"]?.stringValue() {
            return AgentToolDisplay.controlLabel(for: raw)
        }
        return call.arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.displaySummary)" }
            .joined(separator: " · ")
    }

    private var argumentsLines: String {
        call.arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.displaySummary)" }
            .joined(separator: "\n")
    }

    private var fullCommand: String? {
        guard ["run_command", "terminal_send_command"].contains(call.toolName),
              let command = call.arguments["command"]?.stringValue(),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return command
    }

    /// 审批时给用户看的「这次到底要做什么」明细块。命令类工具显示
    /// 完整命令（默认约 3 行高，超出滚动查看）；网页、控制键及通用工具
    /// 分别展示地址、友好按键说明或参数明细。
    private var approvalDetail: (title: String, body: String)? {
        if let command = fullCommand {
            var body = command
            if call.toolName == "terminal_send_command",
               let uploadPaths = call.arguments["zmodem_upload_paths"]?.stringArrayValue(),
               !uploadPaths.isEmpty {
                body += "\n\nzmodem_upload_paths:\n" + uploadPaths.joined(separator: "\n")
            }
            if call.toolName == "terminal_send_command",
               let downloadDirectory = call.arguments["zmodem_download_directory"]?.stringValue(),
               !downloadDirectory.isEmpty {
                body += "\n\nzmodem_download_directory:\n\(downloadDirectory)"
            }
            return (L10n.ToolCard.command, body)
        }
        if call.toolName == "terminal_send_control",
           let raw = call.arguments["control"]?.stringValue() {
            return ("控制键", AgentToolDisplay.controlLabel(for: raw))
        }
        if call.toolName == "web_fetch",
           let url = call.arguments["url"]?.stringValue(),
           !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ("访问地址", url)
        }
        guard !argumentsLines.isEmpty else { return nil }
        return ("操作内容", argumentsLines)
    }

    private var approvalWorkingDirectoryName: String? {
        if let cwdValue = call.arguments["cwd"]?.stringValue() {
            let cwd = cwdValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cwd.isEmpty {
                return URL(fileURLWithPath: cwd).lastPathComponent
            }
        }

        guard let command = fullCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              command.hasPrefix("cd "),
              let cdSegment = command.dropFirst(3).components(separatedBy: "&&").first else {
            return nil
        }
        let path = cdSegment
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var alwaysAllowSignature: String? {
        AgentToolAuthorization.suggestedPersistentSignature(
            toolName: call.toolName,
            arguments: call.arguments
        )
    }

    private var decisionAlreadySubmitted: Bool {
        appState.hasPendingAgentToolDecision(id: call.id)
    }

    private var iconName: String {
        if terminalShortcutProtectedInputState != nil {
            return "lock.shield"
        }
        switch call.status {
        case .pendingApproval, .awaitingConfirm: return "questionmark.circle"
        case .awaitingUserAnswer: return "bubble.left.and.text.bubble.right"
        case .running: return "hourglass"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .denied: return "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        if terminalShortcutProtectedInputState != nil {
            return askUserAccentColor
        }
        switch call.status {
        case .pendingApproval: return appState.editorSettings.interfaceSkin.palette.accent
        case .awaitingConfirm: return appState.editorSettings.interfaceSkin.palette.secondaryAccent
        case .awaitingUserAnswer: return askUserAccentColor
        case .running: return .secondary
        case .succeeded: return .secondary
        case .failed: return .orange
        case .denied: return .secondary
        }
    }

    private var statusColor: Color {
        if terminalShortcutProtectedInputState != nil {
            return askUserAccentColor
        }
        switch call.status {
        case .pendingApproval: return appState.editorSettings.interfaceSkin.palette.accent
        case .awaitingConfirm: return appState.editorSettings.interfaceSkin.palette.secondaryAccent
        case .awaitingUserAnswer: return askUserAccentColor
        case .failed: return .orange
        case .running, .succeeded, .denied: return .secondary
        }
    }

    private var isInteractive: Bool {
        if case .some(.pending(_)) = terminalShortcutProtectedInputState {
            return true
        }
        switch call.status {
        case .pendingApproval, .awaitingConfirm, .awaitingUserAnswer:
            return true
        case .running, .succeeded, .failed, .denied:
            return isExpanded
        }
    }

    private var isAuthorizationNotice: Bool {
        call.status == .pendingApproval || call.status == .awaitingConfirm
    }

    private var isCompactSurfaceAuthorizationNotice: Bool {
        call.risk == .write && compactAuthorizationDescriptor != nil
    }

    private var authorizationCornerRadius: CGFloat {
        isCompactSurfaceAuthorizationNotice
            ? AgentCompactAuthorizationMetrics.cornerRadius
            : AgentConfirmationReviewMetrics.outerCornerRadius
    }

    private var hasExpandableContent: Bool {
        if terminalShortcutProtectedInputFilled {
            return false
        }
        return terminalShortcutProtectedInputState != nil
        || !argumentsLines.isEmpty
        || !(call.result?.payload.isEmpty ?? true)
        || !(call.errorMessage?.isEmpty ?? true)
    }

    /// Show a small badge next to the status text when a write-tier
    /// tool call ran without the user clicking Allow, so it's auditable
    /// after the fact.
    private var approvalSourceLabel: String? {
        guard call.risk == .write,
              call.status == .running || call.status == .succeeded || call.status == .failed,
              let source = call.approvalSource else { return nil }
        switch source {
        case .user: return nil // explicit user clicks don't need a badge
        case .alwaysAllowList: return "ALWAYS"
        case .staticAllowlist: return "AUTO"
        case .llmJudge: return "AI OK"
        case .goalMode: return "GOAL"
        case .workspaceAccess: return "WORKSPACE"
        case .escalated: return "ESCALATED"
        case .trustedServer: return "TRUSTED"
        }
    }

    private var approvalSourceTooltip: String? {
        guard let source = call.approvalSource else { return nil }
        switch source {
        case .user: return nil
        case .alwaysAllowList: return "You pinned this command signature as always-allowed."
        case .staticAllowlist: return "Matched the built-in read-only allowlist (safe shell commands / read-style MCP tools)."
        case .llmJudge: return "An LLM judge classified this call as non-malicious normal work."
        case .goalMode: return "Auto-approved because this session is in Goal mode. Danger-tier commands still ask."
        case .workspaceAccess: return "Auto-approved by this session's Workspace Access approval mode. Danger-tier commands still ask."
        case .escalated: return "You approved this call to run outside the default sandbox boundary."
        case .trustedServer: return "You marked this MCP server as fully trusted — all its calls auto-run."
        }
    }

    private var cardBackground: Color {
        if isAuthorizationNotice {
            return appState.editorSettings.interfaceSkin.palette.panelFill
        }
        if isInteractive {
            return appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.72)
        }
        return appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.38)
    }

    private var approvalSurfaceBackground: Color {
        appState.editorSettings.interfaceSkin.palette.panelFill.opacity(0.58)
    }

    private var statusText: String {
        switch call.status {
        case .pendingApproval: return L10n.ToolCard.statusAwaitingApproval
        case .awaitingConfirm: return L10n.ToolCard.statusConfirmRequired
        case .awaitingUserAnswer: return L10n.ToolCard.statusAskingYou
        case .running: return L10n.ToolCard.statusRunning
        case .succeeded:
            switch terminalShortcutProtectedInputState {
            case .some(.pending):
                return L10n.ToolCard.terminalPasswordWaiting
            case .some(.filled(_)):
                return L10n.ToolCard.terminalPasswordEntered
            case .none:
                break
            }
            if let summary = call.result?.summary, !summary.isEmpty {
                return summary
            }
            return L10n.ToolCard.statusDone
        case .failed: return L10n.ToolCard.statusFailed
        case .denied: return L10n.ToolCard.statusDenied
        }
    }

    private var riskBadge: String {
        switch call.risk {
        case .read: return "READ"
        case .write: return "WRITE"
        case .danger: return "DANGER"
        case .userInput: return "ASK"
        }
    }

    private var borderColor: Color {
        if isAuthorizationNotice {
            return Color.clear
        }
        switch call.status {
        case .pendingApproval, .awaitingConfirm: return appState.editorSettings.interfaceSkin.palette.hairline
        case .awaitingUserAnswer: return askUserAccentColor.opacity(0.4)
        case .failed: return Color.orange.opacity(0.4)
        case .denied: return Color.secondary.opacity(0.3)
        default: return Color.clear
        }
    }

    private var askUserAccentColor: Color {
        appState.editorSettings.interfaceSkin.palette.accent
    }

    private var askUserSecondaryAccentColor: Color {
        appState.editorSettings.interfaceSkin.palette.secondaryAccent
    }

    private var terminalShortcutProtectedInputFilled: Bool {
        if case .some(.filled(_)) = terminalShortcutProtectedInputState {
            return true
        }
        return false
    }

    private var terminalShortcutProtectedInputState: TerminalShortcutProtectedInputState? {
        guard call.toolName == "terminal_create_shortcut",
              call.status == .succeeded,
              let payload = call.result?.payload,
              let parsed = TerminalShortcutProtectedPromptSet.parse(payload: payload),
              !parsed.prompts.isEmpty else {
            return nil
        }
        guard let current = appState.agentTerminalController.shortcuts.first(where: { $0.id == parsed.shortcutID }) else {
            return .pending(parsed)
        }
        let pendingIndexes = Set(
            current.events.enumerated()
                .filter { $0.element.needsProtectedInputValue }
                .map(\.offset)
        )
        let pendingPrompts = parsed.prompts.filter { pendingIndexes.contains($0.eventIndex) }
        guard !pendingPrompts.isEmpty else { return .filled(parsed) }
        return .pending(TerminalShortcutProtectedPromptSet(shortcutID: parsed.shortcutID, title: parsed.title, prompts: pendingPrompts))
    }
}

private enum TerminalShortcutProtectedInputState: Equatable {
    case pending(TerminalShortcutProtectedPromptSet)
    case filled(TerminalShortcutProtectedPromptSet)
}

struct TerminalShortcutProtectedPromptSet: Identifiable, Equatable {
    let shortcutID: UUID
    let title: String
    let prompts: [TerminalShortcutProtectedPrompt]

    var id: UUID { shortcutID }

    static func parse(payload: String) -> TerminalShortcutProtectedPromptSet? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawID = object["id"] as? String,
              let shortcutID = UUID(uuidString: rawID) else {
            return nil
        }
        let title = (object["title"] as? String) ?? L10n.AgentTerminal.shortcutDefaultTitle
        guard let events = object["events"] as? [[String: Any]] else {
            return nil
        }
        let prompts = events.compactMap { event -> TerminalShortcutProtectedPrompt? in
            guard (event["kind"] as? String) == "protected_placeholder",
                  (event["needs_value"] as? Bool) == true,
                  let eventIndex = event["index"] as? Int else {
                return nil
            }
            let rawLabel = (event["placeholder"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let label = rawLabel?.isEmpty == false
                ? rawLabel!
                : L10n.AgentTerminal.shortcutPasswordDefaultLabel("\(eventIndex + 1)")
            return TerminalShortcutProtectedPrompt(eventIndex: eventIndex, label: label)
        }
        guard !prompts.isEmpty else { return nil }
        return TerminalShortcutProtectedPromptSet(shortcutID: shortcutID, title: title, prompts: prompts)
    }
}

struct TerminalShortcutProtectedPrompt: Identifiable, Equatable {
    let eventIndex: Int
    let label: String

    var id: Int { eventIndex }
}

// MARK: - Tool result image thumbnails

/// Horizontal strip of thumbnails for images a tool produced (today only
/// `capture_screenshot`). Decodes a downsampled thumbnail via ImageIO rather
/// than a full-resolution `NSImage(data:)` so a burst of large captures can't
/// balloon memory — the codebase has been bitten by unbounded image/layout
/// memory before.
private struct AgentToolResultImageStrip: View {
    let images: [AgentImageAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(images) { image in
                    AgentToolResultThumbnail(image: image)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct AgentToolResultThumbnail: View {
    let image: AgentImageAttachment
    @State private var thumbnail: NSImage?
    private let maxHeight: CGFloat = 120
    private let thumbnailMaxPixel = 300

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .onTapGesture { openFullSize() }
                    .help("点击在预览中打开完整截图")
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 120, height: 80)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: image.id) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard thumbnail == nil else { return }
        let base64 = image.dataBase64
        let maxPixel = thumbnailMaxPixel
        // Downsample off the main actor and hand back a small NSSize +
        // PNG `Data` (both Sendable — NSImage is not, and returning it
        // would warn on pre-macOS 14 deployment targets). Build the
        // NSImage on the main actor from the downsampled bytes.
        let rendered = await Task.detached(priority: .userInitiated) { () -> (Data, Int, Int)? in
            guard let data = Data(base64Encoded: base64),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                out as CFMutableData,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else { return nil }
            CGImageDestinationAddImage(dest, cg, nil)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return (out as Data, cg.width, cg.height)
        }.value
        if let rendered, let nsImage = NSImage(data: rendered.0) {
            nsImage.size = NSSize(width: rendered.1, height: rendered.2)
            thumbnail = nsImage
        }
    }

    private func openFullSize() {
        guard let data = Data(base64Encoded: image.dataBase64) else { return }
        let ext = image.mimeType.lowercased().hasSuffix("png") ? "png" : "jpg"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-capture-\(image.id.uuidString).\(ext)")
        do {
            try data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            // Non-fatal: the thumbnail is still visible inline.
        }
    }
}
