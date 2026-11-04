//
//  AgentComposerPickers.swift
//  WillDeep
//
//  The pill-shaped pickers in the composer row, split out of
//  AgentModeComposerView.swift in rc42:
//   - `WorkspacePickerPill`: folder dropdown — current-folder Finder /
//     copy-path / copy-branch + a deduped list of known workspaces +
//     a "Choose folder…" sentinel.
//   - `ModelPickerPill`: provider/model selector. Flat Section per
//     provider with Flash and Pro models as direct rows (nested Menus
//     on macOS dismiss on the slightest hover drift). Has
//     "Recently used", "Hot", "New", and "All models" tail
//     menus for ad-hoc model IDs not in the library entries.
//   - `AgentExecutionPickerPill`: WillDeep / Claude Code / Codex
//     execution backend selector for the next composer turn.
//   - `AgentModePickerPill`: Ordinary / Goal selector. Ordinary mode plans
//     and executes as needed; Goal repeatedly checks a persistent objective.
//   - `AgentApprovalModePickerPill`: per-session tool approval posture
//     selector — request every time, smart approval, or workspace access.
//     with one-way activation switches.
//   - `ComposerAdaptiveControlStrip`: progressively exposes overflow
//     controls inline when the composer has room.
//
//  Previously `private struct` inside the composer file; now internal
//  so the composer card and any future host can mount them across
//  file boundaries. The `String.nilIfEmpty` helper ModelPickerPill
//  relies on tags along too.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Workspace picker pill

/// A small dropdown next to the model picker that lets the user pick
/// (or change) which folder this chat thinks of as its workspace.
///
/// Two states:
///   1. No workspace yet → label reads "Pick folder", clicking opens
///      a menu of every known workspace (sessions' roots ∪ recent
///      folders, deduped) with a "Choose folder…" sentinel at the
///      bottom that triggers the system folder picker.
///   2. A workspace is set → label shows the folder name. Clicking
///      opens a menu with the same picker on top, plus three
///      affordances against the *current* folder: Show in Finder /
///      Copy path / Copy branch name.
private struct WorkspaceMenuItem: Identifiable {
    let id: String
    let path: String
    let displayName: String
}

struct WorkspacePickerPill: View {
    @EnvironmentObject var appState: AppState
    @State private var knownWorkspaceCache: [WorkspaceMenuItem] = []
    @State private var remoteRuntimeCache: [RuntimeDescriptor] = []

    var body: some View {
        Menu {
            menuContent
        } label: {
            HStack(spacing: 3) {
                Image(systemName: workspaceIconName)
                    .font(.system(size: 10))
                    .foregroundStyle(workspaceIconTint)
                Text(label)
                    .font(AgentDesign.chatSupportingFont(
                        baseFontSize: appState.agentChatBaseFontSize
                    ))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: AgentDesign.pillCornerRadius))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .focusable(false)
        .fixedSize()
        .help(helpText)
        .onAppear {
            refreshMenuCaches()
            appState.refreshAgentGitWorktrees()
        }
        .onReceive(appState.$agentSessions) { _ in
            refreshMenuCaches()
        }
        .onReceive(appState.$recentFolders) { _ in
            refreshMenuCaches()
        }
        .onCompatibleChange(of: appState.rootDirectory) { _, _ in
            appState.refreshAgentGitWorktrees()
        }
    }

    private var label: String {
        if let remote = activeRemoteWorkspaceLabel {
            return remote
        }
        if let localPath = activeLocalWorkspacePath {
            let root = URL(fileURLWithPath: localPath)
            return root.lastPathComponent.isEmpty ? localPath : root.lastPathComponent
        }
        return L10n.ComposerWorkspace.pickFolder
    }

    private var helpText: String {
        if let remote = activeRemoteWorkspace {
            return WorkspacePresentation.remoteHelp(runtime: remote.runtime, path: remote.path)
        }
        if let localPath = activeLocalWorkspacePath {
            return localPath
        }
        if appState.activeRuntime == nil, let root = appState.rootDirectory {
            return root.path
        }
        return L10n.ComposerWorkspace.chooseWorkspaceHelp
    }

    @ViewBuilder
    private var menuContent: some View {
        let activeLocalPath = activeLocalWorkspacePath

        // Section 1 — the "current folder" affordances (only if one is set).
        if let root = activeLocalWorkspaceURL {
            Section(root.lastPathComponent) {
                Button {
                    appState.revealInFinder(root)
                } label: {
                    Label(L10n.ComposerWorkspace.showInFinder, systemImage: "folder")
                }
                Button {
                    appState.copyPath(root)
                } label: {
                    Label(L10n.ComposerWorkspace.copyPath, systemImage: "doc.on.doc")
                }
                if let branch = appState.agentWorkspaceGitStatus.branchName, !branch.isEmpty {
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(branch, forType: .string)
                    } label: {
                        Label(L10n.ComposerWorkspace.copyBranchName, systemImage: "arrow.triangle.branch")
                    }
                }
            }
            Divider()
        }

        if appState.agentWorkspaceGitStatus.isRepository {
            Section(L10n.ComposerWorkspace.gitWorktrees) {
                let activeExecutionPath = activeExecutionLocalWorkspacePath
                Button {
                    appState.createAgentGitWorktreeFromActiveWorkspace()
                } label: {
                    Label(L10n.ComposerWorkspace.newWorktree, systemImage: "arrow.triangle.branch")
                }
                .disabled(appState.agentGitWorktreeCreation != nil)

                ForEach(appState.agentGitWorktrees) { worktree in
                    Button {
                        appState.moveActiveAgentSessionToGitWorktree(
                            at: worktree.path,
                            sidebarWorkspaceRootPath: primaryWorktree?.path ?? worktree.path
                        )
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(worktree.displayName)
                                Text(worktree.branchLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if activeExecutionPath == worktree.url.path {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(worktree.isBare)
                }

                if let removable = activeRemovableWorktree {
                    Button(role: .destructive) {
                        appState.removeAgentGitWorktree(removable)
                    } label: {
                        Label(L10n.ComposerWorkspace.removeCurrentWorktree, systemImage: "trash")
                    }
                }

                if appState.agentGitWorktrees.contains(where: \.isPrunable) {
                    Button {
                        appState.pruneAgentGitWorktrees()
                    } label: {
                        Label(L10n.ComposerWorkspace.pruneStaleWorktrees, systemImage: "scissors")
                    }
                }
            }
            Divider()
        }

        // Section 2 — Switch to a known workspace. Dedupes against
        // the current root so the active folder doesn't double up.
        let knownRoots = knownWorkspaceCache
        if !knownRoots.isEmpty {
            Section(L10n.ComposerWorkspace.switchWorkspace) {
                ForEach(knownRoots) { url in
                    Button {
                        appState.moveActiveAgentSessionToWorkspace(at: url.path)
                    } label: {
                        HStack {
                            Text(url.displayName)
                            if activeLocalPath == url.path {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Divider()
        }

        let remoteRuntimes = remoteRuntimeCache
        if !remoteRuntimes.isEmpty {
            Section(L10n.ComposerWorkspace.remoteRuntimes) {
                ForEach(remoteRuntimes) { runtime in
                    Button {
                        appState.moveActiveAgentSessionToRemoteWorkspace(
                            runtimeID: runtime.id,
                            path: runtime.defaultWorkspacePath
                        )
                    } label: {
                        HStack {
                            Text("\(runtime.displayName): \(runtime.defaultWorkspacePath)")
                            Text(WorkspacePresentation.remoteBadge(for: runtime))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(WorkspacePresentation.remoteTint(for: runtime))
                            if activeRemoteRuntime?.id == runtime.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(AgentComposerChrome.iconPrimary)
                            }
                        }
                    }
                }
            }
            Divider()
        }

        // Section 3 — Always show the chooser sentinel last. Composer
        // path uses the "and start a new agent session" variant so the
        // picked folder immediately materialises as its own workspace
        // group in the sidebar (instead of leaving the user with a
        // re-rooted window but no session anchored to the new dir).
        Button {
            appState.openFolderAndStartAgentSession()
        } label: {
            Label(L10n.ComposerWorkspace.chooseFolder, systemImage: "folder.badge.plus")
        }
    }

    private var activeRemoteRuntime: RuntimeDescriptor? {
        activeRemoteWorkspace?.runtime
    }

    private var activeLocalWorkspaceURL: URL? {
        guard let path = activeLocalWorkspacePath else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var activeLocalWorkspacePath: String? {
        guard let runtime = appState.activeRuntime else { return nil }
        let path = runtime.session.sidebarWorkspaceRootPath
            ?? runtime.workspaceLocation?.localPath
            ?? runtime.workspaceRootPath
        guard let path, !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private var activeExecutionLocalWorkspacePath: String? {
        guard let path = appState.activeRuntime?.workspaceLocation?.localPath, !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private var primaryWorktree: AgentGitWorktree? {
        appState.agentGitWorktrees.first(where: \.isPrimary)
    }

    private var activeRemovableWorktree: AgentGitWorktree? {
        guard let activeExecutionLocalWorkspacePath else { return nil }
        return appState.agentGitWorktrees.first { worktree in
            activeExecutionLocalWorkspacePath == worktree.url.path && !worktree.isPrimary && !worktree.isBare
        }
    }

    private var activeRemoteWorkspaceLabel: String? {
        guard let remote = activeRemoteWorkspace else {
            return nil
        }
        return WorkspacePresentation.remoteDisplayName(runtime: remote.runtime, path: remote.path)
    }

    private var activeRemoteWorkspace: (runtime: RuntimeDescriptor?, path: String)? {
        guard case .remote(let runtimeID, let path) = appState.activeRuntime?.workspaceLocation else {
            return nil
        }
        return (remoteRuntimeCache.first { $0.id == runtimeID }, path)
    }

    private var workspaceIconName: String {
        if let remote = activeRemoteWorkspace {
            return WorkspacePresentation.remoteSymbolName(for: remote.runtime)
        }
        return "folder"
    }

    private var workspaceIconTint: Color {
        // Workspace identity remains visible through its symbol and label;
        // Composer chrome does not inherit runtime/provider brand colors.
        return Color.secondary
    }

    private func refreshMenuCaches() {
        knownWorkspaceCache = sortedKnownWorkspaces()
        remoteRuntimeCache = AgentRuntimeStore.loadDescriptors()
            .filter { $0.transport == .ssh && !$0.defaultWorkspacePath.isEmpty }
    }

    /// Union of (a) folder paths that appear as workspaceRootPath on
    /// any agent session, and (b) recentFolders. Both deduped to a
    /// canonical path; sorted by display name for menu stability.
    private func sortedKnownWorkspaces() -> [WorkspaceMenuItem] {
        var seen = Set<String>()
        var result: [WorkspaceMenuItem] = []

        let sessionRoots: [String] = appState.agentSessions
            .compactMap { session -> String? in
                guard let path = session.workspaceRootPath, !path.isEmpty else { return nil }
                return URL(fileURLWithPath: path).standardizedFileURL.path
            }

        let recentRoots = appState.recentFolders.map { $0.standardizedFileURL.path }
        for path in sessionRoots + recentRoots {
            let key = path
            if seen.insert(key).inserted {
                result.append(workspaceMenuItem(for: key))
            }
        }

        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func workspaceMenuItem(for path: String) -> WorkspaceMenuItem {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return WorkspaceMenuItem(
            id: path,
            path: path,
            displayName: name.isEmpty ? path : name
        )
    }
}

// MARK: - Adaptive composer controls

enum ComposerOverflowControl: Hashable {
    case approval
    case executor
}

struct ComposerAdaptiveControlStrip: View {
    @EnvironmentObject private var appState: AppState

    // rc482 perf: 改为固定单套布局，去掉 ViewThatFits。原先用 ViewThatFits
    // 在三套布局变体间按窗口宽度挑一套显示，代价是**每次重渲染都要把每个
    // 变体整建一遍来测量**——composer pill 重建因此成为主线程热点（打字、
    // 窗口切换、焦点变化都中招，采样里占主线程大头）。现在常用的四个
    // （Workspace / Model / Mode / Approval）固定展示，执行偏好
    // 收进「更多 …」弹层。执行器固定在输入框顶部上下文栏右侧。
    // 布局不再随宽度变化，每次重建只建一套。
    var body: some View {
        HStack(spacing: 6) {
            // 只有 WillDeep 执行器时才显示模型选择器。委派给 Claude Code / Codex
            // 等外部执行器时，这个选择器设的是 WillDeep 外层编排模型，不是真正
            // 交给外部 CLI 的模型（后者来自工具调用参数），暴露它会误导用户。
            if appState.agentExecutionAgent == .willDeep {
                ModelPickerPill()
            }
            AgentModePickerPill()
            AgentApprovalModePickerPill()
            ComposerOverflowPill(controls: [])
        }
        .focusable(false)
    }
}

// MARK: - Model picker pill

struct ModelPickerPill: View {
    nonisolated static let modelSymbol = "brain.head.profile"

    @EnvironmentObject var appState: AppState
    @Environment(\.openURL) private var openURL
    @State private var menuSnapshot = ModelPickerMenuSnapshot.empty
    @State private var isModelPanelPresented = false
    @State private var selectedModelProviderID: UUID?
    @State private var selectedModelSourceIsManaged = false
    @State private var selectedSource: AgentModelPickerSource = .managed
    @State private var selectedTierFilter: AgentModelPickerTierFilter = .all
    @State private var searchText = ""
    @State private var fetchedModelsByProvider: [UUID: [String]] = [:]
    @State private var loadingProviderIDs: Set<UUID> = []
    @State private var providerLoadFailures: Set<UUID> = []
    @State private var isDiscoveringLocalGateways = false
    @State private var localGatewayDiscoveryTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggleModelPanel) {
                HStack(spacing: 5) {
                    Image(systemName: Self.modelSymbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isManagedRoutingActive ? Color.primary : Color.secondary)
                    Text(pillLabel)
                        .font(AgentDesign.chatSupportingFont(
                            baseFontSize: appState.agentChatBaseFontSize
                        ))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: AgentModelPickerPresentation.compactLabelMaxWidth)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .padding(.leading, 8)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.AgentModelPicker.chooseHelp)


        }
        .foregroundStyle(.secondary)
        .background(AgentComposerChrome.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: AgentDesign.pillCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AgentDesign.pillCornerRadius, style: .continuous)
                .stroke(
                    AgentComposerChrome.border,
                    lineWidth: 1
                )
        }
        .fixedSize()
        .popover(isPresented: $isModelPanelPresented, arrowEdge: .bottom) {
            modelSelectionPanel
                .frame(width: 820, height: 650)
        }
        .onAppear {
            refreshMenuSnapshot()
        }
        .onReceive(appState.$agentProviderLibrary) { _ in
            refreshMenuSnapshot()
        }
        .onReceive(appState.$magpieIntegrationState) { _ in
            // @Published emits before assignment; defer the projection read.
            Task { @MainActor in refreshMenuSnapshot() }
        }
        .onReceive(appState.$agentConfiguration) { _ in
            refreshMenuSnapshot()
        }
        .onReceive(appState.$agentRecentlyUsedModelIDs) { _ in
            refreshMenuSnapshot()
        }
        .onReceive(appState.$agentKnownModelIDs) { _ in
            refreshMenuSnapshot()
        }
        .onReceive(appState.$agentDiscoveredModelMetadata) { _ in
            refreshMenuSnapshot()
        }
        .onReceive(appState.$activeAgentSessionID) { _ in
            refreshMenuSnapshot()
        }
        .onCompatibleChange(of: appState.agentSessionModelOverride ?? "") { _, _ in
            refreshMenuSnapshot()
        }
        .onReceive(managedRoutingPublisher, perform: handleManagedRoutingChange)
    }

    @ViewBuilder
    private var modelSelectionPanel: some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(L10n.AgentModelPicker.selectModel)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 164, alignment: .leading)
                modelSearchField
                Button {
                    closeModelPanel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            HStack(alignment: .top, spacing: 0) {
                providerSelectionColumn
                    .frame(width: 190)
                    .padding(10)
                    .focusable(false)

                Divider()

                modelDetailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .focusable(false)
            }
            .focusable(false)

            Divider()
            Text(L10n.AgentModelPicker.selectionFooter)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .background(palette.panelFill.opacity(0.98))
        .focusable(false)
    }

    @ViewBuilder
    private var providerSelectionColumn: some View {
        let entries = selectableProviderEntries
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
            providerSourceButton(
                title: L10n.AgentModelPicker.managed,
                subtitle: L10n.AgentModelPicker.managedSubtitle,
                systemImage: "wand.and.stars",
                checked: selectedSource == .managed
            ) {
                selectSource(.managed)
            }

            providerSourceButton(
                title: L10n.AgentModelPicker.allModels,
                subtitle: L10n.AgentModelPicker.modelCount(allCatalogItems.count),
                systemImage: "circle.grid.2x2",
                checked: selectedSource == .allModels
            ) {
                selectSource(.allModels)
            }

            providerSourceButton(
                title: L10n.AgentModelPicker.codingRecommended,
                subtitle: L10n.AgentModelPicker.recommended,
                systemImage: "wand.and.stars.inverse",
                checked: selectedSource == .codingRecommended
            ) {
                selectSource(.codingRecommended)
            }

            // 只在价目表真的报出免费模型时出现。没有模型免费时摆一个空分组，
            // 等于让人点进去看一句「没有模型」。
            if !freeCatalogItems.isEmpty {
                providerSourceButton(
                    title: L10n.AgentModelPicker.free,
                    subtitle: L10n.AgentModelPicker.modelCount(freeCatalogItems.count),
                    systemImage: "gift",
                    checked: selectedSource == .free
                ) {
                    selectSource(.free)
                }
            }

            providerSourceButton(
                title: L10n.AgentModelPicker.recent,
                subtitle: L10n.AgentModelPicker.modelCount(recentCatalogItems.count),
                systemImage: "clock",
                checked: selectedSource == .recent
            ) {
                selectSource(.recent)
            }

            Divider()
                .padding(.vertical, 5)

            HStack(spacing: 6) {
                Text(L10n.AgentModelPicker.providers)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                if isDiscoveringLocalGateways {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 7)

            if isDiscoveringLocalGateways && entries.isEmpty {
                HStack(spacing: 6) {
                    Text(L10n.Settings.Provider.searchingLocalGateways)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
            }

            if appState.isRefreshingMagpieIntegration {
                Text(L10n.MagpieIntegration.refreshing).font(.caption).foregroundStyle(.secondary)
            }
            if let failure = appState.magpieIntegrationFailure {
                Text(failure.localizedDescription).font(.caption).foregroundStyle(.secondary)
            }

            ForEach(entries) { entry in
                providerSourceButton(
                    title: entry.displayName,
                    subtitle: providerCatalogSubtitle(entry),
                    systemImage: providerIcon(entry),
                    checked: selectedSource == .provider(entry.id)
                ) {
                    selectSource(.provider(entry.id))
                    refreshProviderCatalog(entry)
                }
            }

            }
        }
        .scrollIndicators(.hidden)
        .focusable(false)
    }

    @ViewBuilder
    private var modelDetailColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if normalizedSearchText.isEmpty {
                    sourceDetail
                } else {
                    searchResultsDetail
                }
            }
            .padding(14)
            .focusable(false)
        }
        // Rebuilds the scroll view whenever the content set changes, so the
        // offset returns to the top instead of pointing past the end of shorter
        // content — where the LazyVStack would render nothing at all. See
        // `AgentModelDetailScrollIdentity`.
        .id(AgentModelDetailScrollIdentity(
            source: selectedSource,
            isSearching: !normalizedSearchText.isEmpty
        ))
        .focusable(false)
    }

    private var modelSearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(L10n.AgentModelPicker.searchPlaceholder, text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(selectFirstSearchResult)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.54))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var sourceDetail: some View {
        switch selectedSource {
        case .managed:
            managedCatalogOverview
        case .allModels:
            allModelsDetail
        case .codingRecommended:
            codingRecommendationsDetail
        case .free:
            freeModelsDetail
        case .recent:
            recentModelsDetail
        case let .provider(entryID):
            if let entry = selectableProviderEntries.first(where: { $0.id == entryID }) {
                providerCatalogDetail(entry)
            } else {
                emptyProviderDetail
            }
        }
    }

    @ViewBuilder
    private var managedCatalogOverview: some View {
        managedSelectionSummary
        managedBenefitsSummary
    }

    @ViewBuilder
    private var managedSelectionSummary: some View {
        if managedMarketingStatus == .selected {
            managedSelectionSummaryContent
        } else {
            Button(action: performManagedSummaryAction) {
                managedSelectionSummaryContent
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(managedSelectionTitle)
        }
    }

    private var managedSelectionSummaryContent: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: managedSelectionIcon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AgentComposerChrome.iconPrimary)
                .frame(width: 36, height: 36)
                .background(AgentComposerChrome.selectedControlFill)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.AgentModelPicker.managed)
                    .font(.system(size: 15, weight: .semibold))
                Text(managedSelectionTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(managedSelectionTint)
                Text(managedSelectionDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if managedMarketingStatus != .selected {
                Label(managedSelectionActionTitle, systemImage: managedSelectionActionIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(managedSelectionTint.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var managedBenefitsSummary: some View {
        modelPanelSection(
            title: L10n.AgentModelPicker.managedBenefitsTitle,
            systemImage: "point.3.connected.trianglepath.dotted"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                managedBenefitRow(
                    systemImage: "checkmark.seal",
                    title: L10n.AgentModelPicker.managedJudgeTitle,
                    description: L10n.AgentModelPicker.managedJudgeDescription
                )
                Divider().padding(.leading, 36)
                managedBenefitRow(
                    systemImage: "hammer",
                    title: L10n.AgentModelPicker.managedWorkerTitle,
                    description: L10n.AgentModelPicker.managedWorkerDescription
                )
            }
            .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.42))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func managedBenefitRow(
        systemImage: String,
        title: String,
        description: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AgentComposerChrome.iconPrimary)
                .frame(width: 26, height: 26)
                .background(AgentComposerChrome.selectedControlFill)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(description)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    private var managedSelectionTitle: String {
        switch managedMarketingStatus {
        case .selected:
            return L10n.AgentModelPicker.managedSelectedTitle
        case .available:
            return L10n.AgentModelPicker.managedNotSelectedTitle
        case .loginRequired:
            return L10n.AgentModelPicker.managedLoginRequiredTitle
        }
    }

    private var managedSelectionDescription: String {
        switch managedMarketingStatus {
        case .selected:
            return L10n.AgentModelPicker.managedSelectedDescription
        case .available:
            return L10n.AgentModelPicker.managedNotSelectedDescription
        case .loginRequired:
            return L10n.AgentModelPicker.managedLoginRequiredDescription
        }
    }

    private var managedSelectionIcon: String {
        switch managedMarketingStatus {
        case .selected: return "checkmark.circle.fill"
        case .available: return "circle"
        case .loginRequired: return "lock"
        }
    }

    private var managedSelectionTint: Color {
        switch managedMarketingStatus {
        case .selected: return .green
        case .available: return .teal
        case .loginRequired: return .secondary
        }
    }

    private var managedSelectionActionTitle: String {
        switch managedMarketingStatus {
        case .selected:
            return L10n.AgentModelPicker.managedSelectedTitle
        case .available:
            return L10n.AgentModelPicker.selectManaged
        case .loginRequired:
            return L10n.AgentModelPicker.signInSomeIM
        }
    }

    private var managedSelectionActionIcon: String {
        switch managedMarketingStatus {
        case .selected: return "checkmark"
        case .available: return "sparkles"
        case .loginRequired: return "person.crop.circle.badge.checkmark"
        }
    }

    private func performManagedSummaryAction() {
        switch managedMarketingStatus {
        case .selected:
            break
        case .available:
            chooseManagedRouting(tier: .low)
        case .loginRequired:
            isModelPanelPresented = false
            EditorSettingsNavigation.shared.openSomeIM(
                autogenerateBrowserLogin: true,
                appState: appState
            )
        }
    }

    private var managedMarketingStatus: AgentManagedMarketingStatus {
        AgentManagedMarketingStatus.resolve(
            isAuthenticated: menuSnapshot.isSomeIMAuthenticated,
            isManagedActive: menuSnapshot.managedActive
        )
    }

    @ViewBuilder
    private var allModelsDetail: some View {
        catalogSectionHeader(
            title: L10n.AgentModelPicker.allModels,
            subtitle: L10n.AgentModelPicker.modelCount(allCatalogItems.count)
        )
        if allCatalogItems.isEmpty {
            catalogEmptyState(L10n.AgentModelPicker.noModels, clearable: false)
        } else {
            ForEach(selectableProviderEntries) { entry in
                let items = catalogItems(for: entry)
                if !items.isEmpty {
                    catalogSectionHeader(
                        title: entry.displayName,
                        subtitle: L10n.AgentModelPicker.modelCount(items.count)
                    )
                    providerCatalogRows(items, entry: entry)
                }
            }
        }
    }

    @ViewBuilder
    private var codingRecommendationsDetail: some View {
        catalogSectionHeader(
            title: L10n.AgentModelPicker.codingPicks,
            subtitle: L10n.AgentModelPicker.recommended
        )
        let recommendations = resolvedCodingRecommendations
        if recommendations.isEmpty {
            catalogEmptyState(L10n.AgentModelPicker.noModels, clearable: false)
        } else {
            ForEach(recommendations) { recommendation in
                catalogModelRow(
                    recommendation.item,
                    title: recommendation.title,
                    note: recommendation.note,
                    tags: recommendation.tags,
                    recommended: true
                )
            }
        }
    }

    @ViewBuilder
    private var recentModelsDetail: some View {
        catalogSectionHeader(
            title: L10n.AgentModelPicker.recent,
            subtitle: L10n.AgentModelPicker.modelCount(recentCatalogItems.count)
        )
        if recentCatalogItems.isEmpty {
            catalogEmptyState(L10n.AgentModelPicker.noModels, clearable: false)
        } else {
            catalogRows(recentCatalogItems)
        }
    }

    @ViewBuilder
    private var freeModelsDetail: some View {
        catalogSectionHeader(
            title: L10n.AgentModelPicker.free,
            subtitle: L10n.AgentModelPicker.modelCount(freeCatalogItems.count)
        )
        if freeCatalogItems.isEmpty {
            catalogEmptyState(L10n.AgentModelPicker.noModels, clearable: false)
        } else {
            catalogRows(freeCatalogItems)
        }
    }

    @ViewBuilder
    private func providerCatalogDetail(_ entry: AgentProviderEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: providerIcon(entry))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AgentComposerChrome.iconPrimary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .font(.system(size: 14, weight: .semibold))
                    if menuSnapshot.activeProviderID == entry.id {
                        pickerTag(L10n.AgentModelPicker.current, tint: .teal)
                    }
                }
                Text(L10n.AgentModelPicker.modelCount(catalogItems(for: entry).count))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            providerTierFilters
        }

        let items = AgentModelPickerCatalog.filtered(catalogItems(for: entry), by: selectedTierFilter)
        if loadingProviderIDs.contains(entry.id), items.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.AgentModelPicker.loadingModels)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 18)
        } else if items.isEmpty {
            catalogEmptyState(L10n.AgentModelPicker.noModels, clearable: false)
        } else {
            providerCatalogRows(items, entry: entry)
        }

        if providerLoadFailures.contains(entry.id) {
            Button {
                refreshProviderCatalog(entry, force: true)
            } label: {
                Label(L10n.AgentModelPicker.retryCatalog, systemImage: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .foregroundStyle(AgentComposerChrome.iconPrimary)
        }
    }

    private var providerTierFilters: some View {
        HStack(spacing: 5) {
            ForEach(AgentModelPickerTierFilter.allCases) { filter in
                Button {
                    selectedTierFilter = filter
                } label: {
                    Text(tierFilterLabel(filter))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(selectedTierFilter == filter ? Color.teal : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(selectedTierFilter == filter ? Color.teal.opacity(0.12) : Color.clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
    }

    @ViewBuilder
    private var searchResultsDetail: some View {
        catalogSectionHeader(
            title: L10n.AgentModelPicker.resultCount(searchResults.count),
            subtitle: searchText
        )
        if searchResults.isEmpty {
            catalogEmptyState(L10n.AgentModelPicker.noResults, clearable: true)
        } else {
            ForEach(selectableProviderEntries) { entry in
                let providerResults = searchResults.filter { $0.providerEntryID == entry.id }
                if !providerResults.isEmpty {
                    catalogSectionHeader(
                        title: entry.displayName,
                        subtitle: L10n.AgentModelPicker.modelCount(providerResults.count)
                    )
                    providerCatalogRows(providerResults, entry: entry)
                }
            }
        }
    }

    private func catalogSectionHeader(title: String, subtitle: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func catalogRows(_ items: [AgentModelCatalogItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                catalogModelRow(
                    item,
                    title: modelDisplayTitle(item.modelID),
                    note: modelDescription(item),
                    tags: catalogTags(item),
                    recommended: false
                )
                if item.id != items.last?.id {
                    Divider().padding(.leading, 32)
                }
            }
        }
    }

    @ViewBuilder
    private func providerCatalogRows(_ items: [AgentModelCatalogItem], entry: AgentProviderEntry) -> some View {
        if entry.displayName.caseInsensitiveCompare("Magpie") == .orderedSame {
            let groups = AgentModelPickerCatalog.prefixGroups(items)
            ForEach(groups, id: \.prefix) { group in
                catalogSectionHeader(
                    title: group.prefix,
                    subtitle: L10n.AgentModelPicker.modelCount(group.items.count)
                )
                catalogRows(group.items)
            }
            let ungroupedItems = AgentModelPickerCatalog.itemsWithoutPrefix(items)
            if !ungroupedItems.isEmpty {
                catalogRows(ungroupedItems)
            }
        } else {
            catalogRows(items)
        }
    }

    private func catalogModelRow(
        _ item: AgentModelCatalogItem,
        title: String,
        note: String,
        tags: [String],
        recommended: Bool
    ) -> some View {
        Button {
            selectCatalogItem(item)
        } label: {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: modelIcon(item))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isCatalogItemCurrent(item) ? AgentComposerChrome.iconPrimary : AgentComposerChrome.iconSecondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        pickerTag(item.providerName, tint: .secondary)
                        ForEach(tags, id: \.self) { tag in
                            pickerTag(tag, tint: .secondary)
                        }
                        if recommended {
                            pickerTag(L10n.AgentModelPicker.recommended, tint: .teal)
                        }
                    }
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isCatalogItemCurrent(item) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AgentComposerChrome.iconPrimary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(isCatalogItemCurrent(item) ? Color.teal.opacity(0.10) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func pickerTag(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.opacity(0.10))
            .clipShape(Capsule())
    }

    private func catalogEmptyState(_ title: String, clearable: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            if clearable {
                Button(L10n.AgentModelPicker.clearSearch) {
                    searchText = ""
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .focusable(false)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }


    @ViewBuilder
    private var managedRoutingDetail: some View {
        detailHeader(
            title: "省心托管",
            subtitle: L10n.AgentModelPicker.managedRule,
            systemImage: "wand.and.stars",
            checked: menuSnapshot.managedActive
        )

        modelPanelSection(title: L10n.AgentManagedRouting.title, systemImage: "slider.horizontal.3") {
            Button {
                chooseManagedRouting(tier: menuSnapshot.managedFloor ?? .low)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AgentComposerChrome.actionForeground)
                        .frame(width: 28, height: 28)
                        .background(AgentComposerChrome.actionFill)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("启用省心托管")
                            .font(.system(size: 12, weight: .semibold))
                        Text("不确定选哪个模型时，优先用这个。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if menuSnapshot.managedActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AgentComposerChrome.iconPrimary)
                    }
                }
                .padding(10)
                .background(modelRowBackground(checked: menuSnapshot.managedActive))
            }
            .buttonStyle(.plain)
            .focusable(false)

        }

        recommendedModelsSection
    }

    @ViewBuilder
    private func providerModelDetail(_ entry: AgentProviderEntry) -> some View {
        let isActive = menuSnapshot.activeProviderID == entry.id
        detailHeader(
            title: entry.displayName,
            subtitle: isActive ? "当前 provider；选择下方模型可切换本会话用量。" : "先选中这个 provider，再从右侧选择模型。",
            systemImage: providerIcon(entry),
            checked: isActive
        )

        modelPanelSection(title: "路由默认", systemImage: "location") {
            let defaultModel = entry.makeConfiguration().normalized.model(for: .interactive)
            modelActionRow(
                title: "使用 \(entry.displayName) 默认路由",
                subtitle: defaultModel,
                badge: "Default",
                systemImage: "arrow.triangle.2.circlepath",
                checked: isActive && menuSnapshot.sessionOverride == nil && !menuSnapshot.managedActive
            ) {
                pick(entry: entry, model: defaultModel)
                closeModelPanel()
            }
        }

        if !entry.allFlashModels.isEmpty {
            modelPanelSection(title: "Flash", systemImage: "bolt") {
                ForEach(entry.allFlashModels, id: \.self) { model in
                    providerModelButton(entry: entry, model: model, label: "Flash")
                }
            }
        }

        if !entry.allProModels.isEmpty {
            modelPanelSection(title: "Pro", systemImage: "speedometer") {
                ForEach(entry.allProModels, id: \.self) { model in
                    providerModelButton(entry: entry, model: model, label: "Pro")
                }
            }
        }

        if entry.providerID == AgentProviderPreset.someIMID, menuSnapshot.isSomeIMAuthenticated {
            recommendedModelsSection
        }

        let extraModels = catalogModels(for: entry)
        if !extraModels.isEmpty {
            modelPanelSection(title: "更多模型", systemImage: "list.bullet") {
                ForEach(extraModels, id: \.self) { model in
                    modelActionRow(
                        title: model,
                        subtitle: "来自最近使用 / 热门 / 新模型 / 已获取列表",
                        badge: nil,
                        systemImage: "circle.grid.2x2",
                        checked: isCurrent(model: model, override: menuSnapshot.sessionOverride, isActive: isActive)
                    ) {
                        pick(entry: entry, model: model)
                        closeModelPanel()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyProviderDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("还没有可用 provider", systemImage: "exclamationmark.circle")
                .font(.system(size: 13, weight: .semibold))
            Text("请先到 Settings → Agent 添加模型服务商。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func providerSourceButton(
        title: String,
        subtitle: String,
        systemImage: String,
        checked: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(checked ? AgentComposerChrome.iconPrimary : AgentComposerChrome.iconSecondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: checked ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if checked {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AgentComposerChrome.iconPrimary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(modelRowBackground(checked: checked))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    @ViewBuilder
    private func detailHeader(
        title: String,
        subtitle: String,
        systemImage: String,
        checked: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(checked ? AgentComposerChrome.iconPrimary : AgentComposerChrome.iconSecondary)
                .frame(width: 34, height: 34)
                .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    if checked {
                        Text("当前")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.teal)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.teal.opacity(0.13))
                            .clipShape(Capsule())
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.40))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .focusable(false)
    }

    private var selectedProviderEntry: AgentProviderEntry? {
        let entries = selectableProviderEntries
        if let selectedModelProviderID,
           let selected = entries.first(where: { $0.id == selectedModelProviderID }) {
            return selected
        }
        if let activeID = menuSnapshot.activeProviderID,
           let active = entries.first(where: { $0.id == activeID }) {
            return active
        }
        return entries.first
    }

    private func providerSubtitle(_ entry: AgentProviderEntry) -> String {
        if menuSnapshot.activeProviderID == entry.id {
            return menuSnapshot.managedActive ? "当前 · 托管中" : "当前 provider"
        }
        let model = entry.makeConfiguration().normalized.model(for: .interactive)
        return model.isEmpty ? "未设置默认模型" : model
    }

    private func providerIcon(_ entry: AgentProviderEntry) -> String {
        switch entry.providerID {
        case AgentProviderPreset.someIMID: return "sparkles"
        case "openai": return "circle.hexagongrid"
        case "anthropic": return "a.circle"
        case "google": return "g.circle"
        case "dashscope": return "cloud"
        default: return "server.rack"
        }
    }

    private func catalogModels(for entry: AgentProviderEntry) -> [String] {
        let libraryModels = Set((entry.allFlashModels + entry.allProModels).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        return combinedCatalogModels.filter { model in
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !libraryModels.contains(trimmed.lowercased()) else { return false }
            guard let preset = AgentProviderPreset.preset(id: entry.providerID),
                  preset.id != AgentProviderPreset.customID else {
                return true
            }
            return preset.recognizesModelID(trimmed)
        }
    }

    @ViewBuilder
    private var currentRouteSection: some View {
        modelPanelSection(title: "当前选择", systemImage: "location") {
            if !menuSnapshot.configuredModel.isEmpty {
                modelActionRow(
                    title: "使用路由默认值",
                    subtitle: menuSnapshot.configuredModel,
                    badge: "Default",
                    systemImage: "arrow.triangle.2.circlepath",
                    checked: menuSnapshot.sessionOverride == nil && !menuSnapshot.managedActive
                ) {
                    appState.recordRecentlyUsedAgentModel(menuSnapshot.configuredModel)
                    appState.setAgentSessionModel(nil)
                    closeModelPanel()
                }
            }
        }
    }

    @ViewBuilder
    private var managedRoutingHero: some View {
        modelPanelSection(title: "最省心", systemImage: "sparkles") {
            Button {
                chooseManagedRouting(tier: .low)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AgentComposerChrome.actionForeground)
                        .frame(width: 38, height: 38)
                        .background(AgentComposerChrome.actionFill)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text("省心托管")
                                .font(.system(size: 14, weight: .semibold))
                            Text("不懂就选这个")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.teal)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.teal.opacity(0.13))
                                .clipShape(Capsule())
                        }
                        Text(L10n.AgentModelPicker.managedRule)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if menuSnapshot.managedActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AgentComposerChrome.iconPrimary)
                    }
                }
                .padding(12)
                .background(modelRowBackground(checked: menuSnapshot.managedActive))
            }
            .buttonStyle(.plain)
            .focusable(false)

        }
    }

    @ViewBuilder
    private var recommendedModelsSection: some View {
        modelPanelSection(title: "重点推荐", systemImage: "star") {
            ForEach(Self.recommendedSomeIMModels) { item in
                modelActionRow(
                    title: item.title,
                    subtitle: "\(item.model) · \(item.note)",
                    badge: item.badge,
                    systemImage: item.systemImage,
                    checked: isCurrent(model: item.model, override: menuSnapshot.sessionOverride, isActive: menuSnapshot.isSomeIMActive)
                ) {
                    chooseSomeIMModel(item.model)
                }
            }
        }
    }

    @ViewBuilder
    private var someIMLockedSection: some View {
        modelPanelSection(title: "some.im", systemImage: "lock") {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.AgentModelPicker.someIMConnectHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button {
                    openURL(URL(string: "https://some.im/customer/plan")!)
                } label: {
                    Label("查看 some.im 套餐", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .focusable(false)
            }
            .padding(12)
            .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.42))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var configuredProvidersSection: some View {
        modelPanelSection(title: "用户配置", systemImage: "person.crop.circle.badge.checkmark") {
            let entries = selectableProviderEntries
            if entries.isEmpty {
                Text("还没有可用的用户模型配置。请先到 Settings → Agent 添加服务商。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.42))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(entries) { entry in
                    providerModelCard(entry)
                }
            }
        }
    }

    @ViewBuilder
    private var catalogSection: some View {
        let models = combinedCatalogModels
        if !models.isEmpty {
            modelPanelSection(title: "更多模型", systemImage: "list.bullet") {
                ForEach(models, id: \.self) { model in
                    modelActionRow(
                        title: model,
                        subtitle: "来自最近使用 / 热门 / 新模型 / 已获取列表",
                        badge: nil,
                        systemImage: "circle.grid.2x2",
                        checked: appState.agentSessionModelOverride == model
                    ) {
                        appState.setAgentSessionModel(model)
                        closeModelPanel()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func providerModelCard(_ entry: AgentProviderEntry) -> some View {
        let isActive = menuSnapshot.activeProviderID == entry.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(entry.displayName)
                    .font(.system(size: 12, weight: .semibold))
                if isActive {
                    Text("当前服务商")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.teal)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.teal.opacity(0.12))
                        .clipShape(Capsule())
                }
                Spacer()
            }
            if !entry.flashPrimary.isEmpty, !SomeIMManagedModel.isRetired(entry.flashPrimary) {
                providerModelButton(entry: entry, model: entry.flashPrimary, label: "Flash")
            }
            if menuSnapshot.isSomeIMAuthenticated {
                ForEach(entry.flashAlternates, id: \.self) { model in
                    providerModelButton(entry: entry, model: model, label: "Flash")
                }
            }
            if !entry.proPrimary.isEmpty, !SomeIMManagedModel.isRetired(entry.proPrimary) {
                providerModelButton(entry: entry, model: entry.proPrimary, label: "Pro")
            }
            if menuSnapshot.isSomeIMAuthenticated {
                ForEach(entry.proAlternates, id: \.self) { model in
                    providerModelButton(entry: entry, model: model, label: "Pro")
                }
            }
        }
        .padding(12)
        .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func providerModelButton(entry: AgentProviderEntry, model: String, label: String) -> some View {
        modelActionRow(
            title: "\(label) · \(model)",
            subtitle: "选择后本次对话固定使用这个模型。",
            badge: label,
            systemImage: label == "Pro" ? "speedometer" : "bolt",
            checked: isCurrent(
                model: model,
                override: menuSnapshot.sessionOverride,
                isActive: menuSnapshot.activeProviderID == entry.id
            )
        ) {
            pick(entry: entry, model: model)
            closeModelPanel()
        }
    }

    @ViewBuilder
    private func modelMiniButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .focusable(false)
    }

    @ViewBuilder
    private func modelPanelSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AgentComposerChrome.iconPrimary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            content()
        }
    }

    @ViewBuilder
    private func modelActionRow(
        title: String,
        subtitle: String,
        badge: String?,
        systemImage: String,
        checked: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(checked ? AgentComposerChrome.iconPrimary : AgentComposerChrome.iconSecondary)
                    .frame(width: 24, height: 24)
                    .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.8))
                                .clipShape(Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if checked {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AgentComposerChrome.iconPrimary)
                }
            }
            .padding(10)
            .background(modelRowBackground(checked: checked))
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func modelRowBackground(checked: Bool) -> AnyShapeStyle {
        if checked {
            return AnyShapeStyle(.teal.opacity(0.13))
        }
        return AnyShapeStyle(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.42))
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var allCatalogItems: [AgentModelCatalogItem] {
        AgentModelPickerCatalog.items(
            entries: selectableProviderEntries,
            fetchedByProvider: fetchedModelsByProvider,
            freeModelIDs: freeModelIDs
        )
    }

    /// Models a provider's own price list reported at zero cost. Empty when no
    /// provider published one, which is also what hides the free group.
    private var freeModelIDs: Set<String> {
        Set(
            appState.agentDiscoveredModelMetadata
                .filter { $0.isFree == true }
                .map { $0.id.lowercased() }
        )
    }

    private var freeCatalogItems: [AgentModelCatalogItem] {
        AgentModelPickerCatalog.freeItems(allCatalogItems)
            .sorted { $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending }
    }

    private var searchResults: [AgentModelCatalogItem] {
        AgentModelPickerCatalog.search(allCatalogItems, query: normalizedSearchText)
            .sorted { lhs, rhs in
                if lhs.providerName == rhs.providerName {
                    return lhs.modelID.localizedCaseInsensitiveCompare(rhs.modelID) == .orderedAscending
                }
                return lhs.providerName.localizedCaseInsensitiveCompare(rhs.providerName) == .orderedAscending
            }
    }

    private var recentCatalogItems: [AgentModelCatalogItem] {
        var usedIDs = Set<String>()
        return menuSnapshot.recentlyUsedModels.compactMap { model in
            let matches = allCatalogItems.filter {
                $0.modelID.caseInsensitiveCompare(model) == .orderedSame
            }
            let preferred = matches.first(where: { $0.providerEntryID == menuSnapshot.activeProviderID })
                ?? matches.first
            guard let preferred, usedIDs.insert(preferred.id).inserted else { return nil }
            return preferred
        }
    }

    private var resolvedCodingRecommendations: [ResolvedCodingRecommendation] {
        Self.codingRecommendations.compactMap { recommendation in
            guard let entry = selectableProviderEntries.first(where: {
                $0.providerID == recommendation.providerID
            }) else { return nil }
            let item = AgentModelCatalogItem(
                providerEntryID: entry.id,
                providerID: entry.providerID,
                providerName: entry.displayName,
                modelID: recommendation.model,
                tier: recommendation.tier,
                isPrimaryFlashModel: false
            )
            return ResolvedCodingRecommendation(
                item: item,
                title: recommendation.title,
                note: recommendation.note,
                tags: recommendation.tags
            )
        }
    }

    private func catalogItems(for entry: AgentProviderEntry) -> [AgentModelCatalogItem] {
        allCatalogItems.filter { $0.providerEntryID == entry.id }
    }

    private func providerCatalogSubtitle(_ entry: AgentProviderEntry) -> String {
        if entry.id == AgentMagpieIntegration.providerEntryID { return L10n.MagpieIntegration.managed }
        return L10n.AgentModelPicker.modelCount(catalogItems(for: entry).count)
    }

    private func selectSource(_ source: AgentModelPickerSource) {
        selectedSource = source
        selectedTierFilter = .all
        switch source {
        case .managed:
            selectedModelSourceIsManaged = true
            selectedModelProviderID = selectableProviderEntries.first(where: {
                $0.providerID == AgentProviderPreset.someIMID
            })?.id
        case let .provider(entryID):
            selectedModelSourceIsManaged = false
            selectedModelProviderID = entryID
        case .allModels, .codingRecommended, .free, .recent:
            selectedModelSourceIsManaged = false
        }
    }

    private func toggleModelPanel() {
        if isModelPanelPresented {
            isModelPanelPresented = false
            return
        }
        prepareModelPanel()
        isModelPanelPresented = true
    }

    private func prepareModelPanel() {
        appState.reconcileSomeIMProviderFromSharedSession()
        appState.ensureActiveProviderIsUsableForChatSelection()
        refreshMenuSnapshot()
        searchText = ""
        selectedTierFilter = .all
        if menuSnapshot.managedActive, menuSnapshot.isSomeIMAuthenticated {
            selectSource(.managed)
        } else if let activeID = menuSnapshot.activeProviderID,
                  selectableProviderEntries.contains(where: { $0.id == activeID }) {
            selectSource(.provider(activeID))
        } else {
            selectSource(.allModels)
        }
        selectableProviderEntries.filter { $0.id != AgentMagpieIntegration.providerEntryID }.forEach { entry in
            refreshProviderCatalog(entry)
        }
        Task { @MainActor in
            await appState.refreshMagpieIntegration()
            guard isModelPanelPresented else { return }
            refreshMenuSnapshot()
            if let entry = appState.magpieProviderEntry { refreshProviderCatalog(entry, force: true) }
            discoverLocalGatewaysForPicker()
        }
    }

    private func discoverLocalGatewaysForPicker() {
        guard !isDiscoveringLocalGateways else { return }
        isDiscoveringLocalGateways = true
        localGatewayDiscoveryTask = Task { @MainActor in
            defer {
                isDiscoveringLocalGateways = false
                localGatewayDiscoveryTask = nil
            }
            let gateways = await AgentLocalModelGatewayDiscovery.discover()
            guard !Task.isCancelled, isModelPanelPresented else { return }
            for gateway in gateways {
                let normalizedURL = gateway.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                var existing = appState.effectiveAgentProviderLibrary.entries.first {
                    $0.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        .caseInsensitiveCompare(normalizedURL) == .orderedSame
                }
                if let existingID = existing?.id {
                    appState.materializeProviderLibraryEntryAPIKey(id: existingID)
                    existing = appState.effectiveAgentProviderLibrary.entries.first(where: { $0.id == existingID })
                }
                let entry: AgentProviderEntry
                if let existing {
                    entry = existing
                } else {
                    guard let discoveredEntry = gateway.providerEntry() else { continue }
                    entry = discoveredEntry
                    appState.upsertProviderLibraryEntry(discoveredEntry)
                }
                fetchedModelsByProvider[entry.id] = gateway.modelIDs
                providerLoadFailures.remove(entry.id)
            }
            refreshMenuSnapshot()
        }
    }

    private func refreshProviderCatalog(_ entry: AgentProviderEntry, force: Bool = false) {
        guard force || fetchedModelsByProvider[entry.id] == nil else { return }
        guard !loadingProviderIDs.contains(entry.id) else { return }
        loadingProviderIDs.insert(entry.id)
        providerLoadFailures.remove(entry.id)
        appState.materializeProviderLibraryEntryAPIKey(id: entry.id)
        Task { @MainActor in
            defer { loadingProviderIDs.remove(entry.id) }
            do {
                if entry.id == AgentMagpieIntegration.providerEntryID { await appState.refreshMagpieIntegration() }
                guard let resolvedEntry = appState.effectiveAgentProviderLibrary.entries.first(where: { $0.id == entry.id }) else {
                    throw appState.magpieIntegrationFailure ?? AgentMagpieIntegration.Failure(code: .disconnected)
                }
                // Discoveries, not bare ids: they carry each model's own
                // context window (the local id-matching table only guesses)
                // and the free marking the price list published.
                let found = try await AgentClient(configuration: resolvedEntry.makeConfiguration())
                    .fetchModelDiscoveries()
                fetchedModelsByProvider[entry.id] = found.map(\.id)
                if entry.id != AgentMagpieIntegration.providerEntryID {
                    appState.recordFetchedAgentModelDiscoveries(found)
                }
            } catch {
                fetchedModelsByProvider[entry.id] = []
                providerLoadFailures.insert(entry.id)
            }
        }
    }

    private func selectFirstSearchResult() {
        guard let first = searchResults.first else { return }
        selectCatalogItem(first)
    }

    private func selectCatalogItem(_ item: AgentModelCatalogItem) {
        guard let entry = selectableProviderEntries.first(where: {
            $0.id == item.providerEntryID
        }) else { return }
        pick(entry: entry, model: item.modelID)
        closeModelPanel()
    }




    private var managedRoutingPublisher: AnyPublisher<AgentManagedRoutingState?, Never> {
        guard let runtime = appState.activeRuntime else {
            return Just(nil).eraseToAnyPublisher()
        }
        return runtime.$managedRouting.eraseToAnyPublisher()
    }

    private func handleManagedRoutingChange(_ state: AgentManagedRoutingState?) {
        refreshMenuSnapshot()
    }

    private var pillLabel: String {
        AgentModelPickerPresentation.pillLabel(
            managedActive: isManagedRoutingActive,
            currentModelLabel: currentModelLabel,
            providerDisplayName: appState.effectiveAgentProviderLibrary.entries.count > 1
                ? appState.activeAgentProviderEntry?.displayName : nil,
            managedLabel: L10n.AgentModelPicker.managed,
            selectModelLabel: L10n.AgentModelPicker.selectModel
        )
    }

    /// The compact composer pill must read the active runtime directly.
    /// `menuSnapshot` is intentionally a stable copy for the open model panel,
    /// but using it for the always-visible pill could leave the old managed
    /// label on screen for one or more turns after an explicit model choice.
    /// The runtime already forwards changes through `AppState.objectWillChange`,
    /// so this value follows the actual request configuration.
    private var isManagedRoutingActive: Bool {
        appState.activeRuntime?.managedRouting != nil
    }

    private func isCatalogItemCurrent(_ item: AgentModelCatalogItem) -> Bool {
        guard menuSnapshot.activeProviderID == item.providerEntryID,
              !menuSnapshot.managedActive else { return false }
        if let override = menuSnapshot.sessionOverride, !override.isEmpty {
            return override.caseInsensitiveCompare(item.modelID) == .orderedSame
        }
        return menuSnapshot.configuredModel.caseInsensitiveCompare(item.modelID) == .orderedSame
    }

    private func tierFilterLabel(_ filter: AgentModelPickerTierFilter) -> String {
        switch filter {
        case .all: return L10n.AgentModelPicker.all
        case .flash: return L10n.AgentModelPicker.flash
        case .pro: return L10n.AgentModelPicker.pro
        }
    }

    private func modelDisplayTitle(_ model: String) -> String {
        Self.codingRecommendations.first(where: {
            $0.model.caseInsensitiveCompare(model) == .orderedSame
        })?.title ?? model
    }

    private func modelDescription(_ item: AgentModelCatalogItem) -> String {
        if let recommendation = Self.codingRecommendations.first(where: {
            $0.providerID == item.providerID
                && $0.model.caseInsensitiveCompare(item.modelID) == .orderedSame
        }) {
            return recommendation.note
        }
        return item.modelID
    }

    private func catalogTags(_ item: AgentModelCatalogItem) -> [String] {
        if item.providerID == AgentProviderPreset.ollamaID,
           item.isPrimaryFlashModel {
            return [L10n.AgentModelPicker.localLLM]
        }
        if let recommendation = Self.codingRecommendations.first(where: {
            $0.providerID == item.providerID
                && $0.model.caseInsensitiveCompare(item.modelID) == .orderedSame
        }) {
            return recommendation.tags
        }
        switch item.tier {
        case .some(.flash): return [L10n.AgentModelPicker.flash]
        case .some(.pro): return [L10n.AgentModelPicker.pro]
        case .some(.all), .none: return []
        }
    }

    private func modelIcon(_ item: AgentModelCatalogItem) -> String {
        if catalogTags(item).contains(L10n.AgentModelPicker.coding) {
            return "chevron.left.forwardslash.chevron.right"
        }
        switch item.tier {
        case .some(.flash): return "bolt"
        case .some(.pro): return "speedometer"
        case .some(.all), .none: return "circle.grid.2x2"
        }
    }

    private func chooseManagedRouting(tier: AgentManagedCapabilityTier) {
        appState.selectSomeIMManagedRouting()
        appState.resetManagedRoutingFloor()
        closeModelPanel()
    }

    private func chooseSomeIMModel(_ model: String) {
        if let entry = selectableProviderEntries.first(where: { $0.providerID == AgentProviderPreset.someIMID }) {
            appState.selectAgentEntryAndModel(entryID: entry.id, model: model)
        } else {
            appState.setAgentSessionModel(model)
        }
        closeModelPanel()
    }

    private func closeModelPanel() {
        localGatewayDiscoveryTask?.cancel()
        refreshMenuSnapshot()
        isModelPanelPresented = false
    }

    private var selectableProviderEntries: [AgentProviderEntry] {
        menuSnapshot.providerEntries.filter {
            $0.isUsableForChatSelection(isSomeIMAuthenticated: menuSnapshot.isSomeIMAuthenticated)
        }
    }

    private var combinedCatalogModels: [String] {
        var seen = Set<String>()
        return (
            menuSnapshot.recentlyUsedModels +
            menuSnapshot.hotModels +
            menuSnapshot.newModels +
            menuSnapshot.fetchedModels
        ).compactMap { raw -> String? in
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = model.lowercased()
            guard !model.isEmpty, seen.insert(key).inserted else { return nil }
            return model
        }
    }

    private static let recommendedSomeIMModels: [ModelRecommendation] = [
        ModelRecommendation(
            title: "DeepSeek V4 Flash",
            model: "deepseek-v4-flash",
            note: "通用任务快、稳、省。",
            badge: "通用",
            systemImage: "bolt.fill"
        ),
        ModelRecommendation(
            title: "DeepSeek V4 Pro",
            model: "deepseek-v4-pro",
            note: "更适合复杂一点的通用任务。",
            badge: "通用 Pro",
            systemImage: "speedometer"
        ),
        ModelRecommendation(
            title: "GLM",
            model: "glm",
            note: "中文和代码日常任务性价比好。",
            badge: "编码",
            systemImage: "chevron.left.forwardslash.chevron.right"
        ),
        ModelRecommendation(
            title: "GLM 5.1",
            model: "glm-5.1",
            note: "编码效果好，适合仓库内实现和修复。",
            badge: "编码",
            systemImage: "chevron.left.forwardslash.chevron.right"
        ),
        ModelRecommendation(
            title: "GLM 5.2",
            model: "glm-5.2",
            note: "更便宜，写码表现仍然不错。",
            badge: "便宜",
            systemImage: "dollarsign.circle"
        ),
        ModelRecommendation(
            title: "Grok 4.5",
            model: "grok-4.5",
            note: "推理接近 GPT-5.5 / Opus 4.8，但响应很快。",
            badge: "快推理",
            systemImage: "timer"
        )
    ]

    /// Flat-section layout for one library entry. The provider name
    /// becomes the Section header (rendered as a non-clickable group
    /// label in NSMenu) and every Flash/Pro model — primary first,
    /// then alternates — is a direct Button inside that section.
    /// A single click on a model row activates that provider entry
    /// and sets the session model in one shot. No nested Menus, so
    /// none of the SwiftUI hover-loses-focus weirdness.
    @ViewBuilder
    private func providerSection(
        entry: AgentProviderEntry,
        activeProviderID: UUID?,
        override: String?
    ) -> some View {
        let isActive = activeProviderID == entry.id

        Section(sectionHeader(for: entry, isActive: isActive)) {
            if !entry.flashPrimary.isEmpty, !SomeIMManagedModel.isRetired(entry.flashPrimary) {
                Button { pick(entry: entry, model: entry.flashPrimary) } label: {
                    modelRow(label: "Flash · \(entry.flashPrimary)",
                             checked: isCurrent(model: entry.flashPrimary, override: override, isActive: isActive))
                }
                .focusable(false)
            }
            ForEach(entry.flashAlternates, id: \.self) { m in
                Button { pick(entry: entry, model: m) } label: {
                    modelRow(label: "Flash · \(m)",
                             checked: isCurrent(model: m, override: override, isActive: isActive))
                }
                .focusable(false)
            }
            if !entry.proPrimary.isEmpty, !SomeIMManagedModel.isRetired(entry.proPrimary) {
                Button { pick(entry: entry, model: entry.proPrimary) } label: {
                    modelRow(label: "Pro · \(entry.proPrimary)",
                             checked: isCurrent(model: entry.proPrimary, override: override, isActive: isActive))
                }
                .focusable(false)
            }
            ForEach(entry.proAlternates, id: \.self) { m in
                Button { pick(entry: entry, model: m) } label: {
                    modelRow(label: "Pro · \(m)",
                             checked: isCurrent(model: m, override: override, isActive: isActive))
                }
                .focusable(false)
            }
        }
    }

    /// Header text for a provider section. NSMenu renders Section
    /// headers as small uppercase greyed labels — we keep them plain
    /// text and prefix the active provider with a star glyph so the
    /// user can still tell which library entry is in play.
    private func sectionHeader(for entry: AgentProviderEntry, isActive: Bool) -> String {
        isActive ? "★ \(entry.displayName)" : entry.displayName
    }

    @ViewBuilder
    private func modelRow(label: String, checked: Bool) -> some View {
        HStack {
            Text(label)
            if checked { Image(systemName: "checkmark") }
        }
    }


    /// Concrete model rows only check when the user explicitly picked that
    /// model. Route defaults and managed routing are separate menu states.
    private func isCurrent(model: String, override: String?, isActive: Bool) -> Bool {
        guard isActive else { return false }
        guard let override, !override.isEmpty else { return false }
        return override == model
    }

    private func pick(entry: AgentProviderEntry, model: String) {
        appState.selectAgentEntryAndModel(entryID: entry.id, model: model)
        refreshMenuSnapshot()
    }

    @ViewBuilder
    private func adHocModelButton(_ model: String) -> some View {
        Button {
            appState.setAgentSessionModel(model)
            refreshMenuSnapshot()
        } label: {
            HStack {
                Text(model)
                if appState.agentSessionModelOverride == model {
                    Image(systemName: "checkmark")
                }
            }
        }
        .focusable(false)
    }

    /// Set of every model id that lives somewhere in the library —
    /// used to filter ad-hoc model groups so we don't repeat them.
    private var libraryModelSet: Set<String> {
        var s = Set<String>()
        for e in appState.effectiveAgentProviderLibrary.entries {
            s.formUnion(e.allFlashModels)
            s.formUnion(e.allProModels)
        }
        return s
    }

    private func adHocModels(from ids: [String], excluding excluded: Set<String>) -> [String] {
        var seen = Set<String>()
        let excludedKeys = Set(excluded.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        return ids.compactMap { raw -> String? in
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = model.lowercased()
            guard !model.isEmpty,
                  !SomeIMManagedModel.isRetired(model),
                  !excludedKeys.contains(key),
                  isKnownModelRelevantToActiveProvider(model) else {
                return nil
            }
            guard seen.insert(key).inserted else { return nil }
            return model
        }
    }

    private func catalogModelIDs(where flag: (AgentModelDiscovery) -> Bool) -> [String] {
        appState.agentDiscoveredModelMetadata
            .filter(flag)
            .map(\.id)
    }

    private func isKnownModelRelevantToActiveProvider(_ model: String) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !SomeIMManagedModel.isRetired(trimmed) else { return false }
        guard let active = appState.activeAgentProviderEntry,
              let preset = AgentProviderPreset.preset(id: active.providerID),
              preset.id != AgentProviderPreset.customID else {
            return true
        }
        return preset.recognizesModelID(trimmed)
    }

    private func refreshMenuSnapshot() {
        let library = appState.effectiveAgentProviderLibrary
        let sessionProvider = appState.activeAgentProviderEntry
        let configured = appState.activeRuntime.map {
            appState.configurationForCurrentTurn(for: $0).model(for: .interactive)
        } ?? appState.agentConfiguration.normalized.model(for: .interactive)
        let libraryModels = libraryModelSet
        let used = adHocModels(from: appState.agentRecentlyUsedModelIDs, excluding: libraryModels)
        let hot = adHocModels(from: catalogModelIDs(where: \.isHot), excluding: libraryModels.union(used))
        let newModels = adHocModels(from: catalogModelIDs(where: \.isNew), excluding: libraryModels.union(used).union(hot))
        let fetched = adHocModels(
            from: appState.agentKnownModelIDs,
            excluding: libraryModels.union(used).union(hot).union(newModels)
        )
        menuSnapshot = ModelPickerMenuSnapshot(
            configuredModel: configured,
            providerEntries: library.entries,
            activeProviderID: sessionProvider?.id,
            sessionOverride: appState.agentSessionModelOverride,
            recentlyUsedModels: used,
            hotModels: hot,
            newModels: newModels,
            fetchedModels: fetched,
            currentModelLabel: currentModelLabel,
            isSomeIMActive: sessionProvider?.providerID == AgentProviderPreset.someIMID,
            isSomeIMAuthenticated: SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults(),
            managedActive: appState.activeRuntime?.managedRouting != nil,
            managedFloor: appState.activeRuntime?.managedRouting?.minimumTier
        )
    }

    /// Pill label — prefer the explicit session override, else fall
    /// back to the route's natural pick (prefixed with provider name
    /// when there's more than one library entry, so the user always
    /// knows which provider this chat is talking to).
    private var currentModelLabel: String {
        // Show this task's request model, without legacy session tier labels.
        if let managed = appState.activeRuntime?.managedRouting {
            let model = managed.currentTaskActualModel ?? managed.currentTaskModel.flatMap { SomeIMManagedModel.allowlist.contains($0) ? $0 : nil }
                ?? SomeIMManagedModel.autoFlash
            let core = "\(L10n.AgentManagedRouting.title) · \(model)"
            guard appState.effectiveAgentProviderLibrary.entries.count > 1,
                  let active = appState.activeAgentProviderEntry else {
                return core
            }
            return "\(active.displayName) · \(core)"
        }
        let routed = appState.activeRuntime.map {
            appState.configurationForCurrentTurn(for: $0).model(for: .interactive)
        } ?? appState.agentConfiguration.normalized.model(for: .interactive)
        let override = appState.agentSessionModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let model = override.flatMap { SomeIMManagedModel.isRetired($0) ? nil : $0 } ?? routed
        let authenticated = SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults()
        guard appState.activeAgentProviderEntry?.isUsableForChatSelection(
            isSomeIMAuthenticated: authenticated
        ) == true else {
            return ""
        }
        guard appState.effectiveAgentProviderLibrary.entries.count > 1,
              let active = appState.activeAgentProviderEntry else {
            return model
        }
        return "\(active.displayName) · \(model)"
    }

    private struct ModelPickerMenuSnapshot: Equatable {
        let configuredModel: String
        let providerEntries: [AgentProviderEntry]
        let activeProviderID: UUID?
        let sessionOverride: String?
        let recentlyUsedModels: [String]
        let hotModels: [String]
        let newModels: [String]
        let fetchedModels: [String]
        let currentModelLabel: String
        let isSomeIMActive: Bool
        let isSomeIMAuthenticated: Bool
        let managedActive: Bool
        let managedFloor: AgentManagedCapabilityTier?

        static let empty = ModelPickerMenuSnapshot(
            configuredModel: "",
            providerEntries: [],
            activeProviderID: nil,
            sessionOverride: nil,
            recentlyUsedModels: [],
            hotModels: [],
            newModels: [],
            fetchedModels: [],
            currentModelLabel: "",
            isSomeIMActive: false,
            isSomeIMAuthenticated: false,
            managedActive: false,
            managedFloor: nil
        )
    }

    struct CodingRecommendation: Identifiable {
        var id: String { "\(providerID)::\(model)" }
        let providerID: String
        let title: String
        let model: String
        let note: String
        let tags: [String]
        let tier: AgentModelPickerTierFilter?
    }

    private struct ResolvedCodingRecommendation: Identifiable {
        var id: String { item.id }
        let item: AgentModelCatalogItem
        let title: String
        let note: String
        let tags: [String]
    }

    static let codingRecommendations: [CodingRecommendation] = [
        // First place tracks `SomeIMIntegrationSettings.defaultTextModel`, and
        // a test enforces that so login defaults and picker ordering cannot
        // drift apart again.
        CodingRecommendation(
            providerID: AgentProviderPreset.someIMID,
            title: "some.im Auto Flash",
            model: SomeIMManagedModel.autoFlash,
            note: L10n.AgentModelPicker.dailyCodingNote,
            tags: [L10n.AgentModelPicker.coding, L10n.AgentModelPicker.fast],
            tier: .flash
        ),
        // Still recommended, no longer first: its reason to exist is the 1M
        // window, which is the exception rather than the daily driver.
        CodingRecommendation(
            providerID: AgentProviderPreset.someIMID,
            title: "DeepSeek V4 Flash",
            model: "deepseek-v4-flash",
            note: L10n.AgentModelPicker.fastCodingNote,
            tags: [L10n.AgentModelPicker.coding, L10n.AgentModelPicker.fast],
            tier: .flash
        ),
        CodingRecommendation(
            providerID: AgentProviderPreset.someIMID,
            title: "GPT-5.6 Sol",
            model: "gpt-5.6-sol",
            note: L10n.AgentModelPicker.complexCodingNote,
            tags: [L10n.AgentModelPicker.coding, L10n.AgentModelPicker.pro],
            tier: .pro
        ),
        CodingRecommendation(
            providerID: AgentProviderPreset.someIMID,
            title: "GPT-5.6 Luna",
            model: "gpt-5.6-luna",
            note: L10n.AgentModelPicker.repositoryCodingNote,
            tags: [L10n.AgentModelPicker.coding],
            tier: nil
        ),
        CodingRecommendation(
            providerID: AgentProviderPreset.someIMID,
            title: "GPT-5.6 Terra",
            model: "gpt-5.6-terra",
            note: L10n.AgentModelPicker.dailyCodingNote,
            tags: [L10n.AgentModelPicker.coding, L10n.AgentModelPicker.affordable],
            tier: nil
        ),
        CodingRecommendation(
            providerID: AgentProviderPreset.someIMID,
            title: "DeepSeek V4 Pro",
            model: "deepseek-v4-pro",
            note: L10n.AgentModelPicker.complexCodingNote,
            tags: [L10n.AgentModelPicker.coding, L10n.AgentModelPicker.pro],
            tier: .pro
        ),
        CodingRecommendation(
            providerID: AgentProviderPreset.someIMID,
            title: "GLM 5.1",
            model: "glm-5.1",
            note: L10n.AgentModelPicker.repositoryCodingNote,
            tags: [L10n.AgentModelPicker.coding],
            tier: nil
        ),
        CodingRecommendation(
            providerID: AgentProviderPreset.someIMID,
            title: "GLM 5.2",
            model: "glm-5.2",
            note: L10n.AgentModelPicker.dailyCodingNote,
            tags: [L10n.AgentModelPicker.coding, L10n.AgentModelPicker.affordable],
            tier: nil
        ),
        CodingRecommendation(
            providerID: AgentProviderPreset.someIMID,
            title: "Gemini 3.5 Flash",
            model: "gemini-3.5-flash",
            note: L10n.AgentModelPicker.fastCodingNote,
            tags: [L10n.AgentModelPicker.coding, L10n.AgentModelPicker.fast],
            tier: .flash
        ),
        CodingRecommendation(
            providerID: AgentProviderPreset.someIMID,
            title: "Gemini 3.8 Flash",
            model: "gemini-3.8-flash",
            note: L10n.AgentModelPicker.dailyCodingNote,
            tags: [L10n.AgentModelPicker.coding, L10n.AgentModelPicker.fast],
            tier: .flash
        )
    ]

    private struct ModelRecommendation: Identifiable, Equatable {
        var id: String { model }
        let title: String
        let model: String
        let note: String
        let badge: String
        let systemImage: String
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
