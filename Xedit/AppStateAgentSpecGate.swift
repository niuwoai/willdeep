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
//  Phase 1 does not enforce. It writes one line per interesting decision and
//  returns. See docs/SPEC_FIRST_GATE_DESIGN.md §11.
//

import Foundation

extension AppState {
    /// Decide whether this request is design-shaped, record the decision, and
    /// return it.
    ///
    /// Never throws, never awaits anything, never touches the turn. Phase 1's
    /// entire contract is that the user cannot tell it ran.
    @discardableResult
    func evaluateSpecGate(
        for runtime: AgentRuntime,
        requestText: String,
        settingEnabled: Bool = AgentSettingsStore.loadSpecGateEnabled()
    ) -> AgentSpecGateVerdict {
        guard settingEnabled else {
            return .proceed(.disabled)
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
        let verdict: AgentSpecGateVerdict
        if AgentSpecGateSignals.clearsThreshold(signals) {
            // Phase 3 turns this into `.gate`. Until the false-positive rate
            // says the threshold is right, the honest outcome is `proceed`
            // with a reason that says what would have happened.
            verdict = AgentSpecGateVerdict(
                outcome: .proceed,
                reason: .shadowOnly,
                signals: signals
            )
        } else {
            verdict = .proceed(.belowThreshold, signals: signals)
        }

        // A near miss is worth a row — it is how the threshold gets argued
        // with later. A turn with no signals at all is the common case and
        // would drown the log.
        if !signals.isEmpty {
            AgentSpecGateAuditLog.record(
                verdict: verdict,
                sessionID: runtime.session.id,
                requestLength: requestText.count
            )
        }

        return verdict
    }
}
