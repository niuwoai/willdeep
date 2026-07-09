//
//  WorkflowEngine.swift
//  WillDeep
//
//  Workflow 执行引擎。提供 DSL 原语 `agent(...)` / `parallel(...)`，每次
//  调用都会：
//   1. 在 report.subAgents 加一条 SubAgent
//   2. 直接调用 `AgentSubagentRunner.run(...)`（绕过
//      AgentSubagentRegistry 的硬编码 3 并发上限 —— workflow 自己用
//      `maxConcurrent` 控制并发，跟 spawn_agent 工具走的是不同
//      预算）
//   3. 完成 / 失败时 mutate SubAgent，UI 卡片自动重渲染
//
//  与 [[project-swiftui-streaming-layout-runaway]]、[[project-swiftui-sheet-published-loop]]
//  无关：engine 的所有 UI 更新都走 AppState.updateWorkflowReport，
//  AppState 是 @Published，但只在每个 subagent 状态变化时离散触发，
//  不在 view body 求值期间写。
//

import Foundation

@MainActor
final class WorkflowEngine {
    /// engine 实例的 owning report id。所有 mutation 都通过 appState
    /// 找回这个 report。
    let reportID: UUID
    let runtimeID: UUID
    let workspaceURL: URL?
    let configuration: AgentConfiguration
    /// rc40:some.im 会话/工作区上下文头。子 agent 的每个 provider 请求都要带上,
    /// 否则 some.im 收不到合法会话上下文 → 请求 stall,卡片永远空转。由
    /// `startWorkflow` 按主循环同样的逻辑构造后透传进来(非 some.im provider 为 nil)。
    let someIMContext: SomeIMRequestContext?
    weak var appState: AppState?

    init(
        reportID: UUID,
        runtimeID: UUID,
        workspaceURL: URL?,
        configuration: AgentConfiguration,
        someIMContext: SomeIMRequestContext?,
        appState: AppState
    ) {
        self.reportID = reportID
        self.runtimeID = runtimeID
        self.workspaceURL = workspaceURL
        self.configuration = configuration
        self.someIMContext = someIMContext
        self.appState = appState
    }

    // MARK: - DSL: agent

    /// 派一个 sub-agent 跑 prompt，await 拿到它的最终报告字符串。
    /// 失败抛 WorkflowError.subAgentFailed，由调用方决定整个 workflow
    /// 是否要 fail。
    func agent(_ prompt: String, label: String) async throws -> String {
        let subAgentID = UUID()
        let startedAt = Date()
        mutateReport { report in
            report.subAgents.append(.init(
                id: subAgentID,
                label: label,
                status: .running,
                startedAt: startedAt
            ))
        }

        let outcome: AgentSubagentRunner.Outcome
        do {
            outcome = try await AgentSubagentRunner.run(
                prompt: prompt,
                configuration: configuration,
                workspaceURL: workspaceURL,
                someIMContext: someIMContext
            )
        } catch is CancellationError {
            mutateReport { report in
                if let idx = report.subAgents.firstIndex(where: { $0.id == subAgentID }) {
                    report.subAgents[idx].status = .failed
                    report.subAgents[idx].finishedAt = Date()
                    report.subAgents[idx].report = "(cancelled)"
                }
            }
            throw CancellationError()
        } catch {
            mutateReport { report in
                if let idx = report.subAgents.firstIndex(where: { $0.id == subAgentID }) {
                    report.subAgents[idx].status = .failed
                    report.subAgents[idx].finishedAt = Date()
                    report.subAgents[idx].report = "Sub-agent failed: \(error.localizedDescription)"
                }
            }
            throw WorkflowError.subAgentFailed(label: label, underlying: error)
        }

        mutateReport { report in
            if let idx = report.subAgents.firstIndex(where: { $0.id == subAgentID }) {
                report.subAgents[idx].status = .done
                report.subAgents[idx].finishedAt = Date()
                report.subAgents[idx].usageTokens = outcome.usageTokens
                report.subAgents[idx].roundCount = outcome.roundCount
                report.subAgents[idx].report = outcome.report
            }
            report.totalUsageTokens += outcome.usageTokens
        }
        return outcome.report
    }

    /// 1.85.0-rc18:**结构化输出版** —— 派一个 sub-agent 跑 prompt,通过
    /// schema 约束它的最终交付,自动 Codable decode 到 `T`。
    ///
    /// 机制(详见 [AgentStructuredSchema](Xedit/AgentStructuredSchema.swift)
    /// 顶部注释):往 sub-agent 工具表里注入 `structured_output(data:)`
    /// 虚拟工具,system prompt 同步告诉它「答完调它,data 是 JSON 字符
    /// 串符合 <schema>」;`AgentSubagentRunner` 收到 tool call 时拎出 data
    /// 跑 schema validate,通过即结束 loop 把 JSON 字符串返回。这里再
    /// JSONDecoder 解到 `T`。
    ///
    /// 校验失败 → 把 issues 当 tool result 灌回模型重试,在 round cap 内
    /// 自愈;round cap 用完仍没成 → 抛 `WorkflowError.structuredOutputUnavailable`。
    func agent<T: Decodable>(
        _ prompt: String,
        label: String,
        schema: AgentStructuredSchema,
        decode: T.Type = T.self
    ) async throws -> T {
        let subAgentID = UUID()
        let startedAt = Date()
        mutateReport { report in
            report.subAgents.append(.init(
                id: subAgentID,
                label: label,
                status: .running,
                startedAt: startedAt
            ))
        }

        let outcome: AgentSubagentRunner.Outcome
        do {
            outcome = try await AgentSubagentRunner.run(
                prompt: prompt,
                configuration: configuration,
                workspaceURL: workspaceURL,
                someIMContext: someIMContext,
                outputSchema: schema
            )
        } catch is CancellationError {
            mutateReport { report in
                if let idx = report.subAgents.firstIndex(where: { $0.id == subAgentID }) {
                    report.subAgents[idx].status = .failed
                    report.subAgents[idx].finishedAt = Date()
                    report.subAgents[idx].report = "(cancelled)"
                }
            }
            throw CancellationError()
        } catch {
            mutateReport { report in
                if let idx = report.subAgents.firstIndex(where: { $0.id == subAgentID }) {
                    report.subAgents[idx].status = .failed
                    report.subAgents[idx].finishedAt = Date()
                    report.subAgents[idx].report = "Sub-agent failed: \(error.localizedDescription)"
                }
            }
            throw WorkflowError.subAgentFailed(label: label, underlying: error)
        }

        mutateReport { report in
            if let idx = report.subAgents.firstIndex(where: { $0.id == subAgentID }) {
                report.subAgents[idx].status = .done
                report.subAgents[idx].finishedAt = Date()
                report.subAgents[idx].usageTokens = outcome.usageTokens
                report.subAgents[idx].roundCount = outcome.roundCount
                report.subAgents[idx].report = outcome.report
            }
            report.totalUsageTokens += outcome.usageTokens
        }

        // Outcome.report 在 schema 模式下装的是已 validate 的 JSON 字符
        // 串;decode 到 T。失败抛出 dedicated error,把原文 head 带出来
        // 方便排查(罕见 —— 通常意味着 schema 描述和 Swift Decodable
        // 类型对不上)。
        guard let data = outcome.report.data(using: .utf8) else {
            throw WorkflowError.structuredOutputDecodeFailed(
                label: label,
                underlying: NSError(domain: "WorkflowEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "outcome.report is not UTF-8"]),
                json: outcome.report
            )
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw WorkflowError.structuredOutputDecodeFailed(
                label: label,
                underlying: error,
                json: outcome.report
            )
        }
    }

    // MARK: - DSL: parallel

    /// 并发跑一组任务，受 `maxConcurrent` 限制（用 actor + semaphore
    /// 风格的简易窗口）。失败的子任务返回 nil，不让整组炸。
    func parallel<T: Sendable>(
        maxConcurrent: Int,
        _ thunks: [@Sendable () async throws -> T]
    ) async -> [T?] {
        let cap = max(1, min(maxConcurrent, thunks.count))
        var results: [T?] = Array(repeating: nil, count: thunks.count)

        // 用 indices 块式滚动 + TaskGroup 控制并发窗口。
        var nextIndex = 0
        while nextIndex < thunks.count {
            let windowEnd = min(nextIndex + cap, thunks.count)
            await withTaskGroup(of: (Int, T?).self) { group in
                for i in nextIndex..<windowEnd {
                    let thunk = thunks[i]
                    group.addTask {
                        do {
                            let value = try await thunk()
                            return (i, value)
                        } catch {
                            return (i, nil)
                        }
                    }
                }
                for await (idx, value) in group {
                    results[idx] = value
                }
            }
            nextIndex = windowEnd
        }
        return results
    }

    // MARK: - DSL: pipeline (rc19)

    /// 1.85.0-rc19:item 级 pipeline。每个 item 独立流过 `body` 里的所有
    /// stage,**stage 间没有 barrier** —— item A 可以在 stage 3,item B
    /// 还在 stage 1。这是把 deep-research 那种「search 完一个就立刻
    /// fetch+extract 一个,不等所有 search 都完成」的形态做成 first-class
    /// 入口。
    ///
    /// 严格说,这层是 `parallel()` 之上的语法糖 —— 因为 Swift 异步本来
    /// 就是 thunk 级独立 await,把多 stage 写在一个 body 里自然就拿到
    /// 「no barrier」的 pipeline 语义。差别只是 ergonomic:`pipeline` 强
    /// 调输入是「items + 一个流水线 body」,`parallel` 强调「一堆独立 thunks」。
    /// Claude Code workflow runtime 用的是 `pipeline(items, stage1, stage2, ...)`
    /// 多 stage 函数式语法;在 Swift 用单 body 闭包更简洁,语义等价。
    ///
    /// `body` 收 `(item, index)`,index 给你打日志 / label。失败 → nil,
    /// 不让整组炸,语义同 `parallel`。
    func pipeline<Item: Sendable, Result: Sendable>(
        _ items: [Item],
        maxConcurrent: Int,
        _ body: @Sendable @escaping (Item, Int) async throws -> Result
    ) async -> [Result?] {
        let thunks: [@Sendable () async throws -> Result] = items.enumerated().map { offset, item in
            { try await body(item, offset) }
        }
        return await parallel(maxConcurrent: maxConcurrent, thunks)
    }

    // MARK: - DSL: displayWidget

    /// 1.85.0-rc3：让 workflow 直接把 widget 推到 transcript 立刻显示
    /// （绕过 `show_widget` 工具的 next-turn drain 管线，因为 workflow
    /// 跑完没有"下一个 turn"概念）。同样落到 runtime.messages，由
    /// `AgentWidgetCardView` 渲染。
    func displayWidget(_ widget: AgentWidget) async {
        await MainActor.run {
            guard let appState = appState else { return }
            guard let runtime = appState.agentRuntimes[runtimeID] else { return }
            runtime.messages.append(AgentMessage(role: .widget, content: "", widget: widget))
        }
    }

    // MARK: - Internal report mutation

    private func mutateReport(_ mutation: (inout WorkflowReport) -> Void) {
        appState?.updateWorkflowReport(id: reportID, runtimeID: runtimeID, mutation: mutation)
    }
}

enum WorkflowError: Error, LocalizedError {
    case subAgentFailed(label: String, underlying: Error)
    case noWorkflowMatch(slashCommand: String)
    case missingArgs(workflow: String)
    case noActiveRuntime
    /// rc18:schema 模式下子 agent 在 round cap 内没能产出合规结构化输出。
    case structuredOutputUnavailable(reason: String)
    /// rc18:JSON Codable decode 失败 —— validate 过了但 Decodable 类型
    /// 对不上(很罕见,通常是 schema 和 Swift 类型不一致)。
    case structuredOutputDecodeFailed(label: String, underlying: Error, json: String)
    /// rc40:所有子任务(维度)都失败了 —— 别再伪装成绿勾成功,直接 fail。
    case allTasksFailed(reason: String)
    /// rc40:整个 workflow 超过看门狗时限还没结束(大概率某个子 agent 的
    /// provider 请求 stall) —— 抛出让卡片变 failed 并给出原因,而不是永远挂着。
    case timedOut(seconds: Double)

    var errorDescription: String? {
        switch self {
        case .subAgentFailed(let label, let underlying):
            return "Sub-agent \"\(label)\" failed: \(underlying.localizedDescription)"
        case .noWorkflowMatch(let cmd):
            return "Unknown workflow: \(cmd)"
        case .missingArgs(let workflow):
            return "Workflow \(workflow) requires input args."
        case .noActiveRuntime:
            return "No active Agent session to run this workflow in."
        case .structuredOutputUnavailable(let reason):
            return "Structured output unavailable: \(reason)"
        case .structuredOutputDecodeFailed(let label, let underlying, let json):
            let preview = json.prefix(120)
            return "Structured output for \"\(label)\" passed schema but failed Codable decode (\(underlying.localizedDescription)). JSON head: \(preview)"
        case .allTasksFailed(let reason):
            return reason
        case .timedOut(let seconds):
            return "Workflow timed out after \(Int(seconds))s with no result. The model/provider likely never responded — check the provider connection (for some.im-hosted models, confirm the account is still signed in)."
        }
    }
}
