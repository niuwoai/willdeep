//
//  AppStateAgentSpeculativeScout.swift
//  WillDeep
//
//  The parallel read-only scout.
//
//  The serial preflight (AppStateAgentReadOnlyPreflight) runs a read-only
//  worker *before* the root model and therefore taxes time-to-first-token on
//  every request it matches. This is the same worker started *alongside* the
//  first provider request instead: the root model streams immediately, and
//  if the scout finishes before one of the turn's tool boundaries its report
//  is injected there as a system message. If the turn ends first, the scout
//  is cancelled (or its report dropped) — the user asked a question, not for
//  a second answer later.
//
//  Deliberately not a registry background run. Background runs queue a
//  pending report and publish a kernel event, both of which can wake the
//  runtime after the turn has ended; that is exactly what a speculative
//  helper must never do. Everything here is owned by the turn: started in
//  `dispatchAgentMessage`, drained at the top of each round, finalized in
//  `runAgentLoop`'s defer.
//
//  `/no-subagent` (`.forbidden`) disables it for the turn, an operator-pinned
//  worker replaces it, and the serial preflight (when explicitly enabled)
//  takes precedence so a request never gets two scouts.
//

import Foundation
import OSLog

@MainActor
final class AgentSpeculativeScout {
    enum Phase: String, Sendable {
        case running
        /// Finished with a report that no tool boundary has consumed yet.
        case reported
        case delivered
        /// Finished, but the turn ended before a tool boundary could read it.
        case dropped
        case cancelled
        case timedOut
        case failed
    }

    let profileID: String
    let model: String
    let providerID: String
    let hostRunID: UUID
    let cardRecordID: UUID
    let userMessageID: UUID
    let prompt: String
    let requestedAt = Date()
    var startedAt: Date?
    var finishedAt: Date?
    var phase: Phase = .running
    var report: String?
    var outcome: AgentSubagentRunner.Outcome?
    var task: Task<Void, Never>?
    var timeoutTask: Task<Void, Never>?

    init(
        profileID: String,
        model: String,
        providerID: String,
        hostRunID: UUID,
        cardRecordID: UUID,
        userMessageID: UUID,
        prompt: String
    ) {
        self.profileID = profileID
        self.model = model
        self.providerID = providerID
        self.hostRunID = hostRunID
        self.cardRecordID = cardRecordID
        self.userMessageID = userMessageID
        self.prompt = prompt
    }
}

extension AppState {
    private static let parallelScoutLog = Logger(
        subsystem: "com.willdeep.app",
        category: "parallel-scout"
    )

    /// Wall-clock cap. A scout that has not reported by then is unlikely to
    /// beat the root model to a useful tool boundary anyway.
    static let speculativeScoutTimeout: TimeInterval = 45
    /// Round cap, tighter than the profile's own: this is a sprint, not the
    /// serial preflight's full investigation.
    static let speculativeScoutMaxRounds = 4

    /// The shared config wins; absent, the parallel scout is on. It rides on
    /// `small_model_routing` because without routing there is no decision to
    /// scout for.
    static func speculativeScoutEnabled(
        sharedConfig: AgentSharedRuntimeConfig = .load()
    ) -> Bool {
        sharedConfig.smallModelRouting != false && (sharedConfig.speculativeScout ?? true)
    }

    /// Which routed profile, if any, should scout in parallel for this turn.
    /// Pure so the policy can be tested without a runtime.
    static func speculativeScoutProfileID(
        decision: AgentRequestRouter.Decision?,
        delegationPolicy: AgentDelegationPolicy,
        serialPreflightEnabled: Bool,
        speculativeEnabled: Bool
    ) -> String? {
        guard speculativeEnabled, !serialPreflightEnabled else { return nil }
        // `/no-subagent` means "do all of it yourself this turn".
        guard delegationPolicy != .forbidden else { return nil }
        guard let decision,
              // A named worker is an instruction the root model will act on;
              // a second scout for the same question would only duplicate it.
              !decision.isOperatorPinned,
              // Read-only requests only. A mutation route's scout prepares a
              // write task and belongs to the explicit serial preflight.
              decision.autoDispatchEligible,
              let profileID = decision.preflightProfileID,
              profileID == decision.profileID else { return nil }
        return profileID
    }

    static func steeringWithParallelScout(
        existing: String?,
        profileID: String,
        model: String
    ) -> String {
        let note = """
        <runtime-parallel-scout profile="\(profileID)" model="\(model)">
        WillDeep started a read-only `\(profileID)` worker in parallel with this turn, on the same request. \
        If it finishes in time, its findings arrive as a <runtime-parallel-scout-report> system message at one of \
        your tool boundaries; treat them as evidence to verify, not as a verdict. Do not wait for it, do not poll, \
        and do not spawn another read-only worker for the same question. If you already know enough, answer directly.
        </runtime-parallel-scout>
        """
        return [existing, note].compactMap { $0 }.joined(separator: "\n\n")
    }

    static func parallelScoutReportNotice(
        profileID: String,
        model: String,
        rounds: Int,
        report: String
    ) -> String {
        """
        <runtime-parallel-scout-report profile="\(profileID)" model="\(model)" rounds="\(rounds)">
        The parallel read-only worker finished. Its report follows. It was gathered without your context, so \
        verify anything you build on, and do not read the absence of a finding as evidence of absence.

        \(clampedReport(AgentInjectionDefense.neutralizeInjectionMarkers(in: report)))
        </runtime-parallel-scout-report>
        """
    }

    /// A turn-owned scout gets the same live card and inspector identity as
    /// other foreground Workers, without entering the background registry.
    /// `hostRunID` is already unique and durable, so it also keys the
    /// transcript sidecar used by the fleet panel.
    static func speculativeScoutToolCall(
        hostRunID: UUID,
        cardRecordID: UUID,
        userMessageID: UUID,
        profile: AgentSubagentProfile,
        workerName: String,
        model: String,
        startedAt: Date = Date()
    ) -> AgentToolCall {
        var call = AgentToolCall(
            id: cardRecordID,
            messageID: userMessageID,
            externalID: "parallel-scout-\(cardRecordID.uuidString)",
            toolName: "spawn_agent",
            arguments: [
                "profile": .string(profile.id),
                "_runtime_parallel_scout": .bool(true),
            ],
            risk: .read,
            status: .running,
            startedAt: startedAt,
            subagentModel: model,
            subagentWorkerName: workerName,
            subagentRunID: hostRunID
        )
        call.subagentLiveActivity = AgentSubagentLiveActivity(
            profileID: profile.id,
            workerName: workerName,
            model: model,
            round: 0,
            maximumRounds: profile.maxRounds,
            completedToolInvocations: 0,
            activityText: "",
            startedAt: startedAt,
            isBackground: false
        )
        return call
    }

    /// Start the scout for this turn if the route, the policy and the
    /// workspace binding all allow it. Never throws, never blocks: on any
    /// missing precondition the turn simply proceeds without a scout.
    func startSpeculativeScoutIfEligible(
        for runtime: AgentRuntime,
        requestText: String,
        configuration: AgentConfiguration,
        userMessageID: UUID
    ) {
        runtime.speculativeScout = nil
        guard runtime.currentTurnDelegationPolicy != .agentPreferred else { return }
        guard !runtime.isUnattendedDispatchTask else { return }
        guard let profileID = Self.speculativeScoutProfileID(
            decision: runtime.currentTurnRouteDecision,
            delegationPolicy: runtime.currentTurnDelegationPolicy,
            serialPreflightEnabled: Self.readOnlyPreflightEnabled(),
            speculativeEnabled: Self.speculativeScoutEnabled()
        ) else { return }

        let workspaceLocation = runtime.workspaceLocation
            ?? runtime.workspaceRootPath.map { .local(path: $0) }
        let runtimeDescriptor = workspaceLocation?.remoteRuntimeID.flatMap {
            AgentRuntimeStore.descriptor(id: $0)
        }
        let workspaceURL: URL?
        if workspaceLocation?.remoteRuntimeID != nil {
            guard runtimeDescriptor != nil else { return }
            workspaceURL = nil
        } else {
            workspaceURL = try? runtime.localWorkspaceURLForOptimisticUse()
        }

        var profile = AgentSubagentProfileStore.resolvedProfile(id: profileID)
        // Defensive: every scout trade is non-writing, but a user-edited
        // profile store could have widened one of them.
        guard !profile.requiresWriteAccess else { return }
        profile.maxRounds = min(max(1, profile.maxRounds), Self.speculativeScoutMaxRounds)
        guard profile.id == AgentSubagentProfileCatalog.terminalOperatorID
                || workspaceURL != nil
                || runtimeDescriptor != nil else { return }

        let childConfiguration = resolvedSubagentConfiguration(
            for: profile,
            parentConfiguration: configuration,
            sessionID: runtime.id
        )
        let someIMContext: SomeIMRequestContext? = {
            guard childConfiguration.providerID == AgentProviderPreset.someIMID else { return nil }
            let workspaceID = AgentWorkspaceIdentityStore.workspaceID(
                forWorkspaceKey: Self.managedWorkspaceKey(for: runtime)
            )
            return SomeIMRequestContext(sessionID: runtime.id.uuidString, workspaceID: workspaceID)
        }()

        let hostRunID = beginHostWorkerRun(
            profileID: profile.id,
            source: .speculativeScout,
            userMessageID: userMessageID,
            model: childConfiguration.model,
            providerID: childConfiguration.providerID,
            runtime: runtime
        )
        let prompt = Self.preflightPrompt(requestText: requestText, profileID: profile.id)
        let workerName = L10n.AgentDelegation.profileName(for: profile.id)
        // Visible in the ledger and fleet panel from the start, like the
        // preflight card, but deliberately absent from the background registry.
        let cardRecordID = UUID()
        runtime.toolCalls.append(Self.speculativeScoutToolCall(
            hostRunID: hostRunID,
            cardRecordID: cardRecordID,
            userMessageID: userMessageID,
            profile: profile,
            workerName: workerName,
            model: childConfiguration.model
        ))

        let scout = AgentSpeculativeScout(
            profileID: profile.id,
            model: childConfiguration.model,
            providerID: childConfiguration.providerID,
            hostRunID: hostRunID,
            cardRecordID: cardRecordID,
            userMessageID: userMessageID,
            prompt: prompt
        )
        runtime.speculativeScout = scout
        runtime.currentTurnRouteSteering = Self.steeringWithParallelScout(
            existing: runtime.currentTurnRouteSteering,
            profileID: profile.id,
            model: childConfiguration.model
        )
        markHostWorkerRunStarted(hostRunID, runtime: runtime)
        scout.startedAt = Date()
        Self.parallelScoutLog.notice(
            "parallel scout started runtime=\(runtime.id.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) model=\(childConfiguration.model, privacy: .public)"
        )

        let terminalController = profile.id == AgentSubagentProfileCatalog.terminalOperatorID
            ? agentTerminalController
            : nil
        let runProfile = profile
        let executionBudget = toolExecutionBudget(for: runtime)
        scout.task = Task { @MainActor [weak self, weak runtime, scout] in
            let result: Result<AgentSubagentRunner.Outcome, Error>
            do {
                let outcome = try await AgentSubagentRunner.run(
                    prompt: prompt,
                    configuration: childConfiguration,
                    workspaceURL: workspaceURL,
                    localSandboxDisabled: runtime?.localSandboxDisabled ?? false,
                    runtimeDescriptor: runtimeDescriptor,
                    workspaceLocation: workspaceLocation,
                    someIMContext: someIMContext,
                    profile: runProfile,
                    writeAccess: nil,
                    verifierCommand: nil,
                    patchProposalSink: nil,
                    terminalController: terminalController,
                    executionBudget: executionBudget,
                    onProgress: { [weak self, weak runtime] update in
                        guard let self, let runtime else { return }
                        self.applySubagentLiveProgress(
                            update,
                            recordID: cardRecordID,
                            runtime: runtime,
                            profileID: runProfile.id,
                            workerName: workerName,
                            model: childConfiguration.model
                        )
                    }
                )
                result = .success(outcome)
            } catch {
                result = .failure(error)
            }
            guard let self, let runtime else { return }
            self.completeSpeculativeScout(scout, runtime: runtime, result: result)
        }
        scout.timeoutTask = Task { @MainActor [weak scout] in
            try? await Task.sleep(nanoseconds: UInt64(Self.speculativeScoutTimeout * 1_000_000_000))
            guard !Task.isCancelled, let scout, scout.phase == .running else { return }
            scout.phase = .timedOut
            scout.task?.cancel()
        }
    }

    /// The report for this turn's next tool boundary, once. Nil while the
    /// scout is still running, after delivery, or when there is no scout.
    func takeSpeculativeScoutReportIfReady(for runtime: AgentRuntime) -> String? {
        guard let scout = runtime.speculativeScout,
              scout.phase == .reported,
              let report = scout.report else { return nil }
        scout.phase = .delivered
        // Counted as a lower-tier attempt only once the root model actually
        // received the evidence; a dropped scout proves nothing either way.
        runtime.deepAdmissionObservation.recordProfileAttempt(scout.profileID)
        markHostWorkerDelivery(scout.hostRunID, accepted: true, requiredParentRepair: false, runtime: runtime)
        recordSpeculativeScoutTiming(scout, runtime: runtime, deliveredAtToolBoundary: true)
        Self.parallelScoutLog.notice(
            "parallel scout delivered runtime=\(runtime.id.uuidString, privacy: .public) profile=\(scout.profileID, privacy: .public) rounds=\(scout.outcome?.roundCount ?? 0, privacy: .public) reportChars=\(report.count, privacy: .public)"
        )
        return Self.parallelScoutReportNotice(
            profileID: scout.profileID,
            model: scout.model,
            rounds: scout.outcome?.roundCount ?? 0,
            report: report
        )
    }

    /// Turn end. Returns the scout's final phase for the turn's timing line,
    /// or nil when the turn had no scout.
    @discardableResult
    func finalizeSpeculativeScoutAtTurnEnd(for runtime: AgentRuntime) -> String? {
        guard let scout = runtime.speculativeScout else { return nil }
        runtime.speculativeScout = nil
        scout.timeoutTask?.cancel()
        switch scout.phase {
        case .running:
            // The completion handler settles the card, the ledger and the
            // timing line once the child loop has actually unwound.
            scout.phase = .cancelled
            scout.task?.cancel()
        case .reported:
            scout.phase = .dropped
            markHostWorkerDelivery(scout.hostRunID, accepted: false, requiredParentRepair: false, runtime: runtime)
            recordSpeculativeScoutTiming(scout, runtime: runtime, deliveredAtToolBoundary: false)
            Self.parallelScoutLog.notice(
                "parallel scout dropped runtime=\(runtime.id.uuidString, privacy: .public) profile=\(scout.profileID, privacy: .public)"
            )
        case .delivered, .dropped, .cancelled, .timedOut, .failed:
            break
        }
        return scout.phase.rawValue
    }

    /// Cancels or drops the scout, then writes the turn's timing line. Called
    /// from `runAgentLoop`'s defer, before any wake-up probe.
    func finalizeTurnTiming(for runtime: AgentRuntime, turnID: UUID, outcome: String) {
        // A veto nobody collected is worthless — the turn it would have
        // corrected is over. Cancel it rather than let it run out its budget
        // against a runtime that has moved on. Same rule as the scout below:
        // turn-owned, expired means discarded.
        if let veto = runtime.pendingRouteVeto {
            veto.task.cancel()
            runtime.pendingRouteVeto = nil
        }
        let scoutPhase = finalizeSpeculativeScoutAtTurnEnd(for: runtime)
        guard var probe = runtime.currentTurnTiming, probe.turnID == turnID else { return }
        runtime.currentTurnTiming = nil
        probe.workerRuns = runtime.currentTurnSpawnAgentCallCount + (scoutPhase == nil ? 0 : 1)
        probe.parallelScout = scoutPhase
        AgentWorkerTimingLog.record(AgentWorkerTimingLog.TurnEntry(probe: probe, outcome: outcome))
    }

    private func completeSpeculativeScout(
        _ scout: AgentSpeculativeScout,
        runtime: AgentRuntime,
        result: Result<AgentSubagentRunner.Outcome, Error>
    ) {
        scout.timeoutTask?.cancel()
        scout.finishedAt = Date()
        func settle(_ status: AgentToolCallStatus, summary: String, error: String? = nil) {
            guard let index = runtime.toolCalls.firstIndex(where: { $0.id == scout.cardRecordID }) else { return }
            if runtime.toolCalls[index].subagentLiveActivity?.finishedAt == nil {
                runtime.toolCalls[index].subagentLiveActivity?.finishedAt = scout.finishedAt
            }
            runtime.toolCalls[index].subagentProgress = nil
            runtime.toolCalls[index].status = status
            runtime.toolCalls[index].errorMessage = error
            runtime.toolCalls[index].subagentModel = scout.model
            runtime.toolCalls[index].result = AgentToolResult(summary: summary, payload: "")
        }

        switch result {
        case .success(let outcome):
            scout.outcome = outcome
            scout.report = outcome.report
            if scout.phase == .running {
                scout.phase = .reported
            }
            settle(.succeeded, summary: "parallel scout")
            finishHostWorkerRun(
                scout.hostRunID,
                status: .succeeded,
                outcome: outcome,
                runtime: runtime,
                recordsTiming: false
            )
            persistSpeculativeScoutTranscript(
                scout,
                status: .completed,
                outcome: outcome,
                report: outcome.report
            )
            // A success that arrives after the turn already released the
            // scout (phase != .reported) has nobody left to deliver to.
            if scout.phase != .reported {
                recordSpeculativeScoutTiming(scout, runtime: runtime, deliveredAtToolBoundary: false)
            }
        case .failure(let error):
            if scout.phase == .running {
                scout.phase = error is CancellationError ? .cancelled : .failed
            }
            let label = scout.phase.rawValue
            settle(.failed, summary: "parallel scout \(label)", error: error is CancellationError ? nil : error.localizedDescription)
            finishHostWorkerRun(scout.hostRunID, status: .failed, runtime: runtime, recordsTiming: false)
            persistSpeculativeScoutTranscript(
                scout,
                status: .failed,
                outcome: nil,
                report: error is CancellationError ? label : error.localizedDescription
            )
            recordSpeculativeScoutTiming(scout, runtime: runtime, deliveredAtToolBoundary: false)
            Self.parallelScoutLog.notice(
                "parallel scout \(label, privacy: .public) runtime=\(runtime.id.uuidString, privacy: .public) profile=\(scout.profileID, privacy: .public)"
            )
        }
    }

    private func persistSpeculativeScoutTranscript(
        _ scout: AgentSpeculativeScout,
        status: AgentSubagentRun.Status,
        outcome: AgentSubagentRunner.Outcome?,
        report: String
    ) {
        AppState.persistSubagentTranscript(AgentSubagentTranscript(
            runID: scout.hostRunID,
            label: L10n.AgentDelegation.profileName(for: scout.profileID),
            prompt: AgentSubagentTranscript.clamped(
                scout.prompt,
                to: AgentSubagentTranscript.Limits.promptCharacters
            ).text,
            model: scout.model,
            status: status,
            rounds: outcome?.rounds ?? [],
            report: AgentSubagentTranscript.clamped(
                report,
                to: AgentSubagentTranscript.Limits.reportCharacters
            ).text,
            usageTokens: outcome?.usageTokens ?? 0,
            startedAt: scout.startedAt ?? scout.requestedAt,
            finishedAt: scout.finishedAt,
            didTruncate: outcome?.didTruncate ?? false,
            profileID: scout.profileID,
            citationsChecked: (outcome?.citationsChecked).flatMap { $0 > 0 ? $0 : nil },
            citationsUnverifiable: (outcome?.citationsChecked).flatMap {
                $0 > 0 ? (outcome?.citationsUnverifiable ?? 0) : nil
            }
        ))
    }

    private func recordSpeculativeScoutTiming(
        _ scout: AgentSpeculativeScout,
        runtime: AgentRuntime,
        deliveredAtToolBoundary: Bool
    ) {
        AgentWorkerTimingLog.record(AgentWorkerTimingLog.WorkerRunEntry(
            runID: scout.hostRunID,
            sessionID: runtime.id,
            userMessageID: scout.userMessageID,
            profileID: scout.profileID,
            source: AgentHostWorkerRunRecord.Source.speculativeScout.rawValue,
            status: scout.phase.rawValue,
            model: scout.model,
            providerID: scout.providerID,
            requestedAt: scout.requestedAt,
            startedAt: scout.startedAt,
            finishedAt: scout.finishedAt ?? Date(),
            rounds: scout.outcome?.roundCount,
            toolInvocations: scout.outcome?.toolInvocationCount,
            promptTokens: scout.outcome?.usageSplit.prompt,
            completionTokens: scout.outcome?.usageSplit.completion,
            totalTokens: scout.outcome?.usageTokens,
            acceptedOutput: deliveredAtToolBoundary ? true : nil,
            deliveredAtToolBoundary: deliveredAtToolBoundary
        ))
    }
}
