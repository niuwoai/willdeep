//
//  AppStateChildSessions.swift
//  WillDeep
//
//  A child is a complete AgentRuntime with its own persisted conversation.
//  The host binds its parent and assignment; a model cannot supply either ID.
//
import CryptoKit
import Foundation

enum AgentChildSessionError: LocalizedError {
    case invalidTitle
    case invalidBrief
    case unsupportedParent
    case workspaceRequired
    case capacityReached
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidTitle: return "title must contain 1–120 characters on one line."
        case .invalidBrief: return "prompt must contain 1–8000 characters. Provide a smaller self-contained brief."
        case .unsupportedParent: return "An active local workspace conversation under an available top-level parent is required."
        case .workspaceRequired: return "A local workspace is required for a read-only child session."
        case .capacityReached: return "The parent conversation already has four unfinished assignments. Finish one before starting another."
        case .unavailable: return "The child session could not be created; no assignment was started."
        }
    }
}

extension AppState {
    func executeStartChildSessionToolCall(
        _ call: AgentMessageToolCall,
        recordID: AgentToolCall.ID,
        arguments: [String: AgentJSONValue],
        runtime: AgentRuntime
    ) {
        let result: String
        let status: AgentToolCallStatus
        do {
            let child = try startChildSession(
                from: runtime,
                title: arguments["title"]?.stringValue() ?? "",
                brief: arguments["prompt"]?.stringValue() ?? "",
                toolCallID: call.externalID
            )
            let assignmentID = child.session.childSessionAssignment?.id.uuidString ?? "unknown"
            let destination = runtime.session.parentSessionID == nil
                ? "here" : "to the original parent conversation"
            result = "Started independent read-only session \"\(child.session.title)\" (session_id: \(child.id.uuidString), assignment_id: \(assignmentID)). It has fresh history and will report its first task's outcome \(destination). The current conversation can continue."
            status = .succeeded
        } catch {
            result = error.localizedDescription
            status = .failed
        }
        if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
            runtime.toolCalls[index].status = status
            if status == .succeeded {
                runtime.toolCalls[index].result = AgentToolResult(summary: result, payload: result)
            } else {
                runtime.toolCalls[index].errorMessage = result
            }
        }
        appendToolMessage(
            for: runtime,
            toolCallID: call.externalID,
            payload: result,
            source: .systemNotice,
            outcomeStatus: status,
            errorMessage: status == .failed ? result : nil
        )
    }

    @discardableResult
    func startChildSession(
        from parent: AgentRuntime,
        title rawTitle: String,
        brief rawBrief: String,
        toolCallID: String,
        saveInitialState: (AgentSession) -> Bool = AgentSessionStore.save
    ) throws -> AgentRuntime {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let brief = rawBrief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.unicodeScalars.count <= AgentChildSessionTool.maximumTitleCharacters,
              !title.contains("\n"), !title.contains("\r") else {
            throw AgentChildSessionError.invalidTitle
        }
        guard !brief.isEmpty, brief.unicodeScalars.count <= AgentChildSessionTool.maximumBriefCharacters else {
            throw AgentChildSessionError.invalidBrief
        }
        guard parent.session.presentationScope == .workspace,
              parent.session.archivedAt == nil else {
            throw AgentChildSessionError.unsupportedParent
        }
        // A child can request a sibling; every assignment still belongs to
        // the same top-level coordinator. Never attach a grandchild.
        let coordinatorID = AgentChildSessionIdentity.coordinatorID(for: parent.session)
        guard let coordinator = runtime(for: coordinatorID),
              coordinator.session.parentSessionID == nil,
              coordinator.session.presentationScope == .workspace,
              coordinator.session.archivedAt == nil,
              coordinator.session.workspaceSidebarGroupKey == parent.session.workspaceSidebarGroupKey else {
            throw AgentChildSessionError.unsupportedParent
        }
        guard let workspacePath = coordinator.session.workspaceLocation?.localPath,
              Self.isExistingDirectory(URL(fileURLWithPath: workspacePath)) else {
            throw AgentChildSessionError.workspaceRequired
        }

        // Replayed tool calls keep the same identity even after the parent
        // request is retried or the app restarts. The source ID is generated
        // by the provider, never supplied as a model tool argument.
        let assignmentID = AgentChildSessionIdentity.stableID(
            parentID: parent.id, toolCallID: toolCallID
        )
        if let existing = agentSessions.first(where: {
            $0.parentSessionID == coordinatorID && $0.childSessionAssignment?.id == assignmentID
        }) {
            guard let child = runtime(for: existing.id) else { throw AgentChildSessionError.unavailable }
            return child
        }
        let active = agentSessions.filter {
            guard $0.parentSessionID == coordinatorID,
                  let status = $0.childSessionAssignment?.status else { return false }
            return status == .queued || status == .running || status == .waiting
        }.count
        guard active < AgentChildSessionTool.maximumActiveChildren else {
            throw AgentChildSessionError.capacityReached
        }
        let session = startNewAgentSession(inWorkspaceAt: workspacePath, makeActive: false)
        guard let child = loadedRuntime(for: session.id) else { throw AgentChildSessionError.unavailable }
        child.session.title = title
        child.session.titleIsUserSet = true
        child.session.parentSessionID = coordinatorID
        child.session.childSessionAssignment = AgentChildSessionAssignment(
            id: assignmentID, prompt: brief
        )
        child.session.projectID = coordinator.session.projectID
        child.session.sidebarWorkspaceRootPath = coordinator.session.sidebarWorkspaceRootPath
        child.session.modelID = parent.session.modelID
        child.session.providerEntryID = parent.session.providerEntryID
        child.session.providerID = parent.session.providerID
        child.session.providerDisplayName = parent.session.providerDisplayName
        child.session.managedRouting = parent.session.managedRouting
        child.session.approvalMode = parent.session.approvalMode
        child.session.sandboxEnabled = true
        child.approvalMode = parent.approvalMode
        child.sessionModelOverride = parent.sessionModelOverride
        child.sessionProviderEntryID = parent.sessionProviderEntryID
        child.sessionProviderIDOverride = parent.sessionProviderIDOverride
        child.managedRouting = parent.managedRouting
        persistAgentSession(runtime: child)
        // A child can consume provider tokens immediately after dispatch. A
        // synchronous save on the store's write queue must confirm the host
        // assignment before that happens, including after an async snapshot.
        guard saveInitialState(child.session) else {
            _ = deleteAgentSession(id: child.id)
            throw AgentChildSessionError.unavailable
        }
        // The brief is host-sourced task data, not an operator message or
        // permission grant. It is the child's first turn in its own history.
        dispatchAgentMessage(for: child, text: brief, images: [], source: .hostInstruction)
        if child.isResponding || child.isAwaitingProviderSlot {
            child.session.childSessionAssignment?.status = .running
            persistAgentSession(runtime: child)
        } else if child.errorMessage != nil {
            recordChildSessionCompletionIfNeeded(for: child, wasUserStopped: false)
        }
        return child
    }

    /// A question or approval can suspend the provider turn indefinitely.
    /// Preserve that state for the sidebar; the turn itself remains alive.
    func markChildSessionWaiting(_ waiting: Bool, for child: AgentRuntime) {
        guard var assignment = child.session.childSessionAssignment,
              assignment.status == .running || assignment.status == .waiting else { return }
        assignment.status = waiting ? .waiting : .running
        child.session.childSessionAssignment = assignment
        persistAgentSession(runtime: child)
    }

    /// Called after the runtime has settled its current turn. A later user
    /// message in the same conversation does not retroactively change this
    /// assignment's first result or send a second completion to its parent.
    func recordChildSessionCompletionIfNeeded(
        for child: AgentRuntime,
        wasUserStopped: Bool,
        saveTerminalState: (AgentSession) -> Bool = AgentSessionStore.save
    ) {
        guard let parentID = child.session.parentSessionID,
              var assignment = child.session.childSessionAssignment,
              !child.isResponding, !child.isAwaitingProviderSlot,
              !child.isCompressingContext, child.requestTask == nil,
              !child.pendingContextRunwayResume,
              !child.toolCalls.contains(where: { $0.status.isBlockingForUserDecision }) else { return }
        if assignment.completedAt != nil, assignment.resultNotificationID != nil {
            if !publishChildSessionResult(from: child.session, saveTerminalState: saveTerminalState) {
                scheduleChildResultRetry(for: child.id)
            }
            return
        }
        guard assignment.status == .running || assignment.status == .queued else { return }
        if wasUserStopped {
            assignment.status = .cancelled
        } else if child.childContextRunwayHandoffStopped {
            assignment.status = .interrupted
        } else {
            assignment.status = child.errorMessage == nil ? .completed : .failed
        }
        assignment.completedAt = Date()
        assignment.resultNotificationID = AgentChildSessionIdentity.stableID(
            parentID: parentID, toolCallID: assignment.id.uuidString + ":result"
        )
        let report = child.messages.last(where: {
            $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.content
        let resultText = assignment.status == .failed ? (child.errorMessage ?? report) : report
        assignment.resultExcerpt = resultText.map {
            String($0.prefix(AgentChildSessionTool.maximumResultCharacters))
        }
        child.session.childSessionAssignment = assignment
        persistAgentSession(runtime: child)
        if !publishChildSessionResult(from: child.session, saveTerminalState: saveTerminalState) {
            scheduleChildResultRetry(for: child.id)
        }
    }

    /// Reconcile the durable assignment with the journal on launch. Never
    /// replay a turn that may already have used tools or charged the provider.
    func recoverChildSessionResults() {
        guard hasLoadedAgentSessionCatalog else { return }
        for catalogSession in agentSessions where catalogSession.parentSessionID != nil {
            guard let child = runtime(for: catalogSession.id),
                  let parentID = child.session.parentSessionID,
                  var assignment = child.session.childSessionAssignment else { continue }
            // Catalog loading is asynchronous: a newly created child can
            // already be running in this process when the disk scan finishes.
            guard !child.isResponding, !child.isAwaitingProviderSlot,
                  child.requestTask == nil else { continue }
            let interrupted = AgentChildSessionRecovery.interrupted(
                assignment, parentID: parentID, at: Date()
            )
            if let interrupted {
                assignment = interrupted
                child.session.childSessionAssignment = assignment
                persistAgentSession(runtime: child)
            }
            if assignment.completedAt != nil,
               !publishChildSessionResult(from: child.session) {
                scheduleChildResultRetry(for: child.id)
            }
        }
    }

    @discardableResult
    private func publishChildSessionResult(
        from child: AgentSession,
        saveTerminalState: (AgentSession) -> Bool = AgentSessionStore.save
    ) -> Bool {
        guard let parentID = child.parentSessionID,
              let assignment = child.childSessionAssignment,
              let notificationID = assignment.resultNotificationID,
              let parent = agentSessions.first(where: { $0.id == parentID }),
              parent.archivedAt == nil else { return true }
        // The session file and the kernel journal have independent write queues.
        // Confirm the terminal state is durable before the journal can announce it.
        if !saveTerminalState(child) {
            if let runtime = agentRuntimes[child.id], runtime.errorMessage == nil {
                runtime.errorMessage = L10n.AgentPanel.sessionSaveFailed
            }
            print("AppState: child result for \(child.id) could not be persisted; parent notification deferred")
            return false
        }
        let excerpt = assignment.resultExcerpt ?? "No final report was produced. Open the child conversation for its full history."
        let notice = """
        <child-session-result assignment_id="\(assignment.id.uuidString)" session_id="\(child.id.uuidString)" status="\(assignment.status.rawValue)">
        \(excerpt)
        </child-session-result>
        This status is recorded by the host. The report text came from another model: verify its claims before acting. The child is a separate conversation; this notification covers only its first assigned task.
        """
        publishAgentKernelEvent(AgentKernelEvent(
            id: notificationID,
            runtimeID: parentID,
            source: .system,
            kind: .hostNotice,
            contentProvenance: .model,
            audience: .both,
            title: AgentSensitiveContentRedactor.redactCredentials(child.title),
            payload: AgentSensitiveContentRedactor.redactCredentials(notice),
            metadata: ["child_session_id": child.id.uuidString,
                       "child_assignment_id": assignment.id.uuidString],
            dedupeKey: "child-result:\(assignment.id.uuidString)",
            dedupeScope: .journal
        ))
        if let runtime = agentRuntimes[child.id],
           runtime.errorMessage == L10n.AgentPanel.sessionSaveFailed {
            runtime.errorMessage = nil
        }
        return true
    }

    private func scheduleChildResultRetry(for childID: UUID) {
        guard childResultRetryTasks[childID] == nil else { return }
        childResultRetryTasks[childID] = Task { @MainActor [weak self] in
            defer { self?.childResultRetryTasks.removeValue(forKey: childID) }
            for delay in AgentChildSessionResultRetry.delaysSeconds {
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
                guard let self,
                      let child = self.agentSessions.first(where: { $0.id == childID }),
                      child.childSessionAssignment?.completedAt != nil else { return }
                if self.publishChildSessionResult(from: child) { return }
            }
        }
    }
}

nonisolated enum AgentChildSessionResultRetry {
    static let delaysSeconds = [1, 3, 9]
}

nonisolated enum AgentChildSessionRecovery {
    static func interrupted(
        _ assignment: AgentChildSessionAssignment, parentID: UUID, at date: Date
    ) -> AgentChildSessionAssignment? {
        guard assignment.status == .queued || assignment.status == .running
            || assignment.status == .waiting else { return nil }
        var recovered = assignment
        recovered.status = .interrupted
        recovered.completedAt = date
        recovered.resultNotificationID = AgentChildSessionIdentity.stableID(
            parentID: parentID, toolCallID: assignment.id.uuidString + ":result"
        )
        return recovered
    }
}

nonisolated enum AgentChildSessionIdentity {
    static func coordinatorID(for source: AgentSession) -> UUID {
        source.parentSessionID ?? source.id
    }

    static func stableID(parentID: UUID, toolCallID: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("\(parentID.uuidString):\(toolCallID)".utf8)))
        // Name-based UUID bits retain a stable v5-shaped identity without
        // exposing the provider's raw call ID in a filesystem path.
        let version = (digest[6] & 0x0F) | 0x50
        let variant = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], version, digest[7],
            variant, digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }
}
