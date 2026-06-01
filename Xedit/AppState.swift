//
//  AppState.swift
//  VeilWriter
//
//  Created by rocky on 2026/5/27.
//

import Combine
import Foundation
import SwiftUI
import AppKit

/// Central observable state hub for the VeilWriter app.
/// Manages the currently opened file URL, its text content, the dirty (edited) flag,
/// and the root directory for the sidebar file tree.
final class AppState: ObservableObject {
    @Published var openedFileURL: URL?
    @Published var fileContent: String {
        didSet {
            updateActiveTab { tab in
                tab.content = fileContent
            }
        }
    }
    @Published var isEdited: Bool {
        didSet {
            updateActiveTab { tab in
                tab.isEdited = isEdited
            }
        }
    }
    @Published var rootDirectory: URL?
    @Published var tabs: [EditorTab]
    @Published var activeTabID: EditorTab.ID?
    @Published private(set) var editorRenderRevision = 0
    @Published private(set) var editorHighlightRevision = 0
    @Published private(set) var editorNavigationRequest: EditorNavigationRequest?
    @Published var isFindBarVisible = false
    @Published var findQuery = "" {
        didSet {
            activeFindIndex = 0
        }
    }
    @Published var replaceText = ""
    @Published var activeFindIndex = 0
    @Published var findReplaceScope: FindReplaceScope = .currentTab
    @Published var selectedFolderURL: URL?
    @Published var selectedSidebarFileURL: URL?
    @Published var imagePreviewURL: URL?
    @Published var isInspectorVisible = true
    @Published var inspectorMode: EditorInspectorMode = .minimap
    @Published var isFocusModeEnabled = false
    @Published var isPreviewVisible = false
    @Published var isSplitEditorVisible = false
    @Published var splitFileURL: URL?
    @Published var splitFileContent = ""
    @Published var isQuickOpenVisible = false
    @Published var quickOpenQuery = ""
    @Published var isGoToLineVisible = false
    @Published var goToLineText = ""
    @Published var isCommandPaletteVisible = false
    @Published var commandPaletteQuery = ""
    @Published var isSymbolJumpVisible = false
    @Published var symbolJumpQuery = ""
    @Published private(set) var recentFiles: [URL] = []
    @Published private(set) var recentFolders: [URL] = []
    @Published private(set) var cursorLine = 1
    @Published private(set) var cursorColumn = 1
    @Published private(set) var selectedCharacterCount = 0
    @Published private(set) var selectedLineCount = 0
    @Published private(set) var selectedText = ""
    @Published private(set) var hasExternalFileChanges = false
    @Published private(set) var gitStatus = GitRepositoryStatus()
    @Published var isAgentPanelVisible = false
    @Published var agentConfiguration: AgentConfiguration {
        didSet {
            AgentSettingsStore.save(agentConfiguration)
        }
    }
    @Published var agentMessages: [AgentMessage] = []
    @Published var agentPatchProposals: [AgentPatchProposal] = []
    @Published var agentToolCalls: [AgentToolCall] = []
    @Published var agentInput = ""
    @Published var isAgentResponding = false
    @Published var agentErrorMessage: String?
    /// Images staged in the composer for the next user message.
    @Published var agentPendingImages: [AgentImageAttachment] = []
    /// Messages the user queued while the agent was busy. Each entry is a
    /// snapshot of text + images, consumed FIFO once the current turn ends.
    @Published var agentQueuedMessages: [AgentQueuedMessage] = []
    /// Per-session model override. If non-nil, takes precedence over
    /// `agentConfiguration.model` for the active Agent-mode session.
    @Published var agentSessionModelOverride: String?
    /// Model IDs the user has previously fetched in Settings — surfaced in
    /// the Agent-mode model picker as a quick switcher.
    @Published var agentKnownModelIDs: [String] = []
    /// Persisted Agent-mode chat sessions, newest-updated first.
    @Published private(set) var agentSessions: [AgentSession] = []
    /// Active Agent-mode session id. nil means "scratch" — Editor-mode
    /// chat keeps working without forcing a session to exist.
    @Published var activeAgentSessionID: AgentSession.ID?
    /// Top-level UI mode. Editor is the classic file editor; agent hides
    /// the editor and shows the conversation-first layout.
    @Published var appMode: AppMode = .editor
    /// Continuation resumed when the user resolves (approve/deny/confirm) the
    /// currently-blocked tool call. Internal to the agent loop.
    private var agentToolDecisionWaiter: CheckedContinuation<AgentToolDecision, Never>?
    /// Display-ready Quick Open file list, backed by `ProjectFileListCache`.
    /// Populated instantly from disk cache on project open, then verified and
    /// backfilled by a background scan. `QuickOpenPanel` filters this in-memory
    /// array per keystroke instead of re-walking the project tree.
    @Published private(set) var quickOpenFiles: [URL] = []
    @Published var editorSettings: EditorSettings {
        didSet {
            scheduleEditorSettingsSideEffects()
        }
    }

    /// Internal flag to suppress re-entrant `onChange` processing when a URL
    /// change is a programmatic revert (e.g. binary file rejected, user cancelled).
    var suppressURLChangeProcessing = false
    private var isApplyingTabSnapshot = false
    private var closedTabs: [EditorTab] = []
    private var knownModificationDates: [URL: Date] = [:]
    private var securityScopedAccessURLs: Set<URL> = []
    private var gitStatusRefreshTask: Task<Void, Never>?
    private var quickOpenRefreshTask: Task<Void, Never>?
    private var agentRequestTask: Task<Void, Never>?
    private var editorSettingsSideEffectsWorkItem: DispatchWorkItem?
    private var editorSettingsObserver: AnyCancellable?

    init(
        openedFileURL: URL? = nil,
        fileContent: String = "",
        isEdited: Bool = false,
        rootDirectory: URL? = nil,
        editorSettings: EditorSettings = EditorSettingsStore.load()
    ) {
        self.openedFileURL = openedFileURL
        self.fileContent = fileContent
        self.isEdited = isEdited
        self.rootDirectory = rootDirectory
        if let openedFileURL {
            let tab = EditorTab(url: openedFileURL, content: fileContent, isEdited: isEdited)
            self.tabs = [tab]
            self.activeTabID = tab.id
        } else {
            self.tabs = []
            self.activeTabID = nil
        }
        self.editorSettings = editorSettings.normalized()
        self.agentConfiguration = AgentSettingsStore.load()
        self.inspectorMode = self.editorSettings.preferredInspectorMode
        self.recentFiles = RecentItemsStore.loadFiles()
        self.recentFolders = RecentItemsStore.loadFolders()
        self.editorSettingsObserver = NotificationCenter.default
            .publisher(for: EditorSettingsStore.didChangeNotification)
            .compactMap { $0.object as? EditorSettings }
            .sink { [weak self] settings in
                guard let self else { return }
                let normalizedSettings = settings.normalized()
                guard self.editorSettings != normalizedSettings else { return }
                self.editorSettings = normalizedSettings
            }
        self.agentSessions = AgentSessionStore.loadAll()
        self.agentKnownModelIDs = AgentSettingsStore.loadKnownModelIDs()
    }

    deinit {
        gitStatusRefreshTask?.cancel()
        quickOpenRefreshTask?.cancel()
        agentRequestTask?.cancel()
        for url in securityScopedAccessURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }

    var activeTab: EditorTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    var findMatchRanges: [NSRange] {
        Self.findRanges(in: fileContent, query: findQuery)
    }

    var activeFindRange: NSRange? {
        let ranges = findMatchRanges
        guard !ranges.isEmpty else { return nil }
        return ranges[min(activeFindIndex, ranges.count - 1)]
    }

    var changedLineNumbers: Set<Int> {
        guard let activeTab else { return [] }
        return Self.changedLineNumbers(current: activeTab.content, saved: activeTab.savedContent)
    }

    var canShowPreview: Bool {
        let language = effectiveLanguage
        return language == .markdown || language == .html
    }

    var detectedLanguage: Language? {
        openedFileURL.map(Language.fromURL) ?? nil
    }

    var syntaxHighlightingSelection: SyntaxHighlightingSelection {
        activeTab?.syntaxHighlightingSelection ?? .automatic
    }

    var effectiveLanguage: Language? {
        switch syntaxHighlightingSelection {
        case .automatic:
            return detectedLanguage
        case .plainText:
            return nil
        case .language(let language):
            return language
        }
    }

    func showFindBar() {
        isFindBarVisible = true
    }

    func hideFindBar() {
        isFindBarVisible = false
    }

    func showQuickOpen() {
        guard rootDirectory != nil else { return }
        quickOpenQuery = ""
        isQuickOpenVisible = true
    }

    func hideQuickOpen() {
        isQuickOpenVisible = false
        quickOpenQuery = ""
    }

    func showGoToLine() {
        guard activeTabID != nil else { return }
        goToLineText = ""
        isGoToLineVisible = true
    }

    func hideGoToLine() {
        isGoToLineVisible = false
        goToLineText = ""
    }

    func showCommandPalette() {
        commandPaletteQuery = ""
        isCommandPaletteVisible = true
    }

    func hideCommandPalette() {
        isCommandPaletteVisible = false
        commandPaletteQuery = ""
    }

    func showSymbolJump() {
        guard activeTabID != nil else { return }
        symbolJumpQuery = ""
        isSymbolJumpVisible = true
    }

    func hideSymbolJump() {
        isSymbolJumpVisible = false
        symbolJumpQuery = ""
    }

    func toggleFocusMode() {
        isFocusModeEnabled.toggle()
    }

    func toggleAgentPanel() {
        isAgentPanelVisible.toggle()
    }

    func togglePreview() {
        guard canShowPreview else { return }
        isPreviewVisible.toggle()
    }

    func updateSelectionInfo(line: Int, column: Int, selectedCharacters: Int, selectedLines: Int, selectedText: String = "") {
        cursorLine = max(1, line)
        cursorColumn = max(1, column)
        selectedCharacterCount = max(0, selectedCharacters)
        selectedLineCount = max(0, selectedLines)
        self.selectedText = selectedText
    }

    /// Submit the composer (text + staged images). If the agent is already
    /// responding, the message is queued and consumed when the current turn
    /// finishes. Editor-mode and Agent-mode share this entry point.
    func sendAgentMessage() {
        let prompt = agentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = agentPendingImages
        guard !prompt.isEmpty || !images.isEmpty else { return }

        agentInput = ""
        agentPendingImages = []

        if isAgentResponding {
            agentQueuedMessages.append(AgentQueuedMessage(text: prompt, images: images))
            return
        }

        dispatchAgentMessage(text: prompt, images: images)
    }

    /// Cancel the in-flight response (if any). Queued messages are kept and
    /// the next one is dispatched automatically. Use `clearAgentQueue` to
    /// drop them explicitly.
    func stopAgentResponse() {
        guard isAgentResponding else { return }
        agentRequestTask?.cancel()
        // The loop's defer clears `isAgentResponding` and triggers
        // `consumeNextQueuedMessageIfNeeded()`.
    }

    func clearAgentQueue() {
        agentQueuedMessages.removeAll()
    }

    func addAgentImage(data: Data, mimeType: String) {
        let attachment = AgentImageAttachment(mimeType: mimeType, dataBase64: data.base64EncodedString())
        agentPendingImages.append(attachment)
    }

    func removeAgentImage(id: AgentImageAttachment.ID) {
        agentPendingImages.removeAll { $0.id == id }
    }

    private func dispatchAgentMessage(text: String, images: [AgentImageAttachment]) {
        agentErrorMessage = nil
        isAgentResponding = true

        agentMessages.append(AgentMessage(role: .user, content: text, images: images))
        let configuration = configurationForCurrentTurn()

        agentRequestTask?.cancel()
        agentRequestTask = Task { [weak self] in
            await self?.runAgentLoop(configuration: configuration)
        }
    }

    /// Resolve the configuration to use for this turn. Honours the per-
    /// session `agentSessionModelOverride` if one is set; falls back to the
    /// global Settings model.
    private func configurationForCurrentTurn() -> AgentConfiguration {
        var configuration = agentConfiguration
        if let override = agentSessionModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            configuration.model = override
        }
        return configuration.normalized
    }

    private func consumeNextQueuedMessageIfNeeded() {
        guard !isAgentResponding, let next = agentQueuedMessages.first else { return }
        agentQueuedMessages.removeFirst()
        dispatchAgentMessage(text: next.text, images: next.images)
    }

    func clearAgentConversation() {
        agentRequestTask?.cancel()
        agentMessages.removeAll()
        agentPatchProposals.removeAll()
        agentToolCalls.removeAll()
        agentQueuedMessages.removeAll()
        agentPendingImages.removeAll()
        agentErrorMessage = nil
        agentToolDecisionWaiter?.resume(returning: .denied(reason: "Conversation cleared"))
        agentToolDecisionWaiter = nil
        isAgentResponding = false
        persistActiveAgentSession()
    }

    // MARK: - Agent mode + sessions

    func setAppMode(_ mode: AppMode) {
        guard appMode != mode else { return }
        appMode = mode
        if mode == .agent, activeAgentSessionID == nil {
            // Drop any stale Editor-mode chat state when first entering
            // Agent mode so the user lands on an empty New Chat.
            agentRequestTask?.cancel()
            agentMessages = []
            agentPatchProposals = []
            agentToolCalls = []
            agentQueuedMessages = []
            agentPendingImages = []
            agentErrorMessage = nil
            isAgentResponding = false
            startNewAgentSession()
        }
    }

    func toggleAppMode() {
        setAppMode(appMode == .agent ? .editor : .agent)
    }

    @discardableResult
    func startNewAgentSession() -> AgentSession {
        agentRequestTask?.cancel()
        agentMessages = []
        agentPatchProposals = []
        agentToolCalls = []
        agentQueuedMessages = []
        agentPendingImages = []
        agentErrorMessage = nil
        agentToolDecisionWaiter?.resume(returning: .denied(reason: "Session switched"))
        agentToolDecisionWaiter = nil
        isAgentResponding = false
        agentSessionModelOverride = nil

        let session = AgentSession(
            workspaceRootPath: rootDirectory?.standardizedFileURL.path,
            modelID: agentConfiguration.model
        )
        agentSessions.insert(session, at: 0)
        activeAgentSessionID = session.id
        AgentSessionStore.save(session)
        return session
    }

    func selectAgentSession(id: AgentSession.ID) {
        guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
        // Save the outgoing session first.
        persistActiveAgentSession()

        agentRequestTask?.cancel()
        agentToolDecisionWaiter?.resume(returning: .denied(reason: "Session switched"))
        agentToolDecisionWaiter = nil
        isAgentResponding = false

        let session = agentSessions[index]
        activeAgentSessionID = session.id
        agentMessages = session.messages
        agentSessionModelOverride = session.modelID == agentConfiguration.model ? nil : session.modelID
        agentPatchProposals = []
        agentToolCalls = []
        agentQueuedMessages = []
        agentPendingImages = []
        agentErrorMessage = nil
    }

    func deleteAgentSession(id: AgentSession.ID) {
        AgentSessionStore.delete(id: id)
        agentSessions.removeAll { $0.id == id }
        if activeAgentSessionID == id {
            activeAgentSessionID = nil
            agentMessages = []
            agentPatchProposals = []
            agentToolCalls = []
            agentQueuedMessages = []
            agentPendingImages = []
            agentErrorMessage = nil
        }
    }

    /// Write the active session back to disk. No-op if no session is
    /// active (Editor-mode chats aren't persisted).
    func persistActiveAgentSession() {
        guard let id = activeAgentSessionID,
              let index = agentSessions.firstIndex(where: { $0.id == id }) else {
            return
        }
        var session = agentSessions[index]
        session.messages = agentMessages
        session.updatedAt = Date()
        session.title = AgentSessionStore.deriveTitle(from: agentMessages)
        if let override = agentSessionModelOverride, !override.isEmpty {
            session.modelID = override
        } else {
            session.modelID = agentConfiguration.model
        }
        agentSessions[index] = session
        // Bubble most-recently-updated to the top.
        agentSessions.sort { $0.updatedAt > $1.updatedAt }
        AgentSessionStore.save(session)
    }

    func recordFetchedAgentModels(_ ids: [String]) {
        let merged = Array(Set(agentKnownModelIDs + ids))
            .filter { !$0.isEmpty }
            .sorted()
        agentKnownModelIDs = merged
        AgentSettingsStore.saveKnownModelIDs(merged)
    }

    func setAgentSessionModel(_ model: String?) {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            agentSessionModelOverride = trimmed
            recordFetchedAgentModels([trimmed])
        } else {
            agentSessionModelOverride = nil
        }
        persistActiveAgentSession()
    }

    /// Best-effort token count for the messages currently in the
    /// conversation. Uses a chars/4 rule of thumb plus a flat per-image
    /// budget — accurate enough to drive the "context remaining" UI.
    var estimatedAgentTokens: Int {
        var total = 0
        for message in agentMessages {
            total += max(1, message.content.count / 4)
            // Each image roughly equates to a 256x256 tile budget in the
            // OpenAI and Claude vision pricing models — call it 600 tokens.
            total += message.images.count * 600
            for call in message.toolCalls {
                total += call.argumentsJSON.count / 4
            }
        }
        // System prompt is a small constant; pad 500 tokens.
        total += 500
        return total
    }

    /// Heuristic context-window budget for the active model. Falls back to
    /// 8k for unknown models so the indicator stays informative without
    /// over-promising.
    var agentContextWindow: Int {
        let model = (agentSessionModelOverride ?? agentConfiguration.model).lowercased()
        // Substring match — vendors include variants like `-32k`, `-128k` in the id.
        if model.contains("1m") || model.contains("-1m") { return 1_000_000 }
        if model.contains("200k") { return 200_000 }
        if model.contains("128k") || model.contains("-128k") { return 128_000 }
        if model.contains("64k") { return 64_000 }
        if model.contains("32k") { return 32_000 }
        if model.contains("16k") { return 16_000 }
        // Known family defaults.
        if model.contains("gpt-4.1") || model.contains("gpt-4o") || model.contains("o1") || model.contains("o3") { return 128_000 }
        if model.contains("claude") { return 200_000 }
        if model.contains("deepseek") { return 64_000 }
        if model.contains("qwen") || model.contains("dashscope") { return 32_000 }
        if model.contains("kimi") || model.contains("moonshot") { return 128_000 }
        if model.contains("gpt-3.5") { return 16_000 }
        return 8_000
    }

    func approveAgentToolCall(id: AgentToolCall.ID) {
        resolveAgentToolCallDecision(id: id, decision: .approved)
    }

    func denyAgentToolCall(id: AgentToolCall.ID) {
        resolveAgentToolCallDecision(id: id, decision: .denied(reason: "User denied"))
    }

    func confirmAgentToolCall(id: AgentToolCall.ID, typedConfirmation: String) -> Bool {
        let expected = "confirm"
        guard typedConfirmation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expected else {
            return false
        }
        resolveAgentToolCallDecision(id: id, decision: .approved)
        return true
    }

    private func resolveAgentToolCallDecision(id: AgentToolCall.ID, decision: AgentToolDecision) {
        guard let index = agentToolCalls.firstIndex(where: { $0.id == id }) else { return }
        guard agentToolCalls[index].status == .pendingApproval
            || agentToolCalls[index].status == .awaitingConfirm else {
            return
        }
        if case .denied(let reason) = decision {
            agentToolCalls[index].status = .denied
            agentToolCalls[index].errorMessage = reason
        }
        agentToolDecisionWaiter?.resume(returning: decision)
        agentToolDecisionWaiter = nil
    }

    @MainActor
    private func runAgentLoop(configuration: AgentConfiguration) async {
        defer {
            self.isAgentResponding = false
            self.agentRequestTask = nil
            self.persistActiveAgentSession()
            self.consumeNextQueuedMessageIfNeeded()
        }

        let maxTurns = 6
        let client = AgentClient(configuration: configuration)

        for _ in 0..<maxTurns {
            let assistantMessage = AgentMessage(role: .assistant, content: "")
            agentMessages.append(assistantMessage)
            let assistantID = assistantMessage.id

            let systemPrompt = AgentContextBuilder.systemPrompt(
                rootDirectory: rootDirectory,
                openedFileURL: openedFileURL,
                fileContent: fileContent,
                selectedText: selectedText,
                language: effectiveLanguage,
                toolsEnabled: rootDirectory != nil
            )
            let history = agentMessages.filter { $0.id != assistantID }
            let requestMessages = [AgentMessage(role: .system, content: systemPrompt)] + history

            var finishReason: String?
            var latestToolCalls: [AgentMessageToolCall] = []

            do {
                try await client.streamChat(
                    messages: requestMessages,
                    tools: rootDirectory != nil ? AgentToolRegistry.all : []
                ) { event in
                    await MainActor.run { [weak self] in
                        guard let self,
                              let index = self.agentMessages.firstIndex(where: { $0.id == assistantID }) else {
                            return
                        }
                        switch event {
                        case .textDelta(let delta):
                            self.agentMessages[index].content += delta
                        case .toolCallsUpdated(let calls):
                            self.agentMessages[index].toolCalls = calls
                            latestToolCalls = calls
                        case .finishedTurn(let reason):
                            finishReason = reason
                        }
                    }
                }
            } catch is CancellationError {
                if let index = agentMessages.firstIndex(where: { $0.id == assistantID }),
                   agentMessages[index].content.isEmpty,
                   agentMessages[index].toolCalls.isEmpty {
                    agentMessages.remove(at: index)
                }
                return
            } catch {
                agentErrorMessage = error.localizedDescription
                if let index = agentMessages.firstIndex(where: { $0.id == assistantID }),
                   agentMessages[index].content.isEmpty,
                   agentMessages[index].toolCalls.isEmpty {
                    agentMessages.remove(at: index)
                }
                return
            }

            // Snapshot the assistant's final tool_calls list (the .toolCallsUpdated
            // closure may not have published the very last fragment yet if the
            // stream ended on the same chunk).
            if let index = agentMessages.firstIndex(where: { $0.id == assistantID }) {
                if latestToolCalls.isEmpty {
                    latestToolCalls = agentMessages[index].toolCalls
                } else {
                    agentMessages[index].toolCalls = latestToolCalls
                }
            }

            // No tool calls → assistant finished talking. Capture patches and return.
            guard !latestToolCalls.isEmpty else {
                captureAgentPatchProposals(fromMessageID: assistantID)
                return
            }

            // Execute every tool call, gating on the user when necessary.
            var anyDenied = false
            for call in latestToolCalls {
                let arguments = AgentJSONValue.decode(from: call.argumentsJSON.isEmpty ? "{}" : call.argumentsJSON)
                let argsDict: [String: AgentJSONValue]
                if case .object(let dict) = arguments {
                    argsDict = dict
                } else {
                    argsDict = [:]
                }

                let risk = AgentToolRegistry.risk(for: call.toolName, arguments: argsDict)
                let initialStatus: AgentToolCallStatus
                switch risk {
                case .read: initialStatus = .running
                case .write: initialStatus = .pendingApproval
                case .danger: initialStatus = .awaitingConfirm
                }

                let record = AgentToolCall(
                    messageID: assistantID,
                    externalID: call.externalID,
                    toolName: call.toolName,
                    arguments: argsDict,
                    risk: risk,
                    status: initialStatus
                )
                agentToolCalls.append(record)
                let recordID = record.id

                if risk != .read {
                    let decision = await awaitToolDecision(forCallID: recordID)
                    if case .denied(let reason) = decision {
                        anyDenied = true
                        if let index = agentToolCalls.firstIndex(where: { $0.id == recordID }) {
                            agentToolCalls[index].status = .denied
                            agentToolCalls[index].errorMessage = reason
                        }
                        appendToolMessage(
                            toolCallID: call.externalID,
                            payload: "Tool call denied by the user."
                        )
                        continue
                    }
                    if let index = agentToolCalls.firstIndex(where: { $0.id == recordID }) {
                        agentToolCalls[index].status = .running
                    }
                }

                let context = AgentToolContext(rootDirectory: rootDirectory)
                do {
                    let result = try await AgentToolRunner.run(
                        name: call.toolName,
                        arguments: argsDict,
                        context: context
                    )
                    if let index = agentToolCalls.firstIndex(where: { $0.id == recordID }) {
                        agentToolCalls[index].status = .succeeded
                        agentToolCalls[index].result = result
                    }
                    appendToolMessage(toolCallID: call.externalID, payload: result.payload)
                } catch {
                    if let index = agentToolCalls.firstIndex(where: { $0.id == recordID }) {
                        agentToolCalls[index].status = .failed
                        agentToolCalls[index].errorMessage = error.localizedDescription
                    }
                    appendToolMessage(
                        toolCallID: call.externalID,
                        payload: "Tool error: \(error.localizedDescription)"
                    )
                }
            }

            if anyDenied, finishReason == "stop" {
                // Model already decided it was done; don't loop further.
                return
            }
            // Otherwise: loop again so the model can react to the tool outputs.
        }

        agentErrorMessage = "Agent reached the maximum number of tool-call rounds."
    }

    private func awaitToolDecision(forCallID id: AgentToolCall.ID) async -> AgentToolDecision {
        await withCheckedContinuation { continuation in
            // Already resolved before we got to register (e.g. user clicked
            // Deny while the previous tool was still running) — resume now.
            if let call = agentToolCalls.first(where: { $0.id == id }),
               call.status != .pendingApproval, call.status != .awaitingConfirm {
                if call.status == .denied {
                    continuation.resume(returning: .denied(reason: call.errorMessage ?? "User denied"))
                } else {
                    continuation.resume(returning: .approved)
                }
                return
            }
            self.agentToolDecisionWaiter = continuation
        }
    }

    private func appendToolMessage(toolCallID: String, payload: String) {
        let limited: String
        let maxPayload = 24_000
        if payload.count > maxPayload {
            limited = String(payload.prefix(maxPayload)) + "\n...[tool output truncated]"
        } else {
            limited = payload
        }
        agentMessages.append(
            AgentMessage(role: .tool, content: limited, toolCallID: toolCallID)
        )
    }

    func rejectAgentPatchProposal(id: AgentPatchProposal.ID) {
        guard let index = agentPatchProposals.firstIndex(where: { $0.id == id }) else { return }
        agentPatchProposals[index].status = .rejected
        agentPatchProposals[index].statusMessage = "Rejected"
    }

    func applyAgentPatchProposal(id: AgentPatchProposal.ID) {
        guard let index = agentPatchProposals.firstIndex(where: { $0.id == id }) else { return }

        do {
            try applyAgentPatch(agentPatchProposals[index].diff)
            agentPatchProposals[index].status = .applied
            agentPatchProposals[index].statusMessage = "Applied"
        } catch {
            agentPatchProposals[index].status = .failed
            agentPatchProposals[index].statusMessage = error.localizedDescription
        }
    }

    private func captureAgentPatchProposals(fromMessageID messageID: UUID) {
        guard let message = agentMessages.first(where: { $0.id == messageID }) else { return }
        let diffs = AgentPatchApplier.extractDiffBlocks(from: message.content)
        guard !diffs.isEmpty else { return }

        let existingDiffs = Set(agentPatchProposals.map(\.diff))
        for (offset, diff) in diffs.enumerated() where !existingDiffs.contains(diff) {
            let title = diffs.count == 1 ? "Agent Patch" : "Agent Patch \(offset + 1)"
            agentPatchProposals.append(
                AgentPatchProposal(messageID: messageID, title: title, diff: diff)
            )
        }
    }

    private func applyAgentPatch(_ diff: String) throws {
        guard let rootDirectory else {
            throw AgentPatchError.noWorkspace
        }

        let changes = try AgentPatchApplier.parse(diff)
        let root = rootDirectory.standardizedFileURL
        let rootPath = root.path
        var pendingWrites: [(url: URL, content: String)] = []

        for change in changes {
            let url = try resolveAgentPatchURL(change.path, root: root, rootPath: rootPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AgentPatchError.missingFile(change.path)
            }

            let currentContent = try editableContent(forAgentPatchURL: url)
            let newContent = try AgentPatchApplier.apply(change, to: currentContent)
            pendingWrites.append((url, newContent))
        }

        for pendingWrite in pendingWrites {
            try pendingWrite.content.write(to: pendingWrite.url, atomically: true, encoding: .utf8)
            applyAgentPatchedContent(pendingWrite.content, to: pendingWrite.url)
        }

        refreshGitStatus()
        persistSession()
    }

    private func resolveAgentPatchURL(_ path: String, root: URL, rootPath: String) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        let filePath = url.path
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else {
            throw AgentPatchError.pathOutsideWorkspace(path)
        }
        return url
    }

    private func editableContent(forAgentPatchURL url: URL) throws -> String {
        if let tab = tabs.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
            return tab.content
        }

        let data = try Self.readFileData(from: url, allowLargeFile: true)
        return Self.decodeText(from: data)
    }

    private func applyAgentPatchedContent(_ content: String, to url: URL) {
        let standardizedPath = url.standardizedFileURL.path

        for index in tabs.indices where tabs[index].url.standardizedFileURL.path == standardizedPath {
            tabs[index].content = content
            tabs[index].savedContent = content
            tabs[index].isEdited = false
        }

        if openedFileURL?.standardizedFileURL.path == standardizedPath {
            isApplyingTabSnapshot = true
            fileContent = content
            isEdited = false
            isApplyingTabSnapshot = false
            bumpEditorRenderRevision()
            bumpEditorHighlightRevision()
            updateWindowTitle(url: url, isEdited: false)
        }

        knownModificationDates[url] = Self.modificationDate(at: url)
        hasExternalFileChanges = false
    }

    func navigateEditor(toLine line: Int) {
        guard line > 0 else { return }
        let nextRevision = (editorNavigationRequest?.revision ?? 0) + 1
        editorNavigationRequest = EditorNavigationRequest(line: line, revision: nextRevision)
    }

    func openRecentFile(_ url: URL) {
        registerRecentFile(url)
        openedFileURL = url
    }

    func openRecentFolder(_ url: URL, openInNewWindow: ((URL) -> Void)? = nil) {
        openFolderURL(url, openInNewWindow: openInNewWindow)
    }

    func openExternalURL(_ url: URL) {
        let fileURL = url.isFileURL ? url : URL(fileURLWithPath: url.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            return
        }

        if isDirectory.boolValue {
            registerRecentFolder(fileURL)
            setRootDirectory(fileURL)
            refreshGitStatus()
            persistSession()
            return
        }

        registerRecentFile(fileURL)
        registerRecentFolder(fileURL.deletingLastPathComponent())
        setRootDirectory(fileURL.deletingLastPathComponent())
        openedFileURL = fileURL
        refreshGitStatus()
        persistSession()
    }

    func openFolderURL(_ url: URL, openInNewWindow: ((URL) -> Void)? = nil) {
        registerRecentFolder(url)

        if let openInNewWindow {
            openInNewWindow(url)
            return
        }

        setRootDirectory(url)
        refreshGitStatus()
        persistSession()
    }

    nonisolated static func isExistingDirectory(_ url: URL) -> Bool {
        let fileURL = url.isFileURL ? url : URL(fileURLWithPath: url.path)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func registerRecentFile(_ url: URL) {
        recentFiles = RecentItemsStore.add(url, to: recentFiles)
        RecentItemsStore.saveFiles(recentFiles)
    }

    func registerRecentFolder(_ url: URL) {
        recentFolders = RecentItemsStore.add(url, to: recentFolders)
        RecentItemsStore.saveFolders(recentFolders)
    }

    func gitStatusKind(for url: URL) -> GitFileStatusKind? {
        gitStatus.kind(for: url)
    }

    func refreshGitStatus() {
        gitStatusRefreshTask?.cancel()

        guard let rootDirectory else {
            let emptyStatus = GitRepositoryStatus()
            DispatchQueue.main.async { [weak self] in
                self?.gitStatus = emptyStatus
            }
            return
        }

        let targetDirectory = rootDirectory.standardizedFileURL
        gitStatusRefreshTask = Task { [weak self] in
            let status = await Task.detached(priority: .utility) {
                Self.loadGitStatus(for: targetDirectory)
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.rootDirectory?.standardizedFileURL.path == targetDirectory.path else {
                    return
                }
                self.gitStatus = status
            }
        }
    }

    /// Refresh the Quick Open file list: serve the disk cache immediately (if
    /// present), then verify it against a fresh background scan and backfill any
    /// differences. All file IO runs off the main thread; only the two
    /// `@Published` assignments hop back to the main actor.
    func refreshProjectFileList() {
        quickOpenRefreshTask?.cancel()

        guard let rootDirectory else {
            quickOpenFiles = []
            return
        }

        let targetRoot = rootDirectory.standardizedFileURL
        let rootPath = targetRoot.path
        let limit = Self.quickOpenFileLimit

        quickOpenRefreshTask = Task { [weak self] in
            // 1. Serve cache instantly (if any).
            let cached = await Task.detached(priority: .userInitiated) {
                ProjectFileListCache.load(forRootPath: rootPath)
            }.value

            if let cached, !Task.isCancelled {
                let urls = ProjectFileListCache.fileURLs(from: cached, root: targetRoot)
                await self?.applyQuickOpenFiles(urls, ifRootMatches: rootPath)
            }

            guard !Task.isCancelled else { return }

            // 2. Verify with a full scan and backfill if it differs.
            let scanned = await Task.detached(priority: .utility) {
                ProjectFileListCache.scan(root: targetRoot, limit: limit)
            }.value

            guard !Task.isCancelled else { return }

            if cached == nil || ProjectFileListCache.differs(cached!.entries, scanned.entries) {
                ProjectFileListCache.save(scanned)
                let urls = ProjectFileListCache.fileURLs(from: scanned, root: targetRoot)
                await self?.applyQuickOpenFiles(urls, ifRootMatches: rootPath)
            }
        }
    }

    @MainActor
    private func applyQuickOpenFiles(_ urls: [URL], ifRootMatches rootPath: String) {
        // Guard against a fast project switch clobbering the new project's list.
        guard rootDirectory?.standardizedFileURL.path == rootPath else { return }
        quickOpenFiles = urls
    }

    func openTerminalHere(_ url: URL? = nil) {
        let targetURL = terminalTargetURL(for: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", targetURL.path]
        try? process.run()
    }

    func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func copyRelativePath(_ url: URL) {
        let path = relativePath(for: url)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func createNewFile(in directoryURL: URL, completion: (() -> Void)? = nil) {
        promptForName(
            title: "New File",
            message: "Create a file in \(directoryURL.lastPathComponent).",
            placeholder: "Untitled.txt"
        ) { [weak self] name in
            guard let self else { return }
            let fileURL = directoryURL.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: fileURL.path) else {
                self.showFileOperationError("A file or folder named \"\(name)\" already exists.")
                return
            }

            do {
                try Data().write(to: fileURL)
                registerRecentFile(fileURL)
                openedFileURL = fileURL
                refreshGitStatus()
                completion?()
            } catch {
                showFileOperationError(error.localizedDescription)
            }
        }
    }

    func createNewFolder(in directoryURL: URL, completion: (() -> Void)? = nil) {
        promptForName(
            title: "New Folder",
            message: "Create a folder in \(directoryURL.lastPathComponent).",
            placeholder: "Untitled Folder"
        ) { [weak self] name in
            guard let self else { return }
            let folderURL = directoryURL.appendingPathComponent(name, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: folderURL.path) else {
                self.showFileOperationError("A file or folder named \"\(name)\" already exists.")
                return
            }

            do {
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
                registerRecentFolder(folderURL)
                selectedFolderURL = folderURL
                refreshGitStatus()
                completion?()
            } catch {
                showFileOperationError(error.localizedDescription)
            }
        }
    }

    func activateNextTab() {
        guard tabs.count > 1,
              let activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID }) else {
            return
        }
        let nextIndex = (index + 1) % tabs.count
        activateTab(id: tabs[nextIndex].id)
    }

    func activatePreviousTab() {
        guard tabs.count > 1,
              let activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID }) else {
            return
        }
        let previousIndex = (index - 1 + tabs.count) % tabs.count
        activateTab(id: tabs[previousIndex].id)
    }

    func activateTab(atDisplayIndex displayIndex: Int) {
        guard displayIndex > 0, displayIndex <= tabs.count else { return }
        activateTab(id: tabs[displayIndex - 1].id)
    }

    func createNewTab() {
        let tab = EditorTab(url: Self.untitledTabURL(), isUntitled: true)
        tabs.append(tab)
        activeTabID = tab.id
        imagePreviewURL = nil
        selectedSidebarFileURL = nil
        applySnapshot(from: tab, suppressURLChange: true)
    }

    func setSyntaxHighlightingSelection(_ selection: SyntaxHighlightingSelection) {
        updateActiveTab { tab in
            tab.syntaxHighlightingSelection = selection
        }
        bumpEditorHighlightRevision()
        persistSession()
    }

    func reopenClosedTab() {
        guard let tab = closedTabs.popLast() else { return }
        if activateTab(for: tab.url) {
            return
        }
        tabs.append(tab)
        activeTabID = tab.id
        applySnapshot(from: tab, suppressURLChange: true)
    }

    func duplicateCurrentLine() {
        fileContent = Self.duplicateLine(at: cursorLine, in: fileContent)
        isEdited = true
        navigateEditor(toLine: cursorLine + 1)
    }

    func moveCurrentLineUp() {
        let result = Self.moveLine(at: cursorLine, direction: -1, in: fileContent)
        guard result.text != fileContent else { return }
        fileContent = result.text
        isEdited = true
        navigateEditor(toLine: result.line)
    }

    func moveCurrentLineDown() {
        let result = Self.moveLine(at: cursorLine, direction: 1, in: fileContent)
        guard result.text != fileContent else { return }
        fileContent = result.text
        isEdited = true
        navigateEditor(toLine: result.line)
    }

    func openContainingFolder() {
        guard let openedFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([openedFileURL])
    }

    func openSplitFile() {
        let panel = NSOpenPanel()
        panel.title = "Open Split File"
        panel.message = "Select a text file to show beside the current editor."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.loadSplitFile(from: url)
        }
    }

    func closeSplitEditor() {
        isSplitEditorVisible = false
        splitFileURL = nil
        splitFileContent = ""
    }

    func reloadCurrentFileFromDisk() {
        guard let openedFileURL else { return }
        loadFile(from: openedFileURL, fallbackURL: openedFileURL, allowLargeFile: true)
        hasExternalFileChanges = false
    }

    func refreshExternalFileStatus() {
        guard let openedFileURL,
              let knownDate = knownModificationDates[openedFileURL],
              let currentDate = Self.modificationDate(at: openedFileURL) else {
            hasExternalFileChanges = false
            return
        }
        hasExternalFileChanges = currentDate > knownDate
    }

    func findNext() {
        let ranges = findMatchRanges
        guard !ranges.isEmpty else { return }
        activeFindIndex = (activeFindIndex + 1) % ranges.count
    }

    func findPrevious() {
        let ranges = findMatchRanges
        guard !ranges.isEmpty else { return }
        activeFindIndex = (activeFindIndex - 1 + ranges.count) % ranges.count
    }

    @discardableResult
    func replaceCurrentFindMatch() -> Bool {
        let ranges = findMatchRanges
        guard !ranges.isEmpty else { return false }

        let index = min(activeFindIndex, ranges.count - 1)
        let range = ranges[index]
        let mutable = NSMutableString(string: fileContent)
        mutable.replaceCharacters(in: range, with: replaceText)
        fileContent = mutable as String
        isEdited = true

        let nextRanges = findMatchRanges
        activeFindIndex = nextRanges.isEmpty ? 0 : min(index, nextRanges.count - 1)
        return true
    }

    @discardableResult
    func replaceAllFindMatches() -> Int {
        switch findReplaceScope {
        case .currentTab:
            return replaceAllInCurrentTab()
        case .openTabs:
            return replaceAllInOpenTabs()
        case .selectedFolder:
            return replaceAllInSelectedFolder()
        }
    }

    @discardableResult
    private func replaceAllInCurrentTab() -> Int {
        let ranges = findMatchRanges
        guard !ranges.isEmpty else { return 0 }

        let mutable = NSMutableString(string: fileContent)
        for range in ranges.reversed() {
            mutable.replaceCharacters(in: range, with: replaceText)
        }
        fileContent = mutable as String
        isEdited = true
        activeFindIndex = 0
        return ranges.count
    }

    @discardableResult
    private func replaceAllInOpenTabs() -> Int {
        guard !findQuery.isEmpty else { return 0 }

        var replacementCount = 0
        for index in tabs.indices {
            let ranges = Self.findRanges(in: tabs[index].content, query: findQuery)
            guard !ranges.isEmpty else { continue }

            tabs[index].content = Self.replacingRanges(ranges, in: tabs[index].content, with: replaceText)
            tabs[index].isEdited = true
            replacementCount += ranges.count
        }

        if let activeTabID, let activeIndex = tabs.firstIndex(where: { $0.id == activeTabID }) {
            isApplyingTabSnapshot = true
            fileContent = tabs[activeIndex].content
            isEdited = tabs[activeIndex].isEdited
            isApplyingTabSnapshot = false
        }

        activeFindIndex = 0
        return replacementCount
    }

    @discardableResult
    private func replaceAllInSelectedFolder() -> Int {
        guard !findQuery.isEmpty, let folder = selectedFolderURL ?? rootDirectory else {
            return 0
        }

        var replacementCount = 0
        let fileURLs = Self.textFileURLs(in: folder)

        for url in fileURLs {
            if let tabIndex = tabs.firstIndex(where: { $0.url == url }) {
                let ranges = Self.findRanges(in: tabs[tabIndex].content, query: findQuery)
                guard !ranges.isEmpty else { continue }

                let replaced = Self.replacingRanges(ranges, in: tabs[tabIndex].content, with: replaceText)
                do {
                    try replaced.write(to: url, atomically: true, encoding: .utf8)
                    tabs[tabIndex].content = replaced
                    tabs[tabIndex].isEdited = false
                    replacementCount += ranges.count
                } catch {
                    continue
                }
                continue
            }

            guard let data = try? Self.readFileData(from: url),
                  let content = String(data: data, encoding: .utf8) ?? Optional(Self.decodeText(from: data)) else {
                continue
            }

            let ranges = Self.findRanges(in: content, query: findQuery)
            guard !ranges.isEmpty else { continue }

            let replaced = Self.replacingRanges(ranges, in: content, with: replaceText)
            do {
                try replaced.write(to: url, atomically: true, encoding: .utf8)
                replacementCount += ranges.count
            } catch {
                continue
            }
        }

        if let activeTabID, let activeIndex = tabs.firstIndex(where: { $0.id == activeTabID }) {
            isApplyingTabSnapshot = true
            fileContent = tabs[activeIndex].content
            isEdited = tabs[activeIndex].isEdited
            isApplyingTabSnapshot = false
        }

        activeFindIndex = 0
        return replacementCount
    }

    nonisolated static func findRanges(in text: String, query: String) -> [NSRange] {
        guard !query.isEmpty, !text.isEmpty else { return [] }

        let nsText = text as NSString
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: nsText.length)

        while searchRange.length > 0 {
            let found = nsText.range(
                of: query,
                options: [.caseInsensitive],
                range: searchRange
            )
            guard found.location != NSNotFound, found.length > 0 else {
                break
            }

            ranges.append(found)
            let nextLocation = found.location + found.length
            searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
        }

        return ranges
    }

    nonisolated static func replacingRanges(_ ranges: [NSRange], in text: String, with replacement: String) -> String {
        let mutable = NSMutableString(string: text)
        for range in ranges.reversed() {
            mutable.replaceCharacters(in: range, with: replacement)
        }
        return mutable as String
    }

    nonisolated static func changedLineNumbers(current: String, saved: String) -> Set<Int> {
        let currentLines = current.components(separatedBy: .newlines)
        let savedLines = saved.components(separatedBy: .newlines)
        let maxCount = max(currentLines.count, savedLines.count)
        guard maxCount > 0 else { return [] }

        var changed: Set<Int> = []
        for index in 0..<maxCount {
            let currentLine = index < currentLines.count ? currentLines[index] : ""
            let savedLine = index < savedLines.count ? savedLines[index] : ""
            if currentLine != savedLine {
                changed.insert(index + 1)
            }
        }
        return changed
    }

    nonisolated static func contentForSave(_ content: String, settings: EditorSettings) -> String {
        var result = content
        if settings.trimsTrailingWhitespaceOnSave {
            result = trimTrailingWhitespace(in: result)
        }
        if settings.ensuresFinalNewlineOnSave, !result.isEmpty, !result.hasSuffix("\n") {
            result += "\n"
        }
        return result
    }

    nonisolated static func trimTrailingWhitespace(in content: String) -> String {
        let endsWithNewline = content.hasSuffix("\n")
        var lines = content.components(separatedBy: "\n")
        if endsWithNewline {
            lines.removeLast()
        }

        let trimmed = lines
            .map { line in
                String(line.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
            }
            .joined(separator: "\n")
        return endsWithNewline ? "\(trimmed)\n" : trimmed
    }

    nonisolated static func duplicateLine(at line: Int, in content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard !lines.isEmpty else { return content }
        let index = min(max(0, line - 1), lines.count - 1)
        lines.insert(lines[index], at: index + 1)
        return lines.joined(separator: "\n")
    }

    nonisolated static func moveLine(at line: Int, direction: Int, in content: String) -> (text: String, line: Int) {
        var lines = content.components(separatedBy: "\n")
        guard lines.count > 1 else { return (content, line) }

        let index = min(max(0, line - 1), lines.count - 1)
        let target = index + direction
        guard target >= 0, target < lines.count else {
            return (content, line)
        }

        lines.swapAt(index, target)
        return (lines.joined(separator: "\n"), target + 1)
    }

    nonisolated static func textFileURLs(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            if shouldRequireLargeFileConfirmation(at: url) || isBinaryFile(at: url) {
                continue
            }
            urls.append(url)
        }
        return urls
    }

    static let quickOpenFileLimit = 1_500

    nonisolated static func quickOpenFileURLs(in folder: URL, limit: Int = quickOpenFileLimit) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }

            urls.append(url)
        }

        return urls
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }

    func beginOpeningTab(for url: URL) {
        if activateTab(for: url) {
            return
        }

        let tab = EditorTab(url: url)
        tabs.append(tab)
        activeTabID = tab.id
        applySnapshot(from: tab, suppressURLChange: true)
    }

    @discardableResult
    func activateTab(id: EditorTab.ID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }) else {
            return false
        }
        imagePreviewURL = nil
        selectedSidebarFileURL = tab.url
        activeTabID = id
        applySnapshot(from: tab, suppressURLChange: true)
        return true
    }

    func openImagePreview(_ url: URL) {
        selectedSidebarFileURL = url
        imagePreviewURL = url
        registerRecentFile(url)
        registerRecentFolder(url.deletingLastPathComponent())
        updateWindowTitle(url: url, isEdited: false)
        persistSession()
    }

    func closeImagePreview() {
        imagePreviewURL = nil
        selectedSidebarFileURL = openedFileURL
        if let activeTab {
            updateWindowTitle(url: activeTab.url, isEdited: activeTab.isEdited)
        } else {
            updateWindowTitle(url: nil, isEdited: false)
        }
    }

    @discardableResult
    func activateTab(for url: URL) -> Bool {
        guard let tab = tabs.first(where: { $0.url == url }) else {
            return false
        }
        return activateTab(id: tab.id)
    }

    func closeActiveTab() {
        guard let activeTabID else {
            return
        }
        closeTab(id: activeTabID)
    }

    func closeTab(id: EditorTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        if tabs[index].isEdited {
            let tab = tabs[index]
            let alert = NSAlert()
            alert.messageText = "Unsaved Changes"
            alert.informativeText = "Do you want to save the changes made to \"\(tab.title)\"?"
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard saveTabBeforeClosing(at: index) else {
                    return
                }
            case .alertThirdButtonReturn:
                return
            default:
                break
            }
        }

        let wasActive = tabs[index].id == activeTabID
        let closedTab = tabs.remove(at: index)
        closedTabs.append(closedTab)
        closedTabs = Array(closedTabs.suffix(10))

        guard wasActive else {
            persistSession()
            return
        }

        if tabs.isEmpty {
            activeTabID = nil
            isApplyingTabSnapshot = true
            suppressURLChangeProcessing = true
            openedFileURL = nil
            fileContent = ""
            isEdited = false
            isApplyingTabSnapshot = false
            bumpEditorRenderRevision()
            bumpEditorHighlightRevision()
            updateWindowTitle(url: nil, isEdited: false)
            persistSession()
            return
        }

        let nextIndex = min(index, tabs.count - 1)
        let nextTab = tabs[nextIndex]
        activeTabID = nextTab.id
        applySnapshot(from: nextTab, suppressURLChange: true)
    }

    private func applySnapshot(from tab: EditorTab, suppressURLChange: Bool) {
        isApplyingTabSnapshot = true
        if suppressURLChange, openedFileURL != tab.url {
            suppressURLChangeProcessing = true
        }
        openedFileURL = tab.url
        fileContent = tab.content
        isEdited = tab.isEdited
        isApplyingTabSnapshot = false
        bumpEditorRenderRevision()
        bumpEditorHighlightRevision()
        updateWindowTitle(url: tab.url, isEdited: tab.isEdited)
        persistSession()
    }

    private func bumpEditorRenderRevision() {
        editorRenderRevision += 1
    }

    private func bumpEditorHighlightRevision() {
        editorHighlightRevision += 1
    }

    private func scheduleEditorSettingsSideEffects() {
        editorSettingsSideEffectsWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let normalizedSettings = self.editorSettings.normalized()
            if self.inspectorMode != normalizedSettings.preferredInspectorMode {
                self.inspectorMode = normalizedSettings.preferredInspectorMode
            }
            EditorSettingsStore.save(normalizedSettings)
            self.bumpEditorRenderRevision()
            self.bumpEditorHighlightRevision()
        }

        editorSettingsSideEffectsWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func updateActiveTab(_ mutation: (inout EditorTab) -> Void) {
        guard !isApplyingTabSnapshot,
              let activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID }) else {
            return
        }
        mutation(&tabs[index])
    }

    private func updateActiveTabAfterURLChange(to url: URL) {
        guard let activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID }) else {
            return
        }
        tabs[index].url = url
        tabs[index].content = fileContent
        tabs[index].savedContent = fileContent
        tabs[index].isEdited = isEdited
        tabs[index].isUntitled = false
    }

    private func saveTabBeforeClosing(at index: Int) -> Bool {
        guard tabs.indices.contains(index) else { return false }
        let tab = tabs[index]

        if tab.isUntitled {
            let previousActiveTabID = activeTabID
            activeTabID = tab.id
            applySnapshot(from: tab, suppressURLChange: true)
            let saved = saveCurrentFileAs()
            if !saved, let previousActiveTabID {
                activateTab(id: previousActiveTabID)
            }
            return saved
        }

        do {
            try tab.content.write(to: tab.url, atomically: true, encoding: .utf8)
            tabs[index].savedContent = tab.content
            tabs[index].isEdited = false
            return true
        } catch {
            let saveAlert = NSAlert()
            saveAlert.messageText = "Save Failed"
            saveAlert.informativeText = "Could not save \"\(tab.title)\": \(error.localizedDescription)"
            saveAlert.alertStyle = .critical
            saveAlert.addButton(withTitle: "OK")
            saveAlert.runModal()
            return false
        }
    }

    private static func untitledTabURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("veilwriter-untitled-\(UUID().uuidString)")
            .appendingPathExtension("txt")
    }

    private func updateWindowTitle(url: URL?, isEdited: Bool) {
        guard let window = NSApplication.shared.keyWindow else { return }
        window.title = activeTab?.title ?? url?.lastPathComponent ?? ""
        window.isDocumentEdited = isEdited
    }

    // MARK: - Folder Opening

    /// Presents an `NSOpenPanel` configured for directory selection and assigns
    /// the chosen URL to `rootDirectory`.
    func openFolder(openInNewWindow: ((URL) -> Void)? = nil) {
        let panel = Self.folderOpenPanel()

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openFolderURL(url, openInNewWindow: openInNewWindow)
        }
    }

    static func folderOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder"
        panel.message = "Select a directory to browse in the sidebar."
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return panel
    }

    // MARK: - File Opening

    /// Presents an `NSOpenPanel` configured for file selection. The selected file
    /// is assigned to `openedFileURL`; the view layer handles unsaved prompts,
    /// binary checks, size confirmation, and loading.
    func openFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a File"
        panel.message = "Select a text file to open in VeilWriter."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.registerRecentFile(url)
            self?.registerRecentFolder(url.deletingLastPathComponent())
            self?.openedFileURL = url
            self?.setRootDirectory(url.deletingLastPathComponent())
            self?.refreshGitStatus()
            self?.persistSession()
        }
    }

    // MARK: - File Size

    /// Maximum recommended file size for the editor (1 MB).
    /// Files larger than this trigger a user-confirmation dialog before loading.
    nonisolated static let maxFileSize: Int = 1_048_576

    enum FileLoadError: Error, Equatable {
        case fileTooLarge(Int64)
        case unreadable
    }

    /// Returns the file size (in bytes) of the resource at `url`, or `nil` if
    /// the attributes cannot be read.
    nonisolated static func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return nil
        }
        return size
    }

    nonisolated static func modificationDate(at url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else {
            return nil
        }
        return date
    }

    nonisolated static func shouldRequireLargeFileConfirmation(at url: URL) -> Bool {
        guard let size = fileSize(at: url) else { return false }
        return size > Int64(maxFileSize)
    }

    // MARK: - Binary Detection

    /// Reads the first 8192 bytes of the file at `url` and returns `true` if
    /// any null byte (`0x00`) is found, indicating a binary (non-text) file.
    nonisolated static func isBinaryFile(at url: URL) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            // If we can't open the file at all, treat as non-binary —
            // the read attempt in loadFile will surface the actual error.
            return false
        }
        defer { try? handle.close() }
        let chunk = handle.readData(ofLength: 8192)
        return chunk.contains(0)
    }

    nonisolated static func isImageFile(at url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "ico", "icns":
            return true
        default:
            return false
        }
    }

    // MARK: - File Loading

    /// Reads the file at `url` on a background queue, applies encoding detection
    /// (UTF-8 → NSString detection → ISO Latin 1 fallback), and updates
    /// `fileContent`, `isEdited`, and the window title on the main thread.
    ///
    /// If reading fails, the selection is reverted to `fallbackURL` (or `nil`).
    ///
    /// Caller is responsible for binary detection and unsaved-change dialogs
    /// before invoking this method. Size checks are enforced here as a backstop.
    func loadFile(from url: URL, fallbackURL: URL? = nil, allowLargeFile: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<String, FileLoadError>

            do {
                let data = try Self.readFileData(from: url, allowLargeFile: allowLargeFile)
                result = .success(Self.decodeText(from: data))
            } catch let error as FileLoadError {
                result = .failure(error)
            } catch {
                result = .failure(.unreadable)
            }

            DispatchQueue.main.async { [weak self] in
                self?.applyFileLoadResult(result, for: url, fallbackURL: fallbackURL)
            }
        }
    }

    private func applyFileLoadResult(_ result: Result<String, FileLoadError>, for url: URL, fallbackURL: URL?) {
        switch result {
        case .success(let content):
            applyLoadedContent(content, for: url)
        case .failure(.fileTooLarge(let size)):
            let alert = NSAlert()
            alert.messageText = "File Too Large"
            let limit = ByteCountFormatter.string(
                fromByteCount: Int64(Self.maxFileSize),
                countStyle: .file
            )
            let actualSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            alert.informativeText = "\"\(url.lastPathComponent)\" is \(actualSize); files over \(limit) require confirmation before loading."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            revertFailedLoad(for: url, fallbackURL: fallbackURL)
        case .failure(.unreadable):
            let alert = NSAlert()
            alert.messageText = "Cannot Read File"
            alert.informativeText = "The file \"\(url.lastPathComponent)\" could not be read."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            revertFailedLoad(for: url, fallbackURL: fallbackURL)
        }
    }

    private func applyLoadedContent(_ content: String, for url: URL) {
        if let index = tabs.firstIndex(where: { $0.url == url }) {
            tabs[index].content = content
            tabs[index].savedContent = content
            tabs[index].isEdited = false
        }

        guard openedFileURL == url else {
            return
        }

        isApplyingTabSnapshot = true
        fileContent = content
        isEdited = false
        isApplyingTabSnapshot = false
        bumpEditorRenderRevision()
        bumpEditorHighlightRevision()
        updateWindowTitle(url: url, isEdited: false)
        knownModificationDates[url] = Self.modificationDate(at: url)
        hasExternalFileChanges = false
        registerRecentFile(url)
        registerRecentFolder(url.deletingLastPathComponent())
        persistSession()
    }

    private func loadSplitFile(from url: URL) {
        guard !Self.isBinaryFile(at: url),
              let data = try? Self.readFileData(from: url),
              let content = String(data: data, encoding: .utf8) ?? Optional(Self.decodeText(from: data)) else {
            return
        }
        splitFileURL = url
        splitFileContent = content
        isSplitEditorVisible = true
        registerRecentFile(url)
    }

    private func revertFailedLoad(for url: URL, fallbackURL: URL?) {
        tabs.removeAll { $0.url == url && $0.content.isEmpty && !$0.isEdited }

        guard openedFileURL == url else {
            return
        }

        suppressURLChangeProcessing = true
        openedFileURL = fallbackURL
        if let fallbackURL, let fallbackTab = tabs.first(where: { $0.url == fallbackURL }) {
            activeTabID = fallbackTab.id
            applySnapshot(from: fallbackTab, suppressURLChange: false)
        } else {
            activeTabID = nil
            isApplyingTabSnapshot = true
            fileContent = ""
            isEdited = false
            isApplyingTabSnapshot = false
            bumpEditorRenderRevision()
            bumpEditorHighlightRevision()
            updateWindowTitle(url: nil, isEdited: false)
            persistSession()
        }
    }

    nonisolated static func readFileData(from url: URL, allowLargeFile: Bool = false) throws -> Data {
        if !allowLargeFile, let size = fileSize(at: url), size > Int64(maxFileSize) {
            throw FileLoadError.fileTooLarge(size)
        }

        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw FileLoadError.unreadable
        }
    }

    /// Runs the encoding detection pipeline on raw file data.
    ///
    /// 1. Try UTF-8.
    /// 2. Ask NSString to detect the encoding.
    /// 3. Fall back to ISO Latin 1.
    /// 4. Ultimate fallback: error placeholder.
    nonisolated static func decodeText(from data: Data) -> String {
        // 1. UTF-8 (covers the vast majority of modern text files).
        if let str = String(data: data, encoding: .utf8) {
            return str
        }

        // 2. NSString encoding detection.
        var convertedString: NSString?
        let rawEncoding = NSString.stringEncoding(
            for: data,
            encodingOptions: nil,
            convertedString: &convertedString,
            usedLossyConversion: nil
        )
        if rawEncoding != 0 {
            if let converted = convertedString {
                return converted as String
            }
            if let str = String(data: data, encoding: String.Encoding(rawValue: rawEncoding)) {
                return str
            }
        }

        // 3. ISO Latin 1 (covers many Western European encodings).
        if let str = String(data: data, encoding: .isoLatin1) {
            return str
        }

        // 4. Unable to decode — return a placeholder so the user sees something.
        return "Error: Unable to decode file contents."
    }

    // MARK: - File Saving

    /// Writes `fileContent` back to `openedFileURL` using UTF-8 encoding.
    /// On success clears the dirty flag and window indicator and returns `true`.
    /// On failure optionally presents an alert describing the error and returns `false`.
    @discardableResult
    func saveCurrentFile() -> Bool {
        if activeTab?.isUntitled == true {
            return saveCurrentFileAs()
        }

        guard let url = openedFileURL else {
            return saveCurrentFileAs()
        }
        return writeCurrentFile(to: url, updateOpenedURL: false)
    }

    /// Presents an `NSSavePanel` and writes `fileContent` to the chosen URL.
    /// On success updates the current file URL and clears dirty state.
    @discardableResult
    func saveCurrentFileAs() -> Bool {
        let panel = NSSavePanel()
        panel.title = "Save As"
        panel.message = "Choose where to save this file."
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = activeTab?.isUntitled == true ? "Untitled.txt" : (openedFileURL?.lastPathComponent ?? "Untitled.txt")

        guard panel.runModal() == .OK, let url = panel.url else {
            return false
        }

        return writeCurrentFile(to: url, updateOpenedURL: true)
    }

    @discardableResult
    func writeCurrentFile(to url: URL, updateOpenedURL: Bool, showsAlert: Bool = true) -> Bool {
        do {
            let contentToWrite = Self.contentForSave(fileContent, settings: editorSettings)
            if contentToWrite != fileContent {
                fileContent = contentToWrite
            }
            try contentToWrite.write(to: url, atomically: true, encoding: .utf8)
            if updateOpenedURL {
                suppressURLChangeProcessing = true
                openedFileURL = url
                rootDirectory = url.deletingLastPathComponent()
                updateActiveTabAfterURLChange(to: url)
            }
            updateActiveTab { tab in
                tab.savedContent = contentToWrite
            }
            isEdited = false
            updateWindowTitle(url: url, isEdited: false)
            knownModificationDates[url] = Self.modificationDate(at: url)
            hasExternalFileChanges = false
            registerRecentFile(url)
            registerRecentFolder(url.deletingLastPathComponent())
            refreshGitStatus()
            persistSession()
            return true
        } catch {
            guard showsAlert else {
                return false
            }

            let alert = NSAlert()
            alert.messageText = "Save Failed"
            alert.informativeText = "Could not save \"\(url.lastPathComponent)\": \(error.localizedDescription)"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
    }

    // MARK: - Session Restore

    func restoreSessionIfAvailable() {
        guard tabs.isEmpty, openedFileURL == nil, let session = SessionStore.load() else {
            return
        }

        if let rootURL = resolvedRootDirectory(from: session) {
            setRootDirectory(rootURL)
            registerRecentFolder(rootURL)
        }

        var restoredTabs: [EditorTab] = []
        for path in session.tabPaths {
            let url = URL(fileURLWithPath: path)
            guard !Self.isBinaryFile(at: url),
                  let data = try? Self.readFileData(from: url),
                  let content = String(data: data, encoding: .utf8) ?? Optional(Self.decodeText(from: data)) else {
                continue
            }
            restoredTabs.append(EditorTab(url: url, content: content, savedContent: content, isEdited: false))
        }

        guard !restoredTabs.isEmpty else { return }

        tabs = restoredTabs
        let activeURL = session.activeTabPath.map { URL(fileURLWithPath: $0) }
        let activeTab = activeURL.flatMap { url in restoredTabs.first { $0.url == url } } ?? restoredTabs[0]
        activeTabID = activeTab.id
        applySnapshot(from: activeTab, suppressURLChange: true)
    }

    func persistSession() {
        let restorableTabs = tabs.filter { !$0.isUntitled }
        let session = EditorSessionSnapshot(
            rootDirectoryPath: rootDirectory?.path,
            rootDirectoryBookmarkData: rootDirectory.flatMap { bookmarkData(for: $0) },
            tabPaths: restorableTabs.map(\.url.path),
            activeTabPath: activeTab?.isUntitled == true ? nil : activeTab?.url.path
        )
        SessionStore.save(session)
    }

    private func setRootDirectory(_ url: URL) {
        activateSecurityScope(for: url)
        rootDirectory = url
        selectedFolderURL = url
        // Security scope is active above, so the background verify scan can read
        // the project; the cache itself lives in Caches (outside the scope).
        refreshProjectFileList()
    }

    @discardableResult
    private func activateSecurityScope(for url: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        guard !securityScopedAccessURLs.contains(standardizedURL) else {
            return true
        }

        guard standardizedURL.startAccessingSecurityScopedResource() else {
            return false
        }

        securityScopedAccessURLs.insert(standardizedURL)
        return true
    }

    private func bookmarkData(for url: URL) -> Data? {
        activateSecurityScope(for: url)
        return try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func resolvedRootDirectory(from session: EditorSessionSnapshot) -> URL? {
        if let bookmarkData = session.rootDirectoryBookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                activateSecurityScope(for: url)
                return url
            }
        }

        guard let rootPath = session.rootDirectoryPath else { return nil }
        return URL(fileURLWithPath: rootPath)
    }

    private func terminalTargetURL(for url: URL?) -> URL {
        let candidate = url ?? selectedFolderURL ?? openedFileURL ?? rootDirectory
        guard let candidate else {
            return FileManager.default.homeDirectoryForCurrentUser
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return candidate
        }

        return candidate.deletingLastPathComponent()
    }

    private func relativePath(for url: URL) -> String {
        guard let rootDirectory else { return url.path }
        let rootPath = rootDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else {
            return path
        }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func promptForName(
        title: String,
        message: String,
        placeholder: String,
        onConfirm: @escaping (String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = placeholder
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            showFileOperationError("Enter a valid name.")
            return
        }

        onConfirm(name)
    }

    private func showFileOperationError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "File Operation Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    nonisolated static func loadGitStatus(for directoryURL: URL) -> GitRepositoryStatus {
        guard let repositoryRoot = findGitRepositoryRoot(startingAt: directoryURL) else {
            return GitRepositoryStatus()
        }

        let branch = runGit(arguments: ["branch", "--show-current"], in: repositoryRoot)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let statusOutput = runGit(arguments: ["status", "--porcelain=v1", "-uall"], in: repositoryRoot)
        let entries = parseGitStatusPorcelain(statusOutput)

        return GitRepositoryStatus(
            repositoryRoot: repositoryRoot,
            branchName: branch.isEmpty ? "detached" : branch,
            entries: entries
        )
    }

    nonisolated static func parseGitStatusPorcelain(_ output: String) -> [String: GitFileStatusKind] {
        var result: [String: GitFileStatusKind] = [:]

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.count >= 4 else { continue }
            let x = line[line.startIndex]
            let y = line[line.index(after: line.startIndex)]
            let pathStart = line.index(line.startIndex, offsetBy: 3)
            var path = String(line[pathStart...])
            if let renameRange = path.range(of: " -> ") {
                path = String(path[renameRange.upperBound...])
            }

            result[path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))] = GitFileStatusKind(indexStatus: x, workTreeStatus: y)
        }

        return result
    }

    nonisolated private static func findGitRepositoryRoot(startingAt directoryURL: URL) -> URL? {
        var currentURL = directoryURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: currentURL.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            currentURL.deleteLastPathComponent()
        }

        while true {
            if FileManager.default.fileExists(atPath: currentURL.appendingPathComponent(".git").path) {
                return currentURL
            }

            let parentURL = currentURL.deletingLastPathComponent()
            guard parentURL.path != currentURL.path else { return nil }
            currentURL = parentURL
        }
    }

    nonisolated private static func runGit(arguments: [String], in repositoryRoot: URL) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return ""
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum GitFileStatusKind: String, Equatable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case untracked = "?"

    nonisolated init(indexStatus: Character, workTreeStatus: Character) {
        if indexStatus == "?" || workTreeStatus == "?" {
            self = .untracked
        } else if indexStatus == "A" || workTreeStatus == "A" {
            self = .added
        } else if indexStatus == "D" || workTreeStatus == "D" {
            self = .deleted
        } else if indexStatus == "R" || workTreeStatus == "R" {
            self = .renamed
        } else {
            self = .modified
        }
    }

    nonisolated static func aggregate(_ kinds: [GitFileStatusKind]) -> GitFileStatusKind? {
        kinds.max { $0.folderPriority < $1.folderPriority }
    }

    private nonisolated var folderPriority: Int {
        switch self {
        case .deleted:
            return 50
        case .renamed:
            return 40
        case .modified:
            return 30
        case .added:
            return 20
        case .untracked:
            return 10
        }
    }
}

struct GitRepositoryStatus: Equatable {
    var repositoryRoot: URL?
    var branchName: String?
    var entries: [String: GitFileStatusKind]

    nonisolated init(repositoryRoot: URL? = nil, branchName: String? = nil, entries: [String: GitFileStatusKind] = [:]) {
        self.repositoryRoot = repositoryRoot
        self.branchName = branchName
        self.entries = entries
    }

    nonisolated var isRepository: Bool {
        repositoryRoot != nil
    }

    nonisolated func kind(for url: URL) -> GitFileStatusKind? {
        guard let repositoryRoot else { return nil }
        let rootPath = repositoryRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
        let relativePath = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let kind = entries[relativePath] {
            return kind
        }

        let prefix = relativePath.isEmpty ? "" : relativePath + "/"
        let childKinds = entries.compactMap { path, kind in
            path.hasPrefix(prefix) ? kind : nil
        }
        return GitFileStatusKind.aggregate(childKinds)
    }
}

private enum RecentItemsStore {
    private static let filesKey = "im.some.veilwriter.recentFiles.v1"
    private static let foldersKey = "im.some.veilwriter.recentFolders.v1"
    private static let limit = 8

    static func loadFiles() -> [URL] {
        loadCleaned(key: filesKey)
    }

    static func loadFolders() -> [URL] {
        loadCleaned(key: foldersKey)
    }

    static func saveFiles(_ urls: [URL]) {
        save(urls, key: filesKey)
    }

    static func saveFolders(_ urls: [URL]) {
        save(urls, key: foldersKey)
    }

    static func add(_ url: URL, to urls: [URL]) -> [URL] {
        let standardized = url.standardizedFileURL
        let cleaned = urls.filter(Self.isEligible)
        guard isEligible(standardized) else {
            return Array(cleaned.prefix(limit))
        }

        let unique = cleaned.filter { $0.standardizedFileURL != standardized }
        return Array(([standardized] + unique).prefix(limit))
    }

    private static func loadCleaned(key: String) -> [URL] {
        let urls = load(key: key)
        let cleaned = Array(urls.filter(Self.isEligible).prefix(limit))
        if cleaned.map(\.path) != urls.map(\.path) {
            save(cleaned, key: key)
        }
        return cleaned
    }

    private static func load(key: String) -> [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    private static func save(_ urls: [URL], key: String) {
        UserDefaults.standard.set(urls.filter(Self.isEligible).map(\.path), forKey: key)
    }

    nonisolated fileprivate static func isEligible(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return !temporaryDirectoryPaths.contains { tempPath in
            path == tempPath || path.hasPrefix(tempPath + "/")
        }
    }

    nonisolated private static var temporaryDirectoryPaths: [String] {
        [
            FileManager.default.temporaryDirectory,
            URL(fileURLWithPath: NSTemporaryDirectory()),
            URL(fileURLWithPath: "/tmp"),
            URL(fileURLWithPath: "/private/tmp")
        ]
        .map { $0.standardizedFileURL.path }
    }
}

extension AppState {
    nonisolated static func isRecentItemEligibleForTesting(_ url: URL) -> Bool {
        RecentItemsStore.isEligible(url)
    }
}

private struct EditorSessionSnapshot: Codable {
    let rootDirectoryPath: String?
    let rootDirectoryBookmarkData: Data?
    let tabPaths: [String]
    let activeTabPath: String?
}

private enum SessionStore {
    private static let key = "im.some.veilwriter.session.v1"

    static func load() -> EditorSessionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(EditorSessionSnapshot.self, from: data)
    }

    static func save(_ snapshot: EditorSessionSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
