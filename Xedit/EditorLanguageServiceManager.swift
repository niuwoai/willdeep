//
//  EditorLanguageServiceManager.swift
//  WillDeep
//
//  Owns process-backed LSP sessions for editor files.
//

import Foundation

actor EditorLanguageServiceManager {
    typealias TransportFactory = @Sendable (URL, [String], URL) -> LanguageServerTransport
    typealias ExecutableResolver = @Sendable (EditorLanguageServerConfiguration) -> URL?
    typealias DiagnosticsHandler = @Sendable (String, [LSPDiagnostic]) -> Void
    typealias ApplyEditHandler = LanguageServerClient.ApplyEditHandler

    private final class Session {
        let configuration: EditorLanguageServerConfiguration
        let rootURL: URL
        let client: LanguageServerClient
        var openedDocumentVersions: [String: Int] = [:]

        init(configuration: EditorLanguageServerConfiguration, rootURL: URL, client: LanguageServerClient) {
            self.configuration = configuration
            self.rootURL = rootURL
            self.client = client
        }
    }

    private struct SessionKey: Hashable {
        let configurationID: String
        let rootPath: String
    }

    private let transportFactory: TransportFactory
    private let executableResolver: ExecutableResolver
    private var diagnosticsHandler: DiagnosticsHandler?
    private var applyEditHandler: ApplyEditHandler?
    private var sessions: [SessionKey: Session] = [:]

    /// LRU bookkeeping + cap for live language-server processes. Sessions
    /// are keyed by (server, workspace root) and were previously never
    /// stopped: every project the user visited left its LSP processes
    /// running for the app's whole lifetime (`closeAll` had no callers).
    /// A hop across a dozen repos meant a dozen sourcekit-lsp/gopls/…
    /// instances idling in the background. Evicting the least-recently
    /// used session is safe: document state re-syncs on the next request
    /// because a fresh session starts with empty `openedDocumentVersions`,
    /// which routes through `didOpen` again.
    private static let maxLiveSessions = 6
    private var sessionUseCounter: UInt64 = 0
    private var sessionLastUse: [SessionKey: UInt64] = [:]

    init(
        transportFactory: @escaping TransportFactory = { executableURL, arguments, rootURL in
            ProcessLanguageServerTransport(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: rootURL
            )
        },
        executableResolver: @escaping ExecutableResolver = { configuration in
            LanguageServerExecutableResolver.resolve(configuration)
        }
    ) {
        self.transportFactory = transportFactory
        self.executableResolver = executableResolver
    }

    func setDiagnosticsHandler(_ handler: DiagnosticsHandler?) async {
        diagnosticsHandler = handler
        for session in sessions.values {
            await session.client.setDiagnosticsHandler(handler)
        }
    }

    func setApplyEditHandler(_ handler: ApplyEditHandler?) async {
        applyEditHandler = handler
        for session in sessions.values {
            await session.client.setApplyEditHandler(handler)
        }
    }

    func synchronizeDocument(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String
    ) async throws {
        guard let language else { return }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
    }

    func definition(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        characterOffset: Int
    ) async throws -> [LSPLocation] {
        guard let language else { return [] }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        let position = LSPPosition(utf16Offset: characterOffset, in: text)
        return try await session.client.definition(url: fileURL, position: position)
    }

    func declaration(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        characterOffset: Int
    ) async throws -> [LSPLocation] {
        guard let language else { return [] }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        let position = LSPPosition(utf16Offset: characterOffset, in: text)
        return try await session.client.declaration(url: fileURL, position: position)
    }

    func typeDefinition(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        characterOffset: Int
    ) async throws -> [LSPLocation] {
        guard let language else { return [] }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        let position = LSPPosition(utf16Offset: characterOffset, in: text)
        return try await session.client.typeDefinition(url: fileURL, position: position)
    }

    func implementation(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        characterOffset: Int
    ) async throws -> [LSPLocation] {
        guard let language else { return [] }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        let position = LSPPosition(utf16Offset: characterOffset, in: text)
        return try await session.client.implementation(url: fileURL, position: position)
    }

    func hover(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        characterOffset: Int
    ) async throws -> LSPHover? {
        guard let language else { return nil }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        let position = LSPPosition(utf16Offset: characterOffset, in: text)
        return try await session.client.hover(url: fileURL, position: position)
    }

    func references(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        characterOffset: Int
    ) async throws -> [LSPLocation] {
        guard let language else { return [] }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        let position = LSPPosition(utf16Offset: characterOffset, in: text)
        return try await session.client.references(url: fileURL, position: position)
    }

    func documentSymbols(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String
    ) async throws -> [LSPDocumentSymbol] {
        guard let language else { return [] }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        return try await session.client.documentSymbols(url: fileURL)
    }

    func workspaceSymbols(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        query: String
    ) async throws -> [EditorWorkspaceSymbolItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let language, !normalizedQuery.isEmpty else { return [] }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        let symbols = try await session.client.workspaceSymbols(query: normalizedQuery)
        return symbols.compactMap(EditorWorkspaceSymbolItem.init(symbol:))
    }

    func completion(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        characterOffset: Int
    ) async throws -> [LSPCompletionItem] {
        guard let language else { return [] }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        let position = LSPPosition(utf16Offset: characterOffset, in: text)
        return try await session.client.completion(url: fileURL, position: position)
    }

    func resolveCompletionItem(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        item: LSPCompletionItem
    ) async throws -> LSPCompletionItem {
        guard let language else { return item }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        return try await session.client.resolveCompletionItem(item)
    }

    func signatureHelp(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        characterOffset: Int
    ) async throws -> LSPSignatureHelp? {
        guard let language else { return nil }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        let position = LSPPosition(utf16Offset: characterOffset, in: text)
        return try await session.client.signatureHelp(url: fileURL, position: position)
    }

    func selectionRanges(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        characterOffset: Int
    ) async throws -> [NSRange] {
        guard let language else { return [] }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        let position = LSPPosition(utf16Offset: characterOffset, in: text)
        return try await session.client.selectionRanges(url: fileURL, position: position)
            .flatMap { $0.flattenedRanges(in: text) }
    }

    func callHierarchy(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        characterOffset: Int
    ) async throws -> EditorCallHierarchyResponse {
        guard let language else {
            return EditorCallHierarchyResponse(target: nil, incoming: [], outgoing: [])
        }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        let position = LSPPosition(utf16Offset: characterOffset, in: text)
        guard let item = try await session.client.prepareCallHierarchy(url: fileURL, position: position).first else {
            return EditorCallHierarchyResponse(target: nil, incoming: [], outgoing: [])
        }
        async let incoming = session.client.incomingCallHierarchy(item: item)
        async let outgoing = session.client.outgoingCallHierarchy(item: item)
        return try await EditorCallHierarchyResponse(
            target: item,
            incoming: incoming,
            outgoing: outgoing
        )
    }

    func documentHighlights(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        characterOffset: Int
    ) async throws -> [EditorDocumentHighlightSpan] {
        guard let language else { return [] }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        let position = LSPPosition(utf16Offset: characterOffset, in: text)
        let highlights = try await session.client.documentHighlights(url: fileURL, position: position)
        return highlights.compactMap { EditorDocumentHighlightSpan(highlight: $0, in: text) }
    }

    func semanticTokens(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String
    ) async throws -> [EditorSemanticTokenSpan] {
        guard let language else { return [] }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        guard let tokens = try await session.client.semanticTokens(url: fileURL),
              let legend = await session.client.semanticTokensLegendValue() else {
            return []
        }
        return EditorSemanticTokenDecoder.spans(from: tokens, legend: legend, text: text)
    }

    func inlayHints(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String
    ) async throws -> [EditorInlayHintSpan] {
        guard let language else { return [] }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        let fullRange = LSPRange(
            start: LSPPosition(line: 0, character: 0),
            end: LSPPosition(utf16Offset: (text as NSString).length, in: text)
        )
        let hints = try await session.client.inlayHints(url: fileURL, range: fullRange)
        var resolvedHints: [LSPInlayHint] = []
        resolvedHints.reserveCapacity(hints.count)
        for hint in hints {
            resolvedHints.append((try? await session.client.resolveInlayHint(hint)) ?? hint)
        }
        return resolvedHints.compactMap { EditorInlayHintSpan(hint: $0, in: text) }
    }

    func documentLinks(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String
    ) async throws -> [EditorDocumentLinkSpan] {
        guard let language else { return [] }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        let links = try await session.client.documentLinks(url: fileURL)
        return links.compactMap { EditorDocumentLinkSpan(link: $0, in: text) }
    }

    func resolveDocumentLink(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        link: LSPDocumentLink
    ) async throws -> LSPDocumentLink {
        guard let language else { return link }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        return try await session.client.resolveDocumentLink(link)
    }

    func foldingRanges(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String
    ) async throws -> [ScopeGuide] {
        guard let language else { return [] }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        let ranges = try await session.client.foldingRanges(url: fileURL)
        return EditorFoldingRangeMapper.scopeGuides(from: ranges)
    }

    func documentFormatting(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        options: LSPFormattingOptions
    ) async throws -> [LSPTextEdit] {
        guard let language else { return [] }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        return try await session.client.documentFormatting(url: fileURL, options: options)
    }

    func documentRangeFormatting(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        range: LSPRange,
        options: LSPFormattingOptions
    ) async throws -> [LSPTextEdit] {
        guard let language else { return [] }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        return try await session.client.documentRangeFormatting(url: fileURL, range: range, options: options)
    }

    func rename(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        characterOffset: Int,
        newName: String
    ) async throws -> LSPWorkspaceEdit {
        guard let language else { return LSPWorkspaceEdit() }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        let position = LSPPosition(utf16Offset: characterOffset, in: text)
        return try await session.client.rename(url: fileURL, position: position, newName: newName)
    }

    func prepareRename(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        characterOffset: Int
    ) async throws -> EditorPreparedRename? {
        guard let language else { return nil }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        let position = LSPPosition(utf16Offset: characterOffset, in: text)
        let result = try await session.client.prepareRename(url: fileURL, position: position)
        guard let range = result.range else { return nil }
        return EditorPreparedRename(
            range: range.nsRange(in: text),
            placeholder: result.placeholder
        )
    }

    func codeActions(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        range: LSPRange,
        diagnostics: [LSPDiagnostic]
    ) async throws -> [LSPCodeAction] {
        guard let language else { return [] }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        return try await session.client.codeActions(url: fileURL, range: range, diagnostics: diagnostics)
    }

    func resolveCodeAction(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        action: LSPCodeAction
    ) async throws -> LSPCodeAction {
        guard let language else { return action }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        return try await session.client.resolveCodeAction(action)
    }

    func executeCommand(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String,
        command: LSPCommand
    ) async throws {
        guard let language else { return }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        try await session.client.executeCommand(command)
    }

    func saveDocument(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String
    ) async throws {
        guard let language else { return }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        try await session.client.saveDocument(url: fileURL, text: text)
    }

    func willSaveWaitUntil(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        text: String
    ) async throws -> [LSPTextEdit] {
        guard let language else { return [] }
        let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
        try await synchronizeDocument(fileURL: fileURL, language: language, text: text, in: session)
        return try await session.client.willSaveWaitUntil(url: fileURL)
    }

    func didChangeWatchedFiles(
        fileURL: URL,
        language: Language?,
        rootDirectory: URL?,
        type: LSPFileChangeType
    ) async throws {
        let event = LSPFileEvent(uri: fileURL.absoluteString, type: type)
        if let language, EditorLanguageServiceRegistry.isFirstStageIDELanguage(language) {
            let session = try await session(for: fileURL, language: language, rootDirectory: rootDirectory)
            try await session.client.didChangeWatchedFiles(changes: [event])
            return
        }

        let targetPath = fileURL.standardizedFileURL.path
        for session in sessions.values where Self.path(targetPath, isInsideRoot: session.rootURL.standardizedFileURL.path) {
            try await session.client.didChangeWatchedFiles(changes: [event])
        }
    }

    func closeAll() async {
        for session in sessions.values {
            await session.client.stop()
        }
        sessions.removeAll()
        sessionLastUse.removeAll()
    }

    private func session(
        for fileURL: URL,
        language: Language,
        rootDirectory: URL?
    ) async throws -> Session {
        guard let configuration = EditorLanguageServiceRegistry.configuration(for: language) else {
            throw LanguageServerClientError.missingLanguageID
        }

        let rootURL = EditorLanguageServiceRegistry.workspaceRoot(
            for: fileURL,
            language: language,
            explicitRoot: rootDirectory
        )
        let key = SessionKey(
            configurationID: configuration.id,
            rootPath: rootURL.standardizedFileURL.path
        )
        if let existing = sessions[key] {
            touchSession(key)
            return existing
        }

        guard let executableURL = executableResolver(configuration) else {
            throw LanguageServerClientError.serverUnavailable(configuration.installHint)
        }

        let transport = transportFactory(executableURL, configuration.arguments, rootURL)
        let client = LanguageServerClient(configuration: configuration, transport: transport)
        await client.setDiagnosticsHandler(diagnosticsHandler)
        await client.setApplyEditHandler(applyEditHandler)
        try await client.start()
        try await client.initialize(rootURL: rootURL)

        let created = Session(configuration: configuration, rootURL: rootURL, client: client)
        sessions[key] = created
        touchSession(key)
        await evictLeastRecentlyUsedSessionsIfNeeded(protecting: key)
        return created
    }

    private func touchSession(_ key: SessionKey) {
        sessionUseCounter += 1
        sessionLastUse[key] = sessionUseCounter
    }

    private func evictLeastRecentlyUsedSessionsIfNeeded(protecting protectedKey: SessionKey) async {
        while sessions.count > Self.maxLiveSessions {
            let evictable = sessions.keys
                .filter { $0 != protectedKey }
                .min { (sessionLastUse[$0] ?? 0) < (sessionLastUse[$1] ?? 0) }
            guard let victim = evictable, let session = sessions.removeValue(forKey: victim) else { return }
            sessionLastUse.removeValue(forKey: victim)
            await session.client.stop()
        }
    }

    private func synchronizeDocument(
        fileURL: URL,
        language: Language,
        text: String,
        in session: Session
    ) async throws {
        let uri = fileURL.absoluteString
        let nextVersion = (session.openedDocumentVersions[uri] ?? 0) + 1
        if session.openedDocumentVersions[uri] == nil {
            try await session.client.openDocument(url: fileURL, language: language, version: nextVersion, text: text)
        } else {
            try await session.client.changeDocument(url: fileURL, version: nextVersion, text: text)
        }
        session.openedDocumentVersions[uri] = nextVersion
    }

    private static func path(_ path: String, isInsideRoot rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath + "/")
    }
}
