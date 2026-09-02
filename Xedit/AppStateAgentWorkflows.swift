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

enum WorkflowStartResult: Equatable {
    case started(reportID: UUID)
    case rejected(reason: String)
    case notRecognized

    var commandWasRecognized: Bool {
        if case .notRecognized = self { return false }
        return true
    }
}

extension AppState {
    /// Slash 命令 (`/research`, `/code-review`, ...) 触发入口。
    /// 返回 true 表示命令已由 workflow 层认领（可能启动，也可能因参数
    /// 缺失而明确拒绝）；false 表示未识别，让其他 slash handler 继续。
    @discardableResult
    func startWorkflow(slashCommand: String, args: String) -> Bool {
        let result = startWorkflow(
            slashCommand: slashCommand,
            args: args,
            runtimeID: activeRuntime?.id,
            notifyAgentOnCompletion: false
        )
        return result.commandWasRecognized
    }

    /// Session-explicit workflow entry used by `run_workflow`. Unlike the
    /// composer wrapper above, this never consults `activeRuntime`, so a tool
    /// call finishing in background session A cannot put its card in the
    /// currently visible session B.
    @discardableResult
    func startWorkflow(
        slashCommand: String,
        args: String,
        runtimeID: UUID?,
        notifyAgentOnCompletion: Bool
    ) -> WorkflowStartResult {
        guard let workflow = WorkflowRegistry.find(slashCommand: slashCommand) else {
            // 1.85.0-rc6:slash 没匹配任何内置/用户 workflow 时,如果有
            // 用户 workflow.yaml 解析失败,顺手把错误浮上来给用户看 ——
            // 否则用户写错 yaml 后 slash 命令静默"不存在",根本不知道
            // 是 yaml 语法错。注意只 set message 不 return true,常规
            // slash palette 仍然有机会处理这条命令(可能是别的功能)。
            if let banner = UserWorkflowRegistry.errorBanner(),
               let runtimeID,
               let runtime = runtime(for: runtimeID) {
                runtime.errorMessage = banner
                runtime.errorSeverity = .error
            }
            return .notRecognized
        }

        return startWorkflow(
            workflow: workflow,
            args: args,
            runtimeID: runtimeID,
            notifyAgentOnCompletion: notifyAgentOnCompletion
        )
    }

    /// Definition-explicit overload kept internal so lifecycle tests can use
    /// deterministic workflows without reaching a real model/provider.
    @discardableResult
    func startWorkflow(
        workflow: any WorkflowDefinition,
        args: String,
        runtimeID: UUID?,
        notifyAgentOnCompletion: Bool
    ) -> WorkflowStartResult {
        let trimmedArgs = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let runtimeID, let runtime = runtime(for: runtimeID) else {
            let reason = WorkflowError.noActiveRuntime.errorDescription ?? "No Agent session."
            agentErrorMessage = reason
            return .rejected(reason: reason)
        }
        if !workflow.allowsEmptyArgs && trimmedArgs.isEmpty {
            let reason = WorkflowError.missingArgs(workflow: workflow.displayTitle).errorDescription
                ?? "Workflow input is required."
            runtime.errorMessage = reason
            return .rejected(reason: reason)
        }

        let workspaceLocation = runtime.workspaceLocation
            ?? runtime.workspaceRootPath.map { .local(path: $0) }
        let workspaceURL: URL?
        do {
            workspaceURL = try runtime.localWorkspaceURLForOptimisticUse()
        } catch {
            runtime.errorMessage = error.localizedDescription
            return .rejected(reason: error.localizedDescription)
        }
        let runtimeDescriptor = workspaceLocation?.remoteRuntimeID.flatMap {
            AgentRuntimeStore.descriptor(id: $0)
        }
        runtime.errorMessage = nil

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
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)

        // 3. 起后台 Task 跑 engine，并把句柄留在 owning runtime 里供卡片
        // stop / 会话删除 / clear conversation 精确取消。
        let configuration = configurationForCurrentTurn(for: runtime)
        // 省心托管:主循环每回合跑 routing judge 解析具体虚拟模型
        // (AppStateAgentLoop),workflow 之前直接拿原始配置里的静态模型,
        // 完全绕过托管路由 —— 与 5dd9273a 修的 someIMContext 缺失同族,
        // some.im 托管会话的子 agent 请求与主循环行为不一致。workflow
        // 是多 agent 编排,天然复杂任务,不必再问 judge:floor 与 high
        // 取高者直接解析。非托管/非 some.im 会话为 nil,不动配置。
        let managedFloor: AgentManagedCapabilityTier? =
            configuration.providerID == AgentProviderPreset.someIMID
                ? runtime.managedRouting?.minimumTier
                : nil
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

        let workflowTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 标记 running。
            await MainActor.run {
                self.updateWorkflowReport(id: report.id, runtimeID: runtimeID) { r in
                    r.status = .running
                }
                self.persistWorkflowRuntime(runtimeID: runtimeID)
            }

            var workflowConfiguration = configuration
            if let managedFloor {
                let hasCodingPlan = await self.refreshedSomeIMCodingPlanStatusIfNeeded().isActiveNow
                workflowConfiguration.model = Self.managedWorkflowModel(
                    floor: managedFloor,
                    domain: workflow.managedDomain,
                    hasCodingPlan: hasCodingPlan
                )
            }

            let engine = WorkflowEngine(
                reportID: report.id,
                runtimeID: runtimeID,
                workspaceURL: workspaceURL,
                workspaceLocation: workspaceLocation,
                runtimeDescriptor: runtimeDescriptor,
                configuration: workflowConfiguration,
                someIMContext: someIMContext,
                appState: self
            )

            do {
                try Task.checkCancellation()
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
                    self.finishWorkflowRun(
                        reportID: report.id,
                        runtimeID: runtimeID,
                        notifyAgentOnCompletion: notifyAgentOnCompletion
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.updateWorkflowReport(id: report.id, runtimeID: runtimeID) { r in
                        r.status = .cancelled
                        r.finishedAt = Date()
                        if r.summary.isEmpty {
                            r.summary = L10n.WorkflowCard.cancelledByUser
                        }
                    }
                    self.finishWorkflowRun(
                        reportID: report.id,
                        runtimeID: runtimeID,
                        notifyAgentOnCompletion: notifyAgentOnCompletion
                    )
                }
            } catch {
                await MainActor.run {
                    self.updateWorkflowReport(id: report.id, runtimeID: runtimeID) { r in
                        r.status = .failed
                        r.finishedAt = Date()
                        if r.summary.isEmpty {
                            r.summary = L10n.WorkflowCard.failed(error.localizedDescription)
                        }
                    }
                    self.finishWorkflowRun(
                        reportID: report.id,
                        runtimeID: runtimeID,
                        notifyAgentOnCompletion: notifyAgentOnCompletion
                    )
                }
            }
        }
        runtime.workflowTasks[report.id] = workflowTask

        return .started(reportID: report.id)
    }

    /// Stop a live workflow immediately. The optimistic report mutation makes
    /// the UI respond on the click; the task's cancellation handler then
    /// tears down watchdog/subagent work and performs final persistence.
    func cancelWorkflow(reportID: UUID, runtimeID: UUID? = nil) {
        let owner: AgentRuntime? = {
            if let runtimeID { return runtime(for: runtimeID) }
            return agentRuntimes.values.first(where: { runtime in
                runtime.workflowTasks[reportID] != nil
                    || runtime.messages.contains(where: {
                        $0.workflowReport?.id == reportID
                    })
            })
        }()
        guard let owner else { return }

        if owner.messages.contains(where: { $0.workflowReport?.id == reportID && $0.workflowReport?.consultation != nil }) {
            stopAgentConsultation(reportID: reportID)
            return
        }
        guard let task = owner.workflowTasks[reportID] else { return }
        updateWorkflowReport(id: reportID, runtimeID: owner.id) { report in
            guard report.status == .planning || report.status == .running else { return }
            report.status = .cancelled
            report.finishedAt = Date()
            if report.summary.isEmpty {
                report.summary = L10n.WorkflowCard.cancelledByUser
            }
        }
        persistWorkflowRuntime(runtimeID: owner.id)
        task.cancel()
    }

    func cancelAllWorkflows(for runtime: AgentRuntime) {
        let tasks = Array(runtime.workflowTasks.values)
        runtime.workflowTasks.removeAll()
        runtime.pendingWorkflowCompletionReportIDs.removeAll()
        for task in tasks { task.cancel() }
    }

    private func finishWorkflowRun(
        reportID: UUID,
        runtimeID: UUID,
        notifyAgentOnCompletion: Bool
    ) {
        guard let runtime = runtime(for: runtimeID) else { return }
        let wasTracked = runtime.workflowTasks.removeValue(forKey: reportID) != nil
        persistWorkflowRuntime(runtimeID: runtimeID)
        // clear conversation / session deletion removes task handles before
        // cancellation. The late cancellation callback must not wake a session
        // the user has intentionally cleared or deleted.
        guard wasTracked,
              notifyAgentOnCompletion,
              !runtime.pendingWorkflowCompletionReportIDs.contains(reportID) else { return }
        runtime.pendingWorkflowCompletionReportIDs.append(reportID)
        if let report = runtime.messages.compactMap(\.workflowReport).first(where: { $0.id == reportID }) {
            publishWorkflowKernelEvent(report, runtime: runtime)
        } else {
            resumeAgentLoopForPendingBackgroundCompletions(for: runtime)
        }
    }

    func consumePendingWorkflowCompletions(for runtime: AgentRuntime) -> [WorkflowReport] {
        let ids = runtime.pendingWorkflowCompletionReportIDs
        runtime.pendingWorkflowCompletionReportIDs.removeAll()
        guard !ids.isEmpty else { return [] }
        let reportsByID: [UUID: WorkflowReport] = Dictionary(
            uniqueKeysWithValues: runtime.messages.compactMap { message in
                guard let report = message.workflowReport else { return nil }
                return (report.id, report)
            }
        )
        return ids.compactMap { reportsByID[$0] }
    }

    nonisolated static func workflowCompletionNotice(for report: WorkflowReport) -> String {
        let summary = report.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        <workflow-completion>
        workflow: \(report.workflowName)
        status: \(report.status.rawValue)
        report_id: \(report.id.uuidString)
        summary:
        \(summary.isEmpty ? "(no summary)" : summary)
        </workflow-completion>

        A workflow you started has finished. Use its result to continue the user's task. Do not merely announce completion; synthesize the useful outcome, or explain the failure/cancellation and the next actionable step.
        """
    }

    /// 省心托管会话里 workflow 子 agent 的主模型解析:floor 与 high 取
    /// 高者(workflow 天然是复杂任务,不再走每回合 judge),按任务域映射
    /// 到 some.im 虚拟模型。纯函数,单测覆盖。
    static func managedWorkflowModel(
        floor: AgentManagedCapabilityTier,
        domain: SomeIMManagedDomain,
        hasCodingPlan: Bool
    ) -> String {
        SomeIMManagedModel.resolve(
            domain: domain,
            tier: max(floor, .high),
            hasCodingPlan: hasCodingPlan
        )
    }

    /// 单次 workflow 运行的看门狗时限。某个子 agent 的 provider 请求 stall（例如
    /// some.im 调用一直不返回流）时，本会让整张卡片永远空转、无任何反馈；超过此
    /// 时限则把它转成 `.failed` 卡片并给出原因。取值偏宽松以免误杀大 diff 的正常
    /// review（4 个子 agent 并发、各自还带 120s 请求超时）。
    static let workflowWatchdogSeconds: Double = 360

    /// 让 `operation` 和一个截止时间赛跑；截止时间先到就抛
    /// `WorkflowError.timedOut`。不能用 `withThrowingTaskGroup` 实现这里：
    /// task group 退出前会等待所有子任务真正结束，如果 provider stream
    /// 卡在不响应 cancellation 的网络读取里，workflow 卡片仍会一直空转。
    /// 这里用非结构化任务守住 UI 反馈边界：超时后立即恢复调用方，同时
    /// 尝试取消仍在跑的 operation。
    static func runWorkflowWithWatchdog<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = WorkflowWatchdogRace<T>()
        let operationTask = Task {
            try await operation()
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: workflowWatchdogNanoseconds(for: seconds))
                operationTask.cancel()
                race.resume(.failure(WorkflowError.timedOut(seconds: seconds)))
            } catch {
                operationTask.cancel()
                race.resume(.failure(error))
            }
        }
        let relayTask = Task {
            do {
                let value = try await operationTask.value
                timeoutTask.cancel()
                race.resume(.success(value))
            } catch {
                timeoutTask.cancel()
                race.resume(.failure(error))
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
            }
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            relayTask.cancel()
            race.resume(.failure(CancellationError()))
        }
    }

    private static func workflowWatchdogNanoseconds(for seconds: Double) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let maxSeconds = Double(UInt64.max) / 1_000_000_000
        return UInt64(min(seconds, maxSeconds) * 1_000_000_000)
    }

    /// Engine 内部调。找到目标 runtime 里持有这个 report 的 message，
    /// mutate 它的 workflowReport 字段后整体 reassign 触发 @Published。
    func updateWorkflowReport(
        id: UUID,
        runtimeID: UUID,
        mutation: (inout WorkflowReport) -> Void
    ) {
        // `runtime(for:)` 而非裸 `agentRuntimes[...]`:workflow 跑到一半
        // 会话被 idle-runtime 驱逐的话,裸查找会让后续所有状态更新静默
        // no-op,卡片永远冻结 —— 与后台作业回调同款兜底(见 AppState
        // onJobFinished 的注释)。
        guard let runtime = runtime(for: runtimeID) else { return }
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

nonisolated private final class WorkflowWatchdogRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pendingResult: Result<T, Error>?
    private var completed = false

    // Explicit (empty) deinit on purpose. Swift 6.3.1 crashes in the
    // SIL EarlyPerfInliner while inlining this generic class's *synthesized*
    // deallocating deinit under Release optimization (`-O -enable-default-cmo`),
    // intermittently breaking release archives. Providing an explicit deinit
    // body changes how the destructor is emitted and sidesteps the inliner bug.
    // Do not remove without re-testing a Release archive on the pinned toolchain.
    deinit {}

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let resultToResume: Result<T, Error>?
        lock.lock()
        if completed {
            resultToResume = nil
        } else if let pendingResult {
            completed = true
            self.pendingResult = nil
            resultToResume = pendingResult
        } else {
            self.continuation = continuation
            resultToResume = nil
        }
        lock.unlock()

        if let resultToResume {
            continuation.resume(with: resultToResume)
        }
    }

    func resume(_ result: Result<T, Error>) {
        let continuationToResume: CheckedContinuation<T, Error>?
        lock.lock()
        if completed {
            continuationToResume = nil
        } else if let continuation {
            completed = true
            self.continuation = nil
            continuationToResume = continuation
        } else {
            pendingResult = result
            continuationToResume = nil
        }
        lock.unlock()

        continuationToResume?.resume(with: result)
    }
}
