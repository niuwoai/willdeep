//
//  AppStateAgentCodingPipeline.swift
//  WillDeep
//
//  Host-owned low-risk coding lane:
//    scout packet -> configured standard-tier implementation -> host verifier ->
//    independent standard-tier review -> straight-through delivery.
//
//  The parent model is deliberately absent from the happy path. Deterministic
//  host policy, exact file capabilities, verifier exit status, and a second
//  model's structured verdict replace confidence-based self-acceptance.
//

import Foundation

nonisolated enum AgentAutomaticCodingPipelineResult: Equatable, Sendable {
    case notEligible
    case needsParent(String)
    case delivered(String)
}

private struct AgentAutomaticCodingWorkerRun {
    let hostRunID: UUID
    let profile: AgentSubagentProfile
    let configuration: AgentConfiguration
    let outcome: AgentSubagentRunner.Outcome
}

private enum AgentAutomaticCodingPipelineError: LocalizedError {
    case denied
    case filesLocked
    case runFailed(String, hostRunID: UUID)

    var errorDescription: String? {
        switch self {
        case .denied: return "The coding worker was declined."
        case .filesLocked: return "Another worker is editing one of the declared files."
        case .runFailed(let message, _): return message
        }
    }
}

private final class AgentCodingDiffCollector {
    var values: [String] = []
}

extension AppState {
    func runAutomaticCodingPipelineIfEligible(
        for runtime: AgentRuntime,
        requestText: String,
        userMessageID: UUID,
        plan: AgentCodingTaskPlan,
        parentConfiguration: AgentConfiguration
    ) async -> AgentAutomaticCodingPipelineResult {
        guard runtime.interactionMode == .normal,
              runtime.currentPlan == nil,
              !runtime.currentTurnPlanningOnly,
              runtime.currentTurnDelegationPolicy != .forbidden,
              runtime.currentTurnAttachedSkills.isEmpty,
              let workspaceURL = try? runtime.localWorkspaceURLForOptimisticUse() else {
            return .notEligible
        }
        guard let operatorMessage = runtime.messages.first(where: { $0.id == userMessageID }),
              operatorMessage.images.isEmpty,
              operatorMessage.textAttachments.isEmpty else {
            return .notEligible
        }
        guard let writeAccess = plan.normalizedWriteAccess,
              plan.automaticIneligibilityReason(requestText: requestText) == nil else {
            return .notEligible
        }
        // A verifier that is not deterministically read-tier still has a safe
        // route through the ordinary parent/tool approval loop. The automatic
        // lane intentionally declines that broader authority.
        guard AgentSubagentRunner.verifierCommandIsReadTier(
            plan.verifierCommand,
            workspaceURL: workspaceURL
        ) else {
            return .notEligible
        }

        let smallProfile = AgentSubagentProfileStore.resolvedProfile(
            id: AgentSubagentProfileCatalog.smallImplementerID
        )
        let smallConfiguration = resolvedSubagentConfiguration(
            for: smallProfile,
            parentConfiguration: parentConfiguration
        )
        // Do not silently turn "small-model-first" into "whatever provider
        // happened to be active". If the base some.im worker is unavailable,
        // the parent route remains the honest fallback.
        guard AgentWorkerTierModels.tier(for: smallProfile.modelBinding) == .standard,
              let configured = workerTierConfiguration(.standard, parent: parentConfiguration),
              Self.sameWorkerModel(smallConfiguration, configured) else {
            return .notEligible
        }

        let runID = UUID()
        guard AgentSubagentEditorLock.shared.acquire(
            paths: writeAccess.targetRelativePaths,
            parentRuntimeID: runtime.id,
            runID: runID
        ) else {
            return .needsParent("The structured coding plan was not auto-run because another worker holds one of its target files.")
        }
        defer { AgentSubagentEditorLock.shared.release(runID: runID) }

        let packet = plan.taskPacket(maxAttempts: 2)
        let initialPrompt = packet.openingMessage(fallbackPrompt: requestText) { path in
            Self.localCodingFileContents(path: path, workspaceURL: workspaceURL)
        }
        let diffCollector = AgentCodingDiffCollector()
        var initialHostRunID: UUID?
        var writerRun: AgentAutomaticCodingWorkerRun?
        var initialRun: AgentAutomaticCodingWorkerRun?

        do {
            let initial = try await runAutomaticCodingWorker(
                profile: smallProfile,
                source: .automaticCoding,
                prompt: initialPrompt,
                outputSchema: nil,
                writeAccess: writeAccess,
                verifierCommand: plan.verifierCommand,
                verifierMaxAttempts: 2,
                runtime: runtime,
                workspaceURL: workspaceURL,
                userMessageID: userMessageID,
                parentConfiguration: parentConfiguration,
                diffCollector: diffCollector
            )
            initialRun = initial
            initialHostRunID = initial.hostRunID
            if initial.outcome.verifierPassed == true {
                writerRun = initial
            }
        } catch AgentAutomaticCodingPipelineError.denied {
            return .needsParent("The operator declined the automatic coding worker; continue through the ordinary parent-controlled path.")
        } catch AgentAutomaticCodingPipelineError.runFailed(_, let hostRunID) {
            initialHostRunID = hostRunID
        } catch {
            return .needsParent(Self.parentHandoffNote(
                reason: error.localizedDescription,
                plan: plan
            ))
        }

        if writerRun == nil {
            do {
                writerRun = try await runAutomaticCodingEscalation(
                    after: initialRun,
                    packet: packet,
                    writeAccess: writeAccess,
                    runtime: runtime,
                    workspaceURL: workspaceURL,
                    userMessageID: userMessageID,
                    parentConfiguration: parentConfiguration,
                    diffCollector: diffCollector
                )
            } catch {
                if let initialHostRunID {
                    markHostWorkerDelivery(
                        initialHostRunID,
                        accepted: false,
                        requiredParentRepair: true,
                        runtime: runtime
                    )
                }
                return .needsParent(Self.parentHandoffNote(
                    reason: error.localizedDescription,
                    plan: plan
                ))
            }
        }

        guard let writerRun, writerRun.outcome.verifierPassed == true else {
            if let initialHostRunID {
                markHostWorkerDelivery(
                    initialHostRunID,
                    accepted: false,
                    requiredParentRepair: true,
                    runtime: runtime
                )
            }
            return .needsParent(Self.parentHandoffNote(
                reason: "The verifier still failed after the bounded worker attempts.",
                plan: plan
            ))
        }

        do {
            let review = try await runAutomaticCodingReview(
                requestText: requestText,
                plan: plan,
                writerRun: writerRun,
                appliedDiffs: diffCollector.values,
                runtime: runtime,
                workspaceURL: workspaceURL,
                userMessageID: userMessageID,
                parentConfiguration: parentConfiguration
            )
            let accepted = review.acceptsStraightThroughDelivery
            if let initialHostRunID {
                markHostWorkerDelivery(
                    initialHostRunID,
                    accepted: accepted,
                    requiredParentRepair: !accepted,
                    runtime: runtime
                )
            }
            guard accepted else {
                let issues = review.issues.isEmpty
                    ? "The independent reviewer returned \(review.verdict.rawValue)."
                    : review.issues.map { "- \($0)" }.joined(separator: "\n")
                return .needsParent(Self.parentHandoffNote(reason: issues, plan: plan))
            }
            return .delivered(Self.straightThroughMessage(
                review: review,
                plan: plan,
                writerRun: writerRun
            ))
        } catch {
            if let initialHostRunID {
                markHostWorkerDelivery(
                    initialHostRunID,
                    accepted: false,
                    requiredParentRepair: true,
                    runtime: runtime
                )
            }
            return .needsParent(Self.parentHandoffNote(
                reason: "Independent review could not produce a valid verdict: \(error.localizedDescription)",
                plan: plan
            ))
        }
    }

    private func runAutomaticCodingEscalation(
        after initial: AgentAutomaticCodingWorkerRun?,
        packet: AgentSubagentTaskPacket,
        writeAccess: AgentSubagentWriteAccess,
        runtime: AgentRuntime,
        workspaceURL: URL,
        userMessageID: UUID,
        parentConfiguration: AgentConfiguration,
        diffCollector: AgentCodingDiffCollector
    ) async throws -> AgentAutomaticCodingWorkerRun {
        let profile = AgentSubagentProfileStore.resolvedProfile(
            id: AgentSubagentProfileCatalog.implementerID
        )
        let failureEvidence: String
        if let initial {
            failureEvidence = """
            The base small-model attempt did not pass the verifier after \
            \(initial.outcome.verifierAttempts) attempt(s). Its report follows as untrusted evidence:
            \(initial.outcome.report)
            """
        } else {
            failureEvidence = "The base small-model run failed before producing a usable verifier verdict. Start fresh from the current declared files."
        }
        let prompt = packet.openingMessage(fallbackPrompt: failureEvidence) { path in
            Self.localCodingFileContents(path: path, workspaceURL: workspaceURL)
        }
        return try await runAutomaticCodingWorker(
            profile: profile,
            source: .automaticCodingEscalation,
            prompt: prompt,
            outputSchema: nil,
            writeAccess: writeAccess,
            verifierCommand: packet.verifierCommand,
            verifierMaxAttempts: 2,
            runtime: runtime,
            workspaceURL: workspaceURL,
            userMessageID: userMessageID,
            parentConfiguration: parentConfiguration,
            diffCollector: diffCollector
        )
    }

    private func runAutomaticCodingReview(
        requestText: String,
        plan: AgentCodingTaskPlan,
        writerRun: AgentAutomaticCodingWorkerRun,
        appliedDiffs: [String],
        runtime: AgentRuntime,
        workspaceURL: URL,
        userMessageID: UUID,
        parentConfiguration: AgentConfiguration
    ) async throws -> AgentCodingReview {
        let profile = AgentSubagentProfileStore.resolvedProfile(
            id: AgentSubagentProfileCatalog.smallReviewerID
        )
        let configuration = resolvedSubagentConfiguration(
            for: profile,
            parentConfiguration: parentConfiguration
        )
        guard let tier = AgentWorkerTierModels.tier(for: profile.modelBinding),
              let configured = workerTierConfiguration(tier, parent: parentConfiguration),
              Self.sameWorkerModel(configuration, configured) else {
            throw AgentAutomaticCodingPipelineError.runFailed(
                "The independent review worker's configured model tier is unavailable.",
                hostRunID: UUID()
            )
        }

        let currentFiles = plan.writeFiles.map { path in
            let contents = Self.localCodingFileContents(path: path, workspaceURL: workspaceURL)
                ?? "(missing)"
            return "### \(path) after\n```\n\(Self.clampCodingEvidence(contents, limit: 16_000))\n```"
        }.joined(separator: "\n\n")
        let diffs = appliedDiffs.isEmpty
            ? "(no patch evidence was captured)"
            : Self.clampCodingEvidence(appliedDiffs.joined(separator: "\n\n"), limit: 40_000)
        let prompt = """
        ## Operator request
        \(requestText)

        ## Declared goal
        \(plan.goal)

        ## Declared write scope
        \(plan.writeFiles.map { "- \($0)" }.joined(separator: "\n"))

        ## Host verifier
        Command: \(plan.verifierCommand)
        Result: exit 0 after \(writerRun.outcome.verifierAttempts) attempt(s)

        ## Applied patch evidence
        \(diffs)

        ## Current declared files
        \(currentFiles)
        """
        let ignoredDiffs = AgentCodingDiffCollector()
        let run = try await runAutomaticCodingWorker(
            profile: profile,
            source: .automaticCodingReview,
            prompt: prompt,
            outputSchema: AgentCodingReview.schema,
            writeAccess: nil,
            verifierCommand: nil,
            verifierMaxAttempts: 1,
            runtime: runtime,
            workspaceURL: workspaceURL,
            userMessageID: userMessageID,
            parentConfiguration: parentConfiguration,
            diffCollector: ignoredDiffs
        )
        guard let data = run.outcome.report.data(using: .utf8) else {
            throw AgentAutomaticCodingPipelineError.runFailed(
                "The review payload was not UTF-8.",
                hostRunID: run.hostRunID
            )
        }
        return try JSONDecoder().decode(AgentCodingReview.self, from: data)
    }

    private func runAutomaticCodingWorker(
        profile: AgentSubagentProfile,
        source: AgentHostWorkerRunRecord.Source,
        prompt: String,
        outputSchema: AgentStructuredSchema?,
        writeAccess: AgentSubagentWriteAccess?,
        verifierCommand: String?,
        verifierMaxAttempts: Int,
        runtime: AgentRuntime,
        workspaceURL: URL,
        userMessageID: UUID,
        parentConfiguration: AgentConfiguration,
        diffCollector: AgentCodingDiffCollector
    ) async throws -> AgentAutomaticCodingWorkerRun {
        let configuration = resolvedSubagentConfiguration(
            for: profile,
            parentConfiguration: parentConfiguration
        )
        let hostRunID = beginHostWorkerRun(
            profileID: profile.id,
            source: source,
            userMessageID: userMessageID,
            model: configuration.model,
            providerID: configuration.providerID,
            runtime: runtime
        )
        let recordID = UUID()
        var spawnArguments: [String: AgentJSONValue] = [
            "profile": .string(profile.id),
            "_automatic_coding": .bool(true),
        ]
        if let writeAccess {
            spawnArguments["target_files"] = .array(
                writeAccess.targetRelativePaths.map { .string($0) }
            )
        }
        runtime.toolCalls.append(AgentToolCall(
            id: recordID,
            messageID: userMessageID,
            externalID: "automatic-coding-\(recordID.uuidString)",
            toolName: "spawn_agent",
            arguments: spawnArguments,
            risk: writeAccess == nil ? .read : .write,
            status: .running
        ))

        func settle(_ status: AgentToolCallStatus, summary: String, error: String? = nil) {
            guard let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) else { return }
            runtime.toolCalls[index].status = status
            runtime.toolCalls[index].errorMessage = error
            runtime.toolCalls[index].subagentModel = configuration.model
            runtime.toolCalls[index].result = AgentToolResult(summary: summary, payload: "")
        }

        if writeAccess != nil {
            let approval: AgentToolApprovalSource?
            do { approval = try await checkedAutoApprovalSource(
                toolName: "spawn_agent",
                arguments: spawnArguments,
                risk: .write,
                rootDirectory: workspaceURL,
                additionalWorkspaceRoots: Array(agentWorkspaceRoots(for: runtime.session).dropFirst()),
                interactionMode: runtime.interactionMode,
                approvalMode: runtime.approvalMode,
                conversationAllowedToolSignatures: runtime.conversationAllowedToolSignatures,
                environmentTrustDeclarations: runtime.environmentTrustDeclarations,
                computerUseOwner: runtime.computerUseOwner,
                latestUserMessage: requestTextForAutomaticCoding(runtime: runtime), budgetRuntime: runtime
            ) } catch {
                let notice = handleApprovalRequestStop(error, runtime: runtime)
                settle(.failed, summary: notice, error: notice)
                finishHostWorkerRun(hostRunID, status: .failed, runtime: runtime)
                throw error
            }
            if approval == nil {
                activateSerialToolDecision(recordID: recordID, status: .pendingApproval, runtime: runtime)
                let decision = await awaitToolDecision(for: runtime, forCallID: recordID)
                if runtime.toolCalls.first(where: { $0.id == recordID })?.status == .failed {
                    finishHostWorkerRun(hostRunID, status: .failed, runtime: runtime)
                    throw CancellationError() // Owner hold, if needed, was settled by re-evaluation.
                }
                if Task.isCancelled || decision.isDenied {
                    settle(.denied, summary: "declined", error: "Declined")
                    finishHostWorkerRun(hostRunID, status: .denied, runtime: runtime)
                    throw AgentAutomaticCodingPipelineError.denied
                }
            }
            if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                runtime.toolCalls[index].approvalSource = approval ?? .user
                runtime.toolCalls[index].status = .running
            }
        }

        runtime.currentTurnSpawnAgentCallCount += 1
        runtime.currentTurnAttemptedWorkerProfiles.insert(profile.id)
        runtime.deepAdmissionObservation.recordProfileAttempt(profile.id)
        markHostWorkerRunStarted(hostRunID, runtime: runtime)
        let someIMContext: SomeIMRequestContext? = {
            guard configuration.providerID == AgentProviderPreset.someIMID else { return nil }
            let workspaceID = AgentWorkspaceIdentityStore.workspaceID(
                forWorkspaceKey: Self.managedWorkspaceKey(for: runtime)
            )
            return SomeIMRequestContext(sessionID: runtime.id.uuidString, workspaceID: workspaceID)
        }()

        do {
            let outcome = try await AgentSubagentRunner.run(
                prompt: prompt,
                configuration: configuration,
                workspaceURL: workspaceURL,
                workspaceLocation: runtime.workspaceLocation,
                someIMContext: someIMContext,
                outputSchema: outputSchema,
                profile: profile,
                writeAccess: writeAccess,
                verifierCommand: verifierCommand,
                verifierMaxAttempts: verifierMaxAttempts,
                patchProposalSink: writeAccess == nil ? nil : { [weak self] title, diff, _, root in
                    guard let self else { throw AgentToolError.noWorkspace }
                    diffCollector.values.append(diff)
                    return try self.enqueueAgentPatchProposal(
                        for: runtime,
                        messageID: userMessageID,
                        title: title,
                        diff: diff,
                        workspaceRoot: root,
                        autoApplySource: .subagentEditor,
                        applyImmediately: true
                    )
                },
                executionBudget: toolExecutionBudget(for: runtime),
                onProgress: { [weak self] progress in
                    self?.applySubagentLiveProgress(
                        progress,
                        recordID: recordID,
                        runtime: runtime,
                        profileID: profile.id,
                        workerName: L10n.AgentDelegation.profileName(for: profile.id),
                        model: configuration.model
                    )
                }
            )
            let succeeded = verifierCommand == nil || outcome.verifierPassed == true
            settle(succeeded ? .succeeded : .failed, summary: succeeded ? "verified" : "not verified")
            finishHostWorkerRun(
                hostRunID,
                status: succeeded ? .succeeded : .failed,
                outcome: outcome,
                runtime: runtime
            )
            return AgentAutomaticCodingWorkerRun(
                hostRunID: hostRunID,
                profile: profile,
                configuration: configuration,
                outcome: outcome
            )
        } catch {
            settle(.failed, summary: "worker failed", error: error.localizedDescription)
            finishHostWorkerRun(hostRunID, status: .failed, runtime: runtime)
            throw AgentAutomaticCodingPipelineError.runFailed(
                error.localizedDescription,
                hostRunID: hostRunID
            )
        }
    }

    func completeAutomaticCodingTurn(
        for runtime: AgentRuntime,
        message: String,
        configuration: AgentConfiguration,
        providerSlotClaimID: UUID,
        turnID: UUID
    ) {
        guard runtime.activeTurnID == turnID else {
            releaseProviderSlot(for: runtime, claimID: providerSlotClaimID, providerID: configuration.providerID)
            return
        }
        runtime.messages.append(AgentMessage(
            role: .assistant,
            content: message,
            origin: .delegatedExternal,
            originLabel: "WillDeep 小模型编码流水线"
        ))
        let shouldConsumeQueueAfterStop = runtime.shouldConsumeQueueAfterStop
        runtime.isResponding = false
        runtime.turnStartedAt = nil
        runtime.requestTask = nil
        if runtime.activeTurnID == turnID {
            runtime.activeTurnID = nil
            runtime.activeTurnConfiguration = nil
            runtime.userStoppedTurnID = nil
        }
        runtime.goalTurnRecoveryCheckpoint = nil
        runtime.shouldConsumeQueueAfterStop = false
        auditDelegationPolicyForFinishedTurn(in: runtime)
        refreshAgentWorkspaceCollision()
        persistAgentSession(runtime: runtime)
        recordRoutineRunCompletionIfNeeded(for: runtime)
        if !shouldConsumeQueueAfterStop {
            maybeAutoCompressContext(for: runtime)
        }
        consumeNextQueuedMessageIfNeeded(for: runtime)
        releaseProviderSlot(
            for: runtime,
            claimID: providerSlotClaimID,
            providerID: configuration.providerID
        )
    }

    private func requestTextForAutomaticCoding(runtime: AgentRuntime) -> String {
        runtime.messages.last(where: { $0.isOperatorInput })?.content ?? ""
    }

    private static func localCodingFileContents(path: String, workspaceURL: URL) -> String? {
        guard let normalized = AgentSubagentWriteAccess.normalizedTargetPath(path) else { return nil }
        let root = workspaceURL.standardizedFileURL.path
        let url = workspaceURL.appendingPathComponent(normalized).standardizedFileURL
        guard url.path.hasPrefix(root + "/"),
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func clampCodingEvidence(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "\n… (evidence truncated; escalate instead of accepting if omitted context matters)"
    }

    private static func parentHandoffNote(reason: String, plan: AgentCodingTaskPlan) -> String {
        """
        <automatic-coding-handoff>
        The host-owned coding lane changed or inspected the declared files but did not clear its \
        acceptance gate. Continue from the current workspace state; do not repeat the same small-model \
        attempt. Review the exact target files and repair or explain the following:
        \(reason)
        Declared goal: \(plan.goal)
        Declared files: \(plan.writeFiles.joined(separator: ", "))
        Verifier: \(plan.verifierCommand)
        </automatic-coding-handoff>
        """
    }

    private static func straightThroughMessage(
        review: AgentCodingReview,
        plan: AgentCodingTaskPlan,
        writerRun: AgentAutomaticCodingWorkerRun
    ) -> String {
        let files = plan.writeFiles.map { "`\($0)`" }.joined(separator: "、")
        return """
        \(review.userSummary)

        - 已修改：\(files)
        - 验证：`\(plan.verifierCommand)` 通过
        - 执行：\(writerRun.profile.localizedDisplayName)（`\(writerRun.configuration.model)`）
        - 复核：Small Reviewer（`\(AgentSubagentModelCompatibility.baseModel)`）通过

        本次由小模型流水线直通交付，未调用本会话的高智主模型。
        """
    }
}

private extension AgentToolDecision {
    var isDenied: Bool {
        if case .denied = self { return true }
        return false
    }
}
