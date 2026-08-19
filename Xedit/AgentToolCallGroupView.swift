//
//  AgentToolCallGroupView.swift
//  WillDeep
//
//  The collapsible group wrapper around a run of tool calls. Split out of
//  AgentToolCallViews.swift, which had grown past the repository's hard
//  file-size limit.
//

import SwiftUI
import AppKit

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
                    if !status.isEmpty {
                        Text(status)
                            .font(AgentDesign.chatSupportingFont(
                                baseFontSize: appState.agentChatBaseFontSize
                            ))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
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
        let queued = calls.filter(AgentSerialToolApprovalQueue.contains).count
        let running = calls.filter {
            $0.status == .running && !AgentSerialToolApprovalQueue.contains($0)
        }.count
        let failed = calls.filter { $0.status == .failed }.count
        let denied = calls.filter { $0.status == .denied }.count
        var parts: [String] = []
        if waiting > 0 { parts.append("(\(waiting)条待处理)") }
        if queued > 0 { parts.append("(\(queued)条排队等待确认)") }
        if running > 0 { parts.append("(\(running)条运行中)") }
        if failed > 0 { parts.append("(\(failed)条失败)") }
        if denied > 0 { parts.append("(\(denied)条已拒绝)") }
        return parts.joined(separator: " · ")
    }

    private var previewSummary: String? {
        AgentCollapsedToolActivitySummary.text(for: calls)
    }

    private var groupBorderColor: Color {
        if containsInteractiveCall { return appState.editorSettings.interfaceSkin.palette.accent.opacity(0.28) }
        if calls.contains(where: { $0.status == .failed && $0.commandExitCode == nil }) {
            return Color.orange.opacity(0.28)
        }
        return Color.primary.opacity(0.04)
    }
}

/// Live, phase-aware activity surface for the current assistant turn. The
/// current operation is one quiet disclosure row by default. Expanding it
/// reveals the recent timeline. Interactive approvals keep their full controls.
