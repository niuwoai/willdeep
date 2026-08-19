//
//  AppStateAgentReadOnlyPreflight.swift
//  WillDeep
//
//  Running a bounded read-only worker *before* the root model answers.
//
//  `AgentRequestRouter` classifies the request and, on its own, only appends
//  a steering paragraph. This is the executing half: for the high-confidence
//  read-only cases it actually dispatches the worker first and hands the root
//  model the report as evidence, so the expensive model spends its window
//  reasoning about findings instead of re-deriving them.
//
//  Off by default, and that is a considered position rather than caution:
//
//  - It costs time the user can feel. In a TUI a pause before the first token
//    is ordinary; in a GUI it doubles time-to-first-token on questions as
//    small as "where is this function".
//  - The classifier is keyword matching. A false positive here is not a
//    wasted paragraph, it is a wasted worker run and a visibly slower answer.
//
//  So the switch ships off and the Deep Share / Skill Coverage numbers decide
//  when to turn it on. `agent.auto_dispatch_read_only` in the shared
//  config.toml turns it on for both clients at once.
//
//  Read-only by construction: no write access, no verifier, no editor lock,
//  no patch sink. A preflight that can edit is not a preflight.
//
//  See docs/SMALL_MODEL_FIRST_RUNTIME_PLAN.md §4 step 4.
//

import Foundation

extension AppState {
    /// Whether request-level preflight may run at all. The shared config.toml
    /// wins; absent, it stays off.
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
        assistantMessageID: UUID
    ) async {
        guard Self.readOnlyPreflightEnabled() else { return }
        // `/no-subagent` means "do all of it yourself this turn". Dispatching
        // a worker anyway would be the one thing the user explicitly refused.
        guard runtime.currentTurnDelegationPolicy != .forbidden else { return }

        let decision = AgentRequestRouter.classify(requestText)
        guard decision.autoDispatchEligible, let profileID = decision.profileID else { return }

        // A remote workspace has no local tree for a read-only worker to walk,
        // and the trades this path uses are the local file/git ones.
        let workspaceLocation = runtime.workspaceLocation
            ?? runtime.workspaceRootPath.map { .local(path: $0) }
        guard workspaceLocation?.remoteRuntimeID == nil,
              let workspaceURL = try? runtime.localWorkspaceURLForOptimisticUse() else { return }

        let profile = AgentSubagentProfileStore.resolvedProfile(id: profileID)
        // Defensive: every trade this router names is read-only, but a
        // user-edited profile store could have widened one of them.
        guard !profile.requiresWriteAccess else { return }

        let childConfiguration = resolvedSubagentConfiguration(
            for: profile,
            parentConfiguration: configuration
        )

        // Visible in WillDeep's own ledger before it starts. A pause the user
        // cannot account for is worse than the pause itself.
        let recordID = UUID()
        runtime.toolCalls.append(AgentToolCall(
            id: recordID,
            messageID: assistantMessageID,
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
            let outcome = try await AgentSubagentRunner.run(
                prompt: Self.preflightPrompt(requestText: requestText),
                configuration: childConfiguration,
                workspaceURL: workspaceURL,
                workspaceLocation: workspaceLocation,
                profile: profile,
                writeAccess: nil,
                verifierCommand: nil,
                patchProposalSink: nil
            )
            settle(.succeeded, summary: "preflight")
            runtime.currentTurnRouteSteering = Self.steeringWithReport(
                existing: runtime.currentTurnRouteSteering,
                profileID: profile.id,
                model: childConfiguration.model,
                report: outcome.report
            )
        } catch {
            settle(.failed, summary: "preflight failed", error: error.localizedDescription)
            // Deliberately silent toward the model: a failed preflight is not
            // evidence that the task is hard, and telling the root model about
            // WillDeep's plumbing invites it to reason about the wrong thing.
        }
    }

    /// The worker sees none of this conversation, so the request is restated
    /// as a self-contained brief.
    static func preflightPrompt(requestText: String) -> String {
        """
        Answer the following request about this workspace using read-only \
        inspection. Report precise locations (path plus line numbers) and quote \
        only what you actually saw. If you cannot answer it fully, say exactly \
        what you checked so the caller can continue from there — do not guess.

        Request:
        \(requestText)
        """
    }

    /// Fold the worker's report into the steering paragraph the turn already
    /// carries, so the system prompt gains one block rather than two.
    static func steeringWithReport(
        existing: String?,
        profileID: String,
        model: String,
        report: String
    ) -> String {
        let block = """
        <runtime-preflight profile="\(profileID)" model="\(model)">
        WillDeep ran this bounded read-only worker before you saw the request. Treat the report \
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
}
