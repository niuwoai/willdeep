//
//  AppStateAgentReadOnlyPreflight.swift
//  WillDeep
//
//  Running a bounded worker *before* the root model answers.
//
//  `AgentRequestRouter` classifies the request and, on its own, only appends
//  a steering paragraph. This is the executing half: for high-confidence
//  routes it dispatches the cheapest suitable worker first and hands the root
//  model the report as evidence, so the expensive model spends its window on
//  synthesis and decisions instead of re-deriving repository facts.
//
//  It is opt-in: a serial worker before the root model is useful for large
//  repository reads, but is also a visible time-to-first-token tax on small
//  requests. Set `agent.auto_dispatch_read_only = true` to enable it.
//
//  Read-only by construction: the tester may execute read-tier gates, but no
//  preflight receives write access, an editor lock, a verifier, or a patch
//  sink. Mutation is delegated separately after the report is available.
//
//  See docs/SMALL_MODEL_FIRST_RUNTIME_PLAN.md §4 step 4.
//

import Foundation

extension AppState {
    /// Whether request-level preflight may run at all. The shared config.toml
    /// wins; absent, it stays off to protect first-token latency.
    static func readOnlyPreflightEnabled(
        sharedConfig: AgentSharedRuntimeConfig = .load()
    ) -> Bool {
        sharedConfig.autoDispatchReadOnly ?? false
    }

    /// Run the preflight for this turn if it applies, and fold the report into
    /// the turn's steering paragraph.
    ///
    /// Never throws and never blocks the turn on failure: a preflight that
    /// cannot run is a missed optimization, not a failed request. The root
    /// model simply proceeds with the ordinary steering note.
    func runReadOnlyPreflightIfNeeded(
        for runtime: AgentRuntime,
        requestText: String,
        configuration: AgentConfiguration,
        userMessageID: UUID
    ) async -> AgentCodingTaskPlan? {
        guard Self.readOnlyPreflightEnabled() else { return nil }
        // `/no-subagent` means "do all of it yourself this turn". Dispatching
        // a worker anyway would be the one thing the user explicitly refused.
        guard runtime.currentTurnDelegationPolicy != .forbidden else { return nil }
        guard runtime.currentTurnDelegationPolicy != .agentPreferred else { return nil }

        let decision = runtime.currentTurnRouteDecision ?? AgentRequestRouter.classify(requestText)
        guard let profileID = decision.preflightProfileID else { return nil }

        let requestsCodingPlan = decision.requiresDelegatedExecution
            && profileID == AgentSubagentProfileCatalog.scoutID
            && [
                AgentSubagentProfileCatalog.editorID,
                AgentSubagentProfileCatalog.implementerID,
            ].contains(decision.profileID)

        let workspaceLocation = runtime.workspaceLocation
            ?? runtime.workspaceRootPath.map { .local(path: $0) }
        let runtimeDescriptor = workspaceLocation?.remoteRuntimeID.flatMap {
            AgentRuntimeStore.descriptor(id: $0)
        }
        let workspaceURL: URL?
        if workspaceLocation?.remoteRuntimeID != nil {
            guard runtimeDescriptor != nil else { return nil }
            workspaceURL = nil
        } else {
            workspaceURL = try? runtime.localWorkspaceURLForOptimisticUse()
        }

        let profile = AgentSubagentProfileStore.resolvedProfile(id: profileID)
        // Defensive: every preflight trade is non-writing, but a user-edited
        // profile store could have widened one of them.
        guard !profile.requiresWriteAccess else { return nil }

        let childConfiguration = resolvedSubagentConfiguration(
            for: profile,
            parentConfiguration: configuration
        )
        // Terminal inspection is the only preflight that can be useful with
        // no workspace binding at all. Every other trade needs either a local
        // root or a resolvable remote runtime.
        guard profile.id == AgentSubagentProfileCatalog.terminalOperatorID
                || workspaceURL != nil
                || runtimeDescriptor != nil else { return nil }

        let workspaceRevision = requestsCodingPlan
            ? await AgentWorkspaceRevisionCapture.capture(for: workspaceURL)
            : nil
        if let workspaceRevision,
           let cachedPlan = await AgentCodingArtifactCache.shared.plan(
                requestText: requestText,
                revision: workspaceRevision
           ) {
            let cacheRecordID = beginHostWorkerRun(
                profileID: profile.id,
                source: .codingPlanCacheHit,
                userMessageID: userMessageID,
                model: "artifact-cache",
                providerID: nil,
                runtime: runtime
            )
            finishHostWorkerRun(cacheRecordID, status: .succeeded, runtime: runtime)
            runtime.currentTurnRouteSteering = Self.steeringWithCodingPlan(
                existing: runtime.currentTurnRouteSteering,
                profileID: profile.id,
                model: "artifact-cache",
                plan: cachedPlan,
                cacheHit: true
            )
            return cachedPlan
        }

        let someIMContext: SomeIMRequestContext? = {
            guard childConfiguration.providerID == AgentProviderPreset.someIMID else { return nil }
            let workspaceID = AgentWorkspaceIdentityStore.workspaceID(
                forWorkspaceKey: Self.managedWorkspaceKey(for: runtime)
            )
            return SomeIMRequestContext(sessionID: runtime.id.uuidString, workspaceID: workspaceID)
        }()

        let hostRunID = beginHostWorkerRun(
            profileID: profile.id,
            source: .requestPreflight,
            userMessageID: userMessageID,
            model: childConfiguration.model,
            providerID: childConfiguration.providerID,
            runtime: runtime
        )

        // Visible in WillDeep's own ledger before it starts. A pause the user
        // cannot account for is worse than the pause itself.
        let recordID = UUID()
        runtime.toolCalls.append(AgentToolCall(
            id: recordID,
            messageID: userMessageID,
            externalID: "preflight-\(recordID.uuidString)",
            toolName: "spawn_agent",
            arguments: [
                "profile": .string(profile.id),
                "_runtime_preflight": .bool(true),
            ],
            risk: .read,
            status: .running
        ))
        func settle(_ status: AgentToolCallStatus, summary: String, error: String? = nil) {
            guard let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) else { return }
            runtime.toolCalls[index].status = status
            runtime.toolCalls[index].errorMessage = error
            runtime.toolCalls[index].subagentModel = childConfiguration.model
            runtime.toolCalls[index].result = AgentToolResult(summary: summary, payload: "")
        }

        // Counted as a lower-tier attempt: it really ran, so it is honest
        // evidence toward a later deep escalation.
        runtime.deepAdmissionObservation.recordProfileAttempt(profile.id)

        do {
            markHostWorkerRunStarted(hostRunID, runtime: runtime)
            let outcome = try await AgentSubagentRunner.run(
                prompt: Self.preflightPrompt(requestText: requestText, profileID: profile.id),
                configuration: childConfiguration,
                workspaceURL: workspaceURL,
                localSandboxDisabled: runtime.localSandboxDisabled,
                runtimeDescriptor: runtimeDescriptor,
                workspaceLocation: workspaceLocation,
                someIMContext: someIMContext,
                outputSchema: requestsCodingPlan ? AgentCodingTaskPlan.schema : nil,
                profile: profile,
                writeAccess: nil,
                verifierCommand: nil,
                patchProposalSink: nil,
                terminalController: profile.id == AgentSubagentProfileCatalog.terminalOperatorID
                    ? agentTerminalController
                    : nil,
                executionBudget: toolExecutionBudget(for: runtime),
                // Without this the card above the composer sits at round 0 with
                // an empty tool count for the whole run: `onProgress` defaults
                // to nil, so nothing ever writes `subagentLiveActivity` and the
                // fleet row falls back to zeroes while the Worker is visibly
                // working. Most obvious on the terminal operator, the one
                // profile this path hands a terminal to.
                onProgress: { [weak self] update in
                    guard let self else { return }
                    self.applySubagentLiveProgress(
                        update,
                        recordID: recordID,
                        runtime: runtime,
                        profileID: profile.id,
                        workerName: L10n.AgentDelegation.profileName(for: profile.id),
                        model: childConfiguration.model
                    )
                }
            )
            settle(.succeeded, summary: "preflight")
            finishHostWorkerRun(hostRunID, status: .succeeded, outcome: outcome, runtime: runtime)
            if requestsCodingPlan,
               let data = outcome.report.data(using: .utf8),
               let plan = try? JSONDecoder().decode(AgentCodingTaskPlan.self, from: data) {
                if let workspaceRevision {
                    await AgentCodingArtifactCache.shared.store(
                        plan,
                        requestText: requestText,
                        revision: workspaceRevision
                    )
                }
                runtime.currentTurnRouteSteering = Self.steeringWithCodingPlan(
                    existing: runtime.currentTurnRouteSteering,
                    profileID: profile.id,
                    model: childConfiguration.model,
                    plan: plan,
                    cacheHit: false
                )
                return plan
            } else {
                runtime.currentTurnRouteSteering = Self.steeringWithReport(
                    existing: runtime.currentTurnRouteSteering,
                    profileID: profile.id,
                    model: childConfiguration.model,
                    report: outcome.report
                )
            }
        } catch {
            settle(.failed, summary: "preflight failed", error: error.localizedDescription)
            finishHostWorkerRun(hostRunID, status: .failed, runtime: runtime)
            // Deliberately silent toward the model: a failed preflight is not
            // evidence that the task is hard, and telling the root model about
            // WillDeep's plumbing invites it to reason about the wrong thing.
        }
        return nil
    }

    /// The worker sees none of this conversation, so the request is restated
    /// as a self-contained brief.
    static func preflightPrompt(requestText: String, profileID: String = "reader") -> String {
        let task: String
        switch profileID {
        case AgentSubagentProfileCatalog.scoutID:
            task = "Locate the smallest relevant file and symbol set, likely call sites, and verification commands. For coding requests, return an exact bounded task packet: workspace-relative read_files and write_files, confirmed symbols/facts, constraints, the narrowest verifier command, concrete risk flags, and every unresolved question. Never put a path in write_files unless the requested implementation must change it. Do not edit anything."
        case AgentSubagentProfileCatalog.logInspectorID:
            task = "Inspect the supplied failure evidence and nearby diagnostics. Identify likely causes and the smallest repair scope. Do not edit anything."
        case AgentSubagentProfileCatalog.testerID:
            task = "Run the narrowest relevant existing test or validation gates, then report exact commands, exit status, and failures. Do not repair failures."
        case AgentSubagentProfileCatalog.opsRunnerID:
            task = "Perform read-only operational preflight only: inspect current service/deployment state, find the repository's existing release procedure, and report the exact command plus rollback/verification evidence. Do not deploy, restart, mutate, or retry anything."
        case AgentSubagentProfileCatalog.terminalOperatorID:
            task = "Inspect the visible terminal using only read-only terminal actions. Report the active command/prompt and relevant output; do not type a mutating command."
        default:
            task = "Answer using bounded read-only inspection. Report precise locations (path plus line numbers) and quote only what you actually saw."
        }
        return """
        \(task) If you cannot finish, say exactly what you checked so the caller can continue \
        from there — do not guess.

        Request:
        \(requestText)
        """
    }

    /// Upper bound on the report as injected, independent of the 32K-character
    /// cap a subagent transcript is stored under.
    ///
    /// The system prompt is rebuilt on every tool round, so this text is paid
    /// for once per round of the turn. (Injecting into the user message the
    /// way willdeep-rs does costs exactly the same — that copy lives in the
    /// history every round too — but it also never expires, whereas
    /// `currentTurnRouteSteering` is cleared when the next turn starts.)
    /// A preflight worth reading fits in this; a report that does not is one
    /// the root model should be re-deriving selectively anyway.
    static let injectedReportCharacterLimit = 6_000

    /// Fold the worker's report into the steering paragraph the turn already
    /// carries, so the system prompt gains one block rather than two.
    static func steeringWithReport(
        existing: String?,
        profileID: String,
        model: String,
        report: String
    ) -> String {
        let report = clampedReport(report)
        let block = """
        <runtime-preflight profile="\(profileID)" model="\(model)">
        WillDeep ran this bounded worker before you saw the request. Treat the report \
        as evidence, not as a conclusion: verify a citation when you are about to rely on it, and \
        do not re-read the same material unless the report is incomplete or looks wrong.
        <worker-report>
        \(report)
        </worker-report>
        </runtime-preflight>
        """
        guard let existing, !existing.isEmpty else { return block }
        return existing + "\n\n" + block
    }

    static func steeringWithCodingPlan(
        existing: String?,
        profileID: String,
        model: String,
        plan: AgentCodingTaskPlan,
        cacheHit: Bool
    ) -> String {
        let writeFiles = plan.writeFiles.map { "`\($0)`" }.joined(separator: ", ")
        let readFiles = plan.readFiles.map { "`\($0)`" }.joined(separator: ", ")
        let unresolved = plan.unresolved.isEmpty
            ? "none"
            : plan.unresolved.map { "- \($0)" }.joined(separator: "\n")
        let block = """
        <runtime-coding-plan profile="\(profileID)" model="\(model)" cache-hit="\(cacheHit)">
        WillDeep's read-only scout produced a structured task packet. The host independently \
        enforces file scope and risk; do not assume the scout's risk label grants authority.
        Goal: \(plan.goal)
        Read files: \(readFiles.isEmpty ? "none" : readFiles)
        Write files: \(writeFiles.isEmpty ? "none" : writeFiles)
        Verifier: \(plan.verifierCommand.isEmpty ? "none" : plan.verifierCommand)
        Suggested risk: \(plan.suggestedRiskLevel.rawValue)
        Unresolved:
        \(unresolved)
        </runtime-coding-plan>
        """
        guard let existing, !existing.isEmpty else { return block }
        return existing + "\n\n" + block
    }

    /// Truncate from the end and say so. A silently cut report reads as a
    /// complete one, and the root model would then treat "the worker did not
    /// mention it" as evidence of absence.
    static func clampedReport(_ report: String) -> String {
        guard report.count > injectedReportCharacterLimit else { return report }
        let kept = report.prefix(injectedReportCharacterLimit)
        return kept + """


        […truncated at \(injectedReportCharacterLimit) characters. This report was cut, not \
        completed — do not read the absence of something here as evidence it is not there. \
        Inspect the workspace yourself for anything the visible part leaves open.]
        """
    }
}
