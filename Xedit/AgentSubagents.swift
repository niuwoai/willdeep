//
//  AgentSubagents.swift
//  VeilWriter
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
    enum Status: String, Equatable {
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
    var status: Status = .running
    var finishedAt: Date?
    /// Final assistant text from the child loop. Empty until finished.
    var report: String = ""
    var usageTokens: Int = 0
    var roundCount: Int = 0
    var toolInvocationCount: Int = 0

    var displayHandle: String { "agent_\(shortID)" }
    nonisolated var duration: TimeInterval {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

enum AgentSubagentError: LocalizedError {
    case missingPrompt
    case tooManyConcurrent(Int)

    var errorDescription: String? {
        switch self {
        case .missingPrompt:
            return "spawn_agent requires a non-empty `prompt`."
        case .tooManyConcurrent(let limit):
            return "Too many subagents running for this session (max \(limit)). Wait for one to finish or run synchronously."
        }
    }
}

// MARK: - Registry

/// Per-app registry of subagent runs. One instance lives on `AppState`.
/// Background runs ride a stored `Task`; completion queues the run id
/// into `pendingReports` so the parent loop can inject the report at
/// the top of its next round — the exact pattern `AgentJobRegistry`
/// uses for background shell jobs.
@MainActor
final class AgentSubagentRegistry: ObservableObject {
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

    func activeCount(forParentRuntime runtimeID: UUID) -> Int {
        runs.filter { $0.parentRuntimeID == runtimeID && $0.status == .running }.count
    }

    func run(withID id: UUID) -> AgentSubagentRun? {
        runs.first { $0.id == id }
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
        parentRuntimeID: UUID
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
            startedAt: Date()
        )
        runs.insert(run, at: 0)

        tasks[id] = Task { [weak self] in
            let outcome: AgentSubagentRunner.Outcome
            do {
                outcome = try await AgentSubagentRunner.run(
                    prompt: prompt,
                    configuration: configuration,
                    workspaceURL: workspaceURL
                )
            } catch is CancellationError {
                self?.finish(id: id, status: .cancelled, report: "(subagent cancelled)")
                return
            } catch {
                self?.finish(id: id, status: .failed, report: "Subagent failed: \(error.localizedDescription)")
                return
            }
            self?.finish(
                id: id,
                status: .completed,
                report: outcome.report,
                usageTokens: outcome.usageTokens,
                roundCount: outcome.roundCount,
                toolInvocationCount: outcome.toolInvocationCount
            )
        }
        return run
    }

    private func finish(
        id: UUID,
        status: AgentSubagentRun.Status,
        report: String,
        usageTokens: Int = 0,
        roundCount: Int = 0,
        toolInvocationCount: Int = 0
    ) {
        tasks[id] = nil
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].status = status
        runs[index].finishedAt = Date()
        runs[index].report = report
        runs[index].usageTokens = usageTokens
        runs[index].roundCount = roundCount
        runs[index].toolInvocationCount = toolInvocationCount

        let parentID = runs[index].parentRuntimeID
        pendingReports[parentID, default: []].append(id)
        evictOldFinishedRuns(forParentRuntime: parentID)
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

    /// Cancel every live subagent owned by a session. Used when the
    /// conversation is cleared or the session goes away — orphaned
    /// child loops must not keep burning tokens.
    func cancelAll(forParentRuntime runtimeID: UUID) {
        for run in runs where run.parentRuntimeID == runtimeID && run.status == .running {
            tasks[run.id]?.cancel()
        }
    }

    private func evictOldFinishedRuns(forParentRuntime runtimeID: UUID) {
        let finished = runs.filter { $0.parentRuntimeID == runtimeID && $0.status != .running }
        guard finished.count > Self.historyLimit else { return }
        let toEvict = Set(finished.suffix(finished.count - Self.historyLimit).map(\.id))
        runs.removeAll { toEvict.contains($0.id) }
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
    /// MCP tools (server side effects unknowable), background-job
    /// tools (a child shouldn't leave processes behind).
    static let allowedToolNames: Set<String> = [
        "search_files", "grep_files", "read_file", "list_directory",
        "git_status", "run_command", "list_skills", "read_skill",
    ]

    static var toolDescriptors: [AgentToolDescriptor] {
        AgentToolRegistry.all.filter { allowedToolNames.contains($0.name) }
    }

    struct Outcome: Equatable {
        let report: String
        let usageTokens: Int
        let roundCount: Int
        let toolInvocationCount: Int
    }

    static func systemPrompt(workspaceURL: URL?) -> String {
        var lines: [String] = []
        lines.append("You are a focused subagent spawned by a coding agent to complete one task.")
        if let workspaceURL {
            lines.append("Workspace root: \(workspaceURL.path)")
        }
        lines.append("""
        Rules:
        - You have READ-ONLY access: search/grep/read/list tools plus read-only shell commands. Write operations are denied — do not attempt them; report what should be changed instead.
        - You cannot ask the user anything. Make reasonable assumptions and note them.
        - Work autonomously until the task is done, then STOP calling tools and write your final report as a normal message.
        - Your final message IS the deliverable returned to the parent agent. Make it self-contained, specific (file paths, line numbers, code excerpts), and free of filler.
        """)
        return lines.joined(separator: "\n")
    }

    /// Run the child loop to completion. Throws on network/provider
    /// errors and on cancellation; a round-cap exhaustion returns
    /// whatever the child said last with an explanatory note instead
    /// of throwing, so the parent still gets partial value.
    static func run(
        prompt: String,
        configuration: AgentConfiguration,
        workspaceURL: URL?
    ) async throws -> Outcome {
        let client = AgentClient(configuration: configuration)
        var transcript: [AgentMessage] = [
            AgentMessage(role: .system, content: systemPrompt(workspaceURL: workspaceURL)),
            AgentMessage(role: .user, content: prompt),
        ]
        var totalTokens = 0
        var toolInvocations = 0

        for round in 1...maxRounds {
            var content = ""
            var reasoning = ""
            var toolCalls: [AgentMessageToolCall] = []
            let collector = SubagentTurnCollector()

            try await client.streamChat(
                messages: transcript,
                tools: toolDescriptors
            ) { event in
                await collector.consume(event)
            }
            let turn = await collector.snapshot()
            content = turn.content
            reasoning = turn.reasoning
            toolCalls = turn.toolCalls
            totalTokens += turn.usageTokens

            transcript.append(AgentMessage(
                role: .assistant,
                content: content,
                reasoningContent: reasoning.isEmpty ? nil : reasoning,
                toolCalls: toolCalls
            ))

            guard !toolCalls.isEmpty else {
                let report = content.trimmingCharacters(in: .whitespacesAndNewlines)
                return Outcome(
                    report: report.isEmpty ? "(subagent finished without producing a report)" : report,
                    usageTokens: totalTokens,
                    roundCount: round,
                    toolInvocationCount: toolInvocations
                )
            }

            for call in toolCalls {
                try Task.checkCancellation()
                toolInvocations += 1
                let payload = await executeToolCall(call, workspaceURL: workspaceURL)
                transcript.append(AgentMessage(
                    role: .tool,
                    content: payload,
                    toolCallID: call.externalID
                ))
            }
        }

        // Round cap hit — return partial value rather than throwing away
        // every token the child already spent.
        let lastText = transcript.last(where: { $0.role == .assistant && !$0.content.isEmpty })?.content ?? ""
        let note = "[Subagent stopped after \(maxRounds) tool rounds without a final report. Last progress shown below.]"
        return Outcome(
            report: lastText.isEmpty ? note : "\(note)\n\n\(lastText)",
            usageTokens: totalTokens,
            roundCount: maxRounds,
            toolInvocationCount: toolInvocations
        )
    }

    /// Execute one child tool call, enforcing the read-only contract.
    /// Errors are folded into the payload string — the child should see
    /// what went wrong and adapt, exactly like the parent loop does.
    private static func executeToolCall(
        _ call: AgentMessageToolCall,
        workspaceURL: URL?
    ) async -> String {
        guard allowedToolNames.contains(call.toolName) else {
            return "Denied: tool `\(call.toolName)` is not available to subagents. Available tools: \(allowedToolNames.sorted().joined(separator: ", "))."
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
        guard risk == .read else {
            return "Denied: subagents may only run read-only operations, and this call classified as `\(risk.rawValue)`. Report the suggested change to the parent agent instead of performing it."
        }

        let context = AgentToolContext(rootDirectory: workspaceURL)
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
        case .finishedTurn:
            break
        case .usageReported(_, _, let total):
            turn.usageTokens = total
        }
    }

    func snapshot() -> Turn {
        turn
    }
}
