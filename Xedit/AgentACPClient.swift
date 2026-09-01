//
//  AgentACPClient.swift
//  WillDeep
//
//  Agent Client Protocol (ACP) client for local coding-agent adapters.
//  JSON-RPC 2.0 is transported as newline-delimited JSON over stdio.
//

import Foundation

nonisolated struct AgentACPConfiguration: Sendable {
    let executableURL: URL
    let adapterArguments: [String]
    let claudeExecutableURL: URL
    let prompt: String
    let model: String?
    let sessionID: String?
    let imagePaths: [String]
    let workingDirectory: URL
    let environment: [String: String]
    let sandboxMode: AgentSandboxMode
    let permissionMode: String
    let secretRedactionValues: [String]

    init(
        executableURL: URL,
        adapterArguments: [String] = [],
        claudeExecutableURL: URL,
        prompt: String,
        model: String?,
        sessionID: String?,
        imagePaths: [String],
        workingDirectory: URL,
        environment: [String: String],
        sandboxMode: AgentSandboxMode,
        permissionMode: String,
        secretRedactionValues: [String]
    ) {
        self.executableURL = executableURL
        self.adapterArguments = adapterArguments
        self.claudeExecutableURL = claudeExecutableURL
        self.prompt = prompt
        self.model = model
        self.sessionID = sessionID
        self.imagePaths = imagePaths
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.sandboxMode = sandboxMode
        self.permissionMode = permissionMode
        self.secretRedactionValues = secretRedactionValues
    }
}

nonisolated struct AgentACPResult: Sendable {
    let sessionID: String
    let stopReason: String
    let status: AgentExecutorEventStatus
}

nonisolated enum AgentACPError: LocalizedError {
    case invalidMessage(String)
    case protocolFailure(String)
    case missingSessionID
    case processExited(Int32, String)
    case pathOutsideWorkspace(String)
    case unavailableHostCapability(String)
    case unknownTerminal(String)

    var errorDescription: String? {
        switch self {
        case .invalidMessage(let detail):
            return "ACP returned invalid JSON: \(detail)"
        case .protocolFailure(let detail):
            return "ACP request failed: \(detail)"
        case .missingSessionID:
            return "ACP did not return a session id."
        case .processExited(let code, let detail):
            return "ACP adapter exited with code \(code): \(detail)"
        case .pathOutsideWorkspace(let path):
            return "ACP refused a path outside the workspace: \(path)"
        case .unavailableHostCapability(let capability):
            return "ACP host capability is unavailable: \(capability)"
        case .unknownTerminal(let terminalID):
            return "ACP terminal does not exist: \(terminalID)"
        }
    }
}

nonisolated final class AgentACPClientTurn: @unchecked Sendable {
    typealias ApprovalHandler = @MainActor (
        AgentDelegatedApprovalRequest
    ) async -> AgentDelegatedApprovalDecision
    typealias ReadHandler = @MainActor (URL) throws -> String
    typealias WriteHandler = @MainActor (URL, String) throws -> Void
    typealias EventHandler = @Sendable ([AgentExecutorEvent]) async -> Void
    typealias ProcessHandler = @Sendable (Int32) async -> Void

    private let configuration: AgentACPConfiguration
    private let approvalHandler: ApprovalHandler?
    private let readHandler: ReadHandler?
    private let writeHandler: WriteHandler?
    private let eventHandler: EventHandler
    private let processHandler: ProcessHandler
    private let processLock = NSLock()
    private var process: Process?
    private var terminalStore: AgentACPTerminalStore
    private var authorizationStore = AgentACPAuthorizationStore()

    init(
        configuration: AgentACPConfiguration,
        approvalHandler: ApprovalHandler?,
        readHandler: ReadHandler?,
        writeHandler: WriteHandler?,
        eventHandler: @escaping EventHandler,
        processHandler: @escaping ProcessHandler
    ) {
        self.configuration = configuration
        self.approvalHandler = approvalHandler
        self.readHandler = readHandler
        self.writeHandler = writeHandler
        self.eventHandler = eventHandler
        self.processHandler = processHandler
        self.terminalStore = AgentACPTerminalStore(
            rootDirectory: configuration.workingDirectory,
            sandboxMode: configuration.sandboxMode,
            baseEnvironment: configuration.environment,
            secretRedactionValues: configuration.secretRedactionValues
        )
    }

    func cancel() {
        processLock.withLock {
            guard let process, process.isRunning else { return }
            AgentProcessSupport.terminateProcessTree(process)
        }
        terminalStore.killAll()
    }

    func run() async throws -> AgentACPResult {
        try Task.checkCancellation()
        if let requestedSessionID = configuration.sessionID,
           let connection = await AgentACPConnectionPool.shared.take(
            sessionID: requestedSessionID,
            configuration: configuration
           ) {
            terminalStore = connection.terminalStore
            authorizationStore = connection.authorizationStore
            processLock.withLock { self.process = connection.process }
            await processHandler(connection.process.processIdentifier)
            do {
                try connection.writer.send(
                    promptRequest(sessionID: requestedSessionID)
                )
                let result = try await processMessages(
                    lines: connection.lines,
                    writer: connection.writer,
                    process: connection.process,
                    errors: connection.errors,
                    existingSessionID: requestedSessionID
                )
                await AgentACPConnectionPool.shared.store(
                    sessionID: result.sessionID,
                    connection: connection
                )
                processLock.withLock { self.process = nil }
                return result
            } catch {
                connection.terminate()
                processLock.withLock { self.process = nil }
                throw error
            }
        }

        let process = Process()
        let launch = AgentSandboxPolicy.processLaunch(
            executableURL: configuration.executableURL,
            arguments: configuration.adapterArguments,
            mode: configuration.sandboxMode,
            rootDirectory: configuration.workingDirectory
        )
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.currentDirectoryURL = configuration.workingDirectory
        var environment = AgentSandboxPolicy.sandboxedEnvironment(
            mode: configuration.sandboxMode,
            rootDirectory: configuration.workingDirectory,
            base: configuration.environment
        )
        environment["PWD"] = configuration.workingDirectory.path
        environment["CLAUDE_CODE_EXECUTABLE"] = configuration.claudeExecutableURL.path
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let lines = AgentACPLineStream()
        let errors = AgentACPTextBuffer(
            limit: 64 * 1_024,
            redactionValues: configuration.secretRedactionValues
        )
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF. Detach first so the dispatch source cannot spin on
                // an exhausted handle, then close the stream — every byte
                // the process wrote has been consumed at this point.
                handle.readabilityHandler = nil
                lines.finish()
            } else {
                lines.append(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errors.append(data)
            }
        }
        process.terminationHandler = { _ in
            // Process exit is NOT "output drained": under load the reader
            // lags the termination notification, and the previous eager
            // drain-once-then-finish here dropped the final buffered lines —
            // observed as `.processExited(0, "while waiting for
            // session/prompt")` from a server that had already written its
            // response and exited cleanly. EOF on the pipe (handled above)
            // is the only signal that guarantees completeness, and it always
            // follows a real exit. Keep a grace-window fallback solely for a
            // leaked child that inherited the write end, where EOF would
            // never arrive.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                guard !lines.finished else { return }
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                lines.append(outputPipe.fileHandleForReading.availableData)
                errors.append(errorPipe.fileHandleForReading.availableData)
                lines.finish()
            }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? inputPipe.fileHandleForWriting.close()
            throw error
        }
        processLock.withLock { self.process = process }
        await processHandler(process.processIdentifier)
        let writer = AgentACPJSONLineWriter(handle: inputPipe.fileHandleForWriting)
        let connection = AgentACPConnection(
            process: process,
            inputPipe: inputPipe,
            outputPipe: outputPipe,
            errorPipe: errorPipe,
            lines: lines,
            errors: errors,
            writer: writer,
            executablePath: configuration.executableURL.path,
            workingDirectoryPath: configuration.workingDirectory.path,
            terminalStore: terminalStore,
            authorizationStore: authorizationStore
        )

        do {
            try writer.send(initializeRequest())
            let result = try await processMessages(
                lines: lines,
                writer: writer,
                process: process,
                errors: errors,
                existingSessionID: nil
            )
            await AgentACPConnectionPool.shared.store(
                sessionID: result.sessionID,
                connection: connection
            )
            processLock.withLock { self.process = nil }
            return result
        } catch {
            connection.terminate()
            processLock.withLock { self.process = nil }
            throw error
        }
    }

    private func processMessages(
        lines: AgentACPLineStream,
        writer: AgentACPJSONLineWriter,
        process: Process,
        errors: AgentACPTextBuffer,
        existingSessionID: String?
    ) async throws -> AgentACPResult {
        var activeSessionID = existingSessionID ?? configuration.sessionID
        var sentSessionRequest = false
        var sentPrompt = existingSessionID != nil

        for await line in lines.stream {
            try Task.checkCancellation()
            guard let object = AgentExecutorJSON.object(from: line) else {
                throw AgentACPError.invalidMessage(redact(line))
            }
            if let method = AgentExecutorJSON.string(object["method"]) {
                if object["id"] != nil {
                    try await respondToAgentRequest(
                        method: method,
                        object: object,
                        writer: writer
                    )
                } else if method == "session/update" {
                    let events = AgentACPEventDecoder.decode(
                        params: object["params"] as? [String: Any] ?? [:],
                        rawLine: redact(line)
                    )
                    if !events.isEmpty {
                        await eventHandler(redacted(events))
                    }
                }
                continue
            }

            let responseID = AgentExecutorJSON.string(object["id"])
            if let error = object["error"] {
                throw AgentACPError.protocolFailure(
                    redact(AgentExecutorJSON.pretty(error) ?? "unknown error")
                )
            }
            switch responseID {
            case "initialize":
                try writer.send(sessionRequest())
                sentSessionRequest = true
            case "session":
                guard let result = object["result"] as? [String: Any],
                      let sessionID = AgentExecutorJSON.string(result["sessionId"]),
                      !sessionID.isEmpty else {
                    throw AgentACPError.missingSessionID
                }
                activeSessionID = sessionID
                await eventHandler([AgentExecutorEvent(
                    kind: .sessionStarted,
                    sessionID: sessionID,
                    title: "ACP",
                    status: .running,
                    rawJSON: redact(line)
                )])
                try writer.send(promptRequest(sessionID: sessionID))
                sentPrompt = true
            case "prompt":
                guard let sessionID = activeSessionID else {
                    throw AgentACPError.missingSessionID
                }
                let result = object["result"] as? [String: Any] ?? [:]
                let stopReason = AgentExecutorJSON.string(result["stopReason"])
                    ?? "end_turn"
                let status: AgentExecutorEventStatus = stopReason == "cancelled"
                    ? .cancelled
                    : .completed
                var events: [AgentExecutorEvent] = []
                if let usage = AgentACPEventDecoder.usage(
                    from: result["usage"] as? [String: Any]
                ), !usage.isEmpty {
                    events.append(AgentExecutorEvent(
                        kind: .usage,
                        sessionID: sessionID,
                        usage: usage,
                        rawJSON: redact(line)
                    ))
                }
                events.append(AgentExecutorEvent(
                    kind: .finished,
                    sessionID: sessionID,
                    detail: stopReason,
                    status: status,
                    rawJSON: redact(line)
                ))
                await eventHandler(events)
                return AgentACPResult(
                    sessionID: sessionID,
                    stopReason: stopReason,
                    status: status
                )
            default:
                break
            }
        }

        let code = process.isRunning ? -1 : process.terminationStatus
        let phase: String
        if sentPrompt {
            phase = "while waiting for session/prompt"
        } else if sentSessionRequest {
            phase = "while creating or loading a session"
        } else {
            phase = "during initialize"
        }
        throw AgentACPError.processExited(
            code,
            redact("\(phase). \(errors.stringValue)")
        )
    }

    private func initializeRequest() -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": "initialize",
            "method": "initialize",
            "params": [
                "protocolVersion": 1,
                "clientInfo": [
                    "name": AgentNetworkSupport.clientNameHeaderValue,
                    "version": Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "unknown",
                ],
                "clientCapabilities": [
                    "fs": [
                        "readTextFile": true,
                        "writeTextFile": writeHandler != nil,
                    ],
                    "terminal": true,
                ],
            ],
        ]
    }

    private func sessionRequest() -> [String: Any] {
        var params: [String: Any] = [
            "cwd": configuration.workingDirectory.path,
            "mcpServers": [],
            "_meta": [
                "claudeCode": [
                    "options": sessionOptions(),
                ],
            ],
        ]
        let method: String
        if let sessionID = configuration.sessionID, !sessionID.isEmpty {
            method = "session/load"
            params["sessionId"] = sessionID
        } else {
            method = "session/new"
        }
        return [
            "jsonrpc": "2.0",
            "id": "session",
            "method": method,
            "params": params,
        ]
    }

    private func sessionOptions() -> [String: Any] {
        var options: [String: Any] = [
            "permissionMode": configuration.permissionMode,
        ]
        if let model = configuration.model, !model.isEmpty {
            options["model"] = model
        }
        return options
    }

    private func promptRequest(sessionID: String) -> [String: Any] {
        var blocks: [[String: Any]] = [[
            "type": "text",
            "text": configuration.prompt,
        ]]
        for path in configuration.imagePaths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                continue
            }
            blocks.append([
                "type": "image",
                "mimeType": AgentACPMIMEType.forPath(path),
                "data": data.base64EncodedString(),
            ])
        }
        return [
            "jsonrpc": "2.0",
            "id": "prompt",
            "method": "session/prompt",
            "params": [
                "sessionId": sessionID,
                "prompt": blocks,
            ],
        ]
    }

    private func respondToAgentRequest(
        method: String,
        object: [String: Any],
        writer: AgentACPJSONLineWriter
    ) async throws {
        let id = object["id"] ?? NSNull()
        let params = object["params"] as? [String: Any] ?? [:]
        do {
            let result: [String: Any]
            switch method {
            case "session/request_permission":
                result = try await permissionResult(params: params)
            case "fs/read_text_file":
                result = try await readTextFile(params: params)
            case "fs/write_text_file":
                result = try await writeTextFile(params: params)
            case "terminal/create":
                result = try await createTerminal(params: params)
            case "terminal/output":
                result = try terminalStore.output(params: params)
            case "terminal/wait_for_exit":
                result = try await terminalStore.waitForExit(params: params)
            case "terminal/kill":
                result = try terminalStore.kill(params: params)
            case "terminal/release":
                result = try terminalStore.release(params: params)
            default:
                throw AgentACPError.unavailableHostCapability(method)
            }
            try writer.send([
                "jsonrpc": "2.0",
                "id": id,
                "result": result,
            ])
        } catch {
            try writer.send([
                "jsonrpc": "2.0",
                "id": id,
                "error": [
                    "code": -32_603,
                    "message": redact(error.localizedDescription),
                ],
            ])
        }
    }

    private func permissionResult(
        params: [String: Any]
    ) async throws -> [String: Any] {
        guard let approvalHandler else {
            return ["outcome": ["outcome": "cancelled"]]
        }
        let toolCall = params["toolCall"] as? [String: Any] ?? [:]
        let options = params["options"] as? [[String: Any]] ?? []
        let rawInput = toolCall["rawInput"] as? [String: Any] ?? [:]
        let locations = toolCall["locations"] as? [[String: Any]] ?? []
        let kindText = AgentExecutorJSON.string(toolCall["kind"]) ?? ""
        let command = AgentExecutorJSON.string(rawInput["command"])
        let filePaths = locations.compactMap {
            AgentExecutorJSON.string($0["path"])
        } + [
            AgentExecutorJSON.string(rawInput["file_path"]),
            AgentExecutorJSON.string(rawInput["path"]),
        ].compactMap { $0 }
        let kind: AgentDelegatedApprovalKind
        if command != nil || kindText == "execute" {
            kind = .command
        } else if !filePaths.isEmpty
                    || ["edit", "delete", "move"].contains(kindText) {
            kind = .fileChange
        } else {
            kind = .permissions
        }
        let request = AgentDelegatedApprovalRequest(
            id: AgentExecutorJSON.string(toolCall["toolCallId"])
                ?? AgentExecutorJSON.string(toolCall["id"])
                ?? UUID().uuidString,
            executor: .claudeCode,
            kind: kind,
            command: command,
            cwd: configuration.workingDirectory.path,
            reason: AgentExecutorJSON.pretty(rawInput),
            filePaths: filePaths,
            requestedPermissions: kind == .permissions
                ? AgentExecutorJSON.pretty(rawInput)
                : nil,
            allowsSessionApproval: options.contains {
                AgentExecutorJSON.string($0["kind"]) == "allow_always"
            }
        )
        await eventHandler([AgentExecutorEvent(
            kind: .permissionRequested,
            itemID: request.id,
            title: AgentExecutorJSON.string(toolCall["title"]) ?? kindText,
            detail: request.reason,
            status: .pending,
            toolName: kindText
        )])
        let decision = await approvalHandler(request)
        if decision == .accept || decision == .acceptForSession {
            authorizationStore.record(
                command: command,
                filePaths: filePaths,
                persistent: decision == .acceptForSession
            )
        }
        let selectedKind: String
        switch decision {
        case .accept:
            selectedKind = "allow_once"
        case .acceptForSession:
            selectedKind = "allow_always"
        case .decline:
            selectedKind = "reject_once"
        case .cancel:
            await eventHandler([AgentExecutorEvent(
                kind: .permissionRequested,
                itemID: request.id,
                title: AgentExecutorJSON.string(toolCall["title"]) ?? kindText,
                status: .cancelled
            )])
            return ["outcome": ["outcome": "cancelled"]]
        }
        let optionID = options.first {
            AgentExecutorJSON.string($0["kind"]) == selectedKind
        }.flatMap { AgentExecutorJSON.string($0["optionId"]) }
            ?? options.first.flatMap { AgentExecutorJSON.string($0["optionId"]) }
        guard let optionID else {
            return ["outcome": ["outcome": "cancelled"]]
        }
        await eventHandler([AgentExecutorEvent(
            kind: .permissionRequested,
            itemID: request.id,
            title: AgentExecutorJSON.string(toolCall["title"]) ?? kindText,
            status: decision == .decline ? .failed : .completed
        )])
        return [
            "outcome": [
                "outcome": "selected",
                "optionId": optionID,
            ],
        ]
    }

    private func readTextFile(params: [String: Any]) async throws -> [String: Any] {
        guard let readHandler else {
            throw AgentACPError.unavailableHostCapability("fs/read_text_file")
        }
        let url = try workspaceURL(params: params)
        let content = try await MainActor.run { try readHandler(url) }
        let line = max(1, AgentExecutorJSON.int(params["line"]) ?? 1)
        let limit = AgentExecutorJSON.int(params["limit"])
        let lines = content.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        let start = min(line - 1, lines.count)
        let end = limit.map { min(start + max(0, $0), lines.count) }
            ?? lines.count
        return ["content": lines[start..<end].joined(separator: "\n")]
    }

    private func writeTextFile(params: [String: Any]) async throws -> [String: Any] {
        guard let writeHandler else {
            throw AgentACPError.unavailableHostCapability("fs/write_text_file")
        }
        let url = try workspaceURL(params: params)
        guard let content = AgentExecutorJSON.string(params["content"]) else {
            throw AgentACPError.protocolFailure("fs/write_text_file omitted content")
        }
        if !authorizationStore.consumeFile(path: url.path) {
            try await requireFallbackApproval(
                kind: .fileChange,
                title: "ACP file write",
                command: nil,
                filePaths: [url.path]
            )
        }
        try await MainActor.run { try writeHandler(url, content) }
        await eventHandler([AgentExecutorEvent(
            kind: .fileChanged,
            title: "write",
            status: .completed,
            filePath: url.path
        )])
        return [:]
    }

    private func createTerminal(params: [String: Any]) async throws -> [String: Any] {
        guard let command = AgentExecutorJSON.string(params["command"]),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentACPError.protocolFailure("terminal/create omitted command")
        }
        if !authorizationStore.consumeCommand(command) {
            try await requireFallbackApproval(
                kind: .command,
                title: "ACP terminal command",
                command: command,
                filePaths: []
            )
        }
        return try terminalStore.create(params: params)
    }

    private func requireFallbackApproval(
        kind: AgentDelegatedApprovalKind,
        title: String,
        command: String?,
        filePaths: [String]
    ) async throws {
        guard let approvalHandler else {
            throw AgentACPError.unavailableHostCapability("delegated approval")
        }
        let decision = await approvalHandler(AgentDelegatedApprovalRequest(
            id: UUID().uuidString,
            executor: .claudeCode,
            kind: kind,
            command: command,
            cwd: configuration.workingDirectory.path,
            reason: nil,
            filePaths: filePaths,
            requestedPermissions: nil,
            allowsSessionApproval: true
        ))
        guard decision == .accept || decision == .acceptForSession else {
            throw AgentACPError.protocolFailure("Host declined \(title)")
        }
    }

    private func workspaceURL(params: [String: Any]) throws -> URL {
        guard let path = AgentExecutorJSON.string(params["path"]), !path.isEmpty else {
            throw AgentACPError.protocolFailure("filesystem request omitted path")
        }
        return try AgentWorkspacePathGuard.validate(
            URL(
                fileURLWithPath: path,
                relativeTo: configuration.workingDirectory
            ),
            root: configuration.workingDirectory
        )
    }

    private func redacted(_ events: [AgentExecutorEvent]) -> [AgentExecutorEvent] {
        events.map { event in
            var copy = event
            copy.title = copy.title.map(redact)
            copy.detail = copy.detail.map(redact)
            copy.rawJSON = copy.rawJSON.map(redact)
            return copy
        }
    }

    private func redact(_ text: String) -> String {
        AgentSecretStore.redact(
            text,
            secretValues: configuration.secretRedactionValues
        )
    }
}

nonisolated enum AgentACPEventDecoder {
    static func decode(
        params: [String: Any],
        rawLine: String
    ) -> [AgentExecutorEvent] {
        let sessionID = AgentExecutorJSON.string(params["sessionId"])
        guard let update = params["update"] as? [String: Any],
              let kind = AgentExecutorJSON.string(update["sessionUpdate"]) else {
            return [AgentExecutorEvent(
                kind: .raw,
                sessionID: sessionID,
                detail: rawLine,
                rawJSON: rawLine
            )]
        }
        let itemID = AgentExecutorJSON.string(update["toolCallId"])
        switch kind {
        case "agent_message_chunk", "user_message_chunk":
            return [AgentExecutorEvent(
                kind: .message,
                sessionID: sessionID,
                detail: contentText(update["content"]),
                status: .running,
                rawJSON: rawLine
            )]
        case "agent_thought_chunk":
            return [AgentExecutorEvent(
                kind: .thinking,
                sessionID: sessionID,
                detail: contentText(update["content"]),
                status: .running,
                rawJSON: rawLine
            )]
        case "tool_call":
            return toolCallEvents(
                update: update,
                sessionID: sessionID,
                itemID: itemID,
                kind: .toolStarted,
                rawLine: rawLine
            )
        case "tool_call_update":
            return toolCallEvents(
                update: update,
                sessionID: sessionID,
                itemID: itemID,
                kind: .toolUpdated,
                rawLine: rawLine
            )
        case "usage_update":
            guard let usage = usage(from: update), !usage.isEmpty else { return [] }
            return [AgentExecutorEvent(
                kind: .usage,
                sessionID: sessionID,
                usage: usage,
                rawJSON: rawLine
            )]
        case "plan":
            return [AgentExecutorEvent(
                kind: .thinking,
                sessionID: sessionID,
                title: "plan",
                detail: AgentExecutorJSON.pretty(update["entries"]),
                status: .running,
                rawJSON: rawLine
            )]
        default:
            return [AgentExecutorEvent(
                kind: .raw,
                sessionID: sessionID,
                detail: rawLine,
                rawJSON: rawLine
            )]
        }
    }

    static func usage(from object: [String: Any]?) -> AgentExecutorUsage? {
        guard let object else { return nil }
        return AgentExecutorUsage(
            inputTokens: AgentExecutorJSON.int(object["inputTokens"])
                ?? AgentExecutorJSON.int(object["input_tokens"]),
            cachedInputTokens: AgentExecutorJSON.int(object["cachedInputTokens"])
                ?? AgentExecutorJSON.int(object["cached_input_tokens"]),
            outputTokens: AgentExecutorJSON.int(object["outputTokens"])
                ?? AgentExecutorJSON.int(object["output_tokens"]),
            costUSD: AgentExecutorJSON.double(object["costUsd"])
                ?? AgentExecutorJSON.double(object["cost_usd"]),
            durationMilliseconds: AgentExecutorJSON.int(object["durationMs"])
                ?? AgentExecutorJSON.int(object["duration_ms"])
        )
    }

    private static func toolCallEvents(
        update: [String: Any],
        sessionID: String?,
        itemID: String?,
        kind: AgentExecutorEventKind,
        rawLine: String
    ) -> [AgentExecutorEvent] {
        let toolKind = AgentExecutorJSON.string(update["kind"])
        let statusText = AgentExecutorJSON.string(update["status"])
        let status: AgentExecutorEventStatus
        switch statusText {
        case "completed": status = .completed
        case "failed": status = .failed
        case "pending": status = .pending
        default: status = .running
        }
        var events = [AgentExecutorEvent(
            kind: kind,
            sessionID: sessionID,
            itemID: itemID,
            title: AgentExecutorJSON.string(update["title"]),
            detail: AgentExecutorJSON.pretty(update["rawInput"])
                ?? AgentExecutorJSON.pretty(update["content"]),
            status: status,
            toolName: toolKind,
            rawJSON: rawLine
        )]
        let locations = update["locations"] as? [[String: Any]] ?? []
        if ["edit", "delete", "move"].contains(toolKind) {
            events += locations.compactMap { location in
                guard let path = AgentExecutorJSON.string(location["path"]) else {
                    return nil
                }
                return AgentExecutorEvent(
                    kind: .fileChanged,
                    sessionID: sessionID,
                    itemID: itemID,
                    title: toolKind,
                    status: status,
                    filePath: path,
                    rawJSON: rawLine
                )
            }
        }
        return events
    }

    private static func contentText(_ value: Any?) -> String? {
        if let object = value as? [String: Any] {
            return AgentExecutorJSON.string(object["text"])
                ?? AgentExecutorJSON.pretty(object)
        }
        return AgentExecutorJSON.textContent(value)
    }
}

private nonisolated final class AgentACPAuthorizationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String: Bool] = [:]
    private var filePaths: [String: Bool] = [:]

    func record(command: String?, filePaths: [String], persistent: Bool) {
        lock.withLock {
            if let command { commands[command] = persistent }
            for path in filePaths {
                self.filePaths[path] = persistent
            }
        }
    }

    func consumeCommand(_ command: String) -> Bool {
        lock.withLock {
            guard let persistent = commands[command] else { return false }
            if !persistent { commands.removeValue(forKey: command) }
            return true
        }
    }

    func consumeFile(path: String) -> Bool {
        lock.withLock {
            let match = filePaths.keys.first { approved in
                let normalized = URL(fileURLWithPath: approved).standardizedFileURL.path
                return normalized == path
            }
            guard let match, let persistent = filePaths[match] else { return false }
            if !persistent { filePaths.removeValue(forKey: match) }
            return true
        }
    }
}

private nonisolated final class AgentACPTerminalStore: @unchecked Sendable {
    private let rootDirectory: URL
    private let sandboxMode: AgentSandboxMode
    private let baseEnvironment: [String: String]
    private let secretRedactionValues: [String]
    private let lock = NSLock()
    private var terminals: [String: AgentACPTerminal] = [:]

    init(
        rootDirectory: URL,
        sandboxMode: AgentSandboxMode,
        baseEnvironment: [String: String],
        secretRedactionValues: [String]
    ) {
        self.rootDirectory = rootDirectory
        self.sandboxMode = sandboxMode
        self.baseEnvironment = baseEnvironment
        self.secretRedactionValues = secretRedactionValues
    }

    func create(params: [String: Any]) throws -> [String: Any] {
        let command = AgentExecutorJSON.string(params["command"]) ?? ""
        let requestedCWD = AgentExecutorJSON.string(params["cwd"])
        let cwd = try workspaceDirectory(requestedCWD)
        let process = Process()
        let launch = AgentSandboxPolicy.shellLaunch(
            command: command,
            mode: sandboxMode,
            rootDirectory: rootDirectory
        )
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.currentDirectoryURL = cwd
        var environment = AgentSandboxPolicy.sandboxedEnvironment(
            mode: sandboxMode,
            rootDirectory: rootDirectory,
            base: baseEnvironment
        )
        for entry in params["env"] as? [[String: Any]] ?? [] {
            guard let name = AgentExecutorJSON.string(entry["name"]),
                  let value = AgentExecutorJSON.string(entry["value"]),
                  !name.isEmpty else {
                continue
            }
            environment[name] = value
        }
        environment["PWD"] = cwd.path
        process.environment = environment
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        AgentToolRunner.closeStandardInput(for: process)
        let terminal = AgentACPTerminal(
            process: process,
            outputLimit: max(
                1_024,
                AgentExecutorJSON.int(params["outputByteLimit"]) ?? 32_000
            ),
            redactionValues: secretRedactionValues
        )
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { terminal.append(data) }
        }
        process.terminationHandler = { process in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            terminal.append(outputPipe.fileHandleForReading.availableData)
            terminal.finish(exitCode: process.terminationStatus)
        }
        try process.run()
        let id = UUID().uuidString
        lock.withLock { terminals[id] = terminal }
        return ["terminalId": id]
    }

    func output(params: [String: Any]) throws -> [String: Any] {
        let terminal = try lookup(params)
        let snapshot = terminal.snapshot()
        var result: [String: Any] = [
            "output": snapshot.output,
            "truncated": snapshot.truncated,
        ]
        if let exitCode = snapshot.exitCode {
            result["exitStatus"] = ["exitCode": exitCode]
        }
        return result
    }

    func waitForExit(params: [String: Any]) async throws -> [String: Any] {
        let terminal = try lookup(params)
        while true {
            try Task.checkCancellation()
            if let exitCode = terminal.snapshot().exitCode {
                return ["exitCode": exitCode]
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func kill(params: [String: Any]) throws -> [String: Any] {
        let terminal = try lookup(params)
        terminal.kill()
        return [:]
    }

    func release(params: [String: Any]) throws -> [String: Any] {
        guard let id = AgentExecutorJSON.string(params["terminalId"]) else {
            throw AgentACPError.protocolFailure("terminal/release omitted terminalId")
        }
        let terminal = lock.withLock { terminals.removeValue(forKey: id) }
        terminal?.kill()
        return [:]
    }

    func killAll() {
        let active = lock.withLock {
            let values = Array(terminals.values)
            terminals.removeAll()
            return values
        }
        active.forEach { $0.kill() }
    }

    private func lookup(_ params: [String: Any]) throws -> AgentACPTerminal {
        guard let id = AgentExecutorJSON.string(params["terminalId"]),
              let terminal = lock.withLock({ terminals[id] }) else {
            throw AgentACPError.unknownTerminal(
                AgentExecutorJSON.string(params["terminalId"]) ?? "missing"
            )
        }
        return terminal
    }

    private func workspaceDirectory(_ path: String?) throws -> URL {
        guard let path, !path.isEmpty else { return rootDirectory }
        return try AgentWorkspacePathGuard.validate(
            URL(fileURLWithPath: path, relativeTo: rootDirectory),
            root: rootDirectory
        )
    }
}

/// Shared workspace containment rules for every local path that a tool is
/// about to touch. Two callers rely on it: the ACP bridge (`validate`) and
/// `AgentToolContext.resolveWorkspaceURL` (`containingRoot`).
///
/// A lexical prefix check alone is not a boundary: a symlink inside an
/// authorized folder can point anywhere on disk, so `root/link/secret` reads
/// as "inside the workspace" while the kernel writes somewhere the user never
/// authorized. `run_command` already refuses those paths — seatbelt matches
/// the resolved vnode path — so accepting them in the native file tools only
/// made the two channels disagree. Resolve first, then compare.
nonisolated enum AgentWorkspacePathGuard {
    static func validate(
        _ candidateURL: URL,
        root rootURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = rootURL.standardizedFileURL
        let candidate = candidateURL.standardizedFileURL
        guard isContained(candidate.path, by: root.path) else {
            throw AgentACPError.pathOutsideWorkspace(candidate.path)
        }
        guard containingRoot(for: candidate, roots: [root], fileManager: fileManager) != nil else {
            throw AgentACPError.pathOutsideWorkspace(candidate.path)
        }
        return candidate
    }

    /// The authorized root that still contains `candidate` once symlinks are
    /// resolved, or nil when the path escapes every root. Any root may match —
    /// a link from one authorized folder into another is a legitimate shortcut
    /// between folders the user already granted, and seatbelt allows the same
    /// pair, so the two channels stay in agreement.
    static func containingRoot(
        for candidateURL: URL,
        roots: [URL],
        fileManager: FileManager = .default
    ) -> URL? {
        guard !roots.isEmpty else { return nil }
        let resolvedCandidate = resolvedPath(of: candidateURL, fileManager: fileManager)
        return roots.first { root in
            let resolvedRoot = root.standardizedFileURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            return isContained(resolvedCandidate, by: resolvedRoot)
        }
    }

    /// Resolve `url` through symlinks. A path that does not exist yet (a file
    /// the agent is about to create) has nothing to resolve, so walk up to the
    /// nearest existing ancestor, resolve that, and re-append the tail — this
    /// is what makes "write a new file behind a symlinked folder" resolve to
    /// the real destination instead of silently staying lexical.
    static func resolvedPath(
        of url: URL,
        fileManager: FileManager = .default
    ) -> String {
        let standardized = url.standardizedFileURL
        var existingAncestor = standardized
        var trailingComponents: [String] = []
        while !fileManager.fileExists(atPath: existingAncestor.path) {
            let parent = existingAncestor.deletingLastPathComponent()
            guard parent.path != existingAncestor.path else { break }
            trailingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor = parent
        }
        var resolved = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
        for component in trailingComponents {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }

    private static func isContained(
        _ candidatePath: String,
        by rootPath: String
    ) -> Bool {
        candidatePath == rootPath
            || candidatePath.hasPrefix(rootPath + "/")
    }
}

private nonisolated final class AgentACPTerminal: @unchecked Sendable {
    private let process: Process
    private let outputLimit: Int
    private let redactionValues: [String]
    private let lock = NSLock()
    private var data = Data()
    private var wasTruncated = false
    private var exitCode: Int32?

    init(process: Process, outputLimit: Int, redactionValues: [String]) {
        self.process = process
        self.outputLimit = outputLimit
        self.redactionValues = redactionValues
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.withLock {
            data.append(chunk)
            if data.count > outputLimit {
                data.removeFirst(data.count - outputLimit)
                wasTruncated = true
            }
        }
    }

    func finish(exitCode: Int32) {
        lock.withLock { self.exitCode = exitCode }
    }

    func snapshot() -> (output: String, truncated: Bool, exitCode: Int32?) {
        lock.withLock {
            let raw = String(decoding: data, as: UTF8.self)
            return (
                AgentSecretStore.redact(raw, secretValues: redactionValues),
                wasTruncated,
                exitCode
            )
        }
    }

    func kill() {
        if process.isRunning {
            AgentProcessSupport.terminateProcessTree(process)
        }
    }
}

private nonisolated final class AgentACPConnection: @unchecked Sendable {
    let process: Process
    let inputPipe: Pipe
    let outputPipe: Pipe
    let errorPipe: Pipe
    let lines: AgentACPLineStream
    let errors: AgentACPTextBuffer
    let writer: AgentACPJSONLineWriter
    let executablePath: String
    let workingDirectoryPath: String
    let terminalStore: AgentACPTerminalStore
    let authorizationStore: AgentACPAuthorizationStore

    init(
        process: Process,
        inputPipe: Pipe,
        outputPipe: Pipe,
        errorPipe: Pipe,
        lines: AgentACPLineStream,
        errors: AgentACPTextBuffer,
        writer: AgentACPJSONLineWriter,
        executablePath: String,
        workingDirectoryPath: String,
        terminalStore: AgentACPTerminalStore,
        authorizationStore: AgentACPAuthorizationStore
    ) {
        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.lines = lines
        self.errors = errors
        self.writer = writer
        self.executablePath = executablePath
        self.workingDirectoryPath = workingDirectoryPath
        self.terminalStore = terminalStore
        self.authorizationStore = authorizationStore
    }

    func matches(_ configuration: AgentACPConfiguration) -> Bool {
        process.isRunning
            && executablePath == configuration.executableURL.path
            && workingDirectoryPath
                == configuration.workingDirectory.standardizedFileURL.path
    }

    func terminate() {
        try? writer.close()
        terminalStore.killAll()
        if process.isRunning {
            AgentProcessSupport.terminateProcessTree(process)
        }
    }
}

private actor AgentACPConnectionPool {
    static let shared = AgentACPConnectionPool()

    private struct Entry {
        let connection: AgentACPConnection
        let storedAt: Date
    }

    private let idleLifetime: TimeInterval = 15 * 60
    private let capacity = 8
    private var entries: [String: Entry] = [:]

    func take(
        sessionID: String,
        configuration: AgentACPConfiguration
    ) -> AgentACPConnection? {
        prune()
        guard let entry = entries.removeValue(forKey: sessionID) else {
            return nil
        }
        guard entry.connection.matches(configuration) else {
            entry.connection.terminate()
            return nil
        }
        return entry.connection
    }

    func store(
        sessionID: String,
        connection: AgentACPConnection
    ) {
        prune()
        if let replaced = entries.removeValue(forKey: sessionID) {
            replaced.connection.terminate()
        }
        let storedAt = Date()
        entries[sessionID] = Entry(
            connection: connection,
            storedAt: storedAt
        )
        let idleNanoseconds = UInt64(
            idleLifetime * 1_000_000_000
        )
        Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: idleNanoseconds
            )
            await self?.expire(
                sessionID: sessionID,
                storedAt: storedAt
            )
        }
        while entries.count > capacity,
              let oldest = entries.min(by: {
                $0.value.storedAt < $1.value.storedAt
              }) {
            entries.removeValue(forKey: oldest.key)?.connection.terminate()
        }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-idleLifetime)
        let expired = entries.filter { $0.value.storedAt < cutoff }
        for (sessionID, entry) in expired {
            entries.removeValue(forKey: sessionID)
            entry.connection.terminate()
        }
    }

    private func expire(sessionID: String, storedAt: Date) {
        guard let entry = entries[sessionID],
              entry.storedAt == storedAt else {
            return
        }
        entries.removeValue(forKey: sessionID)
        entry.connection.terminate()
    }
}

private nonisolated final class AgentACPJSONLineWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }

    func close() throws {
        try lock.withLock { try handle.close() }
    }
}

private nonisolated final class AgentACPLineStream: @unchecked Sendable {
    let stream: AsyncStream<String>
    private let lock = NSLock()
    private var continuation: AsyncStream<String>.Continuation?
    private var buffer = Data()
    private var isFinished = false

    /// True once `finish()` ran. The termination grace-window fallback
    /// checks this so it only force-drains when EOF genuinely never came.
    var finished: Bool {
        lock.withLock { isFinished }
    }

    init() {
        var captured: AsyncStream<String>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [String] = lock.withLock {
            guard !isFinished else { return [] }
            buffer.append(data)
            var values: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                var line = buffer[..<newline]
                if line.last == 0x0D { line = line.dropLast() }
                values.append(String(decoding: line, as: UTF8.self))
                buffer.removeSubrange(...newline)
            }
            return values
        }
        lines.filter { !$0.isEmpty }.forEach { continuation?.yield($0) }
    }

    func finish() {
        let tail: String? = lock.withLock {
            guard !isFinished else { return nil }
            isFinished = true
            let value = buffer.isEmpty
                ? nil
                : String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            return value
        }
        if let tail, !tail.isEmpty { continuation?.yield(tail) }
        continuation?.finish()
    }
}

private nonisolated final class AgentACPTextBuffer: @unchecked Sendable {
    private let limit: Int
    private let redactionValues: [String]
    private let lock = NSLock()
    private var data = Data()

    init(limit: Int, redactionValues: [String]) {
        self.limit = limit
        self.redactionValues = redactionValues
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.withLock {
            data.append(chunk)
            if data.count > limit {
                data.removeFirst(data.count - limit)
            }
        }
    }

    var stringValue: String {
        lock.withLock {
            AgentSecretStore.redact(
                String(decoding: data, as: UTF8.self),
                secretValues: redactionValues
            )
        }
    }
}

private nonisolated enum AgentACPMIMEType {
    static func forPath(_ path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }
}
