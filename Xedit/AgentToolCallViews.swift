//
//  AgentToolCallViews.swift
//  WillDeep
//
//  The tool call card: the agent transcript's per-call surface, including
//  every approval and confirmation variant.
//
//  This file used to hold the whole tool-call view layer and crossed the
//  repository's 3000-line hard limit, which blocked `scripts/run_tests.sh`
//  at its first gate. Split into AgentToolDisplayNames, AgentApprovalPresentation,
//  AgentActivityTimelineViews, AgentToolCallGroupView, AgentTerminalShortcutPrompts
//  and AgentToolResultImageViews; what remains here is the card itself.
//

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct AgentToolCallCard: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
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
            if !isAttentionNotice {
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

            if subagentBadgeText != nil
                || call.subagentRunID != nil
                || call.subagentWorkerName != nil {
                HStack(spacing: 5) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    if let badge = subagentBadgeText {
                        Text(badge)
                            .font(AgentDesign.chatSupportingFont(
                                baseFontSize: appState.agentChatBaseFontSize,
                                visualMinimum: 10,
                                weight: .medium
                            ))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if let workerName = call.subagentWorkerName {
                        Text(workerName)
                            .font(AgentDesign.chatSupportingFont(
                                baseFontSize: appState.agentChatBaseFontSize,
                                visualMinimum: 10,
                                weight: .medium
                            ))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    // Entry point into the per-round record. Present as soon
                    // as the run has an id: a cancelled or failed child still
                    // has a prompt and partial rounds worth reading.
                    if let runID = call.subagentRunID {
                        Button {
                            AgentSubagentInspectorWindowRegistry.shared.open(
                                runID: runID,
                                fallbackLabel: call.subagentModel
                            )
                        } label: {
                            Label(
                                L10n.AgentDelegation.inspectorTitle,
                                systemImage: "list.bullet.rectangle"
                            )
                            .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.AgentDelegation.inspectorTitle)
                    }
                }
            }

            // The Worker's own words, in the card that spawned it. Kept on
            // screen after the run finishes: the narration is how you tell a
            // Worker that reasoned its way to the answer from one that
            // guessed, and the final report alone does not show that.
            if let activity = call.subagentLiveActivity,
               call.subagentIsWorking
                    || !activity.utterances.isEmpty
                    || !activity.interventionReceipts.isEmpty {
                AgentSubagentSpeechView(
                    activity: activity,
                    runID: call.subagentRunID,
                    isRunning: call.subagentIsWorking,
                    taskTitle: AgentToolDisplay.objectSummary(
                        toolName: call.toolName,
                        arguments: call.arguments
                    )
                )
            }

            if let progress = call.delegatedProgress {
                AgentDelegatedLiveProgressView(progress: progress)
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
                if let recentOutput = call.delegatedProgress?.recentOutput,
                   !recentOutput.isEmpty {
                    expandableBlock(
                        title: L10n.DelegatedTask.recentOutput,
                        text: recentOutput
                    )
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
        .padding(.horizontal, isAttentionNotice ? 0 : 7)
        .padding(.vertical, isAttentionNotice ? 0 : (isInteractive ? 7 : 4))
        .background(cardBackground)
        .clipShape(
            RoundedRectangle(
                cornerRadius: isAttentionNotice
                    ? authorizationCornerRadius
                    : 6,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: isAttentionNotice
                    ? authorizationCornerRadius
                    : 6,
                style: .continuous
            )
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var approvalDescriptor: AgentApprovalNoticeDescriptor {
        AgentApprovalNoticeCopy.descriptor(
            toolName: call.toolName,
            arguments: call.arguments,
            terminalHostLine: approvalTerminalHostLine
        )
    }

    /// 这条命令要落在哪台机器上。只对终端那条路有意义，其余工具传 nil。
    private var approvalTerminalHostLine: String? {
        guard call.toolName == "terminal_send_command" || call.toolName == "terminal_send_control" else {
            return nil
        }
        let controller = appState.agentTerminalController
        let requested = call.arguments["terminal_tab_id"]?.stringValue()
            .flatMap(UUID.init(uuidString:))
        let tab = requested.flatMap { id in controller.tabs.first { $0.id == id } } ?? controller.activeTab
        return tab?.hostLine
    }

    private var compactAuthorizationDescriptor: AgentCompactAuthorizationDescriptor? {
        AgentCompactAuthorizationCopy.descriptor(
            toolName: call.toolName,
            arguments: call.arguments
        )
    }

    private var compactSurfaceAuthorizationNoticeBody: some View {
        let descriptor = compactAuthorizationDescriptor
        return VStack(alignment: .leading, spacing: AgentCompactAuthorizationMetrics.contentSpacing) {
            if let descriptor {
                HStack(spacing: 8) {
                    Image(systemName: descriptor.iconName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(appState.editorSettings.interfaceSkin.palette.secondaryText)
                        .frame(width: 18, height: 18)
                    Text(descriptor.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(appState.editorSettings.interfaceSkin.palette.secondaryText)
                }

                Text(descriptor.question)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(appState.editorSettings.interfaceSkin.palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let note = descriptor.note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(appState.editorSettings.interfaceSkin.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            compactAuthorizationActions
        }
        .padding(.horizontal, AgentCompactAuthorizationMetrics.horizontalPadding)
        .padding(.vertical, AgentCompactAuthorizationMetrics.verticalPadding)
    }

    @ViewBuilder
    private var compactAuthorizationActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AgentCompactAuthorizationMetrics.actionSpacing) {
                compactDenyButton
                Spacer(minLength: 16)
                if appState.canOfferGoalTaskAuthorization(id: call.id) { goalAuthorizationButton }
                if alwaysAllowSignature != nil {
                    compactAlwaysAllowButton
                } else if conversationAllowSignature == nil {
                    compactAllowOnceButton
                }
                if conversationAllowSignature != nil {
                    compactConversationAllowButton
                }
            }
            VStack(alignment: .leading, spacing: AgentCompactAuthorizationMetrics.actionSpacing) {
                HStack(spacing: AgentCompactAuthorizationMetrics.actionSpacing) {
                    compactDenyButton
                    Spacer(minLength: 0)
                    if appState.canOfferGoalTaskAuthorization(id: call.id) { goalAuthorizationButton }
                    if alwaysAllowSignature != nil {
                        compactAlwaysAllowButton
                    } else if conversationAllowSignature == nil {
                        compactAllowOnceButton
                    }
                    if conversationAllowSignature != nil {
                        compactConversationAllowButton
                    }
                }
            }
        }
        .controlSize(.regular)
    }

    private var compactAlwaysAllowButton: some View {
        Button {
            appState.alwaysAllowAgentToolCall(id: call.id)
        } label: {
            compactAuthorizationActionLabel(
                alwaysAllowSignature.flatMap(AgentCompactAuthorizationCopy.alwaysAllowLabel(signature:))
                    ?? L10n.ToolCard.alwaysAllow
            )
        }
        .buttonStyle(
            AgentApprovalPrimaryButtonStyle(
                colorScheme: colorScheme,
                cornerRadius: AgentCompactAuthorizationMetrics.buttonCornerRadius
            )
        )
        .cursor(.arrow)
    }

    private var goalAuthorizationButton: some View {
        Button(L10n.GoalAuthorization.allow) {
            Task { await appState.allowAgentVerifierForGoal(id: call.id) }
        }
        .help(L10n.GoalAuthorization.scope)
        .cursor(.arrow)
    }

    private var compactAllowOnceButton: some View {
        Button {
            appState.approveAgentToolCall(id: call.id)
        } label: {
            compactAuthorizationActionLabel(L10n.ToolCard.allow)
        }
        .buttonStyle(
            AgentApprovalPrimaryButtonStyle(
                colorScheme: colorScheme,
                cornerRadius: AgentCompactAuthorizationMetrics.buttonCornerRadius
            )
        )
        .cursor(.arrow)
    }

    private var compactDenyButton: some View {
        Button {
            appState.denyAgentToolCall(id: call.id)
        } label: {
            compactAuthorizationActionLabel(L10n.ToolCard.deny)
        }
        .buttonStyle(
            AgentApprovalSecondaryButtonStyle(
                colorScheme: colorScheme,
                cornerRadius: AgentCompactAuthorizationMetrics.buttonCornerRadius
            )
        )
        .cursor(.arrow)
    }

    private var compactConversationAllowButton: some View {
        Button {
            appState.allowAgentToolFamilyForConversation(id: call.id)
        } label: {
            compactAuthorizationActionLabel(
                call.toolName.hasPrefix("computer_use_")
                    ? L10n.ToolCard.allowComputerUseSession
                    : L10n.ToolCard.allowConversation,
                minimumWidth: AgentCompactAuthorizationMetrics.primaryButtonMinimumWidth
            )
        }
        .buttonStyle(
            AgentApprovalPrimaryButtonStyle(
                colorScheme: colorScheme,
                cornerRadius: AgentCompactAuthorizationMetrics.buttonCornerRadius
            )
        )
        .cursor(.arrow)
    }

    private func compactAuthorizationActionLabel(
        _ title: String,
        minimumWidth: CGFloat = AgentCompactAuthorizationMetrics.minimumButtonWidth
    ) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(
                minWidth: minimumWidth,
                minHeight: AgentCompactAuthorizationMetrics.minimumButtonHeight
            )
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
                .fill(palette.primaryText.opacity(colorScheme == .dark ? 0.12 : 0.06))
                Image(systemName: descriptor.iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
            }
            .frame(
                width: AgentConfirmationReviewMetrics.iconTileSize,
                height: AgentConfirmationReviewMetrics.iconTileSize
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("需要你的确认")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
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

                ScrollView(
                    AgentConfirmationReviewMetrics.commandScrollAxes,
                    showsIndicators: true
                ) {
                    Text(detail.body)
                        .font(.system(size: 12, design: .monospaced))
                        .lineSpacing(3)
                        .foregroundStyle(palette.primaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
        .background(palette.primaryText.opacity(colorScheme == .dark ? 0.09 : 0.05))
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
            .foregroundStyle(palette.primaryText)
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
        let palette = appState.editorSettings.interfaceSkin.palette
        VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: AgentConfirmationReviewMetrics.actionButtonSpacing) {
                    Button {
                        appState.denyAgentToolCall(id: call.id)
                    } label: {
                        approvalActionLabel(descriptor.declineTitle, systemImage: "xmark")
                    }
                    .buttonStyle(
                        AgentApprovalSecondaryButtonStyle(
                            colorScheme: colorScheme,
                            cornerRadius: AgentApprovalActionMetrics.cornerRadius
                        )
                    )
                    .cursor(.arrow)
                    .frame(maxWidth: AgentConfirmationReviewMetrics.actionButtonMaxWidth)

                    authorizationApproveButton(descriptor)
                }
                .controlSize(.regular)

                if appState.canOfferGoalTaskAuthorization(id: call.id) {
                    goalAuthorizationButton
                }
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

    @ViewBuilder
    private func authorizationApproveButton(
        _ descriptor: AgentApprovalNoticeDescriptor
    ) -> some View {
        Button {
            approveAuthorizationNotice()
        } label: {
            approvalActionLabel(descriptor.approveTitle, systemImage: "arrow.right")
        }
        .buttonStyle(
            AgentApprovalPrimaryButtonStyle(
                colorScheme: colorScheme,
                cornerRadius: AgentApprovalActionMetrics.cornerRadius
            )
        )
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

                ScrollView(
                    AgentConfirmationReviewMetrics.commandScrollAxes,
                    showsIndicators: true
                ) {
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

    @ViewBuilder
    private var askUserBody: some View {
        let prompt = AgentAskUserPromptPresentationBuilder.make(arguments: call.arguments)
        // rc3: option labels are LLM-authored. Defang first so the button
        // the user clicks shows the same string the model gets back as the
        // user's answer — and so options can't smuggle control characters
        // or `<system>` framing through the chat UI.
        let rawOptions = call.arguments["options"]?.stringArrayValue() ?? []
        let options = AgentInjectionDefense.sanitizeAskUserOptions(rawOptions)
        let isMultiSelect = call.arguments["multi_select"]?.boolValue() ?? false

        let palette = appState.editorSettings.interfaceSkin.palette
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: AgentConfirmationReviewMetrics.sectionSpacing) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(
                            cornerRadius: AgentConfirmationReviewMetrics.innerCornerRadius,
                            style: .continuous
                        )
                        .fill(palette.primaryText.opacity(colorScheme == .dark ? 0.12 : 0.06))
                        Image(systemName: "bubble.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                    }
                    .frame(
                        width: AgentConfirmationReviewMetrics.iconTileSize,
                        height: AgentConfirmationReviewMetrics.iconTileSize
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.ToolCard.askUserEyebrow)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.secondaryText)
                        if let prompt {
                            Text(prompt.title)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(palette.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            if let body = prompt.body {
                                Text(
                                    MarkdownInline.attributedString(
                                        from: body,
                                        inlineCodeFontSize: 13
                                    )
                                )
                                    .font(.system(size: 13))
                                    .foregroundStyle(palette.primaryText.opacity(0.82))
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !prompt.requestedInformation.isEmpty {
                                askUserPromptSection(
                                    title: L10n.ToolCard.askUserRequestedInformation,
                                    items: prompt.requestedInformation,
                                    palette: palette
                                )
                            }
                            if !prompt.defaultAssumptions.isEmpty {
                                askUserPromptSection(
                                    title: L10n.ToolCard.askUserDefaultAssumptions,
                                    items: prompt.defaultAssumptions,
                                    palette: palette
                                )
                            }
                        }
                        Text(
                            isMultiSelect
                                ? L10n.ToolCard.askUserMultipleHint
                                : L10n.ToolCard.askUserSingleHint
                        )
                            .font(.system(size: 13))
                            .foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                if !options.isEmpty {
                    if isMultiSelect {
                        multiSelectChoices(options)
                    } else {
                        singleSelectChoices(options)
                    }
                }

                TextField(
                    options.isEmpty
                        ? L10n.ToolCard.askUserAnswerPlaceholder
                        : L10n.ToolCard.askUserOtherAnswerPlaceholder,
                    text: $answerInput,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
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
            .padding(AgentConfirmationReviewMetrics.contentPadding)

            Rectangle()
                .fill(palette.hairline)
                .frame(height: AgentConfirmationReviewMetrics.dividerThickness)

            HStack(spacing: AgentConfirmationReviewMetrics.actionButtonSpacing) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.ToolCard.askUserFooterTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                    Text(L10n.ToolCard.askUserFooterHint)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryText)
                }
                Spacer(minLength: 16)
                Button {
                    appState.denyAgentToolCall(id: call.id)
                    resetAskUserInputs()
                } label: {
                    approvalActionLabel(L10n.ToolCard.askUserSkip, systemImage: "xmark")
                }
                .buttonStyle(
                    AgentApprovalSecondaryButtonStyle(
                        colorScheme: colorScheme,
                        cornerRadius: AgentApprovalActionMetrics.cornerRadius
                    )
                )
                .frame(maxWidth: AgentConfirmationReviewMetrics.actionButtonMaxWidth)
                .cursor(.arrow)

                Button {
                    submitAnswer(options: options, isMultiSelect: isMultiSelect)
                } label: {
                    approvalActionLabel(L10n.ToolCard.askUserSend, systemImage: "arrow.right")
                }
                .buttonStyle(
                    AgentApprovalPrimaryButtonStyle(
                        colorScheme: colorScheme,
                        cornerRadius: AgentApprovalActionMetrics.cornerRadius
                    )
                )
                .disabled(!canSubmitAskUser(isMultiSelect: isMultiSelect))
                .frame(maxWidth: AgentConfirmationReviewMetrics.actionButtonMaxWidth)
                .cursor(.arrow)
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(AgentConfirmationReviewMetrics.contentPadding)
        }
    }

    @ViewBuilder
    private func askUserPromptSection(
        title: String,
        items: [String],
        palette: EditorInterfaceSkinPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.primaryText)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(
                    MarkdownInline.attributedString(
                        from: item,
                        inlineCodeFontSize: 13
                    )
                )
                    .font(.system(size: 13))
                    .foregroundStyle(palette.primaryText.opacity(0.78))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
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
        let palette = appState.editorSettings.interfaceSkin.palette
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button {
                    selectedOptions = [option]
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selectedOptions.contains(option) ? "circle.inset.filled" : "circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selectedOptions.contains(option) ? palette.primaryText : palette.secondaryText)
                        Text(option)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(palette.primaryText)
                    .background(
                        selectedOptions.contains(option)
                            ? palette.primaryText.opacity(colorScheme == .dark ? 0.12 : 0.07)
                            : palette.controlFill.opacity(0.58)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(palette.hairline, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .cursor(.arrow)
            }
        }
    }

    private func multiSelectChoices(_ options: [String]) -> some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button {
                    if selectedOptions.contains(option) {
                        selectedOptions.remove(option)
                    } else {
                        selectedOptions.insert(option)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selectedOptions.contains(option) ? "checkmark.square.fill" : "square")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selectedOptions.contains(option) ? palette.primaryText : palette.secondaryText)
                        Text(option)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(palette.primaryText)
                    .background(
                        selectedOptions.contains(option)
                            ? palette.primaryText.opacity(colorScheme == .dark ? 0.12 : 0.07)
                            : palette.controlFill.opacity(0.58)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(palette.hairline, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .cursor(.arrow)
            }
        }
    }

    private func canSubmitAskUser(isMultiSelect: Bool) -> Bool {
        if !answerInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return !selectedOptions.isEmpty
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
        } else if let selected = options.first(where: { selectedOptions.contains($0) }) {
            answer = selected
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
        if call.toolName == "spawn_agent",
           let detail = AgentDelegatedCommandApprovalCopy.detail(arguments: call.arguments) {
            return (detail.title, detail.body)
        }
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
        if call.toolName == "declare_environment_trust" {
            // 用户原话必须原样出现在卡片正文里——这是用户识破“注入文本
            // 冒充我说过的话”的唯一凭据，不能只显示类别标签。
            let statement = call.arguments["user_statement"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let kindRaw = (call.arguments["kind"]?.stringValue() ?? "").lowercased()
            if kindRaw == "revoke_all" {
                return ("将要撤销", statement.isEmpty ? "撤销本会话的全部环境信任声明" : statement)
            }
            var body = statement.isEmpty ? "(Agent 没有引用你的原话)" : "「\(statement)」"
            if let target = call.arguments["target"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty {
                body += "\n\n匹配目标：\(target)"
            }
            return ("Agent 引用的你的原话", body)
        }
        if call.toolName == "web_fetch",
           let url = call.arguments["url"]?.stringValue(),
           !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ("访问地址", url)
        }
        if call.toolName == "create_user_skills",
           let rawJSON = call.arguments["skills_json"]?.stringValue(),
           let drafts = try? AgentSelfLearning.decodeSkillBatch(rawJSON) {
            let lines = drafts.enumerated().flatMap { index, draft in
                [
                    "\(index + 1). \(draft.name)",
                    "   \(draft.description)",
                ]
            }
            return ("技能清单", lines.joined(separator: "\n"))
        }
        let localizedArguments = AgentToolDisplay.approvalArgumentsLines(
            for: call.arguments
        )
        guard !localizedArguments.isEmpty else { return nil }
        return ("操作内容", localizedArguments)
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

    private var conversationAllowSignature: String? {
        guard call.risk == .write else { return nil }
        return AgentToolAuthorization.interactiveSurfaceSignature(
            toolName: call.toolName
        )
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
        case .failed: return .secondary
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
        case .failed: return .secondary
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

    private var isAttentionNotice: Bool {
        isAuthorizationNotice || call.status == .awaitingUserAnswer
    }

    private var isCompactSurfaceAuthorizationNotice: Bool {
        AgentApprovalPresentationPolicy.usesCompactAuthorization(
            toolName: call.toolName,
            arguments: call.arguments,
            risk: call.risk
        )
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
        || !(call.delegatedProgress?.recentOutput?.isEmpty ?? true)
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
        case .taskGrant: return L10n.GoalAuthorization.badge
        case .alwaysAllowList: return "ALWAYS"
        case .staticAllowlist: return "AUTO"
        case .llmJudge: return "AI OK"
        case .goalMode: return "GOAL"
        case .dispatchTask: return "UNATTENDED"
        case .workspaceAccess: return "WORKSPACE"
        case .fullAccess: return "FULL"
        case .controlLease: return L10n.ToolCard.approvalControlLeaseBadge
        case .escalated: return "ESCALATED"
        case .trustedServer: return "TRUSTED"
        case .subagentEditor: return "SUBAGENT"
        case .environmentTrust: return "DECLARED"
        }
    }

    private var approvalSourceTooltip: String? {
        guard let source = call.approvalSource else { return nil }
        switch source {
        case .user: return nil
        case .taskGrant: return L10n.GoalAuthorization.scope
        case .alwaysAllowList: return "You pinned this command signature as always-allowed."
        case .staticAllowlist: return "Matched a built-in deterministic low-risk rule (safe inspection, bounded local metadata, or read-style MCP tools)."
        case .llmJudge: return "An LLM judge classified this call as non-malicious normal work."
        case .goalMode: return "Auto-approved because this session is in Goal mode. Danger-tier commands still ask."
        case .dispatchTask: return "Auto-approved because this scheduler-owned task is running unattended."
        case .workspaceAccess: return "Auto-approved by this session's Workspace Access approval mode. Danger-tier commands still ask."
        case .fullAccess: return "Ran under Full Access: internet, local files, and credentials are allowed without approval prompts unless a deterministic malicious-command rule blocks the call."
        case .controlLease: return L10n.ToolCard.approvalControlLeaseTooltip
        case .escalated: return "You approved this call to run outside the default sandbox boundary."
        case .trustedServer: return "You marked this MCP server as fully trusted — all its calls auto-run."
        case .subagentEditor: return "Applied by an editor subagent, limited to the single file you approved when the spawn was confirmed."
        case .environmentTrust: return "Covered by an environment trust declaration you confirmed earlier in this session, such as a deployment window."
        }
    }

    private var cardBackground: Color {
        if isAttentionNotice {
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
        if isAttentionNotice {
            return Color.clear
        }
        switch call.status {
        case .pendingApproval, .awaitingConfirm: return appState.editorSettings.interfaceSkin.palette.hairline
        case .awaitingUserAnswer: return appState.editorSettings.interfaceSkin.palette.hairline
        case .failed:
            // Every failure — a non-zero command and a tool that malfunctioned
            // alike — stays in the neutral palette. The icon and title went
            // grayscale first; an orange border on the same card was the last
            // thing still styling "编辑文件失败" as an alarm.
            return Color.secondary.opacity(0.3)
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
