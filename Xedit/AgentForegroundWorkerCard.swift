//
//  AgentForegroundWorkerCard.swift
//  WillDeep
//
//  "Show in foreground" for a background Worker. The live Worker card
//  (AgentSubagentSpeechView: monitor, rounds, intervention) only renders in
//  the chat's live-activity area while the parent turn is responding, and a
//  background spawn's tool card turns `.succeeded` the moment the handle is
//  returned. Once the parent reply ends, a background Worker is left with
//  nothing but a counter in the composer strip. Pinning brings the same card
//  back above the composer for as long as the user wants to watch it.
//

import SwiftUI

extension AppState {
    /// Pins one Worker of the active session. Pinning another replaces it:
    /// one live card above the composer is readable, several are not.
    func showWorkerInForeground(runID: UUID) {
        activeRuntime?.foregroundWorkerRunID = runID
    }

    func returnForegroundWorkerToBackground() {
        activeRuntime?.foregroundWorkerRunID = nil
    }

    /// The spawn tool call carrying the pinned Worker's live activity.
    var foregroundWorkerCall: AgentToolCall? {
        guard let runtime = activeRuntime, let runID = runtime.foregroundWorkerRunID else { return nil }
        return runtime.toolCalls.last { $0.subagentRunID == runID && $0.subagentLiveActivity != nil }
    }

    /// Only background Workers get pinned: a foreground Worker already has
    /// this card in the chat's live-activity area, and a second copy above
    /// the composer would just duplicate it.
    func isBackgroundWorker(runID: UUID) -> Bool {
        agentToolCalls.contains { $0.subagentRunID == runID && $0.subagentLiveActivity?.isBackground == true }
    }

    /// A finished pinned Worker stays readable until the next user turn, then
    /// gets out of the way. A running one is never dropped this way.
    func releaseFinishedForegroundWorker(for runtime: AgentRuntime) {
        guard let runID = runtime.foregroundWorkerRunID else { return }
        let stillWorking = runtime.toolCalls.contains { $0.subagentRunID == runID && $0.subagentIsWorking }
        if !stillWorking {
            runtime.foregroundWorkerRunID = nil
        }
    }
}

/// Live card of the pinned Worker, rendered above the composer.
struct AgentForegroundWorkerCard: View {
    @EnvironmentObject private var appState: AppState
    let call: AgentToolCall

    /// Keeps the composer on screen however long the Worker's narration gets.
    static let maximumHeight: CGFloat = 380

    private var runID: UUID? { call.subagentRunID }

    private var isStoppable: Bool {
        guard let runID, let parentID = appState.activeAgentSessionID else { return false }
        return appState.agentSubagentRegistry.runs.contains {
            $0.id == runID && $0.parentRuntimeID == parentID && $0.status == .running
        }
    }

    var body: some View {
        if let activity = call.subagentLiveActivity {
            VStack(alignment: .leading, spacing: 0) {
                header(activity)
                Divider()
                ScrollView {
                    AgentSubagentSpeechView(
                        activity: activity,
                        runID: runID,
                        isRunning: call.subagentIsWorking,
                        taskTitle: AgentToolDisplay.objectSummary(
                            toolName: call.toolName,
                            arguments: call.arguments
                        )
                    )
                    .padding(8)
                }
                .frame(maxHeight: Self.maximumHeight)
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
            )
            .accessibilityIdentifier("foreground-worker-card")
        }
    }

    private func header(_ activity: AgentSubagentLiveActivity) -> some View {
        HStack(spacing: 8) {
            Text(L10n.AgentDelegation.foregroundBadge)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.16)))
            Text(activity.workerName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let runID {
                Button(L10n.AgentDelegation.foregroundOpenRecord) {
                    AgentSubagentInspectorWindowRegistry.shared.open(
                        runID: runID,
                        fallbackLabel: activity.workerName
                    )
                }
                .buttonStyle(.borderless)
                .focusable(false)
            }
            if isStoppable, let runID, let parentID = appState.activeAgentSessionID {
                Button {
                    appState.agentSubagentRegistry.stop(runID: runID, forParentRuntime: parentID)
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help(L10n.Consultation.stop)
                .accessibilityLabel(L10n.Consultation.stop)
                .disabled(appState.agentSubagentRegistry.stopRequestedRunIDs.contains(runID))
            }
            Button {
                appState.returnForegroundWorkerToBackground()
            } label: {
                Image(systemName: call.subagentIsWorking ? "arrow.down.right.and.arrow.up.left" : "xmark")
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help(call.subagentIsWorking ? L10n.AgentDelegation.foregroundReturn : L10n.AgentDelegation.foregroundClose)
            .accessibilityLabel(call.subagentIsWorking ? L10n.AgentDelegation.foregroundReturn : L10n.AgentDelegation.foregroundClose)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
