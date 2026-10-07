import Foundation
import SwiftUI

/// 反向请求未携带发起会话时的保守展示策略。冻结于创建时，切会话不迁移卡片。
nonisolated enum AgentPluginRoundtableChatOrigin {
    static func resolve(activeSessionID: UUID?, respondingSessionIDs: [UUID]) -> UUID? {
        guard let activeSessionID,
              respondingSessionIDs.count == 1,
              respondingSessionIDs.first == activeSessionID else { return nil }
        return activeSessionID
    }
}

/// 只取已经公开的专家正文；草稿和最终消息切换时保留姓名与轮次的一致性。
nonisolated struct AgentPluginRoundtableChatSpeech: Equatable {
    let name: String
    let round: Int
    let text: String
    let state: State

    enum State { case preparing, streaming, analyzing, finished }

    static let previewLimit = 1_600

    static func make(from report: AgentRoundtableReport) -> Self? {
        if let seat = report.activeSeat {
            let draft = report.activeExpertDraft ?? ""
            return Self(
                name: seat.displayName,
                round: report.currentRound,
                text: String(draft.suffix(previewLimit)),
                state: draft.isEmpty ? .preparing
                    : report.activeExpertDraftIsComplete == true ? .analyzing : .streaming
            )
        }
        guard let message = report.messages.last(where: {
            $0.speaker == .expert && $0.isError != true
        }) else { return nil }
        return Self(
            name: report.seat(for: message)?.displayName ?? message.speakerName,
            round: message.round,
            text: String(message.content.suffix(previewLimit)),
            state: .finished
        )
    }
}

/// 主会话直接观察圆桌 runtime。正文增量只重绘这张卡，不复制到主模型上下文，
/// 不额外调模型、不等待 MCP 最终响应，也不逐 token 重绘整段聊天历史。
struct AgentPluginRoundtableChatProgressList: View {
    @EnvironmentObject private var appState: AppState
    let sessionID: UUID

    var body: some View {
        ForEach(appState.agentRuntimes.values.filter {
            $0.session.presentationScope == .roundtable &&
                $0.messages.compactMap(\.workflowReport).last?.roundtable?.originSessionID == sessionID
        }.sorted { $0.session.createdAt > $1.session.createdAt }.prefix(3)) { runtime in
            AgentPluginRoundtableChatProgressHost(runtime: runtime, originSessionID: sessionID)
        }
    }
}

private struct AgentPluginRoundtableChatProgressHost: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var runtime: AgentRuntime
    let originSessionID: UUID

    var body: some View {
        ForEach(runtime.messages) { message in
            if let workflow = message.workflowReport,
               let report = workflow.roundtable,
               report.originSessionID == originSessionID {
                AgentPluginRoundtableChatProgressCard(
                    report: report,
                    onOpen: {
                        appState.requestedRoundtableRoute = .discussion(runtimeID: runtime.id, reportID: workflow.id)
                        appState.agentPrimaryDestination = .roundtable
                    }
                )
            }
        }
    }
}

struct AgentPluginRoundtableChatProgressCard: View {
    let report: AgentRoundtableReport
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !report.seats.isEmpty { participants }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                ForEach(AgentRoundtableChatTimeline.entries(from: report)) { entry in
                    speechRow(entry)
                }
            }
            if report.phase == .awaitingUser {
                Label(L10n.RoundtableChat.needsReply, systemImage: "bubble.left.and.exclamationmark.bubble.right")
                    .font(.callout).foregroundStyle(.orange)
            }
            Divider()
            footer
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
        .accessibilityIdentifier("agent-roundtable-live-progress")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.3").foregroundStyle(.secondary)
            Text(report.displayTitle).font(.headline).lineLimit(1)
            Spacer(minLength: 8)
            Text(phaseTitle).font(.caption).foregroundStyle(report.phase == .failed ? .red : .secondary)
            if report.currentRound > 0 {
                Text(String(format: L10n.Roundtable.roundLabelFormat, report.currentRound)).font(.caption)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(AgentRoundtableChatTimeline.elapsed(
                    from: report.createdAt,
                    to: AgentRoundtableChatTimeline.isTerminal(report.phase) ? report.updatedAt : context.date
                ))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var participants: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(report.seats) { seat in
                    HStack(spacing: 6) {
                        RoundtableSeatAvatar(seat: seat, size: 28, isActive: report.activeSeatID == seat.id)
                        Text(seat.displayName).font(.caption).lineLimit(1)
                    }
                    .foregroundStyle(report.activeSeatID == seat.id ? .orange : .secondary)
                }
            }
        }
        .frame(height: 36)
    }

    private func speechRow(_ entry: AgentRoundtableChatTimeline.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 4) {
                Circle().fill(entry.isLive ? Color.orange : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 1)
            }
            .frame(width: 8, height: entry.isLive ? 160 : 64)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    if let seat = entry.seat { RoundtableSeatAvatar(seat: seat, size: 24, isActive: entry.isLive) }
                    Text(entry.name).font(.subheadline.weight(.semibold))
                    Text(entry.isError ? L10n.Roundtable.statusFailed : stateTitle(entry.state))
                        .font(.caption).foregroundStyle(entry.isError ? .red : entry.isLive ? .orange : .secondary)
                    Spacer(minLength: 4)
                    Text(entry.timestamp).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if entry.isLive, !entry.text.isEmpty {
                    liveText(entry)
                } else if !entry.text.isEmpty {
                    Text(verbatim: entry.text).font(.callout).lineLimit(3).textSelection(.enabled)
                }
                if entry.isTruncated {
                    Text(L10n.RoundtableChat.truncated).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func liveText(_ entry: AgentRoundtableChatTimeline.Entry) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(verbatim: entry.text).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 1).id("speech-bottom")
            }
            .onAppear { proxy.scrollTo("speech-bottom", anchor: .bottom) }
            .onChange(of: entry.text) { _ in proxy.scrollTo("speech-bottom", anchor: .bottom) }
        }
        .frame(height: 140)
        .padding(8)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(L10n.RoundtableChat.previewHint).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onOpen) {
                Label(L10n.RoundtableChat.open, systemImage: "arrow.up.right")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("agent-roundtable-open")
        }
    }

    private var phaseTitle: String {
        switch report.phase {
        case .clarifying: return L10n.RoundtableSetup.preparationTitle
        case .selectingExperts: return L10n.RoundtableSetup.selectionTitle
        case .recommending: return L10n.Roundtable.phaseRecommending
        case .opening: return L10n.Roundtable.phaseOpening
        case .synthesizing: return L10n.Roundtable.phaseSynthesizing
        case .awaitingUser: return L10n.Roundtable.phaseAwaiting
        case .completed: return L10n.Roundtable.statusConverged
        case .failed: return L10n.Roundtable.statusFailed
        case .cancelled: return L10n.Roundtable.cancelledNote
        default: return L10n.Roundtable.phaseDiscussing
        }
    }

    private func stateTitle(_ state: AgentPluginRoundtableChatSpeech.State) -> String {
        switch state {
        case .preparing: return L10n.RoundtableChat.preparing
        case .streaming: return L10n.RoundtableChat.speaking
        case .analyzing: return L10n.RoundtableChat.analyzing
        case .finished: return L10n.RoundtableChat.finished
        }
    }
}
