//
//  AgentComposerPickers.swift
//  VeilWriter
//
//  The three pill-shaped pickers in the composer row, split out of
//  AgentModeComposerView.swift in rc42:
//   - `WorkspacePickerPill`: folder dropdown — current-folder Finder /
//     copy-path / copy-branch + a deduped list of known workspaces +
//     a "Choose folder…" sentinel.
//   - `ModelPickerPill`: provider/model selector. Flat Section per
//     provider with Flash and Pro models as direct rows (nested Menus
//     on macOS dismiss on the slightest hover drift). Has a
//     "Recently fetched" tail menu for ad-hoc model IDs not in the
//     library entries.
//   - `AgentModePickerPill`: Normal / Plan / Goal selector with an
//     attached goal-editor sheet — Plan locks writes until approval,
//     Goal pins an objective to every reply.
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
                Image(systemName: "folder")
                    .font(.system(size: 10))
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
    }

    private var label: String {
        if let root = appState.rootDirectory {
            return root.lastPathComponent
        }
        return "Pick folder"
    }

    private var helpText: String {
        if let root = appState.rootDirectory {
            return root.path
        }
        return "Choose a workspace for this chat"
    }

    @ViewBuilder
    private var menuContent: some View {
        // Section 1 — the "current folder" affordances (only if one is set).
        if let root = appState.rootDirectory {
            Section(root.lastPathComponent) {
                Button {
                    appState.revealInFinder(root)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                Button {
                    appState.copyPath(root)
                } label: {
                    Label("Copy path", systemImage: "doc.on.doc")
                }
                if let branch = appState.gitStatus.branchName, !branch.isEmpty {
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(branch, forType: .string)
                    } label: {
                        Label("Copy branch name", systemImage: "arrow.triangle.branch")
                    }
                }
            }
            Divider()
        }

        // Section 2 — Switch to a known workspace. Dedupes against
        // the current root so the active folder doesn't double up.
        let knownRoots = sortedKnownWorkspaces()
        if !knownRoots.isEmpty {
            Section("Switch workspace") {
                ForEach(knownRoots, id: \.self) { url in
                    Button {
                        appState.openFolderURL(url)
                    } label: {
                        HStack {
                            Text(url.lastPathComponent)
                            if appState.rootDirectory?.standardizedFileURL == url.standardizedFileURL {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Divider()
        }

        // Section 3 — Always show the chooser sentinel last.
        Button {
            appState.openFolder()
        } label: {
            Label("Choose folder…", systemImage: "folder.badge.plus")
        }
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
            let extras = appState.agentKnownModelIDs.filter { !libraryModels.contains($0) && !$0.isEmpty }
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

// MARK: - Mode picker (Normal / Plan / Goal)

struct AgentModePickerPill: View {
    @EnvironmentObject var appState: AppState
    @State private var showingGoalEditor = false

    var body: some View {
        Menu {
            ForEach(AgentInteractionMode.allCases) { mode in
                Button {
                    if mode == .goal {
                        // Goal mode requires a definition; if there's
                        // already a goal we just flip the mode, otherwise
                        // open the editor sheet first.
                        appState.setAgentInteractionMode(.goal)
                        if appState.agentCurrentGoal == nil { showingGoalEditor = true }
                    } else {
                        appState.setAgentInteractionMode(mode)
                    }
                } label: {
                    Label(mode.displayName, systemImage: mode.symbol)
                }
            }
            if appState.agentInteractionMode == .goal {
                Divider()
                Button("Edit goal…") { showingGoalEditor = true }
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
        .sheet(isPresented: $showingGoalEditor) {
            AgentGoalEditorSheet { statement, items in
                appState.setAgentGoal(statement: statement, items: items)
                if appState.agentInteractionMode != .goal {
                    appState.setAgentInteractionMode(.goal)
                }
                showingGoalEditor = false
            } onCancel: {
                showingGoalEditor = false
            }
        }
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
