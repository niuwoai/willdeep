import Foundation

extension AgentDispatchCoordinator {
    /// Only explicit project-scoped, fully identical questions may coalesce
    /// across nodes. Task-scoped questions include their locked contract.
    @discardableResult
    func recordDecision(goalID: UUID, taskID: UUID, runtimeID: UUID, externalCallID: String,
                        workspace: WorkspaceLocation, runtimeGoalDigest: String? = nil, question: AgentDispatchDecision.Question) -> UUID? {
        guard let goal = goals.first(where: { $0.id == goalID }), !goal.isPaused,
              let task = goal.tasks.first(where: { $0.id == taskID }), task.runtimeSessionID == runtimeID,
              [.running, .reviewing, .blocked].contains(task.state),
              let contract = try? AgentDispatchDecision.contractDigest(goal: goal, task: task),
              let questionDigest = try? AgentGoalTaskAuthorization.digest(question),
              let key = try? AgentGoalTaskAuthorization.digest([goalID.uuidString, goal.statement,
                  goal.resolvedWorkspaceBinding(for: task)?.id ?? "unbound", questionDigest,
                  question.scope == .task ? contract : "project"]) else { return nil }
        if let existing = goal.decisions?.first(where: { decision in
            decision.participants.contains { $0.runtimeID == runtimeID && $0.externalCallID == externalCallID && $0.contractDigest == contract }
        }) { return existing.id }
        let matching = goal.decisions?.first { $0.answer == nil && $0.deduplicationKey == key }
        guard matching != nil || goal.pendingDecisions.count < 32 else { return nil }
        let id = matching?.id ?? UUID()
        updateGoal(id: goalID) { goal in
            var decisions = goal.decisions ?? []
            let participant = AgentDispatchDecision.Participant(id: UUID(), taskID: taskID, runtimeID: runtimeID,
                externalCallID: externalCallID, contractDigest: contract, workspace: workspace, runtimeGoalDigest: runtimeGoalDigest)
            if let index = decisions.firstIndex(where: { $0.id == id }) {
                decisions[index].participants.append(participant)
            } else {
                decisions.append(.init(id: id, deduplicationKey: key, question: question,
                    participants: [participant], createdAt: Date()))
            }
            goal.decisions = decisions
            guard let index = goal.tasks.firstIndex(where: { $0.id == taskID }) else { return }
            var pending = goal.tasks[index].pendingDecisionIDs ?? []
            if !pending.contains(id) { pending.append(id) }
            goal.tasks[index].pendingDecisionIDs = pending
            goal.tasks[index].state = .blocked
            goal.updatedAt = Date()
        }
        return id
    }

    /// One immutable response. An old view cannot replace an answer or resume
    /// a stopped/replaced executor. No approval source is produced here.
    @discardableResult
    func answerDecision(goalID: UUID, decisionID: UUID, answer: String) -> Bool {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, answer.count <= 8_000,
              let goal = goals.first(where: { $0.id == goalID }),
              let decision = goal.decisions?.first(where: { $0.id == decisionID }), decision.answer == nil,
              goal.tasks.contains(where: {
                  $0.state == .blocked && ($0.pendingDecisionIDs ?? []).contains(decisionID) && decision.applies(to: $0, in: goal)
              }) else { return false }
        updateGoal(id: goalID) { goal in
            guard let index = goal.decisions?.firstIndex(where: { $0.id == decisionID }) else { return }
            goal.decisions?[index].answer = answer
            goal.decisions?[index].answeredAt = Date()
            goal.updatedAt = Date()
        }
        return true
    }

    func answeredDecisions(goalID: UUID, taskID: UUID, runtimeID: UUID, includingResumed: Bool = false) -> [AgentDispatchDecision]? {
        guard let goal = goals.first(where: { $0.id == goalID }), !goal.isPaused,
              let task = goal.tasks.first(where: { $0.id == taskID }),
              task.state == .blocked || (includingResumed && task.state == .running),
              task.runtimeSessionID == runtimeID,
              let ids = task.pendingDecisionIDs ?? (includingResumed ? task.resumedDecisionIDs : nil), !ids.isEmpty else { return nil }
        let answers = ids.compactMap { id in goal.decisions?.first(where: { $0.id == id }) }
        guard answers.count == ids.count, answers.allSatisfy({ $0.answer != nil && $0.applies(to: task, in: goal) }) else { return nil }
        return answers
    }

    func resumeAnsweredTask(goalID: UUID, taskID: UUID, runtimeID: UUID) -> Bool {
        guard answeredDecisions(goalID: goalID, taskID: taskID, runtimeID: runtimeID) != nil else { return false }
        updateTask(goalID: goalID, taskID: taskID) { task in
            task.resumedDecisionIDs = task.pendingDecisionIDs
            task.pendingDecisionIDs = nil
            task.state = .running
            task.updatedAt = Date()
        }
        return true
    }
}
