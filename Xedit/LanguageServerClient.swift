//
//  LanguageServerClient.swift
//  WillDeep
//
//  Process-backed JSON-RPC client for first-stage LSP integration.
//

import Foundation

nonisolated enum LanguageServerClientError: Error, Equatable {
    case missingLanguageID
    case serverUnavailable(String)
    case unsupportedCapability(String)
    case responseError(code: Int, message: String)
    case malformedResponse
}

nonisolated protocol LanguageServerTransport: AnyObject {
    var onData: ((Data) -> Void)? { get set }
    var onTermination: ((Int32) -> Void)? { get set }

    func start() throws
    func send(_ data: Data) throws
    func stop()
}

nonisolated final class ProcessLanguageServerTransport: LanguageServerTransport {
    var onData: ((Data) -> Void)?
    var onTermination: ((Int32) -> Void)?

    private let executableURL: URL
    private let arguments: [String]
    private let currentDirectoryURL: URL
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()

    init(executableURL: URL, arguments: [String], currentDirectoryURL: URL) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
    }

    func start() throws {
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.onData?(data)
        }
        process.terminationHandler = { [weak self] process in
            self?.outputPipe.fileHandleForReading.readabilityHandler = nil
            self?.onTermination?(process.terminationStatus)
        }

        try process.run()
    }

    func send(_ data: Data) throws {
        inputPipe.fileHandleForWriting.write(data)
    }

    func stop() {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }
}

nonisolated enum LanguageServerExecutableResolver {
    static func resolve(_ configuration: EditorLanguageServerConfiguration) -> URL? {
        for candidate in configuration.executableCandidates {
            if candidate.contains("/") {
                let url = URL(fileURLWithPath: candidate)
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    return url
                }
                continue
            }

            if let url = executableURL(named: candidate) {
                return url
            }
        }
        return nil
    }

    private static func executableURL(named name: String) -> URL? {
        let pathValues = [
            ProcessInfo.processInfo.environment["PATH"],
            "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        ].compactMap { $0 }

        for pathValue in pathValues {
            for directory in pathValue.split(separator: ":") {
                let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }
}

actor LanguageServerClient {
    typealias DiagnosticsHandler = @Sendable (String, [LSPDiagnostic]) -> Void
    typealias ApplyEditHandler = @Sendable (LSPApplyWorkspaceEditParams) async -> LSPApplyWorkspaceEditResponse

    private let configuration: EditorLanguageServerConfiguration
    private let transport: LanguageServerTransport
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var receiveBuffer = Data()
    private var nextRequestID = 1
    private var pendingResponses: [Int: (Result<Data, Error>) -> Void] = [:]
    private var diagnosticsByURI: [String: [LSPDiagnostic]] = [:]
    private var diagnosticsHandler: DiagnosticsHandler?
    private var rootURL: URL?
    private var semanticTokensLegend: LSPSemanticTokensLegend?
    private var supportsFoldingRanges = false
    private var supportsSignatureHelp = false
    private var supportsCodeActions = false
    private var supportsDocumentHighlights = false
    private var supportsDocumentSymbols = false
    private var supportsDocumentLinks = false
    private var supportsCodeActionResolve = false
    private var supportsDocumentLinkResolve = false
    private var supportsInlayHints = false
    private var supportsInlayHintResolve = false
    private var supportsDeclaration = false
    private var supportsTypeDefinition = false
    private var supportsImplementation = false
    private var supportsWorkspaceSymbols = false
    private var supportsSelectionRanges = false
    private var supportsCallHierarchy = false
    private var supportsDocumentRangeFormatting = false
    private var supportsPrepareRename = false
    private var supportsDocumentSave = false
    private var supportsWillSaveWaitUntil = false
    private var documentSaveIncludesText = false
    private var supportsCompletionResolve = false
    private var executableCommands: Set<String> = []
    private var applyEditHandler: ApplyEditHandler?

    init(configuration: EditorLanguageServerConfiguration, transport: LanguageServerTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    func start() throws {
        transport.onData = { [weak self] data in
            guard let self else { return }
            Task {
                await self.receive(data)
            }
        }
        transport.onTermination = { [weak self] status in
            guard let self else { return }
            Task {
                await self.failPending(LanguageServerClientError.serverUnavailable("Language server exited with status \(status)."))
            }
        }
        try transport.start()
    }

    func stop() {
        transport.stop()
    }

    func setDiagnosticsHandler(_ handler: DiagnosticsHandler?) {
        diagnosticsHandler = handler
    }

    func setApplyEditHandler(_ handler: ApplyEditHandler?) {
        applyEditHandler = handler
    }

    func initialize(rootURL: URL) async throws {
        self.rootURL = rootURL
        let params = LSPInitializeParams(
            processId: Int(ProcessInfo.processInfo.processIdentifier),
            rootUri: rootURL.absoluteString,
            capabilities: LSPClientCapabilities()
        )
        let result: LSPInitializeResult = try await sendRequest(method: "initialize", params: params)
        supportsDocumentSave = result.capabilities?.textDocumentSync?.supportsSave == true
        supportsWillSaveWaitUntil = result.capabilities?.textDocumentSync?.willSaveWaitUntil == true
        documentSaveIncludesText = result.capabilities?.textDocumentSync?.saveIncludesText == true
        semanticTokensLegend = result.capabilities?.semanticTokensProvider?.legend
        supportsFoldingRanges = result.capabilities?.foldingRangeProvider?.isSupported == true
        supportsSignatureHelp = result.capabilities?.signatureHelpProvider?.isSupported == true
        supportsCodeActions = result.capabilities?.codeActionProvider?.isSupported == true
        supportsCodeActionResolve = result.capabilities?.codeActionProvider?.resolveProvider == true
        supportsDocumentHighlights = result.capabilities?.documentHighlightProvider?.isSupported == true
        supportsDocumentSymbols = result.capabilities?.documentSymbolProvider?.isSupported == true
        supportsDocumentLinks = result.capabilities?.documentLinkProvider?.isSupported == true
        supportsDocumentLinkResolve = result.capabilities?.documentLinkProvider?.resolveProvider == true
        supportsInlayHints = result.capabilities?.inlayHintProvider?.isSupported == true
        supportsInlayHintResolve = result.capabilities?.inlayHintProvider?.resolveProvider == true
        supportsDeclaration = result.capabilities?.declarationProvider?.isSupported == true
        supportsTypeDefinition = result.capabilities?.typeDefinitionProvider?.isSupported == true
        supportsImplementation = result.capabilities?.implementationProvider?.isSupported == true
        supportsWorkspaceSymbols = result.capabilities?.workspaceSymbolProvider?.isSupported == true
        supportsSelectionRanges = result.capabilities?.selectionRangeProvider?.isSupported == true
        supportsCallHierarchy = result.capabilities?.callHierarchyProvider?.isSupported == true
        supportsDocumentRangeFormatting = result.capabilities?.documentRangeFormattingProvider?.isSupported == true
        supportsPrepareRename = result.capabilities?.renameProvider?.prepareProvider == true
        supportsCompletionResolve = result.capabilities?.completionProvider?.resolveProvider == true
        executableCommands = Set(result.capabilities?.executeCommandProvider?.commands ?? [])
        try sendNotification(method: "initialized", params: LSPInitializedParams())
    }

    func openDocument(url: URL, language: Language, version: Int, text: String) throws {
        guard let languageID = language.lspLanguageID else {
            throw LanguageServerClientError.missingLanguageID
        }
        try sendNotification(
            method: "textDocument/didOpen",
            params: LSPDidOpenTextDocumentParams(
                textDocument: LSPTextDocumentItem(
                    uri: url.absoluteString,
                    languageId: languageID,
                    version: version,
                    text: text
                )
            )
        )
    }

    func changeDocument(url: URL, version: Int, text: String) throws {
        try sendNotification(
            method: "textDocument/didChange",
            params: LSPDidChangeTextDocumentParams(
                textDocument: LSPVersionedTextDocumentIdentifier(uri: url.absoluteString, version: version),
                contentChanges: [LSPTextDocumentContentChangeEvent(text: text)]
            )
        )
    }

    func closeDocument(url: URL) throws {
        try sendNotification(
            method: "textDocument/didClose",
            params: LSPDidCloseTextDocumentParams(textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString))
        )
    }

    func saveDocument(url: URL, text: String) throws {
        guard supportsDocumentSave else { return }
        try sendNotification(
            method: "textDocument/didSave",
            params: LSPDidSaveTextDocumentParams(
                textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString),
                text: documentSaveIncludesText ? text : nil
            )
        )
    }

    func willSaveWaitUntil(url: URL) async throws -> [LSPTextEdit] {
        guard supportsWillSaveWaitUntil else { return [] }
        let result: LSPTextEditResult = try await sendRequest(
            method: "textDocument/willSaveWaitUntil",
            params: LSPWillSaveTextDocumentParams(
                textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString),
                reason: 1
            )
        )
        return result.edits
    }

    func didChangeWatchedFiles(changes: [LSPFileEvent]) throws {
        guard !changes.isEmpty else { return }
        try sendNotification(
            method: "workspace/didChangeWatchedFiles",
            params: LSPDidChangeWatchedFilesParams(changes: changes)
        )
    }

    func hover(url: URL, position: LSPPosition) async throws -> LSPHover? {
        try await sendRequest(
            method: "textDocument/hover",
            params: LSPTextDocumentPositionParams(
                textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString),
                position: position
            )
        )
    }

    func definition(url: URL, position: LSPPosition) async throws -> [LSPLocation] {
        let result: LSPDefinitionResult = try await sendRequest(
            method: "textDocument/definition",
            params: LSPTextDocumentPositionParams(
                textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString),
                position: position
            )
        )
        return result.locations
    }

    func declaration(url: URL, position: LSPPosition) async throws -> [LSPLocation] {
        guard supportsDeclaration else { return [] }
        let result: LSPDefinitionResult = try await sendRequest(
            method: "textDocument/declaration",
            params: LSPTextDocumentPositionParams(
                textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString),
                position: position
            )
        )
        return result.locations
    }

    func typeDefinition(url: URL, position: LSPPosition) async throws -> [LSPLocation] {
        guard supportsTypeDefinition else { return [] }
        let result: LSPDefinitionResult = try await sendRequest(
            method: "textDocument/typeDefinition",
            params: LSPTextDocumentPositionParams(
                textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString),
                position: position
            )
        )
        return result.locations
    }

    func implementation(url: URL, position: LSPPosition) async throws -> [LSPLocation] {
        guard supportsImplementation else { return [] }
        let result: LSPDefinitionResult = try await sendRequest(
            method: "textDocument/implementation",
            params: LSPTextDocumentPositionParams(
                textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString),
                position: position
            )
        )
        return result.locations
    }

    func references(url: URL, position: LSPPosition, includeDeclaration: Bool = true) async throws -> [LSPLocation] {
        let result: LSPDefinitionResult = try await sendRequest(
            method: "textDocument/references",
            params: LSPReferenceParams(
                textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString),
                position: position,
                context: LSPReferenceParams.Context(includeDeclaration: includeDeclaration)
            )
        )
        return result.locations
    }

    func documentSymbols(url: URL) async throws -> [LSPDocumentSymbol] {
        guard supportsDocumentSymbols else { return [] }
        let result: LSPDocumentSymbolResult = try await sendRequest(
            method: "textDocument/documentSymbol",
            params: LSPDocumentSymbolParams(textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString))
        )
        return result.documentSymbols
    }

    func documentLinks(url: URL) async throws -> [LSPDocumentLink] {
        guard supportsDocumentLinks else { return [] }
        let result: LSPDocumentLinkResult = try await sendRequest(
            method: "textDocument/documentLink",
            params: LSPDocumentLinkParams(textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString))
        )
        return result.links
    }

    func resolveDocumentLink(_ link: LSPDocumentLink) async throws -> LSPDocumentLink {
        guard supportsDocumentLinkResolve else { return link }
        return try await sendRequest(method: "documentLink/resolve", params: link)
    }

    func workspaceSymbols(query: String) async throws -> [LSPWorkspaceSymbol] {
        guard supportsWorkspaceSymbols else { return [] }
        let result: LSPWorkspaceSymbolResult = try await sendRequest(
            method: "workspace/symbol",
            params: LSPWorkspaceSymbolParams(query: query)
        )
        return result.symbols
    }

    func completion(url: URL, position: LSPPosition) async throws -> [LSPCompletionItem] {
        let result: LSPCompletionResult = try await sendRequest(
            method: "textDocument/completion",
            params: LSPTextDocumentPositionParams(
                textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString),
                position: position
            )
        )
        return result.items
    }

    func resolveCompletionItem(_ item: LSPCompletionItem) async throws -> LSPCompletionItem {
        guard supportsCompletionResolve else { return item }
        return try await sendRequest(method: "completionItem/resolve", params: item)
    }

    func signatureHelp(url: URL, position: LSPPosition) async throws -> LSPSignatureHelp? {
        guard supportsSignatureHelp else { return nil }
        return try await sendRequest(
            method: "textDocument/signatureHelp",
            params: LSPSignatureHelpParams(
                textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString),
                position: position
            )
        )
    }

    func selectionRanges(url: URL, position: LSPPosition) async throws -> [LSPSelectionRange] {
        guard supportsSelectionRanges else { return [] }
        let result: LSPSelectionRangeResult = try await sendRequest(
            method: "textDocument/selectionRange",
            params: LSPSelectionRangeParams(
                textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString),
                positions: [position]
            )
        )
        return result.ranges
    }

    func prepareCallHierarchy(url: URL, position: LSPPosition) async throws -> [LSPCallHierarchyItem] {
        guard supportsCallHierarchy else { return [] }
        let result: LSPCallHierarchyItemResult = try await sendRequest(
            method: "textDocument/prepareCallHierarchy",
            params: LSPCallHierarchyPrepareParams(
                textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString),
                position: position
            )
        )
        return result.items
    }

    func incomingCallHierarchy(item: LSPCallHierarchyItem) async throws -> [LSPCallHierarchyIncomingCall] {
        guard supportsCallHierarchy else { return [] }
        let result: LSPCallHierarchyIncomingCallResult = try await sendRequest(
            method: "callHierarchy/incomingCalls",
            params: LSPCallHierarchyItemParams(item: item)
        )
        return result.calls
    }

    func outgoingCallHierarchy(item: LSPCallHierarchyItem) async throws -> [LSPCallHierarchyOutgoingCall] {
        guard supportsCallHierarchy else { return [] }
        let result: LSPCallHierarchyOutgoingCallResult = try await sendRequest(
            method: "callHierarchy/outgoingCalls",
            params: LSPCallHierarchyItemParams(item: item)
        )
        return result.calls
    }

    func documentHighlights(url: URL, position: LSPPosition) async throws -> [LSPDocumentHighlight] {
        guard supportsDocumentHighlights else { return [] }
        let result: LSPDocumentHighlightResult = try await sendRequest(
            method: "textDocument/documentHighlight",
            params: LSPTextDocumentPositionParams(
                textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString),
                position: position
            )
        )
        return result.highlights
    }

    func inlayHints(url: URL, range: LSPRange) async throws -> [LSPInlayHint] {
        guard supportsInlayHints else { return [] }
        let result: LSPInlayHintResult = try await sendRequest(
            method: "textDocument/inlayHint",
            params: LSPInlayHintParams(
                textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString),
                range: range
            )
        )
        return result.hints
    }

    func resolveInlayHint(_ hint: LSPInlayHint) async throws -> LSPInlayHint {
        guard supportsInlayHintResolve else { return hint }
        return try await sendRequest(method: "inlayHint/resolve", params: hint)
    }

    func semanticTokens(url: URL) async throws -> LSPSemanticTokens? {
        guard semanticTokensLegend != nil else { return nil }
        return try await sendRequest(
            method: "textDocument/semanticTokens/full",
            params: LSPSemanticTokensParams(textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString))
        )
    }

    func foldingRanges(url: URL) async throws -> [LSPFoldingRange] {
        guard supportsFoldingRanges else { return [] }
        let result: LSPFoldingRangeResult = try await sendRequest(
            method: "textDocument/foldingRange",
            params: LSPFoldingRangeParams(textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString))
        )
        return result.ranges
    }

    func documentFormatting(url: URL, options: LSPFormattingOptions) async throws -> [LSPTextEdit] {
        let result: LSPTextEditResult = try await sendRequest(
            method: "textDocument/formatting",
            params: LSPDocumentFormattingParams(
                textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString),
                options: options
            )
        )
        return result.edits
    }

    func documentRangeFormatting(url: URL, range: LSPRange, options: LSPFormattingOptions) async throws -> [LSPTextEdit] {
        guard supportsDocumentRangeFormatting else { return [] }
        let result: LSPTextEditResult = try await sendRequest(
            method: "textDocument/rangeFormatting",
            params: LSPDocumentRangeFormattingParams(
                textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString),
                range: range,
                options: options
            )
        )
        return result.edits
    }

    func rename(url: URL, position: LSPPosition, newName: String) async throws -> LSPWorkspaceEdit {
        try await sendRequest(
            method: "textDocument/rename",
            params: LSPRenameParams(
                textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString),
                position: position,
                newName: newName
            )
        )
    }

    func prepareRename(url: URL, position: LSPPosition) async throws -> LSPPrepareRenameResult {
        guard supportsPrepareRename else {
            throw LanguageServerClientError.unsupportedCapability("textDocument/prepareRename")
        }
        return try await sendRequest(
            method: "textDocument/prepareRename",
            params: LSPTextDocumentPositionParams(
                textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString),
                position: position
            )
        )
    }

    func codeActions(url: URL, range: LSPRange, diagnostics: [LSPDiagnostic]) async throws -> [LSPCodeAction] {
        guard supportsCodeActions else { return [] }
        let result: LSPCodeActionResult = try await sendRequest(
            method: "textDocument/codeAction",
            params: LSPCodeActionParams(
                textDocument: LSPTextDocumentIdentifier(uri: url.absoluteString),
                range: range,
                context: LSPCodeActionContext(diagnostics: diagnostics)
            )
        )
        return result.actions
    }

    func resolveCodeAction(_ action: LSPCodeAction) async throws -> LSPCodeAction {
        guard supportsCodeActionResolve else { return action }
        return try await sendRequest(method: "codeAction/resolve", params: action)
    }

    func executeCommand(_ command: LSPCommand) async throws {
        guard executableCommands.contains(command.command) else {
            throw LanguageServerClientError.unsupportedCapability("workspace/executeCommand \(command.command)")
        }
        try await sendRequestIgnoringResult(
            method: "workspace/executeCommand",
            params: LSPExecuteCommandParams(command: command.command, arguments: command.arguments)
        )
    }

    func semanticTokensLegendValue() -> LSPSemanticTokensLegend? {
        semanticTokensLegend
    }

    func diagnostics(for url: URL) -> [LSPDiagnostic] {
        diagnosticsByURI[url.absoluteString] ?? []
    }

    private func sendRequest<Params: Encodable, ResultType: Decodable>(
        method: String,
        params: Params
    ) async throws -> ResultType {
        let id = nextRequestID
        nextRequestID += 1
        let envelope = LSPRequestEnvelope(id: id, method: method, params: params)
        let data = try LSPMessageFramer.encodeMessage(envelope, encoder: encoder)

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[id] = { payloadResult in
                do {
                    let payload = try payloadResult.get()
                    let response = try self.decoder.decode(LSPResponseEnvelope<ResultType>.self, from: payload)
                    if let error = response.error {
                        continuation.resume(throwing: LanguageServerClientError.responseError(code: error.code, message: error.message))
                    } else if let result = response.result {
                        continuation.resume(returning: result)
                    } else {
                        continuation.resume(throwing: LanguageServerClientError.malformedResponse)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            do {
                try transport.send(data)
            } catch {
                pendingResponses.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification<Params: Encodable>(method: String, params: Params) throws {
        let envelope = LSPNotificationEnvelope(method: method, params: params)
        try transport.send(LSPMessageFramer.encodeMessage(envelope, encoder: encoder))
    }

    private func sendRequestIgnoringResult<Params: Encodable>(
        method: String,
        params: Params
    ) async throws {
        let id = nextRequestID
        nextRequestID += 1
        let envelope = LSPRequestEnvelope(id: id, method: method, params: params)
        let data = try LSPMessageFramer.encodeMessage(envelope, encoder: encoder)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingResponses[id] = { payloadResult in
                do {
                    let payload = try payloadResult.get()
                    let response = try self.decoder.decode(LSPResponseEnvelope<LSPAnyValue>.self, from: payload)
                    if let error = response.error {
                        continuation.resume(throwing: LanguageServerClientError.responseError(code: error.code, message: error.message))
                    } else {
                        continuation.resume()
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            do {
                try transport.send(data)
            } catch {
                pendingResponses.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendResponse<Result: Encodable>(id: Int, result: Result) throws {
        let envelope = LSPResultResponseEnvelope(id: id, result: result)
        try transport.send(LSPMessageFramer.encodeMessage(envelope, encoder: encoder))
    }

    private func receive(_ data: Data) {
        receiveBuffer.append(data)
        for payload in LSPMessageFramer.extractMessages(from: &receiveBuffer) {
            handle(payload)
        }
    }

    private func handle(_ payload: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return
        }

        if let id = object["id"] as? Int, let callback = pendingResponses.removeValue(forKey: id) {
            callback(.success(payload))
            return
        }

        guard let method = object["method"] as? String else { return }
        if method == "textDocument/publishDiagnostics",
           let params = object["params"] as? [String: Any],
           let paramsData = try? JSONSerialization.data(withJSONObject: params),
           let diagnostics = try? decoder.decode(LSPPublishDiagnosticsParams.self, from: paramsData) {
            diagnosticsByURI[diagnostics.uri] = diagnostics.diagnostics
            diagnosticsHandler?(diagnostics.uri, diagnostics.diagnostics)
            return
        }

        if method == "workspace/applyEdit",
           let id = object["id"] as? Int,
           let params = object["params"] as? [String: Any],
           let paramsData = try? JSONSerialization.data(withJSONObject: params),
           let applyEdit = try? decoder.decode(LSPApplyWorkspaceEditParams.self, from: paramsData) {
            let handler = applyEditHandler
            Task {
                let response: LSPApplyWorkspaceEditResponse
                if let handler {
                    response = await handler(applyEdit)
                } else {
                    response = LSPApplyWorkspaceEditResponse(
                        applied: false,
                        failureReason: "workspace/applyEdit is not configured."
                    )
                }
                try? self.sendResponse(id: id, result: response)
            }
            return
        }

        if method == "workspace/configuration",
           let id = object["id"] as? Int {
            let itemCount: Int
            if let params = object["params"] as? [String: Any],
               let paramsData = try? JSONSerialization.data(withJSONObject: params),
               let configuration = try? decoder.decode(LSPWorkspaceConfigurationParams.self, from: paramsData) {
                itemCount = configuration.items.count
            } else {
                itemCount = 0
            }
            let result = Array(repeating: LSPAnyValue.object([:]), count: itemCount)
            try? sendResponse(id: id, result: result)
            return
        }

        if method == "workspace/workspaceFolders",
           let id = object["id"] as? Int {
            let folders: [LSPWorkspaceFolder]
            if let rootURL {
                folders = [LSPWorkspaceFolder(uri: rootURL.absoluteString, name: rootURL.lastPathComponent)]
            } else {
                folders = []
            }
            try? sendResponse(id: id, result: folders)
            return
        }
    }

    private func failPending(_ error: Error) {
        let callbacks = pendingResponses.values
        pendingResponses.removeAll()
        callbacks.forEach { $0(.failure(error)) }
    }
}

nonisolated struct LSPInitializeParams: Encodable, Equatable, Sendable {
    let processId: Int
    let rootUri: String
    let capabilities: LSPClientCapabilities
}

nonisolated struct LSPClientCapabilities: Encodable, Equatable, Sendable {
    let textDocument = LSPTextDocumentClientCapabilities()
    let workspace = LSPWorkspaceClientCapabilities()
}

nonisolated struct LSPTextDocumentClientCapabilities: Encodable, Equatable, Sendable {
    let synchronization = LSPTextDocumentSyncClientCapabilities()
    let hover = LSPDynamicRegistrationCapability(dynamicRegistration: false)
    let declaration = LSPDynamicRegistrationCapability(dynamicRegistration: false)
    let definition = LSPDynamicRegistrationCapability(dynamicRegistration: false)
    let typeDefinition = LSPDynamicRegistrationCapability(dynamicRegistration: false)
    let implementation = LSPDynamicRegistrationCapability(dynamicRegistration: false)
    let references = LSPDynamicRegistrationCapability(dynamicRegistration: false)
    let formatting = LSPDynamicRegistrationCapability(dynamicRegistration: false)
    let rangeFormatting = LSPDynamicRegistrationCapability(dynamicRegistration: false)
    let rename = LSPRenameClientCapabilities(dynamicRegistration: false, prepareSupport: true)
    let documentSymbol = LSPDynamicRegistrationCapability(dynamicRegistration: false)
    let completion = LSPCompletionClientCapabilities()
    let signatureHelp = LSPDynamicRegistrationCapability(dynamicRegistration: false)
    let codeAction = LSPDynamicRegistrationCapability(dynamicRegistration: false)
    let documentHighlight = LSPDynamicRegistrationCapability(dynamicRegistration: false)
    let inlayHint = LSPDynamicRegistrationCapability(dynamicRegistration: false)
    let selectionRange = LSPDynamicRegistrationCapability(dynamicRegistration: false)
    let callHierarchy = LSPDynamicRegistrationCapability(dynamicRegistration: false)
    let semanticTokens = LSPSemanticTokensClientCapabilities()
    let foldingRange = LSPDynamicRegistrationCapability(dynamicRegistration: false)
}

nonisolated struct LSPWorkspaceClientCapabilities: Encodable, Equatable, Sendable {
    let workspaceFolders = true
    let configuration = true
    let symbol = LSPDynamicRegistrationCapability(dynamicRegistration: false)
    let didChangeWatchedFiles = LSPDynamicRegistrationCapability(dynamicRegistration: false)
}

nonisolated struct LSPTextDocumentSyncClientCapabilities: Encodable, Equatable, Sendable {
    let didSave = true
}

nonisolated struct LSPDynamicRegistrationCapability: Codable, Equatable, Sendable {
    let dynamicRegistration: Bool
}

nonisolated struct LSPRenameClientCapabilities: Encodable, Equatable, Sendable {
    let dynamicRegistration: Bool
    let prepareSupport: Bool
}

nonisolated struct LSPCompletionClientCapabilities: Encodable, Equatable, Sendable {
    let dynamicRegistration = false
    let completionItem = LSPCompletionItemClientCapabilities()
}

nonisolated struct LSPCompletionItemClientCapabilities: Encodable, Equatable, Sendable {
    let snippetSupport = true
    let additionalTextEditsSupport = true
}

nonisolated struct LSPSemanticTokensClientCapabilities: Encodable, Equatable, Sendable {
    let dynamicRegistration = false
    let requests = LSPSemanticTokensRequestsCapability()
    let tokenTypes = [
        "namespace", "type", "class", "enum", "interface", "struct", "typeParameter",
        "parameter", "variable", "property", "enumMember", "event", "function", "method",
        "macro", "keyword", "modifier", "comment", "string", "number", "regexp",
        "operator", "decorator"
    ]
    let tokenModifiers = [
        "declaration", "definition", "readonly", "static", "deprecated", "abstract",
        "async", "modification", "documentation", "defaultLibrary"
    ]
    let formats = ["relative"]
    let overlappingTokenSupport = false
    let multilineTokenSupport = true
}

nonisolated struct LSPSemanticTokensRequestsCapability: Encodable, Equatable, Sendable {
    let range = false
    let full = true
}

nonisolated struct LSPInitializeResult: Codable, Equatable, Sendable {
    let capabilities: LSPServerCapabilities?
}

nonisolated struct LSPServerCapabilities: Codable, Equatable, Sendable {
    let textDocumentSync: LSPTextDocumentSyncProvider?
    let hoverProvider: LSPProviderCapability?
    let declarationProvider: LSPProviderCapability?
    let definitionProvider: LSPProviderCapability?
    let typeDefinitionProvider: LSPProviderCapability?
    let implementationProvider: LSPProviderCapability?
    let referencesProvider: LSPProviderCapability?
    let documentFormattingProvider: LSPProviderCapability?
    let documentRangeFormattingProvider: LSPProviderCapability?
    let renameProvider: LSPProviderCapability?
    let documentSymbolProvider: LSPProviderCapability?
    let documentLinkProvider: LSPProviderCapability?
    let completionProvider: LSPCompletionProvider?
    let signatureHelpProvider: LSPProviderCapability?
    let codeActionProvider: LSPProviderCapability?
    let documentHighlightProvider: LSPProviderCapability?
    let inlayHintProvider: LSPProviderCapability?
    let semanticTokensProvider: LSPSemanticTokensProvider?
    let foldingRangeProvider: LSPProviderCapability?
    let workspaceSymbolProvider: LSPProviderCapability?
    let selectionRangeProvider: LSPProviderCapability?
    let callHierarchyProvider: LSPProviderCapability?
    let executeCommandProvider: LSPExecuteCommandProvider?
}

nonisolated enum LSPTextDocumentSyncProvider: Codable, Equatable, Sendable {
    case kind(Int)
    case options([String: LSPAnyValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .kind(value)
        } else {
            self = .options((try? container.decode([String: LSPAnyValue].self)) ?? [:])
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .kind(let value):
            try container.encode(value)
        case .options(let object):
            try container.encode(object)
        }
    }

    var supportsSave: Bool {
        switch self {
        case .kind:
            return false
        case .options(let object):
            guard let save = object["save"] else { return false }
            switch save {
            case .bool(let value):
                return value
            case .object:
                return true
            default:
                return false
            }
        }
    }

    var saveIncludesText: Bool {
        switch self {
        case .kind:
            return false
        case .options(let object):
            if case .object(let saveOptions)? = object["save"] {
                return saveOptions["includeText"] == .bool(true)
            }
            return false
        }
    }

    var willSaveWaitUntil: Bool {
        switch self {
        case .kind:
            return false
        case .options(let object):
            return object["willSaveWaitUntil"] == .bool(true)
        }
    }
}

nonisolated enum LSPProviderCapability: Codable, Equatable, Sendable {
    case bool(Bool)
    case object([String: LSPAnyValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            self = .object((try? container.decode([String: LSPAnyValue].self)) ?? [:])
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value):
            try container.encode(value)
        case .object(let object):
            try container.encode(object)
        }
    }

    var isSupported: Bool {
        switch self {
        case .bool(let value):
            return value
        case .object:
            return true
        }
    }

    var prepareProvider: Bool {
        switch self {
        case .bool:
            return false
        case .object(let object):
            return object["prepareProvider"] == .bool(true)
        }
    }

    var resolveProvider: Bool {
        switch self {
        case .bool:
            return false
        case .object(let object):
            return object["resolveProvider"] == .bool(true)
        }
    }
}

nonisolated struct LSPCompletionProvider: Codable, Equatable, Sendable {
    let triggerCharacters: [String]?
    let resolveProvider: Bool?
}

nonisolated struct LSPSemanticTokensProvider: Codable, Equatable, Sendable {
    let legend: LSPSemanticTokensLegend
    let range: LSPProviderCapability?
    let full: LSPProviderCapability?
}

nonisolated struct LSPInitializedParams: Codable, Equatable, Sendable {}

nonisolated struct LSPDocumentSymbolParams: Codable, Equatable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
}

nonisolated enum LSPDefinitionResult: Decodable, Equatable, Sendable {
    case single(LSPLocation)
    case multiple([LSPLocation])
    case none

    var locations: [LSPLocation] {
        switch self {
        case .single(let location):
            return [location]
        case .multiple(let locations):
            return locations
        case .none:
            return []
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else if let locations = try? container.decode([LSPLocation].self) {
            self = .multiple(locations)
        } else {
            self = .single(try container.decode(LSPLocation.self))
        }
    }
}
