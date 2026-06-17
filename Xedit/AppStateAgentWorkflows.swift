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
                appState: self
            )

            do {
                let summary = try await workflow.run(engine: engine, args: trimmedArgs)
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
