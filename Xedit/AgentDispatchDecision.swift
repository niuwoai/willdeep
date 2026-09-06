import Foundation

/// A durable request for missing information, not a tool permission grant.
nonisolated struct AgentDispatchDecision: Codable, Equatable, Identifiable {
    struct Question: Codable, Equatable {
        enum Scope: String, Codable { case task, project }
        let title: String
        let question: String
        let requestedInformation: [String]
        let defaultAssumptions: [String]
        let options: [String]
        let multiSelect: Bool
        let scope: Scope

        init?(arguments: [String: AgentJSONValue]) {
            guard let text = arguments["question"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.count <= 4_000 else { return nil }
            title = arguments["title"]?.stringValue() ?? ""
            question = text
            requestedInformation = arguments["requested_information"]?.stringArrayValue() ?? []
            defaultAssumptions = arguments["default_assumptions"]?.stringArrayValue() ?? []
            options = arguments["options"]?.stringArrayValue() ?? []
            multiSelect = arguments["multi_select"]?.boolValue() ?? false
            scope = Scope(rawValue: arguments["decision_scope"]?.stringValue() ?? "task") ?? .task
            guard title.count <= 200, options.count <= 12, requestedInformation.count <= 12,
                  defaultAssumptions.count <= 12,
                  (options + requestedInformation + defaultAssumptions).allSatisfy({ !$0.isEmpty && $0.count <= 2_000 }) else { return nil }
        }
    }

    struct Participant: Codable, Equatable, Identifiable {
        let id: UUID
        let taskID: UUID
        let runtimeID: UUID
        let externalCallID: String
        let contractDigest: String
        let workspace: WorkspaceLocation
        var runtimeGoalDigest: String? = nil
    }

    let id: UUID
    let deduplicationKey: String
    let question: Question
    var participants: [Participant]
    let createdAt: Date
    var answer: String?
    var answeredAt: Date?

    static func contractDigest(goal: AgentDispatchGoal, task: AgentDispatchTask) throws -> String {
        struct Contract: Encodable {
            let goalID: UUID
            let statement: String
            let taskID: UUID
            let title: String
            let criteria: [String]
            let dependencies: [UUID]
            let binding: AgentDispatchWorkspaceBinding?
            let verificationCommands: [String]?
            let scheduling: AgentDispatchSchedulingHints?
            let deliveryRevisionID: UUID?
        }
        return try AgentGoalTaskAuthorization.digest(Contract(goalID: goal.id, statement: goal.statement,
            taskID: task.id, title: task.title, criteria: task.acceptanceCriteria,
            dependencies: task.dependencyIDs, binding: goal.resolvedWorkspaceBinding(for: task),
            verificationCommands: task.verificationCommands, scheduling: task.scheduling,
            deliveryRevisionID: task.deliveryRevisionID))
    }

    func applies(to task: AgentDispatchTask, in goal: AgentDispatchGoal) -> Bool {
        guard let digest = try? Self.contractDigest(goal: goal, task: task) else { return false }
        return participants.contains {
            $0.taskID == task.id && $0.runtimeID == task.runtimeSessionID && $0.contractDigest == digest
        }
    }
}

extension AgentDispatchGoal {
    var outstandingDecisions: [AgentDispatchDecision] {
        (decisions ?? []).filter { decision in
            tasks.contains { $0.state == .blocked && ($0.pendingDecisionIDs ?? []).contains(decision.id) }
        }
    }
    var pendingDecisions: [AgentDispatchDecision] {
        (decisions ?? []).filter { decision in
            decision.answer == nil && tasks.contains {
                $0.state == .blocked && ($0.pendingDecisionIDs ?? []).contains(decision.id) && decision.applies(to: $0, in: self)
            }
        }
    }
}
