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

/// One tool call as the delegation card shows it: verb plus object.
///
/// The card used to carry only the verb, which produced columns of identical
/// `运行命令` chips — enough to tell you the Worker is busy, not enough to
/// decide whether to interrupt it. `object` is what the call acts on: the
/// file it reads, the pattern it greps, the command it runs. Nil when the
/// tool has nothing worth naming; the chip then shows the verb alone.
nonisolated struct AgentSubagentToolMention: Equatable, Sendable {
    let name: String
    let object: String?

    init(name: String, object: String? = nil) {
        self.name = name
        self.object = object
    }
}

nonisolated struct AgentSubagentLiveActivity: Equatable, Sendable {
    /// One thing the Worker said out loud, in the round it said it.
    nonisolated struct Utterance: Equatable, Sendable, Identifiable {
        var id: Int { round }
        let round: Int
        let text: String
        /// Tools the Worker went on to call in that same round, in order.
        let tools: [AgentSubagentToolMention]
    }

    enum InterventionDeliveryState: Equatable, Sendable {
        case queued
        case applied(effectiveRound: Int)
    }

    struct InterventionReceipt: Equatable, Sendable, Identifiable {
        let id: UUID
        let text: String
        let mode: AgentSubagentInterventionMode
        let submittedAt: Date
        let requestedRound: Int
        var deliveryState: InterventionDeliveryState
    }

    /// Keep the tail, not the head: the newest round is what the user is
    /// reading, and an old round is one inspector click away.
    static let maxUtterances = 6
    static let utteranceCharacterLimit = 600
    static let maxToolMentionsPerUtterance = 8
    static let maxInterventionReceipts = 6

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
    /// Set when the Worker's run ends. The tool-call status cannot answer
    /// "is this Worker still working": a background spawn settles its record
    /// to `.succeeded` the instant it hands back a handle, while the Worker
    /// itself runs for minutes afterwards. This is the Worker's own liveness.
    var finishedAt: Date?
    /// Who is responsible for sealing `finishedAt`.
    ///
    /// A foreground Worker dies with the tool call that spawned it, so the
    /// record's own `didSet` seals it — no completion path can forget. A
    /// background Worker outlives that record and is sealed by the registry's
    /// closing heartbeat instead. Getting this backwards leaves a finished
    /// Worker on the composer strip forever, or drops a live one off it.
    var isBackground: Bool = false
    var utterances: [Utterance] = []
    var interventionReceipts: [InterventionReceipt] = []

    var isRunning: Bool { finishedAt == nil }

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
    mutating func recordUtterance(
        round: Int,
        text: String,
        tools: [AgentSubagentToolMention]
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let clampedTools = Array(tools.prefix(Self.maxToolMentionsPerUtterance))
        guard !trimmed.isEmpty || !clampedTools.isEmpty else { return }
        let utterance = Utterance(
            round: round,
            text: String(trimmed.prefix(Self.utteranceCharacterLimit)),
            tools: clampedTools
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

    mutating func recordIntervention(_ event: AgentSubagentInterventionEvent) {
        switch event {
        case .queued(let submission):
            let receipt = InterventionReceipt(
                id: submission.id,
                text: submission.text,
                mode: submission.mode,
                submittedAt: submission.submittedAt,
                requestedRound: submission.requestedRound,
                deliveryState: .queued
            )
            if let index = interventionReceipts.firstIndex(where: { $0.id == receipt.id }) {
                interventionReceipts[index] = receipt
            } else {
                interventionReceipts.append(receipt)
            }
        case .applied(let submission, let effectiveRound):
            if let index = interventionReceipts.firstIndex(where: { $0.id == submission.id }) {
                interventionReceipts[index].deliveryState = .applied(
                    effectiveRound: effectiveRound
                )
            } else {
                interventionReceipts.append(InterventionReceipt(
                    id: submission.id,
                    text: submission.text,
                    mode: submission.mode,
                    submittedAt: submission.submittedAt,
                    requestedRound: submission.requestedRound,
                    deliveryState: .applied(effectiveRound: effectiveRound)
                ))
            }
        }
        if interventionReceipts.count > Self.maxInterventionReceipts {
            interventionReceipts.removeFirst(
                interventionReceipts.count - Self.maxInterventionReceipts
            )
        }
    }
}

/// The compact monitor intentionally shows coarse execution phases instead of
/// a made-up percentage. The active phase is inferred from the Worker's
/// provider-visible status and latest tool mention; no private reasoning is
/// inspected and no completion estimate is claimed.
nonisolated enum AgentSubagentMonitorPhase: Int, CaseIterable, Equatable, Sendable {
    case reading
    case locating
    case implementing
    case verifying

    @MainActor
    var title: String {
        switch self {
        case .reading: return L10n.AgentDelegation.monitorPhaseReading
        case .locating: return L10n.AgentDelegation.monitorPhaseLocating
        case .implementing: return L10n.AgentDelegation.monitorPhaseImplementing
        case .verifying: return L10n.AgentDelegation.monitorPhaseVerifying
        }
    }

    static func infer(from activity: AgentSubagentLiveActivity) -> Self {
        let latestToolName = activity.utterances.reversed().lazy
            .compactMap { $0.tools.last?.name }
            .first ?? ""
        let signal = "\(activity.activityText) \(latestToolName)".lowercased()

        if containsAny(signal, keywords: [
            "verify", "validat", "test", "build", "compil", "review",
            "验证", "校验", "测试", "构建", "编译", "审查", "整理结果", "准备结果",
        ]) {
            return .verifying
        }
        if containsAny(signal, keywords: [
            "implement", "edit", "write", "patch", "create", "run",
            "实现", "编辑", "写入", "补丁", "创建", "运行", "执行",
        ]) {
            return .implementing
        }
        if containsAny(signal, keywords: [
            "search", "grep", "glob", "find", "locat",
            "搜索", "正则", "查找", "定位", "通配",
        ]) {
            return .locating
        }
        if containsAny(signal, keywords: [
            "read", "list", "browse", "inspect", "读取", "浏览", "查看",
        ]) {
            return .reading
        }
        return activity.round <= 1 && activity.completedToolInvocations == 0
            ? .reading
            : .implementing
    }

    private static func containsAny(_ value: String, keywords: [String]) -> Bool {
        keywords.contains(where: value.contains)
    }
}

/// View-ready facts for the three-column Worker monitor. Keeping the newest
/// action and phase selection outside SwiftUI makes the information contract
/// testable without rendering the entire transcript.
nonisolated struct AgentSubagentMonitorPresentation: Equatable, Sendable {
    let taskTitle: String?
    let currentPhase: AgentSubagentMonitorPhase
    let currentAction: String
    let latestTool: AgentSubagentToolMention?

    init(activity: AgentSubagentLiveActivity, taskTitle: String?) {
        let normalizedTitle = taskTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.taskTitle = normalizedTitle?.isEmpty == false ? normalizedTitle : nil
        currentPhase = AgentSubagentMonitorPhase.infer(from: activity)
        currentAction = activity.activityText.trimmingCharacters(in: .whitespacesAndNewlines)
        latestTool = activity.utterances.reversed().lazy
            .compactMap { $0.tools.last }
            .first
    }

    var latestAction: String {
        if let latestTool {
            return [latestTool.name, latestTool.object]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "  ")
        }
        return currentAction
    }
}

/// One row of the delegation card, after merging.
nonisolated enum AgentSubagentSpeechRow: Equatable, Identifiable {
    /// A round the Worker actually spoke in, plus whatever it called next.
    case speech(round: Int, text: String, tools: [AgentSubagentToolMention])
    /// One or more consecutive silent rounds, as a single flowing chip run.
    case tools(firstRound: Int, lastRound: Int, mentions: [AgentSubagentToolMention])
    case intervention(AgentSubagentLiveActivity.InterventionReceipt)

    var id: String {
        switch self {
        case .speech(let round, _, _):
            return "speech-\(round)"
        case .tools(let firstRound, let lastRound, _):
            return "tools-\(firstRound)-\(lastRound)"
        case .intervention(let receipt):
            return "intervention-\(receipt.id.uuidString)"
        }
    }
}

/// Turns a Worker's utterances and intervention receipts into the rows the
/// card draws.
///
/// Two jobs, both of which used to live in the view:
///
///  - **Order.** Receipts sort *before* the round they take effect in, so a
///    correction reads above the round that acted on it.
///  - **Merge.** One row per utterance produced a column of single-chip rows
///    whenever the Worker spent several rounds calling one tool each: the
///    line breaks came from the shape of the data rather than from how much
///    there was to read. Consecutive silent rounds now collapse into one
///    row that carries the whole span, so the card wraps when it runs out of
///    width instead of when a round happens to end.
///
/// Pure on purpose — the merging rule is the part worth testing, and it
/// should not need a rendered view to check.
nonisolated enum AgentSubagentSpeechTimeline {
    /// A merged run stops accumulating chips here. Six silent rounds of
    /// eight tools each would otherwise put 48 chips in one row, which is
    /// the same wall of noise the merge was meant to remove.
    static let maximumMergedMentions = 12

    static func rows(for activity: AgentSubagentLiveActivity) -> [AgentSubagentSpeechRow] {
        rows(
            utterances: activity.utterances,
            interventions: activity.interventionReceipts
        )
    }

    static func rows(
        utterances: [AgentSubagentLiveActivity.Utterance],
        interventions: [AgentSubagentLiveActivity.InterventionReceipt]
    ) -> [AgentSubagentSpeechRow] {
        enum Item {
            case utterance(AgentSubagentLiveActivity.Utterance)
            case intervention(AgentSubagentLiveActivity.InterventionReceipt)

            /// Doubled so a receipt can sit at an odd slot just ahead of the
            /// round it lands in, without inventing a fractional round.
            var sortRound: Int {
                switch self {
                case .utterance(let utterance):
                    return utterance.round * 2
                case .intervention(let receipt):
                    switch receipt.deliveryState {
                    case .queued:
                        return receipt.requestedRound * 2 - 1
                    case .applied(let effectiveRound):
                        return effectiveRound * 2 - 1
                    }
                }
            }

            var submittedAt: Date {
                switch self {
                case .utterance: return .distantPast
                case .intervention(let receipt): return receipt.submittedAt
                }
            }
        }

        let ordered = (utterances.map(Item.utterance) + interventions.map(Item.intervention))
            .sorted {
                if $0.sortRound == $1.sortRound {
                    return $0.submittedAt < $1.submittedAt
                }
                return $0.sortRound < $1.sortRound
            }

        var rows: [AgentSubagentSpeechRow] = []
        // The silent run being accumulated, if any.
        var pendingFirstRound: Int?
        var pendingLastRound = 0
        var pendingMentions: [AgentSubagentToolMention] = []

        func flushPendingTools() {
            guard let firstRound = pendingFirstRound, !pendingMentions.isEmpty else {
                pendingFirstRound = nil
                pendingMentions = []
                return
            }
            rows.append(.tools(
                firstRound: firstRound,
                lastRound: pendingLastRound,
                mentions: pendingMentions
            ))
            pendingFirstRound = nil
            pendingMentions = []
        }

        for item in ordered {
            switch item {
            case .utterance(let utterance) where utterance.text.isEmpty:
                guard !utterance.tools.isEmpty else { continue }
                if pendingFirstRound == nil { pendingFirstRound = utterance.round }
                pendingLastRound = utterance.round
                let room = maximumMergedMentions - pendingMentions.count
                if room > 0 {
                    pendingMentions.append(contentsOf: utterance.tools.prefix(room))
                }
            case .utterance(let utterance):
                // A round with text anchors itself; it never joins a run.
                flushPendingTools()
                rows.append(.speech(
                    round: utterance.round,
                    text: utterance.text,
                    tools: utterance.tools
                ))
            case .intervention(let receipt):
                flushPendingTools()
                rows.append(.intervention(receipt))
            }
        }
        flushPendingTools()
        return rows
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
    struct Member: Identifiable, Equatable {
        let id: UUID
        let workerName: String
        let model: String?
        let detail: String
        let startedAt: Date?
        let runID: UUID?
        let round: Int
        let maximumRounds: Int
        let completedToolInvocations: Int
    }

    let runningCount: Int
    /// How many of the running Workers hold one of the registry's background
    /// slots.
    ///
    /// This is deliberately not `runningCount`. `maxConcurrentPerRuntime`
    /// bounds `startBackground` alone — a foreground Worker never takes a slot
    /// — so pairing the two would let the panel read "6/5". The count comes
    /// from the registry rather than from the tool calls because a background
    /// Worker occupies its slot from the moment it is admitted, before it has
    /// published any live activity to recognise it by.
    let backgroundCount: Int
    let primaryWorkerName: String
    let primaryDetail: String
    /// The primary Worker's own start time, for the strip's elapsed clock.
    let primaryStartedAt: Date?
    let members: [Member]

    /// Nil when no Worker is running, which leaves the strip on whatever
    /// phase it would otherwise show.
    static func make(
        from calls: [AgentToolCall],
        backgroundCount: Int = 0,
        fallbackWorkerName: (AgentToolCall) -> String
    ) -> AgentSubagentFleetStatus? {
        // See `AgentToolCall.subagentIsWorking` for why liveness cannot just
        // read the record's status: a background spawn settles the moment it
        // hands back a handle, while its Worker runs on for minutes.
        let running = calls.filter { $0.toolName == "spawn_agent" && $0.subagentIsWorking }
        guard !running.isEmpty else { return nil }

        // Prefer a Worker that has actually reported in. One that has not
        // published a round yet has nothing to say, and picking it would
        // blank a line that another Worker could have filled.
        let reporting = running.filter { $0.subagentLiveActivity != nil }
        let primary = reporting.max {
            ($0.subagentLiveActivity?.round ?? 0) < ($1.subagentLiveActivity?.round ?? 0)
        } ?? running[running.count - 1]

        func workerName(for call: AgentToolCall) -> String {
            call.subagentLiveActivity?.workerName
                ?? call.subagentWorkerName
                ?? fallbackWorkerName(call)
        }
        let name = workerName(for: primary)
        let members = running.map { call in
            let activity = call.subagentLiveActivity
            return Member(
                id: call.id,
                workerName: workerName(for: call),
                model: call.subagentModel,
                detail: activity?.detailLine ?? call.subagentProgress ?? "",
                startedAt: activity?.startedAt ?? call.startedAt,
                runID: call.subagentRunID,
                round: activity?.round ?? 0,
                maximumRounds: activity?.maximumRounds ?? 0,
                completedToolInvocations: activity?.completedToolInvocations ?? 0
            )
        }
        return AgentSubagentFleetStatus(
            runningCount: running.count,
            backgroundCount: min(backgroundCount, AgentSubagentRegistry.maxConcurrentPerRuntime),
            primaryWorkerName: name,
            primaryDetail: primary.subagentLiveActivity?.detailLine
                ?? primary.subagentProgress
                ?? "",
            primaryStartedAt: primary.subagentLiveActivity?.startedAt,
            members: members
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
    @discardableResult
    func submitSubagentIntervention(
        runID: UUID,
        text: String,
        mode: AgentSubagentInterventionMode
    ) throws -> AgentSubagentInterventionSubmission {
        try agentSubagentRegistry.submitIntervention(
            runID: runID,
            text: text,
            mode: mode
        )
    }

    func applySubagentIntervention(
        runID: UUID,
        event: AgentSubagentInterventionEvent
    ) {
        guard let runtimeID = agentSubagentRegistry.parentRuntimeID(
            forInterventionRunID: runID
        ),
        let runtime = runtime(for: runtimeID),
        let index = runtime.toolCalls.firstIndex(where: { $0.subagentRunID == runID }),
        var activity = runtime.toolCalls[index].subagentLiveActivity else {
            return
        }
        activity.recordIntervention(event)
        runtime.toolCalls[index].subagentLiveActivity = activity
    }

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
        model: String,
        isBackground: Bool = false
    ) {
        guard let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) else { return }

        // The closing heartbeat only flips liveness. Overwriting round and
        // tool counts with its zeroes would blank a card that should keep
        // showing what the Worker got through.
        if update.activity == .finished {
            runtime.toolCalls[index].subagentProgress = nil
            if runtime.toolCalls[index].subagentLiveActivity?.finishedAt == nil {
                runtime.toolCalls[index].subagentLiveActivity?.finishedAt = Date()
            }
            return
        }

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
                startedAt: Date(),
                isBackground: isBackground
            )
        activity.round = update.round
        activity.maximumRounds = update.maximumRounds
        activity.completedToolInvocations = update.completedToolInvocations
        activity.activityText = update.activity.displayText
        activity.recordUtterance(
            round: update.round,
            text: update.speech,
            tools: update.tools
        )
        runtime.toolCalls[index].subagentLiveActivity = activity
    }

    /// Route one background Worker's heartbeat back to the tool call that
    /// spawned it. The registry only knows the run id; `subagentRunID` is the
    /// thread back to the record, bound at spawn time by `bindSubagentRun`.
    func applyBackgroundSubagentProgress(
        runID: UUID,
        _ update: AgentSubagentProgressUpdate
    ) {
        guard let run = agentSubagentRegistry.runs.first(where: { $0.id == runID }),
              let runtime = runtime(for: run.parentRuntimeID),
              let call = runtime.toolCalls.first(where: { $0.subagentRunID == runID }) else {
            return
        }
        applySubagentLiveProgress(
            update,
            recordID: call.id,
            runtime: runtime,
            profileID: run.profileID,
            workerName: call.subagentWorkerName
                ?? L10n.AgentDelegation.profileName(for: run.profileID),
            model: run.model,
            isBackground: true
        )
    }
}
