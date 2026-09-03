//
//  AppStateAgentLoopToolBatching.swift
//  WillDeep
//
//  Split out of AppStateAgentLoop.swift to keep files under the repository
//  size limit. Owns what runAgentLoop delegates to rather than what it is:
//  the read-only parallel tool batch, patch-review path keys, and the serial
//  tool-decision handoff (activateSerialToolDecision / awaitToolDecision).
//

import AppKit
import Foundation

extension AppState {
    /// Read-tier tools safe to execute concurrently inside one model round:
    /// pure local workspace reads with no side effects. `.read` risk already
    /// guarantees auto-run (no approval card, no plan gate), and none of
    /// these can enter the sandbox-escalation flow — that flow suspends on
    /// the runtime's single tool-decision waiter, which concurrent calls
    /// must never share. `run_command` stays serial even when classified
    /// read-only for exactly that reason; `spawn_agent` has its own
    /// dispatch path and is likewise excluded.
    nonisolated static let parallelReadBatchToolNames: Set<String> = [
        "read_file", "search_files", "grep_files", "list_directory", "glob", "git_status"
    ]

    /// Local file tools whose pending proposals can share one review boundary
    /// when the model emits them consecutively in the same assistant turn.
    /// Other write surfaces keep their existing per-call authorization.
    nonisolated static let patchReviewToolNames: Set<String> = [
        "create_file", "edit_file", "apply_patch"
    ]

    /// Conservative path identities used only to decide whether adjacent
    /// patch tools may share a review boundary. Nil means "unknown target" and
    /// forces the current batch to settle before another file tool runs.
    static func patchReviewPathKeys(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> Set<String>? {
        let rawPaths: [String]
        switch toolName {
        case "create_file", "edit_file":
            guard let path = arguments["path"]?.stringValue() else { return nil }
            rawPaths = [path]
        case "apply_patch":
            guard let rawDiff = arguments["diff"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !rawDiff.isEmpty else {
                return nil
            }
            let extractedBlocks = AgentPatchApplier.extractDiffBlocks(from: rawDiff)
            let diff = extractedBlocks.count == 1 ? extractedBlocks[0] : rawDiff
            guard let changes = try? AgentPatchApplier.parse(diff), !changes.isEmpty else {
                return nil
            }
            rawPaths = changes.map(\.path)
        default:
            return nil
        }

        let keys = rawPaths.compactMap { rawPath -> String? in
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return URL(fileURLWithPath: trimmed)
                .standardizedFileURL
                .path
                .precomposedStringWithCanonicalMapping
                .lowercased()
        }
        guard keys.count == rawPaths.count else { return nil }
        return Set(keys)
    }

    /// One read-tier staged call collected for concurrent execution. Risk,
    /// sandbox decision, tool record, and execution context are all resolved
    /// at collection time; only `AgentToolRunner.run` itself fans out.
    struct AgentPendingParallelRead {
        let externalID: String
        let toolName: String
        let arguments: [String: AgentJSONValue]
        let sandboxDecision: AgentSandboxDecision
        let recordID: AgentToolCall.ID
        let context: AgentToolContext
    }

    struct AgentPendingParallelSpawn {
        let call: AgentMessageToolCall
        let arguments: [String: AgentJSONValue]
        let recordID: AgentToolCall.ID
        let messageBuffer: AgentSpawnToolMessageBuffer
    }

    func executeParallelSpawnBatch(
        _ batch: inout [AgentPendingParallelSpawn],
        runtime: AgentRuntime,
        configuration: AgentConfiguration,
        workspaceURL: URL?,
        runtimeDescriptor: RuntimeDescriptor?,
        workspaceLocation: WorkspaceLocation?,
        executor: (@MainActor (AgentPendingParallelSpawn) async -> Void)? = nil
    ) async -> Bool {
        guard !batch.isEmpty else { return false }
        let entries = batch
        batch.removeAll()

        func execute(_ entry: AgentPendingParallelSpawn) async {
            if let executor {
                await executor(entry)
                return
            }
            await executeSpawnAgentToolCall(
                entry.call,
                recordID: entry.recordID,
                arguments: entry.arguments,
                runtime: runtime,
                configuration: configuration,
                workspaceURL: workspaceURL,
                runtimeDescriptor: runtimeDescriptor,
                workspaceLocation: workspaceLocation,
                deferredToolMessage: entry.messageBuffer
            )
        }

        if entries.count == 1 {
            let entry = entries[0]
            await execute(entry)
        } else {
            await withTaskGroup(of: Int.self) { group in
                var nextIndex = 0
                let initialCount = min(entries.count, AgentSubagentRegistry.maxConcurrentPerRuntime)
                for index in 0..<initialCount {
                    let entry = entries[index]
                    group.addTask { @MainActor in
                        await execute(entry)
                        return index
                    }
                    nextIndex += 1
                }
                while await group.next() != nil {
                    guard nextIndex < entries.count else { continue }
                    let index = nextIndex
                    let entry = entries[index]
                    group.addTask { @MainActor in
                        await execute(entry)
                        return index
                    }
                    nextIndex += 1
                }
            }
        }

        for entry in entries {
            if let message = entry.messageBuffer.message {
                appendDeferredSpawnToolMessage(message, runtime: runtime)
            }
        }
        return Task.isCancelled
    }

    /// Execute a collected batch of read-tier tool calls concurrently and
    /// fold the outcomes back in the model's original call order — records
    /// in `runtime.toolCalls` were already appended in order during staging,
    /// and tool messages are appended in order here. Returns `true` when the
    /// enclosing turn must stop (cancellation), mirroring the serial path's
    /// early return.
    // Internal rather than private: runAgentLoop in AppStateAgentLoop.swift
    // is the only caller, and it now lives in a different file.
    func executeParallelReadBatch(
        _ batch: inout [AgentPendingParallelRead],
        runtime: AgentRuntime
    ) async -> Bool {
        guard !batch.isEmpty else { return false }
        let entries = batch
        batch.removeAll()

        var outcomes = [Result<AgentToolResult, Error>?](repeating: nil, count: entries.count)
        if entries.count == 1 {
            // Single read: skip the group machinery, byte-identical to the
            // old serial execution.
            do {
                outcomes[0] = .success(
                    try await AgentToolRunner.run(
                        name: entries[0].toolName,
                        arguments: entries[0].arguments,
                        context: entries[0].context
                    )
                )
            } catch {
                outcomes[0] = .failure(error)
            }
        } else {
            await withTaskGroup(of: (Int, Result<AgentToolResult, Error>).self) { group in
                for (index, entry) in entries.enumerated() {
                    let toolName = entry.toolName
                    let arguments = entry.arguments
                    let context = entry.context
                    group.addTask {
                        do {
                            let result = try await AgentToolRunner.run(
                                name: toolName,
                                arguments: arguments,
                                context: context
                            )
                            return (index, .success(result))
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                }
                for await (index, outcome) in group {
                    outcomes[index] = outcome
                }
            }
        }

        var stopTurn = false
        for (index, entry) in entries.enumerated() {
            switch outcomes[index] {
            case .success(let result):
                if let recordIndex = runtime.toolCalls.firstIndex(where: { $0.id == entry.recordID }) {
                    runtime.toolCalls[recordIndex].status = .succeeded
                    runtime.toolCalls[recordIndex].result = result
                    runtime.toolCalls[recordIndex].arguments[AgentSandboxPolicy.sandboxEscalationRequestArgumentKey] = .bool(false)
                }
                runtime.recordComputerUseActivity(toolName: entry.toolName, images: result.images)
                // First-hand repository inspection. Only successes count:
                // a grep that found nothing taught this session nothing, and
                // must not accumulate into evidence that the work is too big.
                runtime.deepAdmissionObservation.recordToolSuccess(entry.toolName)
                AgentSandboxAuditLog.append(
                    toolName: entry.toolName,
                    arguments: entry.arguments,
                    decision: entry.sandboxDecision,
                    approvalSource: nil,
                    outcome: "succeeded"
                )
                appendToolMessage(
                    for: runtime,
                    toolCallID: entry.externalID,
                    payload: result.payload,
                    images: result.images,
                    outcomeStatus: .succeeded,
                    toolName: entry.toolName,
                    toolCommand: entry.arguments["command"]?.stringValue()
                )
            case .failure(is CancellationError), nil:
                // User stopped the turn mid-batch. Answer this call like the
                // serial cancel path so no record is left spinning, and stop
                // the turn after the whole batch is folded back.
                stopTurn = true
                if let recordIndex = runtime.toolCalls.firstIndex(where: { $0.id == entry.recordID }) {
                    runtime.toolCalls[recordIndex].status = .denied
                    runtime.toolCalls[recordIndex].errorMessage = "Response stopped"
                }
                appendToolMessage(
                    for: runtime,
                    toolCallID: entry.externalID,
                    payload: "Tool execution stopped with the current Agent turn.",
                    source: .systemNotice,
                    outcomeStatus: .denied,
                    errorMessage: "Response stopped"
                )
            case .failure(let error):
                let workspaceIssue = diagnoseLocalWorkspaceIfNeeded(
                    after: error,
                    runtime: runtime,
                    workspaceURL: entry.context.rootDirectory
                )
                let errorMessage = workspaceIssue ?? error.localizedDescription
                if let recordIndex = runtime.toolCalls.firstIndex(where: { $0.id == entry.recordID }) {
                    runtime.toolCalls[recordIndex].status = .failed
                    runtime.toolCalls[recordIndex].errorMessage = errorMessage
                    runtime.toolCalls[recordIndex].commandExitCode = (error as? AgentToolError)?.completedCommandExitCode
                }
                AgentSandboxAuditLog.append(
                    toolName: entry.toolName,
                    arguments: entry.arguments,
                    decision: entry.sandboxDecision,
                    approvalSource: nil,
                    outcome: "failed"
                )
                let dispatchHint = AgentWorkerDispatchHint.hint(
                    toolName: entry.toolName,
                    arguments: entry.arguments,
                    exitCode: (error as? AgentToolError)?.completedCommandExitCode
                ) ?? ""
                appendToolMessage(
                    for: runtime,
                    toolCallID: entry.externalID,
                    payload: "Tool error: \(errorMessage)\n\n(WillDeep: this tool call failed. Do not stop here — diagnose the cause from the exit code/stderr above and try another approach to accomplish the goal. Only give up if you are genuinely blocked, and then explain what you tried and what you still need.)\(dispatchHint)",
                    source: .systemNotice,
                    outcomeStatus: .failed,
                    errorMessage: errorMessage
                )
            }
        }
        return stopTurn
    }

    // Internal rather than private: runAgentLoop in AppStateAgentLoop.swift
    // is the only caller, and it now lives in a different file.
    func patchAutoApplySource(
        forToolName toolName: String,
        runtime: AgentRuntime
    ) -> AgentToolApprovalSource? {
        guard toolName == "apply_patch" || toolName == "edit_file" || toolName == "create_file" else { return nil }
        if runtime.isUnattendedDispatchTask {
            return .dispatchTask
        }
        if runtime.interactionMode == .goal {
            return .goalMode
        }
        if runtime.approvalMode == .fullAccess {
            return .fullAccess
        }
        if runtime.approvalMode == .workspaceAccess {
            return .workspaceAccess
        }
        if runtime.approvalMode == .smart {
            return .staticAllowlist
        }
        return nil
    }

    /// Promote exactly one queued manual decision into an interactive card.
    /// Stage 2 calls this immediately before registering its continuation;
    /// because both operations run on the main actor, SwiftUI cannot expose
    /// the buttons early enough for a click to target the wrong waiter.
    // Internal rather than private: runAgentLoop in AppStateAgentLoop.swift
    // is the only caller, and it now lives in a different file.
    func activateSerialToolDecision(
        recordID: AgentToolCall.ID,
        status: AgentToolCallStatus,
        runtime: AgentRuntime
    ) {
        guard let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) else {
            return
        }
        runtime.toolCalls[index].arguments.removeValue(
            forKey: AgentSerialToolApprovalQueue.argumentKey
        )
        runtime.toolCalls[index].status = status
        AgentToolApprovalNotifier.notifyIfBackgrounded(
            toolName: runtime.toolCalls[index].toolName,
            arguments: runtime.toolCalls[index].arguments,
            status: status,
            runtimeID: runtime.id,
            sessionTitle: runtime.session.title
        )
    }

    /// Suspend until the user resolves the tool call. Three resume paths:
    ///   1. A trusted internal decision was queued before registration —
    ///      resume immediately from the synchronous fast-path.
    ///   2. UI delivers an .approved / .denied / .answered — `resumeToolDecision`
    ///      pulls `toolDecisionWaiter` off the runtime and resumes it.
    ///   3. The enclosing Task is cancelled (session deleted, app shutdown,
    ///      user hit Stop) — `withTaskCancellationHandler` reaches in and
    ///      resumes with .denied so the caller unwinds cleanly. Pre-rc38
    ///      this path leaked: the continuation was stored but never resumed,
    ///      hanging the tool dispatch loop on the next user action.
    func awaitToolDecision(for runtime: AgentRuntime, forCallID id: AgentToolCall.ID) async -> AgentToolDecision {
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancellation may land between publishing the card and registering its waiter.
                // Settle the card too; otherwise sidebar badges keep advertising a dead approval.
                if Task.isCancelled {
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == id }),
                       runtime.toolCalls[index].status.isBlockingForUserDecision,
                       runtime.toolDecisionWaiters[id] == nil {
                        runtime.toolCalls[index].status = .denied
                        runtime.toolCalls[index].errorMessage = "Cancelled"
                    }
                    runtime.pendingToolDecisions.removeValue(forKey: id)
                    continuation.resume(returning: .denied(reason: "Cancelled"))
                    return
                }
                guard let call = runtime.toolCalls.first(where: { $0.id == id }),
                      runtime.toolDecisionWaiters[id] == nil else {
                    continuation.resume(returning: .denied(reason: "Approval is no longer available"))
                    return
                }
                guard call.status.isBlockingForUserDecision else {
                    runtime.pendingToolDecisions.removeValue(forKey: id)
                    continuation.resume(returning: .denied(reason: call.errorMessage ?? "Approval is no longer available"))
                    return
                }
                if let decision = runtime.pendingToolDecisions.removeValue(forKey: id) {
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == id }),
                       runtime.toolCalls[index].status.isBlockingForUserDecision {
                        switch decision {
                        case .approved, .answered:
                            runtime.toolCalls[index].status = .running
                        case .denied(let reason):
                            runtime.toolCalls[index].status = .denied
                            runtime.toolCalls[index].errorMessage = reason
                        }
                    }
                    continuation.resume(returning: decision)
                    return
                }
                runtime.toolDecisionWaiters[id] = AgentToolDecisionRegistration(
                    token: token, continuation: continuation
                )
            }
        } onCancel: {
            // The cancellation handler runs synchronously off the cancelling
            // task — it's nonisolated, so we hop back to the main actor to
            // touch the runtime's continuation slot.
            Task { @MainActor [weak runtime] in
                guard let runtime else { return }
                runtime.cancelToolDecision(id: id, token: token, reason: "Cancelled")
            }
        }
    }
}
