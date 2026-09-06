//
//  AppStateAgentWorkerAutoDispatch.swift
//  WillDeep
//
//  The side-effecting half of auto-dispatch: approval, file lock, child loop.
//  The decision itself is pure and lives in AgentWorkerAutoDispatch.swift.
//
//  Two things this deliberately does *not* do:
//
//  - It does not synthesize a `spawn_agent` tool call in the provider
//    transcript. The model never asked for one, and answering a tool_call_id
//    the provider never issued corrupts the conversation. The worker's verdict
//    is folded into the failing command's own tool result instead — which is
//    also the honest shape: the parent asked "did this command pass", and the
//    answer is now "no, and here is what a worker did about it".
//  - It does not bypass approval. A writing worker is `.write` risk, so it goes
//    through the same `autoApprovalSource` decision and the same approval card
//    a model-requested spawn would. Automatic dispatch changes who *proposes*
//    the delegation, never who authorizes the writes.
//

import Foundation

extension AppState {
    /// Turn off automatic dispatch. Escape hatch for a user who wants failures
    /// to come straight back to the parent; `/no-subagent` covers the
    /// per-turn case.
    static let autoDispatchWorkersDefaultsKey = "willdeep.agent.autoDispatchWorkers"

    static var autoDispatchWorkersEnabled: Bool {
        UserDefaults.standard.object(forKey: autoDispatchWorkersDefaultsKey) as? Bool ?? true
    }

    /// Dispatch the worker a failed verification command earns, and return the
    /// note to append to that command's tool result — or nil when there is
    /// nothing worth telling the model.
    func autoDispatchWorkerForFailedCommand(
        toolName: String,
        arguments: [String: AgentJSONValue],
        exitCode: Int32?,
        failureOutput: String,
        runtime: AgentRuntime,
        configuration: AgentConfiguration,
        workspaceURL: URL?,
        runtimeDescriptor: RuntimeDescriptor?,
        workspaceLocation: WorkspaceLocation?,
        assistantMessageID: UUID
    ) async -> String? {
        // A remote/SSH workspace has no local paths to hand a worker, and the
        // write set was derived from a log we cannot resolve against a real
        // tree. Fall back to the plain hint there.
        guard let workspaceURL, runtimeDescriptor == nil else { return nil }

        let plan = AgentWorkerAutoDispatch.plan(
            toolName: toolName,
            command: arguments["command"]?.stringValue(),
            exitCode: exitCode,
            failureOutput: failureOutput,
            delegationPolicy: runtime.currentTurnDelegationPolicy,
            alreadyDispatchedCommands: runtime.currentTurnAutoDispatchedCommands,
            isEnabled: Self.autoDispatchWorkersEnabled,
            workspaceRootPath: workspaceURL.path,
            existingWorkspacePaths: { relative in
                FileManager.default.fileExists(
                    atPath: workspaceURL.appendingPathComponent(relative).path
                )
            }
        )

        let dispatch: AgentWorkerAutoDispatch.Plan
        switch plan {
        case .failure(let refusal):
            return refusal.modelFacingNote
        case .success(let value):
            dispatch = value
        }

        guard let writeAccess = AgentSubagentWriteAccess(
            targetRelativePaths: dispatch.targetRelativePaths
        ) else { return nil }
        let profile = AgentSubagentProfileStore.resolvedProfile(id: dispatch.tradeID)

        // Claimed before the run, not after: a worker that fails still fought
        // this command, and re-dispatching it would repeat the same loss.
        runtime.currentTurnAutoDispatchedCommands.insert(dispatch.verifierCommand)

        let childConfiguration = resolvedSubagentConfiguration(
            for: profile,
            parentConfiguration: configuration
        )
        let hostRunID = beginHostWorkerRun(
            profileID: profile.id,
            source: .failedCommandRepair,
            userMessageID: runtime.messages.last(where: { $0.isOperatorInput })?.id,
            model: childConfiguration.model,
            providerID: childConfiguration.providerID,
            runtime: runtime
        )

        // A record in WillDeep's own ledger — this is what the user sees and
        // approves. It is not part of the provider transcript.
        let recordID = UUID()
        let spawnArguments: [String: AgentJSONValue] = [
            "profile": .string(profile.id),
            "target_files": .array(dispatch.targetRelativePaths.map { .string($0) }),
            "_auto_dispatch": .bool(true),
        ]
        runtime.toolCalls.append(AgentToolCall(
            id: recordID,
            messageID: assistantMessageID,
            externalID: "auto-dispatch-\(recordID.uuidString)",
            toolName: "spawn_agent",
            arguments: spawnArguments,
            risk: .write,
            status: .running
        ))
        func settle(_ status: AgentToolCallStatus, summary: String, error: String? = nil) {
            guard let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) else { return }
            runtime.toolCalls[index].status = status
            runtime.toolCalls[index].errorMessage = error
            runtime.toolCalls[index].subagentModel = childConfiguration.model
            runtime.toolCalls[index].result = AgentToolResult(summary: summary, payload: "")
        }

        // Same authorization a model-requested writing spawn gets.
        let autoApproval: AgentToolApprovalSource?
        do { autoApproval = try await checkedAutoApprovalSource(
            toolName: "spawn_agent",
            arguments: spawnArguments,
            risk: .write,
            rootDirectory: workspaceURL,
            additionalWorkspaceRoots: Array(
                agentWorkspaceRoots(for: runtime.session).dropFirst()
            ),
            interactionMode: runtime.interactionMode,
            approvalMode: runtime.approvalMode,
            conversationAllowedToolSignatures: runtime.conversationAllowedToolSignatures,
            environmentTrustDeclarations: runtime.environmentTrustDeclarations,
            computerUseOwner: runtime.computerUseOwner,
            latestUserMessage: runtime.messages.last(where: { $0.isOperatorInput })?.content ?? "", budgetRuntime: runtime
        ) } catch {
            let notice = handleApprovalRequestStop(error, runtime: runtime)
            settle(.failed, summary: notice, error: notice)
            finishHostWorkerRun(hostRunID, status: .failed, runtime: runtime)
            return nil
        }
        if autoApproval == nil {
            activateSerialToolDecision(recordID: recordID, status: .pendingApproval, runtime: runtime)
            let decision = await awaitToolDecision(for: runtime, forCallID: recordID)
            if runtime.toolCalls.first(where: { $0.id == recordID })?.status == .failed {
                finishHostWorkerRun(hostRunID, status: .failed, runtime: runtime)
                return nil
            }
            if Task.isCancelled {
                settle(.denied, summary: "cancelled", error: "Cancelled")
                finishHostWorkerRun(hostRunID, status: .denied, runtime: runtime)
                return nil
            }
            if case .denied = decision {
                settle(.denied, summary: "declined", error: "Declined")
                finishHostWorkerRun(hostRunID, status: .denied, runtime: runtime)
                return "(WillDeep: you declined the automatic `\(profile.id)` dispatch for this failure, so it is yours to fix here.)"
            }
        }
        if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
            runtime.toolCalls[index].approvalSource = autoApproval ?? .user
            runtime.toolCalls[index].status = .running
        }

        // One editor per file per session: two children patching the same file
        // would interleave hunks against a moving base.
        let runID = UUID()
        guard AgentSubagentEditorLock.shared.acquire(
            paths: writeAccess.targetRelativePaths,
            parentRuntimeID: runtime.id,
            runID: runID
        ) else {
            settle(.failed, summary: "files locked", error: "Target files locked")
            finishHostWorkerRun(hostRunID, status: .failed, runtime: runtime)
            return "(WillDeep: another subagent already holds \(writeAccess.displayList), so this failure was not auto-delegated.)"
        }
        defer { AgentSubagentEditorLock.shared.release(runID: runID) }

        do {
            runtime.currentTurnAttemptedWorkerProfiles.insert(profile.id)
            markHostWorkerRunStarted(hostRunID, runtime: runtime)
            let outcome = try await AgentSubagentRunner.run(
                prompt: dispatch.prompt,
                configuration: childConfiguration,
                workspaceURL: workspaceURL,
                workspaceLocation: workspaceLocation,
                profile: profile,
                writeAccess: writeAccess,
                verifierCommand: dispatch.verifierCommand,
                // Same sink the model-requested editor spawn uses: the user
                // authorized "this worker may edit these files" once, so its
                // hunks apply without re-asking per patch.
                patchProposalSink: { [weak self] title, diff, _, workspaceRoot in
                    guard let self else { throw AgentToolError.noWorkspace }
                    return try self.enqueueAgentPatchProposal(
                        for: runtime,
                        messageID: assistantMessageID,
                        title: title,
                        diff: diff,
                        workspaceRoot: workspaceRoot,
                        autoApplySource: .subagentEditor,
                        applyImmediately: true
                    )
                },
                // Without this the card and the composer strip showed a
                // frozen trade name for the whole run: only the model's own
                // `spawn_agent` path was wired for progress.
                executionBudget: toolExecutionBudget(for: runtime),
                onProgress: { [weak self] progress in
                    self?.applySubagentLiveProgress(
                        progress,
                        recordID: recordID,
                        runtime: runtime,
                        profileID: profile.id,
                        workerName: L10n.AgentDelegation.profileName(for: profile.id),
                        model: childConfiguration.model
                    )
                }
            )
            settle(
                outcome.verifierPassed == true ? .succeeded : .failed,
                summary: outcome.verifierPassed == true ? "verified" : "not verified"
            )
            finishHostWorkerRun(
                hostRunID,
                status: outcome.verifierPassed == true ? .succeeded : .failed,
                outcome: outcome,
                runtime: runtime
            )
            return Self.autoDispatchResultNote(
                profile: profile,
                model: childConfiguration.model,
                outcome: outcome,
                verifierCommand: dispatch.verifierCommand,
                targets: writeAccess.targetRelativePaths
            )
        } catch {
            settle(.failed, summary: "dispatch failed", error: error.localizedDescription)
            finishHostWorkerRun(hostRunID, status: .failed, runtime: runtime)
            return "(WillDeep: the automatic `\(profile.id)` dispatch could not run (\(error.localizedDescription)). The failure above is yours to diagnose.)"
        }
    }

    /// What the parent is told. States the verdict before the report, because
    /// the verdict is the part that decides what the parent does next.
    static func autoDispatchResultNote(
        profile: AgentSubagentProfile,
        model: String,
        outcome: AgentSubagentRunner.Outcome,
        verifierCommand: String,
        targets: [String]
    ) -> String {
        let verdict: String
        switch outcome.verifierPassed {
        case true:
            verdict = "`\(verifierCommand)` now exits 0."
        case false:
            verdict = "`\(verifierCommand)` still fails after \(outcome.verifierAttempts) attempt(s)."
        default:
            verdict = "the verifier produced no verdict."
        }
        let list = targets.map { "`\($0)`" }.joined(separator: ", ")
        return """

        (WillDeep dispatched the `\(profile.id)` worker on `\(model)` automatically for this \
        failure, scoped to \(list). Verdict: \(verdict)

        Worker report:
        \(outcome.report)

        \(outcome.verifierPassed == true
            ? "Review the change before building on it; the verifier passing is evidence, not a review."
            : "Take it from here — do not re-delegate the same command."))
        """
    }
}
