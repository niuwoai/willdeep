//
//  AppState.swift
//  WillDeep
//
//  Created by rocky on 2026/5/27.
//

import Combine
import Foundation
import SwiftUI
import AppKit

/// Central observable state hub for the WillDeep app.
/// Manages the currently opened file URL, its text content, the dirty (edited) flag,
/// and the root directory for the sidebar file tree.
final class AppState: ObservableObject {
    nonisolated static let maxAgentToolRounds = 64

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
    @Published var hasExternalFileChanges = false
    @Published var gitStatus = GitRepositoryStatus()
    @Published var isAgentPanelVisible = false
    @Published var agentComposerFocusRevision = 0
    @Published var agentConfiguration: AgentConfiguration {
        didSet {
            // A 方案：library 才是 provider 字段（providerID/baseURL/
            // apiKey/flash/pro/routing）的唯一真相源。这里只持久化
            // imageDescription、titleModel 等 library 不覆盖的边角字段，
            // 并且**不再**回灌 active library entry —— 那个回灌是把
            // DeepSeek 的 API key 拷贝到 OpenAI 条目这一系列 bug 的根源。
            AgentSettingsStore.saveAuxiliaryConfiguration(agentConfiguration)
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
    /// Long pasted text staged in the composer for the next user message.
    var agentPendingTextAttachments: [AgentTextAttachment] {
        get { activeRuntime?.pendingTextAttachments ?? [] }
        set { activeRuntime?.pendingTextAttachments = newValue }
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
    /// Per-session approval behavior shown in the composer.
    var agentApprovalMode: AgentApprovalMode {
        get { activeRuntime?.approvalMode ?? .smart }
        set { activeRuntime?.approvalMode = newValue }
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
    @Published var agentWorktreeDiffPreview: AgentWorktreeDiffPreview?
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
    /// User-tunable base font size (in points) for the Agent chat
    /// transcript body — applies to user/assistant message prose and
    /// rendered Markdown blocks. Tool-call summaries, footers, and
    /// composer chrome keep their fixed AgentDesign sizes. Range and
    /// default come from AgentSettingsStore so the UI clamp and the
    /// persisted clamp can't drift.
    @Published var agentChatBaseFontSize: CGFloat = AgentSettingsStore.loadAgentChatBaseFontSize() {
        didSet {
            let clamped = AgentSettingsStore.clampChatBaseFontSize(agentChatBaseFontSize)
            if clamped != agentChatBaseFontSize {
                agentChatBaseFontSize = clamped
                return
            }
            AgentSettingsStore.saveAgentChatBaseFontSize(clamped)
        }
    }
    /// Persisted Agent-mode chat sessions, newest-updated first.
    @Published var agentSessions: [AgentSession] = []
    /// Persisted Agent routines (scheduled prompts), most-recently-updated
    /// first. Surfaces in the Agent-mode sidebar's Routines section and
    /// drives the AgentRoutineScheduler that wakes them up on schedule.
    @Published var agentRoutines: [AgentRoutine] = []
    let agentRoutineScheduler = AgentRoutineScheduler()

    /// Process-wide registry of background `run_command` jobs. Scoped
    /// by `runtime.id` inside the registry so concurrent sessions can't
    /// steal each other's jobs or completion notices. See
    /// `AgentBackgroundJobs.swift` for the lifecycle contract.
    let agentJobRegistry = AgentJobRegistry()

    /// Process-wide registry of `spawn_agent` subagent runs, scoped by
    /// parent runtime the same way jobs are. See `AgentSubagents.swift`
    /// for the lifecycle contract.
    let agentSubagentRegistry = AgentSubagentRegistry()

    /// rc1 scaffold for v1.49's concurrent runtimes. One entry per
    /// session that the user has touched this launch. AppState still
    /// owns every `@Published agent*` field for now — rc2 starts
    /// moving real state in here and rewires UI bindings; rc3 enables
    /// per-runtime dispatch tasks for true parallel turns. Keeping the
    /// dictionary alive in rc1 just means session lifecycle code already
    /// knows where to create/destroy runtimes — when rc2 lands there's
    /// no scramble to retrofit lifecycle.
    @Published var agentRuntimes: [AgentSession.ID: AgentRuntime] = [:]

    /// Session ids for which an LLM title-summarization request is
    /// currently in flight. Used as a dedup guard in
    /// `summarizeAgentSessionTitleIfNeeded` so repeated persists
    /// inside one turn (every tool result / stream chunk landing)
    /// don't fan out into multiple parallel title requests against
    /// the same provider. Not @Published — UI doesn't need to react.
    var titleSummarizationsInFlight: Set<AgentSession.ID> = []

    /// `estimatedAgentTokens`（AppStateAgentLoop.swift）的 memo。该估算
    /// 要重建完整请求（含 system prompt 的项目规则磁盘读取）并逐字符
    /// 扫描全部消息，而状态栏的 ContextRingIndicator / CompressButton
    /// 每次 body 求值会读它 6+ 次——不缓存的话流式期间每个 token 都
    /// 全量重算（1.58.0-rc9 CPU 修复的一环）。消息条数或会话切换立即
    /// 失效；同条数下（流式追加中）最多每秒重算一次。Not @Published。
    var agentTokenEstimateCache: (messageCount: Int, sessionID: AgentSession.ID?, value: Int, at: Date)?

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
    /// Mirrors `AgentRuntime.didEditFiles` for the active session — flips
    /// to true the moment the Agent successfully applies a patch in this
    /// session, and stays true until the session is replaced. Used to gate
    /// the worktree-change card so a fresh New Chat never shows it.
    /// Pre-rc2 this was `@Published private(set)` on AppState; the
    /// delegate keeps the same surface. Internal write call sites use
    /// `appState.agentSessionDidEditFiles = ...` which routes to the
    /// active runtime.
    var agentSessionDidEditFiles: Bool {
        get { activeRuntime?.didEditFiles ?? false }
        set { activeRuntime?.didEditFiles = newValue }
    }
    /// Workspace-relative paths the Agent has actually written to in the
    /// active session — used by the worktree-change card to filter out
    /// the user's own diffs and untracked junk (e.g. `__pycache__/*.pyc`).
    var agentEditedRelativePaths: Set<String> {
        get { activeRuntime?.agentEditedPaths ?? [] }
        set { activeRuntime?.agentEditedPaths = newValue }
    }
    /// Top-level UI mode. Editor is the classic file editor; agent hides
    /// the editor and shows the conversation-first layout.
    @Published var appMode: AppMode = .editor
    /// Continuation resumed when the user resolves (approve/deny/confirm) the
    /// currently-blocked tool call. Internal to the agent loop. Delegated
    /// to `activeRuntime` post-rc2 — each runtime owns its own waiter so
    /// concurrent sessions don't fight over one slot.
    var agentToolDecisionWaiter: CheckedContinuation<AgentToolDecision, Never>? {
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
    // rc42: dropped `private` so the file-ops extension (split into
    // AppStateFileOperations.swift) can read/write these flags. They remain
    // implementation details — no external module sees them.
    var isApplyingTabSnapshot = false
    private var closedTabs: [EditorTab] = []
    var knownModificationDates: [URL: Date] = [:]
    var securityScopedAccessURLs: Set<URL> = []
    var gitStatusRefreshTask: Task<Void, Never>?
    private var quickOpenRefreshTask: Task<Void, Never>?
    /// Provider request `Task` for the active turn. Delegated to
    /// `activeRuntime` post-rc2 so each runtime can hold its own.
    var agentRequestTask: Task<Void, Never>? {
        get { activeRuntime?.requestTask }
        set { activeRuntime?.requestTask = newValue }
    }
    private var editorSettingsSideEffectsWorkItem: DispatchWorkItem?
    private var editorSettingsObserver: AnyCancellable?
    /// Republishes the ACTIVE runtime's `objectWillChange` through
    /// AppState's own publisher so SwiftUI bindings against the
    /// delegated `appState.agent*` properties refresh when the active
    /// runtime mutates.
    ///
    /// Critical: only the active runtime forwards. rc4 briefly tried
    /// forwarding every runtime so the sidebar busy dot could see
    /// background turns, but that turned every stream delta on any
    /// background runtime into a global SwiftUI invalidation — chat
    /// pane scrolling + a live transcript + N sidebar dots animating
    /// + delta-per-token republish = main thread melts. The sidebar
    /// dot now observes its runtime directly via `@ObservedObject`
    /// inside `AgentSessionRowStatusDot`, so background runtime
    /// changes only repaint that one row.
    private var activeRuntimeSubscription: AnyCancellable?
    /// Republishes background job registry changes through AppState so
    /// any view binding `appState.*` repaints when a job starts /
    /// finishes / streams output. Views that need finer-grained
    /// updates can `@ObservedObject` the registry directly.
    private var jobRegistrySubscription: AnyCancellable?
    // A 方案删除了 cfg → library 的回灌方向，此前的 reentrancy 守卫
    // (`isReconcilingProviderLibrary`) 不再需要。

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

    var inFlightCountByProvider: [String: Int] = [:]
    var pendingDispatchQueue: [PendingDispatch] = []

    struct PendingDispatch {
        let runtimeID: AgentSession.ID
        let text: String
        let images: [AgentImageAttachment]
        let textAttachments: [AgentTextAttachment]
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
        // A 方案：library 是 provider 真相源。先把它加载出来（其内部会
        // 做一次性 keychain 错位修复），再用 active entry 覆盖到 cfg 的
        // 主 provider 字段上；imageDescription / titleModel / routingMode
        // 这些 library 不接管的字段从 legacy 存储继承。
        let loadedLibrary = AgentSettingsStore.loadProviderLibrary()
        var bootstrappedConfig = AgentSettingsStore.load()
        if let active = loadedLibrary.active {
            bootstrappedConfig.providerID = active.providerID
            bootstrappedConfig.baseURL = active.baseURL
            bootstrappedConfig.apiKey = active.apiKey
            bootstrappedConfig.flashModel = active.flashPrimary
            bootstrappedConfig.proModel = active.proPrimary
            bootstrappedConfig.routingMode = active.routingMode
            if bootstrappedConfig.model.isEmpty {
                bootstrappedConfig.model = active.flashPrimary
            }
        }
        self.agentConfiguration = bootstrappedConfig.normalized
        self.agentProviderLibrary = loadedLibrary
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
        jobRegistrySubscription = agentJobRegistry.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    deinit {
        gitStatusRefreshTask?.cancel()
        quickOpenRefreshTask?.cancel()
        agentRequestTask?.cancel()
        activeRuntimeSubscription?.cancel()
        jobRegistrySubscription?.cancel()
        // rc38 attempted to cancel every background runtime's
        // requestTask here via `MainActor.assumeIsolated { … }`, which
        // works in production (AppState is held by SwiftUI as a
        // @StateObject, so dealloc happens on the main thread) but
        // crashes the Swift Testing harness, where release sites are
        // sometimes nonisolated and the precondition trips. The
        // background-runtime task is now cancelled explicitly at the
        // call sites that retire a session (`deleteAgentSession`,
        // `pruneEmptyAgentSessions`, etc), not on deinit — see the
        // commentary on those for the new policy.
        for url in securityScopedAccessURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Re-establish the active runtime's change-forward link. Called
    /// whenever `activeAgentSessionID` flips so the chat pane (which
    /// reads `appState.agent*` delegated properties) sees the new
    /// runtime's mutations. Background runtimes do NOT forward here —
    /// that would melt the main thread on long streams. UIs that need
    /// to watch a background runtime (sidebar status dot) observe it
    /// directly via @ObservedObject.
    func subscribeToActiveRuntime() {
        activeRuntimeSubscription?.cancel()
        guard let runtime = activeRuntime else {
            activeRuntimeSubscription = nil
            return
        }
        activeRuntimeSubscription = runtime.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    var activeTab: EditorTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    /// Memoization slot for `findMatchRanges`. Pre-rc38 the computed
    /// property scanned the whole file on every SwiftUI body read, and
    /// the find bar + editor + status bar all read it once per render,
    /// burning O(file size) per render on large files. The find bar is
    /// the bottleneck — a 1 MB file plus a multi-char query was visibly
    /// laggy. Cache key is (content identity hash, query, fileContent
    /// count); set to nil any time we know either input may have shifted
    /// (we DON'T proactively invalidate — the key-based lookup handles
    /// stale entries naturally on the next access).
    private struct FindMatchCache {
        let contentHash: Int
        let query: String
        let ranges: [NSRange]
    }
    private var findMatchCache: FindMatchCache?

    var findMatchRanges: [NSRange] {
        let hash = fileContent.hashValue
        if let cached = findMatchCache,
           cached.contentHash == hash,
           cached.query == findQuery {
            return cached.ranges
        }
        let ranges = Self.findRanges(in: fileContent, query: findQuery)
        findMatchCache = FindMatchCache(contentHash: hash, query: findQuery, ranges: ranges)
        return ranges
    }

    var activeFindRange: NSRange? {
        let ranges = findMatchRanges
        guard !ranges.isEmpty else { return nil }
        return ranges[min(activeFindIndex, ranges.count - 1)]
    }

    /// Memoization slot for `changedLineNumbers`. Same reasoning as
    /// `findMatchCache`: this property is read from the gutter renderer
    /// + change-bar overlay + tab title dirty-dot, so a typo in a 5K-line
    /// file triggers three line-diffs per keystroke.
    private struct ChangedLinesCache {
        let currentHash: Int
        let savedHash: Int
        let lines: Set<Int>
    }
    private var changedLinesCache: ChangedLinesCache?

    var changedLineNumbers: Set<Int> {
        guard let activeTab else { return [] }
        let currentHash = activeTab.content.hashValue
        let savedHash = activeTab.savedContent.hashValue
        if let cached = changedLinesCache,
           cached.currentHash == currentHash,
           cached.savedHash == savedHash {
            return cached.lines
        }
        let lines = Self.changedLineNumbers(current: activeTab.content, saved: activeTab.savedContent)
        changedLinesCache = ChangedLinesCache(currentHash: currentHash, savedHash: savedHash, lines: lines)
        return lines
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

    /// 「正在思考」分割线下方的两行实时预览：当前流式 assistant 占位
    /// 消息正在累积的 reasoningContent。生命周期与指示器完全一致——
    /// 首个正文 token / 工具调用到达后指示器消失，预览随之消失。
    /// 不单独输出 reasoning 流的服务商（未开 thinking 的 Claude 等）
    /// 返回 nil，分割线退回纯标签样式。
    var agentLiveThinkingPreview: String? {
        guard shouldShowAgentThinkingIndicator,
              let lastMessage = agentMessages.last,
              lastMessage.role == .assistant,
              let reasoning = lastMessage.reasoningContent,
              !reasoning.isEmpty else { return nil }
        return reasoning
    }

    /// 把完整 reasoning 轨迹压成适合两行展示的尾巴：换行折叠成空格、
    /// 只留末尾 `maxLength` 个字符。截断时前置省略号示意"前面还有"。
    /// 上限按两行 caption 字号的容量取值，配合视图层的
    /// `truncationMode(.head)` 兜底——窗口再窄也保证看到的是最新内容。
    nonisolated static func agentThinkingPreviewTail(_ raw: String, maxLength: Int = 160) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard collapsed.count > maxLength else { return collapsed }
        return "…" + collapsed.suffix(maxLength)
    }

    /// Claude Code 式「✳ N running task」计数：正在执行的前台工具调用
    /// + 本会话仍存活的后台作业。
    ///
    /// 前台工具只在 turn 进行中统计——被取消的 turn 理论上可能留下
    /// `.running` 残骸，不能让它把状态行永远钉在底部。后台作业则刻意
    /// **跨 turn 存活**：turn 已结束但编译还在跑时，transcript 底部
    /// 继续显示"N 个任务运行中"，这正是参照 Claude Code 界面的关键
    /// 行为（输出停了 ≠ 没事干了）。
    var agentRunningTaskCount: Int {
        let runningTools = isAgentResponding
            ? agentToolCalls.filter { $0.status == .running }.count
            : 0
        let aliveJobs = activeAgentSessionID
            .map { agentJobRegistry.aliveJobs(forRuntime: $0).count } ?? 0
        return runningTools + aliveJobs
    }

    /// Tooltip 明细：每行一个运行中条目 — 前台工具显示工具名，后台
    /// 作业显示 `job_xxxxxx · 命令前缀`。没有任何运行中条目时为 nil。
    var agentRunningTaskSummary: String? {
        var lines: [String] = []
        if isAgentResponding {
            lines += agentToolCalls
                .filter { $0.status == .running }
                .map(\.toolName)
        }
        if let runtimeID = activeAgentSessionID {
            lines += agentJobRegistry.aliveJobs(forRuntime: runtimeID).map { job in
                let command = job.command.replacingOccurrences(of: "\n", with: " ")
                let preview = command.count > 60 ? String(command.prefix(60)) + "…" : command
                return "\(job.displayHandle) · \(preview)"
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    var shouldShowGoalRunningStatusBar: Bool {
        agentInteractionMode == .goal
            && isAgentResponding
            && agentCurrentGoal?.isEmpty == false
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

    /// Best-effort token count for the next provider request. This mirrors

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

    func openAgentChangedFile(_ relativePath: String) {
        guard let url = agentChangedFileURL(relativePath) else { return }
        registerRecentFile(url)
        openedFileURL = url
        if appMode == .agent {
            setAppMode(.editor)
        }
    }

    func agentChangedFileURL(_ relativePath: String) -> URL? {
        let base = agentWorktreeChanges.repositoryRoot ?? rootDirectory
        guard let base else { return nil }

        let url = base.appendingPathComponent(relativePath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        return url
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

    func applySnapshot(from tab: EditorTab, suppressURLChange: Bool) {
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

    func bumpEditorRenderRevision() {
        editorRenderRevision += 1
    }

    func bumpEditorHighlightRevision() {
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

    func updateActiveTab(_ mutation: (inout EditorTab) -> Void) {
        guard !isApplyingTabSnapshot,
              let activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID }) else {
            return
        }
        mutation(&tabs[index])
    }

    func updateActiveTabAfterURLChange(to url: URL) {
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
            .appendingPathComponent("willdeep-untitled-\(UUID().uuidString)")
            .appendingPathExtension("txt")
    }

    func updateWindowTitle(url: URL?, isEdited: Bool) {
        // 生产路径上调用全部从主线程发起；但 XeditTests 在 cooperative
        // pool（非主）里 sync 跑 `appState.saveCurrentFile()` → 这里 →
        // `NSApp.keyWindow` 跨线程。macOS 15 的 Main Thread Checker
        // 只 warn，macOS 26 把它升为 fatal NSInternalInconsistency
        // ("NSWindow geometry should only be modified on the main
        // thread!") 直接终止测试进程，rc10 升完 runner 后 CI 就卡在
        // 这里。窗口标题只是 UI 装饰，主线程之外的调用 async hop 就行。
        let applyTitle: () -> Void = { [weak self] in
            guard let window = NSApplication.shared.keyWindow else { return }
            window.title = self?.activeTab?.title ?? url?.lastPathComponent ?? ""
            window.isDocumentEdited = isEdited
        }
        if Thread.isMainThread {
            applyTitle()
        } else {
            DispatchQueue.main.async(execute: applyTitle)
        }
    }

}

extension AppState {
    nonisolated static func isRecentItemEligibleForTesting(_ url: URL) -> Bool {
        RecentItemsStore.isEligible(url)
    }
}
