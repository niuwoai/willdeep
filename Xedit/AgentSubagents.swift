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

    nonisolated var displayHandle: String { "agent_\(shortID)" }
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
                    workspaceURL: workspaceURL,
                    runtimeDescriptor: runtimeDescriptor,
                    workspaceLocation: workspaceLocation
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
        if let finished = runs.first(where: { $0.id == id }) {
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
    /// tools (a child shouldn't leave processes behind), and
    /// `web_fetch` (write-tier: arbitrary fetches need the parent
    /// session's approval UI, which a child doesn't have).
    /// `web_search` is in: read-tier, single well-known endpoint,
    /// and research subagents are its main customer.
    static let allowedToolNames: Set<String> = [
        "search_files", "grep_files", "read_file", "list_directory",
        "git_status", "run_command", "list_skills", "read_skill",
        "web_search",
    ]

    static var toolDescriptors: [AgentToolDescriptor] {
        AgentToolRegistry.all.filter { allowedToolNames.contains($0.name) }
    }

    /// 1.85.0-rc18:虚拟工具名 —— 当 caller 传了 `outputSchema` 时,这条
    /// 工具会被追加到 sub-agent 可见的工具表里;系统提示同步要求模型
    /// 在答完后必须调它,把 JSON 字符串塞进 `data` 字段。我们这边的
    /// `executeToolCall(...)` 检测到这个 toolName 时不真的「执行」,而是
    /// 把 args["data"] 拎出来送进 `AgentStructuredSchema.validate(...)`
    /// 校验,通过即结束 loop,失败就把 issues 回 tool result 让模型重试。
    static let structuredOutputToolName = "structured_output"

    struct Outcome: Equatable {
        let report: String
        let usageTokens: Int
        let roundCount: Int
        let toolInvocationCount: Int
    }

    static func systemPrompt(workspaceURL: URL?, outputSchema: AgentStructuredSchema? = nil) -> String {
        var lines: [String] = []
        lines.append("You are a focused subagent spawned by a coding agent to complete one task.")
        if let workspaceURL {
            lines.append("Workspace root: \(workspaceURL.path)")
        }
        if outputSchema == nil {
            lines.append("""
            Rules:
            - You have READ-ONLY access: search/grep/read/list tools, read-only shell commands, and `web_search` for public web lookups. Write operations are denied — do not attempt them; report what should be changed instead.
            - You cannot ask the user anything. Make reasonable assumptions and note them.
            - Work autonomously until the task is done, then STOP calling tools and write your final report as a normal message.
            - Your final message IS the deliverable returned to the parent agent. Make it self-contained, specific (file paths, line numbers, code excerpts), and free of filler.
            """)
        } else {
            // schema 模式:模型不要再写自由文本汇报,而是通过 structured_output
            // 工具把最终结果作为 JSON 交付。schema 同步贴出来作 contract。
            lines.append("""
            Rules:
            - You have READ-ONLY access: search/grep/read/list tools, read-only shell commands, and `web_search` for public web lookups. Write operations are denied — do not attempt them; report what should be changed instead.
            - You cannot ask the user anything. Make reasonable assumptions and note them.
            - Work autonomously until you have the answer. Then STOP calling the read-only tools.
            - **Structured output required**: deliver the final answer by calling the `\(structuredOutputToolName)` tool exactly once. Its `data` argument MUST be a JSON STRING that parses into a value satisfying the schema below. Do NOT write the JSON in your normal reply text — the parent only reads the tool call.
            - If your first attempt fails validation, the tool result will explain the issues; correct the JSON and call `\(structuredOutputToolName)` again. Do not give up — only correctly-validated output reaches the parent.
            """)
            lines.append("""
            JSON Schema your `data` must satisfy:
            \(outputSchema!.renderedJSON())
            """)
        }
        return lines.joined(separator: "\n")
    }

    /// rc18:基于 caller 是否要 structured output,返回供模型选择的工具
    /// 列表。schema 路径下追加一条 `structured_output(data: string)`。
    static func toolDescriptors(includingStructuredOutput: Bool) -> [AgentToolDescriptor] {
        var descriptors = toolDescriptors
        guard includingStructuredOutput else { return descriptors }
        descriptors.append(
            AgentToolDescriptor(
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
        )
        return descriptors
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
    static func run(
        prompt: String,
        configuration: AgentConfiguration,
        workspaceURL: URL?,
        runtimeDescriptor: RuntimeDescriptor? = nil,
        workspaceLocation: WorkspaceLocation? = nil,
        outputSchema: AgentStructuredSchema? = nil
    ) async throws -> Outcome {
        let client = AgentClient(configuration: configuration)
        var transcript: [AgentMessage] = [
            AgentMessage(role: .system, content: systemPrompt(workspaceURL: workspaceURL, outputSchema: outputSchema)),
            AgentMessage(role: .user, content: prompt),
        ]
        var totalTokens = 0
        var toolInvocations = 0
        let toolList = toolDescriptors(includingStructuredOutput: outputSchema != nil)

        for round in 1...maxRounds {
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

            transcript.append(AgentMessage(
                role: .assistant,
                content: content,
                reasoningContent: reasoning.isEmpty ? nil : reasoning,
                toolCalls: toolCalls
            ))

            // schema 模式下:本轮里若已经成功调过 structured_output,
            // 立即结束 loop —— 别等模型再吐自由文本。
            if let outputSchema {
                for call in toolCalls where call.toolName == structuredOutputToolName {
                    try Task.checkCancellation()
                    toolInvocations += 1
                    let (ok, payload) = handleStructuredOutputCall(call, schema: outputSchema)
                    transcript.append(AgentMessage(
                        role: .tool,
                        content: payload,
                        toolCallID: call.externalID
                    ))
                    if ok {
                        return Outcome(
                            report: payload,
                            usageTokens: totalTokens,
                            roundCount: round,
                            toolInvocationCount: toolInvocations
                        )
                    }
                }
            }

            // 没有任何工具调用 → free-text 模式正常退出;schema 模式下
            // 此时说明模型答完但忘了调 structured_output,直接报 schema
            // 不可用让 caller 决定要不要重试 / 降级。
            guard !toolCalls.isEmpty else {
                let report = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if outputSchema != nil {
                    throw WorkflowError.structuredOutputUnavailable(
                        reason: "Subagent ended without calling `\(structuredOutputToolName)`. Last text was: \(report.prefix(200))"
                    )
                }
                return Outcome(
                    report: report.isEmpty ? "(subagent finished without producing a report)" : report,
                    usageTokens: totalTokens,
                    roundCount: round,
                    toolInvocationCount: toolInvocations
                )
            }

            // 普通工具(read-only / web_search 等)走原路径。schema 模式
            // 下,structured_output 已经在前面拎走处理,这里只剩别的。
            for call in toolCalls where call.toolName != structuredOutputToolName {
                try Task.checkCancellation()
                toolInvocations += 1
                let payload = await executeToolCall(
                    call,
                    workspaceURL: workspaceURL,
                    runtimeDescriptor: runtimeDescriptor,
                    workspaceLocation: workspaceLocation
                )
                transcript.append(AgentMessage(
                    role: .tool,
                    content: payload,
                    toolCallID: call.externalID
                ))
            }
        }

        // schema 模式下 round cap 到了 = 没有合规的结构化答案;别给
        // caller 返回半成品。
        if outputSchema != nil {
            throw WorkflowError.structuredOutputUnavailable(
                reason: "Subagent exhausted \(maxRounds) rounds without producing valid structured output."
            )
        }

        // Free-text 模式 round cap 到了 — return partial value rather than
        // throwing away every token the child already spent.
        let lastText = transcript.last(where: { $0.role == .assistant && !$0.content.isEmpty })?.content ?? ""
        let note = "[Subagent stopped after \(maxRounds) tool rounds without a final report. Last progress shown below.]"
        return Outcome(
            report: lastText.isEmpty ? note : "\(note)\n\n\(lastText)",
            usageTokens: totalTokens,
            roundCount: maxRounds,
            toolInvocationCount: toolInvocations
        )
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

    /// Execute one child tool call, enforcing the read-only contract.
    /// Errors are folded into the payload string — the child should see
    /// what went wrong and adapt, exactly like the parent loop does.
    private static func executeToolCall(
        _ call: AgentMessageToolCall,
        workspaceURL: URL?,
        runtimeDescriptor: RuntimeDescriptor? = nil,
        workspaceLocation: WorkspaceLocation? = nil
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

        // Forward the parent's remote runtime binding so read-only tools
        // resolve `context.remoteBackend` and execute on the same ssh/daemon
        // box the parent uses — not the local Mac.
        let context = AgentToolContext(
            rootDirectory: workspaceURL,
            workspaceLocation: workspaceLocation,
            runtimeDescriptor: runtimeDescriptor
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
        case .usageReported(_, _, let total, _, _, _):
            turn.usageTokens = total
        }
    }

    func snapshot() -> Turn {
        turn
    }
}
