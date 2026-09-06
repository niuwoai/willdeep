//
//  AppStateAgentRuntimeKernel.swift
//  WillDeep
//
//  Bridges host event producers to the per-session Agent runtime. The kernel
//  owns ordering and persistence; AppState owns provider turns and therefore
//  applies the scheduler's wake/yield/preempt decision.
//

import Combine
import Foundation

nonisolated enum AgentExternalWakeBudget {
    static let window: TimeInterval = 5 * 60
    static let maximumWakeupsPerRuntime = 6
}

nonisolated enum AgentExternalWakePolicy {
    static func reserve(
        history: [Date],
        now: Date,
        window: TimeInterval = AgentExternalWakeBudget.window,
        maximumWakeups: Int = AgentExternalWakeBudget.maximumWakeupsPerRuntime
    ) -> (allowed: Bool, history: [Date], nextAllowedAt: Date?) {
        let cutoff = now.addingTimeInterval(-window)
        var recent = history.filter { $0 >= cutoff }
        guard recent.count < maximumWakeups else {
            return (false, recent, recent.min().map { $0.addingTimeInterval(window) })
        }
        recent.append(now)
        return (true, recent, nil)
    }
}

nonisolated enum AgentAutomaticWakeKind: Equatable, Sendable {
    case host
    case authenticatedExternal
}

nonisolated struct AgentAutomaticWakeDecision: Equatable, Sendable {
    var kind: AgentAutomaticWakeKind
    var externalWakeHistory: [Date]
}

/// Every path that can turn an idle runtime back into a provider request must
/// pass through this policy. In particular, provider-slot release and startup
/// recovery must not bypass the external-event budget used at initial ingress.
nonisolated enum AgentAutomaticWakePolicy {
    static func decision(
        pendingEvents: [AgentKernelEvent],
        hasHostCompletion: Bool,
        externalWakeHistory: [Date],
        now: Date
    ) -> AgentAutomaticWakeDecision? {
        let wakeable = pendingEvents.filter {
            $0.isPendingForModel && $0.interruptPolicy != .enqueue
        }
        let hasWakeableHostEvent = wakeable.contains {
            $0.trust == .host
                && $0.kind != .terminalCommandCompleted
                && $0.kind != .terminalExited
        }
        if hasHostCompletion || hasWakeableHostEvent {
            return AgentAutomaticWakeDecision(kind: .host, externalWakeHistory: externalWakeHistory)
        }
        guard wakeable.contains(where: { $0.trust == .authenticated }) else { return nil }
        let reservation = AgentExternalWakePolicy.reserve(history: externalWakeHistory, now: now)
        guard reservation.allowed else { return nil }
        return AgentAutomaticWakeDecision(
            kind: .authenticatedExternal,
            externalWakeHistory: reservation.history
        )
    }
}

extension AppState {
    func configureAgentRuntimeKernel() {
        runtimeKernelSubscription = agentRuntimeKernel.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        runtimeKernelSaveFailureSubscription = NotificationCenter.default
            .publisher(for: AgentKernelEventStore.saveDidFailNotification)
            .sink { [weak self] note in
                guard let self,
                      let runtimeID = note.object as? UUID,
                      let runtime = self.agentRuntimes[runtimeID],
                      runtime.errorMessage == nil else { return }
                runtime.errorMessage = L10n.RuntimeEvents.journalSaveFailed
            }
        agentTerminalController.onStateEvent = { [weak self] terminalEvent in
            self?.publishTerminalKernelEvent(terminalEvent)
        }
    }

    @discardableResult
    func receiveExternalAgentEvent(_ ingress: AgentExternalEventIngress) -> Bool {
        if let catalogSession = agentSessions.first(where: { $0.id == ingress.runtimeID }) {
            guard catalogSession.archivedAt == nil else { return false }
        } else {
            guard let runtime = agentRuntimes[ingress.runtimeID],
                  runtime.session.archivedAt == nil else { return false }
        }
        let published = publishAgentKernelEvent(ingress.kernelEvent())
        return agentRuntimeKernel.events.contains { $0.id == published.id }
    }

    @discardableResult
    func receiveCollaborationRelayEvent(_ relayEvent: CollaborationRelayIncomingEvent) -> UUID? {
        guard hasLoadedAgentSessionCatalog else { return nil }
        // The sidebar catalog is process-wide, but each editor window owns a
        // separate runtime object. Keep the dedicated orchestrator on one
        // live owner when focus moves between windows; otherwise two idle
        // copies of the same session could start concurrent provider turns.
        if let orchestratorID = AgentRuntimeEventSettingsStore.load().orchestratorSessionID,
           let owner = existingEventOrchestratorOwner(for: orchestratorID),
           owner !== self {
            return owner.receiveCollaborationRelayEvent(relayEvent)
        }
        guard let runtime = eventOrchestratorRuntime() else { return nil }
        let body: String = {
            guard let value = relayEvent.body,
                  let data = try? JSONEncoder().encode(value),
                  let string = String(data: data, encoding: .utf8) else { return "{}" }
            return string
        }()
        let normalizedKind = relayEvent.kind.lowercased()
        let requiresAction = normalizedKind.contains("message")
            || normalizedKind.contains("mention")
            || normalizedKind.contains("mail")
        let source: AgentKernelEventSource = normalizedKind.contains("mail")
            ? .email
            : (normalizedKind.contains("webhook") ? .webhook : .connector)
        guard receiveExternalAgentEvent(
            AgentExternalEventIngress(
                runtimeID: runtime.id,
                source: source,
                kind: relayEvent.kind,
                title: "\(relayEvent.platform): \(relayEvent.kind)",
                body: body,
                sender: relayEvent.platform,
                externalID: relayEvent.id,
                authenticated: relayEvent.authenticatedIngress,
                urgent: requiresAction,
                requiresUserAction: requiresAction
            )
        ) else { return nil }
        return runtime.id
    }

    private func existingEventOrchestratorOwner(for runtimeID: UUID) -> AppState? {
        let registry = EditorAppStateRegistry.shared
        let owners = registry.appStatesForTerminationCheck.filter {
            $0.agentRuntimes[runtimeID] != nil
        }.sorted {
            $0.agentRuntimeKernelOwnerID.uuidString < $1.agentRuntimeKernelOwnerID.uuidString
        }
        let busyOwners = owners.filter {
            guard let runtime = $0.agentRuntimes[runtimeID] else { return false }
            return runtime.isResponding
                || runtime.isAwaitingProviderSlot
                || runtime.isCompressingContext
                || runtime.requestTask != nil
        }
        return busyOwners.first(where: { $0 === registry.current })
            ?? busyOwners.first
            ?? owners.first(where: { $0 === registry.current })
            ?? owners.first
    }

    private func eventOrchestratorRuntime() -> AgentRuntime? {
        guard hasLoadedAgentSessionCatalog else { return nil }
        var settings = AgentRuntimeEventSettingsStore.load()
        if let sessionID = settings.orchestratorSessionID,
           agentSessions.contains(where: { $0.id == sessionID && $0.archivedAt == nil }),
           let existing = runtime(for: sessionID) {
            return existing
        }

        let session = startNewAgentSession(inWorkspaceAt: nil, makeActive: false)
        guard let runtime = agentRuntimes[session.id] else {
            return nil
        }
        runtime.session.title = L10n.RuntimeEvents.orchestratorTitle
        runtime.session.titleIsUserSet = true
        persistAgentSession(runtime: runtime, moveToFront: false)
        settings.orchestratorSessionID = session.id
        AgentRuntimeEventSettingsStore.save(settings)
        return runtime
    }

    func publishHostAgentEvent(
        runtimeID: UUID,
        kind: AgentKernelEventKind,
        title: String,
        payload: String,
        priority: AgentKernelEventPriority = .normal,
        interruptPolicy: AgentKernelInterruptPolicy = .yieldAtBoundary,
        audience: AgentKernelEventAudience = .both,
        contentProvenance: AgentKernelEventContentProvenance = .host,
        dedupeKey: String? = nil,
        requiresUserAction: Bool = false,
        metadata: [String: String] = [:]
    ) {
        publishAgentKernelEvent(
            AgentKernelEvent(
                runtimeID: runtimeID,
                source: .system,
                kind: kind,
                priority: priority,
                interruptPolicy: interruptPolicy,
                trust: .host,
                contentProvenance: contentProvenance,
                audience: audience,
                title: title,
                payload: payload,
                metadata: metadata,
                dedupeKey: dedupeKey,
                requiresUserAction: requiresUserAction
            )
        )
    }

    func resumePersistedAgentKernelEvents() {
        for runtimeID in agentRuntimeKernel.pendingRuntimeIDs() {
            guard agentSessions.first(where: { $0.id == runtimeID })?.archivedAt == nil,
                  let runtime = runtime(for: runtimeID) else { continue }
            // The same persisted catalog can be visible in several windows,
            // but one event may start only one provider turn. Let the registry
            // choose the process-local owner for this session.
            if let owner = EditorAppStateRegistry.shared.appState(containingSession: runtimeID),
               owner !== self {
                continue
            }
            schedulePendingAgentKernelEvents(for: runtime)
        }
    }

    func schedulePendingAgentKernelEvents(for runtime: AgentRuntime) {
        guard agentRuntimeKernel.pendingModelEventCount(for: runtime.id) > 0 else { return }
        let probe = agentRuntimeKernel.events
            .filter { $0.runtimeID == runtime.id && $0.isPendingForModel }
            .max { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.updatedAt < rhs.updatedAt
            }
        if let probe { scheduleAgentKernelEvent(probe) }
    }

    @discardableResult
    func publishBackgroundJobKernelEvent(_ job: AgentBackgroundJob, runtime: AgentRuntime,
        requiresDurableHandoff: Bool = false) -> Bool {
        let recentOutput: String? = {
            guard job.needsAttention, job.outputByteCount > 0 else { return nil }
            let tail = agentJobRegistry.output(id: job.id, tailLines: 40)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tail.isEmpty else { return nil }
            let scrubbed = AgentSandboxPolicy.scrub(tail)
            return scrubbed.count > 4_000 ? "…" + String(scrubbed.suffix(4_000)) : scrubbed
        }()
        let failed = job.needsAttention
        let event = AgentKernelEvent(
                runtimeID: runtime.id,
                source: .backgroundJob,
                kind: failed ? .backgroundJobFailed : .backgroundJobCompleted,
                priority: failed ? .urgent : .normal,
                interruptPolicy: .yieldAtBoundary,
                trust: .host,
                contentProvenance: .tool,
                audience: .both,
                title: job.command,
                payload: Self.backgroundJobCompletionNotice(for: job, recentOutput: recentOutput),
                metadata: ["resource_id": job.id.uuidString, "handle": job.displayHandle],
                dedupeKey: "background-job:\(job.id.uuidString)",
                dedupeScope: .journal,
                requiresUserAction: false
            )
        if requiresDurableHandoff {
            let published = agentRuntimeKernel.publish(event)
            guard agentRuntimeKernel.confirmEventPersistenceForHandoff(published) else { return false }
            // The producer ACK must succeed before this handoff schedules a
            // model. Its caller also retries pending (not handled) events.
        } else {
            publishAgentKernelEvent(event)
        }
        return true
    }

    func publishMediaTaskKernelEvent(_ task: AgentMediaTask, runtime: AgentRuntime) {
        let failed = task.status != .succeeded
        publishAgentKernelEvent(
            AgentKernelEvent(
                runtimeID: runtime.id,
                source: .mediaTask,
                kind: failed ? .mediaTaskFailed : .mediaTaskCompleted,
                priority: failed ? .urgent : .normal,
                interruptPolicy: .yieldAtBoundary,
                trust: .host,
                contentProvenance: .tool,
                audience: .both,
                title: task.title,
                payload: Self.mediaTaskCompletionNotice(for: task),
                metadata: ["resource_id": task.id.uuidString, "handle": task.displayHandle],
                dedupeKey: "media-task:\(task.id.uuidString)",
                requiresUserAction: false
            )
        )
    }

    func publishSubagentKernelEvent(_ run: AgentSubagentRun, runtime: AgentRuntime) {
        let failed = run.status != .completed
        publishAgentKernelEvent(
            AgentKernelEvent(
                runtimeID: runtime.id,
                source: .worker,
                kind: failed ? .workerFailed : .workerCompleted,
                priority: failed ? .urgent : .normal,
                interruptPolicy: .yieldAtBoundary,
                trust: .host,
                contentProvenance: .model,
                audience: .both,
                title: run.label,
                payload: Self.subagentReportNotice(for: run),
                metadata: ["resource_id": run.id.uuidString, "handle": run.displayHandle],
                dedupeKey: "worker:\(run.id.uuidString)",
                requiresUserAction: false
            )
        )
    }

    func publishWorkflowKernelEvent(_ report: WorkflowReport, runtime: AgentRuntime) {
        let failed = report.status == .failed || report.status == .cancelled
        publishAgentKernelEvent(
            AgentKernelEvent(
                runtimeID: runtime.id,
                source: .workflow,
                kind: .workflowCompleted,
                priority: failed ? .urgent : .normal,
                interruptPolicy: .yieldAtBoundary,
                trust: .host,
                contentProvenance: .tool,
                audience: .both,
                title: report.displayTitle,
                payload: Self.workflowCompletionNotice(for: report),
                metadata: ["resource_id": report.id.uuidString, "status": report.status.rawValue],
                dedupeKey: "workflow:\(report.id.uuidString)",
                requiresUserAction: false
            )
        )
    }

    func publishTerminalKernelEvent(_ terminalEvent: AgentTerminalStateEvent) {
        guard let runtimeID = terminalEvent.runtimeID,
              agentSessions.first(where: { $0.id == runtimeID })?.archivedAt == nil,
              runtime(for: runtimeID) != nil else { return }
        let kind: AgentKernelEventKind
        let priority: AgentKernelEventPriority
        switch terminalEvent.transition {
        case .commandCompleted:
            kind = .terminalCommandCompleted
            priority = .normal
        case .exited:
            kind = .terminalExited
            priority = .urgent
        }
        publishAgentKernelEvent(
            AgentKernelEvent(
                runtimeID: runtimeID,
                source: .terminal,
                kind: kind,
                priority: priority,
                interruptPolicy: .yieldAtBoundary,
                trust: .host,
                contentProvenance: .tool,
                audience: .both,
                title: terminalEvent.title,
                payload: terminalEvent.summary,
                metadata: ["resource_id": terminalEvent.tabID.uuidString],
                dedupeKey: "terminal:\(terminalEvent.tabID.uuidString):\(terminalEvent.transition.rawValue)",
                requiresUserAction: false
            )
        )
    }

    /// Project every user-blocking decision into the kernel's user interrupt
    /// lane. Tool calls remain the source of truth for approve/deny actions;
    /// these events provide persistence, Event Center visibility, and one
    /// common signal shape without duplicating the actual decision state.
    func synchronizeApprovalKernelEvents(for runtime: AgentRuntime) {
        var activeKeys: Set<String> = []
        for call in runtime.toolCalls where call.status.isBlockingForUserDecision {
            let key = "approval:tool:\(call.id.uuidString)"
            activeKeys.insert(key)
            guard !agentRuntimeKernel.hasPendingEvent(runtimeID: runtime.id, dedupeKey: key) else { continue }
            publishAgentKernelEvent(
                AgentKernelEvent(
                    runtimeID: runtime.id,
                    source: .approval,
                    kind: .approvalRequired,
                    priority: .urgent,
                    interruptPolicy: .enqueue,
                    trust: .host,
                    contentProvenance: .host,
                    audience: .user,
                    title: call.toolName,
                    payload: "A tool decision is waiting for the operator.",
                    metadata: ["resource_id": call.id.uuidString, "approval_kind": "tool"],
                    dedupeKey: key,
                    requiresUserAction: true
                )
            )
        }
        for patch in runtime.patchProposals where patch.status == .pending {
            let key = "approval:patch:\(patch.id.uuidString)"
            activeKeys.insert(key)
            guard !agentRuntimeKernel.hasPendingEvent(runtimeID: runtime.id, dedupeKey: key) else { continue }
            publishAgentKernelEvent(
                AgentKernelEvent(
                    runtimeID: runtime.id,
                    source: .approval,
                    kind: .approvalRequired,
                    priority: .urgent,
                    interruptPolicy: .enqueue,
                    trust: .host,
                    contentProvenance: .host,
                    audience: .user,
                    title: patch.title,
                    payload: "A patch decision is waiting for the operator.",
                    metadata: ["resource_id": patch.id.uuidString, "approval_kind": "patch"],
                    dedupeKey: key,
                    requiresUserAction: true
                )
            )
        }
        if runtime.currentPlan?.status == .proposed {
            let key = "approval:plan:\(runtime.id.uuidString)"
            activeKeys.insert(key)
            if !agentRuntimeKernel.hasPendingEvent(runtimeID: runtime.id, dedupeKey: key) {
                publishAgentKernelEvent(
                    AgentKernelEvent(
                        runtimeID: runtime.id,
                        source: .approval,
                        kind: .approvalRequired,
                        priority: .urgent,
                        interruptPolicy: .enqueue,
                        trust: .host,
                        contentProvenance: .host,
                        audience: .user,
                        title: L10n.RuntimeEvents.planReview,
                        payload: "A proposed plan is waiting for the operator.",
                        metadata: ["resource_id": runtime.id.uuidString, "approval_kind": "plan"],
                        dedupeKey: key,
                        requiresUserAction: true
                    )
                )
            }
        }
        agentRuntimeKernel.dismissPendingEvents(
            runtimeID: runtime.id,
            source: .approval,
            keepingDedupeKeys: activeKeys
        )
    }

    @discardableResult
    func publishAgentKernelEvent(_ event: AgentKernelEvent) -> AgentKernelEvent {
        let published = agentRuntimeKernel.publish(event)
        // Journal-scoped duplicates return the existing event. Scheduling it
        // again would turn an at-least-once relay retry into another model run.
        guard published.id == event.id,
              agentRuntimeKernel.events.contains(where: { $0.id == published.id }) else { return published }
        scheduleAgentKernelEvent(published)
        return published
    }

    private func scheduleAgentKernelEvent(_ event: AgentKernelEvent) {
        guard ownsAgentRuntimeKernelDelivery(for: event.runtimeID) else { return }
        guard let runtime = runtime(for: event.runtimeID), runtime.session.archivedAt == nil else { return }
        let snapshot = AgentKernelRuntimeSnapshot(
            isResponding: runtime.isResponding,
            isAwaitingProviderSlot: runtime.isAwaitingProviderSlot,
            isCompressingContext: runtime.isCompressingContext,
            hasRequestTask: runtime.requestTask != nil
        )
        switch AgentInterruptScheduler.disposition(for: event, runtime: snapshot) {
        case .queued, .yieldAfterCurrentStep:
            break
        case .wakeIdleRuntime:
            resumeAgentLoopForPendingBackgroundCompletions(for: runtime)
        case .preemptCurrentStep:
            agentKernelPreemptedRuntimeIDs.insert(runtime.id)
            runtime.requestTask?.cancel()
        }
    }

    func ownsAgentRuntimeKernelDelivery(for runtimeID: UUID) -> Bool {
        let registry = EditorAppStateRegistry.shared
        let owners = registry.appStatesForTerminationCheck.filter {
            $0.loadedRuntime(for: runtimeID) != nil
        }.sorted {
            $0.agentRuntimeKernelOwnerID.uuidString < $1.agentRuntimeKernelOwnerID.uuidString
        }
        guard !owners.isEmpty else { return true }
        let busyOwners = owners.filter {
            guard let runtime = $0.loadedRuntime(for: runtimeID) else { return false }
            return runtime.isResponding
                || runtime.isAwaitingProviderSlot
                || runtime.isCompressingContext
                || runtime.requestTask != nil
        }
        let owner = busyOwners.first(where: { $0 === registry.current })
            ?? busyOwners.first
            ?? owners.first { $0 === registry.current && $0.activeAgentSessionID == runtimeID }
            ?? owners.first { $0.activeAgentSessionID == runtimeID }
            ?? owners.first(where: { $0 === registry.current })
            ?? owners[0]
        return owner === self
    }

}
