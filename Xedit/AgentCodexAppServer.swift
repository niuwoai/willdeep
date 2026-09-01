//
//  AgentCodexAppServer.swift
//  WillDeep
//
//  Bidirectional Codex app-server transport. Requests and notifications use
//  newline-delimited JSON over stdio; user prompts never enter argv.
//

import Foundation

nonisolated struct AgentCodexAppServerConfiguration: Sendable {
    let executableURL: URL
    let prompt: String
    let model: String?
    let sessionID: String?
    let imagePaths: [String]
    let workingDirectory: URL
    let environment: [String: String]
    let sandboxMode: AgentSandboxMode
    let permissionMode: String
    let secretRedactionValues: [String]
    let serverArguments: [String]

    init(
        executableURL: URL,
        prompt: String,
        model: String?,
        sessionID: String?,
        imagePaths: [String],
        workingDirectory: URL,
        environment: [String: String],
        sandboxMode: AgentSandboxMode,
        permissionMode: String,
        secretRedactionValues: [String],
        serverArguments: [String] = ["app-server", "--stdio"]
    ) {
        self.executableURL = executableURL
        self.prompt = prompt
        self.model = model
        self.sessionID = sessionID
        self.imagePaths = imagePaths
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.sandboxMode = sandboxMode
        self.permissionMode = permissionMode
        self.secretRedactionValues = secretRedactionValues
        self.serverArguments = serverArguments
    }
}

nonisolated struct AgentCodexAppServerResult: Sendable {
    let sessionID: String
    let status: AgentExecutorEventStatus
}

nonisolated enum AgentCodexAppServerError: LocalizedError {
    case invalidMessage(String)
    case protocolFailure(String)
    case processExited(Int32, String)
    case missingThreadID

    var errorDescription: String? {
        switch self {
        case .invalidMessage(let detail):
            return "Codex app-server returned invalid JSON: \(detail)"
        case .protocolFailure(let detail):
            return "Codex app-server protocol failed: \(detail)"
        case .processExited(let code, let detail):
            return "Codex app-server exited with code \(code): \(detail)"
        case .missingThreadID:
            return "Codex app-server did not return a thread id."
        }
    }
}

nonisolated final class AgentCodexAppServerTurn: @unchecked Sendable {
    typealias ApprovalHandler = @MainActor (
        AgentDelegatedApprovalRequest
    ) async -> AgentDelegatedApprovalDecision
    typealias EventHandler = @Sendable ([AgentExecutorEvent]) async -> Void
    typealias ProcessHandler = @Sendable (Int32) async -> Void

    private let configuration: AgentCodexAppServerConfiguration
    private let approvalHandler: ApprovalHandler?
    private let eventHandler: EventHandler
    private let processHandler: ProcessHandler
    private let processLock = NSLock()
    private var process: Process?

    init(
        configuration: AgentCodexAppServerConfiguration,
        approvalHandler: ApprovalHandler?,
        eventHandler: @escaping EventHandler,
        processHandler: @escaping ProcessHandler
    ) {
        self.configuration = configuration
        self.approvalHandler = approvalHandler
        self.eventHandler = eventHandler
        self.processHandler = processHandler
    }

    func cancel() {
        let runningProcess = processLock.withLock { process }
        guard let runningProcess, runningProcess.isRunning else { return }
        AgentProcessSupport.terminateProcessTree(runningProcess)
    }

    func run() async throws -> AgentCodexAppServerResult {
        try Task.checkCancellation()

        let process = Process()
        let launch = AgentSandboxPolicy.processLaunch(
            executableURL: configuration.executableURL,
            arguments: configuration.serverArguments,
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
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let lines = AgentCodexLineStream()
        let errorOutput = AgentCodexTextBuffer(
            limit: 64 * 1_024,
            secretRedactionValues: configuration.secretRedactionValues
        )
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                lines.finish()
            } else {
                lines.append(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                errorOutput.append(data)
            }
        }
        process.terminationHandler = { _ in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            lines.append(outputPipe.fileHandleForReading.availableData)
            errorOutput.append(errorPipe.fileHandleForReading.availableData)
            lines.finish()
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? inputPipe.fileHandleForWriting.close()
            throw error
        }
        processLock.withLock {
            self.process = process
        }
        await processHandler(process.processIdentifier)

        let writer = AgentCodexJSONLineWriter(
            handle: inputPipe.fileHandleForWriting
        )
        try writer.send([
            "id": "initialize",
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": AgentNetworkSupport.clientNameHeaderValue,
                    "version": Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "unknown",
                ],
                "capabilities": [
                    "experimentalApi": true,
                ],
            ],
        ])

        var activeThreadID = configuration.sessionID
        var didCompleteTurn = false
        var completionStatus = AgentExecutorEventStatus.failed

        do {
            for await line in lines.stream {
                try Task.checkCancellation()
                guard let object = AgentCodexJSON.object(from: line) else {
                    throw AgentCodexAppServerError.invalidMessage(line)
                }
                if let method = AgentCodexJSON.string(object["method"]) {
                    if object["id"] != nil {
                        try await respondToServerRequest(
                            method: method,
                            object: object,
                            writer: writer
                        )
                    } else {
                        let events = AgentCodexAppServerEventDecoder.decode(
                            method: method,
                            params: object["params"] as? [String: Any] ?? [:],
                            rawLine: line
                        )
                        if !events.isEmpty {
                            await eventHandler(redacted(events))
                        }
                        if method == "turn/completed" {
                            completionStatus = events.reversed().first {
                                $0.kind == .finished
                            }?.status ?? .completed
                            didCompleteTurn = true
                            break
                        }
                    }
                    continue
                }

                let responseID = AgentCodexJSON.string(object["id"])
                if let error = object["error"] {
                    throw AgentCodexAppServerError.protocolFailure(
                        AgentCodexJSON.pretty(error) ?? "unknown error"
                    )
                }
                switch responseID {
                case "initialize":
                    try writer.send(["method": "initialized"])
                    try writer.send(threadRequest())
                case "thread":
                    guard let threadID = Self.threadID(from: object["result"]) else {
                        throw AgentCodexAppServerError.missingThreadID
                    }
                    activeThreadID = threadID
                    await eventHandler([AgentExecutorEvent(
                        kind: .sessionStarted,
                        sessionID: threadID,
                        status: .running,
                        rawJSON: redact(line)
                    )])
                    try writer.send(turnRequest(threadID: threadID))
                default:
                    break
                }
            }
        } catch {
            try? writer.close()
            cancel()
            throw error
        }

        try? writer.close()
        cancel()
        guard didCompleteTurn else {
            let code = process.isRunning ? -1 : process.terminationStatus
            throw AgentCodexAppServerError.processExited(
                code,
                errorOutput.stringValue
            )
        }
        guard let activeThreadID, !activeThreadID.isEmpty else {
            throw AgentCodexAppServerError.missingThreadID
        }
        return AgentCodexAppServerResult(
            sessionID: activeThreadID,
            status: completionStatus
        )
    }

    private func threadRequest() -> [String: Any] {
        var params: [String: Any] = [
            "cwd": configuration.workingDirectory.path,
            "approvalPolicy": configuration.permissionMode == "plan"
                ? "never"
                : "on-request",
            "approvalsReviewer": "user",
            "sandbox": configuration.permissionMode == "plan"
                ? "read-only"
                : "workspace-write",
        ]
        if let model = configuration.model, !model.isEmpty {
            params["model"] = model
        }
        if let sessionID = configuration.sessionID, !sessionID.isEmpty {
            params["threadId"] = sessionID
            return [
                "id": "thread",
                "method": "thread/resume",
                "params": params,
            ]
        }
        return [
            "id": "thread",
            "method": "thread/start",
            "params": params,
        ]
    }

    private func turnRequest(threadID: String) -> [String: Any] {
        var input: [[String: Any]] = [
            [
                "type": "text",
                "text": configuration.prompt,
            ],
        ]
        input += configuration.imagePaths.map {
            [
                "type": "localImage",
                "path": $0,
            ]
        }
        return [
            "id": "turn",
            "method": "turn/start",
            "params": [
                "threadId": threadID,
                "input": input,
            ],
        ]
    }

    private func respondToServerRequest(
        method: String,
        object: [String: Any],
        writer: AgentCodexJSONLineWriter
    ) async throws {
        guard let requestID = object["id"] else { return }
        let params = object["params"] as? [String: Any] ?? [:]
        let request = approvalRequest(method: method, params: params)
        guard let request else {
            try writer.send([
                "id": requestID,
                "error": [
                    "code": -32601,
                    "message": "Unsupported server request: \(method)",
                ],
            ])
            return
        }

        await eventHandler([AgentExecutorEvent(
            kind: .permissionRequested,
            itemID: request.id,
            title: request.command ?? request.kind.rawValue,
            detail: request.reason ?? request.requestedPermissions,
            status: .pending
        )])
        let decision = await approvalHandler?(request) ?? .decline
        let result: [String: Any]
        if request.kind == .permissions {
            let granted = decision == .accept || decision == .acceptForSession
            result = [
                "permissions": granted
                    ? (params["permissions"] as? [String: Any] ?? [:])
                    : [:],
                "scope": decision == .acceptForSession ? "session" : "turn",
            ]
        } else {
            result = ["decision": decision.protocolValue]
        }
        try writer.send([
            "id": requestID,
            "result": result,
        ])
        await eventHandler([AgentExecutorEvent(
            kind: .permissionRequested,
            itemID: request.id,
            title: request.command ?? request.kind.rawValue,
            detail: decision.protocolValue,
            status: decision.isApproved ? .completed : .failed
        )])
    }

    private func approvalRequest(
        method: String,
        params: [String: Any]
    ) -> AgentDelegatedApprovalRequest? {
        let itemID = AgentCodexJSON.string(params["approvalId"])
            ?? AgentCodexJSON.string(params["itemId"])
            ?? UUID().uuidString
        switch method {
        case "item/commandExecution/requestApproval":
            let decisions = AgentCodexJSON.stringArray(
                params["availableDecisions"]
            )
            return AgentDelegatedApprovalRequest(
                id: itemID,
                executor: .codexCLI,
                kind: .command,
                command: AgentCodexJSON.string(params["command"]),
                cwd: AgentCodexJSON.string(params["cwd"]),
                reason: AgentCodexJSON.string(params["reason"]),
                filePaths: [],
                requestedPermissions: AgentCodexJSON.pretty(
                    params["additionalPermissions"]
                ),
                allowsSessionApproval: decisions.isEmpty
                    || decisions.contains("acceptForSession")
            )
        case "item/fileChange/requestApproval":
            return AgentDelegatedApprovalRequest(
                id: itemID,
                executor: .codexCLI,
                kind: .fileChange,
                command: nil,
                cwd: nil,
                reason: AgentCodexJSON.string(params["reason"]),
                filePaths: AgentCodexJSON.string(params["grantRoot"]).map {
                    [$0]
                } ?? [],
                requestedPermissions: nil,
                allowsSessionApproval: true
            )
        case "item/permissions/requestApproval":
            return AgentDelegatedApprovalRequest(
                id: itemID,
                executor: .codexCLI,
                kind: .permissions,
                command: nil,
                cwd: AgentCodexJSON.string(params["cwd"]),
                reason: AgentCodexJSON.string(params["reason"]),
                filePaths: [],
                requestedPermissions: AgentCodexJSON.pretty(
                    params["permissions"]
                ),
                allowsSessionApproval: true
            )
        default:
            return nil
        }
    }

    private func redacted(
        _ events: [AgentExecutorEvent]
    ) -> [AgentExecutorEvent] {
        events.map { event in
            var output = event
            output.sessionID = redactOptional(event.sessionID)
            output.itemID = redactOptional(event.itemID)
            output.parentID = redactOptional(event.parentID)
            output.title = redactOptional(event.title)
            output.detail = redactOptional(event.detail)
            output.toolName = redactOptional(event.toolName)
            output.filePath = redactOptional(event.filePath)
            output.rawJSON = redactOptional(event.rawJSON)
            return output
        }
    }

    private func redactOptional(_ text: String?) -> String? {
        text.map(redact)
    }

    private func redact(_ text: String) -> String {
        AgentSecretStore.redact(
            text,
            secretValues: configuration.secretRedactionValues
        )
    }

    private static func threadID(from result: Any?) -> String? {
        guard let result = result as? [String: Any] else { return nil }
        if let threadID = AgentCodexJSON.string(result["threadId"]) {
            return threadID
        }
        guard let thread = result["thread"] as? [String: Any] else {
            return nil
        }
        return AgentCodexJSON.string(thread["id"])
    }
}

private nonisolated extension AgentDelegatedApprovalDecision {
    var protocolValue: String {
        switch self {
        case .accept: return "accept"
        case .acceptForSession: return "acceptForSession"
        case .decline: return "decline"
        case .cancel: return "cancel"
        }
    }

    var isApproved: Bool {
        self == .accept || self == .acceptForSession
    }
}

nonisolated enum AgentCodexAppServerEventDecoder {
    static func decode(
        method: String,
        params: [String: Any],
        rawLine: String
    ) -> [AgentExecutorEvent] {
        switch method {
        case "thread/started":
            let thread = params["thread"] as? [String: Any] ?? [:]
            return [AgentExecutorEvent(
                kind: .sessionStarted,
                sessionID: AgentCodexJSON.string(thread["id"])
                    ?? AgentCodexJSON.string(params["threadId"]),
                status: .running,
                rawJSON: rawLine
            )]
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any] else {
                return []
            }
            return itemEvents(
                item: item,
                completed: method == "item/completed",
                rawLine: rawLine
            )
        case "item/agentMessage/delta":
            return [deltaEvent(
                kind: .message,
                params: params,
                detail: AgentCodexJSON.string(params["delta"]),
                rawLine: rawLine
            )]
        case "item/reasoning/summaryTextDelta",
             "item/reasoning/textDelta":
            return [deltaEvent(
                kind: .thinking,
                params: params,
                detail: AgentCodexJSON.string(params["delta"]),
                rawLine: rawLine
            )]
        case "item/commandExecution/outputDelta":
            return [deltaEvent(
                kind: .toolUpdated,
                params: params,
                detail: AgentCodexJSON.string(params["delta"]),
                rawLine: rawLine,
                toolName: "command_execution"
            )]
        case "thread/tokenUsage/updated":
            let tokenUsage = params["tokenUsage"] as? [String: Any] ?? [:]
            let last = tokenUsage["last"] as? [String: Any] ?? tokenUsage
            let usage = usage(from: last)
            return usage.isEmpty ? [] : [AgentExecutorEvent(
                kind: .usage,
                sessionID: AgentCodexJSON.string(params["threadId"]),
                usage: usage,
                rawJSON: rawLine
            )]
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            let statusText = AgentCodexJSON.string(turn["status"]) ?? "completed"
            let status: AgentExecutorEventStatus
            switch statusText {
            case "completed": status = .completed
            case "interrupted": status = .cancelled
            default: status = .failed
            }
            let error = AgentCodexJSON.pretty(turn["error"])
                ?? AgentCodexJSON.pretty(params["error"])
            var events: [AgentExecutorEvent] = []
            if let error, !error.isEmpty {
                events.append(AgentExecutorEvent(
                    kind: .warning,
                    detail: error,
                    status: .failed,
                    rawJSON: rawLine
                ))
            }
            events.append(AgentExecutorEvent(
                kind: .finished,
                sessionID: AgentCodexJSON.string(params["threadId"]),
                itemID: AgentCodexJSON.string(turn["id"]),
                detail: error,
                status: status,
                rawJSON: rawLine
            ))
            return events
        case "error":
            return [AgentExecutorEvent(
                kind: .warning,
                detail: AgentCodexJSON.string(params["message"])
                    ?? AgentCodexJSON.pretty(params),
                status: .failed,
                rawJSON: rawLine
            )]
        default:
            return []
        }
    }

    private static func itemEvents(
        item: [String: Any],
        completed: Bool,
        rawLine: String
    ) -> [AgentExecutorEvent] {
        let type = AgentCodexJSON.string(item["type"]) ?? ""
        let itemID = AgentCodexJSON.string(item["id"])
        let status: AgentExecutorEventStatus = completed ? .completed : .running
        switch type {
        case "agentMessage":
            return [AgentExecutorEvent(
                kind: .message,
                itemID: itemID,
                detail: AgentCodexJSON.string(item["text"]),
                status: status,
                rawJSON: rawLine
            )]
        case "reasoning":
            return [AgentExecutorEvent(
                kind: .thinking,
                itemID: itemID,
                detail: AgentCodexJSON.textContent(item["summary"])
                    ?? AgentCodexJSON.textContent(item["content"]),
                status: status,
                rawJSON: rawLine
            )]
        case "commandExecution":
            let exitCode = AgentCodexJSON.int(item["exitCode"])
            return [AgentExecutorEvent(
                kind: completed ? .toolUpdated : .toolStarted,
                itemID: itemID,
                title: AgentCodexJSON.string(item["command"]),
                detail: AgentCodexJSON.string(item["aggregatedOutput"]),
                status: exitCode.map { $0 == 0 ? status : .failed } ?? status,
                toolName: "command_execution",
                rawJSON: rawLine
            )]
        case "fileChange":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let paths = changes.compactMap {
                AgentCodexJSON.string($0["path"])
            }
            if !paths.isEmpty {
                return paths.map { path in
                    AgentExecutorEvent(
                        kind: .fileChanged,
                        itemID: itemID,
                        status: status,
                        filePath: path,
                        rawJSON: rawLine
                    )
                }
            }
            return [AgentExecutorEvent(
                kind: .fileChanged,
                itemID: itemID,
                status: status,
                rawJSON: rawLine
            )]
        case "mcpToolCall", "collabToolCall":
            let toolName = AgentCodexJSON.string(item["tool"])
                ?? AgentCodexJSON.string(item["name"])
            return [AgentExecutorEvent(
                kind: completed ? .toolUpdated : .toolStarted,
                itemID: itemID,
                title: toolName,
                detail: AgentCodexJSON.pretty(
                    item["result"] ?? item["arguments"]
                ),
                status: status,
                toolName: toolName,
                rawJSON: rawLine
            )]
        case "error":
            return [AgentExecutorEvent(
                kind: .warning,
                itemID: itemID,
                detail: AgentCodexJSON.string(item["message"]),
                status: .failed,
                rawJSON: rawLine
            )]
        default:
            return []
        }
    }

    private static func deltaEvent(
        kind: AgentExecutorEventKind,
        params: [String: Any],
        detail: String?,
        rawLine: String,
        toolName: String? = nil
    ) -> AgentExecutorEvent {
        AgentExecutorEvent(
            kind: kind,
            sessionID: AgentCodexJSON.string(params["threadId"]),
            itemID: AgentCodexJSON.string(params["itemId"]),
            detail: detail,
            status: .running,
            toolName: toolName,
            rawJSON: rawLine
        )
    }

    private static func usage(from value: [String: Any]) -> AgentExecutorUsage {
        AgentExecutorUsage(
            inputTokens: AgentCodexJSON.int(value["inputTokens"]),
            cachedInputTokens: AgentCodexJSON.int(value["cachedInputTokens"]),
            outputTokens: AgentCodexJSON.int(value["outputTokens"]),
            costUSD: AgentCodexJSON.double(value["costUsd"]),
            durationMilliseconds: nil
        )
    }
}

private nonisolated final class AgentCodexJSONLineWriter: @unchecked Sendable {
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
        lock.lock()
        defer { lock.unlock() }
        try handle.close()
    }
}

private nonisolated final class AgentCodexLineStream: @unchecked Sendable {
    let stream: AsyncStream<String>
    private let lock = NSLock()
    private var continuation: AsyncStream<String>.Continuation?
    private var buffer = Data()
    private var isFinished = false

    init() {
        var captured: AsyncStream<String>.Continuation?
        stream = AsyncStream { continuation in
            captured = continuation
        }
        continuation = captured
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8),
               !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(line)
            }
        }
        let continuation = continuation
        lock.unlock()
        for line in lines {
            continuation?.yield(line)
        }
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let finalLine = String(data: buffer, encoding: .utf8)
        buffer.removeAll()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        if let finalLine,
           !finalLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            continuation?.yield(finalLine)
        }
        continuation?.finish()
    }
}

private nonisolated final class AgentCodexTextBuffer: @unchecked Sendable {
    private let limit: Int
    private let secretRedactionValues: [String]
    private let lock = NSLock()
    private var data = Data()

    init(limit: Int, secretRedactionValues: [String]) {
        self.limit = limit
        self.secretRedactionValues = secretRedactionValues
    }

    func append(_ value: Data) {
        guard !value.isEmpty else { return }
        lock.lock()
        let remaining = max(0, limit - data.count)
        data.append(value.prefix(remaining))
        lock.unlock()
    }

    var stringValue: String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return AgentSecretStore.redact(
            String(data: snapshot, encoding: .utf8) ?? "",
            secretValues: secretRedactionValues
        )
    }
}

private nonisolated enum AgentCodexJSON {
    static func object(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
              ) else {
            return nil
        }
        return value as? [String: Any]
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        default: return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: return value
        case let value as NSNumber: return value.intValue
        case let value as String: return Int(value)
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: return value
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }

    static func stringArray(_ value: Any?) -> [String] {
        if let strings = value as? [String] {
            return strings
        }
        if let values = value as? [Any] {
            return values.compactMap(string)
        }
        return string(value).map { [$0] } ?? []
    }

    static func textContent(_ value: Any?) -> String? {
        if let value = string(value) {
            return value
        }
        guard let values = value as? [Any] else {
            return pretty(value)
        }
        let parts = values.compactMap { entry -> String? in
            guard let object = entry as? [String: Any] else {
                return string(entry)
            }
            return string(object["text"]) ?? pretty(object)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    static func pretty(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let value = value as? String {
            return value
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys]
              ) else {
            return "\(value)"
        }
        return String(data: data, encoding: .utf8)
    }
}
