//
//  AgentActivityTimelineViews.swift
//  WillDeep
//
//  The live activity timeline and its rows. Split out of
//  AgentToolCallViews.swift, which had grown past the repository's hard
//  file-size limit.
//

import SwiftUI
import AppKit

struct AgentLiveActivityTimeline: View {
    @EnvironmentObject var appState: AppState
    let calls: [AgentToolCall]
    @State private var isExpanded = false

    var body: some View {
        let presentation = AgentLiveActivityTimelinePresentation(calls: calls)
        let detailCallIDs = Set(presentation.detailCalls(isExpanded: isExpanded).map(\.id))
        VStack(alignment: .leading, spacing: AgentDesign.liveActivityRowSpacing) {
            if isExpanded, presentation.hiddenOperationCount > 0 {
                AgentActivityTimelineSummaryRow(count: presentation.hiddenOperationCount)
            }
            ForEach(presentation.visibleCalls) { call in
                if call.status.isBlockingForUserDecision {
                    AgentToolCallCard(call: call)
                } else if detailCallIDs.contains(call.id) {
                    // A reporting Worker owns the whole row: its monitor
                    // already carries task, identity, phase and metrics, so
                    // keeping the generic "subagent running" row above it
                    // would repeat the same state and reintroduce the visual
                    // hierarchy problem this component solves.
                    if let activity = call.subagentLiveActivity,
                       call.subagentIsWorking
                            || !activity.utterances.isEmpty
                            || !activity.interventionReceipts.isEmpty {
                        AgentSubagentSpeechView(
                            activity: activity,
                            runID: call.subagentRunID,
                            isRunning: call.subagentIsWorking,
                            taskTitle: AgentToolActivityRowPresentation(call: call).detail
                        )
                    } else if call.status == .failed,
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

/// How long one step has taken. Ticks while the step is in flight; the moment
/// it settles the clock stops and the number becomes what it cost.
///
/// Its own view, with its own timeline, following the
/// `AgentComposerGoalElapsedLabel` / `AgentBackgroundTaskDurationLabel`
/// pattern — a per-second tick wrapped around the whole row would rebuild the
/// icon, title, detail and spinner once a second, for every visible row.
///
/// The schedule is anchored to `startedAt`, not to `.now`. `.now` is captured
/// when the enclosing body is evaluated, so a schedule built that way is
/// re-anchored on every unrelated state change and its phase depends on
/// render timing rather than on the thing being measured. Every other elapsed
/// clock in this app anchors to the start instant; this one does too.
private struct AgentStepDurationLabel: View {
    let startedAt: Date
    let finishedAt: Date?

    var body: some View {
        Group {
            if let finishedAt {
                Text(AgentToolActivityRowPresentation.formatDuration(
                    finishedAt.timeIntervalSince(startedAt)
                ))
            } else {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(AgentToolActivityRowPresentation.formatDuration(
                        context.date.timeIntervalSince(startedAt)
                    ))
                }
            }
        }
        .font(.system(size: 10.5, weight: .regular, design: .monospaced))
        .foregroundStyle(.tertiary)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
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
                .font(agentMetadataFont)
                .lineSpacing(agentMetadataLineSpacing)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
    }

    // 活动行跟着聊天正文字号,不再降一档 —— 回合结束落进 TextKit
    // transcript 后同样是正文字号,两个显示面之间不能有字号跳变。
    private var agentMetadataFont: Font {
        .system(size: appState.agentChatBaseFontSize)
    }

    private var agentMetadataLineSpacing: CGFloat {
        AgentChatTypography.lineSpacing(
            fontSize: appState.agentChatBaseFontSize,
            lineHeightMultiple: appState.agentChatLineHeightMultiple
        )
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
                .font(agentMetadataFont)
                .lineSpacing(agentMetadataLineSpacing)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if let detail = presentation.detail {
                Text(detail)
                    .font(agentMetadataFont)
                    .lineSpacing(agentMetadataLineSpacing)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if presentation.status == .running && !presentation.isQueuedForApproval {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.58)
                    .frame(width: 13, height: 13)
            }
            Spacer(minLength: 0)
            AgentStepDurationLabel(
                startedAt: presentation.startedAt,
                finishedAt: presentation.finishedAt
            )
        }
        .frame(minHeight: AgentChatTypography.lineHeight(
            fontSize: appState.agentChatBaseFontSize,
            lineHeightMultiple: appState.agentChatLineHeightMultiple
        ))
        .help(errorDetail ?? presentation.title)
        .accessibilityElement(children: .combine)
    }

    private var iconColor: Color {
        if presentation.isQueuedForApproval {
            return Color(nsColor: .secondaryLabelColor)
        }
        switch presentation.status {
        case .running, .pendingApproval, .awaitingConfirm, .awaitingUserAnswer:
            return Color(nsColor: .labelColor)
        case .failed:
            // Command failures are usually intermediate retry signals. Keep
            // them visible without giving a recoverable state alarm styling.
            return Color(nsColor: .secondaryLabelColor)
        case .succeeded, .denied:
            return Color(nsColor: .secondaryLabelColor)
        }
    }

    private var titleColor: Color {
        if presentation.isQueuedForApproval {
            return Color(nsColor: .secondaryLabelColor)
        }
        switch presentation.status {
        case .running:
            return .primary
        case .failed:
            return Color(nsColor: .secondaryLabelColor)
        case .pendingApproval, .awaitingConfirm, .awaitingUserAnswer:
            return .primary
        case .succeeded, .denied:
            return Color(nsColor: .secondaryLabelColor)
        }
    }

    // 同上:活动行跟着正文字号,和落定后的 transcript 保持同一档。
    private var agentMetadataFont: Font {
        .system(size: appState.agentChatBaseFontSize)
    }

    private var agentMetadataLineSpacing: CGFloat {
        AgentChatTypography.lineSpacing(
            fontSize: appState.agentChatBaseFontSize,
            lineHeightMultiple: appState.agentChatLineHeightMultiple
        )
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

struct AgentDelegatedLiveProgressView: View {
    @EnvironmentObject var appState: AppState
    let progress: AgentDelegatedLiveProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: phaseSymbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(phaseTint)
                    .frame(width: 14)
                Text(
                    L10n.DelegatedTask.liveProgress(
                        phase: progress.phase,
                        attempt: progress.attempt,
                        maximum: progress.maximumAttempts
                    )
                )
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: 10,
                    weight: .semibold
                ))
                .foregroundStyle(phaseTint)
                .lineLimit(1)
                if !progress.phase.isTerminal {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .frame(width: 12, height: 12)
                }
                Spacer(minLength: 0)
            }

            if let activity = progress.currentActivity, !activity.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.DelegatedTask.currentActivity)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(activity)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            if progress.terminalTabID != nil {
                Label(
                    L10n.DelegatedTask.fullOutputInTerminal,
                    systemImage: "terminal"
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(phaseTint.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityIdentifier("agent-delegated-live-progress")
    }

    private var phaseSymbol: String {
        switch progress.phase {
        case .contracted:
            return "doc.badge.gearshape"
        case .executing:
            return "hammer"
        case .selfVerifying:
            return "person.crop.circle.badge.checkmark"
        case .willDeepVerifying:
            return "checkmark.shield"
        case .reworkRequired:
            return "arrow.uturn.backward.circle"
        case .readyForDelivery:
            return "checkmark.seal.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .cancelled:
            return "stop.circle"
        }
    }

    private var phaseTint: Color {
        switch progress.phase {
        case .contracted:
            return .secondary
        case .executing, .selfVerifying, .willDeepVerifying:
            return appState.editorSettings.interfaceSkin.palette.accent
        case .reworkRequired:
            return .orange
        case .readyForDelivery:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        }
    }
}
