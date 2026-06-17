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
    weak var appState: AppState?

    init(
        reportID: UUID,
        runtimeID: UUID,
        workspaceURL: URL?,
        configuration: AgentConfiguration,
        appState: AppState
    ) {
        self.reportID = reportID
        self.runtimeID = runtimeID
        self.workspaceURL = workspaceURL
        self.configuration = configuration
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
                workspaceURL: workspaceURL
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
        }
    }
}
