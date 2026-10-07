import Foundation

enum AgentRoundtableTools {
    static let startDescriptor = AgentToolDescriptor(
        name: "start_roundtable",
        description: "Start a background expert roundtable / expert PK when the user asks for debate or contrasting perspectives. Returns a session id immediately; it does NOT mean the discussion has finished. A read-only live timeline appears in the originating chat. Experts may pause for the user; all replies, interventions and continuation happen in the sidebar Expert Roundtable page. Do not poll with shell commands or start duplicate discussions. Use get_roundtable_status when the user asks for results.",
        risk: .write,
        parameters: [
            .init(name: "topic", type: .string, description: "Full question and material to debate, up to \(AgentPluginRoundtableRequest.maximumTopicCharacters) characters.", required: true),
            .init(name: "title", type: .string, description: "Optional short user-visible title.", required: false),
            .init(name: "expert_ids", type: .stringArray, description: "Optional 2–6 distinct expert ids: product, architecture, finance, risk, strategy, psychology, legal, research, growth, operations. Omit for the host to recommend experts.", required: false)
        ]
    )
    static let statusDescriptor = AgentToolDescriptor(
        name: "get_roundtable_status",
        description: "Read a roundtable started from this conversation: phase, current speaker, latest public speech and final document when completed. This does not resume, reply to or stop it. Direct the user to Expert Roundtable for interaction.",
        risk: .read,
        parameters: [.init(name: "session_id", type: .string, description: "Roundtable session UUID returned by start_roundtable.", required: true)]
    )

    static func validatedExperts(_ value: AgentJSONValue?) throws -> [AgentRoundtableExpertRole] {
        guard let value else { return [] }
        guard let ids = value.stringArrayValue(),
              (RoundtablePreparation.minimumExpertCount...RoundtablePreparation.maximumExpertCount).contains(ids.count),
              Set(ids).count == ids.count else {
            throw AgentToolError.invalidArgument("expert_ids must contain 2–6 distinct expert ids.")
        }
        return try ids.map { id in
            guard let role = AgentRoundtableExpertRole(rawValue: id) else {
                throw AgentToolError.invalidArgument("Unknown roundtable expert: \(id)")
            }
            return role
        }
    }

    static func run(name: String, arguments: [String: AgentJSONValue], context: AgentToolContext) async throws -> AgentToolResult {
        guard let originID = context.runtimeID else {
            throw AgentToolError.invalidArgument("Roundtable tools require a conversational runtime.")
        }
        if name == "get_roundtable_status" {
            guard let raw = arguments["session_id"]?.stringValue(), let sessionID = UUID(uuidString: raw) else {
                throw AgentToolError.invalidArgument("session_id must be a roundtable session UUID.")
            }
            return try await MainActor.run {
                guard let appState = EditorAppStateRegistry.shared.appState(forRuntime: originID),
                      let runtime = appState.runtime(for: sessionID),
                      let report = runtime.messages.compactMap(\.workflowReport).last?.roundtable,
                      report.originSessionID == originID else {
                    throw AgentToolError.invalidArgument("No roundtable owned by this conversation was found.")
                }
                var payload = "session_id: \(sessionID)\nphase: \(report.phase.rawValue)\nround: \(report.currentRound)"
                if let speech = AgentPluginRoundtableChatSpeech.make(from: report) {
                    payload += "\nexpert: \(speech.name)\nlatest_public_speech: \(speech.text)"
                }
                if report.phase == .completed, let document = report.finalDocument { payload += "\nfinal_document:\n\(document)" }
                if report.phase == .awaitingUser { payload += "\nUser interaction is required in Expert Roundtable. Do not answer on the user's behalf." }
                return AgentToolResult(summary: "Roundtable: \(report.phase.rawValue)", payload: payload)
            }
        }
        let topic = arguments["topic"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !topic.isEmpty, topic.count <= AgentPluginRoundtableRequest.maximumTopicCharacters else {
            throw AgentToolError.invalidArgument("topic must contain 1–\(AgentPluginRoundtableRequest.maximumTopicCharacters) characters.")
        }
        let experts = try validatedExperts(arguments["expert_ids"])
        let title = String((arguments["title"]?.stringValue() ?? "").prefix(AgentPluginRoundtableRequest.maximumTitleCharacters))
        return try await MainActor.run {
            guard let appState = EditorAppStateRegistry.shared.appState(forRuntime: originID),
                  let sessionID = appState.startAgentRoundtable(topic: topic, title: title, experts: experts, originSessionID: originID, startImmediately: true) else {
                throw AgentToolError.invalidArgument("The originating conversation is unavailable.")
            }
            return AgentToolResult(
                summary: "Expert roundtable started",
                payload: "session_id: \(sessionID)\nStarted in the background; this is not a final verdict. Live public speech appears in the chat card. Use get_roundtable_status for results. When awaiting user input, direct the user to the sidebar Expert Roundtable page; all interaction happens there."
            )
        }
    }
}
