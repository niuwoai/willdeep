//
//  AppStateAgentSpecGate.swift
//  WillDeep
//
//  Where the spec gate joins a turn.
//
//  The call sits between the local routing refinement and the optional
//  read-only preflight, which is the last place "before work starts" is still
//  literally true: the provider slot is already claimed, keyword routing has
//  already produced a decision this can read, and `runAgentLoop` has not been
//  entered, so declining to proceed costs nothing to unwind.
//
//  It is also the narrowest place. The enclosing branch only runs for
//  `source == .operatorInput`, so tool-loop continuations, host instructions
//  and dispatch resumptions never re-trigger a judgement about work that is
//  already underway — which is exactly the bug a gate like this would
//  otherwise have.
//
//  See docs/SPEC_FIRST_GATE_DESIGN.md §6.
//

import AppKit
import Foundation

extension AppState {
    /// Decide whether this request is design-shaped, record the decision, and
    /// raise the gate when enforcement is on.
    ///
    /// Never throws. Every failure path proceeds with the turn: a gate that
    /// cannot decide must not become a gate that blocks.
    @discardableResult
    func evaluateSpecGate(
        for runtime: AgentRuntime,
        requestText: String,
        settingEnabled: Bool = AgentSettingsStore.loadSpecGateEnabled(),
        enforcementEnabled: Bool = AgentSettingsStore.loadSpecGateEnforcement()
    ) async -> AgentSpecGateVerdict {
        guard settingEnabled else {
            return .proceed(.disabled)
        }

        // One decision per conversation. Re-gating after the operator already
        // said "go ahead" is how a gate that helped once becomes a gate that
        // gets switched off.
        if runtime.specGateState == .released {
            return .proceed(.userOptedOut)
        }

        let input = AgentSpecGateSignals.Input(
            requestText: requestText,
            routeDecision: runtime.currentTurnRouteDecision,
            hasWorkspace: runtime.workspaceRootPath != nil,
            isGoalMode: runtime.interactionMode == .goal,
            isUnattendedDispatch: runtime.isUnattendedDispatchTask
        )

        // `signals(for:)` returns empty for both "excluded" and "nothing
        // matched", so the exclusions are re-checked here to keep the two
        // apart in the log. A row that says `belowThreshold` when the turn was
        // never eligible would poison the very rate this log exists to
        // measure.
        let excluded = input.isGoalMode
            || input.isUnattendedDispatch
            || !input.hasWorkspace
        guard !excluded else {
            return .proceed(.excluded)
        }

        let signals = AgentSpecGateSignals.signals(for: input)
        guard AgentSpecGateSignals.clearsThreshold(signals) else {
            let verdict = AgentSpecGateVerdict.proceed(.belowThreshold, signals: signals)
            // A near miss is worth a row — it is how the threshold gets argued
            // with later. A turn with no signals at all is the common case and
            // would drown the log.
            if !signals.isEmpty {
                record(verdict, runtime: runtime, requestLength: requestText.count)
            }
            return verdict
        }

        var verdict = await reviewedVerdict(
            for: runtime,
            requestText: requestText,
            signals: signals
        )

        // Enforcement off means the gate still decides and still records — it
        // just does not interrupt. That is the shadow mode the threshold is
        // meant to be calibrated in.
        if verdict.outcome == .gate && !enforcementEnabled {
            verdict = AgentSpecGateVerdict(
                outcome: .proceed,
                reason: .shadowOnly,
                signals: signals,
                judgeModel: verdict.judgeModel,
                judgeLatencyMS: verdict.judgeLatencyMS
            )
        }

        if verdict.outcome == .gate {
            runtime.specGateState = .awaitingDocument
            runtime.specProposal = nil
            runtime.persist()
        }

        record(verdict, runtime: runtime, requestLength: requestText.count)
        return verdict
    }

    /// The design document the gate was waiting for has been written.
    ///
    /// Moves to `awaitingUserReview`: still blocking, but now with something
    /// for the operator to read. The card itself is inserted when the turn
    /// ends — mid-stream is the wrong moment to push a decision at someone.
    func noteSpecGateDocument(_ documentPath: String, for runtime: AgentRuntime) {
        guard runtime.specGateState == .awaitingDocument else { return }
        runtime.specGateState = .awaitingUserReview
        runtime.specProposal = AgentSpecProposal(
            documentPath: documentPath,
            signals: runtime.specProposal?.signals ?? []
        )
        runtime.persist()
    }

    /// The turn ended while the gate was up. Either hand the operator a card,
    /// or stand down.
    func finalizeSpecGateTurn(for runtime: AgentRuntime) {
        switch runtime.specGateState {
        case .awaitingUserReview:
            guard let proposal = runtime.specProposal else { return }
            appendSpecProposalCard(proposal, for: runtime)
        case .awaitingDocument:
            // Asked for a document and did not get one. Standing down is the
            // only honest option: holding write tools hostage to a document
            // the model declined to write strands the conversation, and
            // asking again is how a gate turns into a loop.
            runtime.specGateState = .released
            runtime.specProposal = nil
            runtime.persist()
        case .inactive, .released:
            break
        }
    }

    // MARK: - The card

    /// Put the proposal in the transcript. Called at end of turn, not at the
    /// moment the file lands: pushing a decision at someone mid-stream reads
    /// as an interruption of the thing they are still watching.
    func appendSpecProposalCard(_ proposal: AgentSpecProposal, for runtime: AgentRuntime) {
        guard !runtime.messages.contains(where: { $0.specProposal?.id == proposal.id }) else { return }
        var message = AgentMessage(role: .specProposal, content: "")
        message.specProposal = proposal
        runtime.messages.append(message)
        runtime.persist()
    }

    /// The operator wants the work done as described. Release the gate and
    /// continue in the same runtime, with the same history.
    func acceptSpecProposal(_ proposalID: UUID) {
        guard let runtime = activeRuntime,
              let proposal = runtime.specProposal,
              proposal.id == proposalID else { return }
        settleSpecProposal(proposalID, choice: .accepted, runtime: runtime)
        let instruction = """
        The operator reviewed \(proposal.documentPath) and approved it. Implement it now, \
        following that document. This approval releases the design gate only; it grants no \
        new tool permissions, and every tool call is still subject to the usual approval and \
        sandbox rules.
        """
        resumeAfterSpecProposal(instruction, runtime: runtime)
    }

    /// The operator does not want the document standing between them and the
    /// work. Release the gate, and record it — this is the false-positive
    /// signal the whole feature is judged on.
    func dismissSpecProposal(_ proposalID: UUID) {
        guard let runtime = activeRuntime,
              let proposal = runtime.specProposal,
              proposal.id == proposalID else { return }
        settleSpecProposal(proposalID, choice: .dismissed, runtime: runtime)
        AgentSpecGateAuditLog.record(
            verdict: AgentSpecGateVerdict.proceed(.userOptedOut, signals: proposal.signals),
            sessionID: runtime.session.id,
            requestLength: 0,
            userChoice: AgentSpecProposalChoice.dismissed.rawValue
        )
        let instruction = """
        The operator chose to proceed without the design document. Carry out the original \
        request directly. Do not write further design documents for this task unless asked. \
        This releases the design gate only; it grants no new tool permissions.
        """
        resumeAfterSpecProposal(instruction, runtime: runtime)
    }

    /// Reveal the document so the operator can actually read what they are
    /// being asked to approve.
    func openSpecProposalDocument(_ proposalID: UUID) {
        guard let runtime = activeRuntime,
              let proposal = runtime.specProposal,
              proposal.id == proposalID,
              let root = runtime.workspaceRootPath else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent(proposal.documentPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    private func settleSpecProposal(
        _ proposalID: UUID,
        choice: AgentSpecProposalChoice,
        runtime: AgentRuntime
    ) {
        runtime.specProposal?.choice = choice
        runtime.specGateState = .released
        if let index = runtime.messages.firstIndex(where: { $0.specProposal?.id == proposalID }) {
            runtime.messages[index].specProposal?.choice = choice
        }
        runtime.persist()
    }

    /// Continue the conversation in place. Same runtime, same messages, one
    /// appended host instruction — the shape dispatch decisions already use,
    /// including the sentence about permissions, which exists because an
    /// answer to a question must never read as a grant.
    private func resumeAfterSpecProposal(_ instruction: String, runtime: AgentRuntime) {
        guard !runtime.isResponding else { return }
        let message = AgentMessage(role: .user, content: instruction, source: .hostInstruction)
        runtime.messages.append(message)
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
        dispatchAgentMessage(
            for: runtime,
            text: instruction,
            images: [],
            existingUserMessageID: message.id,
            source: .hostInstruction
        )
    }

    /// Ask a model whether the host over-read this request, and fold the
    /// answer in.
    ///
    /// The reviewer can only take the gate down, never put one up. Three
    /// outcomes, deliberately distinguished:
    ///
    /// - It said "local change" with enough confidence → proceed.
    /// - It was asked and produced nothing usable → proceed. Failing to gate
    ///   is a missed document; gating wrongly interrupts someone mid-thought.
    /// - There was no reviewer to ask → keep the host's own conclusion. This
    ///   is the ordinary state for a user with no spare provider key, and
    ///   treating it as a failure would quietly disable the feature for them.
    private func reviewedVerdict(
        for runtime: AgentRuntime,
        requestText: String,
        signals: [AgentSpecGateSignal]
    ) async -> AgentSpecGateVerdict {
        let candidates = safetyJudgeCandidateConfigurations()
        guard let configuration = candidates.first else {
            return AgentSpecGateVerdict(
                outcome: .gate,
                reason: .judgeUnconfigured,
                signals: signals
            )
        }

        let client = AgentClient(
            configuration: configuration,
            session: safetyJudgeInferenceEnvironment?.session,
            someIMContext: Self.goalPlanningSomeIMContext(configuration: configuration, runtime: runtime),
            requestLedger: modelRequestLedger(for: runtime)
        )
        let judge = AgentGoalRouteJudge(
            client: client,
            executionBudget: auxiliaryModelExecutionBudget(for: runtime)
        )
        let startedAt = Date()
        let verdict = await AgentSpecGateJudge.review(
            requestText: requestText,
            signals: signals
        ) { system, user, maxTokens in
            await judge.text(model: configuration.model, system: system, user: user, maxTokens: maxTokens)
        }
        let latency = Int(Date().timeIntervalSince(startedAt) * 1000)

        guard let verdict else {
            return AgentSpecGateVerdict(
                outcome: .proceed,
                reason: .judgeUnavailable,
                signals: signals,
                judgeModel: configuration.model,
                judgeLatencyMS: latency
            )
        }
        return AgentSpecGateVerdict(
            outcome: verdict.releasesGate ? .proceed : .gate,
            reason: verdict.releasesGate ? .judgeDowngraded : .confirmed,
            signals: signals,
            judgeModel: configuration.model,
            judgeLatencyMS: latency
        )
    }

    private func record(
        _ verdict: AgentSpecGateVerdict,
        runtime: AgentRuntime,
        requestLength: Int
    ) {
        AgentSpecGateAuditLog.record(
            verdict: verdict,
            sessionID: runtime.session.id,
            requestLength: requestLength
        )
    }
}
