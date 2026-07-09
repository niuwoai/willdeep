//
//  AppStateAgentWorkflows.swift
//  WillDeep
//
//  AppState extension承接 1.81.0-rc1 Workflow 特性的 wiring：
//   - `startWorkflow(slashCommand:args:)`：slash 命令分发入口；找到匹配
//     的 WorkflowDefinition、塞一条 `.workflowReport` message 到
//     transcript、起一个后台 Task 跑 engine。
//   - `updateWorkflowReport(id:runtimeID:mutation:)`：engine 边跑边调用，
//     找到对应消息 mutate 上面挂的 WorkflowReport，触发 SwiftUI 重渲染。
//

import Foundation

extension AppState {
    /// Slash 命令 (`/research`, `/code-review`, ...) 触发入口。
    /// 返回 true 表示已认领并启动，调用方应清空 composer；false 表示
    /// 没识别成 workflow 命令（让常规 slash command palette 继续处理）。
    @discardableResult
    func startWorkflow(slashCommand: String, args: String) -> Bool {
        guard let workflow = WorkflowRegistry.find(slashCommand: slashCommand) else {
            // 1.85.0-rc6:slash 没匹配任何内置/用户 workflow 时,如果有
            // 用户 workflow.yaml 解析失败,顺手把错误浮上来给用户看 ——
            // 否则用户写错 yaml 后 slash 命令静默"不存在",根本不知道
            // 是 yaml 语法错。注意只 set message 不 return true,常规
            // slash palette 仍然有机会处理这条命令(可能是别的功能)。
            if let banner = UserWorkflowRegistry.errorBanner() {
                agentErrorMessage = banner
            }
            return false
        }
        let trimmedArgs = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if !workflow.allowsEmptyArgs && trimmedArgs.isEmpty {
            agentErrorMessage = WorkflowError.missingArgs(workflow: workflow.displayTitle).errorDescription
            return true
        }
        guard let runtime = activeRuntime else {
            agentErrorMessage = WorkflowError.noActiveRuntime.errorDescription
            return true
        }

        // 1. 创建一个初始 report。
        let report = WorkflowReport(
            workflowName: workflow.name,
            displayTitle: workflow.displayTitle,
            args: trimmedArgs,
            status: .planning
        )

        // 2. 塞进 transcript（runtime.messages）。
        let card = AgentMessage(
            role: .workflowReport,
            content: "",
            workflowReport: report
        )
        runtime.messages.append(card)

        // 3. 起后台 Task 跑 engine。capture 弱引用避免 runtime 被释放后
        // 还往里写。
        let runtimeID = runtime.id
        let workspaceURL = rootDirectory
        let configuration = agentConfiguration
        // some.im session/workspace context headers, built exactly like the main
        // loop (AppStateAgentLoop). Every subagent request needs these on a
        // some.im-gated provider — without them some.im stalls the call and the
        // card hangs empty. nil for non-some.im providers.
        let someIMContext: SomeIMRequestContext? = {
            guard configuration.providerID == AgentProviderPreset.someIMID else { return nil }
            let workspaceID = AgentWorkspaceIdentityStore.workspaceID(
                forWorkspaceKey: Self.managedWorkspaceKey(for: runtime)
            )
            return SomeIMRequestContext(sessionID: runtimeID.uuidString, workspaceID: workspaceID)
        }()

        Task { [weak self] in
            guard let self else { return }
            // 标记 running。
            await MainActor.run {
                self.updateWorkflowReport(id: report.id, runtimeID: runtimeID) { r in
                    r.status = .running
                }
            }

            let engine = WorkflowEngine(
                reportID: report.id,
                runtimeID: runtimeID,
                workspaceURL: workspaceURL,
                configuration: configuration,
                someIMContext: someIMContext,
                appState: self
            )

            do {
                // Watchdog so a stalled provider request surfaces as a `.failed`
                // card instead of hanging forever with no feedback.
                let summary = try await Self.runWorkflowWithWatchdog(seconds: Self.workflowWatchdogSeconds) {
                    try await workflow.run(engine: engine, args: trimmedArgs)
                }
                await MainActor.run {
                    self.updateWorkflowReport(id: report.id, runtimeID: runtimeID) { r in
                        r.summary = summary
                        r.status = .done
                        r.finishedAt = Date()
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.updateWorkflowReport(id: report.id, runtimeID: runtimeID) { r in
                        r.status = .cancelled
                        r.finishedAt = Date()
                    }
                }
            } catch {
                await MainActor.run {
                    self.updateWorkflowReport(id: report.id, runtimeID: runtimeID) { r in
                        r.status = .failed
                        r.finishedAt = Date()
                        if r.summary.isEmpty {
                            r.summary = "Workflow failed: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }

        return true
    }

    /// 单次 workflow 运行的看门狗时限。某个子 agent 的 provider 请求 stall（例如
    /// some.im 调用一直不返回流）时，本会让整张卡片永远空转、无任何反馈；超过此
    /// 时限则把它转成 `.failed` 卡片并给出原因。取值偏宽松以免误杀大 diff 的正常
    /// review（4 个子 agent 并发、各自还带 120s 请求超时）。
    static let workflowWatchdogSeconds: Double = 360

    /// 让 `operation` 和一个截止时间赛跑；截止时间先到就抛
    /// `WorkflowError.timedOut`。范式对齐 `AgentTerminalTools` 的
    /// `withTerminalSnapshotTimeout`。注意：输的那个分支会被 `cancelAll` 取消，
    /// 但若子任务卡在不响应取消的网络请求里，它会继续跑到自身请求超时才真正结束
    /// —— 这里只保证调用方（卡片）立即拿到失败结果、不再挂死。
    static func runWorkflowWithWatchdog<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw WorkflowError.timedOut(seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw WorkflowError.timedOut(seconds: seconds)
            }
            return first
        }
    }

    /// Engine 内部调。找到目标 runtime 里持有这个 report 的 message，
    /// mutate 它的 workflowReport 字段后整体 reassign 触发 @Published。
    func updateWorkflowReport(
        id: UUID,
        runtimeID: UUID,
        mutation: (inout WorkflowReport) -> Void
    ) {
        guard let runtime = agentRuntimes[runtimeID] else { return }
        guard let idx = runtime.messages.firstIndex(where: {
            $0.role == .workflowReport && $0.workflowReport?.id == id
        }) else { return }
        var msg = runtime.messages[idx]
        guard var report = msg.workflowReport else { return }
        mutation(&report)
        msg.workflowReport = report
        runtime.messages[idx] = msg
    }
}
