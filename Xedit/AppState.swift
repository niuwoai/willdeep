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
    nonisolated static let maxAgentToolRounds = 256
    nonisolated static let agentSidePanelResourceIdleTimeout: TimeInterval = 60 * 60

    @Published var openedFileURL: URL?
    @Published var fileContent: String {
        didSet {
            updateActiveTab { tab in
                if tab.content != fileContent {
                    tab.contentRevision += 1
                }
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
    var pendingDefinitionNavigation: EditorDefinitionLocation?
    let editorLanguageServiceManager = EditorLanguageServiceManager()
    @Published var editorLanguageServiceOutlineItems: [EditorOutlineItem] = []
    @Published var editorLanguageServiceOutlineStatus: EditorLanguageServiceOutlineStatus = .unavailable
    @Published var editorWorkspaceSymbolItems: [EditorWorkspaceSymbolItem] = []
    @Published var editorWorkspaceSymbolSearchStatus: EditorWorkspaceSymbolSearchStatus = .unavailable
    @Published var isEditorWorkspaceSymbolSearchLoading = false
    @Published var editorLanguageServiceDiagnosticIssues: [EditorDiagnosticIssue] = []
    @Published var editorSemanticTokenSpans: [EditorSemanticTokenSpan] = []
    @Published var editorInlayHintSpans: [EditorInlayHintSpan] = []
    @Published var editorDocumentLinkSpans: [EditorDocumentLinkSpan] = []
    @Published var editorLanguageServiceFoldingGuides: [ScopeGuide] = []
    @Published var editorLanguageServiceFoldingStatus: EditorLanguageServiceFoldingStatus = .unavailable
    @Published var editorDocumentHighlightSpans: [EditorDocumentHighlightSpan] = []
    @Published var editorHoverInfo: EditorHoverInfo?
    @Published var editorCompletionPanel: EditorCompletionPanelState?
    @Published var editorSignatureHelpPanel: EditorSignatureHelpPanelState?
    @Published var editorCodeActionPanel: EditorCodeActionPanelState?
    @Published var editorReferencesPanel: EditorReferencesPanelState?
    @Published var editorCallHierarchyPanel: EditorCallHierarchyPanelState?
    @Published var editorTextSelectionRequest: EditorTextSelectionRequest?
    var editorLanguageServiceDiagnosticsURI: String?
    var editorLanguageServiceSemanticTokensURI: String?
    var editorLanguageServiceInlayHintsURI: String?
    var editorLanguageServiceDocumentLinksURI: String?
    var editorLanguageServiceFoldingURI: String?
    var editorLanguageServiceDocumentHighlightsURI: String?
    var editorLanguageServiceDiagnosticsHandlerInstalled = false
    var editorTextSelectionRevision = 0
    var editorDocumentHighlightRevision = 0
    var editorDocumentHighlightRequestKey: String?
    var editorWorkspaceSymbolRevision = 0
    var editorWorkspaceSymbolRequestKey: String?
    var editorLanguageServiceSynchronizationRevision = 0
    var editorLanguageServiceSynchronizationTask: Task<Void, Never>?
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
    @Published var isEditorTerminalVisible = false
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
    /// Current editor selection text for Agent request context. The UI only
    /// renders selection counts, so publishing the text itself would invalidate
    /// the Agent/sidebar view tree on every drag-selection event.
    private(set) var selectedText = ""
    @Published var hasExternalFileChanges = false
    @Published var gitStatus = GitRepositoryStatus()
    @Published var agentWorkspaceGitStatus = GitRepositoryStatus()
    @Published var agentGitWorktrees: [AgentGitWorktree] = []
    /// "Another live session is running a turn in this same local checkout"
    /// hint. Recomputed cheaply (no git/IO) from the shared agent-loop
    /// start/end and on session switch — see `refreshAgentWorkspaceCollision`.
    @Published var agentWorkspaceCollision = AgentWorkspaceCollision()
    @Published var agentGitWorktreeCreation: AgentGitWorktreeCreation?
    var agentGitWorktreeRefreshTask: Task<Void, Never>?
    var agentGitWorktreeRefreshPath: String?
    var agentGitWorktreeCreationTask: Task<Void, Never>?
    var agentGitWorktreeProcessController: AgentGitWorktreeProcessController?
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
            // A 方案的闭环：library 是 provider 字段的唯一真相源,任何对
            // library 的写入(onboarding 首次保存 key、设置页编辑 active 条目、
            // 切换 active 条目)都必须立刻把 active entry 重新灌进运行时的
            // agentConfiguration,否则 key 只落了磁盘、运行时仍是旧值/空值,
            // 表现就是「设置了 api-key 却要重启 App 才生效」。apply 只写 cfg、
            // 不回灌 library,cfg.didSet 也不碰 library,故无死循环。
            applyActiveProviderLibraryEntry()
        }
    }
    /// Model IDs the user has previously fetched in Settings — surfaced in
    /// the Agent-mode model picker as a quick switcher.
    @Published var agentKnownModelIDs: [String] = []
    /// Hot/new flags discovered from provider model metadata. some.im
    /// exposes these through public pricing and `/v1/models` extensions.
    @Published var agentDiscoveredModelMetadata: [AgentModelDiscovery] = []
    @Published var someIMCodingPlanStatus = SomeIMIntegrationStore.loadCodingPlanStatus()
    @Published var someIMCodingPlanRefreshFailure: SomeIMCodingPlanRefreshFailure?
    /// Model IDs explicitly chosen in the composer, most-recently-used
    /// first. This is separate from fetched IDs so a large /models
    /// result doesn't drown out the handful of models the user actually
    /// rotates between.
    @Published var agentRecentlyUsedModelIDs: [String] = []
    @Published var agentWorktreeDiffPreview: AgentWorktreeDiffPreview?
    @Published var isAgentWorktreeDiffPreviewLoading = false
    /// One-shot request from chat-pane affordances (file chips, citations,
    /// future commands) to open a specific kind of side panel in Agent
    /// mode and optionally focus a file. AgentModeView listens, applies
    /// the request to the active session runtime, then clears it.
    @Published var agentSidePanelRequest: AgentSidePanelOpenRequest?
    /// The center-column destination in Agent mode. Scheduled tasks use a
    /// dedicated page instead of expanding an unbounded list in the sidebar.
    @Published var agentPrimaryDestination: AgentPrimaryDestination = .conversation
    /// One-shot request to expand the floating plan card in the conversation
    /// activity overlay. The transcript footer's "查看计划" affordance bumps
    /// this token; `AgentConversationActivityOverlay` observes it and sets its
    /// plan card to expanded. Pure UI transient — never persisted.
    @Published var agentPlanOverlayExpandRequestToken: Int = 0
    /// One-shot request to collapse the floating plan card. The transcript
    /// bumps this when a new assistant round begins so the plan folds away
    /// while the agent works, matching the old inline-card behaviour. Pure UI
    /// transient — never persisted.
    @Published var agentPlanOverlayCollapseRequestToken: Int = 0
    /// One-shot request to open a scheduled task's detail. A transcript
    /// scheduled-task card sets the routine id; the scheduled-tasks page
    /// observes it, opens that routine's editor sheet, then clears it.
    @Published var pendingRoutineDetailID: UUID?
    /// Optional scope for the media task side panel. Short-drama rows set
    /// this before opening the panel so the task list can show only the
    /// project / episode / shot / asset the user clicked.
    @Published var agentMediaTaskPanelScope: AgentMediaTaskScope? {
        didSet { syncActiveSidePanelPayloadFromGlobals() }
    }
    /// Selected local image for the right-side image edit/mask panel.
    /// Media-task artifact rows set this, then request the image editor
    /// side panel. The editor can export masks for Replicate/some.im
    /// inpaint workflows without bloating chat history.
    @Published var agentImageEditorImageURL: URL? {
        didSet { syncActiveSidePanelPayloadFromGlobals() }
    }
    /// Optional seed mask for the image editor. Failed inpaint/erase tasks
    /// can reopen with the previous mask as an editable base layer.
    @Published var agentImageEditorMaskURL: URL? {
        didSet { syncActiveSidePanelPayloadFromGlobals() }
    }
    /// Optional one-shot mode hint for the image editor. Short-drama
    /// review items use it so "erase" opens directly in erase mode while
    /// "redraw" opens in inpaint mode.
    @Published var agentImageEditorPreferredOperation: AgentImageEditorOperationPreference? {
        didSet { syncActiveSidePanelPayloadFromGlobals() }
    }
    /// Optional short-drama anchor for the image editor. When present,
    /// inpaint/erase tasks created from the editor can flow back into
    /// the same project episode and shot through the media task registry.
    @Published var agentImageEditorContext: AgentImageEditorContext? {
        didSet { syncActiveSidePanelPayloadFromGlobals() }
    }
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
    /// Cached few-shot block of the operator's prior hand-review decisions,
    /// appended to the auto-approve safety-judge system prompt. Rebuilt
    /// lazily behind `safetyJudgeHistoryTTL` (see safetyJudgeHistoryContext)
    /// — deliberately NOT recomputed per judge call, both to avoid re-reading
    /// the audit log each time and to keep the judge request prefix stable
    /// for provider prompt caching. Not `@Published`: UI never renders it.
    var cachedJudgeHistoryContext: String = ""
    var cachedJudgeHistoryBuiltAt: Date?
    /// User-tunable base font size (in points) for the Agent chat
    /// transcript body — applies to user/assistant message prose and
    /// rendered Markdown blocks. Supporting chat chrome (tool summaries,
    /// progress/status rows, footers, dashboard captions, and composer
    /// context labels) treats this value as its visual minimum, preserving
    /// hierarchy with color and weight instead of unreadably small text.
    /// Range and default come from AgentSettingsStore so the UI clamp and
    /// the persisted clamp can't drift.
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
    /// Launch catalog loading is asynchronous. The Agent window uses this
    /// edge to run Goal recovery only after every persisted candidate is
    /// visible, avoiding a race with the initial empty in-memory list.
    @Published private(set) var hasLoadedAgentSessionCatalog = false
    /// Set only when a metadata-only sidebar row can no longer be
    /// materialized from disk. The row is deliberately retained so a
    /// recovered JSON file can reconnect without losing its visible title.
    @Published var agentSessionLoadFailure: AgentSessionLoadFailure?
    /// Lightweight usage snapshots decoded only when the stats dashboard is
    /// shown. Launch no longer scans every full conversation for analytics.
    @Published var agentUsageSnapshots: [AgentUsageSessionSnapshot] = []
    @Published var hasLoadedAgentUsageSnapshots = false
    @Published var isLoadingAgentUsageSnapshots = false
    /// Sidebar group keys the user has removed from view. Removal only
    /// hides the workspace — its sessions stay on disk, so re-adding the
    /// same folder restores the full chat list. Persisted across launches.
    @Published var hiddenWorkspaceKeys: Set<String> = AppState.loadHiddenWorkspaceKeys()
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

    /// Process-wide registry of remote AI media tasks. some.im,
    /// Replicate, and short-drama skills publish image/video generation
    /// and editing progress here so the right side panel and future chat
    /// completion notices have one shared source of truth.
    let agentMediaTaskRegistry = AgentMediaTaskRegistry()
    let agentMediaTaskPoller = AgentMediaTaskPoller()

    /// Process-wide short-drama project store. Agent tools and the side
    /// panel share this so generated episodes, shots, characters, and
    /// scenes stay visible outside the current chat turn.
    let agentShortDramaStore = AgentShortDramaStore.shared

    /// Composer-delegated Codex / Claude Code background jobs that
    /// have already been written into the visible transcript by the
    /// host completion hook.
    var surfacedDelegatedBackgroundJobIDs: Set<UUID> = []

    /// Process-wide registry of `spawn_agent` subagent runs, scoped by
    /// parent runtime the same way jobs are. See `AgentSubagents.swift`
    /// for the lifecycle contract.
    let agentSubagentRegistry = AgentSubagentRegistry()

    /// In-flight multi-expert consultations. Keyed by the transcript report
    /// id so the specialized card can stop exactly its own orchestration.
    var agentConsultationTasks: [UUID: Task<Void, Never>] = [:]

    /// In-flight expert roundtables. Keyed by the roundtable report id so the
    /// roundtable window can stop exactly its own orchestration.
    var agentRoundtableTasks: [UUID: Task<Void, Never>] = [:]

    /// Maps each in-flight consultation (report id) to the runtime that owns
    /// it, so the "already running" guard and the composer's disabled state
    /// are scoped per session instead of blocking every other conversation.
    var agentConsultationRuntimeByReport: [UUID: UUID] = [:]

    /// rc1 scaffold for v1.49's concurrent runtimes. One entry per
    /// session that the user has touched this launch. AppState still
    /// owns every `@Published agent*` field for now — rc2 starts
    /// moving real state in here and rewires UI bindings; rc3 enables
    /// per-runtime dispatch tasks for true parallel turns. Keeping the
    /// dictionary alive in rc1 just means session lifecycle code already
    /// knows where to create/destroy runtimes — when rc2 lands there's
    /// no scramble to retrofit lifecycle.
    @Published var agentRuntimes: [AgentSession.ID: AgentRuntime] = [:]
    var agentKnowledgeFolderWatchers: [String: DispatchSourceFileSystemObject] = [:]
    var agentKnowledgeFolderReindexTasks: [String: Task<Void, Never>] = [:]
    var agentKnowledgeFolderIndexTasks: [String: Task<Void, Never>] = [:]
    var agentKnowledgeFolderWatcherDiscoveryTasks: [String: Task<Void, Never>] = [:]
    var isRestoringAgentSidePanelGlobals = false

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

    /// Companion cache for the composer ring's *baseline* — the fixed
    /// system-prompt + tool-schema overhead that is present before the user
    /// sends anything. The ring subtracts it so an empty chat reads 0%.
    /// Same invalidation rules as `agentTokenEstimateCache`. Not @Published.
    var agentBaselineEstimateCache: (messageCount: Int, sessionID: AgentSession.ID?, value: Int, at: Date)?

    /// Memo for the estimated request prompt split: stable `system` message
    /// plus per-turn context appended to the latest user message. Both `estimatedAgentTokens` and
    /// `estimatedAgentBaselineTokens` independently build it, so on a session
    /// switch (which misses BOTH value caches at once) the full system-prompt
    /// construction + memory retrieval ran twice on the main thread inside the
    /// click path — a measurable slice of the switch "慢半拍". Sharing one
    /// build across the two estimators halves it. Same (messageCount,
    /// sessionID, 1s) invalidation as the value caches above, so it inherits
    /// their precision tradeoff and adds no new staleness. Not @Published.
    var agentSystemMessageCache: (
        messageCount: Int,
        sessionID: AgentSession.ID?,
        systemMessage: AgentMessage,
        turnContext: String,
        at: Date
    )?

    /// Active Agent-mode session id. nil means "scratch" — Editor-mode
    /// chat keeps working without forcing a session to exist.
    @Published var activeAgentSessionID: AgentSession.ID? {
        didSet {
            guard let oldValue, oldValue != activeAgentSessionID else { return }
            markSidePanelViewed(sessionID: oldValue)
        }
    }
    /// Top-level UI mode. Editor is the classic file editor; agent hides
    /// the editor and shows the conversation-first layout.
    @Published var appMode: AppMode = .editor
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
    @Published var editorTerminalSettings: EditorTerminalSettings = EditorTerminalSettingsStore.load() {
        didSet {
            // When the sync notification below pushes a change in from another
            // AppState (e.g. the Settings window's own instance), just take the
            // value — don't re-save or re-broadcast — so terminals observing
            // THIS instance update live without echoing back out.
            guard !isApplyingExternalTerminalSettings else { return }
            let normalized = editorTerminalSettings.normalized()
            if normalized != editorTerminalSettings {
                editorTerminalSettings = normalized
                return
            }
            EditorTerminalSettingsStore.save(normalized)
            // Broadcast so every other live AppState reloads — this is what
            // makes a color-scheme / font change in Settings apply to the
            // side-panel terminal immediately instead of only after relaunch.
            NotificationCenter.default.post(name: .editorTerminalSettingsDidChange, object: self)
        }
    }
    /// True while applying an external terminal-settings change so the didSet
    /// above doesn't echo it back out (infinite loop guard).
    private var isApplyingExternalTerminalSettings = false
    private var terminalSettingsSyncSubscription: AnyCancellable?
    private var agentSidePanelResourceReaperTimer: Timer?
    var editorTerminalSession = EditorTerminalSession()
    let agentTerminalController = AgentInteractiveTerminalController()

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
    private var activeRuntimeForwardTask: Task<Void, Never>?
    /// rc482 perf: while the user is typing in the composer, the keystroke
    /// writes `activeRuntime.input` (a `@Published`), whose `objectWillChange`
    /// is forwarded below into `AppState.objectWillChange`. That forward
    /// repaints EVERY `appState`-observing view — including the whole
    /// composer pill row (Model/Workspace/Mode/… pickers), amplified 3× by
    /// the strip's `ViewThatFits`. `sample` showed ~90% of the main thread
    /// rebuilding those pill view-lists on each keystroke → typing echo lag +
    /// startup spike. The composer's NSTextView is its own source of truth
    /// and the pills don't depend on the draft, so we suppress *only* the
    /// per-keystroke forward; the buffer (`runtime.input`) still updates so
    /// send / external readers see live text. Programmatic writers (prefill,
    /// slash-clear, voice, message-edit) leave this false so their writes
    /// still repaint the composer.
    var suppressActiveRuntimeForward: Bool = false
    /// Republishes background job registry changes through AppState so
    /// any view binding `appState.*` repaints when a job starts /
    /// finishes / streams output. Views that need finer-grained
    /// updates can `@ObservedObject` the registry directly.
    private var jobRegistrySubscription: AnyCancellable?
    private var mediaTaskRegistrySubscription: AnyCancellable?
    private var sessionSaveFailureSubscription: AnyCancellable?
    /// Reconciles the some.im agent provider whenever the shared login session
    /// changes — including logins/logouts made by another app sharing the
    /// Keychain access group. Login adopts the fresh key; logout drops the entry.
    private var someIMSessionSubscription: AnyCancellable?
    var someIMCodingPlanRefreshTimer: Timer?
    var someIMCodingPlanRefreshTask: Task<Void, Never>?
    @Published var availableAppUpdate: AppUpdateMeta?
    @Published var isDownloadingAppUpdate = false
    var appUpdateCheckTask: Task<Void, Never>?
    /// Desktop peer for the LAN Mobile Gateway. The Go gateway handles
    /// pairing/device auth; this bridge translates authorized mobile
    /// commands back into normal AppState Agent operations.
    lazy var mobileGatewayDesktopPeer = AgentMobileGatewayDesktopPeer(appState: self)
    /// Starts/stops the local Go Mobile Gateway process and feeds
    /// desktop-authenticated state into Settings.
    lazy var mobileGatewayCoordinator = MobileGatewayCoordinator(appState: self)
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
        /// The user's message is appended to the runtime BEFORE the
        /// dispatch is queued, so it's visible immediately even while
        /// waiting for a provider slot. Carrying its id lets the drain
        /// re-dispatch reuse that message instead of appending a
        /// duplicate.
        let userMessageID: AgentMessage.ID
        let text: String
        let images: [AgentImageAttachment]
        let textAttachments: [AgentTextAttachment]
        let attachedSkills: [AgentSkillEntry]
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
        self.agentSessions = []
        self.agentUsageSnapshots = []
        self.agentKnownModelIDs = AgentSettingsStore.loadKnownModelIDs()
        self.agentDiscoveredModelMetadata = AgentSettingsStore.loadDiscoveredModelMetadata()
        self.agentRecentlyUsedModelIDs = AgentSettingsStore.loadRecentlyUsedModelIDs()
        self.agentAlwaysAllowedCommands = AgentSettingsStore.loadAlwaysAllowedCommands()
        syncLocalModelComposerProvider(settings: AgentSettingsStore.loadLocalModelSettings())
        self.agentRoutines = AgentRoutineStore.loadAll()
        agentRoutineScheduler.start(initialRoutines: agentRoutines) { [weak self] routineID in
            self?.fireRoutine(id: routineID) != nil
        }
        // No initial subscriptions to set up: runtimes are created
        // lazily as the user opens sessions, and `subscribeToRuntime`
        // runs at every creation site.
        jobRegistrySubscription = agentJobRegistry.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        mediaTaskRegistrySubscription = agentMediaTaskRegistry.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        // A cross-app some.im login/logout (shared Keychain group) posts this on
        // the main queue; reconcile our agent provider so the change is live
        // without a relaunch. Login done inside this app also round-trips here —
        // harmless, the upsert is idempotent.
        someIMSessionSubscription = NotificationCenter.default
            .publisher(for: SomeIMIntegrationStore.sessionDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reconcileSomeIMProviderFromSharedSession()
                self?.refreshSomeIMCodingPlanStatus(force: true)
            }
        // Session observers only report future cross-app changes. Reconcile the
        // session that already exists at launch immediately and without a
        // network dependency, otherwise a signed-in user can race the async
        // relay-region probe and send with an empty provider-library key.
        reconcileSomeIMProviderFromSharedSession()
        Task { @MainActor [weak self] in
            guard !SomeIMIntegrationStore.loadAPIKey().isEmpty else { return }
            await self?.refreshSomeIMRelayRouting()
        }
        #if DEBUG
        // Dev convenience: let a local JSON file seed a usable provider+key so
        // Debug builds work without manual entry (à la Claude Code's settings
        // JSON). Opt-in via file presence; git-ignored; key never logged. Placed
        // after the reconcile + relay-probe dispatch so a present dev config has
        // the final say on the active provider, while keeping the
        // reconcile→relay-probe ordering (and its source-scan invariant) intact.
        seedDevProviderIfNeeded()
        #endif
        startSomeIMCodingPlanRefreshTimer()
        refreshSomeIMCodingPlanStatus(force: false)
        startAppUpdateChecks()
        agentMediaTaskRegistry.shortDramaStore = agentShortDramaStore
        agentMediaTaskPoller.start(registry: agentMediaTaskRegistry)
        // Terminals are high-frequency UI surfaces: user typing, title
        // changes, and prompt updates must repaint only the terminal panes.
        // The panes observe their terminal objects directly, so AppState does
        // not republish terminal changes globally.
        // Let the terminal tools open a local shell on demand (rooted at
        // the active session's workspace) when the agent wants to drive
        // the terminal but the user hasn't opened a tab yet.
        agentTerminalController.defaultLocalTabProvider = { [weak self] requestedSessionID in
            guard let self else { return nil }
            let settings = self.editorTerminalSettings.normalized()
            let requestedRuntime = requestedSessionID.flatMap { self.runtime(for: $0) }
            let workingDirectory = requestedRuntime?.workspaceLocation?.localPath
                ?? requestedRuntime?.workspaceRootPath
                ?? self.rootDirectory?.standardizedFileURL.path
            let skin = settings.followsInterfaceSkin
                ? TerminalSkinColors.from(skin: self.editorSettings.interfaceSkin)
                : nil
            return (settings, workingDirectory, requestedSessionID ?? self.activeAgentSessionID, skin)
        }
        agentJobRegistry.onJobFinished = { [weak self] job in
            guard let self else { return }
            self.surfaceDelegatedBackgroundJobCompletionIfNeeded(job)
            // The job result is now queued; if the runtime that spawned it
            // is idle (its turn already ended saying "I'll check back"),
            // auto-resume so the model reacts to the completion/failure
            // instead of going silent until the user sends another message.
            // `runtime(for:)` re-materializes the session if the idle-runtime
            // eviction dropped it while the job was still running — a plain
            // `agentRuntimes[...]` lookup would silently strand the result.
            if let runtime = self.runtime(for: job.runtimeID) {
                self.resumeAgentLoopForPendingBackgroundCompletions(for: runtime)
            }
        }
        // Same wake-up contract for the other two background channels:
        // media tasks and spawned subagents queue their completions for
        // the top-of-round drain, so a run that outlives its turn needs
        // this kick or it stays unreported until the next user message.
        agentMediaTaskRegistry.onTaskFinished = { [weak self] task in
            guard let self, let runtimeID = task.runtimeID,
                  let runtime = self.runtime(for: runtimeID) else { return }
            self.resumeAgentLoopForPendingBackgroundCompletions(for: runtime)
        }
        agentSubagentRegistry.onRunFinished = { [weak self] run in
            guard let self else { return }
            if self.handleAgentGoalPlanningSubagentCompletion(run) {
                return
            }
            guard
                  let runtime = self.runtime(for: run.parentRuntimeID) else { return }
            self.resumeAgentLoopForPendingBackgroundCompletions(for: runtime)
        }
        // Session writes ride a background queue now; when one fails
        // (disk full, permission lost) surface it on the owning session's
        // error card instead of only printing to the console — otherwise
        // the user learns about the lost history at the next relaunch.
        // Never overwrite a provider error that's already showing. Each
        // AppState instance claims only the runtimes it owns, so the
        // Settings window's instance can't swallow the main window's
        // failures.
        sessionSaveFailureSubscription = NotificationCenter.default
            .publisher(for: AgentSessionStore.saveDidFailNotification)
            .sink { [weak self] note in
                guard let self,
                      let sessionID = note.object as? UUID,
                      let runtime = self.agentRuntimes[sessionID],
                      runtime.errorMessage == nil else { return }
                runtime.errorMessage = L10n.AgentPanel.sessionSaveFailed
            }
        // Keep terminal settings in sync across AppState instances (the
        // Settings window builds its own instance). When any instance saves,
        // reload here so `editorTerminalSettings` observers — and thus the live
        // terminals — re-apply appearance immediately rather than at relaunch.
        terminalSettingsSyncSubscription = NotificationCenter.default
            .publisher(for: .editorTerminalSettingsDidChange)
            .sink { [weak self] note in
                guard let self, (note.object as AnyObject) !== self else { return }
                let loaded = EditorTerminalSettingsStore.load()
                guard loaded != self.editorTerminalSettings else { return }
                self.isApplyingExternalTerminalSettings = true
                self.editorTerminalSettings = loaded
                self.isApplyingExternalTerminalSettings = false
            }
        startAgentSidePanelResourceReaper()
        Task { @MainActor [weak self] in
            let persistedSessions = await Task.detached(priority: .utility) {
                AgentSessionStore.loadAll()
            }.value
            guard let self, !Task.isCancelled else { return }

            // A user can create a session while the disk index is loading.
            // In-memory state is newer and therefore wins on ID collisions.
            var sessionsByID = Dictionary(uniqueKeysWithValues: persistedSessions.map { ($0.id, $0) })
            for session in self.agentSessions { sessionsByID[session.id] = session }
            self.agentSessions = sessionsByID.values.sorted { $0.updatedAt > $1.updatedAt }
            self.hasLoadedAgentSessionCatalog = true

            // Empty placeholders are filtered by sidebar visibility instead
            // of being deleted from disk. Automatic deletion previously made
            // a stale/cross-process index capable of erasing real history.
        }
    }

    deinit {
        gitStatusRefreshTask?.cancel()
        quickOpenRefreshTask?.cancel()
        agentGitWorktreeRefreshTask?.cancel()
        agentRequestTask?.cancel()
        activeRuntimeSubscription?.cancel()
        activeRuntimeForwardTask?.cancel()
        jobRegistrySubscription?.cancel()
        mediaTaskRegistrySubscription?.cancel()
        sessionSaveFailureSubscription?.cancel()
        someIMCodingPlanRefreshTask?.cancel()
        someIMCodingPlanRefreshTimer?.invalidate()
        appUpdateCheckTask?.cancel()
        agentSidePanelResourceReaperTimer?.invalidate()
        Task { @MainActor [poller = agentMediaTaskPoller] in
            poller.stop()
        }
        terminalSettingsSyncSubscription?.cancel()
        // rc38 attempted to cancel every background runtime's
        // requestTask here via `MainActor.assumeIsolated { … }`, which
        // works in production (AppState is held by SwiftUI as a
        // @StateObject, so dealloc happens on the main thread) but
        // crashes the Swift Testing harness, where release sites are
        // sometimes nonisolated and the precondition trips. The
        // background-runtime task is now cancelled explicitly at the
        // call sites that retire a session (`deleteAgentSession`, app
        // termination, etc), not on deinit — see the
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
        activeRuntimeForwardTask?.cancel()
        activeRuntimeForwardTask = nil
        guard let runtime = activeRuntime else {
            activeRuntimeSubscription = nil
            restoreAgentSidePanelGlobals(from: nil)
            return
        }
        restoreAgentSidePanelGlobals(from: runtime)
        markActiveSidePanelViewedIfOpen()
        activeRuntimeSubscription = runtime.objectWillChange
            .sink { [weak self] _ in
                guard let self, !self.suppressActiveRuntimeForward else { return }
                self.scheduleActiveRuntimeForward()
            }
    }

    private func startAgentSidePanelResourceReaper() {
        agentSidePanelResourceReaperTimer?.invalidate()
        let timer = Timer(timeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reapStaleAgentSidePanelResources()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        agentSidePanelResourceReaperTimer = timer
    }

    private func scheduleActiveRuntimeForward() {
        guard activeRuntimeForwardTask == nil else { return }
        activeRuntimeForwardTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.activeRuntimeForwardTask = nil
            guard !self.suppressActiveRuntimeForward else { return }
            self.objectWillChange.send()
        }
    }

    var activeTab: EditorTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    nonisolated static func sameFileURL(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    func tabIndex(for url: URL) -> Array<EditorTab>.Index? {
        tabs.firstIndex { Self.sameFileURL($0.url, url) }
    }

    func isOpenedFile(_ url: URL) -> Bool {
        openedFileURL.map { Self.sameFileURL($0, url) } ?? false
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
        let currentRevision: Int
        let savedRevision: Int
        let lines: Set<Int>
    }
    private var changedLinesCache: ChangedLinesCache?

    var changedLineNumbers: Set<Int> {
        guard let activeTab else { return [] }
        if let cached = changedLinesCache,
           cached.currentRevision == activeTab.contentRevision,
           cached.savedRevision == activeTab.savedContentRevision {
            return cached.lines
        }
        let lines = Self.changedLineNumbers(current: activeTab.content, saved: activeTab.savedContent)
        changedLinesCache = ChangedLinesCache(
            currentRevision: activeTab.contentRevision,
            savedRevision: activeTab.savedContentRevision,
            lines: lines
        )
        return lines
    }

    func updateSelectionInfo(
        line: Int,
        column: Int,
        selectedCharacters: Int,
        selectedLines: Int,
        selectedText: String = "",
        characterOffset: Int? = nil
    ) {
        let nextLine = max(1, line)
        let nextColumn = max(1, column)
        let nextSelectedCharacters = max(0, selectedCharacters)
        let nextSelectedLines = max(0, selectedLines)
        if cursorLine != nextLine {
            cursorLine = nextLine
        }
        if cursorColumn != nextColumn {
            cursorColumn = nextColumn
        }
        if selectedCharacterCount != nextSelectedCharacters {
            selectedCharacterCount = nextSelectedCharacters
        }
        if selectedLineCount != nextSelectedLines {
            selectedLineCount = nextSelectedLines
        }
        if self.selectedText != selectedText {
            self.selectedText = selectedText
        }
        if let characterOffset {
            refreshEditorDocumentHighlights(characterOffset: characterOffset, selectedLength: selectedCharacters)
        }
    }

    func navigateEditor(toLine line: Int) {
        guard line > 0 else { return }
        let nextRevision = (editorNavigationRequest?.revision ?? 0) + 1
        editorNavigationRequest = EditorNavigationRequest(line: line, revision: nextRevision)
    }

    func openExternalURL(_ url: URL, createsMissingFileIfNeeded: Bool = false) {
        let fileURL = url.isFileURL ? url : URL(fileURLWithPath: url.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            if createsMissingFileIfNeeded {
                createMissingExternalFile(at: fileURL)
            }
            return
        }

        if isDirectory.boolValue {
            registerRecentFolder(fileURL)
            setRootDirectory(fileURL)
            refreshGitStatus()
            refreshAgentGitWorktrees()
            persistSession()
            return
        }

        // Don't auto-promote the file's parent to `rootDirectory`. That used to
        // load the whole FileTree + run a recursive Quick Open scan + git
        // status for every "open file" — fatal latency when the parent is a
        // huge dir like ~/Downloads. The sidebar only appears now when the
        // user explicitly opens a folder (⇧⌘O / Open Folder…).
        openEditorFile(fileURL)
    }

    func createMissingExternalFile(at fileURL: URL) {
        let parentURL = fileURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            showFileOperationError("The parent folder does not exist: \(parentURL.path)")
            return
        }

        do {
            try Data().write(to: fileURL, options: [.atomic])
            openEditorFile(fileURL, performsSafetyChecks: false)
            notifyEditorLanguageServiceWatchedFileChanged(url: fileURL, type: .created)
            persistSession()
        } catch {
            openMissingExternalFileDraft(at: fileURL)
            showFileOperationError("Opened an unsaved file for \"\(fileURL.path)\" because it could not be created yet: \(error.localizedDescription)")
        }
    }

    func openMissingExternalFileDraft(at fileURL: URL) {
        if let index = tabs.firstIndex(where: { $0.url == fileURL }) {
            activeTabID = tabs[index].id
        } else {
            let tab = EditorTab(url: fileURL, content: "", savedContent: "", isEdited: true)
            tabs.append(tab)
            activeTabID = tab.id
        }

        imagePreviewURL = nil
        selectedSidebarFileURL = fileURL
        registerRecentFolder(fileURL.deletingLastPathComponent())

        isApplyingTabSnapshot = true
        suppressURLChangeProcessing = true
        openedFileURL = fileURL
        fileContent = ""
        isEdited = true
        isApplyingTabSnapshot = false
        bumpEditorRenderRevision()
        bumpEditorHighlightRevision()
        updateWindowTitle(url: fileURL, isEdited: true)
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
        refreshAgentGitWorktrees()
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
        openEditorFile(url)
        // 1.80.0-rc1：editor / agent 已经分窗口，老的 setAppMode(.editor)
        // 切回路径不再有意义；改成把当前跟随中的 editor 窗口抬到前
        // 台，让用户看到刚打开的那个文件。
        EditorAppStateRegistry.shared.focusCurrentEditorWindow()
    }

    func openAgentReferencedFile(_ rawPath: String) {
        guard let url = resolveAgentReferencedFileURL(rawPath) else { return }
        openEditorFile(url)
        registerRecentFile(url)
        EditorAppStateRegistry.shared.focusCurrentEditorWindow()
    }

    /// Click target for inline file chips in the Agent transcript. We're
    /// always in Agent mode here (chip lives in `AgentChatTranscript`),
    /// so a silent `openEditorFile` (which only focuses an already-open
    /// editor window) leaves the user staring at an unchanged chat pane.
    /// Route to the Agent side panel instead.
    ///
    /// MUST NOT silently no-op. rc9–rc13 的反复 bug 就是:解析不到文件
    /// (相对路径不在 base 直下、文件名大小写对不上、文件还没生成)时
    /// 直接 return,用户点了「屁事没发生」。现在:改动文件 → Diff,
    /// 普通文件 → Preview,解析不到 → 仍然打开 Files 面板,让用户看到
    /// 文件树、知道点击被响应了。任何情况下侧栏都会动。
    func revealAgentReferencedFileInSidePanel(_ rawPath: String) {
        if let url = resolveAgentReferencedFileURL(rawPath) {
            revealAgentArtifactFileInSidePanel(url)
        } else {
            // 兜底:打开 Files 面板(没有具体文件),至少有可见反馈。
            agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .files, file: nil)
        }
    }

    /// Click target for concrete artifact URLs in the Agent activity cards.
    /// Changed files should land in Diff with the file focused; unchanged
    /// generated files still use Preview, and missing files fall back to Files.
    func revealAgentArtifactFileInSidePanel(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard Self.existingFile(at: standardized) else {
            agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .files, file: nil)
            return
        }

        registerRecentFile(standardized)
        let panelKind: AgentSidePanelKind
        if AgentSidePanelDiffSelection.relativePath(
            for: standardized,
            changes: agentWorktreeChanges
        ) != nil {
            panelKind = .diff
        } else {
            panelKind = .preview
        }
        agentSidePanelRequest = AgentSidePanelOpenRequest(kind: panelKind, file: standardized)
    }

    /// Explicit Preview action for generated artifacts. Unlike the default
    /// artifact click path, this does not switch changed files to Diff: the
    /// user asked to preview the concrete artifact in the side panel.
    func previewAgentArtifactFileInSidePanel(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard Self.existingFile(at: standardized),
              AgentArtifactFileActions.isSidePanelPreviewCandidate(standardized) else {
            NSSound.beep()
            return
        }
        registerRecentFile(standardized)
        agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .preview, file: standardized)
    }

    private func resolveAgentReferencedFileURL(_ rawPath: String) -> URL? {
        let path = Self.agentFilePathWithoutLineSuffix(rawPath)

        // 1) 绝对路径直接用。
        if path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return Self.existingFile(at: url) ? url : nil
        }

        // 2) worktree 改动列表里的相对路径(最精确,带正确的子目录)。
        if let changed = agentChangedFileURL(path) {
            return changed
        }

        // 3) base + 相对路径直接拼。
        if let base = agentReferencedFileBase() {
            let url = base.appendingPathComponent(path).standardizedFileURL
            if Self.existingFile(at: url) { return url }
        }

        // 4) 兜底:在 quickOpen 索引和 worktree 改动里按「后缀匹配」找。
        //    agent 经常只写文件名(`version.go`)或部分路径,真实文件却在
        //    深层目录(`willdeep-agent/internal/agent/version.go`)。用后缀
        //    匹配把这种情况也接住;有多个候选时取路径最短的(最接近根)。
        if let fuzzy = fuzzyMatchReferencedFile(relativePath: path) {
            return fuzzy
        }

        return nil
    }

    /// 后缀匹配:`candidate` 的路径以 `/relativePath` 结尾,或 basename
    /// 完全相等。优先 quickOpen 索引(全工程文件),再退到 worktree 改动。
    private func fuzzyMatchReferencedFile(relativePath: String) -> URL? {
        let needle = "/" + relativePath
        let targetName = (relativePath as NSString).lastPathComponent

        func score(_ url: URL) -> Int { url.path.count }

        var candidates: [URL] = quickOpenFiles.filter { url in
            let p = url.path
            return p.hasSuffix(needle) || url.lastPathComponent == targetName
        }

        if candidates.isEmpty, let base = agentReferencedFileBase() {
            candidates = agentWorktreeChanges.files.compactMap { change in
                let url = base.appendingPathComponent(change.path).standardizedFileURL
                let p = url.path
                guard p.hasSuffix(needle) || url.lastPathComponent == targetName else { return nil }
                return Self.existingFile(at: url) ? url : nil
            }
        }

        return candidates.sorted { score($0) < score($1) }.first
    }

    private static func existingFile(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// 解析 chat 里的相对路径要找 base。优先级:worktree 已知 repo root →
    /// 当前 runtime 的 workspaceRootPath(Agent mode 下 editor 没打开
    /// 也得用得上) → editor rootDirectory(传统 editor mode)。
    private func agentReferencedFileBase() -> URL? {
        if let root = agentWorktreeChanges.repositoryRoot { return root }
        if let path = activeRuntime?.workspaceRootPath, !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return rootDirectory
    }

    nonisolated static func agentFilePathWithoutLineSuffix(_ rawPath: String) -> String {
        var parts = rawPath.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        while parts.count > 1, let last = parts.last, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        return parts.joined(separator: ":")
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
                self?.applyQuickOpenFiles(urls, ifRootMatches: rootPath)
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
                self?.applyQuickOpenFiles(urls, ifRootMatches: rootPath)
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
        editorTerminalSession.setWorkingDirectory(targetURL)
        isEditorTerminalVisible = true
    }

    func toggleEditorTerminal(_ url: URL? = nil) {
        if isEditorTerminalVisible {
            isEditorTerminalVisible = false
            return
        }
        openTerminalHere(url)
    }

    func openTerminalSettings() {
        EditorSettingsNavigation.shared.open(.terminal)
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
                openEditorFile(fileURL)
                refreshGitStatus()
                notifyEditorLanguageServiceWatchedFileChanged(url: fileURL, type: .created)
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
                notifyEditorLanguageServiceWatchedFileChanged(url: folderURL, type: .created)
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

            let replaced = Self.replacingRanges(ranges, in: tabs[index].content, with: replaceText)
            if tabs[index].content != replaced {
                tabs[index].contentRevision += 1
            }
            tabs[index].content = replaced
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
                    if tabs[tabIndex].content != replaced {
                        tabs[tabIndex].contentRevision += 1
                    }
                    tabs[tabIndex].content = replaced
                    if tabs[tabIndex].savedContent != replaced {
                        tabs[tabIndex].savedContentRevision += 1
                    }
                    tabs[tabIndex].savedContent = replaced
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
        guard let index = tabIndex(for: url) else {
            return false
        }
        let tab = tabs[index]
        return activateTab(id: tab.id)
    }

    func closeActiveTab() {
        guard let activeTabID else {
            return
        }
        closeTab(id: activeTabID)
    }

    func closeTab(id: EditorTab.ID) {
        guard var index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        if tabs[index].isEdited {
            let tab = tabs[index]
            let alert = NSAlert()
            alert.messageText = L10n.CloseTab.unsavedTitle
            alert.informativeText = L10n.CloseTab.unsavedMessage(tab.title)
            alert.addButton(withTitle: L10n.CloseTab.save)
            alert.addButton(withTitle: L10n.CloseTab.discard)
            alert.addButton(withTitle: L10n.CloseTab.cancel)
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

            // The modal alert (and the save panel behind it) spins a nested
            // runloop where main-queue work can mutate `tabs`; the index we
            // captured before the dialog may be stale. Re-resolve by id.
            guard let refreshedIndex = tabs.firstIndex(where: { $0.id == id }) else {
                return
            }
            index = refreshedIndex
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
        if tabs[index].content != fileContent {
            tabs[index].contentRevision += 1
        }
        tabs[index].content = fileContent
        if tabs[index].savedContent != fileContent {
            tabs[index].savedContentRevision += 1
        }
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
            if tabs[index].savedContent != tab.content {
                tabs[index].savedContentRevision += 1
            }
            tabs[index].savedContent = tab.content
            tabs[index].isEdited = false
            return true
        } catch {
            let saveAlert = NSAlert()
            saveAlert.messageText = L10n.CloseTab.saveFailedTitle
            saveAlert.informativeText = L10n.CloseTab.saveFailedMessage(tab.title, error.localizedDescription)
            saveAlert.alertStyle = .critical
            saveAlert.addButton(withTitle: L10n.CloseTab.ok)
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
            if window.identifier?.rawValue == AgentWindowID.value {
                if window.title != L10n.AgentWindow.title {
                    window.title = L10n.AgentWindow.title
                }
                window.isDocumentEdited = false
                return
            }
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
