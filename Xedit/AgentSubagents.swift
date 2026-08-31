//
//  AgentSubagents.swift
//  WillDeep
//
//  Claude Code-style subagents: the model calls `spawn_agent` with a
//  task prompt, and a headless child agent loop runs against the same
//  workspace with a restricted read-only tool set, returning its final
//  assistant message as the tool result.
//
//  Two execution modes, mirroring `run_command`:
//   - Synchronous (default): the parent turn awaits the child loop and
//     gets the report inline as the tool payload.
//   - Background (`run_in_background: true`): returns an agent_xxxxxx
//     handle immediately; when the child finishes, the registry queues
//     the report and the parent loop injects it as a system message at
//     the top of the next round — same contract as background jobs.
//
//  Hard safety lines:
//   - Subagents only get read-only tools (`allowedToolNames`); any
//     `run_command` that doesn't classify as .read risk is denied
//     in-loop. No approval UI exists down here, so nothing that would
//     need approval may run.
//   - No `spawn_agent` in the child tool set — nesting is capped at
//     one level by construction.
//   - Round cap (`maxRounds`) keeps a confused child from looping
//     forever on someone else's token budget.
//

import Foundation
import Combine
import OSLog

private let agentSubagentLog = Logger(subsystem: "com.willdeep.agent", category: "subagent")

// MARK: - Run snapshot

/// One spawned subagent, as observed by UI and the parent loop.
/// The heavy transcript stays inside the runner; this snapshot only
/// carries displayable metadata plus the final report.
struct AgentSubagentRun: Identifiable, Equatable {
    enum Status: String, Codable, Equatable, Sendable {
        case running
        case completed
        case failed
        case cancelled
    }

    let id: UUID
    /// First 6 chars of the UUID, lowercased — "agent_ab12cd" style
    /// copy-pasteable handle, mirroring background job handles.
    let shortID: String
    let label: String
    let prompt: String
    let parentRuntimeID: UUID
    let model: String
    let startedAt: Date
    /// Trade this run executes. Carried on the run itself so the completion
    /// hook can attribute worker cost without re-reading the spawn arguments.
    var profileID: String = AgentSubagentProfileCatalog.deep.id
    /// Provider the child model ran on. Worker trades often bind a different
    /// provider than the parent, and pricing is per (provider, model).
    var providerID: String?
    var status: Status = .running
    var finishedAt: Date?
    /// Final assistant text from the child loop. Empty until finished.
    var report: String = ""
    var usageTokens: Int = 0
    var usageSplit = AgentSubagentRunner.UsageSplit()
    var roundCount: Int = 0
    var toolInvocationCount: Int = 0

    nonisolated var displayHandle: String { "agent_\(shortID)" }
    nonisolated var duration: TimeInterval {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

enum AgentSubagentError: LocalizedError {
    case missingPrompt
    case tooManyConcurrent(Int)
    case emptyStreamingText

    var errorDescription: String? {
        switch self {
        case .missingPrompt:
            return "spawn_agent requires a non-empty `prompt`."
        case .tooManyConcurrent(let limit):
            return "Too many subagents running for this session (max \(limit)). Wait for one to finish or run synchronously."
        case .emptyStreamingText:
            return "The streaming subagent finished without producing visible text."
        }
    }
}

// MARK: - Free-text streaming

/// Full token accounting from a free-text streaming turn.
///
/// This is intentionally separate from `Outcome.usageTokens`: roundtable
/// speech needs the provider's input/output/cache split for observability,
/// while old subagent callers only depend on a cumulative total.
nonisolated struct AgentSubagentStreamingUsage: Equatable, Sendable {
    var prompt = 0
    var completion = 0
    var total = 0
    var cachedPrompt: Int?
    var cacheWritePrompt: Int?
    var reasoning = 0
    var wasReported = false
}

/// Events visible to a free-text streaming caller.
///
/// Text and private reasoning are distinct cases by contract. A roundtable UI
/// should render only `textDelta`; it may retain or discard `reasoningDelta`
/// without risking thinking text leaking into the expert's visible speech.
nonisolated enum AgentSubagentStreamingTextEvent: Equatable, Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    case usage(AgentSubagentStreamingUsage)
    case finished(reason: String?)
}

nonisolated struct AgentSubagentStreamingTextOutcome: Equatable, Sendable {
    let text: String
    let reasoning: String
    let usage: AgentSubagentStreamingUsage
    let finishReason: String?
    let didFinish: Bool
}

// MARK: - Registry

/// Per-app registry of subagent runs. One instance lives on `AppState`.
/// Background runs ride a stored `Task`; completion queues the run id
/// into `pendingReports` so the parent loop can inject the report at
/// the top of its next round — the exact pattern `AgentJobRegistry`
/// uses for background shell jobs.
@MainActor
final class AgentSubagentRegistry: ObservableObject {
    typealias RunOperation = @MainActor (
        _ prompt: String,
        _ configuration: AgentConfiguration,
        _ workspaceURL: URL?,
        _ runtimeDescriptor: RuntimeDescriptor?,
        _ workspaceLocation: WorkspaceLocation?,
        _ someIMContext: SomeIMRequestContext?,
        _ outputSchema: AgentStructuredSchema?,
        _ profile: AgentSubagentProfile,
        _ interventionChannel: AgentSubagentInterventionChannel?,
        _ onProgress: ((AgentSubagentProgressUpdate) -> Void)?
    ) async throws -> AgentSubagentRunner.Outcome

    @Published private(set) var runs: [AgentSubagentRun] = []

    /// Parallel fan-out cap per parent session. Provider rate limits
    /// are the real constraint — three concurrent child loops plus the
    /// parent is already aggressive for most API plans.
    static let maxConcurrentPerRuntime = 3

    /// Finished runs older than this per runtime get evicted so a
    /// long-lived session can't grow the array without bound.
    private static let historyLimit = 20

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var interventionChannels: [UUID: AgentSubagentInterventionChannel] = [:]
    private var interventionRuntimeIDs: [UUID: UUID] = [:]
    private var pendingReports: [UUID: [UUID]] = [:]
    /// Exact parent turn that created each background run. This is narrower
    /// than `parentRuntimeID` and prevents Stop from cancelling subagents that
    /// intentionally outlived an older turn.
    private var originatingTurnIDs: [UUID: UUID] = [:]
    private var suppressedReportRunIDs: Set<UUID> = []
    /// Goal-planning runs are aggregated by their host coordinator. Their
    /// individual completions must never enter the generic parent wake queue.
    private var coordinatorOwnedRunIDs: Set<UUID> = []
    /// Injectable only so coordinator orchestration can be covered without a
    /// live provider. Production keeps the real read-only runner.
    var runOperation: RunOperation = { prompt, configuration, workspaceURL, runtimeDescriptor, workspaceLocation, someIMContext, outputSchema, profile, interventionChannel, onProgress in
        try await AgentSubagentRunner.run(
            prompt: prompt,
            configuration: configuration,
            workspaceURL: workspaceURL,
            runtimeDescriptor: runtimeDescriptor,
            workspaceLocation: workspaceLocation,
            someIMContext: someIMContext,
            outputSchema: outputSchema,
            profile: profile,
            interventionChannel: interventionChannel,
            onProgress: onProgress
        )
    }

    /// Heartbeat from a background run, tagged with the run it came from.
    ///
    /// Background runs are the case the foreground plumbing cannot cover: the
    /// spawn's tool call settles the moment it hands back a handle, so there
    /// is no live parent turn holding a sink. AppState folds these onto the
    /// originating tool-call record, which is how a Worker that outlives its
    /// turn still shows its work.
    var onRunProgress: ((UUID, AgentSubagentProgressUpdate) -> Void)?

    /// Queued/applied receipts follow the same run-id route as progress.
    var onRunIntervention: ((UUID, AgentSubagentInterventionEvent) -> Void)?

    /// Host hook fired after a run finishes and its report is queued
    /// into `pendingReports`. AppState uses it to auto-resume the parent
    /// agent loop when the run outlives the turn that spawned it —
    /// mirroring `AgentJobRegistry.onJobFinished`. Without this, a
    /// background subagent that finishes after its parent turn ended
    /// would sit unreported until the user happens to send a message.
    var onRunFinished: ((AgentSubagentRun) -> Void)?

    func activeCount(forParentRuntime runtimeID: UUID) -> Int {
        runs.filter { $0.parentRuntimeID == runtimeID && $0.status == .running }.count
    }

    func run(withID id: UUID) -> AgentSubagentRun? {
        runs.first { $0.id == id }
    }

    func isGoalPlanningRun(_ id: UUID) -> Bool {
        coordinatorOwnedRunIDs.contains(id)
    }

    func registerInterventionChannel(
        _ channel: AgentSubagentInterventionChannel,
        runID: UUID,
        parentRuntimeID: UUID
    ) {
        interventionChannels[runID] = channel
        interventionRuntimeIDs[runID] = parentRuntimeID
        channel.onEvent = { [weak self] event in
            self?.onRunIntervention?(runID, event)
        }
    }

    func unregisterInterventionChannel(runID: UUID) {
        interventionChannels[runID]?.onEvent = nil
        interventionChannels[runID] = nil
        interventionRuntimeIDs[runID] = nil
    }

    func parentRuntimeID(forInterventionRunID runID: UUID) -> UUID? {
        interventionRuntimeIDs[runID]
    }

    func canIntervene(runID: UUID) -> Bool {
        interventionChannels[runID] != nil
    }

    @discardableResult
    func submitIntervention(
        runID: UUID,
        text: String,
        mode: AgentSubagentInterventionMode
    ) throws -> AgentSubagentInterventionSubmission {
        guard let channel = interventionChannels[runID] else {
            throw AgentSubagentInterventionError.runUnavailable
        }
        return try channel.submit(text: text, mode: mode)
    }

    // MARK: Spawn (background)

    /// Start a background subagent. Returns the snapshot immediately;
    /// the report is queued for injection when the child loop ends.
    @discardableResult
    func startBackground(
        prompt: String,
        label: String,
        configuration: AgentConfiguration,
        workspaceURL: URL?,
        runtimeDescriptor: RuntimeDescriptor? = nil,
        workspaceLocation: WorkspaceLocation? = nil,
        parentRuntimeID: UUID,
        originatingTurnID: UUID? = nil,
        someIMContext: SomeIMRequestContext? = nil,
        outputSchema: AgentStructuredSchema? = nil,
        profile: AgentSubagentProfile = AgentSubagentProfileCatalog.deep,
        queuesParentReport: Bool = true
    ) throws -> AgentSubagentRun {
        guard activeCount(forParentRuntime: parentRuntimeID) < Self.maxConcurrentPerRuntime else {
            throw AgentSubagentError.tooManyConcurrent(Self.maxConcurrentPerRuntime)
        }

        let id = UUID()
        let run = AgentSubagentRun(
            id: id,
            shortID: String(id.uuidString.prefix(6)).lowercased(),
            label: label,
            prompt: prompt,
            parentRuntimeID: parentRuntimeID,
            model: configuration.model,
            startedAt: Date(),
            profileID: profile.id,
            providerID: configuration.providerID
        )
        runs.insert(run, at: 0)
        if let originatingTurnID {
            originatingTurnIDs[id] = originatingTurnID
        }
        if !queuesParentReport {
            coordinatorOwnedRunIDs.insert(id)
        }
        let interventionChannel = AgentSubagentInterventionChannel()
        registerInterventionChannel(
            interventionChannel,
            runID: id,
            parentRuntimeID: parentRuntimeID
        )
        agentSubagentLog.info(
            "background subagent queued run=\(id.uuidString, privacy: .public) parent=\(parentRuntimeID.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) model=\(configuration.model, privacy: .public) provider=\(configuration.providerID, privacy: .public) label=\(label, privacy: .public) queuesParentReport=\(queuesParentReport ? "true" : "false", privacy: .public) promptChars=\(prompt.count, privacy: .public)"
        )

        tasks[id] = Task { [weak self] in
            let outcome: AgentSubagentRunner.Outcome
            do {
                agentSubagentLog.info(
                    "background subagent started run=\(id.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) model=\(configuration.model, privacy: .public)"
                )
                outcome = try await self?.runOperation(
                    prompt,
                    configuration,
                    workspaceURL,
                    runtimeDescriptor,
                    workspaceLocation,
                    someIMContext,
                    outputSchema,
                    profile,
                    interventionChannel,
                    { [weak self] update in
                        self?.onRunProgress?(id, update)
                    }
                ) ?? AgentSubagentRunner.Outcome(
                    report: "",
                    usageTokens: 0,
                    roundCount: 0,
                    toolInvocationCount: 0
                )
            } catch is CancellationError {
                agentSubagentLog.info(
                    "background subagent cancelled run=\(id.uuidString, privacy: .public) profile=\(profile.id, privacy: .public)"
                )
                self?.finish(id: id, status: .cancelled, report: "(subagent cancelled)", profileID: profile.id)
                return
            } catch {
                agentSubagentLog.error(
                    "background subagent failed run=\(id.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) errorType=\(String(describing: type(of: error)), privacy: .public) error=\(error.localizedDescription, privacy: .private)"
                )
                self?.finish(id: id, status: .failed, report: "Subagent failed: \(error.localizedDescription)", profileID: profile.id)
                return
            }
            agentSubagentLog.info(
                "background subagent completed run=\(id.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) rounds=\(outcome.roundCount, privacy: .public) tools=\(outcome.toolInvocationCount, privacy: .public) tokens=\(outcome.usageTokens, privacy: .public) reportChars=\(outcome.report.count, privacy: .public) truncated=\(outcome.didTruncate ? "true" : "false", privacy: .public)"
            )
            self?.finish(
                id: id,
                status: .completed,
                report: outcome.report,
                usageTokens: outcome.usageTokens,
                usageSplit: outcome.usageSplit,
                roundCount: outcome.roundCount,
                toolInvocationCount: outcome.toolInvocationCount,
                rounds: outcome.rounds,
                didTruncate: outcome.didTruncate,
                profileID: profile.id
            )
        }
        return run
    }

    /// Controlled Goal Teams entry point: fixed structured output and no
    /// per-member parent report/wake. The coordinator receives completions
    /// through `onRunFinished` and wakes the parent once after arbitration.
    @discardableResult
    func startGoalPlanningBackground(
        prompt: String,
        label: String,
        configuration: AgentConfiguration,
        workspaceURL: URL?,
        runtimeDescriptor: RuntimeDescriptor? = nil,
        workspaceLocation: WorkspaceLocation? = nil,
        parentRuntimeID: UUID,
        someIMContext: SomeIMRequestContext? = nil,
        outputSchema: AgentStructuredSchema
    ) throws -> AgentSubagentRun {
        try startBackground(
            prompt: prompt,
            label: label,
            configuration: configuration,
            workspaceURL: workspaceURL,
            runtimeDescriptor: runtimeDescriptor,
            workspaceLocation: workspaceLocation,
            parentRuntimeID: parentRuntimeID,
            someIMContext: someIMContext,
            outputSchema: outputSchema,
            queuesParentReport: false
        )
    }

    func runGoalPlanningSynchronously(
        prompt: String,
        configuration: AgentConfiguration,
        workspaceURL: URL?,
        runtimeDescriptor: RuntimeDescriptor?,
        workspaceLocation: WorkspaceLocation?,
        someIMContext: SomeIMRequestContext?,
        outputSchema: AgentStructuredSchema
    ) async throws -> AgentSubagentRunner.Outcome {
        try await runOperation(
            prompt,
            configuration,
            workspaceURL,
            runtimeDescriptor,
            workspaceLocation,
            someIMContext,
            outputSchema,
            // Goal planning is a parent-owned deliberation, not a cost
            // optimization — it stays on the parent's model and tool set.
            AgentSubagentProfileCatalog.deep,
            nil,
            // Deliberately silent: goal-planning members are aggregated by
            // their coordinator and never surface as individual Workers.
            nil
        )
    }

    private func finish(
        id: UUID,
        status: AgentSubagentRun.Status,
        report: String,
        usageTokens: Int = 0,
        usageSplit: AgentSubagentRunner.UsageSplit = .init(),
        roundCount: Int = 0,
        toolInvocationCount: Int = 0,
        rounds: [AgentSubagentTranscript.Round] = [],
        didTruncate: Bool = false,
        profileID: String? = nil
    ) {
        tasks[id] = nil
        unregisterInterventionChannel(runID: id)
        // Seal the Worker's liveness before anything else. The strip and the
        // speech card key on this, not on the spawn's tool-call status, so a
        // run that ends without it would stay "in flight" forever.
        onRunProgress?(id, .runFinished)
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].status = status
        runs[index].finishedAt = Date()
        runs[index].report = report
        runs[index].usageTokens = usageTokens
        runs[index].usageSplit = usageSplit
        runs[index].roundCount = roundCount
        runs[index].toolInvocationCount = toolInvocationCount

        // Persist the inspector record before the run snapshot can be
        // evicted from `runs` by the history cap below.
        let finishedRun = runs[index]
        AppState.persistSubagentTranscript(
            AgentSubagentTranscript(
                runID: id,
                label: finishedRun.label,
                prompt: AgentSubagentTranscript.clamped(
                    finishedRun.prompt,
                    to: AgentSubagentTranscript.Limits.promptCharacters
                ).text,
                model: finishedRun.model,
                status: status,
                rounds: rounds,
                report: AgentSubagentTranscript.clamped(
                    report,
                    to: AgentSubagentTranscript.Limits.reportCharacters
                ).text,
                usageTokens: usageTokens,
                startedAt: finishedRun.startedAt,
                finishedAt: finishedRun.finishedAt,
                didTruncate: didTruncate,
                profileID: profileID
            )
        )

        let parentID = runs[index].parentRuntimeID
        let coordinatorOwned = coordinatorOwnedRunIDs.contains(id)
        let suppressReport = suppressedReportRunIDs.remove(id) != nil
        if !coordinatorOwned && !suppressReport {
            pendingReports[parentID, default: []].append(id)
        }
        agentSubagentLog.info(
            "subagent finished run=\(id.uuidString, privacy: .public) parent=\(parentID.uuidString, privacy: .public) status=\(status.rawValue, privacy: .public) profile=\(profileID ?? finishedRun.profileID, privacy: .public) durationMs=\(Int((finishedRun.finishedAt ?? Date()).timeIntervalSince(finishedRun.startedAt) * 1000), privacy: .public) rounds=\(roundCount, privacy: .public) tools=\(toolInvocationCount, privacy: .public) reportChars=\(report.count, privacy: .public) queuedForParent=\((!coordinatorOwned && !suppressReport) ? "true" : "false", privacy: .public) coordinatorOwned=\(coordinatorOwned ? "true" : "false", privacy: .public) suppressed=\(suppressReport ? "true" : "false", privacy: .public)"
        )
        evictOldFinishedRuns(forParentRuntime: parentID)
        if !suppressReport, let finished = runs.first(where: { $0.id == id }) {
            onRunFinished?(finished)
        }
    }

    // MARK: Report consumption

    /// Pull finished-but-unreported runs for a parent session. Called
    /// at the top of every agent-loop round, mirroring
    /// `AgentJobRegistry.consumePendingCompletions`.
    func consumePendingReports(forParentRuntime runtimeID: UUID) -> [AgentSubagentRun] {
        guard let ids = pendingReports.removeValue(forKey: runtimeID), !ids.isEmpty else {
            return []
        }
        let reports = ids.compactMap { id in runs.first { $0.id == id } }
        if reports.count != ids.count {
            let missing = ids.count - reports.count
            agentSubagentLog.error(
                "subagent pending reports missing snapshots parent=\(runtimeID.uuidString, privacy: .public) requested=\(ids.count, privacy: .public) missing=\(missing, privacy: .public)"
            )
        }
        agentSubagentLog.info(
            "subagent pending reports consumed parent=\(runtimeID.uuidString, privacy: .public) count=\(reports.count, privacy: .public)"
        )
        return reports
    }

    /// Non-destructive count of finished-but-unreported runs — the
    /// auto-resume path checks this before kicking a wake-up turn.
    func pendingReportCount(forParentRuntime runtimeID: UUID) -> Int {
        pendingReports[runtimeID]?.count ?? 0
    }

    /// Cancel every live subagent owned by a session. Used when the
    /// conversation is cleared or the session goes away — orphaned
    /// child loops must not keep burning tokens.
    func cancelAll(forParentRuntime runtimeID: UUID) {
        for run in runs where run.parentRuntimeID == runtimeID && run.status == .running {
            tasks[run.id]?.cancel()
        }
    }

    /// Cancel only background subagents born in the stopped turn. Returns the
    /// number signalled so the host can provide one concise acknowledgement.
    @discardableResult
    func cancelRunning(
        forParentRuntime runtimeID: UUID,
        originatingTurnID turnID: UUID,
        suppressReports: Bool = true
    ) -> Int {
        let matches = runs.filter {
            $0.parentRuntimeID == runtimeID
                && $0.status == .running
                && originatingTurnIDs[$0.id] == turnID
        }
        if suppressReports {
            suppressedReportRunIDs.formUnion(matches.map(\.id))
        }
        agentSubagentLog.info(
            "subagent cancel requested parent=\(runtimeID.uuidString, privacy: .public) turn=\(turnID.uuidString, privacy: .public) count=\(matches.count, privacy: .public) suppressReports=\(suppressReports ? "true" : "false", privacy: .public)"
        )
        for run in matches {
            tasks[run.id]?.cancel()
        }
        return matches.count
    }

    /// Retire one Goal-planning generation synchronously so a replacement
    /// generation can claim the same three per-session concurrency slots.
    /// Late task completions remain coordinator-owned and are ignored by the
    /// generation/runID check in AppState.
    func cancelGoalPlanningRuns(_ runIDs: Set<UUID>) {
        guard !runIDs.isEmpty else { return }
        for index in runs.indices where runIDs.contains(runs[index].id) && runs[index].status == .running {
            tasks[runs[index].id]?.cancel()
            runs[index].status = .cancelled
            runs[index].finishedAt = Date()
        }
    }

    private func evictOldFinishedRuns(forParentRuntime runtimeID: UUID) {
        let finished = runs.filter { $0.parentRuntimeID == runtimeID && $0.status != .running }
        guard finished.count > Self.historyLimit else { return }
        let toEvict = Set(finished.suffix(finished.count - Self.historyLimit).map(\.id))
        runs.removeAll { toEvict.contains($0.id) }
        coordinatorOwnedRunIDs.subtract(toEvict)
        for id in toEvict {
            originatingTurnIDs.removeValue(forKey: id)
            suppressedReportRunIDs.remove(id)
        }
    }
}

// MARK: - Headless runner

/// One safe, user-facing heartbeat from a headless Worker. The activity is
/// deliberately semantic rather than copied from private reasoning or command
/// text: users can see that work is moving without leaking prompts, secrets or
/// chain-of-thought into the parent transcript.
nonisolated struct AgentSubagentProgressUpdate: Equatable, Sendable {
    enum Activity: Equatable, Sendable {
        case thinking
        case retryingEmptyResponse(Int, Int)
        case runningTool(String)
        case verifying
        case preparingReport
        /// The run is over. Not a heartbeat — the closing one, so the
        /// surfaces watching this Worker can stop calling it live.
        case finished

        var displayText: String {
            switch self {
            case .finished:
                return ""
            case .thinking:
                return L10n.AgentDelegation.progressThinking
            case .retryingEmptyResponse(let attempt, let limit):
                return String(format: String(localized: "模型空响应，正在重试（%lld/%lld）", table: "WorkerArchitecture"), attempt, limit)
            case .runningTool(let toolName):
                return L10n.AgentDelegation.progressRunningTool(toolName)
            case .verifying:
                return L10n.AgentDelegation.progressVerifying
            case .preparingReport:
                return L10n.AgentDelegation.progressPreparingReport
            }
        }
    }

    let round: Int
    let maximumRounds: Int
    let completedToolInvocations: Int
    let activity: Activity
    /// The Worker's public text for this round, when it produced any.
    /// Empty on the plain heartbeats. Reasoning is never carried here —
    /// the same rule the activity labels above follow.
    let speech: String
    /// The tools this round went on to call, in order — display name plus
    /// the object each one acts on, so the card can say *which* file was
    /// read rather than only that a file was.
    let tools: [AgentSubagentToolMention]

    init(
        round: Int,
        maximumRounds: Int,
        completedToolInvocations: Int,
        activity: Activity,
        speech: String = "",
        tools: [AgentSubagentToolMention] = []
    ) {
        self.round = round
        self.maximumRounds = maximumRounds
        self.completedToolInvocations = completedToolInvocations
        self.activity = activity
        self.speech = speech
        self.tools = tools
    }

    /// The closing heartbeat. Carries no round or tool counts — whatever the
    /// surface already shows for those stays put; only liveness changes.
    static let runFinished = AgentSubagentProgressUpdate(
        round: 0,
        maximumRounds: 0,
        completedToolInvocations: 0,
        activity: .finished
    )

    var displayText: String {
        if activity == .finished { return "" }
        var parts = [L10n.AgentDelegation.progressRound(round, maximumRounds)]
        if completedToolInvocations > 0 {
            parts.append(L10n.AgentDelegation.progressCompletedTools(completedToolInvocations))
        }
        parts.append(activity.displayText)
        return parts.joined(separator: " · ")
    }
}

/// The child agent loop. It has no independent UI: bounded file writes are
/// granted at spawn, and ambiguous operations commands can only call back to
/// the parent's safety judge. Human approval remains a new parent-level
/// `ops_runner.target_command` spawn.
@MainActor
enum AgentSubagentRunner {
    static let maxRounds = 12

    /// Smart/Goal sessions may let the parent's safety judge review an
    /// otherwise unknown terminal command. A nil reviewer preserves Strict
    /// and Workspace Access semantics: the child reports the command so the
    /// parent can request an explicit `ops_runner.target_command` approval.
    typealias CommandReviewer = (_ toolName: String, _ command: String) async -> Bool

    /// The only tools a subagent may call. Deliberately excludes:
    /// `spawn_agent` (no nesting), `ask_user` (nobody to ask),
    /// MCP tools (server side effects unknowable) and background-job tools
    /// (a child shouldn't leave processes behind). `web_search` and the
    /// locally validated, GET-only `web_fetch` are read-tier so research
    /// children can follow an exact public result without an approval UI.
    static let allowedToolNames: Set<String> = [
        "search_files", "grep_files", "read_file", "list_directory",
        "git_status", "run_command", "list_skills", "read_skill",
        "web_search", "web_fetch",
    ]

    static var toolDescriptors: [AgentToolDescriptor] {
        AgentToolRegistry.all.filter { allowedToolNames.contains($0.name) }
    }

    /// The trade's tool table. This is the per-round cost that profiles
    /// exist to shrink: it is resent on every round of the child loop.
    static func toolDescriptors(
        profile: AgentSubagentProfile,
        writeAccessGranted: Bool = false,
        approvedCommandGranted: Bool = false
    ) -> [AgentToolDescriptor] {
        let permitted = profile.effectiveToolNames(
            writeAccessGranted: writeAccessGranted,
            approvedCommandGranted: approvedCommandGranted
        )
        return AgentToolRegistry.all.filter { permitted.contains($0.name) }
    }

    /// 1.85.0-rc18:虚拟工具名 —— 当 caller 传了 `outputSchema` 时,这条
    /// 工具会被追加到 sub-agent 可见的工具表里;系统提示同步优先要求模型
    /// 在答完后调它,把 JSON 字符串塞进 `data` 字段。我们这边的
    /// `executeToolCall(...)` 检测到这个 toolName 时不真的「执行」,而是
    /// 把 args["data"] 拎出来送进 `AgentStructuredSchema.validate(...)`
    /// 校验,通过即结束 loop,失败就把 issues 回 tool result 让模型重试。
    static let structuredOutputToolName = "structured_output"

    /// Prompt/completion breakdown of a child loop, summed over its rounds.
    /// Zero when the provider reported only a total (or nothing at all).
    struct UsageSplit: Equatable {
        var prompt = 0
        var completion = 0
        var cachedPrompt = 0

        var wasReported: Bool { prompt > 0 || completion > 0 }
    }

    /// One execution of a task packet's verifier command.
    ///
    /// Pass/fail is the command's exit code, never the model's opinion:
    /// `run_command` returns normally on exit 0 and throws `.commandFailed`
    /// otherwise, so there is no output text to misread.
    struct VerifierRun: Equatable {
        let passed: Bool
        let output: String
    }

    struct Outcome: Equatable {
        let report: String
        let usageTokens: Int
        /// Kept alongside the total so worker cost can be priced instead of
        /// guessed: a child loop is prompt-heavy, and output tokens cost
        /// several times what input does.
        var usageSplit = UsageSplit()
        let roundCount: Int
        let toolInvocationCount: Int
        /// Nil when the run had no verifier at all — distinct from `false`,
        /// which means the command ran and did not pass. "Not verified" must
        /// never be counted as a verified failure.
        var verifierPassed: Bool? = nil
        /// How many times the verifier ran. 0 when there was no verifier.
        var verifierAttempts: Int = 0
        /// Citations the runtime spot-checked in a report-only run, and how
        /// many of them pointed at nothing. Read-only trades never earn a
        /// verifier verdict, so without these two numbers they are invisible
        /// in the telemetry — and invisible reads as fine.
        var citationsChecked: Int = 0
        var citationsUnverifiable: Int = 0
        /// Per-round record for the subagent inspector. The runner produces
        /// the rounds; the caller owns the run identity and stamps them into
        /// an `AgentSubagentTranscript` before persisting.
        var rounds: [AgentSubagentTranscript.Round] = []
        /// True when any recorded field hit `AgentSubagentTranscript.Limits`.
        var didTruncate: Bool = false
    }

    typealias StreamingTextEventHandler = @Sendable (
        AgentSubagentStreamingTextEvent
    ) async -> Void

    /// The child's system prompt: invariant rules the runner owns, plus the
    /// trade's capability section.
    ///
    /// Prompt order matters for prefix caching — the invariant opening and
    /// the trade section are compile-time constants, so they stay ahead of
    /// the per-run workspace path.
    static func systemPrompt(
        workspaceURL: URL?,
        outputSchema: AgentStructuredSchema? = nil,
        profile: AgentSubagentProfile = AgentSubagentProfileCatalog.deep,
        writeAccess: AgentSubagentWriteAccess? = nil,
        approvedCommand: String? = nil,
        intelligentCommandReviewAvailable: Bool = false
    ) -> String {
        var lines: [String] = []
        lines.append("You are a focused subagent spawned by a coding agent to complete one task.")
        // The profile (including user-authored soul instructions) is the only
        // authority for the job section, independent of provider/model/login.
        let capabilitySection = profile.capabilityPromptSection
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !capabilitySection.isEmpty {
            lines.append(capabilitySection)
        }
        if let skills = skillPromptSection(for: profile) {
            lines.append(skills)
        }
        if let writeAccess {
            lines.append("""
            The ONLY files you may create or edit are \(writeAccess.displayList). Write calls \
            touching any other path are rejected automatically; file deletion is not allowed.
            """)
        }
        if let workspaceURL {
            lines.append("Workspace root: \(workspaceURL.path)")
        }
        if let approvedCommand,
           profile.id == AgentSubagentProfileCatalog.opsRunnerID {
            let commandEncoder = JSONEncoder()
            commandEncoder.outputFormatting = [.withoutEscapingSlashes]
            let encodedCommand = (try? commandEncoder.encode(approvedCommand))
                .flatMap { String(data: $0, encoding: .utf8) }
                ?? "\"\""
            lines.append("""
            Operator-approved command (JSON string; the decoded text must match exactly):
            \(encodedCommand)

            Rules:
            - You have READ access plus exactly one bounded mutation capability: the operator-approved command above. The host rejects every other write command and every textual variation of this one.
            - Use `terminal_send_command` only when the task says the command belongs in the visible terminal. First snapshot/select the intended tab, verify the host and `shell_ready` state, send the exact command, then snapshot the result. An active SSH tab is not interchangeable with local `run_command`.
            - Never invent or execute rollback, cleanup, force, delete, migration repair, or any second mutating command. Report those decisions to the parent.
            - You cannot ask the user anything. If the approved command cannot run safely in the specified context, stop and report the exact blocker.
            - Work autonomously until the command and read-only verification finish, then STOP calling tools and write a self-contained final report with the command, target context, and decisive output.
            """)
            return lines.joined(separator: "\n")
        }
        if writeAccess != nil {
            // The read-only rule block below is wrong for this trade, and a
            // contradicted rule is worse than no rule.
            var rules = """
            Rules:
            - You have READ access plus bounded write tools (`create_file` / `apply_patch`) carried by your trade, scoped to the files named above. Everything else is denied.
            - You cannot ask the user anything. Make reasonable assumptions and note them.
            - Read a file before patching it. Keep the change minimal and consistent with surrounding code.
            - Work autonomously until the edit is done, then STOP calling tools and write your final report as a normal message.
            - Your final message IS the deliverable returned to the parent agent. State exactly what you changed and why, and flag anything you deliberately left alone.
            """
            if intelligentCommandReviewAvailable {
                rules += "\n- Commands already classified as read-only run directly. A necessary non-destructive modifying command may be submitted once for the parent's intelligent safety review; if denied, report the exact command for human approval instead of retrying or disguising it."
            }
            lines.append(rules)
            return lines.joined(separator: "\n")
        }
        if intelligentCommandReviewAvailable {
            lines.append("""
            Rules:
            - Read-only operations run directly. You may submit one necessary, non-destructive modifying command for the parent's intelligent safety review without disguising, splitting, or rewriting it.
            - If review does not approve the command, stop retrying it and report the exact command to the parent so the parent can request explicit human approval through `ops_runner.target_command`.
            - Deterministically dangerous, destructive, credential-sensitive, rollback, cleanup, and force commands are outside model authority and must be left to the parent.
            - You cannot ask the user anything. Work autonomously until the investigation is complete, then write a self-contained final report.
            """)
            return lines.joined(separator: "\n")
        }
        if outputSchema == nil {
            lines.append("""
            Rules:
            - You have READ-ONLY access: search/grep/read/list tools, read-only shell commands, `web_search`, and GET-only `web_fetch` for public web lookups. Write operations are denied — do not attempt them; report what should be changed instead.
            - You cannot ask the user anything. Make reasonable assumptions and note them.
            - Work autonomously until the task is done, then STOP calling tools and write your final report as a normal message.
            - Your final message IS the deliverable returned to the parent agent. Make it self-contained, specific (file paths, line numbers, code excerpts), and free of filler.
            """)
        } else {
            // schema 模式:模型不要再写自由文本汇报,而是通过 structured_output
            // 工具把最终结果作为 JSON 交付。schema 同步贴出来作 contract。
            lines.append("""
            Rules:
            - You have READ-ONLY access: search/grep/read/list tools, read-only shell commands, `web_search`, and GET-only `web_fetch` for public web lookups. Write operations are denied — do not attempt them; report what should be changed instead.
            - You cannot ask the user anything. Make reasonable assumptions and note them.
            - Work autonomously until you have the answer. Then STOP calling the read-only tools.
            - **Structured output required**: prefer delivering the final answer by calling the `\(structuredOutputToolName)` tool. Its `data` argument MUST be a JSON STRING that parses into a value satisfying the schema below.
            - If the provider cannot call `\(structuredOutputToolName)`, emit only the matching raw JSON value in the normal reply, optionally inside one `json` code fence. The host applies the same schema validation to this compatibility path.
            - If an attempt fails validation, use the returned correction and try again. Do not give up — only correctly validated output reaches the parent.
            """)
            lines.append("""
            JSON Schema your `data` must satisfy:
            \(outputSchema!.renderedJSON())
            """)
        }
        return lines.joined(separator: "\n")
    }

    /// Total characters of skill text a trade may preload. A child loop's
    /// whole point is a narrow context, so the soul's skill packs are capped
    /// well below one tool result rather than allowed to fill the window.
    static let skillPreloadCharacterLimit = 12_000

    /// Inlines the trade's configured skill packs into its system prompt.
    ///
    /// Preloading rather than exposing a `read_skill` tool: a trade with a
    /// declared craft should not spend a round (and a tool schema slot)
    /// fetching it. Unknown or disabled identifiers are skipped silently —
    /// a skill uninstalled after configuration must not break the spawn.
    static func skillPromptSection(for profile: AgentSubagentProfile) -> String? {
        guard !profile.skillIdentifiers.isEmpty else { return nil }
        let available = AgentSkillDirectory.list(includeDisabled: false)
        var sections: [String] = []
        var budget = skillPreloadCharacterLimit
        for identifier in profile.skillIdentifiers {
            guard budget > 0 else { break }
            guard let record = available.first(where: {
                $0.identifier == identifier || $0.name == identifier
            }) else { continue }
            guard let data = try? Data(contentsOf: record.url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = trimmed.count > budget ? String(trimmed.prefix(budget)) + "\n...[skill truncated]" : trimmed
            budget -= min(budget, trimmed.count)
            sections.append("### Skill: \(record.identifier)\n\(body)")
        }
        guard !sections.isEmpty else { return nil }
        return """
        Skills loaded for this trade — apply them as standing instructions for this task:

        \(sections.joined(separator: "\n\n"))
        """
    }

    /// rc18:基于 caller 是否要 structured output,返回供模型选择的工具
    /// 列表。schema 路径下追加一条 `structured_output(data: string)`。
    static func toolDescriptors(includingStructuredOutput: Bool) -> [AgentToolDescriptor] {
        var descriptors = toolDescriptors
        guard includingStructuredOutput else { return descriptors }
        descriptors.append(structuredOutputDescriptor)
        return descriptors
    }

    /// Caps one tool result before it enters the child's history. Unlike the
    /// inspector's cap (storage), this one protects the model's context
    /// window, so the notice has to be legible to the model itself.
    static func clampedToolPayload(_ payload: String, limit: Int) -> String {
        guard limit > 0, payload.count > limit else { return payload }
        return String(payload.prefix(limit))
            + "\n...[tool output truncated at \(limit) characters for this subagent trade. Narrow the request — grep for a pattern, or read a specific line range.]"
    }

    static let structuredOutputDescriptor = AgentToolDescriptor(
        name: structuredOutputToolName,
        description: "Submit the final answer as a JSON string that satisfies the structured-output schema declared in the system prompt. Call this exactly once when done.",
        risk: .read,
        parameters: [
            AgentToolParameter(
                name: "data",
                type: .string,
                description: "JSON string that decodes into the required structured payload.",
                required: true
            )
        ]
    )

    /// Generate one visible, free-text answer and surface it as real provider
    /// deltas. This is the first half of the roundtable's two-stage expert
    /// turn: stream the speech here, then analyze the completed `outcome.text`
    /// with a separate structured-output call.
    ///
    /// Deliberately:
    /// - sends no tools, so there is exactly one visible model turn;
    /// - never attempts to parse partial `structured_output` arguments;
    /// - keeps reasoning separate from visible text;
    /// - propagates provider errors and cancellation unchanged;
    /// - returns usage and finish metadata even when the caller ignores events.
    ///
    /// Existing `run(...)` callers are unaffected.
    static func runStreamingText(
        prompt: String,
        systemInstruction: String,
        configuration: AgentConfiguration,
        someIMContext: SomeIMRequestContext? = nil,
        onEvent: StreamingTextEventHandler? = nil
    ) async throws -> AgentSubagentStreamingTextOutcome {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw AgentSubagentError.missingPrompt
        }
        let trimmedInstruction = systemInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedInstruction = trimmedInstruction.isEmpty
            ? "Answer the user directly in clear, visible prose."
            : trimmedInstruction
        let messages = [
            AgentMessage(role: .system, content: resolvedInstruction),
            AgentMessage(role: .user, content: trimmedPrompt),
        ]
        let configuration = AgentSubagentModelCompatibility.configuration(configuration)
        let client = AgentClient(configuration: configuration, someIMContext: someIMContext)

        return try await AgentSubagentTextStreamPipeline.run(onEvent: onEvent) { consume in
            try await client.streamChat(messages: messages, tools: [], onEvent: consume)
        }
    }

    /// Run the child loop to completion. Throws on network/provider
    /// errors and on cancellation; a round-cap exhaustion returns
    /// whatever the child said last with an explanatory note instead
    /// of throwing, so the parent still gets partial value.
    ///
    /// 1.85.0-rc18:`outputSchema` 非 nil 时进入「结构化模式」—— 模型必
    /// 须通过 `structured_output(data:)` 虚拟工具交付答案;`Outcome.report`
    /// 装的是已校验通过的 JSON 字符串(由 `WorkflowEngine.agent<T>`
    /// 再 Codable 解到 typed model)。任何一次校验失败的 `structured_output`
    /// 调用都会把 issues 当作 tool result 回灌给模型,让它在剩余轮次内
    /// 重试。最终 round cap 到了仍没成功 → 抛 `WorkflowError.structuredOutputUnavailable`。
    /// `runtimeDescriptor` + `workspaceLocation` carry the parent session's
    /// remote runtime binding. When the parent workspace is an ssh/daemon
    /// runtime these must be forwarded, otherwise the child's
    /// `AgentToolContext.remoteBackend` is nil and read-only tools run
    /// against the local Mac instead of the remote box.
    /// `onProgress` reports round changes plus safe semantic activity before
    /// every potentially long provider, tool and verifier operation. The
    /// synchronous `spawn_agent` path appends it after the Worker name so a
    /// long child loop never looks frozen. Background / workflow callers leave
    /// it nil.
    @MainActor
    static func run(
        prompt: String,
        configuration: AgentConfiguration,
        workspaceURL: URL?,
        /// The parent's other authorized folders, handed down verbatim. See
        /// `executeToolCall` — the child's boundary is the folder set the user
        /// authorized, not whichever one happens to be primary.
        additionalWorkspaceRoots: [URL] = [],
        runtimeDescriptor: RuntimeDescriptor? = nil,
        workspaceLocation: WorkspaceLocation? = nil,
        someIMContext: SomeIMRequestContext? = nil,
        outputSchema: AgentStructuredSchema? = nil,
        profile: AgentSubagentProfile = AgentSubagentProfileCatalog.deep,
        writeAccess: AgentSubagentWriteAccess? = nil,
        /// Command that decides whether this run succeeded. When present the
        /// worker's own "done" is never accepted on its word.
        verifierCommand: String? = nil,
        verifierMaxAttempts: Int = AgentSubagentTaskPacket.defaultMaxAttempts,
        patchProposalSink: (@MainActor (String?, String, Bool, URL) async throws -> AgentPatchProposal)? = nil,
        /// terminal_operator 与带 target_command 的 ops_runner 需要：把父
        /// 会话的侧栏终端 controller 递给子循环，terminal_* 工具才有执行
        /// 对象。其余工种传了也会在 executeToolCall 里被丢弃。
        terminalController: AgentInteractiveTerminalController? = nil,
        /// 单命令授权（仅 ops_runner）：用户在 spawn 审批卡上批准的那条
        /// 确切命令。子循环里恰好等于这条文本的 run_command 或
        /// terminal_send_command 可以越过"只许 read"的死门执行——
        /// 语义上等同用户在主会话批准了这条命令，
        /// 爆炸半径恰好一条。可重复执行（发布脚本按部署规范应幂等），
        /// verifier 循环靠这一点重试。
        approvedCommand: String? = nil,
        commandReviewer: CommandReviewer? = nil,
        interventionChannel: AgentSubagentInterventionChannel? = nil,
        onProgress: ((AgentSubagentProgressUpdate) -> Void)? = nil
    ) async throws -> Outcome {
        // some.im-gated providers require the session/workspace context headers on
        // every request; without them some.im rejects/stalls the call. Workflow
        // subagents used to omit this (unlike the main loop), so a `/code-review`
        // on a some.im model hung as an empty card. Forward it here.
        let configuration = AgentSubagentModelCompatibility.configuration(configuration)
        let client = AgentClient(configuration: configuration, someIMContext: someIMContext)
        var transcript: [AgentMessage] = [
            AgentMessage(
                role: .system,
                content: systemPrompt(
                    workspaceURL: workspaceURL,
                    outputSchema: outputSchema,
                    profile: profile,
                    writeAccess: writeAccess,
                    approvedCommand: approvedCommand,
                    // 严格只读工种没有这条通道（见执行闸门处的说明），提示词
                    // 就不能许诺它。提示词说"可以送审"而闸门一律拒绝，模型
                    // 会把每条被拒的命令当成偶发故障反复重试。
                    intelligentCommandReviewAvailable: commandReviewer != nil
                        && !AgentSubagentProfileCatalog
                            .strictReadOnlyShellTradeIDs.contains(profile.id)
                )
            ),
            AgentMessage(role: .user, content: prompt),
        ]
        var totalTokens = 0
        var usageSplit = UsageSplit()
        var toolInvocations = 0
        var verifierAttempts = 0
        var verifierPassed: Bool?

        // A run with a verifier is judged by its exit code; a report-only run
        // has nothing to judge it, so the runtime checks what the report
        // cites. Structured output is exempt: the payload has to stay
        // schema-valid, and an appended note would break it.
        let auditCitations: (String) -> AgentSubagentCitationAudit.Result = { report in
            guard verifierCommand == nil, outputSchema == nil else {
                return AgentSubagentCitationAudit.Result()
            }
            return AgentSubagentCitationAudit.audit(
                report: report,
                workspaceURL: workspaceURL
            )
        }
        let annotate: (String, AgentSubagentCitationAudit.Result) -> String = { report, audit in
            guard let note = audit.note else { return report }
            return "\(report)\n\n\(note)"
        }
        // The trade's narrowed tool table — resent every round, so this is
        // where a cheap profile earns most of its savings.
        var toolList = toolDescriptors(
            profile: profile,
            writeAccessGranted: writeAccess != nil,
            approvedCommandGranted: approvedCommand != nil
        )
        if outputSchema != nil {
            toolList.append(structuredOutputDescriptor)
        }
        // This begins at the profile budget, but a user instruction accepted
        // at the final boundary must still receive one real provider round.
        // Extending only when an instruction is actually applied preserves
        // the ordinary Worker budget while preventing a late correction from
        // being acknowledged in the UI and then silently dropped.
        var roundLimit = max(1, profile.maxRounds)
        // Inspector record, built alongside the provider-facing transcript.
        // Kept separate because this one is capped, keeps per-call timings,
        // and drops the system prompt.
        var recordedRounds: [AgentSubagentTranscript.Round] = []
        var didTruncateRecord = false

        func publishProgress(
            round: Int,
            activity: AgentSubagentProgressUpdate.Activity,
            speech: String = "",
            tools: [AgentSubagentToolMention] = []
        ) {
            onProgress?(
                AgentSubagentProgressUpdate(
                    round: round,
                    maximumRounds: roundLimit,
                    completedToolInvocations: toolInvocations,
                    activity: activity,
                    speech: speech,
                    tools: tools
                )
            )
        }

        @discardableResult
        func applyPendingInterventions(effectiveRound: Int) -> Bool {
            guard let interventionChannel else { return false }
            let submissions = interventionChannel.drainPending(
                effectiveRound: effectiveRound
            )
            guard !submissions.isEmpty else { return false }
            roundLimit = max(roundLimit, effectiveRound)
            transcript.append(AgentMessage(
                role: .user,
                content: interventionMessage(submissions)
            ))
            return true
        }

        var round = 1
        let inputLimit = AgentWorkerContextBudget.inputLimit(
            profile: profile, configuration: configuration,
            models: AgentProfileStore().workerTierModels()
        )
        while round <= roundLimit {
            defer { round += 1 }
            interventionChannel?.beginRound(round)
            _ = applyPendingInterventions(effectiveRound: round)
            // Surface the provider wait before the (potentially long)
            // streaming round begins. Never mirror private reasoning text.
            publishProgress(round: round, activity: .thinking)
            let roundStartedAt = Date()
            var content = ""
            var reasoning = ""
            var toolCalls: [AgentMessageToolCall] = []
            let collector = SubagentTurnCollector()

            try AgentWorkerContextBudget.validate(messages: transcript, tools: toolList, limit: inputLimit)

            do {
                if let interventionChannel {
                    try await interventionChannel.runCancellableStep {
                        try await client.streamChat(
                            messages: transcript,
                            tools: toolList,
                            onEmptyResponseRetry: { attempt, limit in
                                publishProgress(round: round, activity: .retryingEmptyResponse(attempt, limit))
                            }
                        ) { event in
                            await collector.consume(event)
                        }
                    }
                } else {
                    try await client.streamChat(
                        messages: transcript,
                        tools: toolList,
                        onEmptyResponseRetry: { attempt, limit in
                            publishProgress(round: round, activity: .retryingEmptyResponse(attempt, limit))
                        }
                    ) { event in
                        await collector.consume(event)
                    }
                }
            } catch is CancellationError {
                guard interventionChannel?.hasPendingInterruption == true else {
                    throw CancellationError()
                }
                _ = applyPendingInterventions(effectiveRound: round + 1)
                continue
            }
            let turn = await collector.snapshot()
            content = turn.content
            reasoning = turn.reasoning
            toolCalls = turn.toolCalls
            totalTokens += turn.usageTokens
            usageSplit.prompt += turn.promptTokens
            usageSplit.completion += turn.completionTokens
            usageSplit.cachedPrompt += turn.cachedPromptTokens

            transcript.append(AgentMessage(
                role: .assistant,
                content: content,
                reasoningContent: reasoning.isEmpty ? nil : reasoning,
                toolCalls: toolCalls
            ))

            // The round's public text, published as its own heartbeat so the
            // parent's delegation card can show the Worker talking instead of
            // holding everything back until the final report. Emitted once per
            // completed round rather than per token: streaming rich text into
            // the transcript is the shape that previously pinned the main
            // thread in SwiftUI layout, and a round's text is already whole.
            let roundTools = toolCalls.map { call in
                AgentSubagentToolMention(
                    name: AgentToolDisplay.name(for: call.toolName),
                    object: AgentToolDisplay.objectSummary(
                        toolName: call.toolName,
                        argumentsJSON: call.argumentsJSON
                    )
                )
            }
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !roundTools.isEmpty {
                publishProgress(
                    round: round,
                    activity: roundTools.isEmpty
                        ? .preparingReport
                        : .runningTool(roundTools[0].name),
                    speech: content,
                    tools: roundTools
                )
            }

            let clampedContent = AgentSubagentTranscript.clamped(
                content,
                to: AgentSubagentTranscript.Limits.roundContentCharacters
            )
            let clampedReasoning = AgentSubagentTranscript.clamped(
                reasoning,
                to: AgentSubagentTranscript.Limits.roundContentCharacters
            )
            didTruncateRecord = didTruncateRecord
                || clampedContent.didTruncate
                || clampedReasoning.didTruncate
            var recordedRound = AgentSubagentTranscript.Round(
                index: round,
                content: clampedContent.text,
                // Only what the provider actually emitted as visible
                // reasoning — never a reconstructed chain of thought.
                reasoning: reasoning.isEmpty ? nil : clampedReasoning.text,
                toolCalls: [],
                usageTokens: turn.usageTokens,
                startedAt: roundStartedAt,
                finishedAt: nil
            )
            /// Closes the in-progress round so an early `return` still records it.
            func sealingRound() -> [AgentSubagentTranscript.Round] {
                var sealed = recordedRound
                sealed.finishedAt = Date()
                return recordedRounds + [sealed]
            }
            func recordToolCall(
                _ call: AgentMessageToolCall,
                payload: String,
                startedAt: Date
            ) {
                let clampedResult = AgentSubagentTranscript.clamped(
                    payload,
                    to: AgentSubagentTranscript.Limits.toolResultCharacters
                )
                didTruncateRecord = didTruncateRecord || clampedResult.didTruncate
                recordedRound.toolCalls.append(
                    AgentSubagentTranscript.ToolCall(
                        externalID: call.externalID,
                        name: call.toolName,
                        argumentsJSON: call.argumentsJSON,
                        result: clampedResult.text,
                        resultWasTruncated: clampedResult.didTruncate,
                        durationSeconds: Date().timeIntervalSince(startedAt)
                    )
                )
            }

            // An interrupt may arrive in the tiny boundary after the provider
            // completed but before its proposed tools started. Close every
            // emitted tool call with a synthetic result so the next provider
            // request remains protocol-valid, then follow the user's route.
            if interventionChannel?.hasPendingInterruption == true {
                for call in toolCalls {
                    let payload = "Skipped because the user interrupted this Worker step before the tool started."
                    let callStartedAt = Date()
                    transcript.append(AgentMessage(
                        role: .tool,
                        content: payload,
                        toolCallID: call.externalID
                    ))
                    recordToolCall(call, payload: payload, startedAt: callStartedAt)
                }
                _ = applyPendingInterventions(effectiveRound: round + 1)
                recordedRound.finishedAt = Date()
                recordedRounds.append(recordedRound)
                continue
            }

            // schema 模式下:本轮里若已经成功调过 structured_output,
            // 立即结束 loop —— 别等模型再吐自由文本。
            if let outputSchema {
                for call in toolCalls where call.toolName == structuredOutputToolName {
                    try Task.checkCancellation()
                    publishProgress(round: round, activity: .preparingReport)
                    toolInvocations += 1
                    let callStartedAt = Date()
                    let (ok, payload) = handleStructuredOutputCall(call, schema: outputSchema)
                    transcript.append(AgentMessage(
                        role: .tool,
                        content: payload,
                        toolCallID: call.externalID
                    ))
                    recordToolCall(call, payload: payload, startedAt: callStartedAt)
                    // A queued user correction outranks a would-be final
                    // structured result. Finish this tool step so the
                    // transcript stays protocol-valid, then the common
                    // boundary below injects the correction into a new round.
                    if ok, interventionChannel?.hasPendingSubmission != true {
                        return Outcome(
                            report: payload,
                            usageTokens: totalTokens,
                            usageSplit: usageSplit,
                            roundCount: round,
                            toolInvocationCount: toolInvocations,
                            verifierPassed: verifierPassed,
                            verifierAttempts: verifierAttempts,
                            rounds: sealingRound(),
                            didTruncate: didTruncateRecord
                        )
                    }
                }
            }

            // 没有任何工具调用 → free-text 模式正常退出。schema 模式先
            // 接受通过同一 schema 校验的纯 JSON / JSON fence；这兼容不
            // 支持自定义 tool call 的 OpenAI-compatible provider。无效
            // 文本会收到纠正回合，而不是第一轮就把整个 Goal Team 判死。
            if toolCalls.isEmpty {
                let report = content.trimmingCharacters(in: .whitespacesAndNewlines)

                // A normal intervention received during the provider step is
                // the next round, even if the Worker was about to declare
                // itself done. Give the user's correction the final word.
                if interventionChannel?.hasPendingSubmission == true {
                    _ = applyPendingInterventions(effectiveRound: round + 1)
                    recordedRound.finishedAt = Date()
                    recordedRounds.append(recordedRound)
                    continue
                }

                // The worker says it is finished. With a verifier configured,
                // that claim is not the verdict — the command is. Run it here
                // rather than trusting the report, because "I fixed it" is
                // exactly the sentence a stuck small model produces.
                if let verifierCommand, verifierPassed != true {
                    publishProgress(round: round, activity: .verifying)
                    let verification = await runVerifier(
                        command: verifierCommand,
                        workspaceURL: workspaceURL,
                        additionalWorkspaceRoots: additionalWorkspaceRoots,
                        runtimeDescriptor: runtimeDescriptor,
                        workspaceLocation: workspaceLocation
                    )
                    verifierAttempts += 1
                    verifierPassed = verification.passed

                    if !verification.passed, verifierAttempts < verifierMaxAttempts {
                        transcript.append(AgentMessage(
                            role: .user,
                            content: verifierRetryMessage(
                                command: verifierCommand,
                                output: verification.output,
                                attempt: verifierAttempts,
                                maxAttempts: verifierMaxAttempts,
                                payloadLimit: profile.toolPayloadCharacterLimit
                            )
                        ))
                        recordedRound.finishedAt = Date()
                        recordedRounds.append(recordedRound)
                        continue
                    }

                    if !verification.passed {
                        // Attempts exhausted: report the failure honestly and
                        // hand the caller the evidence. A wrong "done" here
                        // would poison every KPI built on this field.
                        let clamped = AgentSubagentTranscript.clamped(
                            verification.output,
                            to: profile.toolPayloadCharacterLimit
                        )
                        return Outcome(
                            report: """
                            [Verifier still failing after \(verifierAttempts) attempt\(verifierAttempts == 1 ? "" : "s"). \
                            `\(verifierCommand)` did not exit 0.]

                            \(report)

                            Last verifier output:
                            \(clamped.text)
                            """,
                            usageTokens: totalTokens,
                            usageSplit: usageSplit,
                            roundCount: round,
                            toolInvocationCount: toolInvocations,
                            verifierPassed: false,
                            verifierAttempts: verifierAttempts,
                            rounds: sealingRound(),
                            didTruncate: didTruncateRecord
                        )
                    }
                }

                if let outputSchema {
                    if let fallback = validatedStructuredOutputFallback(
                        in: report,
                        schema: outputSchema
                    ) {
                        return Outcome(
                            report: fallback,
                            usageTokens: totalTokens,
                            usageSplit: usageSplit,
                            roundCount: round,
                            toolInvocationCount: toolInvocations,
                            verifierPassed: verifierPassed,
                            verifierAttempts: verifierAttempts,
                            rounds: sealingRound(),
                            didTruncate: didTruncateRecord
                        )
                    }
                    transcript.append(AgentMessage(
                        role: .user,
                        content: "Your previous reply did not produce schema-valid JSON. Call `\(structuredOutputToolName)` now, or return only one raw JSON value matching the declared schema. Do not add explanation."
                    ))
                    recordedRound.finishedAt = Date()
                    recordedRounds.append(recordedRound)
                    continue
                }
                let finalReport = report.isEmpty
                    ? "(subagent finished without producing a report)"
                    : report
                publishProgress(round: round, activity: .preparingReport)
                let audit = auditCitations(finalReport)
                return Outcome(
                    report: annotate(finalReport, audit),
                    usageTokens: totalTokens,
                    usageSplit: usageSplit,
                    roundCount: round,
                    toolInvocationCount: toolInvocations,
                    verifierPassed: verifierPassed,
                    verifierAttempts: verifierAttempts,
                    citationsChecked: audit.checked,
                    citationsUnverifiable: audit.unverifiable.count,
                    rounds: sealingRound(),
                    didTruncate: didTruncateRecord
                )
            }

            // 普通工具(read-only / web_search / web_fetch 等)走原路径。schema 模式
            // 下,structured_output 已经在前面拎走处理,这里只剩别的。
            let executableCalls = toolCalls.filter {
                $0.toolName != structuredOutputToolName
            }
            var toolStepWasInterrupted = false
            for (callIndex, call) in executableCalls.enumerated() {
                try Task.checkCancellation()
                publishProgress(
                    round: round,
                    activity: .runningTool(AgentToolDisplay.name(for: call.toolName))
                )
                toolInvocations += 1
                let callStartedAt = Date()
                let rawPayload: String
                do {
                    if let interventionChannel {
                        rawPayload = try await interventionChannel.runCancellableStep {
                            await executeToolCall(
                                call,
                                workspaceURL: workspaceURL,
                                additionalWorkspaceRoots: additionalWorkspaceRoots,
                                runtimeDescriptor: runtimeDescriptor,
                                workspaceLocation: workspaceLocation,
                                profile: profile,
                                writeAccess: writeAccess,
                                terminalController: terminalController,
                                approvedCommand: approvedCommand,
                                commandReviewer: commandReviewer,
                                patchProposalSink: patchProposalSink
                            )
                        }
                    } else {
                        rawPayload = await executeToolCall(
                            call,
                            workspaceURL: workspaceURL,
                            additionalWorkspaceRoots: additionalWorkspaceRoots,
                            runtimeDescriptor: runtimeDescriptor,
                            workspaceLocation: workspaceLocation,
                            profile: profile,
                            writeAccess: writeAccess,
                            terminalController: terminalController,
                            approvedCommand: approvedCommand,
                            commandReviewer: commandReviewer,
                            patchProposalSink: patchProposalSink
                        )
                    }
                } catch is CancellationError {
                    guard interventionChannel?.hasPendingInterruption == true else {
                        throw CancellationError()
                    }
                    rawPayload = "Interrupted by the user's new instruction before this tool completed."
                }

                if interventionChannel?.hasPendingInterruption == true {
                    transcript.append(AgentMessage(
                        role: .tool,
                        content: rawPayload,
                        toolCallID: call.externalID
                    ))
                    recordToolCall(call, payload: rawPayload, startedAt: callStartedAt)
                    for remaining in executableCalls.dropFirst(callIndex + 1) {
                        let payload = "Skipped because the user interrupted the preceding Worker step."
                        let skippedAt = Date()
                        transcript.append(AgentMessage(
                            role: .tool,
                            content: payload,
                            toolCallID: remaining.externalID
                        ))
                        recordToolCall(remaining, payload: payload, startedAt: skippedAt)
                    }
                    _ = applyPendingInterventions(effectiveRound: round + 1)
                    toolStepWasInterrupted = true
                    break
                }
                // Budgeted per trade: a 128K-window child cannot afford the
                // same tool payloads a 1M-window parent shrugs off.
                let payload = clampedToolPayload(
                    rawPayload,
                    limit: profile.toolPayloadCharacterLimit
                )
                transcript.append(AgentMessage(
                    role: .tool,
                    content: payload,
                    toolCallID: call.externalID
                ))
                recordToolCall(call, payload: payload, startedAt: callStartedAt)
            }
            recordedRound.finishedAt = Date()
            recordedRounds.append(recordedRound)
            if toolStepWasInterrupted {
                continue
            }
            // Normally the next loop head drains a queued instruction. At
            // the configured final round there would be no next head, so do
            // it at this safe tool boundary and extend `roundLimit` before
            // evaluating the while condition.
            if interventionChannel?.hasPendingSubmission == true {
                _ = applyPendingInterventions(effectiveRound: round + 1)
                continue
            }
        }

        // schema 模式下 round cap 到了 = 没有合规的结构化答案;别给
        // caller 返回半成品。
        if outputSchema != nil {
            throw WorkflowError.structuredOutputUnavailable(
                reason: "Subagent exhausted \(roundLimit) rounds without producing valid structured output."
            )
        }

        // Free-text 模式 round cap 到了 — return partial value rather than
        // throwing away every token the child already spent.
        //
        // Run the verifier once even here: a worker can run out of rounds
        // narrating after the change already landed, and "did the tests pass"
        // is worth one command before we call the run a loss.
        if let verifierCommand, verifierPassed == nil {
            publishProgress(round: roundLimit, activity: .verifying)
            let verification = await runVerifier(
                command: verifierCommand,
                workspaceURL: workspaceURL,
                additionalWorkspaceRoots: additionalWorkspaceRoots,
                runtimeDescriptor: runtimeDescriptor,
                workspaceLocation: workspaceLocation
            )
            verifierAttempts += 1
            verifierPassed = verification.passed
        }
        let lastText = transcript.last(where: { $0.role == .assistant && !$0.content.isEmpty })?.content ?? ""
        let note = "[Subagent stopped after \(roundLimit) tool rounds without a final report. Last progress shown below.]"
        let cappedReport = lastText.isEmpty ? note : "\(note)\n\n\(lastText)"
        let cappedAudit = auditCitations(cappedReport)
        return Outcome(
            report: annotate(cappedReport, cappedAudit),
            usageTokens: totalTokens,
            usageSplit: usageSplit,
            roundCount: roundLimit,
            toolInvocationCount: toolInvocations,
            verifierPassed: verifierPassed,
            verifierAttempts: verifierAttempts,
            citationsChecked: cappedAudit.checked,
            citationsUnverifiable: cappedAudit.unverifiable.count,
            rounds: recordedRounds,
            didTruncate: didTruncateRecord
        )
    }

    /// Provider-facing wrapper for one or more user corrections. The wrapper
    /// is deliberately short and carries the user's exact visible text; no
    /// private reasoning or hidden command context is reconstructed here.
    static func interventionMessage(
        _ submissions: [AgentSubagentInterventionSubmission]
    ) -> String {
        let instructions = submissions.enumerated().map { index, submission in
            let mode = submission.mode == .interruptCurrentStep
                ? "interrupt"
                : "next-round"
            return "\(index + 1). [\(mode)] \(submission.text)"
        }
        return """
        The user redirected this Worker while it was running. Treat the following text as the newest user instruction, adjust the route immediately, and do not repeat the abandoned step unless the instruction asks for it.

        \(instructions.joined(separator: "\n"))
        """
    }

    /// Provider compatibility path for structured output. Some compatible
    /// gateways expose tools in the request but still return the requested
    /// payload as ordinary text. Accept only an exact JSON value or one JSON
    /// code fence, and always run the identical schema validator.
    static func validatedStructuredOutputFallback(
        in content: String,
        schema: AgentStructuredSchema
    ) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidates = [trimmed]
        let fencePattern = #"```(?:json)?\s*([\s\S]*?)```"#
        if let expression = try? NSRegularExpression(
            pattern: fencePattern,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            for match in expression.matches(in: trimmed, range: range) {
                guard match.numberOfRanges > 1,
                      let matchRange = Range(match.range(at: 1), in: trimmed) else { continue }
                candidates.append(
                    String(trimmed[matchRange])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let value = try? AgentJSONValue.decode(from: data),
                  schema.validate(value).isEmpty else { continue }
            return candidate
        }
        return nil
    }

    /// rc18:把 `structured_output(data: ...)` 调用里那个 data 字符串拎出
    /// 来,解析成 JSON,跑 schema validate。
    ///   - 成功:返回 (true, "<已 trim 的 JSON 字符串>"),caller 退出 loop。
    ///   - 失败:返回 (false, "<给模型读的中文/英文混合错误说明>"),
    ///     这条说明会作为 tool result 进 transcript,模型下一轮重试。
    /// 不抛错 —— validate fail 是预期路径,要让模型自己接住改正,而不是
    /// 让整个 sub-agent 死掉。
    private static func handleStructuredOutputCall(
        _ call: AgentMessageToolCall,
        schema: AgentStructuredSchema
    ) -> (Bool, String) {
        // call.argumentsJSON 是 provider 回的原始 JSON 字符串(形如
        // `{"data":"...escaped json..."}`);先用 AgentJSONValue.decode 解
        // 成 dict,再拎 data 字段。模型可能把 data 直接当对象塞进来(没
        // 当字符串)—— 兜底:如果不是 string,就把整个 data 子对象 re-
        // serialize 回 JSON 字符串当成 caller 的答案,体验更顺。
        let parsed = AgentJSONValue.decode(from: call.argumentsJSON)
        guard case .object(let argDict) = parsed else {
            return (false, "structured_output: invalid arguments wrapper, expected an object with a `data` field. Got: \(call.argumentsJSON.prefix(120))")
        }
        guard let dataField = argDict["data"] else {
            return (false, "structured_output: missing `data` argument. Call again with `{\"data\": \"<json string>\"}`.")
        }
        let trimmed: String
        switch dataField {
        case .string(let s):
            trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            // 模型把 data 当成结构对象塞进来。容忍一下:re-serialize 回字符串。
            if let json = try? JSONSerialization.data(withJSONObject: dataField.rawAny, options: [.fragmentsAllowed, .sortedKeys]),
               let str = String(data: json, encoding: .utf8) {
                trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                return (false, "structured_output: `data` could not be serialized. Pass it as a JSON STRING value.")
            }
        }
        guard !trimmed.isEmpty else {
            return (false, "structured_output: `data` was empty. Call again with a non-empty JSON string matching the schema.")
        }
        let value = AgentJSONValue.decode(from: trimmed)
        let issues = schema.validate(value)
        guard issues.isEmpty else {
            let bulletted = issues.prefix(8).map { "- \($0)" }.joined(separator: "\n")
            return (false, "structured_output: validation failed. Fix the following and call again:\n\(bulletted)")
        }
        return (true, trimmed)
    }

    /// Whether `command` clears the deterministic read-tier bar on its own.
    ///
    /// Not the whole gate: a verifier that writes (a build emitting objects, a
    /// test writing fixtures) is still a legitimate verdict, so the spawn site
    /// sends anything that fails this check to the security-guard judge rather
    /// than refusing it. What must never happen is a verifier running
    /// unattended with no gate at all.
    static func verifierCommandIsReadTier(_ command: String, workspaceURL: URL?) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string(trimmed)],
            rootDirectory: workspaceURL
        ) == .read
    }

    /// Run a task packet's verifier command and report the verdict.
    ///
    /// Deliberately not a tool the worker calls: if the model owned the
    /// verification step it could skip it, misread it, or claim it ran. Here
    /// the runner runs it, and the exit code is the whole judgement.
    static func runVerifier(
        command: String,
        workspaceURL: URL?,
        additionalWorkspaceRoots: [URL] = [],
        runtimeDescriptor: RuntimeDescriptor? = nil,
        workspaceLocation: WorkspaceLocation? = nil
    ) async -> VerifierRun {
        let context = AgentToolContext(
            rootDirectory: workspaceURL,
            additionalWorkspaceRoots: additionalWorkspaceRoots,
            workspaceLocation: workspaceLocation,
            runtimeDescriptor: runtimeDescriptor
        )
        do {
            let result = try await AgentToolRunner.run(
                name: "run_command",
                arguments: ["command": .string(command)],
                context: context
            )
            return VerifierRun(passed: true, output: result.payload)
        } catch let error as AgentToolError {
            if case .commandFailed(_, let output) = error {
                return VerifierRun(passed: false, output: output)
            }
            return VerifierRun(passed: false, output: error.localizedDescription)
        } catch {
            return VerifierRun(passed: false, output: error.localizedDescription)
        }
    }

    /// The failure text handed back to the worker between attempts. Trimmed to
    /// the trade's payload budget so a 200-line build log cannot eat the
    /// window the fix itself needs.
    nonisolated static func verifierRetryMessage(
        command: String,
        output: String,
        attempt: Int,
        maxAttempts: Int,
        payloadLimit: Int
    ) -> String {
        let clamped = AgentSubagentTranscript.clamped(output, to: payloadLimit)
        let truncationNote = clamped.didTruncate ? "\n… (output truncated)" : ""
        return """
        The verifier failed (attempt \(attempt) of \(maxAttempts)).

        `\(command)` did not exit 0:
        \(clamped.text)\(truncationNote)

        You are not done. Read the failure, refine your hypothesis, and fix the \
        cause — do not repeat an attempt you already made, and do not weaken the \
        check to make it pass. If you now believe the fix belongs outside the \
        files you may edit, stop and say so instead of guessing.
        """
    }

    /// 单命令授权的匹配规则：修剪首尾空白后的**精确相等**。刻意不做
    /// 前缀/家族匹配——用户批准的是一条命令，不是一类命令。
    nonisolated static func approvedCommandMatches(_ candidate: String, approved: String) -> Bool {
        candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            == approved.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only ambiguous, non-sensitive terminal commands may reach the AI
    /// judge. Deterministically dangerous or typed-confirmation operations
    /// remain outside model authority and must be approved by the operator as
    /// an exact `ops_runner.target_command` on a new spawn.
    /// Whether a Worker's command may be resolved by the parent's approval
    /// ladder instead of a human approval card.
    ///
    /// The ladder itself is the user's `approvalMode` and lives in the
    /// parent; this only answers whether to consult it:
    ///
    ///  - **Strict** means "ask me every time", so nothing is consulted —
    ///    consulting would answer on the user's behalf.
    ///  - **Full Access** consults for everything. The user has already
    ///    granted that level to the parent; a Worker running the same
    ///    command is not a second decision, and the deterministic malicious
    ///    denylist remains the hard floor on the parent side.
    ///  - Everything else keeps the narrower floor below: a command needing
    ///    typed confirmation, or one touching credentials, is never put to
    ///    the judge. A terminal is the user's real shell and seatbelt does
    ///    not reach it.
    nonisolated static func subagentCommandMayBeReviewedByParent(
        _ command: String,
        approvalMode: AgentApprovalMode,
        workspaceURL: URL?,
        additionalWorkspaceRoots: [URL] = []
    ) -> Bool {
        switch approvalMode {
        case .requestEveryTime:
            return false
        case .fullAccess:
            return true
        case .smart, .workspaceAccess:
            return subagentCommandCanUseIntelligentReview(
                command,
                workspaceURL: workspaceURL,
                additionalWorkspaceRoots: additionalWorkspaceRoots
            )
        }
    }

    nonisolated static func subagentCommandCanUseIntelligentReview(
        _ command: String,
        workspaceURL: URL?,
        additionalWorkspaceRoots: [URL] = []
    ) -> Bool {
        let decision = AgentSandboxPolicy.commandDecision(
            command: command,
            rootDirectory: workspaceURL,
            additionalWorkspaceRoots: additionalWorkspaceRoots
        )
        guard !decision.requiresTypedConfirmation,
              !decision.credentialSensitive else { return false }
        return SafeCommand.classify(command: command) == .needsJudgment
    }

    private static func executeToolCall(
        _ call: AgentMessageToolCall,
        workspaceURL: URL?,
        /// The parent's other authorized folders. A child used to be handed
        /// only `workspaceURL`, so every tool it called measured paths against
        /// one root: in a multi-folder project the parent could read the second
        /// folder and its own worker could not, which reads as the subagent
        /// being broken rather than as a boundary. The boundary is the set the
        /// user authorized, and the child gets the same set.
        additionalWorkspaceRoots: [URL] = [],
        runtimeDescriptor: RuntimeDescriptor? = nil,
        workspaceLocation: WorkspaceLocation? = nil,
        profile: AgentSubagentProfile = AgentSubagentProfileCatalog.deep,
        writeAccess: AgentSubagentWriteAccess? = nil,
        terminalController: AgentInteractiveTerminalController? = nil,
        approvedCommand: String? = nil,
        commandReviewer: CommandReviewer? = nil,
        patchProposalSink: (@MainActor (String?, String, Bool, URL) async throws -> AgentPatchProposal)? = nil
    ) async -> String {
        let permitted = profile.effectiveToolNames(
            writeAccessGranted: writeAccess != nil,
            approvedCommandGranted: approvedCommand != nil
        )
        guard permitted.contains(call.toolName) else {
            // A narrow trade being asked for a tool it does not carry is a
            // routing mistake, not a capability gap — tell the parent how to
            // fix it instead of leaving it to guess.
            let available = permitted.sorted().joined(separator: ", ")
            let redirect = profile.id == AgentSubagentProfileCatalog.deepID
                ? ""
                : " If this task genuinely needs `\(call.toolName)`, the parent should re-spawn with `profile=\"deep\"`."
            return "Denied: tool `\(call.toolName)` is not available to the `\(profile.id)` subagent trade. Available tools: \(available).\(redirect)"
        }

        // The writing trades' exact file-set lock. These tools are the only
        // way a child can mutate anything, so the path check lives on the
        // execution path rather than in the prompt.
        if let writeAccess, AgentSubagentProfileCatalog.writeToolNames.contains(call.toolName) {
            if let violation = writeAccess.violationMessage(
                forToolName: call.toolName,
                argumentsJSON: call.argumentsJSON,
                workspaceURL: workspaceURL
            ) {
                return violation
            }
        }

        var argsDict: [String: AgentJSONValue] = [:]
        if !call.argumentsJSON.isEmpty {
            guard case .object(let dict) = AgentJSONValue.decode(from: call.argumentsJSON) else {
                return "Tool arguments JSON could not be parsed; re-emit the call with valid JSON."
            }
            argsDict = dict
        }
        // No job registry down here — background execution is a parent-
        // session capability. Force the foreground path.
        argsDict["run_in_background"] = nil

        let risk = AgentToolRegistry.risk(
            for: call.toolName,
            arguments: argsDict,
            rootDirectory: workspaceURL,
            additionalWorkspaceRoots: additionalWorkspaceRoots
        )
        // Writing trades carry bounded tools backed by an exact workspace
        // capability. Everything else stays read-only.
        let isApprovedWrite = writeAccess != nil
            && AgentSubagentProfileCatalog.writeToolNames.contains(call.toolName)
        // terminal_operator 的 send_command 是 .write 档，但放行的口子开得
        // 很窄：静态只读直接通过；Smart/Goal 可把非敏感、非确定性危险的
        // 模糊命令送父会话安全裁判一次。裁判不放行时仍由父会话通过
        // ops_runner.target_command 向用户申请精确授权。终端是用户的真实
        // shell，seatbelt 管不到那里，所以危险与敏感命令绝不能交给模型越权。
        let isTerminalOperatorReadOnlySend: Bool = {
            guard call.toolName == "terminal_send_command",
                  profile.id == AgentSubagentProfileCatalog.terminalOperatorID,
                  let command = argsDict["command"]?.stringValue() else { return false }
            return AgentSandboxPolicy.commandDecision(
                command: command,
                rootDirectory: workspaceURL,
                additionalWorkspaceRoots: additionalWorkspaceRoots
            ).risk == .read
        }()
        let isReviewableCommandTool = call.toolName == "run_command"
            || call.toolName == "terminal_send_command"
        // The child no longer pre-filters what the parent is allowed to be
        // asked about. Deciding *which* commands may run without a human is
        // the user's approval-mode setting, and that setting lives in the
        // parent — a second policy down here could only ever disagree with
        // it, and did: it silently refused to consult the parent at all
        // unless the command classified `.needsJudgment`, so Full Access
        // could not reach commands it plainly authorizes. The reviewer
        // returning false still lands in the same denial below.
        // 严格只读工种（scout / reader / generalist）不参与智能审核这条口子。
        // 它们拿到 shell 是为了 `ls` / `head` / `git log` 这类静态只读命令，
        // 不必再经过父会话裁判；一旦允许裁判为它们放行修改类命令，"只读
        // 工种"这个词就没有意义了，而这些工种恰恰跑在最小的模型上。
        let isStrictReadOnlyShellTrade = AgentSubagentProfileCatalog
            .strictReadOnlyShellTradeIDs.contains(profile.id)
        var isJudgeApprovedCommand = false
        if isReviewableCommandTool,
           !isStrictReadOnlyShellTrade,
           let command = argsDict["command"]?.stringValue(),
           let commandReviewer {
            isJudgeApprovedCommand = await commandReviewer(call.toolName, command)
        }
        // 单命令授权：用户在 spawn 审批卡上批准的那条确切命令（仅
        // ops_runner）。精确文本匹配——多一个字符都不放。
        let isApprovedCommandInvocation: Bool = {
            guard ["run_command", "terminal_send_command"].contains(call.toolName),
                  profile.id == AgentSubagentProfileCatalog.opsRunnerID,
                  let approvedCommand,
                  let command = argsDict["command"]?.stringValue() else { return false }
            return approvedCommandMatches(command, approved: approvedCommand)
        }()
        guard risk == .read
            || isApprovedWrite
            || isTerminalOperatorReadOnlySend
            || isJudgeApprovedCommand
            || isApprovedCommandInvocation else {
            if call.toolName == "terminal_send_command",
               profile.id == AgentSubagentProfileCatalog.terminalOperatorID {
                return "Denied: this command was neither statically read-only nor approved by intelligent safety review. Report the exact command to the parent. If it still needs to run, the parent must re-spawn `profile=\"ops_runner\"` with this exact `target_command`, which asks the operator for approval instead of silently discarding the request."
            }
            if call.toolName == "run_command", isStrictReadOnlyShellTrade {
                return "Denied: `\(profile.id)` runs only statically read-only commands, and this one classified as `\(risk.rawValue)`. Common causes: it writes, or it touches a path outside the workspace. Report the exact command to the parent — a modifying command belongs to a writing trade, and an operations command to `profile=\"ops_runner\"` with an exact `target_command`."
            }
            if call.toolName == "run_command" {
                return "Denied: this subagent command was neither statically read-only nor approved by intelligent safety review. Report the exact command to the parent. If it still needs to run, the parent must request exact human approval, using `profile=\"ops_runner\"` with this `target_command` for an operations command."
            }
            return "Denied: subagents may only run read-only operations, and this call classified as `\(risk.rawValue)`. Report the suggested change to the parent agent instead of performing it."
        }

        // Forward the parent's remote runtime binding so read-only tools
        // resolve `context.remoteBackend` and execute on the same ssh/daemon
        // box the parent uses — not the local Mac.
        // The patch sink is handed down only for an approved editor trade,
        // so `apply_patch` remains unreachable for every other subagent —
        // the tool errors out without a sink even if it somehow got called.
        // 子代理的 run_command 沙箱档按命令自身的分类走，而不是死钉
        // .readOnly：查询类命令（kubectl get / gh run list）分类为
        // readOnlyNetwork，钉 readOnly 会 deny network，把它们全逼进
        // "假 DNS 失败"——ops_runner 上架即残废。被授权的单命令则拿它
        // 分类应得的档（发布脚本通常是 workspaceWriteNetworkCredentialed，
        // 正好接上凭证沙箱的 ~/.ssh）。
        var sandboxMode: AgentSandboxMode = .readOnly
        if call.toolName == "run_command",
           let command = argsDict["command"]?.stringValue() {
            let decision = AgentSandboxPolicy.commandDecision(
                command: command,
                rootDirectory: workspaceURL,
                additionalWorkspaceRoots: additionalWorkspaceRoots
            )
            if isApprovedCommandInvocation || isJudgeApprovedCommand {
                sandboxMode = decision.mode
            } else if decision.mode == .readOnlyNetwork {
                sandboxMode = .readOnlyNetwork
            }
        }

        let context = AgentToolContext(
            rootDirectory: workspaceURL,
            additionalWorkspaceRoots: additionalWorkspaceRoots,
            workspaceLocation: workspaceLocation,
            runtimeDescriptor: runtimeDescriptor,
            sandboxMode: sandboxMode,
            patchProposalSink: writeAccess == nil ? nil : patchProposalSink,
            // 终端 controller 只随 terminal_operator 或已获单命令授权的
            // ops_runner 下发；其他工种拿不到用户终端。
            terminalController: (profile.id == AgentSubagentProfileCatalog.terminalOperatorID
                || (profile.id == AgentSubagentProfileCatalog.opsRunnerID && approvedCommand != nil))
                ? terminalController : nil
        )
        do {
            let result = try await AgentToolRunner.run(
                name: call.toolName,
                arguments: argsDict,
                context: context
            )
            return result.payload
        } catch {
            return "Tool error: \(error.localizedDescription)"
        }
    }
}

/// Accumulates one streaming turn's deltas off the event callback.
/// An actor (not main-actor state) because `streamChat`'s `onEvent`
/// is `@Sendable` and may hop executors between chunks.
private actor SubagentTurnCollector {
    struct Turn {
        var content = ""
        var reasoning = ""
        var toolCalls: [AgentMessageToolCall] = []
        var usageTokens = 0
        /// Kept split, not just totalled: a child loop resends its whole
        /// history every round, so its cost is overwhelmingly prompt-side.
        /// Collapsing to a total forces the dashboard to guess the ratio,
        /// and output tokens cost several times what input does.
        var promptTokens = 0
        var completionTokens = 0
        var cachedPromptTokens = 0
    }

    private var turn = Turn()

    func consume(_ event: AgentClientEvent) {
        switch event {
        case .textDelta(let delta):
            turn.content += delta
        case .reasoningDelta(let delta):
            turn.reasoning += delta
        case .toolCallsUpdated(let calls):
            turn.toolCalls = calls
        case .sourceReferencesUpdated:
            break
        case .finishedTurn:
            break
        case .usageReported(let prompt, let completion, let total, let cachedPrompt, _, _):
            turn.usageTokens = total
            turn.promptTokens = prompt
            turn.completionTokens = completion
            turn.cachedPromptTokens = cachedPrompt ?? 0
        }
    }

    func snapshot() -> Turn {
        turn
    }
}

/// Provider-neutral collector for the one-turn free-text streaming API.
///
/// Kept as a small standalone pipeline so deterministic tests can inject an
/// event stream without a live provider. Production passes
/// `AgentClient.streamChat` directly.
enum AgentSubagentTextStreamPipeline {
    typealias EventHandler = AgentSubagentRunner.StreamingTextEventHandler
    typealias Consumer = @Sendable (AgentClientEvent) async -> Void

    static func run(
        onEvent: EventHandler?,
        stream: (_ consume: @escaping Consumer) async throws -> Void
    ) async throws -> AgentSubagentStreamingTextOutcome {
        try Task.checkCancellation()
        let collector = AgentSubagentTextStreamCollector()

        try await stream { event in
            guard !Task.isCancelled else { return }
            guard let forwarded = await collector.consume(event) else { return }
            await onEvent?(forwarded)
        }

        try Task.checkCancellation()
        let outcome = await collector.outcome()
        guard !outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentSubagentError.emptyStreamingText
        }
        return outcome
    }
}

private actor AgentSubagentTextStreamCollector {
    private var text = ""
    private var reasoning = ""
    private var usage = AgentSubagentStreamingUsage()
    private var finishReason: String?
    private var didFinish = false

    func consume(_ event: AgentClientEvent) -> AgentSubagentStreamingTextEvent? {
        switch event {
        case .textDelta(let delta):
            guard !delta.isEmpty else { return nil }
            text += delta
            return .textDelta(delta)
        case .reasoningDelta(let delta):
            guard !delta.isEmpty else { return nil }
            reasoning += delta
            return .reasoningDelta(delta)
        case .toolCallsUpdated:
            // `runStreamingText` advertises no tools. Ignore a provider's
            // defensive empty tool snapshot rather than exposing it as text.
            return nil
        case .sourceReferencesUpdated:
            return nil
        case .finishedTurn(let reason):
            didFinish = true
            finishReason = reason
            return .finished(reason: reason)
        case .usageReported(
            let prompt,
            let completion,
            let total,
            let cachedPrompt,
            let cacheWritePrompt,
            let reasoningTokens
        ):
            usage = AgentSubagentStreamingUsage(
                prompt: prompt,
                completion: completion,
                total: total,
                cachedPrompt: cachedPrompt,
                cacheWritePrompt: cacheWritePrompt,
                reasoning: reasoningTokens,
                wasReported: true
            )
            return .usage(usage)
        }
    }

    func outcome() -> AgentSubagentStreamingTextOutcome {
        AgentSubagentStreamingTextOutcome(
            text: text,
            reasoning: reasoning,
            usage: usage,
            finishReason: finishReason,
            didFinish: didFinish
        )
    }
}
