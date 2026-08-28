//
//  AgentSubagentLiveActivity.swift
//  WillDeep
//
//  What a running Worker is doing, as seen from outside the child loop.
//
//  Before this existed the parent had exactly two things to show while a
//  Worker ran: the trade's name, and a one-line progress string that only
//  the model-requested `spawn_agent` path ever populated. Everything the
//  child actually said stayed inside the runner until it finished, then
//  landed in the inspector window — a surface you have to go open.
//
//  This type carries the same heartbeat in structured form, plus the
//  child's *public* round text, so the delegation card in the transcript
//  can show the Worker talking while it works.
//
//  Two deliberate limits:
//
//   - Utterances are published once per completed round, not per token.
//     Streaming rich text into the transcript is the exact shape that
//     previously pinned the main thread in SwiftUI layout; a Worker's
//     round text is a finished paragraph and loses nothing by arriving
//     whole.
//   - Only provider-visible content is carried. Reasoning stays out, the
//     same rule `AgentSubagentProgressUpdate` already follows: a Worker's
//     private chain of thought is not the parent transcript's business.
//

import Foundation

nonisolated struct AgentSubagentLiveActivity: Equatable, Sendable {
    /// One thing the Worker said out loud, in the round it said it.
    nonisolated struct Utterance: Equatable, Sendable, Identifiable {
        var id: Int { round }
        let round: Int
        let text: String
        /// Tools the Worker went on to call in that same round, in order.
        let toolNames: [String]
    }

    /// Keep the tail, not the head: the newest round is what the user is
    /// reading, and an old round is one inspector click away.
    static let maxUtterances = 6
    static let utteranceCharacterLimit = 600
    static let maxToolNamesPerUtterance = 8

    var profileID: String
    var workerName: String
    var model: String
    var round: Int
    var maximumRounds: Int
    var completedToolInvocations: Int
    /// Semantic, already-localized activity ("正在执行 grep_files").
    var activityText: String
    /// When this Worker started — not when the parent turn started. A turn
    /// that spawns a Worker eight minutes in should not show the Worker as
    /// eight minutes old.
    var startedAt: Date
    var utterances: [Utterance] = []

    /// `第 3/8 轮 · 已完成 5 次工具调用 · 正在执行 grep_files`
    var detailLine: String {
        var parts = [L10n.AgentDelegation.progressRound(round, maximumRounds)]
        if completedToolInvocations > 0 {
            parts.append(L10n.AgentDelegation.progressCompletedTools(completedToolInvocations))
        }
        if !activityText.isEmpty {
            parts.append(activityText)
        }
        return parts.joined(separator: " · ")
    }

    /// Appends `text` as round `round`'s utterance, replacing the existing
    /// one for that round rather than stacking duplicates — a round can
    /// publish more than once (text first, then its tool names).
    mutating func recordUtterance(round: Int, text: String, toolNames: [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let clampedTools = Array(toolNames.prefix(Self.maxToolNamesPerUtterance))
        guard !trimmed.isEmpty || !clampedTools.isEmpty else { return }
        let utterance = Utterance(
            round: round,
            text: String(trimmed.prefix(Self.utteranceCharacterLimit)),
            toolNames: clampedTools
        )
        if let index = utterances.firstIndex(where: { $0.round == round }) {
            utterances[index] = utterance
        } else {
            utterances.append(utterance)
        }
        if utterances.count > Self.maxUtterances {
            utterances.removeFirst(utterances.count - Self.maxUtterances)
        }
    }
}

/// The composer strip's view of every Worker running right now.
///
/// The strip has one line. When several Workers run at once it used to show
/// whichever tool call happened to be last in the array and silently drop
/// the rest — "委派给「运维查询员」Worker" while three trades were working.
/// This states the count first and then details the one Worker whose status
/// is freshest, so the line never claims to be the whole story when it isn't.
nonisolated struct AgentSubagentFleetStatus: Equatable {
    let runningCount: Int
    let primaryWorkerName: String
    let primaryDetail: String
    /// The primary Worker's own start time, for the strip's elapsed clock.
    let primaryStartedAt: Date?

    /// Nil when no Worker is running, which leaves the strip on whatever
    /// phase it would otherwise show.
    static func make(
        from calls: [AgentToolCall],
        fallbackWorkerName: (AgentToolCall) -> String
    ) -> AgentSubagentFleetStatus? {
        let running = calls.filter {
            $0.toolName == "spawn_agent" && $0.status == .running
        }
        guard !running.isEmpty else { return nil }

        // Prefer a Worker that has actually reported in. One that has not
        // published a round yet has nothing to say, and picking it would
        // blank a line that another Worker could have filled.
        let reporting = running.filter { $0.subagentLiveActivity != nil }
        let primary = reporting.max {
            ($0.subagentLiveActivity?.round ?? 0) < ($1.subagentLiveActivity?.round ?? 0)
        } ?? running[running.count - 1]

        let name = primary.subagentLiveActivity?.workerName
            ?? primary.subagentWorkerName
            ?? fallbackWorkerName(primary)
        return AgentSubagentFleetStatus(
            runningCount: running.count,
            primaryWorkerName: name,
            primaryDetail: primary.subagentLiveActivity?.detailLine
                ?? primary.subagentProgress
                ?? "",
            primaryStartedAt: primary.subagentLiveActivity?.startedAt
        )
    }

    /// The whole strip label. Single Worker keeps the familiar
    /// "委派给「X」Worker · …" wording; a fleet leads with the count so the
    /// number is the first thing read.
    var composerLabel: String {
        let base = runningCount > 1
            ? L10n.AgentDelegation.fleetRunning(runningCount, primaryWorkerName)
            : L10n.AgentDelegation.delegatedToWorker(primaryWorkerName)
        return primaryDetail.isEmpty ? base : "\(base) · \(primaryDetail)"
    }
}

@MainActor
extension AppState {
    /// Fold one child heartbeat into the structured live activity the
    /// delegation card and the composer strip read.
    ///
    /// All three dispatch paths funnel here — the model's own `spawn_agent`,
    /// the automatic repair dispatch, and the coding pipeline. The latter two
    /// used to pass no progress sink at all, which is why an auto-dispatched
    /// Worker showed a frozen "委派给「X」Worker" for its whole run: the label
    /// had a slot for progress and nothing ever filled it.
    ///
    /// `subagentProgress` keeps its one-line string form for the surfaces
    /// that only want text.
    func applySubagentLiveProgress(
        _ update: AgentSubagentProgressUpdate,
        recordID: AgentToolCall.ID,
        runtime: AgentRuntime,
        profileID: String,
        workerName: String,
        model: String
    ) {
        guard let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) else { return }
        runtime.toolCalls[index].subagentProgress = update.displayText
        if runtime.toolCalls[index].subagentWorkerName == nil {
            runtime.toolCalls[index].subagentWorkerName = workerName
        }
        var activity = runtime.toolCalls[index].subagentLiveActivity
            ?? AgentSubagentLiveActivity(
                profileID: profileID,
                workerName: workerName,
                model: model,
                round: update.round,
                maximumRounds: update.maximumRounds,
                completedToolInvocations: update.completedToolInvocations,
                activityText: update.activity.displayText,
                // First heartbeat wins the clock: the strip should time the
                // Worker, not the turn that happened to spawn it eight
                // minutes ago.
                startedAt: Date()
            )
        activity.round = update.round
        activity.maximumRounds = update.maximumRounds
        activity.completedToolInvocations = update.completedToolInvocations
        activity.activityText = update.activity.displayText
        activity.recordUtterance(
            round: update.round,
            text: update.speech,
            toolNames: update.toolNames
        )
        runtime.toolCalls[index].subagentLiveActivity = activity
    }
}
