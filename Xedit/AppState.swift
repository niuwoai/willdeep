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
    nonisolated private static let maxAgentToolRounds = 64

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
            // Mirror back into the active library entry so the new
            // Settings UI doesn't drift from the legacy single-cfg
            // path. We only sync the fields that overlap (provider /
            // baseURL / api key / flash primary / pro primary); the
            // alternate lists are library-only and stay untouched.
            syncActiveLibraryEntryFromConfiguration()
        }
    }
    /// Multi-provider library — the durable source of truth for the
    /// Settings rewrite (Phase C). `agentConfiguration` above is
    /// derived from the active entry; selecting a different entry in
    /// Settings rebuilds the configuration on the spot.
    @Published var agentProviderLibrary: AgentProviderLibrary {
        didSet {
            AgentSettingsStore.saveProviderLibrary(agentProviderLibrary)
        }
    }
    // MARK: - Per-session state (rc2: delegated to activeRuntime)
    //
    // The 22 fields below used to be `@Published` stored properties.
    // rc2 moved them onto `AgentRuntime` (one runtime per AgentSession)
    // and turned the AppState-side names into get/set delegates that
    // route to `activeRuntime`. UI and AppState-internal call sites
    // are unchanged — they read/write `appState.agentMessages` etc.
    // exactly as before, but the data now lives on the runtime.
    //
    // Change notifications: `subscribeToActiveRuntime()` republishes
    // the active runtime's `objectWillChange` through AppState's own
    // publisher, so SwiftUI bindings against `appState.foo` still
    // refresh when the underlying runtime field mutates.
    //
    // When there is no active runtime (no session opened yet), reads
    // return safe defaults and writes are dropped. That matches the
    // pre-rc2 "empty AppState fields before any session exists" state.

    var agentMessages: [AgentMessage] {
        get { activeRuntime?.messages ?? [] }
        set { activeRuntime?.messages = newValue }
    }
    var agentPatchProposals: [AgentPatchProposal] {
        get { activeRuntime?.patchProposals ?? [] }
        set { activeRuntime?.patchProposals = newValue }
    }
    var agentToolCalls: [AgentToolCall] {
        get { activeRuntime?.toolCalls ?? [] }
        set { activeRuntime?.toolCalls = newValue }
    }
    var agentInput: String {
        get { activeRuntime?.input ?? "" }
        set { activeRuntime?.input = newValue }
    }
    var isAgentResponding: Bool {
        get { activeRuntime?.isResponding ?? false }
        set { activeRuntime?.isResponding = newValue }
    }
    /// Wall-clock moment the current turn started — set when the user's
    /// message is dispatched, cleared when the loop exits. The thinking
    /// banner reads this through a `TimelineView` so the elapsed seconds
    /// tick visibly while the model is still working.
    var agentTurnStartedAt: Date? {
        get { activeRuntime?.turnStartedAt }
        set { activeRuntime?.turnStartedAt = newValue }
    }
    var agentErrorMessage: String? {
        get { activeRuntime?.errorMessage }
        set { activeRuntime?.errorMessage = newValue }
    }
    var agentErrorDetails: AgentErrorDetails? {
        get { activeRuntime?.errorDetails }
        set { activeRuntime?.errorDetails = newValue }
    }
    /// Images staged in the composer for the next user message.
    var agentPendingImages: [AgentImageAttachment] {
        get { activeRuntime?.pendingImages ?? [] }
        set { activeRuntime?.pendingImages = newValue }
    }
    /// Skills the user attached via `@skill` for the next send.
    var agentPendingSkills: [AgentSkillEntry] {
        get { activeRuntime?.pendingSkills ?? [] }
        set { activeRuntime?.pendingSkills = newValue }
    }
    /// Files the user attached via the `@` picker for the next send.
    var agentPendingFiles: [AgentFileAttachment] {
        get { activeRuntime?.pendingFiles ?? [] }
        set { activeRuntime?.pendingFiles = newValue }
    }
    /// Whether the next send should include a workspace overview block.
    var agentPendingIncludeWorkspaceOverview: Bool {
        get { activeRuntime?.pendingIncludeWorkspaceOverview ?? false }
        set { activeRuntime?.pendingIncludeWorkspaceOverview = newValue }
    }
    /// Top-level interaction mode for the active session.
    var agentInteractionMode: AgentInteractionMode {
        get { activeRuntime?.interactionMode ?? .normal }
        set { activeRuntime?.interactionMode = newValue }
    }
    /// Current proposed/approved plan for Plan mode.
    var agentCurrentPlan: AgentPlan? {
        get { activeRuntime?.currentPlan }
        set { activeRuntime?.currentPlan = newValue }
    }
    /// Currently-pinned goal for Goal mode.
    var agentCurrentGoal: AgentGoal? {
        get { activeRuntime?.currentGoal }
        set { activeRuntime?.currentGoal = newValue }
    }

    /// True when Plan mode is on AND no plan exists yet OR the existing
    /// plan hasn't been approved. While true, all write/exec tools and
    /// patch application are blocked.
    var isPlanGateActive: Bool {
        activeRuntime?.isPlanGateActive ?? false
    }
    /// Messages the user queued while the agent was busy.
    var agentQueuedMessages: [AgentQueuedMessage] {
        get { activeRuntime?.queuedMessages ?? [] }
        set { activeRuntime?.queuedMessages = newValue }
    }
    /// Per-session concrete model override.
    var agentSessionModelOverride: String? {
        get { activeRuntime?.sessionModelOverride }
        set { activeRuntime?.sessionModelOverride = newValue }
    }
    /// Live `git status` snapshot for the active session's workspace.
    var agentWorktreeChanges: AgentWorktreeChangeSummary {
        get { activeRuntime?.worktreeChanges ?? .init() }
        set { activeRuntime?.worktreeChanges = newValue }
    }
    /// Model IDs the user has previously fetched in Settings — surfaced in
    /// the Agent-mode model picker as a quick switcher.
    @Published var agentKnownModelIDs: [String] = []
    /// Command families the user has explicitly allowed Agent mode to run
    /// without prompting again, e.g. `git push`.
    @Published var agentAlwaysAllowedCommands: [AgentAlwaysAllowedCommand] = []
    /// When true, `run_command` invocations the static SafeCommand
    /// allowlist marks as `.alwaysSafe` (or the LLM judge confirms as
    /// safe) skip the Allow/Deny prompt and run immediately. Defaults
    /// to true so a fresh install gets the no-friction experience.
    @Published var autoApproveSafeCommands: Bool = AgentSettingsStore.loadAutoApproveSafeCommands() {
        didSet { AgentSettingsStore.saveAutoApproveSafeCommands(autoApproveSafeCommands) }
    }
    /// Persisted Agent-mode chat sessions, newest-updated first.
    @Published private(set) var agentSessions: [AgentSession] = []
    /// Persisted Agent routines (scheduled prompts), most-recently-updated
    /// first. Surfaces in the Agent-mode sidebar's Routines section and
    /// drives the AgentRoutineScheduler that wakes them up on schedule.
    @Published private(set) var agentRoutines: [AgentRoutine] = []
    private let agentRoutineScheduler = AgentRoutineScheduler()

    /// rc1 scaffold for v1.49's concurrent runtimes. One entry per
    /// session that the user has touched this launch. AppState still
    /// owns every `@Published agent*` field for now — rc2 starts
    /// moving real state in here and rewires UI bindings; rc3 enables
    /// per-runtime dispatch tasks for true parallel turns. Keeping the
    /// dictionary alive in rc1 just means session lifecycle code already
    /// knows where to create/destroy runtimes — when rc2 lands there's
    /// no scramble to retrofit lifecycle.
    @Published private(set) var agentRuntimes: [AgentSession.ID: AgentRuntime] = [:]

    /// The runtime backing the currently-selected session, or nil if
    /// no session is selected (or its session was deleted underneath
    /// us). Computed so it always reflects `activeAgentSessionID`.
    var activeRuntime: AgentRuntime? {
        guard let id = activeAgentSessionID else { return nil }
        return agentRuntimes[id]
    }
    /// Active Agent-mode session id. nil means "scratch" — Editor-mode
    /// chat keeps working without forcing a session to exist.
    @Published var activeAgentSessionID: AgentSession.ID?
    /// Mirrors `AgentSession.didEditFiles` for the active session — flips to
    /// true the moment the Agent successfully applies a patch in this
    /// session, and stays true until the session is replaced. Used to gate
    /// the worktree-change card so a fresh New Chat never shows it.
    /// Mirrors `AgentRuntime.didEditFiles` for the active session.
    /// Pre-rc2 this was `@Published private(set)`; the delegate keeps
    /// the same surface. Internal write call sites use `appState.agentSessionDidEditFiles = ...`
    /// which routes to the active runtime.
    var agentSessionDidEditFiles: Bool {
        get { activeRuntime?.didEditFiles ?? false }
        set { activeRuntime?.didEditFiles = newValue }
    }
    /// Top-level UI mode. Editor is the classic file editor; agent hides
    /// the editor and shows the conversation-first layout.
    @Published var appMode: AppMode = .editor
    /// Continuation resumed when the user resolves (approve/deny/confirm) the
    /// currently-blocked tool call. Internal to the agent loop. Delegated
    /// to `activeRuntime` post-rc2 — each runtime owns its own waiter so
    /// concurrent sessions don't fight over one slot.
    private var agentToolDecisionWaiter: CheckedContinuation<AgentToolDecision, Never>? {
        get { activeRuntime?.toolDecisionWaiter }
        set { activeRuntime?.toolDecisionWaiter = newValue }
    }
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
    /// Provider request `Task` for the active turn. Delegated to
    /// `activeRuntime` post-rc2 so each runtime can hold its own.
    private var agentRequestTask: Task<Void, Never>? {
        get { activeRuntime?.requestTask }
        set { activeRuntime?.requestTask = newValue }
    }
    private var editorSettingsSideEffectsWorkItem: DispatchWorkItem?
    private var editorSettingsObserver: AnyCancellable?
    /// Republishes EVERY runtime's `objectWillChange` through AppState's
    /// own publisher. Pre-rc4 this only forwarded the active runtime —
    /// fine for the chat pane (delegated `agent*` props point at active),
    /// but the sidebar busy dot needs to know when a background runtime
    /// flips `isResponding` too. One subscription per runtime, indexed by
    /// session id so we can drop them when sessions are deleted.
    private var runtimeSubscriptions: [AgentSession.ID: AnyCancellable] = [:]

    // MARK: - Per-provider concurrency (v1.49 rc3)
    //
    // Allow multiple sessions to run simultaneously, but cap each
    // provider so a routine fleet can't sprint past its rate limit.
    // The cap is per `providerID` (not per baseURL) — same provider,
    // different base URL, still one quota pool.
    //
    // When the cap is hit, additional dispatches go into
    // `pendingDispatchQueue` (FIFO) and drain as soon as a slot frees.

    /// Cap on simultaneous in-flight turns per provider. User-tunable
    /// via Settings → Agent → "Per-provider concurrency". Persisted to
    /// UserDefaults and applied immediately — raising it lets queued
    /// dispatches drain right away; lowering it stops promoting new
    /// dispatches until current ones finish (it never aborts running
    /// turns to enforce a smaller cap).
    @Published var perProviderConcurrencyLimit: Int = AgentSettingsStore.loadPerProviderConcurrencyLimit() {
        didSet {
            let clamped = max(1, min(8, perProviderConcurrencyLimit))
            if clamped != perProviderConcurrencyLimit {
                perProviderConcurrencyLimit = clamped
                return
            }
            AgentSettingsStore.savePerProviderConcurrencyLimit(clamped)
            // Raising the cap may free up slots for queued dispatches.
            drainPendingDispatchQueue()
        }
    }

    private var inFlightCountByProvider: [String: Int] = [:]
    private var pendingDispatchQueue: [PendingDispatch] = []

    private struct PendingDispatch {
        let runtimeID: AgentSession.ID
        let text: String
        let images: [AgentImageAttachment]
        let providerID: String
        let enqueuedAt: Date
    }

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
        // Load the multi-provider library — on first launch after the
        // Phase B change this auto-migrates the legacy configuration
        // into a single-entry library, so existing users land with
        // their previous setup already present in the new UI.
        self.agentProviderLibrary = AgentSettingsStore.loadProviderLibrary()
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
        self.agentAlwaysAllowedCommands = AgentSettingsStore.loadAlwaysAllowedCommands()
        // Sweep persisted "New Chat" rows that never received a user
        // message — every ⌘N press creates one on disk, and over time
        // the sidebar fills with identical empty placeholders. At launch
        // there's no active session yet, so this purges all of them.
        pruneEmptyAgentSessions()
        self.agentRoutines = AgentRoutineStore.loadAll()
        agentRoutineScheduler.start(initialRoutines: agentRoutines) { [weak self] routineID in
            self?.fireRoutine(id: routineID) ?? false
        }
        // No initial subscriptions to set up: runtimes are created
        // lazily as the user opens sessions, and `subscribeToRuntime`
        // runs at every creation site.
    }

    deinit {
        gitStatusRefreshTask?.cancel()
        quickOpenRefreshTask?.cancel()
        agentRequestTask?.cancel()
        for cancellable in runtimeSubscriptions.values { cancellable.cancel() }
        for url in securityScopedAccessURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Compatibility shim — pre-rc4 callers used to ask AppState to
    /// re-establish the change-forward link whenever `activeAgentSessionID`
    /// flipped. With per-runtime subscriptions the active flip is no
    /// longer special, but we make sure subscriptions exist for the
    /// active runtime (in case it was created off the lifecycle hooks).
    private func subscribeToActiveRuntime() {
        if let runtime = activeRuntime {
            subscribeToRuntime(runtime)
        }
    }

    /// Add the runtime's `objectWillChange` into AppState's republish
    /// chain. Idempotent — calling it twice for the same runtime is a
    /// no-op. Paired with `unsubscribeFromRuntime(id:)` when a session
    /// is deleted so cancellables don't leak.
    private func subscribeToRuntime(_ runtime: AgentRuntime) {
        if runtimeSubscriptions[runtime.id] != nil { return }
        runtimeSubscriptions[runtime.id] = runtime.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    private func unsubscribeFromRuntime(id: AgentSession.ID) {
        runtimeSubscriptions.removeValue(forKey: id)?.cancel()
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

    var primaryAgentChangedFile: AgentFileChangeSummary? {
        if let openedFileURL,
           let repositoryRoot = agentWorktreeChanges.repositoryRoot {
            let rootPath = repositoryRoot.standardizedFileURL.path
            let filePath = openedFileURL.standardizedFileURL.path
            if filePath == rootPath || filePath.hasPrefix(rootPath + "/") {
                let relativePath = String(filePath.dropFirst(rootPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if let activeChange = agentWorktreeChanges.change(for: relativePath) {
                    return activeChange
                }
            }
        }

        return agentWorktreeChanges.files.first
    }

    var shouldShowAgentThinkingIndicator: Bool {
        guard isAgentResponding, !isCompressingAgentContext else { return false }
        if agentToolCalls.contains(where: { call in
            call.status == .pendingApproval
                || call.status == .awaitingConfirm
                || call.status == .awaitingUserAnswer
        }) {
            return false
        }

        guard let lastMessage = agentMessages.last else { return false }
        switch lastMessage.role {
        case .user, .tool:
            return true
        case .assistant:
            return lastMessage.content.isEmpty && lastMessage.toolCalls.isEmpty
        case .system:
            return false
        }
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

    /// Submit the composer (text + staged images + skills + files + optional
    /// workspace overview). Queues if the agent is already responding.
    /// Editor-mode and Agent-mode share this entry point.
    func sendAgentMessage() {
        // The UI's send button always targets whatever session is on
        // screen — that's the active runtime by definition. If there
        // isn't one, lazily create one so a brand-new install can fire
        // off its first message without manually picking ⌘N first.
        guard let runtime = activeRuntime ?? activeRuntimeAfterCreatingNewSession() else { return }

        let userText = runtime.input.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = runtime.pendingImages
        let skills = runtime.pendingSkills
        let files = runtime.pendingFiles
        let includeWorkspaceOverview = runtime.pendingIncludeWorkspaceOverview
        guard !userText.isEmpty || !images.isEmpty || !skills.isEmpty || !files.isEmpty || includeWorkspaceOverview else { return }

        // Splice attached context (skills / files / workspace overview) in
        // front of the user's prose under labelled headers so the model
        // treats them as task setup rather than verbatim user text.
        let prompt = composeAttachedPrompt(
            userText: userText,
            skills: skills,
            files: files,
            includeWorkspaceOverview: includeWorkspaceOverview
        )

        runtime.input = ""
        runtime.pendingImages = []
        runtime.pendingSkills = []
        runtime.pendingFiles = []
        runtime.pendingIncludeWorkspaceOverview = false

        if runtime.isResponding {
            runtime.queuedMessages.append(AgentQueuedMessage(text: prompt, images: images))
            return
        }

        dispatchAgentMessage(for: runtime, text: prompt, images: images)
    }

    /// Fallback used by `sendAgentMessage` when the user typed into the
    /// composer before ever opening a session. Starts a new one so
    /// their message has somewhere to go.
    private func activeRuntimeAfterCreatingNewSession() -> AgentRuntime? {
        _ = startNewAgentSession()
        return activeRuntime
    }

    /// Build the outgoing prompt, prepending sections for attached
    /// skills, file contents (re-read from disk so the model sees the
    /// latest), and an optional workspace overview. Returns the user
    /// text unchanged when nothing is attached.
    private func composeAttachedPrompt(
        userText: String,
        skills: [AgentSkillEntry],
        files: [AgentFileAttachment],
        includeWorkspaceOverview: Bool
    ) -> String {
        guard !skills.isEmpty || !files.isEmpty || includeWorkspaceOverview else { return userText }
        var blocks: [String] = []
        blocks.append("The user attached the following context for this turn — treat it as task setup, not verbatim user text:")

        if includeWorkspaceOverview {
            blocks.append(workspaceOverviewBlock())
        }

        for skill in skills {
            let body = AgentSkillDirectory.loadBody(for: skill) ?? "(skill body unavailable)"
            blocks.append("""
            ### Skill: \(skill.identifier)
            > \(skill.description)

            \(body)
            """)
        }

        for file in files {
            let body = readAttachedFileBody(at: file.url)
            blocks.append("""
            ### File: \(file.relativePath)

            \(body)
            """)
        }

        if !userText.isEmpty {
            blocks.append("---")
            blocks.append(userText)
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Fenced excerpt of a file's contents, capped to keep one
    /// attachment from blowing the context budget. Falls back to a
    /// short placeholder when the file is unreadable or binary.
    private func readAttachedFileBody(at url: URL) -> String {
        let maxChars = 20_000
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return "```\n(file unreadable or binary)\n```"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if trimmed.count > maxChars {
            let idx = trimmed.index(trimmed.startIndex, offsetBy: maxChars)
            body = "\(trimmed[..<idx])\n\n[truncated at \(maxChars) chars]"
        } else {
            body = trimmed
        }
        return "```\n\(body)\n```"
    }

    /// A compact workspace overview: root path + a flat list of project
    /// files (already cached via `quickOpenFiles`). Capped so even a
    /// large repo overview stays reasonable.
    private func workspaceOverviewBlock() -> String {
        guard let root = rootDirectory else {
            return "### Workspace\n(no folder is currently open)"
        }
        let rootPath = root.standardizedFileURL.path
        let entries = quickOpenFiles
            .prefix(120)
            .map { url -> String in
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
                let rel = String(path.dropFirst(rootPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return rel.isEmpty ? url.lastPathComponent : rel
            }
        let extraCount = max(0, quickOpenFiles.count - 120)
        let extraLine = extraCount > 0 ? "\n…and \(extraCount) more files" : ""
        return """
        ### Workspace
        Root: \(rootPath)
        Files (first \(entries.count)):
        ```
        \(entries.joined(separator: "\n"))\(extraLine)
        ```
        """
    }

    // MARK: - Skill attachment

    /// Stage a skill for the next send. Idempotent — re-attaching the
    /// same skill is a no-op.
    func attachAgentSkill(_ skill: AgentSkillEntry) {
        guard !agentPendingSkills.contains(where: { $0.identifier == skill.identifier }) else { return }
        agentPendingSkills.append(skill)
    }

    /// Drop a single staged skill by identifier.
    func detachAgentSkill(identifier: String) {
        agentPendingSkills.removeAll { $0.identifier == identifier }
    }

    // MARK: - File / workspace attachment

    /// Stage a workspace file for the next send. Dedup by URL.
    func attachAgentFile(url: URL) {
        let standardized = url.standardizedFileURL
        guard !agentPendingFiles.contains(where: { $0.url.standardizedFileURL == standardized }) else { return }
        let relative: String = {
            guard let root = rootDirectory?.standardizedFileURL.path else { return standardized.lastPathComponent }
            let path = standardized.path
            guard path.hasPrefix(root) else { return standardized.lastPathComponent }
            let rel = String(path.dropFirst(root.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return rel.isEmpty ? standardized.lastPathComponent : rel
        }()
        agentPendingFiles.append(AgentFileAttachment(url: standardized, relativePath: relative))
    }

    /// Drop a single staged file by id (which is its standardized path).
    func detachAgentFile(id: String) {
        agentPendingFiles.removeAll { $0.id == id }
    }

    /// Toggle whether the workspace overview rides along next send.
    func toggleAgentWorkspaceOverview() {
        agentPendingIncludeWorkspaceOverview.toggle()
    }

    // MARK: - Provider library

    /// Reentrancy guard. Both `agentConfiguration` and
    /// `agentProviderLibrary` have didSets that talk to each other;
    /// the flag stops the loop on the second hop.
    private var isReconcilingProviderLibrary = false

    /// Reflect the active library entry's tier picks back into
    /// `agentConfiguration` so the existing agent loop (which still
    /// reads from the single configuration) sees the right provider
    /// + key + model the moment the user picks one in Settings.
    func applyActiveProviderLibraryEntry() {
        guard let entry = agentProviderLibrary.active else { return }
        isReconcilingProviderLibrary = true
        defer { isReconcilingProviderLibrary = false }
        var cfg = agentConfiguration
        cfg.providerID = entry.providerID
        cfg.baseURL = entry.baseURL
        cfg.apiKey = entry.apiKey
        cfg.flashModel = entry.flashPrimary
        cfg.proModel = entry.proPrimary
        // The active entry's routing mode wins — that's the whole
        // point of having a per-entry override. The user can still
        // pick a session-only override via the chat-mode picker.
        cfg.routingMode = entry.routingMode
        if cfg.model.isEmpty { cfg.model = entry.flashPrimary }
        agentConfiguration = cfg.normalized
    }

    /// Activate a different library entry by id and immediately apply
    /// it to the live configuration. No-op if the id is unknown.
    func setActiveProviderLibraryEntry(id: UUID) {
        guard agentProviderLibrary.entries.contains(where: { $0.id == id }) else { return }
        agentProviderLibrary.setActive(id)
        applyActiveProviderLibraryEntry()
    }

    /// Add or update a library entry. If the entry is the active one,
    /// the live configuration is refreshed too.
    func upsertProviderLibraryEntry(_ entry: AgentProviderEntry) {
        agentProviderLibrary.upsert(entry)
        if agentProviderLibrary.activeID == entry.id {
            applyActiveProviderLibraryEntry()
        }
    }

    /// Remove a library entry. The library auto-repoints `activeID`
    /// to the next entry; if nothing remains the live configuration
    /// is left as-is (the Settings UI is expected to require at
    /// least one entry to chat).
    func removeProviderLibraryEntry(id: UUID) {
        let wasActive = agentProviderLibrary.activeID == id
        agentProviderLibrary.remove(id: id)
        // Drop the Keychain row for the removed entry's API key.
        AgentSettingsStore.deleteLibraryEntryAPIKey(for: id)
        if wasActive, agentProviderLibrary.active != nil {
            applyActiveProviderLibraryEntry()
        }
    }

    /// Called from `agentConfiguration.didSet` — keeps the active
    /// library entry's mirrored fields in sync when an older code
    /// path (e.g. an in-flight Settings save, the model picker)
    /// writes directly to the configuration.
    private func syncActiveLibraryEntryFromConfiguration() {
        guard !isReconcilingProviderLibrary else { return }
        guard var active = agentProviderLibrary.active else {
            // No library yet — bootstrap one from the configuration
            // so the new UI has something to show.
            agentProviderLibrary = AgentProviderLibrary.migrate(from: agentConfiguration)
            return
        }
        var changed = false
        if active.providerID != agentConfiguration.providerID {
            active.providerID = agentConfiguration.providerID
            active.displayName = AgentProviderPreset.preset(id: agentConfiguration.providerID)?.displayName ?? active.displayName
            changed = true
        }
        if active.baseURL != agentConfiguration.baseURL {
            active.baseURL = agentConfiguration.baseURL
            changed = true
        }
        if active.apiKey != agentConfiguration.apiKey {
            active.apiKey = agentConfiguration.apiKey
            changed = true
        }
        if active.flashPrimary != agentConfiguration.flashModel {
            active.flashPrimary = agentConfiguration.flashModel
            changed = true
        }
        if active.proPrimary != agentConfiguration.proModel {
            active.proPrimary = agentConfiguration.proModel
            changed = true
        }
        if active.routingMode != agentConfiguration.routingMode {
            active.routingMode = agentConfiguration.routingMode
            changed = true
        }
        guard changed else { return }
        agentProviderLibrary.upsert(active)
    }

    // MARK: - Interaction modes (plan / goal)

    /// Flip the session into a different interaction mode. Switching out
    /// of Plan or Goal also drops any associated state so the next
    /// session pick-up starts clean.
    func setAgentInteractionMode(_ mode: AgentInteractionMode) {
        guard agentInteractionMode != mode else { return }
        agentInteractionMode = mode
        if mode != .plan { agentCurrentPlan = nil }
        if mode != .goal { agentCurrentGoal = nil }
        persistActiveAgentSession()
    }

    /// User clicks Approve on the proposed plan — flips it to approved
    /// so the next turn's system prompt unlocks write tools.
    func approveAgentPlan() {
        guard var plan = agentCurrentPlan else { return }
        plan.status = .approved
        agentCurrentPlan = plan
        persistActiveAgentSession()
    }

    /// User clicks Reject — drops the plan so the agent re-plans next turn.
    func rejectAgentPlan() {
        agentCurrentPlan = nil
        persistActiveAgentSession()
    }

    /// Manually retire an approved plan (e.g. after the agent reported done).
    func completeAgentPlan() {
        guard var plan = agentCurrentPlan else { return }
        plan.status = .done
        agentCurrentPlan = plan
        persistActiveAgentSession()
    }

    /// Ask the agent to revise the current plan. Drops the existing
    /// plan (so the system prompt flips back to "needs a plan") and
    /// auto-sends a user message — either the bare "please revise"
    /// boilerplate, or the caller's free-form note appended to it.
    /// Falls through to the normal queue path if the agent is busy.
    func requestPlanRevision(note: String) {
        guard agentInteractionMode == .plan else { return }
        // Drop the existing plan so the next turn's system prompt
        // sends the "you must emit a ```plan block" instructions.
        agentCurrentPlan = nil
        persistActiveAgentSession()

        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt: String
        if trimmed.isEmpty {
            prompt = "Please revise the plan. Re-emit a fresh ```plan``` block reflecting the new approach, then stop and wait for approval."
        } else {
            prompt = """
            Please revise the plan with this guidance from me:

            \(trimmed)

            Re-emit a fresh ```plan``` block reflecting the new approach, then stop and wait for approval.
            """
        }

        guard let runtime = activeRuntime else { return }
        if runtime.isResponding {
            runtime.queuedMessages.append(AgentQueuedMessage(text: prompt, images: []))
            return
        }
        dispatchAgentMessage(for: runtime, text: prompt, images: [])
    }

    /// Parse the most recent assistant message looking for a ```plan
    /// fenced block and replace `agentCurrentPlan` if one is found and
    /// the user hasn't already approved a plan this session. Convenience
    /// wrapper that targets `activeRuntime`; the turn loop calls the
    /// runtime-explicit variant below.
    func captureAgentPlanFromLatestMessage() {
        guard let runtime = activeRuntime else { return }
        captureAgentPlanFromLatestMessage(for: runtime)
    }

    func captureAgentPlanFromLatestMessage(for runtime: AgentRuntime) {
        guard runtime.interactionMode == .plan else { return }
        if let existing = runtime.currentPlan,
           existing.status == .approved || existing.status == .executing || existing.status == .done {
            applyAgentPlanProgressFromLatestMessage(for: runtime, existingPlan: existing)
            return
        }
        guard let last = runtime.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }),
              let parsed = AgentPlanParser.extract(from: last.content) else {
            return
        }
        runtime.currentPlan = parsed
    }

    private func applyAgentPlanProgressFromLatestMessage(for runtime: AgentRuntime, existingPlan: AgentPlan) {
        guard let last = runtime.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }) else { return }
        if let next = AgentPlanParser.applyProgress(to: existingPlan, from: last.content) {
            runtime.currentPlan = next
        }
    }

    /// Convenience wrapper that targets `activeRuntime`.
    func captureAgentGoalEvaluationFromLatestMessage() {
        guard let runtime = activeRuntime else { return }
        captureAgentGoalEvaluationFromLatestMessage(for: runtime)
    }

    func captureAgentGoalEvaluationFromLatestMessage(for runtime: AgentRuntime) {
        guard runtime.interactionMode == .goal,
              let goal = runtime.currentGoal,
              !goal.checklist.isEmpty else { return }
        guard let last = runtime.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }) else { return }
        if let updated = AgentGoalChecklistParser.applyEvaluation(to: goal, from: last.content) {
            runtime.currentGoal = updated
            persistAgentSession(runtime: runtime)
        }
    }

    /// Manually override a single step's status from the UI checkbox.
    /// Mirrors the model-driven path: bumps the plan to .executing on
    /// first touch, .done when everything is terminal.
    func setAgentPlanStepStatus(id: UUID, status: AgentPlan.StepStatus) {
        guard var plan = agentCurrentPlan,
              let idx = plan.steps.firstIndex(where: { $0.id == id }) else { return }
        plan.steps[idx].status = status
        let terminal: Set<AgentPlan.StepStatus> = [.done, .skipped, .failed]
        if plan.steps.allSatisfy({ terminal.contains($0.status) }) {
            plan.status = .done
        } else if plan.status == .approved {
            plan.status = .executing
        }
        agentCurrentPlan = plan
        persistActiveAgentSession()
    }

    /// Edit a step's text in place — handy when the agent's wording
    /// isn't quite right and the user wants to fix it before/during
    /// execution. Status is preserved.
    func editAgentPlanStepText(id: UUID, newText: String) {
        guard var plan = agentCurrentPlan,
              let idx = plan.steps.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        plan.steps[idx].text = trimmed
        agentCurrentPlan = plan
        persistActiveAgentSession()
    }

    /// Insert a fresh pending step before/after another step (or at the
    /// list start/end if `relativeToID` is nil). Plan status is left
    /// alone — adding a step to an executing plan keeps it executing.
    func insertAgentPlanStep(text: String, relativeToID: UUID?, before: Bool) {
        guard var plan = agentCurrentPlan else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let newStep = AgentPlan.Step(text: trimmed, status: .pending)
        let insertIdx: Int
        if let relativeToID, let i = plan.steps.firstIndex(where: { $0.id == relativeToID }) {
            insertIdx = before ? i : i + 1
        } else {
            insertIdx = before ? 0 : plan.steps.count
        }
        plan.steps.insert(newStep, at: insertIdx)
        // If the plan was already .done but a step was added, it's not
        // done anymore — bump it back to executing.
        if plan.status == .done {
            plan.status = .executing
        }
        agentCurrentPlan = plan
        persistActiveAgentSession()
    }

    /// Remove a step entirely. Promotes to .done if the remaining steps
    /// are all terminal; demotes to .approved if the plan becomes empty.
    func removeAgentPlanStep(id: UUID) {
        guard var plan = agentCurrentPlan,
              let idx = plan.steps.firstIndex(where: { $0.id == id }) else { return }
        plan.steps.remove(at: idx)
        let terminal: Set<AgentPlan.StepStatus> = [.done, .skipped, .failed]
        if plan.steps.isEmpty {
            plan.status = .approved   // back to "no progress yet" rather than .done
        } else if plan.steps.allSatisfy({ terminal.contains($0.status) }) {
            plan.status = .done
        }
        agentCurrentPlan = plan
        persistActiveAgentSession()
    }

    /// Reset a step (and every step after it) back to .pending, then
    /// ask the agent to resume from that point. "Run from here" — the
    /// common need when an earlier step's output turned out wrong and
    /// every downstream step has to be redone.
    func restartAgentPlanFromStep(id: UUID, note: String) {
        guard agentInteractionMode == .plan,
              var plan = agentCurrentPlan,
              let startIdx = plan.steps.firstIndex(where: { $0.id == id }) else { return }
        for i in startIdx..<plan.steps.count {
            plan.steps[i].status = .pending
        }
        // Plan stays approved/executing — we're not redoing the
        // approval gate, just rewinding the execution head.
        if plan.status == .done { plan.status = .executing }
        agentCurrentPlan = plan
        persistActiveAgentSession()

        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = "Please restart execution from step \(startIdx + 1) onward."
        let prompt: String
        if trimmed.isEmpty {
            prompt = "\(header) Steps \(startIdx + 1)..\(plan.steps.count) have been reset to pending. Pick up there and emit a `progress` block as you go."
        } else {
            prompt = """
            \(header) Steps \(startIdx + 1)..\(plan.steps.count) have been reset to pending. Here's why:

            \(trimmed)

            Pick up from step \(startIdx + 1) and emit a `progress` block as you go.
            """
        }
        guard let runtime = activeRuntime else { return }
        if runtime.isResponding {
            runtime.queuedMessages.append(AgentQueuedMessage(text: prompt, images: []))
            return
        }
        dispatchAgentMessage(for: runtime, text: prompt, images: [])
    }

    /// Replace the goal definition for Goal mode. Empty values clear it.
    /// Preserves existing checklist `done` state when an item's text
    /// hasn't changed — so the user can tweak the goal statement or add
    /// new items without losing what's already ticked.
    func setAgentGoal(statement: String, items: [String]) {
        let trimmedStatement = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedItems = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if trimmedStatement.isEmpty && trimmedItems.isEmpty {
            agentCurrentGoal = nil
            persistActiveAgentSession()
            return
        }
        let priorDone: [String: Bool] = Dictionary(uniqueKeysWithValues:
            (agentCurrentGoal?.checklist ?? []).map { ($0.text, $0.done) })
        agentCurrentGoal = AgentGoal(
            statement: trimmedStatement,
            checklist: trimmedItems.map { text in
                AgentGoal.Item(text: text, done: priorDone[text] ?? false)
            }
        )
        persistActiveAgentSession()
    }

    /// Toggle a single checklist item by id. The flipped state shows up
    /// in the next system prompt, so the agent sees progress.
    func toggleAgentGoalItem(_ id: UUID) {
        guard var goal = agentCurrentGoal else { return }
        guard let idx = goal.checklist.firstIndex(where: { $0.id == id }) else { return }
        goal.checklist[idx].done.toggle()
        agentCurrentGoal = goal
        persistActiveAgentSession()
    }

    func reviewAgentWorktreeChanges() {
        guard !agentWorktreeChanges.isEmpty else { return }

        let files = agentWorktreeChanges.files
            .prefix(40)
            .map { change in
                "- \(change.path) \(Self.formatLineStats(change.lineStats))"
            }
            .joined(separator: "\n")
        let extraCount = max(0, agentWorktreeChanges.fileCount - 40)
        let extraLine = extraCount > 0 ? "\n- ...and \(extraCount) more files" : ""
        let prompt = """
        Please review the current uncommitted workspace changes.

        Focus on bugs, hangs/freezes, regressions, approval/security risks, and missing tests. Start with findings ordered by severity and cite file paths.

        Change summary:
        \(files)\(extraLine)
        """

        guard let runtime = activeRuntime else { return }
        runtime.input = ""
        runtime.pendingImages = []

        if runtime.isResponding {
            runtime.queuedMessages.append(AgentQueuedMessage(text: prompt, images: []))
            return
        }

        if appMode == .editor {
            isAgentPanelVisible = true
        }
        dispatchAgentMessage(for: runtime, text: prompt, images: [])
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

    private func dispatchAgentMessage(for runtime: AgentRuntime, text: String, images: [AgentImageAttachment]) {
        let configuration = configurationForCurrentTurn(for: runtime)
        let providerID = configuration.providerID

        // Concurrency gate: cap simultaneous turns per provider so a
        // routine fleet can't blow past the provider's rate limit. If
        // the slot isn't open, queue this dispatch — `releaseProviderSlot`
        // drains pending entries FIFO as turns finish.
        guard acquireProviderSlotIfPossible(providerID: providerID) else {
            pendingDispatchQueue.append(
                PendingDispatch(
                    runtimeID: runtime.id,
                    text: text,
                    images: images,
                    providerID: providerID,
                    enqueuedAt: Date()
                )
            )
            return
        }

        runtime.errorMessage = nil
        runtime.errorDetails = nil
        runtime.isResponding = true
        runtime.turnStartedAt = Date()

        let userMessage = AgentMessage(role: .user, content: text, images: images)
        runtime.messages.append(userMessage)
        let imageDescriptionConfiguration = agentConfiguration.normalized.imageDescription.agentConfiguration

        runtime.requestTask?.cancel()
        runtime.requestTask = Task { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            await self.prepareImagesForTextOnlyProvider(
                for: runtime,
                userMessageID: userMessage.id,
                mainConfiguration: configuration,
                imageDescriptionConfiguration: imageDescriptionConfiguration
            )
            await self.runAgentLoop(for: runtime, configuration: configuration)
        }
    }

    /// Try to claim a slot for `providerID`. Returns true if the cap
    /// wasn't reached and a slot was reserved; false if the caller
    /// should queue. Always pairs with `releaseProviderSlot(providerID:)`
    /// from the turn loop's defer so counts stay accurate even on
    /// thrown errors / cancellation.
    private func acquireProviderSlotIfPossible(providerID: String) -> Bool {
        let current = inFlightCountByProvider[providerID] ?? 0
        guard current < perProviderConcurrencyLimit else { return false }
        inFlightCountByProvider[providerID] = current + 1
        return true
    }

    private func releaseProviderSlot(providerID: String) {
        let current = inFlightCountByProvider[providerID] ?? 0
        if current <= 1 {
            inFlightCountByProvider.removeValue(forKey: providerID)
        } else {
            inFlightCountByProvider[providerID] = current - 1
        }
        // Drain any pending entries that can now grab the freshly
        // released slot. Walk once: each released slot can promote at
        // most one queued entry for the same provider; entries for
        // other providers stay in line.
        drainPendingDispatchQueue()
    }

    private func drainPendingDispatchQueue() {
        guard !pendingDispatchQueue.isEmpty else { return }
        var remaining: [PendingDispatch] = []
        remaining.reserveCapacity(pendingDispatchQueue.count)
        // Walk in FIFO order; promote the first entry per provider
        // that fits under the cap, leave the rest queued.
        var promotedByProvider: Set<String> = []
        for entry in pendingDispatchQueue {
            if promotedByProvider.contains(entry.providerID) {
                remaining.append(entry)
                continue
            }
            let current = inFlightCountByProvider[entry.providerID] ?? 0
            guard current < perProviderConcurrencyLimit else {
                remaining.append(entry)
                continue
            }
            guard let runtime = agentRuntimes[entry.runtimeID] else {
                // Runtime was torn down (session deleted) — drop it.
                continue
            }
            promotedByProvider.insert(entry.providerID)
            dispatchAgentMessage(for: runtime, text: entry.text, images: entry.images)
        }
        pendingDispatchQueue = remaining
    }

    private func prepareImagesForTextOnlyProvider(
        for runtime: AgentRuntime,
        userMessageID: AgentMessage.ID,
        mainConfiguration: AgentConfiguration,
        imageDescriptionConfiguration: AgentConfiguration
    ) async {
        guard !mainConfiguration.supportsImageInput else { return }
        guard let index = runtime.messages.firstIndex(where: { $0.id == userMessageID }) else { return }
        let images = runtime.messages[index].images
        guard !images.isEmpty else { return }

        let description: String
        do {
            description = try await describeImagesForTextOnlyProvider(
                images,
                configuration: imageDescriptionConfiguration
            )
        } catch {
            description = "Image description failed before sending to \(mainConfiguration.providerID): \(error.localizedDescription)"
        }

        guard !Task.isCancelled,
              let liveIndex = runtime.messages.firstIndex(where: { $0.id == userMessageID }) else {
            return
        }
        runtime.messages[liveIndex].content = Self.contentByAppendingImageDescription(
            to: runtime.messages[liveIndex].content,
            description: description,
            imageCount: images.count,
            providerID: imageDescriptionConfiguration.providerID,
            model: imageDescriptionConfiguration.model
        )
    }

    private func describeImagesForTextOnlyProvider(
        _ images: [AgentImageAttachment],
        configuration: AgentConfiguration
    ) async throws -> String {
        let normalized = configuration.normalized
        guard normalized.supportsImageInput else {
            throw AgentClientError.serverStatus(
                AgentProviderHTTPError(
                    statusCode: 400,
                    method: "POST",
                    url: normalized.baseURL,
                    providerID: normalized.providerID,
                    model: normalized.model,
                    requestSummary: "Image description provider does not support image input.",
                    requestBody: "(not sent)",
                    responseBody: "Choose an image-capable provider/model for Image Understanding."
                )
            )
        }

        let prompt = """
        Describe each attached image for a coding agent that cannot see images directly.
        Return concise but information-dense notes. For screenshots, include visible UI text, error messages, dialogs, file names, code snippets, tables, controls, layout, and anything likely relevant to debugging or implementation.
        If there are multiple images, number them as Image 1, Image 2, etc.
        """
        let message = AgentMessage(role: .user, content: prompt, images: images)
        let collector = CompressionSummaryCollector()
        try await AgentClient(configuration: normalized).streamChat(messages: [message]) { event in
            if case .textDelta(let delta) = event {
                await collector.append(delta)
            }
        }
        let result = await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw AgentClientError.invalidResponse
        }
        return result
    }

    nonisolated private static func contentByAppendingImageDescription(
        to content: String,
        description: String,
        imageCount: Int,
        providerID: String,
        model: String
    ) -> String {
        let header = "[Image description generated by \(providerID) / \(model) for \(imageCount) attached image\(imageCount == 1 ? "" : "s")]"
        let block = "\(header)\n\(description)"
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? block : "\(content)\n\n\(block)"
    }

    /// Resolve the configuration to use for this turn. Honours the per-
    /// session concrete model override if one is set; otherwise follows the
    /// global Flash/Pro route. Takes the runtime so concurrent runs each
    /// pick up their own override rather than whatever happened to be on
    /// the currently-selected one.
    private func configurationForCurrentTurn(for runtime: AgentRuntime) -> AgentConfiguration {
        var configuration = agentConfiguration.normalized.resolved(for: .interactive)
        if let override = runtime.sessionModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            configuration.model = override
        }
        return configuration.normalized
    }

    private func configurationForContextCompression() -> AgentConfiguration {
        agentConfiguration.normalized.resolved(for: .compression)
    }

    private func consumeNextQueuedMessageIfNeeded(for runtime: AgentRuntime) {
        // Wait for any in-flight compression to finish — otherwise the
        // user's queued message would race a compression that just got
        // kicked off in the same defer block.
        guard !runtime.isResponding, !runtime.isCompressingContext else { return }
        guard let next = runtime.queuedMessages.first else { return }
        runtime.queuedMessages.removeFirst()
        dispatchAgentMessage(for: runtime, text: next.text, images: next.images)
    }

    func clearAgentConversation() {
        agentRequestTask?.cancel()
        agentMessages.removeAll()
        agentPatchProposals.removeAll()
        agentToolCalls.removeAll()
        agentQueuedMessages.removeAll()
        agentPendingImages.removeAll()
        agentErrorMessage = nil
        agentErrorDetails = nil
        agentToolDecisionWaiter?.resume(returning: .denied(reason: "Conversation cleared"))
        agentToolDecisionWaiter = nil
        isAgentResponding = false
        agentTurnStartedAt = nil
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
            agentErrorDetails = nil
            isAgentResponding = false
            agentTurnStartedAt = nil
            startNewAgentSession()
        }
    }

    func toggleAppMode() {
        setAppMode(appMode == .agent ? .editor : .agent)
    }

    @discardableResult
    func startNewAgentSession() -> AgentSession {
        // Pre-rc2 this function cleared a wall of `agent*` fields on
        // AppState (messages, toolCalls, queued, errors, …). Under rc2
        // those fields delegate to `activeRuntime`, so clearing them
        // here would actually wipe the OUTGOING session's runtime —
        // the wrong thing. rc4 went further: the outgoing turn isn't
        // even cancelled. With per-runtime concurrency, "I want a new
        // chat" no longer implies "kill the one I was on" — the old
        // one keeps streaming in the background and the user can pick
        // it back up from the sidebar.

        // Garbage-collect any prior empty "New Chat" rows before adding a
        // fresh one — otherwise repeatedly pressing ⌘N stacks up empty
        // placeholders in the sidebar.
        pruneEmptyAgentSessions()

        let session = AgentSession(
            workspaceRootPath: rootDirectory?.standardizedFileURL.path,
            modelID: activeAgentModelID
        )
        agentSessions.insert(session, at: 0)
        // Build the runtime BEFORE flipping activeAgentSessionID — the
        // delegated `agent*` setters below all route to `activeRuntime`,
        // and there has to be one in `agentRuntimes` for those writes
        // to land somewhere.
        let newRuntime = AgentRuntime(session: session)
        agentRuntimes[session.id] = newRuntime
        subscribeToRuntime(newRuntime)
        activeAgentSessionID = session.id
        // These now go to the freshly-built runtime via delegation.
        agentSessionDidEditFiles = false
        agentInteractionMode = .normal
        agentCurrentPlan = nil
        agentCurrentGoal = nil
        AgentSessionStore.save(session)
        return session
    }

    /// Start a new session that belongs to a specific workspace, switching
    /// the current window's `rootDirectory` to that workspace first so the
    /// Agent's tool context matches the session's group. Used by the
    /// sidebar workspace-row context menu. Pass `nil` for the "no
    /// workspace" group — the new session is created with no root.
    @discardableResult
    func startNewAgentSession(inWorkspaceAt workspacePath: String?) -> AgentSession {
        if let workspacePath, !workspacePath.isEmpty {
            let url = URL(fileURLWithPath: workspacePath)
            // Only switch root if the target really is an existing
            // directory — a stale persisted path shouldn't break anything.
            if Self.isExistingDirectory(url),
               rootDirectory?.standardizedFileURL.path != url.standardizedFileURL.path {
                openFolderURL(url)
            }
        }
        return startNewAgentSession()
    }

    func selectAgentSession(id: AgentSession.ID) {
        guard agentSessions.contains(where: { $0.id == id }) else { return }
        // Save the outgoing session first.
        persistActiveAgentSession()

        // rc4: switching away from a session no longer kills its in-flight
        // turn. Each runtime owns its own request task and waiter; with
        // real concurrency in place, switching is purely a UI focus
        // change. The outgoing turn keeps streaming, and the sidebar's
        // status dot makes that visible (green pulse on the row you
        // just left). If the user actually wants to stop it, the Stop
        // button on that runtime's chat pane is the explicit affordance.

        // Make sure the destination runtime is built before flipping
        // `activeAgentSessionID` — delegated readers fall back to
        // safe defaults if the runtime is missing, which would briefly
        // show the new session as empty before the runtime appears.
        _ = runtime(for: id)
        activeAgentSessionID = id

        // Re-derive the session model override from the persisted
        // session record. The runtime carries it across the lifetime
        // of one launch, but a freshly-built runtime started from a
        // disk session needs this seeded.
        if let runtime = activeRuntime {
            let session = runtime.session
            let routedModel = agentConfiguration.normalized.model(for: .interactive)
            runtime.sessionModelOverride = session.modelID == routedModel ? nil : session.modelID
        }
    }

    /// Drop sessions that never received a user message — they're
    /// indistinguishable "New Chat" placeholders left behind by users
    /// who hit ⌘N and walked away. The currently-active session is
    /// preserved even when empty (the user is presumably about to type
    /// into it). Wipes both the in-memory list and the persisted JSON.
    private func pruneEmptyAgentSessions() {
        let activeID = activeAgentSessionID
        let toRemove = agentSessions.filter { session in
            if session.id == activeID { return false }
            return !session.messages.contains(where: { $0.role == .user })
        }
        guard !toRemove.isEmpty else { return }
        for session in toRemove {
            AgentSessionStore.delete(id: session.id)
        }
        let removedIDs = Set(toRemove.map(\.id))
        agentSessions.removeAll { removedIDs.contains($0.id) }
        // Tear down any runtimes left for the pruned sessions, lest
        // they keep republishing change events into AppState and
        // hold onto in-flight tasks for sessions that no longer exist.
        for id in removedIDs {
            agentRuntimes.removeValue(forKey: id)
            unsubscribeFromRuntime(id: id)
        }
    }

    /// Lazy lookup: returns the existing runtime for `sessionID` or
    /// builds one on demand from the persisted session list. Used by
    /// the session lifecycle hooks below to make sure every selected
    /// session has a runtime entry sitting in `agentRuntimes`. Returns
    /// nil only when the session id doesn't exist anymore (e.g. it was
    /// just deleted on disk).
    @discardableResult
    func runtime(for sessionID: AgentSession.ID) -> AgentRuntime? {
        if let existing = agentRuntimes[sessionID] { return existing }
        guard let session = agentSessions.first(where: { $0.id == sessionID }) else { return nil }
        let runtime = AgentRuntime(session: session)
        agentRuntimes[sessionID] = runtime
        subscribeToRuntime(runtime)
        return runtime
    }

    func deleteAgentSession(id: AgentSession.ID) {
        // If the doomed session is currently mid-turn, cancel its
        // in-flight work before tearing down the runtime so the URL
        // session task and tool-decision waiter don't leak. The
        // turn loop's defer will release the provider slot when the
        // cancellation propagates.
        if let doomed = agentRuntimes[id] {
            doomed.requestTask?.cancel()
            doomed.toolDecisionWaiter?.resume(returning: .denied(reason: "Session deleted"))
            doomed.toolDecisionWaiter = nil
        }
        // Drop any not-yet-started dispatches queued for this session
        // so they don't fire after the session is gone.
        pendingDispatchQueue.removeAll { $0.runtimeID == id }

        AgentSessionStore.delete(id: id)
        agentSessions.removeAll { $0.id == id }
        agentRuntimes.removeValue(forKey: id)
        unsubscribeFromRuntime(id: id)
        if activeAgentSessionID == id {
            activeAgentSessionID = nil
        }
    }

    // MARK: - Routines

    /// Insert or replace a routine, then persist + notify the scheduler.
    /// Used by both "create" (id not in list) and "edit" (id already
    /// present) paths from the routine editor sheet.
    func saveAgentRoutine(_ routine: AgentRoutine) {
        var updated = routine
        updated.updatedAt = Date()
        if let index = agentRoutines.firstIndex(where: { $0.id == updated.id }) {
            agentRoutines[index] = updated
        } else {
            agentRoutines.insert(updated, at: 0)
        }
        AgentRoutineStore.save(updated)
        agentRoutines.sort { $0.updatedAt > $1.updatedAt }
        agentRoutineScheduler.routinesChanged(agentRoutines)
        if updated.isEnabled {
            agentRoutineScheduler.requestNotificationAuthorizationIfNeeded()
        }
    }

    func deleteAgentRoutine(id: AgentRoutine.ID) {
        AgentRoutineStore.delete(id: id)
        agentRoutines.removeAll { $0.id == id }
        agentRoutineScheduler.routinesChanged(agentRoutines)
    }

    /// Flip enabled on/off in place. Cheaper than going through the
    /// editor sheet for the sidebar inline toggle.
    func toggleAgentRoutineEnabled(id: AgentRoutine.ID) {
        guard let index = agentRoutines.firstIndex(where: { $0.id == id }) else { return }
        agentRoutines[index].isEnabled.toggle()
        agentRoutines[index].updatedAt = Date()
        AgentRoutineStore.save(agentRoutines[index])
        agentRoutineScheduler.routinesChanged(agentRoutines)
        if agentRoutines[index].isEnabled {
            agentRoutineScheduler.requestNotificationAuthorizationIfNeeded()
        }
    }

    /// User-driven manual fire ("Run now" button in editor or sidebar).
    /// Ignores `isEnabled` — a disabled routine can still be run on demand.
    func runAgentRoutineNow(id: AgentRoutine.ID) {
        _ = fireRoutine(id: id, force: true)
    }

    /// Scheduler entry point. Returns true if the routine actually
    /// started a session; false if the routine was empty / missing
    /// (the scheduler will retry next tick if appropriate).
    ///
    /// Concurrency model (rc3+): routines spawn a background runtime
    /// rather than yanking the user's UI. They do NOT change
    /// `activeAgentSessionID` and do NOT flip `appMode`. The user
    /// keeps working in whatever session they had on screen; the
    /// routine's session shows up in the sidebar (with a "busy" dot
    /// once rc4 lands) and they can click into it later to inspect.
    @discardableResult
    private func fireRoutine(id: AgentRoutine.ID, force: Bool = false) -> Bool {
        _ = force // The per-provider concurrency cap replaces the old
                  // "is anyone responding?" gate; manual "Run now"
                  // doesn't need to bypass anything different.

        guard let index = agentRoutines.firstIndex(where: { $0.id == id }) else { return false }
        let routine = agentRoutines[index]
        let prompt = routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return false }

        // Build the session and its runtime, but DO NOT touch
        // activeAgentSessionID or appMode — that would yank the user
        // out of whatever they're reading.
        let session = AgentSession(
            workspaceRootPath: routine.workspaceRootPath,
            modelID: routine.modelID?.isEmpty == false ? routine.modelID : activeAgentModelID
        )
        agentSessions.insert(session, at: 0)
        AgentSessionStore.save(session)
        let runtime = AgentRuntime(session: session)
        agentRuntimes[session.id] = runtime
        subscribeToRuntime(runtime)
        if let modelID = routine.modelID, !modelID.isEmpty {
            runtime.sessionModelOverride = modelID
        }

        agentRoutines[index].lastRunAt = Date()
        agentRoutines[index].lastSessionID = session.id
        agentRoutines[index].updatedAt = Date()
        AgentRoutineStore.save(agentRoutines[index])
        agentRoutineScheduler.routinesChanged(agentRoutines)

        // dispatchAgentMessage handles the per-provider concurrency
        // cap — if the cap is hit, the dispatch queues and drains
        // FIFO as slots free. So even a fleet of 10 routines hitting
        // the same provider all at 09:00 won't stomp on each other.
        dispatchAgentMessage(for: runtime, text: prompt, images: [])
        return true
    }

    /// Toggle pin state. Pinned sessions float to the top of their
    /// workspace group, sorted by `pinnedAt` (most recently pinned
    /// first). The timestamp doubles as both the on/off flag and the
    /// within-pinned ordering key, so re-pinning sends the row back to
    /// the top of the pinned block.
    func toggleAgentSessionPinned(id: AgentSession.ID) {
        guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
        agentSessions[index].pinnedAt = agentSessions[index].pinnedAt == nil ? Date() : nil
        _ = AgentSessionStore.save(agentSessions[index])
    }

    /// Toggle archive state. Archived sessions disappear from the main
    /// workspace list and instead live under a collapsed "已归档" row
    /// at the bottom of each workspace group. Unarchiving puts them
    /// back into the active set with their original `updatedAt` intact
    /// so they sort back into their natural recency position.
    func toggleAgentSessionArchived(id: AgentSession.ID) {
        guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
        let willArchive = agentSessions[index].archivedAt == nil
        agentSessions[index].archivedAt = willArchive ? Date() : nil
        // Archiving the currently-active session shouldn't kick the
        // user out — the chat stays selected. They can pick another
        // session whenever they want; in the meantime the row simply
        // vanishes from the visible list, which is exactly what every
        // other chat app (Cursor, Slack, Linear) does.
        _ = AgentSessionStore.save(agentSessions[index])
    }

    /// Write the active session back to disk. No-op if no session is
    /// active (Editor-mode chats aren't persisted). Convenience wrapper
    /// that targets `activeRuntime`; concurrent code paths that need to
    /// persist a specific (potentially background) runtime should call
    /// `persistAgentSession(runtime:)` directly.
    func persistActiveAgentSession() {
        guard let runtime = activeRuntime else { return }
        persistAgentSession(runtime: runtime)
    }

    /// Persist a specific runtime's session. Used by the turn loop's
    /// defer so background runtimes that finish while the user is on a
    /// different session still write their final state to disk.
    func persistAgentSession(runtime: AgentRuntime) {
        guard let index = agentSessions.firstIndex(where: { $0.id == runtime.id }) else { return }
        if let override = runtime.sessionModelOverride, !override.isEmpty {
            runtime.session.modelID = override
        } else {
            runtime.session.modelID = activeAgentModelID
        }
        runtime.persist()
        agentSessions[index] = runtime.session
        agentSessions.sort { $0.updatedAt > $1.updatedAt }
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

    /// Chat-mode picker entry point — pick a (library entry, model)
    /// pair in one shot. When `entryID` differs from the current
    /// active, activates that entry first (rebuilds configuration),
    /// then sets the session override to `model`. Picking a model
    /// that already matches the route default clears the override so
    /// the chip falls back to displaying the routed name.
    func selectAgentEntryAndModel(entryID: UUID, model: String) {
        // Activate the target library entry — this rebuilds
        // agentConfiguration's provider / base URL / key / primaries.
        if agentProviderLibrary.activeID != entryID {
            setActiveProviderLibraryEntry(id: entryID)
        }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setAgentSessionModel(nil)
            return
        }
        // If the chosen model is already what the route would pick by
        // default, clear the override so the picker shows the natural
        // "Use route default" state instead of a redundant lock.
        let routed = agentConfiguration.normalized.model(for: .interactive)
        if trimmed == routed {
            setAgentSessionModel(nil)
        } else {
            setAgentSessionModel(trimmed)
        }
    }

    /// Best-effort token count for the next provider request. This mirrors
    /// the actual Agent request shape instead of only counting visible chat
    /// bubbles, so system context, tool schemas, collapsed tool history, and
    /// provider-ready message normalization are all represented.
    var estimatedAgentTokens: Int {
        let requestMessages = estimatedAgentRequestMessages
        let tools = AgentToolRegistry.all
        return Self.estimateAgentTokens(messages: requestMessages, tools: tools)
    }

    var activeAgentModelID: String {
        if let override = agentSessionModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return agentConfiguration.normalized.model(for: .interactive)
    }

    var agentModelStatusText: String {
        if let override = agentSessionModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return "Override · \(override)"
        }
        return agentConfiguration.normalized.routingLabel
    }

    private var estimatedAgentRequestMessages: [AgentMessage] {
        let systemPrompt = AgentContextBuilder.systemPrompt(
            rootDirectory: rootDirectory,
            openedFileURL: openedFileURL,
            fileContent: fileContent,
            selectedText: selectedText,
            language: effectiveLanguage,
            toolsEnabled: true,
            interactionMode: agentInteractionMode,
            currentPlan: agentCurrentPlan,
            currentGoal: agentCurrentGoal
        )
        let collapsedHistory = Self.collapseOldToolResults(in: agentMessages)
        return AgentClient.providerReadyMessages([
            AgentMessage(role: .system, content: systemPrompt)
        ] + collapsedHistory, supportsImages: agentConfiguration.normalized.supportsImageInput)
    }

    nonisolated static func estimateAgentTokens(
        messages: [AgentMessage],
        tools: [AgentToolDescriptor]
    ) -> Int {
        var total = 0

        for message in AgentClient.providerReadyMessages(messages) {
            total += 4
            total += estimateTextTokens(message.role.rawValue)
            total += estimateTextTokens(message.content)
            total += message.images.count * 600
            for call in message.toolCalls {
                total += 12
                total += estimateTextTokens(call.externalID)
                total += estimateTextTokens(call.toolName)
                total += estimateTextTokens(call.argumentsJSON)
            }
            if let toolCallID = message.toolCallID {
                total += estimateTextTokens(toolCallID)
            }
        }

        if !tools.isEmpty {
            total += 16
            for tool in tools {
                total += 24
                total += estimateTextTokens(tool.name)
                total += estimateTextTokens(tool.description)
                for parameter in tool.parameters {
                    total += 8
                    total += estimateTextTokens(parameter.name)
                    total += estimateTextTokens(parameter.type.rawValue)
                    total += estimateTextTokens(parameter.description)
                }
            }
        }

        total += 2
        return total
    }

    nonisolated private static func estimateTextTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var asciiNonWhitespace = 0
        var cjkScalars = 0
        var otherScalars = 0

        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            if scalar.value <= 0x7F {
                asciiNonWhitespace += 1
            } else if isCJKScalar(scalar) {
                cjkScalars += 1
            } else {
                otherScalars += 1
            }
        }

        let asciiTokens = Int(ceil(Double(asciiNonWhitespace) / 4.0))
        let otherTokens = Int(ceil(Double(otherScalars) * 0.8))
        return max(1, asciiTokens + cjkScalars + otherTokens)
    }

    nonisolated private static func isCJKScalar(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0x3040...0x30FF).contains(value)
            || (0xAC00...0xD7AF).contains(value)
    }

    /// Heuristic context-window budget for the active model. Falls back to
    /// a modern 128k window for unknown models so custom OpenAI-compatible
    /// models don't look full after one ordinary turn.
    var agentContextWindow: Int {
        Self.agentContextWindow(
            model: activeAgentModelID,
            providerID: agentConfiguration.providerID
        )
    }

    nonisolated static func agentContextWindow(model rawModel: String, providerID rawProviderID: String = "") -> Int {
        let model = rawModel.lowercased()
        let providerID = rawProviderID.lowercased()
        // Substring match — vendors include variants like `-32k`, `-128k` in the id.
        if model.contains("1m") || model.contains("-1m") || model.contains("1000k") { return 1_000_000 }
        if model.contains("512k") { return 512_000 }
        if model.contains("400k") { return 400_000 }
        if model.contains("200k") { return 200_000 }
        if model.contains("128k") || model.contains("-128k") { return 128_000 }
        if model.contains("64k") { return 64_000 }
        if model.contains("32k") { return 32_000 }
        if model.contains("16k") { return 16_000 }
        if model.contains("8k") { return 8_000 }
        // Known family defaults.
        if model.contains("gpt-5") { return 400_000 }
        if model.contains("gpt-4.1") { return 1_000_000 }
        if model.contains("gpt-4o") || model.contains("o1") || model.contains("o3") || model.contains("o4") { return 128_000 }
        if model.contains("claude") { return 200_000 }
        if model.contains("deepseek") { return 64_000 }
        if model.contains("qwen-long") { return 1_000_000 }
        if model.contains("qwen") || model.contains("dashscope") { return 128_000 }
        if model.contains("kimi") || model.contains("moonshot") { return 128_000 }
        if model.contains("gpt-3.5") { return 16_000 }
        if providerID == "openai" { return 128_000 }
        return 128_000
    }

    func approveAgentToolCall(id: AgentToolCall.ID) {
        resolveAgentToolCallDecision(id: id, decision: .approved)
    }

    func alwaysAllowAgentToolCall(id: AgentToolCall.ID) {
        guard let call = agentToolCalls.first(where: { $0.id == id }) else { return }
        if let rule = alwaysAllowedCommand(for: call) {
            addAgentAlwaysAllowedCommand(rule)
        }
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

    /// Resolve an `ask_user` call with the user's typed answer. Empty
    /// strings still resume the loop (so the model can react to "no answer
    /// provided"); use `denyAgentToolCall` to skip outright.
    func answerAgentToolCall(id: AgentToolCall.ID, answer: String) {
        resolveAgentToolCallDecision(id: id, decision: .answered(answer))
    }

    func removeAgentAlwaysAllowedCommand(id: AgentAlwaysAllowedCommand.ID) {
        agentAlwaysAllowedCommands.removeAll { $0.id == id }
        AgentSettingsStore.saveAlwaysAllowedCommands(agentAlwaysAllowedCommands)
    }

    func clearAgentAlwaysAllowedCommands() {
        agentAlwaysAllowedCommands = []
        AgentSettingsStore.saveAlwaysAllowedCommands(agentAlwaysAllowedCommands)
    }

    private func addAgentAlwaysAllowedCommand(_ command: AgentAlwaysAllowedCommand) {
        guard !agentAlwaysAllowedCommands.contains(where: { $0.commandSignature == command.commandSignature }) else {
            return
        }
        agentAlwaysAllowedCommands.append(command)
        agentAlwaysAllowedCommands.sort { $0.commandSignature < $1.commandSignature }
        AgentSettingsStore.saveAlwaysAllowedCommands(agentAlwaysAllowedCommands)
    }

    private func alwaysAllowedCommand(for call: AgentToolCall) -> AgentAlwaysAllowedCommand? {
        guard call.toolName == "run_command",
              let command = call.arguments["command"]?.stringValue(),
              let signature = AgentCommandAuthorization.signature(for: command) else {
            return nil
        }
        return AgentAlwaysAllowedCommand(commandSignature: signature)
    }

    private func isAgentToolCallAlwaysAllowed(toolName: String, arguments: [String: AgentJSONValue], risk: AgentToolRisk) -> Bool {
        guard risk == .write,
              toolName == "run_command",
              let command = arguments["command"]?.stringValue(),
              let signature = AgentCommandAuthorization.signature(for: command) else {
            return false
        }
        return agentAlwaysAllowedCommands.contains { $0.commandSignature == signature }
    }

    /// Resolve auto-approval for a write-tier tool call. Returns the
    /// source that approved it, or `nil` to mean "user must decide".
    /// Cheap paths (user allowlist, static SafeCommand) run inline; the
    /// LLM judge round-trips only when nothing cheaper matched.
    private func autoApprovalSource(
        toolName: String,
        arguments: [String: AgentJSONValue],
        risk: AgentToolRisk
    ) async -> AgentToolApprovalSource? {
        guard risk == .write, toolName == "run_command" else { return nil }

        // 1. User-pinned signatures (Always Allow button) — always honored.
        if isAgentToolCallAlwaysAllowed(toolName: toolName, arguments: arguments, risk: risk) {
            return .alwaysAllowList
        }

        // The remaining auto paths require both a command argument and
        // the user opting in via the master toggle.
        guard autoApproveSafeCommands,
              let command = arguments["command"]?.stringValue() else {
            return nil
        }

        // 2. Static read-only allowlist (zero latency, zero cost).
        switch SafeCommand.classify(command: command) {
        case .alwaysSafe:
            return .staticAllowlist
        case .alwaysDangerous:
            return nil
        case .needsJudgment:
            break
        }

        // 3. LLM judge. Lightweight non-streaming request; defaults to
        //    "no" on network errors so the user still gates anything we
        //    couldn't certify. We deliberately route the classifier
        //    through the Flash tier (not whatever model the current
        //    turn happens to be using) — it's a single-word YES/NO,
        //    cheap & fast on Flash, and we don't want Pro tokens spent
        //    on every "is `ls` safe?" check.
        let configuration = configurationForSafetyJudge()
        let client = AgentClient(configuration: configuration)
        let safe = await client.judgeCommandSafety(command: command)
        return safe ? .llmJudge : nil
    }

    /// Configuration used for the auto-approval safety judge. Always
    /// resolves to the active library entry's **Flash** model — small,
    /// cheap, fast — regardless of what tier the current turn is on.
    /// Falls back to the regular per-turn configuration if Flash isn't
    /// set (e.g. a custom provider entry only filled in a Pro model),
    /// because some classification is still better than no
    /// classification.
    private func configurationForSafetyJudge() -> AgentConfiguration {
        var configuration = agentConfiguration.normalized.resolved(for: .interactive)
        let flash = configuration.flashModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !flash.isEmpty {
            configuration.model = flash
        }
        return configuration.normalized
    }

    private func resolveAgentToolCallDecision(id: AgentToolCall.ID, decision: AgentToolDecision) {
        guard let index = agentToolCalls.firstIndex(where: { $0.id == id }) else { return }
        guard agentToolCalls[index].status == .pendingApproval
            || agentToolCalls[index].status == .awaitingConfirm
            || agentToolCalls[index].status == .awaitingUserAnswer else {
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
    private func runAgentLoop(for runtime: AgentRuntime, configuration: AgentConfiguration) async {
        defer {
            runtime.isResponding = false
            runtime.turnStartedAt = nil
            runtime.requestTask = nil
            captureAgentPlanFromLatestMessage(for: runtime)
            captureAgentGoalEvaluationFromLatestMessage(for: runtime)
            persistAgentSession(runtime: runtime)
            maybeAutoCompressContext(for: runtime)
            consumeNextQueuedMessageIfNeeded(for: runtime)
            // Always release the provider slot last so the queue drain
            // sees a fully cleared `isResponding` and won't refuse to
            // dispatch a queued user message that's for the same runtime.
            releaseProviderSlot(providerID: configuration.providerID)
        }

        let client = AgentClient(configuration: configuration)
        // Resolve the runtime's workspace path for tool execution —
        // never read AppState.rootDirectory here. Concurrent runtimes
        // can be running against different workspaces; the window's
        // current folder is a UI concept, not a session concept.
        let workspaceURL = runtime.workspaceRootPath.map { URL(fileURLWithPath: $0) }

        for _ in 0..<Self.maxAgentToolRounds {
            let assistantMessage = AgentMessage(role: .assistant, content: "")
            runtime.messages.append(assistantMessage)
            let assistantID = assistantMessage.id
            // Stamp the wall-clock start so we can attach an elapsed
            // seconds value to the message footer once the stream
            // finishes. We use the moment we hand the request off to
            // the client — pre-network — because that's what the user
            // perceives as "how long did the agent take".
            let turnStartedAt = Date()

            // Build the system prompt against the runtime's workspace,
            // not whatever the window happens to be focused on. The
            // active tab / selection still come from AppState — that's
            // window-level context the user can flip while another
            // session is running, and the model just sees it as
            // "what's on screen right now".
            let systemPrompt = AgentContextBuilder.systemPrompt(
                rootDirectory: workspaceURL,
                openedFileURL: openedFileURL,
                fileContent: fileContent,
                selectedText: selectedText,
                language: effectiveLanguage,
                toolsEnabled: true,
                interactionMode: runtime.interactionMode,
                currentPlan: runtime.currentPlan,
                currentGoal: runtime.currentGoal
            )
            let history = runtime.messages.filter { $0.id != assistantID }
            let collapsedHistory = Self.collapseOldToolResults(in: history)
            let requestMessages = [AgentMessage(role: .system, content: systemPrompt)] + collapsedHistory

            var finishReason: String?
            var latestToolCalls: [AgentMessageToolCall] = []

            do {
                try await client.streamChat(
                    messages: requestMessages,
                    tools: AgentToolRegistry.all
                ) { event in
                    await MainActor.run { [weak runtime] in
                        guard let runtime,
                              let index = runtime.messages.firstIndex(where: { $0.id == assistantID }) else {
                            return
                        }
                        switch event {
                        case .textDelta(let delta):
                            runtime.messages[index].content += delta
                        case .reasoningDelta(let delta):
                            // Append into reasoningContent so the next
                            // turn echoes it back verbatim. DashScope
                            // thinking-mode returns HTTP 400 if this
                            // field disappears between turns.
                            var existing = runtime.messages[index].reasoningContent ?? ""
                            existing += delta
                            runtime.messages[index].reasoningContent = existing
                        case .toolCallsUpdated(let calls):
                            runtime.messages[index].toolCalls = calls
                            latestToolCalls = calls
                        case .finishedTurn(let reason):
                            finishReason = reason
                        case .usageReported(let prompt, let completion, let total):
                            runtime.messages[index].usageTokens = total
                            runtime.messages[index].promptTokens = prompt > 0 ? prompt : nil
                            runtime.messages[index].completionTokens = completion > 0 ? completion : nil
                        }
                    }
                }
            } catch is CancellationError {
                if let index = runtime.messages.firstIndex(where: { $0.id == assistantID }),
                   runtime.messages[index].content.isEmpty,
                   runtime.messages[index].toolCalls.isEmpty {
                    runtime.messages.remove(at: index)
                }
                return
            } catch {
                setAgentError(error, for: runtime)
                if let index = runtime.messages.firstIndex(where: { $0.id == assistantID }),
                   runtime.messages[index].content.isEmpty,
                   runtime.messages[index].toolCalls.isEmpty {
                    runtime.messages.remove(at: index)
                }
                return
            }

            // Snapshot the assistant's final tool_calls list (the .toolCallsUpdated
            // closure may not have published the very last fragment yet if the
            // stream ended on the same chunk).
            if let index = runtime.messages.firstIndex(where: { $0.id == assistantID }) {
                if latestToolCalls.isEmpty {
                    latestToolCalls = runtime.messages[index].toolCalls
                } else {
                    runtime.messages[index].toolCalls = latestToolCalls
                }
                runtime.messages[index].elapsedSeconds = Date().timeIntervalSince(turnStartedAt)
            }

            // No tool calls → assistant finished talking. Capture patches and return.
            guard !latestToolCalls.isEmpty else {
                captureAgentPatchProposals(for: runtime, fromMessageID: assistantID)
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

                let risk = AgentToolRegistry.risk(
                    for: call.toolName,
                    arguments: argsDict,
                    rootDirectory: workspaceURL
                )

                let autoApproval = await autoApprovalSource(
                    toolName: call.toolName,
                    arguments: argsDict,
                    risk: risk
                )
                let isAlwaysAllowed = autoApproval != nil
                let initialStatus: AgentToolCallStatus
                if isAlwaysAllowed {
                    initialStatus = .running
                } else {
                    switch risk {
                    case .read: initialStatus = .running
                    case .write: initialStatus = .pendingApproval
                    case .danger: initialStatus = .awaitingConfirm
                    case .userInput: initialStatus = .awaitingUserAnswer
                    }
                }

                let record = AgentToolCall(
                    messageID: assistantID,
                    externalID: call.externalID,
                    toolName: call.toolName,
                    arguments: argsDict,
                    risk: risk,
                    status: initialStatus,
                    approvalSource: autoApproval
                )
                runtime.toolCalls.append(record)
                let recordID = record.id

                if risk == .userInput {
                    let decision = await awaitToolDecision(for: runtime, forCallID: recordID)
                    let answer: String
                    switch decision {
                    case .answered(let typed):
                        answer = typed
                    case .denied(let reason):
                        anyDenied = true
                        if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                            runtime.toolCalls[index].status = .denied
                            runtime.toolCalls[index].errorMessage = reason
                        }
                        appendToolMessage(
                            for: runtime,
                            toolCallID: call.externalID,
                            payload: "User skipped the question."
                        )
                        continue
                    case .approved:
                        answer = ""
                    }
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .succeeded
                        runtime.toolCalls[index].result = AgentToolResult(
                            summary: answer.isEmpty ? "(no answer)" : "answered",
                            payload: answer
                        )
                    }
                    appendToolMessage(for: runtime, toolCallID: call.externalID, payload: answer)
                    continue
                }

                // Plan mode: block any write/exec tool until the user has
                // approved a plan. The reply goes back as a tool error so
                // the model knows to stop and emit a plan.
                if risk != .read && runtime.isPlanGateActive {
                    anyDenied = true
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .denied
                        runtime.toolCalls[index].errorMessage = "Plan mode: needs user approval"
                    }
                    appendToolMessage(
                        for: runtime,
                        toolCallID: call.externalID,
                        payload: "Blocked: Plan mode is active and no plan has been approved yet. Emit a ```plan``` block listing the steps you intend to take, then stop and wait for the user to approve."
                    )
                    continue
                }

                if risk != .read && !isAlwaysAllowed {
                    let decision = await awaitToolDecision(for: runtime, forCallID: recordID)
                    if case .denied(let reason) = decision {
                        anyDenied = true
                        if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                            runtime.toolCalls[index].status = .denied
                            runtime.toolCalls[index].errorMessage = reason
                        }
                        appendToolMessage(
                            for: runtime,
                            toolCallID: call.externalID,
                            payload: "Tool call denied by the user."
                        )
                        continue
                    }
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .running
                        runtime.toolCalls[index].approvalSource = .user
                    }
                }

                let context = AgentToolContext(rootDirectory: workspaceURL)
                do {
                    let result = try await AgentToolRunner.run(
                        name: call.toolName,
                        arguments: argsDict,
                        context: context
                    )
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .succeeded
                        runtime.toolCalls[index].result = result
                    }
                    if call.toolName == "run_command" || risk != .read {
                        refreshGitStatus()
                    }
                    appendToolMessage(for: runtime, toolCallID: call.externalID, payload: result.payload)
                } catch {
                    if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                        runtime.toolCalls[index].status = .failed
                        runtime.toolCalls[index].errorMessage = error.localizedDescription
                    }
                    appendToolMessage(
                        for: runtime,
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

        runtime.errorMessage = "Agent paused after \(Self.maxAgentToolRounds) tool-call rounds to avoid an accidental loop. Send another message to continue."
        runtime.errorDetails = nil
    }

    private func setAgentError(_ error: Error, for runtime: AgentRuntime) {
        runtime.errorMessage = Self.friendlyMessage(for: error)
        runtime.errorDetails = Self.details(for: error)
    }

    /// Translate the raw `Error` thrown by `AgentClient` into a one-line
    /// Chinese caption that tells the user what happened and what to do
    /// next. Falls back to `localizedDescription` for the long tail of
    /// errors we don't specifically classify. The "Details" disclosure
    /// still surfaces the full provider payload for debugging.
    private static func friendlyMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "连接模型超时（120 秒内没收到数据）。可能是网络慢、代理掉线，或者模型本身排队。点击「重试」再试一次，或检查网络/代理。"
            case .notConnectedToInternet:
                return "当前似乎没有网络。检查 Wi-Fi 或网线后点「重试」。"
            case .networkConnectionLost:
                return "连接被中途断开。可能是网络抖动或代理重置。点「重试」再发一次。"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "无法连接到模型服务（DNS / 主机解析失败）。检查 Settings 里的 Base URL 是否正确，或代理是否能访问到该域名。"
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return "TLS / 证书校验失败。如果你在使用自签代理或镜像服务，需要先信任对应证书。"
            case .cancelled:
                return "请求被取消。"
            default:
                return "网络请求失败：\(urlError.localizedDescription)。点「重试」再发一次。"
            }
        }
        if let clientError = error as? AgentClientError {
            switch clientError {
            case .missingAPIKey:
                return "尚未配置 API Key。先到 Settings → Agent 里填好再发请求。"
            case .invalidBaseURL:
                return "Agent Base URL 不合法，先到 Settings 检查一下。"
            case .invalidResponse:
                return "模型返回了无法识别的内容（非标准 SSE/JSON）。如果反复出现，多半是 Base URL 指向了不兼容的服务。"
            case .serverStatus(let provider):
                let code = provider.statusCode
                let hint: String
                switch code {
                case 401, 403: hint = "鉴权失败，检查 API Key 是否正确、是否过期。"
                case 404:      hint = "接口路径找不到，检查 Base URL 与模型名是否匹配。"
                case 408, 504: hint = "上游网关超时。稍等片刻点「重试」即可。"
                case 429:      hint = "触发限流（QPS / 配额）。等几秒再点「重试」，或换一个更宽松的模型。"
                case 500...599: hint = "模型服务端 5xx 错误。多半是临时抽风，点「重试」。"
                default:       hint = "查看「Details」里的响应体定位原因。"
                }
                return "模型服务返回 HTTP \(code)。\(hint)"
            }
        }
        return error.localizedDescription
    }

    /// Whether the error banner should expose a "Retry" affordance.
    /// We allow retry whenever the loop is idle and there's at least one
    /// user message in the history — i.e. there's something to retry.
    var canRetryLastAgentTurn: Bool {
        guard !isAgentResponding, !isCompressingAgentContext else { return false }
        guard agentMessages.contains(where: { $0.role == .user }) else { return false }
        return true
    }

    /// Re-run `runAgentLoop` against the existing conversation. The user's
    /// last message is already in `agentMessages` (it stays in the history
    /// even when the assistant turn errors out), so we just kick the loop
    /// again with the current configuration. Used by the error card's
    /// "Retry" button when the previous turn died on a timeout or other
    /// transient network error.
    func retryLastAgentTurn() {
        guard canRetryLastAgentTurn,
              let runtime = activeRuntime else { return }
        let configuration = configurationForCurrentTurn(for: runtime)

        // Same gate as the dispatch path — a retry counts against the
        // provider quota just like a fresh send. Queueing is fine: when
        // a slot frees, the queue drain will pick up the runtime's
        // existing transcript and re-run.
        guard acquireProviderSlotIfPossible(providerID: configuration.providerID) else {
            // Retry button on the error card while the cap is busy:
            // do nothing rather than silently queue a re-run, because
            // the user's expectation is "right now" — leave the error
            // visible so they can click again in a moment.
            return
        }

        runtime.errorMessage = nil
        runtime.errorDetails = nil
        runtime.isResponding = true
        runtime.turnStartedAt = Date()

        runtime.requestTask?.cancel()
        runtime.requestTask = Task { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            await self.runAgentLoop(for: runtime, configuration: configuration)
        }
    }

    /// Dismiss the error banner without retrying — used by the "Close"
    /// (×) affordance on the error card. Keeps the user's last message in
    /// history so they can edit/copy and re-send manually.
    func dismissAgentError() {
        agentErrorMessage = nil
        agentErrorDetails = nil
    }

    private static func details(for error: Error) -> AgentErrorDetails? {
        guard case AgentClientError.serverStatus(let providerError) = error else {
            return nil
        }
        return AgentErrorDetails(sections: [
            AgentErrorDetails.Section(
                title: "Request",
                text: """
                Method: \(providerError.method)
                URL: \(providerError.url)
                Provider: \(providerError.providerID)
                Model: \(providerError.model)
                """
            ),
            AgentErrorDetails.Section(title: "Input Messages", text: providerError.requestSummary),
            AgentErrorDetails.Section(title: "Request Body", text: providerError.requestBody),
            AgentErrorDetails.Section(
                title: "Response",
                text: """
                HTTP \(providerError.statusCode)

                \(providerError.responseBody.isEmpty ? "(empty response body)" : providerError.responseBody)
                """
            )
        ])
    }

    private func awaitToolDecision(for runtime: AgentRuntime, forCallID id: AgentToolCall.ID) async -> AgentToolDecision {
        await withCheckedContinuation { continuation in
            // Already resolved before we got to register (e.g. user clicked
            // Deny while the previous tool was still running) — resume now.
            if let call = runtime.toolCalls.first(where: { $0.id == id }),
               call.status != .pendingApproval, call.status != .awaitingConfirm,
               call.status != .awaitingUserAnswer {
                if call.status == .denied {
                    continuation.resume(returning: .denied(reason: call.errorMessage ?? "User denied"))
                } else {
                    continuation.resume(returning: .approved)
                }
                return
            }
            runtime.toolDecisionWaiter = continuation
        }
    }

    private func appendToolMessage(for runtime: AgentRuntime, toolCallID: String, payload: String) {
        let limited: String
        let maxPayload = 24_000
        if payload.count > maxPayload {
            limited = String(payload.prefix(maxPayload)) + "\n...[tool output truncated]"
        } else {
            limited = payload
        }
        runtime.messages.append(
            AgentMessage(role: .tool, content: limited, toolCallID: toolCallID)
        )
    }

    /// True while context compression is running for the active session.
    /// Delegated to `activeRuntime.isCompressingContext`.
    var isCompressingAgentContext: Bool {
        get { activeRuntime?.isCompressingContext ?? false }
        set { activeRuntime?.isCompressingContext = newValue }
    }

    /// Summarize older conversation history into a single assistant
    /// message to reclaim context budget. Keeps the most recent
    /// `keepRecent` messages verbatim. Runs concurrently with whatever
    /// the user is doing (Send still works once compression resolves).
    func compressAgentContext(keepRecent: Int = 4) {
        guard let runtime = activeRuntime else { return }
        compressAgentContext(for: runtime, keepRecent: keepRecent)
    }

    func compressAgentContext(for runtime: AgentRuntime, keepRecent: Int = 4) {
        guard !runtime.isCompressingContext, !runtime.isResponding else { return }
        guard runtime.messages.count > keepRecent else { return }

        runtime.isCompressingContext = true
        let configuration = configurationForContextCompression()
        let head = Array(runtime.messages.prefix(runtime.messages.count - keepRecent))
        let tail = Array(runtime.messages.suffix(keepRecent))

        Task { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            await self.runContextCompression(
                for: runtime,
                head: head,
                tail: tail,
                configuration: configuration
            )
        }
    }

    /// Pure predicate: true if `maybeAutoCompressContext` would launch a
    /// compression right now for the active runtime. Exposed mainly for
    /// tests; the production caller is `maybeAutoCompressContext` itself.
    var shouldAutoCompressNow: Bool {
        guard let runtime = activeRuntime else { return false }
        return shouldAutoCompressNow(for: runtime)
    }

    func shouldAutoCompressNow(for runtime: AgentRuntime) -> Bool {
        guard !runtime.isCompressingContext, !runtime.isResponding else { return false }
        guard runtime.messages.count > 6 else { return false }
        let window = max(1, agentContextWindow)
        // Token estimate uses the runtime's own message list, not the
        // currently-displayed conversation — a background runtime can
        // get compressed while its session is not on screen.
        let collapsed = Self.collapseOldToolResults(in: runtime.messages)
        let used = Self.estimateAgentTokens(messages: collapsed, tools: AgentToolRegistry.all)
        let usedFraction = Double(used) / Double(window)
        return usedFraction > 0.75
    }

    /// Auto-compress when token usage crosses 75% and nothing else is in
    /// flight. Invoked from `runAgentLoop`'s defer so it runs between
    /// turns and never interrupts a streaming response.
    func maybeAutoCompressContext() {
        guard let runtime = activeRuntime else { return }
        maybeAutoCompressContext(for: runtime)
    }

    func maybeAutoCompressContext(for runtime: AgentRuntime) {
        guard shouldAutoCompressNow(for: runtime) else { return }
        compressAgentContext(for: runtime)
    }

    @MainActor
    private func runContextCompression(
        for runtime: AgentRuntime,
        head: [AgentMessage],
        tail: [AgentMessage],
        configuration: AgentConfiguration
    ) async {
        defer {
            runtime.isCompressingContext = false
            persistAgentSession(runtime: runtime)
            // Auto-compression can be racing with a queued message —
            // resume the queue once compression resolves so the user
            // doesn't see "queued" forever.
            consumeNextQueuedMessageIfNeeded(for: runtime)
        }

        let transcript = head
            .filter { $0.role != .system }
            .map { message -> String in
                let label: String
                switch message.role {
                case .user: label = "USER"
                case .assistant: label = "ASSISTANT"
                case .tool: label = "TOOL(\(message.toolCallID ?? "?"))"
                case .system: label = "SYSTEM"
                }
                return "\(label):\n\(message.content)"
            }
            .joined(separator: "\n\n---\n\n")

        let system = AgentMessage(
            role: .system,
            content: """
            You compress a coding-agent conversation transcript into a tight summary.
            Goal: preserve enough state that the agent can continue without re-reading the old turns.
            Cover, in this order: the user's goal, key decisions, file paths examined or modified, important findings, and any open questions. Skip pleasantries and verbatim quotes. Keep under 300 words. Output plain text, no preamble like "Here's the summary".
            """
        )
        let payload = AgentMessage(
            role: .user,
            content: "Transcript to compress:\n\n\(transcript)"
        )

        let client = AgentClient(configuration: configuration)
        let collector = CompressionSummaryCollector()
        do {
            try await client.streamChat(messages: [system, payload]) { event in
                if case .textDelta(let delta) = event {
                    await collector.append(delta)
                }
            }
        } catch {
            runtime.errorMessage = "Context compression failed: \(error.localizedDescription)"
            runtime.errorDetails = Self.details(for: error)
            return
        }

        let trimmed = await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            runtime.errorMessage = "Context compression returned an empty summary; nothing changed."
            runtime.errorDetails = nil
            return
        }

        let summaryMessage = AgentMessage(
            role: .assistant,
            content: "[Earlier conversation summary]\n\n\(trimmed)"
        )
        runtime.messages = [summaryMessage] + tail
        // Tool calls referencing pre-compression assistant messages no
        // longer have a valid messageID; drop them so they stop rendering.
        let liveMessageIDs = Set(runtime.messages.map(\.id))
        runtime.toolCalls.removeAll { !liveMessageIDs.contains($0.messageID) }
    }

    /// Replace the body of older `tool` role messages with a tiny
    /// placeholder so they stop dominating the request payload. The most
    /// recent `keepRecentToolMessages` tool messages are left untouched so
    /// the model can still reason about what it just did.
    nonisolated static func collapseOldToolResults(
        in messages: [AgentMessage],
        keepRecentToolMessages: Int = 4
    ) -> [AgentMessage] {
        // Find tool message indices.
        let toolIndices = messages.enumerated().compactMap { offset, message in
            message.role == .tool ? offset : nil
        }
        guard toolIndices.count > keepRecentToolMessages else { return messages }
        let collapseUpTo = toolIndices[toolIndices.count - keepRecentToolMessages - 1]

        var copy = messages
        for index in 0...collapseUpTo where copy[index].role == .tool {
            let original = copy[index]
            // Already collapsed.
            if original.content.hasPrefix("[tool result hidden") { continue }
            let bytes = original.content.utf8.count
            let placeholder = "[tool result hidden — earlier turn, was \(bytes) bytes; ask the user or re-run the tool if you need it again]"
            copy[index] = AgentMessage(
                id: original.id,
                role: .tool,
                content: placeholder,
                images: original.images,
                toolCalls: original.toolCalls,
                toolCallID: original.toolCallID,
                createdAt: original.createdAt
            )
        }
        return copy
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

    private func captureAgentPatchProposals(for runtime: AgentRuntime, fromMessageID messageID: UUID) {
        guard let message = runtime.messages.first(where: { $0.id == messageID }) else { return }
        let diffs = AgentPatchApplier.extractDiffBlocks(from: message.content)
        guard !diffs.isEmpty else { return }

        let existingDiffs = Set(runtime.patchProposals.map(\.diff))
        for (offset, diff) in diffs.enumerated() where !existingDiffs.contains(diff) {
            let title = diffs.count == 1 ? "Agent Patch" : "Agent Patch \(offset + 1)"
            runtime.patchProposals.append(
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

        // Mark this session as having had the Agent actually touch files so
        // the worktree-change card can show. Fresh sessions with no applied
        // patch never get the card, even if the repo has unrelated diffs.
        if !pendingWrites.isEmpty {
            agentSessionDidEditFiles = true
            persistActiveAgentSession()
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
        // Don't auto-promote the file's parent to `rootDirectory`. That used to
        // load the whole FileTree + run a recursive Quick Open scan + git
        // status for every "open file" — fatal latency when the parent is a
        // huge dir like ~/Downloads. The sidebar only appears now when the
        // user explicitly opens a folder (⇧⌘O / Open Folder…).
        openedFileURL = fileURL
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
            let emptyChanges = AgentWorktreeChangeSummary()
            DispatchQueue.main.async { [weak self] in
                self?.gitStatus = emptyStatus
                self?.agentWorktreeChanges = emptyChanges
            }
            return
        }

        let targetDirectory = rootDirectory.standardizedFileURL
        gitStatusRefreshTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                let status = Self.loadGitStatus(for: targetDirectory)
                let changes = Self.loadAgentWorktreeChangeSummary(status: status)
                return (status: status, changes: changes)
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.rootDirectory?.standardizedFileURL.path == targetDirectory.path else {
                    return
                }
                self.gitStatus = snapshot.status
                self.agentWorktreeChanges = snapshot.changes
            }
        }
    }

    func openAgentChangedFile(_ relativePath: String) {
        let base = agentWorktreeChanges.repositoryRoot ?? rootDirectory
        guard let base else { return }

        let url = base.appendingPathComponent(relativePath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return
        }

        registerRecentFile(url)
        openedFileURL = url
        if appMode == .agent {
            setAppMode(.editor)
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

    nonisolated static let quickOpenFileLimit = 1_500

    nonisolated static func quickOpenFileURLs(in folder: URL, limit: Int = quickOpenFileLimit) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var urls: [URL] = []
        let candidateLimit = max(limit * 4, limit)
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
                continue
            }
            if values.isDirectory == true {
                if ProjectDirectoryExclusions.shouldSkip(url) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }

            urls.append(url)
            if urls.count >= candidateLimit { break }
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
            // Same rationale as openExternalURL: opening a file no longer
            // promotes its parent to rootDirectory. Use Open Folder… (⇧⌘O)
            // to load the FileTree.
            self?.openedFileURL = url
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
                // Save As no longer hijacks the workspace root. If a folder
                // was explicitly opened, it stays; otherwise no FileTree
                // appears for the saved file's parent.
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

    nonisolated static func loadAgentWorktreeChangeSummary(status: GitRepositoryStatus) -> AgentWorktreeChangeSummary {
        guard let repositoryRoot = status.repositoryRoot else {
            return AgentWorktreeChangeSummary()
        }

        let numstatOutput = runGit(arguments: ["diff", "--numstat", "HEAD", "--"], in: repositoryRoot)
        let lineStats = parseGitNumstat(numstatOutput)
        let files: [AgentFileChangeSummary] = status.entries.compactMap { entry in
            let path = entry.key
            let kind = entry.value
            let stats = lineStats[path] ?? AgentLineChangeStats(added: nil, deleted: nil)
            let hasNumstatEntry = lineStats[path] != nil
            guard shouldIncludeAgentWorktreeChange(
                kind: kind,
                lineStats: stats,
                hasNumstatEntry: hasNumstatEntry
            ) else {
                return nil
            }
            return AgentFileChangeSummary(
                path: path,
                kind: kind,
                lineStats: stats
            )
        }

        return AgentWorktreeChangeSummary(repositoryRoot: repositoryRoot, files: files)
    }

    nonisolated static func shouldIncludeAgentWorktreeChange(
        kind: GitFileStatusKind,
        lineStats: AgentLineChangeStats,
        hasNumstatEntry: Bool
    ) -> Bool {
        if let added = lineStats.added, let deleted = lineStats.deleted {
            return added > 0 || deleted > 0
        }
        if hasNumstatEntry {
            return true
        }
        switch kind {
        case .added, .deleted, .renamed, .untracked:
            return true
        case .modified:
            return false
        }
    }

    nonisolated static func parseGitNumstat(_ output: String) -> [String: AgentLineChangeStats] {
        var result: [String: AgentLineChangeStats] = [:]

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }

            let added = Int(parts[0])
            let deleted = Int(parts[1])
            let path = parts.dropFirst(2).joined(separator: "\t")
            guard !path.isEmpty else { continue }

            result[String(path)] = AgentLineChangeStats(added: added, deleted: deleted)
        }

        return result
    }

    nonisolated static func formatLineStats(_ stats: AgentLineChangeStats) -> String {
        let added = stats.added.map { "+\($0)" } ?? "+?"
        let deleted = stats.deleted.map { "-\($0)" } ?? "-?"
        return "\(added) \(deleted)"
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

    nonisolated private static let maxGitOutputBytes = 512 * 1024
    nonisolated private static let gitCommandTimeout: TimeInterval = 5

    nonisolated private static func runGit(arguments: [String], in repositoryRoot: URL) -> String {
        let process = Process()
        let stdoutPipe = Pipe()
        let collector = ProcessOutputCollector(limit: maxGitOutputBytes)
        let runState = TimedProcessState()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0"
        ]) { current, _ in current }
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.append(data) }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            return ""
        }

        let timeoutWorkItem = DispatchWorkItem {
            runState.markTimedOut()
            if process.isRunning {
                process.terminate()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning {
                    process.interrupt()
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + gitCommandTimeout, execute: timeoutWorkItem)

        process.waitUntilExit()
        timeoutWorkItem.cancel()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        collector.append(stdoutPipe.fileHandleForReading.availableData)

        guard !runState.didTimeout else { return "" }
        guard process.terminationStatus == 0 else { return "" }

        return collector.stringValue
    }
}

private nonisolated final class ProcessOutputCollector: @unchecked Sendable {
    private let limit: Int
    private var data = Data()
    private let lock = NSLock()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        let remaining = max(0, limit - data.count)
        guard remaining > 0 else { return }
        data.append(chunk.prefix(remaining))
    }

    var stringValue: String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? AppState.decodeText(from: snapshot)
    }
}

private nonisolated final class TimedProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    var didTimeout: Bool {
        lock.lock()
        let value = timedOut
        lock.unlock()
        return value
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

/// Tiny actor used to thread-safely accumulate a streamed summary
/// without leaking `@MainActor` isolation into the streaming callback.
private actor CompressionSummaryCollector {
    private(set) var value: String = ""
    func append(_ chunk: String) {
        value += chunk
    }
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
