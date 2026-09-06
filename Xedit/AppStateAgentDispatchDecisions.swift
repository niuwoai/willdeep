import Foundation

extension AppState {
    func hasPendingDispatchDecisions(_ runtime: AgentRuntime) -> Bool {
        guard let goalID = runtime.session.dispatchParentProjectID,
              let taskID = runtime.session.dispatchTaskID else { return false }
        return agentDispatchCoordinator.goals.first(where: { $0.id == goalID })?
            .tasks.first(where: { $0.id == taskID && $0.runtimeSessionID == runtime.id })?
            .pendingDecisionIDs?.isEmpty == false
    }

    /// Late host wakeups cannot undo a pending decision or an operator Stop.
    func dispatchContinuationIsSuspended(_ runtime: AgentRuntime) -> Bool {
        if runtime.currentGoal?.continuationBudget?.modelAdmissionPaused == true { return true }
        guard let goalID = runtime.session.dispatchParentProjectID,
              let taskID = runtime.session.dispatchTaskID,
              let goal = agentDispatchCoordinator.goals.first(where: { $0.id == goalID }),
              let task = goal.tasks.first(where: { $0.id == taskID && $0.runtimeSessionID == runtime.id }) else { return false }
        return goal.isPaused || task.state == .cancelled || task.pendingDecisionIDs?.isEmpty == false
    }

    /// Intercept the complete batch BEFORE any side effects. Every provider
    /// call still receives a protocol result, including deferred sibling calls.
    func captureDispatchDecisions(runtime: AgentRuntime, messageID: UUID, calls: [AgentMessageToolCall]) -> Bool {
        guard runtime.isUnattendedDispatchTask, runtime.executionAgent == .willDeep, !Task.isCancelled,
              let goalID = runtime.session.dispatchParentProjectID,
              let taskID = runtime.session.dispatchTaskID,
              let workspace = runtime.workspaceLocation ?? runtime.workspaceRootPath.map({ WorkspaceLocation.local(path: $0) }) else { return false }
        var captured: [String: UUID] = [:]
        for call in calls where call.toolName == "ask_user" {
            guard case .object(let arguments) = AgentJSONValue.decode(from: call.argumentsJSON),
                  AgentToolRegistry.argumentValidationError(for: "ask_user", arguments: arguments) == nil,
                  let question = AgentDispatchDecision.Question(arguments: arguments),
                  let id = agentDispatchCoordinator.recordDecision(goalID: goalID, taskID: taskID, runtimeID: runtime.id,
                      externalCallID: call.externalID, workspace: workspace,
                      runtimeGoalDigest: runtime.currentGoal.map(AgentGoalVerification.contractDigest), question: question) else { continue }
            captured[call.externalID] = id
        }
        guard !captured.isEmpty else { return false }
        runtime.pendingContextRunwayResume = false
        for call in calls {
            let arguments: [String: AgentJSONValue]
            if case .object(let values) = AgentJSONValue.decode(from: call.argumentsJSON) { arguments = values }
            else { arguments = [:] }
            let id = captured[call.externalID]
            let payload = id.map {
                "Decision request \($0.uuidString) is persisted on the project board. No answer or permission has been granted. This task is suspended until the operator answers; do not poll or retry."
            } ?? "Deferred without execution because this batch requires a project decision. Reissue only the still-needed call after the answer."
            let status: AgentToolCallStatus = id == nil ? .denied : .succeeded
            runtime.toolCalls.append(.init(messageID: messageID, externalID: call.externalID, toolName: call.toolName,
                arguments: arguments, risk: id == nil ? .write : .userInput, status: status,
                result: .init(summary: L10n.DispatchDecision.waiting, payload: payload)))
            appendToolMessage(for: runtime, toolCallID: call.externalID, payload: payload,
                              source: .systemNotice, outcomeStatus: status)
        }
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
        return true
    }

    func answerDispatchDecision(goalID: UUID, decisionID: UUID, answer: String) {
        guard agentDispatchCoordinator.answerDecision(goalID: goalID, decisionID: decisionID, answer: answer) else { return }
        resumeAnsweredDispatchDecisions(goalID: goalID)
    }

    func resumeAnsweredDispatchDecisions(goalID: UUID) {
        guard let goal = agentDispatchCoordinator.goals.first(where: { $0.id == goalID }), !goal.isPaused else { return }
        for task in goal.tasks where task.pendingDecisionIDs?.isEmpty == false {
            guard let runtimeID = task.runtimeSessionID, let runtime = runtime(for: runtimeID) else { continue }
            _ = resumeAnsweredDispatchDecision(runtime: runtime, goalID: goalID, taskID: task.id)
        }
    }

    /// Coalesce lifecycle notifications, never poll. Deferring also lets
    /// @Published's willSet finish before reading reservations and answers.
    func scheduleDispatchDecisionResumption() {
        guard dispatchDecisionResumptionTask == nil,
              agentDispatchCoordinator.goals.contains(where: { goal in
                  !goal.isPaused && goal.tasks.contains {
                      $0.pendingDecisionIDs?.isEmpty == false || $0.pendingOutcomeRevision == true
                  }
              }) else { return }
        dispatchDecisionResumptionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            defer { self.dispatchDecisionResumptionTask = nil }
            for goal in self.agentDispatchCoordinator.goals where !goal.isPaused {
                self.resumeAnsweredDispatchDecisions(goalID: goal.id)
                self.resumePendingOutcomeRevisions(goalID: goal.id)
            }
        }
    }

    /// Reuses the same execution runtime and its artifacts/budget. Stable
    /// participant IDs make replayed answers idempotent in the transcript.
    @discardableResult
    func prepareAnsweredDispatchDecision(runtime: AgentRuntime, goalID: UUID, taskID: UUID, includingResumed: Bool = false) -> AgentMessage? {
        guard !Task.isCancelled, runtime.executionAgent == .willDeep,
              !runtime.isResponding, !runtime.isAwaitingProviderSlot, !runtime.isCompressingContext,
              !runtime.queuedMessages.contains(where: { $0.source == .operatorInput }),
              runtime.session.dispatchParentProjectID == goalID, runtime.session.dispatchTaskID == taskID,
              runtime.currentPlan?.isInterrupted != true,
              let decisions = agentDispatchCoordinator.answeredDecisions(goalID: goalID, taskID: taskID,
                  runtimeID: runtime.id, includingResumed: includingResumed) else { return nil }
        do { try toolExecutionBudget(for: runtime)?.check() } catch { return nil }
        let workspace = runtime.workspaceLocation ?? runtime.workspaceRootPath.map { WorkspaceLocation.local(path: $0) }
        guard decisions.allSatisfy({ $0.participants.contains {
            $0.taskID == taskID && $0.runtimeID == runtime.id && $0.workspace == workspace
                && $0.runtimeGoalDigest == runtime.currentGoal.map(AgentGoalVerification.contractDigest)
        } }) else { return nil }
        var last: AgentMessage?
        for decision in decisions {
            guard let participant = decision.participants.first(where: { $0.taskID == taskID && $0.runtimeID == runtime.id }),
                  let answer = decision.answer else { return nil }
            struct Response: Encodable { let question: AgentDispatchDecision.Question; let answer: String }
            let body = Response(question: decision.question, answer: answer)
            guard let data = try? JSONEncoder().encode(body) else { return nil }
            let message = AgentMessage(id: participant.id, role: .user,
                content: "The operator answered this persisted project question. Continue only the remaining work under the existing task contract and permissions; this answer does not grant new tool permissions.\n" + String(decoding: data, as: UTF8.self),
                source: .hostInstruction)
            if !runtime.messages.contains(where: { $0.id == participant.id }) { runtime.messages.append(message) }
            last = message
        }
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
        return last
    }

    @discardableResult
    func resumeAnsweredDispatchDecision(runtime: AgentRuntime, goalID: UUID, taskID: UUID) -> Bool {
        guard dispatchAdmissionIsAvailable(goalID: goalID, taskID: taskID, continuingRuntimeID: runtime.id),
              let message = prepareAnsweredDispatchDecision(runtime: runtime, goalID: goalID, taskID: taskID),
              agentDispatchCoordinator.resumeAnsweredTask(goalID: goalID, taskID: taskID, runtimeID: runtime.id) else { return false }
        dispatchAgentMessage(for: runtime, text: message.content, images: [], existingUserMessageID: message.id, source: .hostInstruction)
        monitorDispatchTaskRuntime(runtime, goalID: goalID, taskID: taskID, allowsAutomaticRecovery: true)
        return true
    }

    func recordUnattendedInputDenial(_ call: AgentMessageToolCall, messageID: UUID,
                                    arguments: [String: AgentJSONValue], risk: AgentToolRisk, runtime: AgentRuntime) {
        var record = AgentToolCall(messageID: messageID, externalID: call.externalID, toolName: call.toolName,
            arguments: arguments, risk: risk, status: .denied)
        record.errorMessage = "Unavailable in unattended dispatch task"
        runtime.toolCalls.append(record)
        appendToolMessage(for: runtime, toolCallID: call.externalID,
            payload: "Unavailable in unattended dispatch task: use a bounded, self-contained ask_user question for genuinely missing information; do not request confirmation of routine authorized work.",
            source: .systemNotice, outcomeStatus: .denied, errorMessage: record.errorMessage)
    }
}
