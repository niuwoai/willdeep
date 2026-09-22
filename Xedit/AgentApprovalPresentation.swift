//
//  AgentApprovalPresentation.swift
//  WillDeep
//
//  Layout metrics, button styles and copy for the tool-approval surfaces.
//  Split out of AgentToolCallViews.swift, which had grown past the
//  repository's hard file-size limit.
//
//  The button styles are internal rather than private because
//  `AgentToolCallCard` applies them; they were file-private only because they
//  used to live in the same file.
//

import SwiftUI
import AppKit

nonisolated enum AgentApprovalActionMetrics {
    static let spacing: CGFloat = 12
    static let minimumButtonWidth: CGFloat = 112
    static let minimumButtonHeight: CGFloat = 36
    static let cornerRadius: CGFloat = 14
}

extension View {
    /// The custom-radius overload arrived in macOS 14. Keep the intended
    /// 9pt shape there, and use SwiftUI's system rounded rectangle on the
    /// app's macOS 13.7 deployment floor.
    ///
    /// Internal rather than file-private because the approval card in
    /// AgentToolCallViews.swift also applies it.
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
struct AgentApprovalOutlinedButtonStyle: ButtonStyle {
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

/// Neutral companion to the black/white primary action. Interactive Agent
/// surfaces intentionally avoid the macOS accent tint so the controls remain
/// calm and consistent across every interface skin.
struct AgentApprovalSecondaryButtonStyle: ButtonStyle {
    let colorScheme: ColorScheme
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let foreground: Color = colorScheme == .dark ? .white.opacity(0.88) : .black.opacity(0.78)
        let border: Color = colorScheme == .dark ? .white.opacity(0.26) : .black.opacity(0.22)
        return configuration.label
            .foregroundStyle(foreground)
            .background(shape.fill(Color.clear))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.62 : 1)
    }
}

/// Codex-style high-contrast approval action. Light appearances use a black
/// button with white text; dark appearances invert the pair so the primary
/// action remains clearly visible instead of disappearing into the card.
struct AgentApprovalPrimaryButtonStyle: ButtonStyle {
    let colorScheme: ColorScheme
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let background: Color = colorScheme == .dark ? .white : .black
        let foreground: Color = colorScheme == .dark ? .black : .white
        return configuration.label
            .foregroundStyle(foreground)
            .background(shape.fill(background))
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.72 : 1)
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
    /// Command reviews wrap at the available width and expose at most five
    /// readable lines before vertical scrolling takes over. Horizontal
    /// scrolling makes long shell pipelines needlessly hard to audit.
    static let commandViewportHeight: CGFloat = 112
    static let commandVisibleLineCount = 5
    static let commandScrollAxes: Axis.Set = .vertical
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

struct AgentAskUserPromptPresentation: Equatable {
    let title: String
    let body: String?
    let requestedInformation: [String]
    let defaultAssumptions: [String]

    var hasStructuredSections: Bool {
        !requestedInformation.isEmpty || !defaultAssumptions.isEmpty
    }
}

enum AgentAskUserPromptPresentationBuilder {
    static let longQuestionThreshold = 72

    static func make(
        arguments: [String: AgentJSONValue]
    ) -> AgentAskUserPromptPresentation? {
        guard let question = sanitizedLine(
            arguments["question"]?.stringValue(),
            maxLength: 2_000
        ) else {
            return nil
        }

        let explicitTitle = sanitizedLine(
            arguments["title"]?.stringValue(),
            maxLength: 120
        )
        let requestedInformation = sanitizedItems(
            arguments["requested_information"]?.stringArrayValue() ?? []
        )
        let defaultAssumptions = sanitizedItems(
            arguments["default_assumptions"]?.stringArrayValue() ?? []
        )
        let needsBody = explicitTitle != nil
            || !requestedInformation.isEmpty
            || !defaultAssumptions.isEmpty
            || question.count > longQuestionThreshold
            || question.contains("\n")

        return AgentAskUserPromptPresentation(
            title: explicitTitle ?? (needsBody ? L10n.ToolCard.askUserDefaultTitle : question),
            body: needsBody ? question : nil,
            requestedInformation: requestedInformation,
            defaultAssumptions: defaultAssumptions
        )
    }

    private static func sanitizedItems(_ values: [String]) -> [String] {
        values.compactMap { sanitizedLine($0, maxLength: 500) }
    }

    private static func sanitizedLine(_ value: String?, maxLength: Int) -> String? {
        guard let value else { return nil }
        return AgentInjectionDefense.sanitizeAskUserOption(value, maxLength: maxLength)
    }
}

nonisolated enum AgentCompactAuthorizationMetrics {
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 15
    static let contentSpacing: CGFloat = 15
    static let actionSpacing: CGFloat = 10
    static let minimumButtonWidth: CGFloat = 76
    static let primaryButtonMinimumWidth: CGFloat = 112
    static let minimumButtonHeight: CGFloat = 36
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
    /// Why this card has no always-allow button, for tools that are approved
    /// one call at a time.
    var note: String? = nil
}

nonisolated enum AgentCompactAuthorizationCopy {
    static func descriptor(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> AgentCompactAuthorizationDescriptor? {
        if toolName == "kill_job" {
            let jobHandle = arguments["job_id"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentCompactAuthorizationDescriptor(
                iconName: "stop.circle",
                title: L10n.ToolCard.backgroundTaskAuthorizationTitle,
                question: jobHandle.flatMap { $0.isEmpty ? nil : $0 }
                    .map(L10n.ToolCard.backgroundTaskAuthorizationQuestion)
                    ?? L10n.ToolCard.backgroundTaskAuthorizationGenericQuestion
            )
        }
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
                question: L10n.ToolCard.browserChromeAuthorizationQuestion,
                note: perCallNote(toolName)
            )
        }
        if toolName.hasPrefix("embedded_browser_") {
            return AgentCompactAuthorizationDescriptor(
                iconName: "globe",
                title: L10n.ToolCard.browserAuthorizationTitle,
                question: L10n.ToolCard.browserEmbeddedAuthorizationQuestion,
                note: perCallNote(toolName)
            )
        }
        return nil
    }

    private static func perCallNote(_ toolName: String) -> String? {
        AgentToolAuthorization.browserToolsRequiringPerCallApproval.contains(toolName)
            ? L10n.ToolCard.browserPerCallAuthorizationNote
            : nil
    }
}

nonisolated enum AgentApprovalPresentationPolicy {
    static func usesCompactAuthorization(
        toolName: String,
        arguments: [String: AgentJSONValue],
        risk: AgentToolRisk
    ) -> Bool {
        risk == .write
            && AgentCompactAuthorizationCopy.descriptor(
                toolName: toolName,
                arguments: arguments
            ) != nil
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

nonisolated struct AgentApprovalDetailDescriptor: Equatable {
    let title: String
    let body: String
}

/// Human-facing copy for the one built-in worker case that still needs a
/// confirmation. The user is authorizing an exact external write command,
/// not WillDeep's decision to create a worker, so internal routing arguments
/// must never be dumped into the card as if they were useful instructions.
nonisolated enum AgentDelegatedCommandApprovalCopy {
    static func notice(
        arguments: [String: AgentJSONValue]
    ) -> AgentApprovalNoticeDescriptor? {
        guard detail(arguments: arguments) != nil else { return nil }
        let goal = AgentSubagentTaskPacket.parse(arguments["task"])?.goal
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle: String
        if let goal, !goal.isEmpty {
            subtitle = L10n.ToolCard.delegatedCommandGoal(clampedGoal(goal))
        } else {
            subtitle = L10n.ToolCard.delegatedCommandSubtitle
        }
        return AgentApprovalNoticeDescriptor(
            iconName: "shippingbox.and.arrow.backward",
            title: L10n.ToolCard.delegatedCommandTitle,
            subtitle: subtitle,
            detailTitle: L10n.ToolCard.delegatedCommandDetail,
            metadata: [
                L10n.ToolCard.delegatedCommandWorker,
                L10n.ToolCard.delegatedCommandExactScope,
            ],
            explanationTitle: L10n.ToolCard.delegatedCommandExplanation,
            decisionTitle: L10n.ToolCard.delegatedCommandDecisionTitle,
            decisionSubtitle: L10n.ToolCard.delegatedCommandDecisionSubtitle,
            declineTitle: L10n.ToolCard.delegatedCommandDecline,
            approveTitle: L10n.ToolCard.delegatedCommandApprove,
            usesOutlinedApproveAction: false
        )
    }

    static func detail(
        arguments: [String: AgentJSONValue]
    ) -> AgentApprovalDetailDescriptor? {
        guard let command = arguments["target_command"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return nil
        }
        return AgentApprovalDetailDescriptor(
            title: L10n.ToolCard.delegatedCommandDetail,
            body: command
        )
    }

    private static func clampedGoal(_ goal: String) -> String {
        let oneLine = goal
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .joined(separator: " ")
        let limit = 180
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(limit - 1)) + "…"
    }
}

/// Tool-specific copy for the shared authorization notice. Keep this free of
/// SwiftUI types so its user-facing promises can be covered by unit tests.
nonisolated enum AgentApprovalNoticeCopy {
    /// `terminalHostLine` 是「这条命令会落在哪台机器上」的一句话，由调用方
    /// 从终端 tab 的实测状态取。它只影响终端那张卡的措辞：用户点确认前，
    /// 最该看到的就是目标主机——同一条 `kubectl set image` 打在本机和打在
    /// 生产 master 上，是两件完全不同的事。
    static func descriptor(
        toolName: String,
        arguments: [String: AgentJSONValue],
        terminalHostLine: String? = nil
    ) -> AgentApprovalNoticeDescriptor {
        switch toolName {
        case "spawn_agent":
            if let descriptor = AgentDelegatedCommandApprovalCopy.notice(arguments: arguments) {
                return descriptor
            }
            return defaultDescriptor(toolName: toolName)
        case "run_command":
            if arguments[AgentSandboxPolicy.sandboxEscalationRequestArgumentKey]?.boolValue() == true {
                var metadata = commandMetadata(arguments: arguments)
                metadata.append(L10n.ToolCard.sandboxEscalationMetadata)
                if let detail = arguments[AgentSandboxPolicy.sandboxDenialDetailArgumentKey]?.stringValue(),
                   !detail.isEmpty {
                    metadata.append(detail)
                }
                return AgentApprovalNoticeDescriptor(
                    iconName: "lock.shield",
                    title: L10n.ToolCard.sandboxEscalationTitle,
                    subtitle: L10n.ToolCard.sandboxEscalationSubtitle,
                    detailTitle: L10n.ToolCard.command,
                    metadata: metadata,
                    explanationTitle: L10n.ToolCard.sandboxEscalationExplanation,
                    decisionTitle: L10n.ToolCard.sandboxEscalationDecisionTitle,
                    decisionSubtitle: L10n.ToolCard.sandboxEscalationDecisionSubtitle,
                    declineTitle: L10n.ToolCard.sandboxEscalationDecline,
                    approveTitle: L10n.ToolCard.sandboxEscalationApprove,
                    usesOutlinedApproveAction: false
                )
            }
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
        case "declare_environment_trust":
            return environmentTrustDescriptor(arguments: arguments)
        case "terminal_send_command":
            return AgentApprovalNoticeDescriptor(
                iconName: "rectangle.rightthird.inset.filled",
                title: "Agent 准备发送命令到终端",
                subtitle: terminalSubtitle(hostLine: terminalHostLine),
                detailTitle: "即将发送",
                metadata: terminalMetadata(arguments: arguments, hostLine: terminalHostLine),
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
        case "create_user_skills":
            let drafts = (try? AgentSelfLearning.decodeSkillBatch(
                arguments["skills_json"]?.stringValue() ?? ""
            )) ?? []
            let count = drafts.count
            return AgentApprovalNoticeDescriptor(
                iconName: "wand.and.stars",
                title: "Agent 准备创建 \(count) 个技能",
                subtitle: "所有技能会先整体校验，再作为同一批次写入；任一项失败都会撤销本批已创建内容。",
                detailTitle: "技能清单",
                metadata: ["\(count) 个技能", "一次确认", "失败整批回滚"],
                explanationTitle: "查看批量创建说明",
                decisionTitle: "创建这批技能吗？",
                decisionSubtitle: "确认一次即可处理清单中的全部技能，结果会逐项显示。",
                declineTitle: "暂不创建",
                approveTitle: "创建全部",
                usesOutlinedApproveAction: false
            )
        default:
            return defaultDescriptor(toolName: toolName)
        }
    }

    private static func defaultDescriptor(toolName: String) -> AgentApprovalNoticeDescriptor {
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

    private static func commandMetadata(
        arguments: [String: AgentJSONValue]
    ) -> [String] {
        let workspaceName = arguments["cwd"]?.stringValue()
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
        var metadata = [
            workspaceName.map { "在 \($0) 工作区运行" } ?? "在当前工作区运行",
            commandImpact(arguments: arguments),
        ]
        // 二十多行的 shell 摆在卡上等于没摆。结构摘要排在最前：要判断放不放
        // 行，先看的是「它要动几处、哪几处会改东西」，不是逐字读完脚本。
        // 拆不出结构就没有这一条，绝不编一个听起来很确定的概括。
        if let command = arguments["command"]?.stringValue(),
           let summary = AgentCommandCardSummary.summary(for: command) {
            metadata.insert(summary, at: 0)
        }
        return metadata
    }

    private static func commandImpact(arguments: [String: AgentJSONValue]) -> String {
        guard let command = arguments["command"]?.stringValue() else {
            return String(localized: "请确认命令的操作范围", table: "WorkerArchitecture")
        }
        let root = arguments["cwd"]?.stringValue().map { URL(fileURLWithPath: $0) }
        let decision = AgentSandboxPolicy.commandDecision(command: command, rootDirectory: root)
        if decision.credentialSensitive {
            return String(localized: "可能读取凭据或敏感文件", table: "WorkerArchitecture")
        }
        if decision.mode == .readOnly || decision.mode == .readOnlyNetwork {
            return String(localized: "只读检查，不修改工作区文件", table: "WorkerArchitecture")
        }
        return String(localized: "请确认命令的操作范围", table: "WorkerArchitecture")
    }

    /// 环境信任声明的确认卡。这张卡是整个特性的防注入闸门：把 Agent 声称的
    /// “用户原话”原样摆在最显眼处，用户一眼就能认出自己是否真的说过。注入
    /// 文本骗 Agent 调这个工具时，用户看到的是一句自己从没说过的话。
    private static func environmentTrustDescriptor(
        arguments: [String: AgentJSONValue]
    ) -> AgentApprovalNoticeDescriptor {
        let kindRaw = (arguments["kind"]?.stringValue() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if kindRaw == "revoke_all" {
            return AgentApprovalNoticeDescriptor(
                iconName: "lock.rotation",
                title: "Agent 准备撤销环境信任声明",
                subtitle: "撤销后，相关操作恢复为默认审批策略。",
                detailTitle: "将要撤销",
                metadata: ["仅影响当前会话"],
                explanationTitle: nil,
                decisionTitle: "撤销这些声明吗？",
                decisionSubtitle: "之后同类操作会重新向你确认。",
                declineTitle: "保持不变",
                approveTitle: "撤销",
                usesOutlinedApproveAction: true
            )
        }
        let kind = AgentEnvironmentTrustKind(rawValue: kindRaw)
        let target = (arguments["target"]?.stringValue() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var metadata = ["仅本次会话有效", "读取密钥仍需确认"]
        switch kind {
        case .disposableTerminal:
            metadata.insert("放宽范围：侧边栏终端", at: 0)
        case .testDatabase:
            metadata.insert(
                target.isEmpty ? "放宽范围：测试数据库" : "放宽范围：含 \(target) 的命令",
                at: 0
            )
        case .deploymentWindow:
            metadata.insert(
                target.isEmpty
                    ? "放宽范围：部署命令族"
                    : "放宽范围：含 \(target) 的部署命令",
                at: 0
            )
            // 这一档与另外两档有本质区别，必须写在卡上：它是直接执行，不是
            // 交给 AI 再看一眼。用户批准的是「这段时间别再问我」。
            metadata.insert("kubectl / helm / docker / systemctl", at: 1)
        case nil:
            break
        }
        // 部署窗口直接放行，另外两类只是降级送 AI 复核。这句话是用户判断
        // 「我到底批了什么」的依据，不能两档共用一句含糊的话。
        let decisionSubtitle = kind == .deploymentWindow
            ? "确认后，本会话内的部署命令直接执行，不再逐条询问；族外命令照旧。"
            : "确认后，该环境内的常规操作改由 AI 复核，不再逐条询问。"
        return AgentApprovalNoticeDescriptor(
            iconName: "checkmark.shield",
            title: "Agent 认为你声明了这个环境可以放宽审批",
            subtitle: "确认前请核对下面这句话确实是你说过的。",
            detailTitle: "Agent 引用的你的原话",
            metadata: metadata,
            explanationTitle: nil,
            decisionTitle: "你说过这句话吗？",
            decisionSubtitle: decisionSubtitle,
            declineTitle: "我没说过",
            approveTitle: "确认，是我说的",
            usesOutlinedApproveAction: true
        )
    }

    private static func terminalSubtitle(hostLine: String?) -> String {
        guard let hostLine, !hostLine.isEmpty else {
            return "命令会出现在侧边栏终端中，并在确认后执行。"
        }
        return "命令会在 \(hostLine) 上执行，过程显示在侧边栏终端里。"
    }

    private static func terminalMetadata(
        arguments: [String: AgentJSONValue],
        hostLine: String? = nil
    ) -> [String] {
        let target = arguments.keys.contains("terminal_tab_id")
            ? "指定终端标签"
            : "当前会话终端"
        var metadata = ["侧边栏可见", target]
        // 目标主机排在中断提示前面：它是这张卡上最该先看到的一条。
        if let hostLine, !hostLine.isEmpty {
            metadata.append(hostLine.contains("REMOTE") ? "⚠︎ 远端主机" : "本机")
        }
        metadata.append("可随时按 Ctrl-C 中断")
        return metadata
    }

    private static func webMetadata(
        arguments: [String: AgentJSONValue]
    ) -> [String] {
        let maxCharacters = arguments["max_chars"]?.intValue() ?? 20_000
        let formattedCount = maxCharacters.formatted(.number.grouping(.automatic))
        return ["仅发送 GET 请求", "公开网页", "最多读取 \(formattedCount) 字符"]
    }
}
