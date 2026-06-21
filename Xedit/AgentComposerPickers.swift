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
//     on macOS dismiss on the slightest hover drift). Has a
//     "Recently fetched" tail menu for ad-hoc model IDs not in the
//     library entries.
//   - `AgentExecutionPickerPill`: WillDeep / Claude Code / Codex
//     execution backend selector for the next composer turn.
//   - `AgentModePickerPill`: Normal / Plan / Goal selector. Plan locks
//     writes until approval; Goal gathers the objective through chat
//     and pins it to every reply once defined.
//   - `AgentApprovalModePickerPill`: per-session tool approval posture
//     selector — request every time, smart approval, or workspace access.
//   - `AgentPluginPickerPill`: installed plugin/MCP capability browser.
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
struct WorkspacePickerPill: View {
    @EnvironmentObject var appState: AppState

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
            .background(AgentDesign.subtleBackground)
            .clipShape(RoundedRectangle(cornerRadius: AgentDesign.pillCornerRadius))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(helpText)
        .onAppear {
            appState.refreshAgentGitWorktrees()
        }
        .onChange(of: appState.rootDirectory) { _, _ in
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
                            if isActiveWorktree(worktree) {
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
        let knownRoots = sortedKnownWorkspaces()
        if !knownRoots.isEmpty {
            Section(L10n.ComposerWorkspace.switchWorkspace) {
                ForEach(knownRoots, id: \.self) { url in
                    Button {
                        appState.moveActiveAgentSessionToWorkspace(at: url.standardizedFileURL.path)
                    } label: {
                        HStack {
                            Text(url.lastPathComponent)
                            if activeLocalWorkspaceURL?.standardizedFileURL == url.standardizedFileURL {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Divider()
        }

        let remoteRuntimes = AgentRuntimeStore.loadDescriptors()
            .filter { $0.transport == .ssh && !$0.defaultWorkspacePath.isEmpty }
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
        guard let path = appState.activeRuntime?.workspaceLocation?.localPath, !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private var activeRemovableWorktree: AgentGitWorktree? {
        appState.agentGitWorktrees.first { worktree in
            isActiveWorktree(worktree) && !worktree.isPrimary && !worktree.isBare
        }
    }

    private func isActiveWorktree(_ worktree: AgentGitWorktree) -> Bool {
        activeLocalWorkspaceURL?.path == worktree.url.path
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
        return (AgentRuntimeStore.descriptor(id: runtimeID), path)
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

    /// Union of (a) folder paths that appear as workspaceRootPath on
    /// any agent session, and (b) recentFolders. Both deduped to a
    /// canonical URL; sorted by lastPathComponent for menu stability.
    private func sortedKnownWorkspaces() -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        let sessionRoots: [URL] = appState.agentSessions
            .compactMap { session -> URL? in
                guard let path = session.workspaceRootPath, !path.isEmpty else { return nil }
                return URL(fileURLWithPath: path).standardizedFileURL
            }

        for url in sessionRoots + appState.recentFolders.map(\.standardizedFileURL) {
            let key = url.path
            if seen.insert(key).inserted {
                result.append(url)
            }
        }

        return result.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
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

    var body: some View {
        Menu {
            // First entry: keep the "use the route's natural pick"
            // shortcut so the user can drop a session override.
            let configured = appState.agentConfiguration.normalized.model(for: .interactive)
            if !configured.isEmpty {
                Button {
                    appState.setAgentSessionModel(nil)
                } label: {
                    HStack {
                        Text("Use route default: \(configured)")
                        if appState.agentSessionModelOverride == nil {
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
            ForEach(appState.agentProviderLibrary.entries) { entry in
                providerSection(entry: entry)
            }

            if appState.agentProviderLibrary.entries.isEmpty {
                Text("No providers configured. Open Settings → Agent.")
            }

            // Tail: previously fetched ad-hoc models that don't belong
            // to any library entry's primary/alternates list. Keeps the
            // old "fetch + pick" workflow working when the user grabs a
            // brand-new model id mid-conversation.
            let libraryModels = libraryModelSet
            let extras = appState.agentKnownModelIDs.filter {
                !libraryModels.contains($0) && isKnownModelRelevantToActiveProvider($0)
            }
            if !extras.isEmpty {
                Divider()
                Menu("Recently fetched") {
                    ForEach(extras, id: \.self) { model in
                        Button {
                            appState.setAgentSessionModel(model)
                        } label: {
                            HStack {
                                Text(model)
                                if appState.agentSessionModelOverride == model {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(currentModelLabel.isEmpty ? "Select model" : currentModelLabel)
                    .font(AgentDesign.secondaryFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AgentDesign.subtleBackground)
            .clipShape(RoundedRectangle(cornerRadius: AgentDesign.pillCornerRadius))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Pick provider + model for this chat. The active provider also drives Auto/Flash/Pro routing.")
    }

    /// Flat-section layout for one library entry. The provider name
    /// becomes the Section header (rendered as a non-clickable group
    /// label in NSMenu) and every Flash/Pro model — primary first,
    /// then alternates — is a direct Button inside that section.
    /// A single click on a model row activates that provider entry
    /// and sets the session model in one shot. No nested Menus, so
    /// none of the SwiftUI hover-loses-focus weirdness.
    @ViewBuilder
    private func providerSection(entry: AgentProviderEntry) -> some View {
        let isActive = appState.agentProviderLibrary.activeID == entry.id
        let override = appState.agentSessionModelOverride

        Section(sectionHeader(for: entry, isActive: isActive)) {
            if !entry.flashPrimary.isEmpty {
                Button { pick(entry: entry, model: entry.flashPrimary) } label: {
                    modelRow(label: "Flash · \(entry.flashPrimary)",
                             checked: isCurrent(entry: entry, model: entry.flashPrimary, override: override, isActive: isActive))
                }
            }
            ForEach(entry.flashAlternates, id: \.self) { m in
                Button { pick(entry: entry, model: m) } label: {
                    modelRow(label: "Flash · \(m)",
                             checked: isCurrent(entry: entry, model: m, override: override, isActive: isActive))
                }
            }
            if !entry.proPrimary.isEmpty {
                Button { pick(entry: entry, model: entry.proPrimary) } label: {
                    modelRow(label: "Pro · \(entry.proPrimary)",
                             checked: isCurrent(entry: entry, model: entry.proPrimary, override: override, isActive: isActive))
                }
            }
            ForEach(entry.proAlternates, id: \.self) { m in
                Button { pick(entry: entry, model: m) } label: {
                    modelRow(label: "Pro · \(m)",
                             checked: isCurrent(entry: entry, model: m, override: override, isActive: isActive))
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
    private func isCurrent(entry: AgentProviderEntry, model: String, override: String?, isActive: Bool) -> Bool {
        guard isActive else { return false }
        if let override, !override.isEmpty {
            return override == model
        }
        // No override → matches whichever primary the route would pick.
        let routed = appState.agentConfiguration.normalized.model(for: .interactive)
        return model == routed
    }

    private func pick(entry: AgentProviderEntry, model: String) {
        appState.selectAgentEntryAndModel(entryID: entry.id, model: model)
    }

    /// Set of every model id that lives somewhere in the library —
    /// used to filter "Recently fetched" so we don't repeat them.
    private var libraryModelSet: Set<String> {
        var s = Set<String>()
        for e in appState.agentProviderLibrary.entries {
            s.formUnion(e.allFlashModels)
            s.formUnion(e.allProModels)
        }
        return s
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
