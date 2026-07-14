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
        "terminal_create_shortcut": "生成终端录制",
        "terminal_list_shortcuts": "终端录制列表",
        "terminal_edit_shortcut": "编辑终端录制",
        "terminal_send_command": "终端执行命令",
        "terminal_send_control": "终端控制键",
        "create_file": "创建文件",
        "edit_file": "编辑文件",
        "apply_patch": "应用补丁",
        "list_jobs": "查看后台任务",
        "get_job_output": "读取任务输出",
        "kill_job": "终止后台任务",
        "list_skills": "查看技能",
        "read_skill": "读取技能",
        "activate_expert": "激活专家",
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
        "visual_qa_screenshot": "截图视觉检查",
        "capture_screenshot": "截屏",
        "computer_use_permissions": "电脑操作权限",
        "computer_use_request_permissions": "请求电脑操作权限",
        "computer_use_list_apps": "列出 Mac 应用",
        "computer_use_launch_app": "后台启动 Mac 应用",
        "computer_use_get_app_state": "读取应用界面",
        "computer_use_click": "点击应用控件",
        "computer_use_secondary_action": "打开应用菜单",
        "computer_use_scroll": "滚动应用界面",
        "computer_use_drag": "拖拽应用界面",
        "computer_use_type_text": "输入应用文本",
        "computer_use_press_key": "发送应用按键",
        "computer_use_set_value": "设置应用控件值",
        "computer_use_restart_helper": "重启电脑操作 Helper",
        "chrome_status": "Chrome 状态",
        "chrome_read_page": "读取网页",
        "chrome_read_selection": "读取网页选区",
        "chrome_click": "点击页面元素",
        "chrome_type": "输入网页文本",
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

struct AgentToolCallGroup: View {
    @EnvironmentObject var appState: AppState
    let calls: [AgentToolCall]
    /// Optional codex-style headline ("已运行 3 条命令"). When set, it
    /// replaces the default "N tools" label and we also swap the icon
    /// to match the kind.
    var headline: String? = nil
    var headlineIcon: String? = nil
    @State private var isExpanded = false

    var body: some View {
        let status = statusSummary
        VStack(alignment: .leading, spacing: detailsVisible ? 8 : 0) {
            Button {
                if canToggleDetails {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: groupIconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(groupIconColor)
                        .frame(width: 14)
                    Text(titleText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !status.isEmpty {
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if let previewSummary {
                        Text(previewSummary)
                            .font(.caption2)
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
        // The expanded card paints padding above its title row. Give that
        // expanded chrome its own external breathing room so it never
        // visually climbs into the previous assistant bubble.
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

    private var titleText: String {
        if let headline, !headline.isEmpty { return headline }
        if let activityText = AgentToolActivitySummary(calls: calls).activityText {
            return activityText
        }
        if calls.count == 1, let first = calls.first {
            return "已调用 \(AgentToolDisplay.name(for: first.toolName))"
        }
        return "已调用 \(calls.count) 个工具"
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
        if succeeded == calls.count, waiting == 0, running == 0, failed == 0, denied == 0 {
            return ""
        }
        if waiting > 0 { parts.append("\(waiting) 待处理") }
        if running > 0 { parts.append("\(running) 运行中") }
        if failed > 0 { parts.append("\(failed) 失败") }
        if denied > 0 { parts.append("\(denied) 已拒绝") }
        if succeeded > 0 { parts.append("\(succeeded) 完成") }
        return parts.joined(separator: " · ")
    }

    private var previewSummary: String? {
        guard detailsVisible else { return nil }
        let previews = calls.prefix(3).map { call in
            var text = AgentToolDisplay.name(for: call.toolName)
            if let summary = call.result?.summary, !summary.isEmpty {
                text += " \(summary)"
            } else if let compactArguments = compactArguments(for: call), !compactArguments.isEmpty {
                text += " \(compactArguments)"
            }
            return text
        }
        let suffix = calls.count > previews.count ? " · +\(calls.count - previews.count) more" : ""
        let summary = previews.joined(separator: " · ") + suffix
        return summary.isEmpty ? nil : summary
    }

    private func compactArguments(for call: AgentToolCall) -> String? {
        if call.toolName == "run_command", let command = call.arguments["command"]?.stringValue() {
            let cwd = call.arguments["cwd"]?.stringValue().map { "  cwd: \(trimmed($0, limit: 72))" } ?? ""
            return "command: \(trimmed(command, limit: 140))\(cwd)"
        }
        if call.toolName == "terminal_send_command", let command = call.arguments["command"]?.stringValue() {
            var summary = "命令: \(trimmed(command, limit: 140))"
            if let paths = call.arguments["zmodem_upload_paths"]?.stringArrayValue(), !paths.isEmpty {
                summary += " · zmodem_upload_paths: \(paths.count)"
            } else if let directory = call.arguments["zmodem_download_directory"]?.stringValue(), !directory.isEmpty {
                summary += " · zmodem_download_directory: \(trimmed(directory, limit: 72))"
            }
            return summary
        }
        if call.toolName == "terminal_send_control", let raw = call.arguments["control"]?.stringValue() {
            return "按键: \(AgentToolDisplay.controlLabel(for: raw))"
        }
        if call.toolName == "spawn_agent" {
            let label = call.arguments["label"]?.stringValue()
                ?? call.arguments["prompt"]?.stringValue()
                ?? ""
            let modelSuffix = (call.subagentModel?.isEmpty == false) ? " · \(call.subagentModel!)" : ""
            return label.isEmpty ? nil : "task: \(trimmed(label, limit: 120))\(modelSuffix)"
        }
        if ["claude_code", "codex_cli", "cursor_agent"].contains(call.toolName) {
            let prompt = call.arguments["prompt"]?.stringValue() ?? ""
            let mode = call.arguments["permission_mode"]?.stringValue().map { "  mode: \($0)" } ?? ""
            return prompt.isEmpty ? nil : "task: \(trimmed(prompt, limit: 120))\(mode)"
        }
        if let path = call.arguments["path"]?.stringValue() {
            return "path: \(trimmed(path, limit: 120))"
        }
        if let pattern = call.arguments["pattern"]?.stringValue() {
            return "pattern: \(trimmed(pattern, limit: 120))"
        }
        if let query = call.arguments["query"]?.stringValue() {
            return "query: \(trimmed(query, limit: 120))"
        }
        return nil
    }

    private func trimmed(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<end]) + "…"
    }

    private var groupIconName: String {
        // Status-derived icons (failed / running / asking) take precedence
        // so the user can see a problem at a glance, even when the row is
        // collapsed. A static headline icon is only the calm-state default.
        if calls.contains(where: { $0.status == .failed }) { return "exclamationmark.triangle.fill" }
        if calls.contains(where: { $0.status == .running }) { return "hourglass" }
        if containsInteractiveCall { return "questionmark.circle" }
        if let headlineIcon, !headlineIcon.isEmpty { return headlineIcon }
        return "checkmark.circle.fill"
    }

    private var groupIconColor: Color {
        if calls.contains(where: { $0.status == .failed }) { return .orange }
        if calls.contains(where: { $0.status == .running }) { return .secondary }
        if containsInteractiveCall { return appState.editorSettings.interfaceSkin.palette.accent }
        return .secondary
    }

    private var groupBorderColor: Color {
        if containsInteractiveCall { return appState.editorSettings.interfaceSkin.palette.accent.opacity(0.28) }
        if calls.contains(where: { $0.status == .failed }) { return Color.orange.opacity(0.28) }
        return Color.primary.opacity(0.04)
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

    var body: some View {
        VStack(alignment: .leading, spacing: isInteractive ? 6 : 3) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 14)
                Text(AgentToolDisplay.name(for: call.toolName))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(call.toolName)
                Text(argumentsSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(isInteractive ? 2 : 1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let label = approvalSourceLabel {
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
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

            if let badge = subagentBadgeText {
                HStack(spacing: 5) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.purple)
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
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

            if call.status == .pendingApproval {
                VStack(alignment: .leading, spacing: 9) {
                    approvalReviewHeader(
                        title: "等待你审核",
                        subtitle: "这一步需要你的允许后才会继续执行。",
                        tint: appState.editorSettings.interfaceSkin.palette.accent,
                        systemImage: "shield.lefthalf.filled"
                    )
                    approvalCommandBlock
                    approvalExplanationSection
                    if decisionAlreadySubmitted {
                        submittedDecisionNotice
                    } else {
                        // rc16:把 Deny 推到最左,Allow / Always Allow 在右侧簇集,
                        // 对齐 macOS「主操作右、负操作远离」防误触习惯。
                        HStack {
                            // 拒绝:空心(描边)按钮;允许:实心(高亮)主操作。
                            Button(L10n.ToolCard.deny) { appState.denyAgentToolCall(id: call.id) }
                                .buttonStyle(.bordered)
                            Spacer(minLength: 0)
                            if let signature = alwaysAllowSignature {
                                Button(L10n.ToolCard.alwaysAllow) { appState.alwaysAllowAgentToolCall(id: call.id) }
                                    .buttonStyle(.bordered)
                                    .help(L10n.ToolCard.alwaysAllowHelp(signature))
                            }
                            Button(L10n.ToolCard.allow) { appState.approveAgentToolCall(id: call.id) }
                                .buttonStyle(.borderedProminent)
                        }
                        .font(.caption)
                        .controlSize(.small)
                    }
                }
            } else if call.status == .awaitingConfirm {
                VStack(alignment: .leading, spacing: 9) {
                    approvalReviewHeader(
                        title: "高风险确认",
                        subtitle: L10n.ToolCard.destructiveWarning,
                        tint: destructiveAccentColor,
                        systemImage: "exclamationmark.shield.fill"
                    )
                    approvalCommandBlock
                    approvalExplanationSection
                    if decisionAlreadySubmitted {
                        submittedDecisionNotice
                    } else {
                        // rc16:同上,Deny 在左,Confirm Run 在右。
                        // 破坏性命令误点代价高,把两个按钮的点击区放大:字号 caption→subheadline,
                        // 内边距加大,并给 Deny 也补上等大的描边点击区(原来是裸文字,极难点中)。
                        HStack(spacing: 8) {
                            Button {
                                appState.denyAgentToolCall(id: call.id)
                            } label: {
                                Text(L10n.ToolCard.deny)
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .foregroundStyle(.secondary)
                                    .background(Color.clear)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .stroke(Color.secondary.opacity(0.45), lineWidth: 1)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            Spacer(minLength: 0)
                            Button {
                                _ = appState.confirmAgentToolCall(id: call.id, typedConfirmation: "confirm")
                            } label: {
                                Text(L10n.ToolCard.confirmRun)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .foregroundStyle(destructiveAccentColor)
                                    .background(Color.clear)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .stroke(destructiveAccentColor.opacity(0.62), lineWidth: 1)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if call.status == .awaitingUserAnswer {
                askUserBody
            } else if call.toolName == "ask_user" {
                askUserResolvedRow
            } else if call.toolName == "terminal_create_shortcut" {
                terminalShortcutProtectedInputsBody
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, isInteractive ? 7 : 4)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: 1)
        )
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
                    Text("最多显示 3 行，超出可滚动")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
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
                    approvalExplanationError = "解释失败：\(error.localizedDescription)"
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
                    Spacer(minLength: 0)
                    Button(L10n.ToolCard.askUserSend) {
                        submitAnswer(options: options, isMultiSelect: isMultiSelect)
                    }
                    .disabled(!canSubmitAskUser(isMultiSelect: isMultiSelect))
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
    /// 完整命令(默认约 3 行高,超出滚动查看);控制键工具显示展开后的
    /// 友好按键说明,而不是裸的 `ctrl_c`。
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
        return nil
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
        case .awaitingConfirm: return destructiveAccentColor
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
        case .awaitingConfirm: return destructiveAccentColor
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
        switch call.status {
        case .pendingApproval: return appState.editorSettings.interfaceSkin.palette.accent.opacity(0.4)
        case .awaitingConfirm: return destructiveAccentColor.opacity(0.42)
        case .awaitingUserAnswer: return askUserAccentColor.opacity(0.4)
        case .failed: return Color.orange.opacity(0.4)
        case .denied: return Color.secondary.opacity(0.3)
        default: return Color.clear
        }
    }

    private var destructiveAccentColor: Color {
        Color(red: 0.68, green: 0.16, blue: 0.16)
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
