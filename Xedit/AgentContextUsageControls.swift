//
//  AgentContextUsageControls.swift
//  WillDeep
//
//  Debounced, background-backed context usage controls for the Agent status bar.
//

import Combine
import SwiftUI

@MainActor
private final class AgentContextUsageEstimateStore: ObservableObject {
    private static let trailingDelayNanoseconds: UInt64 = 750_000_000

    @Published private(set) var snapshot = AgentContextTokenUsageSnapshot.placeholder
    private var refreshTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    deinit {
        refreshTask?.cancel()
    }

    func schedule(
        appState: AppState,
        sessionID: AgentSession.ID,
        immediate: Bool = false
    ) {
        generation &+= 1
        let scheduledGeneration = generation
        refreshTask?.cancel()
        refreshTask = Task { [weak self, weak appState] in
            guard let self, let appState else { return }
            if !immediate {
                do {
                    try await Task.sleep(nanoseconds: Self.trailingDelayNanoseconds)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            guard let next = await appState.estimateAgentContextUsageSnapshot(for: sessionID) else {
                return
            }
            guard !Task.isCancelled, scheduledGeneration == generation else { return }
            if snapshot != next {
                snapshot = next
            }
        }
    }
}

struct AgentContextUsageControls: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var runtime: AgentRuntime
    @StateObject private var estimateStore = AgentContextUsageEstimateStore()

    var body: some View {
        Group {
            CompressButton(
                usage: estimateStore.snapshot,
                messageCount: runtime.messages.count
            )
            ContextRingIndicator(usage: estimateStore.snapshot)
        }
        .onAppear {
            scheduleRefresh(immediate: true)
        }
        .onReceive(runtime.$messages.dropFirst()) { _ in scheduleRefresh() }
        .onReceive(runtime.$contextSummary.dropFirst()) { _ in scheduleRefresh() }
        .onReceive(runtime.$contextSummaryThroughMessageID.dropFirst()) { _ in scheduleRefresh() }
        .onReceive(runtime.$activeExperts.dropFirst()) { _ in scheduleRefresh() }
        .onReceive(runtime.$interactionMode.dropFirst()) { _ in scheduleRefresh() }
        .onReceive(runtime.$approvalMode.dropFirst()) { _ in scheduleRefresh() }
        .onReceive(runtime.$executionAgent.dropFirst()) { _ in scheduleRefresh() }
        .onReceive(runtime.$currentPlan.dropFirst()) { _ in scheduleRefresh() }
        .onReceive(runtime.$currentGoal.dropFirst()) { _ in scheduleRefresh() }
        .onReceive(runtime.$sessionModelOverride.dropFirst()) { _ in scheduleRefresh() }
        .onReceive(runtime.$sessionProviderEntryID.dropFirst()) { _ in scheduleRefresh() }
        .onReceive(runtime.$sessionProviderIDOverride.dropFirst()) { _ in scheduleRefresh() }
        .onReceive(appState.$agentConfiguration.dropFirst()) { _ in scheduleRefresh() }
        .onReceive(appState.$agentProviderLibrary.dropFirst()) { _ in scheduleRefresh() }
        .onReceive(appState.$rootDirectory.dropFirst()) { _ in scheduleRefresh() }
        .onReceive(appState.$openedFileURL.dropFirst()) { _ in scheduleRefresh() }
        .onReceive(appState.$fileContent.dropFirst()) { _ in scheduleRefresh() }
        .onReceive(appState.$selectedCharacterCount.dropFirst()) { _ in scheduleRefresh() }
        .onReceive(appState.$selectedLineCount.dropFirst()) { _ in scheduleRefresh() }
    }

    private func scheduleRefresh(immediate: Bool = false) {
        estimateStore.schedule(
            appState: appState,
            sessionID: runtime.id,
            immediate: immediate
        )
    }
}

/// Button to manually compress the conversation. It only consumes the latest
/// background-produced snapshot; no request rebuilding occurs in `body`.
private struct CompressButton: View {
    @EnvironmentObject private var appState: AppState
    let usage: AgentContextTokenUsageSnapshot
    let messageCount: Int

    var body: some View {
        Group {
            if appState.isCompressingAgentContext {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(L10n.ContextCompression.compressing)
                }
            } else if shouldOffer {
                Button {
                    appState.compressAgentContext()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "rectangle.compress.vertical")
                            .font(.system(size: 9))
                        Text(L10n.ContextCompression.compress)
                    }
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L10n.ContextCompression.compressHelp)
                .disabled(appState.isAgentResponding)
            }
        }
    }

    private var usedFraction: Double {
        let window = max(1, usage.contextWindow)
        return min(1, Double(usage.usedTokens) / Double(window))
    }

    private var shouldOffer: Bool {
        usedFraction > 0.5 && messageCount > 6
    }

    private var tint: Color {
        if usedFraction > 0.9 { return .red }
        if usedFraction > 0.75 { return .orange }
        return .accentColor
    }
}

private struct ContextRingIndicator: View {
    let usage: AgentContextTokenUsageSnapshot

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                    .frame(width: 12, height: 12)
                Circle()
                    .trim(from: 0, to: usedFraction)
                    .stroke(barColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 12, height: 12)
            }
            Text("\(percent)%")
                .monospacedDigit()
        }
        .help(L10n.ContextRing.tooltip(
            formatTokens(conversationUsed),
            formatTokens(usableWindow),
            formatTokens(baseline),
            formatTokens(remaining)
        ))
    }

    private var window: Int { max(1, usage.contextWindow) }
    private var used: Int { usage.usedTokens }
    private var baseline: Int { min(usage.baselineTokens, used) }
    private var usableWindow: Int { max(1, window - baseline) }
    private var conversationUsed: Int { max(0, used - baseline) }
    private var usedFraction: CGFloat {
        min(1, max(0, CGFloat(conversationUsed) / CGFloat(usableWindow)))
    }
    private var remaining: Int { max(0, window - used) }
    private var percent: Int { Int(usedFraction * 100) }

    private var barColor: Color {
        if usedFraction > 0.9 { return .red }
        if usedFraction > 0.75 { return .orange }
        return .accentColor
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return "\(count / 1_000)k" }
        return "\(count)"
    }
}
