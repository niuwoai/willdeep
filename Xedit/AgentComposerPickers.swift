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
//     "Recently used", "Hot", "New", and "Recently fetched" tail
//     menus for ad-hoc model IDs not in the library entries.
//   - `AgentExecutionPickerPill`: WillDeep / Claude Code / Codex
//     execution backend selector for the next composer turn.
//   - `AgentModePickerPill`: Normal / Plan / Goal selector. Plan locks
//     writes until approval; Goal gathers the objective through chat
//     and pins it to every reply once defined.
//   - `AgentApprovalModePickerPill`: per-session tool approval posture
//     selector — request every time, smart approval, or workspace access.
//   - `AgentExpertPickerPill`: per-session opt-in specialist tool packs
//     with one-way activation switches.
//   - `AgentPluginPickerPill`: installed plugin/MCP capability browser.
//   - `ComposerAdaptiveControlStrip`: progressively exposes overflow
//     controls inline when the composer has room.
//
//  Previously `private struct` inside the composer file; now internal
//  so the composer card and any future host can mount them across
//  file boundaries. The `String.nilIfEmpty` helper ModelPickerPill
//  relies on tags along too.
//

import AppKit
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
                    .font(AgentDesign.secondaryFont)
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
        if let localPath = appState.activeRuntime?.workspaceLocation?.localPath {
            let root = URL(fileURLWithPath: localPath)
            return root.lastPathComponent.isEmpty ? localPath : root.lastPathComponent
        }
        return L10n.ComposerWorkspace.pickFolder
    }

    private var helpText: String {
        if let remote = activeRemoteWorkspace {
            return WorkspacePresentation.remoteHelp(runtime: remote.runtime, path: remote.path)
        }
        if let localPath = appState.activeRuntime?.workspaceLocation?.localPath {
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
                if let branch = appState.gitStatus.branchName, !branch.isEmpty {
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

        if appState.gitStatus.isRepository {
            Section(L10n.ComposerWorkspace.gitWorktrees) {
                Button {
                    appState.createAgentGitWorktreeFromActiveWorkspace()
                } label: {
                    Label(L10n.ComposerWorkspace.newWorktree, systemImage: "arrow.triangle.branch")
                }

                ForEach(appState.agentGitWorktrees) { worktree in
                    Button {
                        appState.moveActiveAgentSessionToWorkspace(at: worktree.path)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(worktree.displayName)
                                Text(worktree.branchLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if activeLocalPath == worktree.url.path {
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
        guard let path = appState.activeRuntime?.workspaceLocation?.localPath, !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private var activeRemovableWorktree: AgentGitWorktree? {
        guard let activeLocalWorkspacePath else { return nil }
        return appState.agentGitWorktrees.first { worktree in
            activeLocalWorkspacePath == worktree.url.path && !worktree.isPrimary && !worktree.isBare
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
        if let remote = activeRemoteWorkspace {
            return WorkspacePresentation.remoteTint(for: remote.runtime)
        }
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

// MARK: - Approval mode picker

struct AgentApprovalModePickerPill: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Menu {
            ForEach(AgentApprovalMode.allCases) { mode in
                Button {
                    appState.setAgentApprovalMode(mode)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: mode.symbol)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayName)
                            Text(mode.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if appState.agentApprovalMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appState.agentApprovalMode.symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(appState.agentApprovalMode.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(pillForeground)
            .background(Capsule(style: .continuous).fill(pillBackground))
            .overlay(Capsule(style: .continuous).stroke(pillBorder, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.ApprovalMode.pickerHelp)
    }

    private var pillForeground: Color {
        appState.agentApprovalMode == .workspaceAccess ? Color.white : Color.secondary
    }

    private var pillBackground: Color {
        switch appState.agentApprovalMode {
        case .requestEveryTime: return Color.secondary.opacity(0.10)
        case .smart: return Color.accentColor.opacity(0.14)
        case .workspaceAccess: return Color.accentColor
        }
    }

    private var pillBorder: Color {
        switch appState.agentApprovalMode {
        case .requestEveryTime: return Color.secondary.opacity(0.25)
        case .smart: return Color.accentColor.opacity(0.35)
        case .workspaceAccess: return Color.clear
        }
    }
}

// MARK: - Adaptive composer controls

enum ComposerOverflowControl: Hashable {
    case approval
    case executor
    case plugins
    case experts
}

struct ComposerAdaptiveControlStrip: View {
    // rc482 perf: 改为固定单套布局，去掉 ViewThatFits。原先用 ViewThatFits
    // 在三套布局变体间按窗口宽度挑一套显示，代价是**每次重渲染都要把每个
    // 变体整建一遍来测量**——composer pill 重建因此成为主线程热点（打字、
    // 窗口切换、焦点变化都中招，采样里占主线程大头）。现在常用的三个
    // （Workspace / Model / Mode）固定展示，其余（审批 / 执行器 / 插件 /
    // 专家）固定收进「更多 …」弹层。布局不再随宽度变化，每次重建只建一套。
    var body: some View {
        HStack(spacing: 6) {
            WorkspacePickerPill()
            ModelPickerPill()
            AgentModePickerPill()
            ComposerOverflowPill(controls: [.approval, .executor, .plugins, .experts])
        }
    }
}

// MARK: - Expert picker

struct AgentExpertPickerPill: View {
    @EnvironmentObject var appState: AppState
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(pillForeground)
            .background(Capsule(style: .continuous).fill(pillBackground))
            .overlay(Capsule(style: .continuous).stroke(pillBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(L10n.Expert.pickerHelp)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AgentExpertActivationList()
                .padding(14)
                .frame(width: 320, alignment: .leading)
                .environmentObject(appState)
        }
    }

    private var label: String {
        let count = appState.agentActiveExperts.count
        return count == 0 ? L10n.Expert.pickerLabel : L10n.Expert.pickerLabelActive("\(count)")
    }

    private var pillForeground: Color {
        appState.agentActiveExperts.isEmpty ? Color.secondary : Color.white
    }

    private var pillBackground: Color {
        appState.agentActiveExperts.isEmpty ? Color.secondary.opacity(0.10) : Color.accentColor
    }

    private var pillBorder: Color {
        appState.agentActiveExperts.isEmpty ? Color.secondary.opacity(0.25) : Color.clear
    }
}

struct AgentExpertActivationList: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Expert.pickerLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(AgentExpert.allCases) { expert in
                expertRow(expert)
            }
        }
    }

    private func expertRow(_ expert: AgentExpert) -> some View {
        let isActive = appState.agentActiveExperts.contains(expert)
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: expert.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(expert.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(expert.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            Toggle("", isOn: Binding(
                get: { isActive },
                set: { newValue in
                    if newValue {
                        appState.activateAgentExpert(expert)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(isActive)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            guard !isActive else { return }
            appState.activateAgentExpert(expert)
        }
    }
}

// MARK: - Plugin picker

struct AgentPluginPickerPill: View {
    @EnvironmentObject var appState: AppState
    @State private var pluginSkills: [AgentSkillEntry] = []
    @State private var mcpServers: [AgentMCPServerConfig] = []

    var body: some View {
        Menu {
            if pluginGroups.isEmpty && mcpServers.isEmpty {
                Text(L10n.PluginPicker.none)
            }

            if !pluginGroups.isEmpty {
                Section(L10n.PluginPicker.installedPlugins("\(pluginGroups.count)")) {
                    ForEach(pluginGroups, id: \.name) { group in
                        if group.skills.count == 1, let skill = group.skills.first {
                            Button {
                                appState.attachAgentSkill(skill)
                            } label: {
                                pluginRow(name: group.displayName, checked: isSkillAttached(skill))
                            }
                        } else {
                            Menu(group.displayName) {
                                ForEach(group.skills.prefix(12)) { skill in
                                    Button {
                                        appState.attachAgentSkill(skill)
                                    } label: {
                                        pluginRow(name: skill.name, checked: isSkillAttached(skill))
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if !mcpServers.isEmpty {
                Section(L10n.PluginPicker.mcpServers("\(mcpServers.count)")) {
                    ForEach(mcpServers.prefix(12)) { server in
                        Label(server.name, systemImage: serverIcon(server))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 10, weight: .semibold))
                Text(L10n.PluginPicker.label)
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(.secondary)
            .background(Capsule(style: .continuous).fill(Color.secondary.opacity(0.10)))
            .overlay(Capsule(style: .continuous).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.PluginPicker.help)
        .onAppear(perform: refresh)
    }

    private var pluginGroups: [PluginSkillGroup] {
        let grouped = Dictionary(grouping: pluginSkills.filter { $0.source == .plugin }) { skill in
            skill.identifier.split(separator: ":").first.map(String.init) ?? skill.identifier
        }
        return grouped.map { key, skills in
            PluginSkillGroup(name: key, skills: skills.sorted { $0.name < $1.name })
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    @ViewBuilder
    private func pluginRow(name: String, checked: Bool) -> some View {
        HStack {
            Label(name, systemImage: "puzzlepiece.extension")
            if checked {
                Image(systemName: "checkmark")
            }
        }
    }

    private func isSkillAttached(_ skill: AgentSkillEntry) -> Bool {
        appState.agentPendingSkills.contains { $0.identifier == skill.identifier }
    }

    private func serverIcon(_ server: AgentMCPServerConfig) -> String {
        switch server.source {
        case .cursor: return "cursorarrow.rays"
        case .codex: return "terminal"
        case .user: return "server.rack"
        }
    }

    private func refresh() {
        pluginSkills = AgentSkillDirectory.list(includeDisabled: false)
        mcpServers = AgentMCPServerDirectory.list(includeDisabled: false)
    }

    private struct PluginSkillGroup {
        let name: String
        let skills: [AgentSkillEntry]

        var displayName: String {
            switch name.lowercased() {
            case "browser": return "Browser"
            case "chrome": return "Chrome"
            case "gmail": return "Gmail"
            case "github": return "GitHub"
            default:
                return name
                    .split(separator: "-")
                    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    .joined(separator: " ")
            }
        }
    }
}

// MARK: - Model picker pill

struct ModelPickerPill: View {
    @EnvironmentObject var appState: AppState
    @State private var menuSnapshot = ModelPickerMenuSnapshot.empty

    var body: some View {
        Menu {
            // First entry: keep the "use the route's natural pick"
            // shortcut so the user can drop a session override.
            if !menuSnapshot.configuredModel.isEmpty {
                Button {
                    appState.recordRecentlyUsedAgentModel(menuSnapshot.configuredModel)
                    appState.setAgentSessionModel(nil)
                } label: {
                    HStack {
                        Text("Use route default: \(menuSnapshot.configuredModel)")
                        if menuSnapshot.sessionOverride == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Divider()
            }

            // Library entries — one Section per provider, models
            // listed flat under it. Previously this was a nested
            // Menu-in-Menu but SwiftUI's macOS implementation
            // dismisses the inner Menu on the slightest hover drift,
            // so the user would click a provider and only see a
            // brief flash. Sectioned flat layout sidesteps that
            // entirely; the provider name renders as a non-clickable
            // header above its model rows.
            ForEach(menuSnapshot.providerEntries) { entry in
                providerSection(
                    entry: entry,
                    activeProviderID: menuSnapshot.activeProviderID,
                    override: menuSnapshot.sessionOverride,
                    routed: menuSnapshot.configuredModel
                )
            }

            if menuSnapshot.providerEntries.isEmpty {
                Text("No providers configured. Open Settings → Agent.")
            }

            // Tail: ad-hoc models that don't belong to any library
            // entry's primary/alternates list. Recently used comes
            // first, then provider-supplied catalog highlights, then
            // older fetched-only ids.
            if !menuSnapshot.recentlyUsedModels.isEmpty ||
                !menuSnapshot.hotModels.isEmpty ||
                !menuSnapshot.newModels.isEmpty ||
                !menuSnapshot.fetchedModels.isEmpty {
                Divider()
            }
            if !menuSnapshot.recentlyUsedModels.isEmpty {
                Menu("Recently used") {
                    ForEach(menuSnapshot.recentlyUsedModels, id: \.self) { model in
                        adHocModelButton(model)
                    }
                }
            }
            if !menuSnapshot.hotModels.isEmpty {
                Menu("Hot") {
                    ForEach(menuSnapshot.hotModels, id: \.self) { model in
                        adHocModelButton(model)
                    }
                }
            }
            if !menuSnapshot.newModels.isEmpty {
                Menu("New") {
                    ForEach(menuSnapshot.newModels, id: \.self) { model in
                        adHocModelButton(model)
                    }
                }
            }
            if !menuSnapshot.fetchedModels.isEmpty {
                Menu("Recently fetched") {
                    ForEach(menuSnapshot.fetchedModels, id: \.self) { model in
                        adHocModelButton(model)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(menuSnapshot.currentModelLabel.isEmpty ? "Select model" : menuSnapshot.currentModelLabel)
                    .font(AgentDesign.secondaryFont)
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
        .fixedSize()
        .help("Pick provider + model for this chat. The active provider also drives Auto/Flash/Pro routing.")
        .onAppear(perform: refreshMenuSnapshot)
        .onReceive(appState.$agentProviderLibrary) { _ in
            refreshMenuSnapshot()
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
    }

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
        override: String?,
        routed: String
    ) -> some View {
        let isActive = activeProviderID == entry.id

        Section(sectionHeader(for: entry, isActive: isActive)) {
            if !entry.flashPrimary.isEmpty {
                Button { pick(entry: entry, model: entry.flashPrimary) } label: {
                    modelRow(label: "Flash · \(entry.flashPrimary)",
                             checked: isCurrent(model: entry.flashPrimary, override: override, isActive: isActive, routed: routed))
                }
            }
            ForEach(entry.flashAlternates, id: \.self) { m in
                Button { pick(entry: entry, model: m) } label: {
                    modelRow(label: "Flash · \(m)",
                             checked: isCurrent(model: m, override: override, isActive: isActive, routed: routed))
                }
            }
            if !entry.proPrimary.isEmpty {
                Button { pick(entry: entry, model: entry.proPrimary) } label: {
                    modelRow(label: "Pro · \(entry.proPrimary)",
                             checked: isCurrent(model: entry.proPrimary, override: override, isActive: isActive, routed: routed))
                }
            }
            ForEach(entry.proAlternates, id: \.self) { m in
                Button { pick(entry: entry, model: m) } label: {
                    modelRow(label: "Pro · \(m)",
                             checked: isCurrent(model: m, override: override, isActive: isActive, routed: routed))
                }
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

    /// Effective (entry, model) for the current chat is:
    ///   - the active library entry, AND
    ///   - the session override if set, otherwise the route's natural pick.
    private func isCurrent(model: String, override: String?, isActive: Bool, routed: String) -> Bool {
        guard isActive else { return false }
        if let override, !override.isEmpty {
            return override == model
        }
        return model == routed
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
    }

    /// Set of every model id that lives somewhere in the library —
    /// used to filter ad-hoc model groups so we don't repeat them.
    private var libraryModelSet: Set<String> {
        var s = Set<String>()
        for e in appState.agentProviderLibrary.entries {
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
        guard !trimmed.isEmpty else { return false }
        guard let active = appState.agentProviderLibrary.active,
              let preset = AgentProviderPreset.preset(id: active.providerID),
              preset.id != AgentProviderPreset.customID else {
            return true
        }
        return preset.recognizesModelID(trimmed)
    }

    private func refreshMenuSnapshot() {
        let library = appState.agentProviderLibrary
        let configured = appState.agentConfiguration.normalized.model(for: .interactive)
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
            activeProviderID: library.activeID,
            sessionOverride: appState.agentSessionModelOverride,
            recentlyUsedModels: used,
            hotModels: hot,
            newModels: newModels,
            fetchedModels: fetched,
            currentModelLabel: currentModelLabel
        )
    }

    /// Pill label — prefer the explicit session override, else fall
    /// back to the route's natural pick (prefixed with provider name
    /// when there's more than one library entry, so the user always
    /// knows which provider this chat is talking to).
    private var currentModelLabel: String {
        let routed = appState.agentConfiguration.normalized.model(for: .interactive)
        let model = appState.agentSessionModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? routed
        guard appState.agentProviderLibrary.entries.count > 1,
              let active = appState.agentProviderLibrary.active else {
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

        static let empty = ModelPickerMenuSnapshot(
            configuredModel: "",
            providerEntries: [],
            activeProviderID: nil,
            sessionOverride: nil,
            recentlyUsedModels: [],
            hotModels: [],
            newModels: [],
            fetchedModels: [],
            currentModelLabel: ""
        )
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Execution picker (WillDeep / external coding agents)

struct AgentExecutionPickerPill: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Menu {
            ForEach(AgentExecutionAgent.allCases) { agent in
                Button {
                    appState.setAgentExecutionAgent(agent)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: agent.symbol)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.displayName)
                            Text(agent.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if appState.agentExecutionAgent == agent {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appState.agentExecutionAgent.symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(appState.agentExecutionAgent.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(pillForeground)
            .background(Capsule(style: .continuous).fill(pillBackground))
            .overlay(Capsule(style: .continuous).stroke(pillBorder, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("选择这一轮由 WillDeep 自己执行，还是委托给本机 Claude Code / Codex CLI。")
    }

    private var pillForeground: Color {
        appState.agentExecutionAgent == .willDeep ? Color.secondary : Color.white
    }

    private var pillBackground: Color {
        switch appState.agentExecutionAgent {
        case .willDeep: return Color.secondary.opacity(0.10)
        case .claudeCode: return Color.purple
        case .codexCLI: return Color.accentColor
        }
    }

    private var pillBorder: Color {
        appState.agentExecutionAgent == .willDeep
            ? Color.secondary.opacity(0.25)
            : Color.clear
    }
}

// MARK: - Mode picker (Normal / Plan / Goal)

struct AgentModePickerPill: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Menu {
            ForEach(AgentInteractionMode.allCases) { mode in
                Button {
                    appState.setAgentInteractionMode(mode)
                } label: {
                    Label(mode.displayName, systemImage: mode.symbol)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appState.agentInteractionMode.symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(appState.agentInteractionMode.displayName)
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(pillForeground)
            .background(Capsule(style: .continuous).fill(pillBackground))
            .overlay(Capsule(style: .continuous).stroke(pillBorder, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Conversation mode — Plan locks writes until you approve; Goal pins an objective to every reply.")
    }

    private var pillForeground: Color {
        appState.agentInteractionMode == .normal ? Color.secondary : Color.white
    }

    private var pillBackground: Color {
        switch appState.agentInteractionMode {
        case .normal: return Color.secondary.opacity(0.10)
        case .plan: return Color.orange
        case .goal: return Color.accentColor
        }
    }

    private var pillBorder: Color {
        appState.agentInteractionMode == .normal ? Color.secondary.opacity(0.25) : Color.clear
    }
}

/// Overflow「⋯」for composer controls that do not currently fit inline.
/// `ComposerAdaptiveControlStrip` progressively moves executor, plugins,
/// and experts out of this popover as the composer gets wider.
struct ComposerOverflowPill: View {
    @EnvironmentObject var appState: AppState
    let controls: [ComposerOverflowControl]
    @State private var isPresented = false

    init(controls: [ComposerOverflowControl] = [.executor, .plugins, .experts]) {
        self.controls = controls
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: AgentDesign.pillCornerRadius))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(L10n.Composer.overflowHelp)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.Composer.overflowTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if controls.contains(.approval) {
                    overflowRow(L10n.Composer.overflowApproval) { AgentApprovalModePickerPill() }
                }
                if controls.contains(.executor) {
                    overflowRow(L10n.Composer.overflowExecutor) { AgentExecutionPickerPill() }
                }
                if controls.contains(.plugins) {
                    overflowRow(L10n.Composer.overflowPlugins) { AgentPluginPickerPill() }
                }
                if controls.contains(.experts) {
                    AgentExpertActivationList()
                }
            }
            .padding(14)
            .frame(width: controls.contains(.experts) ? 340 : 300, alignment: .leading)
            .environmentObject(appState)
        }
    }

    @ViewBuilder
    private func overflowRow<Pill: View>(
        _ title: String,
        @ViewBuilder pill: () -> Pill
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .frame(width: 64, alignment: .leading)
            Spacer(minLength: 0)
            pill()
        }
    }
}
