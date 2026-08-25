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
        _ profile: AgentSubagentProfile
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
    var runOperation: RunOperation = { prompt, configuration, workspaceURL, runtimeDescriptor, workspaceLocation, someIMContext, outputSchema, profile in
        try await AgentSubagentRunner.run(
            prompt: prompt,
            configuration: configuration,
            workspaceURL: workspaceURL,
            runtimeDescriptor: runtimeDescriptor,
            workspaceLocation: workspaceLocation,
            someIMContext: someIMContext,
            outputSchema: outputSchema,
            profile: profile
        )
    }

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

        tasks[id] = Task { [weak self] in
            let outcome: AgentSubagentRunner.Outcome
            do {
                outcome = try await self?.runOperation(
                    prompt,
                    configuration,
                    workspaceURL,
                    runtimeDescriptor,
                    workspaceLocation,
                    someIMContext,
                    outputSchema,
                    profile
                ) ?? AgentSubagentRunner.Outcome(
                    report: "",
                    usageTokens: 0,
                    roundCount: 0,
                    toolInvocationCount: 0
                )
            } catch is CancellationError {
                self?.finish(id: id, status: .cancelled, report: "(subagent cancelled)", profileID: profile.id)
                return
            } catch {
                self?.finish(id: id, status: .failed, report: "Subagent failed: \(error.localizedDescription)", profileID: profile.id)
                return
            }
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
            AgentSubagentProfileCatalog.deep
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
        return ids.compactMap { id in runs.first { $0.id == id } }
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

/// The child agent loop. No UI, no approvals, no patch proposals —
/// just stream → run read-only tools → stream until the model stops
/// calling tools, then hand back its final message as the report.
@MainActor
enum AgentSubagentRunner {
    static let maxRounds = 12

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
        writeAccessGranted: Bool = false
    ) -> [AgentToolDescriptor] {
        let permitted = profile.effectiveToolNames(writeAccessGranted: writeAccessGranted)
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
        jobPromptIsHosted: Bool = false
    ) -> String {
        var lines: [String] = []
        lines.append("You are a focused subagent spawned by a coding agent to complete one task.")
        // `deep`'s own section only restates the generic opening, so it is
        // skipped — but a user-authored soul section on `deep` is not generic
        // and must still be sent.
        //
        // A hosted trade's job section is prepended by the relay, so sending
        // ours too would stack two copies of the same instructions and burn
        // the tokens twice. The invariant rules below are never hosted: they
        // are the client's safety boundary and always ship from here.
        let capabilitySection = jobPromptIsHosted
            ? ""
            : profile.capabilityPromptSection
                .trimmingCharacters(in: .whitespacesAndNewlines)
        let isRedundantDeepSection = profile.id == AgentSubagentProfileCatalog.deepID
            && capabilitySection == AgentSubagentProfileCatalog.deep.capabilityPromptSection
                .trimmingCharacters(in: .whitespacesAndNewlines)
        if !capabilitySection.isEmpty, !isRedundantDeepSection {
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
        if writeAccess != nil {
            // The read-only rule block below is wrong for this trade, and a
            // contradicted rule is worse than no rule.
            lines.append("""
            Rules:
            - You have READ access plus bounded write tools (`create_file` / `apply_patch`) carried by your trade, scoped to the files named above. Everything else is denied.
            - You cannot ask the user anything. Make reasonable assumptions and note them.
            - Read a file before patching it. Keep the change minimal and consistent with surrounding code.
            - Work autonomously until the edit is done, then STOP calling tools and write your final report as a normal message.
            - Your final message IS the deliverable returned to the parent agent. State exactly what you changed and why, and flag anything you deliberately left alone.
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
    /// `onProgress` (round, cumulative tool invocations) fires once at the
    /// end of every round on the main actor. The synchronous `spawn_agent`
    /// path uses it to keep the tool card's live-progress line current so a
    /// long child loop reads as "第 3/12 轮" rather than a bare spinner.
    /// Background / workflow callers leave it nil.
    static func run(
        prompt: String,
        configuration: AgentConfiguration,
        workspaceURL: URL?,
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
        /// 仅 terminal_operator 工种需要：把父会话的侧栏终端 controller 递
        /// 给子循环，terminal_* 工具才有执行对象。其余工种传了也会在
        /// executeToolCall 里被丢弃。
        terminalController: AgentInteractiveTerminalController? = nil,
        /// 单命令授权（仅 ops_runner）：用户在 spawn 审批卡上批准的那条
        /// 确切命令。子循环里恰好等于这条文本的 run_command 可以越过
        /// "只许 read"的死门执行——语义上等同用户在主会话批准了这条命令，
        /// 爆炸半径恰好一条。可重复执行（发布脚本按部署规范应幂等），
        /// verifier 循环靠这一点重试。
        approvedCommand: String? = nil,
        onProgress: ((_ round: Int, _ toolInvocations: Int) -> Void)? = nil
    ) async throws -> Outcome {
        // some.im-gated providers require the session/workspace context headers on
        // every request; without them some.im rejects/stalls the call. Workflow
        // subagents used to omit this (unlike the main loop), so a `/code-review`
        // on a some.im model hung as an empty card. Forward it here.
        let client = AgentClient(configuration: configuration, someIMContext: someIMContext)
        var transcript: [AgentMessage] = [
            AgentMessage(
                role: .system,
                content: systemPrompt(
                    workspaceURL: workspaceURL,
                    outputSchema: outputSchema,
                    profile: profile,
                    writeAccess: writeAccess,
                    // Derived rather than passed in: the relay hosts this
                    // trade's job prompt exactly when we are actually calling
                    // its hosted virtual model. Signed out, binding resolution
                    // never pins that model, and an escalated re-run lands on
                    // the parent's model — both correctly fall back to sending
                    // our own copy, and the flag cannot drift from reality.
                    jobPromptIsHosted: profile.hostedVirtualModel != nil
                        && configuration.model == profile.hostedVirtualModel
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
            writeAccessGranted: writeAccess != nil
        )
        if outputSchema != nil {
            toolList.append(structuredOutputDescriptor)
        }
        let roundLimit = max(1, profile.maxRounds)
        // Inspector record, built alongside the provider-facing transcript.
        // Kept separate because this one is capped, keeps per-call timings,
        // and drops the system prompt.
        var recordedRounds: [AgentSubagentTranscript.Round] = []
        var didTruncateRecord = false

        for round in 1...roundLimit {
            // Surface "entering round N" to the card before the (potentially
            // long) streaming round begins — this is the window the user
            // otherwise stares at a still spinner during.
            onProgress?(round, toolInvocations)
            let roundStartedAt = Date()
            var content = ""
            var reasoning = ""
            var toolCalls: [AgentMessageToolCall] = []
            let collector = SubagentTurnCollector()

            try await client.streamChat(
                messages: transcript,
                tools: toolList
            ) { event in
                await collector.consume(event)
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

            // schema 模式下:本轮里若已经成功调过 structured_output,
            // 立即结束 loop —— 别等模型再吐自由文本。
            if let outputSchema {
                for call in toolCalls where call.toolName == structuredOutputToolName {
                    try Task.checkCancellation()
                    toolInvocations += 1
                    let callStartedAt = Date()
                    let (ok, payload) = handleStructuredOutputCall(call, schema: outputSchema)
                    transcript.append(AgentMessage(
                        role: .tool,
                        content: payload,
                        toolCallID: call.externalID
                    ))
                    recordToolCall(call, payload: payload, startedAt: callStartedAt)
                    if ok {
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

                // The worker says it is finished. With a verifier configured,
                // that claim is not the verdict — the command is. Run it here
                // rather than trusting the report, because "I fixed it" is
                // exactly the sentence a stuck small model produces.
                if let verifierCommand, verifierPassed != true {
                    let verification = await runVerifier(
                        command: verifierCommand,
                        workspaceURL: workspaceURL,
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
            for call in toolCalls where call.toolName != structuredOutputToolName {
                try Task.checkCancellation()
                toolInvocations += 1
                let callStartedAt = Date()
                let rawPayload = await executeToolCall(
                    call,
                    workspaceURL: workspaceURL,
                    runtimeDescriptor: runtimeDescriptor,
                    workspaceLocation: workspaceLocation,
                    profile: profile,
                    writeAccess: writeAccess,
                    terminalController: terminalController,
                    approvedCommand: approvedCommand,
                    patchProposalSink: patchProposalSink
                )
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
            let verification = await runVerifier(
                command: verifierCommand,
                workspaceURL: workspaceURL,
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
        runtimeDescriptor: RuntimeDescriptor? = nil,
        workspaceLocation: WorkspaceLocation? = nil
    ) async -> VerifierRun {
        let context = AgentToolContext(
            rootDirectory: workspaceURL,
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

    private static func executeToolCall(
        _ call: AgentMessageToolCall,
        workspaceURL: URL?,
        runtimeDescriptor: RuntimeDescriptor? = nil,
        workspaceLocation: WorkspaceLocation? = nil,
        profile: AgentSubagentProfile = AgentSubagentProfileCatalog.deep,
        writeAccess: AgentSubagentWriteAccess? = nil,
        terminalController: AgentInteractiveTerminalController? = nil,
        approvedCommand: String? = nil,
        patchProposalSink: (@MainActor (String?, String, Bool, URL) async throws -> AgentPatchProposal)? = nil
    ) async -> String {
        let permitted = profile.effectiveToolNames(writeAccessGranted: writeAccess != nil)
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
            rootDirectory: workspaceURL
        )
        // Writing trades carry bounded tools backed by an exact workspace
        // capability. Everything else stays read-only.
        let isApprovedWrite = writeAccess != nil
            && AgentSubagentProfileCatalog.writeToolNames.contains(call.toolName)
        // terminal_operator 的 send_command 是 .write 档，但放行的口子开得
        // 很窄：命令文本自己必须分类为只读（`kubectl get` 能敲，`rm` 在这
        // 里就被拒）。终端是用户的真实 shell，seatbelt 管不到那里，所以这
        // 道文本分类闸是唯一的边界——分不出只读的一律拒。此外一切都发生
        // 在用户可见的侧栏终端里，本身就是一层监督。
        let isTerminalOperatorReadOnlySend: Bool = {
            guard call.toolName == "terminal_send_command",
                  profile.id == AgentSubagentProfileCatalog.terminalOperatorID,
                  let command = argsDict["command"]?.stringValue() else { return false }
            return AgentSandboxPolicy.commandDecision(
                command: command,
                rootDirectory: workspaceURL
            ).risk == .read
        }()
        // 单命令授权：用户在 spawn 审批卡上批准的那条确切命令（仅
        // ops_runner）。精确文本匹配——多一个字符都不放。
        let isApprovedCommandRun: Bool = {
            guard call.toolName == "run_command",
                  profile.id == AgentSubagentProfileCatalog.opsRunnerID,
                  let approvedCommand,
                  let command = argsDict["command"]?.stringValue() else { return false }
            return approvedCommandMatches(command, approved: approvedCommand)
        }()
        guard risk == .read || isApprovedWrite || isTerminalOperatorReadOnlySend || isApprovedCommandRun else {
            if call.toolName == "terminal_send_command",
               profile.id == AgentSubagentProfileCatalog.terminalOperatorID {
                return "Denied: this command did not classify as read-only, and the terminal-operator trade may only send read-only commands. Report it back to the parent agent instead of working around the denial."
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
                rootDirectory: workspaceURL
            )
            if isApprovedCommandRun {
                sandboxMode = decision.mode
            } else if decision.mode == .readOnlyNetwork {
                sandboxMode = .readOnlyNetwork
            }
        }

        let context = AgentToolContext(
            rootDirectory: workspaceURL,
            workspaceLocation: workspaceLocation,
            runtimeDescriptor: runtimeDescriptor,
            sandboxMode: sandboxMode,
            patchProposalSink: writeAccess == nil ? nil : patchProposalSink,
            // 终端 controller 只随 terminal_operator 下发；其他工种即便被
            // 允许调 snapshot 之类，也拿不到执行所需的 controller。
            terminalController: profile.id == AgentSubagentProfileCatalog.terminalOperatorID
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
