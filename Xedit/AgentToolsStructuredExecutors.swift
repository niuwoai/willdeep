//
//  AgentToolsStructuredExecutors.swift
//  WillDeep
//
//  Managed lifecycle adapters for ACP, Codex app-server, and structured
//  Claude/Codex process execution.
//

import Foundation

extension AgentToolRunner {
    static func runACPDelegatedAgent(
        _ configuration: AgentACPConfiguration,
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        let runInBackground = arguments["run_in_background"]?.boolValue() ?? true
        let canDetach = runInBackground
            && context.jobRegistry != nil
            && context.runtimeID != nil
        let registry: AgentJobRegistry
        if let sharedRegistry = context.jobRegistry {
            registry = sharedRegistry
        } else {
            registry = await MainActor.run { AgentJobRegistry() }
        }
        let runtimeID = context.runtimeID ?? UUID()
        let requestedTimeout = arguments["timeout_seconds"]?.intValue()
        let timeout: Double? = requestedTimeout.map {
            Double(min(max($0, 1), Int(delegatedAgentForegroundTimeout)))
        } ?? (canDetach ? nil : delegatedAgentForegroundTimeout)
        let jobID = UUID()
        let controller = AgentACPClientTurn(
            configuration: configuration,
            approvalHandler: context.delegatedApprovalHandler,
            readHandler: { url in
                if let provider = context.editableContentProvider {
                    return try provider(url)
                }
                return try String(contentsOf: url, encoding: .utf8)
            },
            writeHandler: context.delegatedFileWriteHandler,
            eventHandler: { events in
                await MainActor.run {
                    registry.recordManagedExecutorEvents(
                        id: jobID,
                        events: events
                    )
                }
            },
            processHandler: { pid in
                await MainActor.run {
                    registry.updateManagedExecutorProcess(id: jobID, pid: pid)
                }
            }
        )
        let job = await MainActor.run {
            registry.registerManagedExecutor(
                id: jobID,
                executor: .claudeCode,
                displayCommand: "Claude Code ACP",
                workingDirectory: configuration.workingDirectory,
                runtimeID: runtimeID,
                turnID: context.turnID,
                timeoutSeconds: timeout,
                publishesCompletion: canDetach,
                cancellation: { controller.cancel() }
            )
        }

        Task {
            do {
                let result = try await controller.run()
                let status: AgentBackgroundJob.Status = result.status == .completed
                    ? .completed
                    : (result.status == .cancelled ? .killed : .failed)
                await MainActor.run {
                    registry.finishManagedExecutor(
                        id: jobID,
                        status: status,
                        exitCode: status == .completed ? 0 : -1
                    )
                }
            } catch {
                let detail = AgentSecretStore.redact(
                    error.localizedDescription,
                    secretValues: context.secretRedactionValues
                )
                await MainActor.run {
                    registry.recordManagedExecutorEvents(
                        id: jobID,
                        events: [AgentExecutorEvent(
                            kind: .warning,
                            detail: detail,
                            status: .failed
                        )]
                    )
                    registry.finishManagedExecutor(
                        id: jobID,
                        status: .failed,
                        exitCode: -1
                    )
                }
            }
        }

        if canDetach {
            let timeoutLine = timeout.map { "\nTimeout: \(Int($0))s" } ?? ""
            return AgentToolResult(
                summary: "▶ \(job.displayHandle) started",
                payload: """
                Started Claude Code ACP job \(job.displayHandle).
                cwd: \(configuration.workingDirectory.path)\(timeoutLine)

                Claude permissions, filesystem access, and terminal commands are routed through WillDeep. Events are streaming into the job registry; use `get_job_output`, `list_jobs`, or `kill_job` while it runs.
                """
            )
        }

        let completedJob = try await withTaskCancellationHandler {
            while true {
                try Task.checkCancellation()
                if let snapshot = await MainActor.run(
                    body: { registry.job(id: job.id) }
                ), !snapshot.isAlive {
                    return snapshot
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } onCancel: {
            Task { @MainActor in
                _ = registry.killForStoppedTurn(id: job.id)
            }
        }
        await MainActor.run {
            registry.markCompletionSurfaced(id: job.id, forRuntime: runtimeID)
        }
        let resultText = await MainActor.run {
            registry.executorResultText(id: job.id)
        }
        let rawOutput = await MainActor.run {
            registry.output(id: job.id, tailLines: nil)
        }
        let detail = resultText.isEmpty ? rawOutput : resultText
        switch completedJob.status {
        case .completed:
            let usage = structuredUsageSummary(completedJob.executorUsage)
            let sessionLine = completedJob.executorSessionID.map {
                "\n\nSession: \($0)"
            } ?? ""
            return AgentToolResult(
                summary: "claude_code completed\(usage)",
                payload: detail + sessionLine
            )
        case .timedOut:
            throw AgentToolError.commandTimeout
        case .running:
            throw AgentToolError.commandFailed(
                -1,
                "Claude Code ACP job did not reach a terminal state."
            )
        case .failed, .killed, .launchFailed:
            throw AgentToolError.commandFailed(
                completedJob.exitCode ?? -1,
                detail
            )
        }
    }

    static func runCodexAppServerDelegatedAgent(
        _ configuration: AgentCodexAppServerConfiguration,
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        let runInBackground = arguments["run_in_background"]?.boolValue() ?? true
        let canDetach = runInBackground
            && context.jobRegistry != nil
            && context.runtimeID != nil
        let registry: AgentJobRegistry
        if let sharedRegistry = context.jobRegistry {
            registry = sharedRegistry
        } else {
            registry = await MainActor.run { AgentJobRegistry() }
        }
        let runtimeID = context.runtimeID ?? UUID()
        let requestedTimeout = arguments["timeout_seconds"]?.intValue()
        let timeout: Double? = requestedTimeout.map {
            Double(min(max($0, 1), Int(delegatedAgentForegroundTimeout)))
        } ?? (canDetach ? nil : delegatedAgentForegroundTimeout)
        let jobID = UUID()
        let controller = AgentCodexAppServerTurn(
            configuration: configuration,
            approvalHandler: context.delegatedApprovalHandler,
            eventHandler: { events in
                await MainActor.run {
                    registry.recordManagedExecutorEvents(
                        id: jobID,
                        events: events
                    )
                }
            },
            processHandler: { pid in
                await MainActor.run {
                    registry.updateManagedExecutorProcess(
                        id: jobID,
                        pid: pid
                    )
                }
            }
        )
        let job = await MainActor.run {
            registry.registerManagedExecutor(
                id: jobID,
                executor: .codexCLI,
                displayCommand: "Codex app-server",
                workingDirectory: configuration.workingDirectory,
                runtimeID: runtimeID,
                turnID: context.turnID,
                timeoutSeconds: timeout,
                publishesCompletion: canDetach,
                cancellation: {
                    controller.cancel()
                }
            )
        }

        Task {
            do {
                let result = try await controller.run()
                let status: AgentBackgroundJob.Status
                switch result.status {
                case .completed:
                    status = .completed
                case .cancelled:
                    status = .killed
                case .pending, .running, .failed:
                    status = .failed
                }
                await MainActor.run {
                    registry.finishManagedExecutor(
                        id: jobID,
                        status: status,
                        exitCode: status == .completed ? 0 : -1
                    )
                }
            } catch {
                let detail = AgentSecretStore.redact(
                    error.localizedDescription,
                    secretValues: context.secretRedactionValues
                )
                await MainActor.run {
                    registry.recordManagedExecutorEvents(
                        id: jobID,
                        events: [AgentExecutorEvent(
                            kind: .warning,
                            detail: detail,
                            status: .failed
                        )]
                    )
                    registry.finishManagedExecutor(
                        id: jobID,
                        status: .failed,
                        exitCode: -1
                    )
                }
            }
        }

        if canDetach {
            let timeoutLine = timeout.map { "\nTimeout: \(Int($0))s" } ?? ""
            return AgentToolResult(
                summary: "▶ \(job.displayHandle) started",
                payload: """
                Started bidirectional Codex app-server job \(job.displayHandle).
                cwd: \(configuration.workingDirectory.path)\(timeoutLine)

                Approval requests are routed through WillDeep. Events are streaming into the job registry; use `get_job_output`, `list_jobs`, or `kill_job` while it runs.
                """
            )
        }

        let completedJob = try await withTaskCancellationHandler {
            while true {
                try Task.checkCancellation()
                if let snapshot = await MainActor.run(
                    body: { registry.job(id: job.id) }
                ), !snapshot.isAlive {
                    return snapshot
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } onCancel: {
            Task { @MainActor in
                _ = registry.killForStoppedTurn(id: job.id)
            }
        }

        await MainActor.run {
            registry.markCompletionSurfaced(id: job.id, forRuntime: runtimeID)
        }
        let resultText = await MainActor.run {
            registry.executorResultText(id: job.id)
        }
        let rawOutput = await MainActor.run {
            registry.output(id: job.id, tailLines: nil)
        }
        let failureDetail = resultText.isEmpty ? rawOutput : resultText
        switch completedJob.status {
        case .completed:
            let usage = structuredUsageSummary(completedJob.executorUsage)
            let sessionLine = completedJob.executorSessionID.map {
                "\n\nSession: \($0)"
            } ?? ""
            return AgentToolResult(
                summary: "codex_cli completed\(usage)",
                payload: (resultText.isEmpty ? rawOutput : resultText)
                    + sessionLine
            )
        case .timedOut:
            throw AgentToolError.commandTimeout
        case .running:
            throw AgentToolError.commandFailed(
                -1,
                "Codex app-server job did not reach a terminal state."
            )
        case .failed, .killed, .launchFailed:
            throw AgentToolError.commandFailed(
                completedJob.exitCode ?? -1,
                failureDetail
            )
        }
    }

    static func runStructuredDelegatedAgent(
        _ specification: AgentExecutorProcessSpecification,
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        let runInBackground = arguments["run_in_background"]?.boolValue() ?? true
        let canDetach = runInBackground && context.jobRegistry != nil && context.runtimeID != nil
        let registry: AgentJobRegistry
        if let sharedRegistry = context.jobRegistry {
            registry = sharedRegistry
        } else {
            registry = await MainActor.run { AgentJobRegistry() }
        }
        let runtimeID = context.runtimeID ?? UUID()
        let requestedTimeout = arguments["timeout_seconds"]?.intValue()
        let timeout: Double? = requestedTimeout.map {
            Double(min(max($0, 1), Int(delegatedAgentForegroundTimeout)))
        } ?? (canDetach ? nil : delegatedAgentForegroundTimeout)

        let job: AgentBackgroundJob
        do {
            job = try await MainActor.run {
                try registry.startExecutor(
                    specification: specification,
                    runtimeID: runtimeID,
                    turnID: context.turnID,
                    timeoutSeconds: timeout,
                    publishesCompletion: canDetach,
                    secretRedactionValues: context.secretRedactionValues
                )
            }
        } catch {
            throw AgentToolError.commandFailed(
                -1,
                AgentSecretStore.redact(
                    error.localizedDescription,
                    secretValues: context.secretRedactionValues
                )
            )
        }
        if job.status == .launchFailed {
            await MainActor.run {
                registry.markCompletionSurfaced(id: job.id, forRuntime: runtimeID)
            }
            let detail: String
            if let eventDetail = job.latestExecutorEvent?.detail {
                detail = eventDetail
            } else {
                detail = await MainActor.run { registry.output(id: job.id) }
            }
            throw AgentToolError.commandFailed(-1, detail)
        }
        if specification.executor == .claudeCode,
           context.delegatedApprovalHandler != nil {
            await MainActor.run {
                registry.recordExecutorNotice(
                    id: job.id,
                    detail: """
                    Claude Code capability note: this CLI build does not expose a fail-closed stdio permission callback. WillDeep is streaming structured events and can resume the session, but Claude permissions remain enforced by its CLI mode plus the outer WillDeep sandbox.
                    """
                )
            }
        }

        if canDetach {
            let timeoutLine = timeout.map { "\nTimeout: \(Int($0))s" } ?? ""
            return AgentToolResult(
                summary: "▶ \(job.displayHandle) started",
                payload: """
                Started structured \(specification.executor.rawValue) job \(job.displayHandle).
                PID: \(job.pid)
                cwd: \(job.workingDirectoryPath ?? specification.workingDirectory?.path ?? "")\(timeoutLine)

                Events are streaming into the job registry. You will receive a completion notification on a later turn; use `get_job_output`, `list_jobs`, or `kill_job` while it runs.
                """
            )
        }

        let completedJob = try await withTaskCancellationHandler {
            while true {
                try Task.checkCancellation()
                if let snapshot = await MainActor.run(body: { registry.job(id: job.id) }),
                   !snapshot.isAlive {
                    return snapshot
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } onCancel: {
            Task { @MainActor in
                _ = registry.killForStoppedTurn(id: job.id)
            }
        }

        await MainActor.run {
            registry.markCompletionSurfaced(id: job.id, forRuntime: runtimeID)
        }
        let resultText = await MainActor.run {
            registry.executorResultText(id: job.id)
        }
        let rawOutput = await MainActor.run {
            registry.output(id: job.id, tailLines: nil)
        }
        let failureDetail = resultText.isEmpty ? rawOutput : resultText

        switch completedJob.status {
        case .completed:
            let usage = structuredUsageSummary(completedJob.executorUsage)
            let payload = resultText.isEmpty ? rawOutput : resultText
            let sessionLine = completedJob.executorSessionID.map {
                "\n\nSession: \($0)"
            } ?? ""
            return AgentToolResult(
                summary: "\(specification.executor.rawValue) completed\(usage)",
                payload: payload + sessionLine
            )
        case .timedOut:
            throw AgentToolError.commandTimeout
        case .running:
            throw AgentToolError.commandFailed(-1, "Structured agent job did not reach a terminal state.")
        case .failed, .killed, .launchFailed:
            throw AgentToolError.commandFailed(
                completedJob.exitCode ?? -1,
                failureDetail
            )
        }
    }
}
