import Foundation

/// Transport-neutral description for the daemon lifecycle. Shell commands are
/// not labelled as an AI executor and their output is never parsed as CLI JSON.
nonisolated struct AgentDaemonExecution {
    enum Input {
        case command(String)
        case process(executable: String, arguments: [String], standardInput: Data)
        case recoveryOnly
    }

    let input: Input
    let executor: AgentExecutionAgent?
    let workingDirectory: URL?
    let displayCommand: String
    let decoder: any AgentExecutorEventDecoding
    var lifetime: AgentBackgroundJobLifetime = .turn
    var goalPhaseID: String? = nil
    var survivesTurnStop = false
    var summaryPrefix: String? = nil

    init(_ specification: AgentExecutorProcessSpecification) {
        input = .process(executable: specification.executableURL.lastPathComponent,
            arguments: specification.arguments, standardInput: specification.standardInput)
        executor = specification.executor
        workingDirectory = specification.workingDirectory
        displayCommand = specification.displayCommand
        decoder = specification.decoder
    }

    init(command: String, displayCommand: String, summaryPrefix: String? = nil) {
        input = .command(command)
        executor = nil
        workingDirectory = nil
        self.displayCommand = displayCommand
        decoder = AgentDaemonCommandDecoder()
        self.summaryPrefix = summaryPrefix
    }

    init(receipt: AgentDaemonStartReceipt, workspace: String) {
        input = .recoveryOnly
        executor = receipt.executor
        workingDirectory = URL(fileURLWithPath: workspace)
        displayCommand = receipt.executor?.displayName ?? L10n.JobReceipt.command
        decoder = AgentDaemonCommandDecoder()
        lifetime = receipt.lifetime ?? .turn
        goalPhaseID = receipt.goalPhaseID
        survivesTurnStop = receipt.survivesTurnStop ?? false
    }

    func startBody(timeout: Int) throws -> [String: Any] {
        var body: [String: Any] = ["cwd": ".", "timeout_seconds": timeout]
        switch input {
        case .command(let command): body["command"] = command
        case .process(let executable, let arguments, let standardInput):
            body["executable"] = executable
            body["arguments"] = arguments
            body["stdin_base64"] = standardInput.base64EncodedString()
        case .recoveryOnly: throw AgentDaemonStartJournalError.conflictingReceipt
        }
        return body
    }

    mutating func applyCommandOwnership(arguments: [String: AgentJSONValue], context: AgentToolContext) throws {
        guard case .command(let command) = input else { return }
        let requested: AgentBackgroundJobLifetime?
        if let raw = arguments["lifetime"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !raw.isEmpty {
            guard let value = AgentBackgroundJobLifetime(rawValue: raw) else {
                throw AgentToolError.invalidArgument("lifetime must be turn, phase, goal, or persistent")
            }
            requested = value
        } else { requested = nil }
        let activity = AgentRunCommandExecutionPolicy.inferredActivityKind(for: command)
        lifetime = requested ?? (activity == .server ? (context.goalPhaseID == nil ? .persistent : .phase) : .turn)
        if lifetime == .phase, context.goalPhaseID == nil { lifetime = context.isGoalMode ? .goal : .turn }
        goalPhaseID = lifetime == .phase ? context.goalPhaseID : nil
        survivesTurnStop = requested == .persistent
    }
}

nonisolated final class AgentDaemonCommandDecoder: AgentExecutorEventDecoding, @unchecked Sendable {
    func decode(line: String) -> [AgentExecutorEvent] {
        guard !line.isEmpty else { return [] }
        return [AgentExecutorEvent(kind: .message, detail: line, status: .running)]
    }
}
