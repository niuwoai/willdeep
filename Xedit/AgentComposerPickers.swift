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
        .focusable(false)
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
        .focusable(false)
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
        .focusable(false)
        .fixedSize()
        .help(L10n.Expert.pickerHelp)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AgentExpertActivationList()
                .focusable(false)
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

            if shouldShowLockedNotice {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(L10n.Expert.lockedNotice)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
                )
                .accessibilityElement(children: .combine)
            }

            ForEach(AgentExpert.allCases) { expert in
                expertRow(expert)
            }
        }
    }

    private var shouldShowLockedNotice: Bool {
        !appState.agentActiveExperts.isEmpty && !appState.canDeactivateAgentExperts()
    }

    private func expertRow(_ expert: AgentExpert) -> some View {
        let isActive = appState.agentActiveExperts.contains(expert)
        let canDeactivate = appState.canDeactivateAgentExperts()
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
                    } else {
                        appState.deactivateAgentExpert(expert)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .focusable(false)
            .disabled(isActive && !canDeactivate)
        }
        .focusable(false)
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
            if isActive {
                appState.deactivateAgentExpert(expert)
            } else {
                appState.activateAgentExpert(expert)
            }
        }
        .focusable(false)
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
                            .focusable(false)
                        } else {
                            Menu(group.displayName) {
                                ForEach(group.skills.prefix(12)) { skill in
                                    Button {
                                        appState.attachAgentSkill(skill)
                                    } label: {
                                        pluginRow(name: skill.name, checked: isSkillAttached(skill))
                                    }
                                    .focusable(false)
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
                            .focusable(false)
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
        .focusable(false)
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
    @Environment(\.openURL) private var openURL
    @State private var menuSnapshot = ModelPickerMenuSnapshot.empty
    @State private var isModelPanelPresented = false
    @State private var selectedModelProviderID: UUID?
    @State private var selectedModelSourceIsManaged = false
    @State private var isRefreshingCodingPlan = false

    var body: some View {
        Button {
            refreshMenuSnapshot()
            selectedModelSourceIsManaged = appState.activeRuntime?.managedRouting != nil
                && SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults()
            selectedModelProviderID = appState.agentProviderLibrary.activeID
                ?? appState.agentProviderLibrary.entries.first?.id
            if !isModelPanelPresented,
               SomeIMIntegrationStore.hasAuthenticatedSessionForAutomaticDefaults() {
                refreshCodingPlanStatus()
            }
            isModelPanelPresented.toggle()
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
        .buttonStyle(.plain)
        .focusable(false)
        .fixedSize()
        .help("Pick provider + model for this chat. The active provider also drives Auto/Flash/Pro routing.")
        .popover(isPresented: $isModelPanelPresented, arrowEdge: .bottom) {
            modelSelectionPanel
                .frame(width: 680, height: 520)
        }
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

    @ViewBuilder
    private var modelSelectionPanel: some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 30, height: 30)
                    .background(palette.controlFill.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text("选择模型与托管方式")
                        .font(.system(size: 15, weight: .semibold))
                    Text(menuSnapshot.isSomeIMAuthenticated
                         ? "已连接 some.im，可使用省心托管、Coding Plan 和推荐模型。"
                         : "未连接 some.im，仅显示你自己配置的 Flash / Pro 模型。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    isModelPanelPresented = false
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
            .padding(.vertical, 14)

            Divider()

            HStack(alignment: .top, spacing: 0) {
                providerSelectionColumn
                    .frame(width: 214)
                    .padding(12)
                    .focusable(false)

                Divider()

                modelDetailColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .focusable(false)
            }
            .focusable(false)
        }
        .background(palette.panelFill.opacity(0.98))
        .focusable(false)
    }

    @ViewBuilder
    private var providerSelectionColumn: some View {
        let entries = selectableProviderEntries
        VStack(alignment: .leading, spacing: 8) {
            Text("Provider")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            if menuSnapshot.isSomeIMAuthenticated {
                providerSourceButton(
                    title: "省心托管",
                    subtitle: "some.im 自动路由",
                    systemImage: "wand.and.stars",
                    checked: selectedModelSourceIsManaged
                ) {
                    selectedModelSourceIsManaged = true
                    selectedModelProviderID = entries.first(where: { $0.providerID == AgentProviderPreset.someIMID })?.id
                }
            }

            ForEach(entries) { entry in
                providerSourceButton(
                    title: entry.displayName,
                    subtitle: providerSubtitle(entry),
                    systemImage: providerIcon(entry),
                    checked: !selectedModelSourceIsManaged && selectedProviderEntry?.id == entry.id
                ) {
                    selectedModelSourceIsManaged = false
                    selectedModelProviderID = entry.id
                }
            }

            if !menuSnapshot.isSomeIMAuthenticated {
                Divider()
                    .padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 8) {
                    Label("some.im 未连接", systemImage: "lock")
                        .font(.system(size: 11, weight: .semibold))
                    Text("连接后可使用省心托管、Coding Plan 和推荐模型。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Button {
                        openURL(URL(string: "https://some.im/customer/plan")!)
                    } label: {
                        Label("查看套餐", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .focusable(false)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.38))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Spacer(minLength: 0)
        }
        .focusable(false)
    }

    @ViewBuilder
    private var modelDetailColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if selectedModelSourceIsManaged, menuSnapshot.isSomeIMAuthenticated {
                    managedRoutingDetail
                } else if let entry = selectedProviderEntry {
                    providerModelDetail(entry)
                } else {
                    emptyProviderDetail
                }
            }
            .padding(16)
            .focusable(false)
        }
        .focusable(false)
    }

    @ViewBuilder
    private var managedRoutingDetail: some View {
        detailHeader(
            title: "省心托管",
            subtitle: "some.im 根据任务自动在通用、编码和高能力模型间路由。",
            systemImage: "wand.and.stars",
            checked: menuSnapshot.managedActive
        )

        modelPanelSection(title: "托管档位", systemImage: "slider.horizontal.3") {
            Button {
                chooseManagedRouting(tier: menuSnapshot.managedFloor ?? .low)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(LinearGradient(colors: [.teal, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
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
                            .foregroundStyle(.teal)
                    }
                }
                .padding(10)
                .background(modelRowBackground(checked: menuSnapshot.managedActive))
            }
            .buttonStyle(.plain)
            .focusable(false)

            HStack(spacing: 8) {
                managedTierChip(.low)
                managedTierChip(.high)
                managedTierChip(.premium)
            }
        }

        codingPlanSection
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
            codingPlanSection
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
                    .foregroundStyle(checked ? Color.teal : Color.secondary)
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
                        .foregroundStyle(.teal)
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
                .foregroundStyle(checked ? Color.teal : Color.secondary)
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
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(LinearGradient(colors: [.teal, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
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
                        Text("WillDeep 按任务自动在通用、编码和高能力模型间路由；需要绑定 some.im。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if menuSnapshot.managedActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.teal)
                    }
                }
                .padding(12)
                .background(modelRowBackground(checked: menuSnapshot.managedActive))
            }
            .buttonStyle(.plain)
            .focusable(false)

            HStack(spacing: 8) {
                managedTierChip(.low)
                managedTierChip(.high)
                managedTierChip(.premium)
            }
        }
    }

    @ViewBuilder
    private var codingPlanSection: some View {
        let status = appState.someIMCodingPlanStatus
        let isInitialRefresh = isRefreshingCodingPlan && status.checkedAt == .distantPast
        modelPanelSection(title: "Coding Plan 套餐", systemImage: "creditcard") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: status.isActiveNow ? "checkmark.seal.fill" : "bolt.badge.checkmark")
                        .foregroundStyle(status.isActiveNow ? Color.green : Color.teal)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        if status.isActiveNow {
                            HStack(spacing: 6) {
                                Text(status.planName ?? "Coding Plan")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("已订阅")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.green.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                            Text(codingPlanValidityText(status))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else if isInitialRefresh {
                            HStack(spacing: 7) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在查询 Coding Plan 套餐状态…")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            Text("查询完成后会显示套餐名称和有效期。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("订阅 Coding Plan 后，优先选择 someim-coding-plan-low / high。")
                                .font(.system(size: 12, weight: .medium))
                            Text("低档适合日常开发，高档适合复杂重构、多文件推理和疑难调试。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 8) {
                    modelMiniButton("Plan Low") { chooseSomeIMModel(SomeIMManagedModel.codingPlanLow) }
                    modelMiniButton("Plan High") { chooseSomeIMModel(SomeIMManagedModel.codingPlanHigh) }
                    Spacer()
                    if status.isActiveNow {
                        Button {
                            openURL(URL(string: "https://some.im/customer/plan")!)
                        } label: {
                            Label("管理套餐", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .focusable(false)
                    } else {
                        Button {
                            openURL(URL(string: "https://some.im/customer/plan")!)
                        } label: {
                            Label(isInitialRefresh ? "查看套餐" : "购买套餐", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .focusable(false)
                    }
                }
            }
            .padding(12)
            .background(status.isActiveNow
                ? Color.green.opacity(0.07)
                : appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.48))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func codingPlanValidityText(_ status: SomeIMCodingPlanStatus) -> String {
        guard let periodEnd = status.periodEnd else {
            return "套餐权益当前有效；省心托管会优先使用 Coding Plan 模型。"
        }
        return "有效期至 \(periodEnd.formatted(date: .abbreviated, time: .shortened))；省心托管会优先使用 Coding Plan 模型。"
    }

    private func refreshCodingPlanStatus() {
        guard !isRefreshingCodingPlan else { return }
        isRefreshingCodingPlan = true
        Task { @MainActor in
            _ = await appState.refreshedSomeIMCodingPlanStatusIfNeeded(force: true)
            isRefreshingCodingPlan = false
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
                Text("绑定 some.im 后可解锁省心托管、推荐模型列表和 Coding Plan。")
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
            if !entry.flashPrimary.isEmpty {
                providerModelButton(entry: entry, model: entry.flashPrimary, label: "Flash")
            }
            if menuSnapshot.isSomeIMAuthenticated {
                ForEach(entry.flashAlternates, id: \.self) { model in
                    providerModelButton(entry: entry, model: model, label: "Flash")
                }
            }
            if !entry.proPrimary.isEmpty {
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
    private func managedTierChip(_ tier: AgentManagedCapabilityTier) -> some View {
        Button {
            chooseManagedRouting(tier: tier)
        } label: {
            HStack(spacing: 5) {
                if menuSnapshot.managedActive, menuSnapshot.managedFloor == tier {
                    Image(systemName: "checkmark.circle.fill")
                }
                Text(managedTierLabel(tier))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(menuSnapshot.managedActive && menuSnapshot.managedFloor == tier ? Color.teal : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(modelRowBackground(checked: menuSnapshot.managedActive && menuSnapshot.managedFloor == tier))
        }
        .buttonStyle(.plain)
        .focusable(false)
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
                    .foregroundStyle(.teal)
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
                    .foregroundStyle(checked ? Color.teal : Color.secondary)
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
                        .foregroundStyle(.teal)
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

    private func chooseManagedRouting(tier: AgentManagedCapabilityTier) {
        appState.selectSomeIMManagedRouting()
        appState.setManagedRoutingFloor(tier)
        closeModelPanel()
    }

    private func chooseSomeIMModel(_ model: String) {
        if let entry = menuSnapshot.providerEntries.first(where: { $0.providerID == AgentProviderPreset.someIMID }) {
            appState.selectAgentEntryAndModel(entryID: entry.id, model: model)
        } else {
            appState.setAgentSessionModel(model)
        }
        closeModelPanel()
    }

    private func closeModelPanel() {
        refreshMenuSnapshot()
        isModelPanelPresented = false
    }

    private var selectableProviderEntries: [AgentProviderEntry] {
        if menuSnapshot.isSomeIMAuthenticated {
            return menuSnapshot.providerEntries
        }
        return menuSnapshot.providerEntries.filter { $0.providerID != AgentProviderPreset.someIMID }
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
            if !entry.flashPrimary.isEmpty {
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
            if !entry.proPrimary.isEmpty {
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

    @ViewBuilder
    private func managedTierButton(_ tier: AgentManagedCapabilityTier) -> some View {
        Button {
            appState.setManagedRoutingFloor(tier)
            refreshMenuSnapshot()
        } label: {
            modelRow(
                label: managedTierLabel(tier),
                checked: menuSnapshot.managedFloor == tier
            )
        }
        .focusable(false)
    }

    private func managedTierLabel(_ tier: AgentManagedCapabilityTier) -> String {
        switch tier {
        case .low: return L10n.AgentManagedRouting.tierFlash
        case .high: return L10n.AgentManagedRouting.tierPro
        case .premium: return L10n.AgentManagedRouting.tierPremium
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
            currentModelLabel: currentModelLabel,
            isSomeIMActive: library.active?.providerID == AgentProviderPreset.someIMID,
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
        // Managed routing has no single model — show the "省心托管" label with
        // the escalated tier suffix instead of a resolved model name.
        if let managed = appState.activeRuntime?.managedRouting {
            let core: String
            switch managed.minimumTier {
            case .low: core = L10n.AgentManagedRouting.titleFlash
            case .high: core = L10n.AgentManagedRouting.titleHigh
            case .premium: core = L10n.AgentManagedRouting.titlePremium
            }
            guard appState.agentProviderLibrary.entries.count > 1,
                  let active = appState.agentProviderLibrary.active else {
                return core
            }
            return "\(active.displayName) · \(core)"
        }
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
        .focusable(false)
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
        .focusable(false)
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
        .focusable(false)
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
                        .focusable(false)
                }
            }
            .padding(14)
            .frame(width: controls.contains(.experts) ? 340 : 300, alignment: .leading)
            .focusable(false)
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
                .focusable(false)
        }
        .focusable(false)
    }
}
