//
//  AgentModeComposerView.swift
//  VeilWriter
//
//  Composer, status bar, slash/at pickers, and compact session badges
//  used by the dedicated Agent mode surface. Split from AgentModeView
//  to keep the top-level view file reviewable.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Composer

struct AgentChatComposer: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ComposerCard()
                    .frame(maxWidth: AgentDesign.chatMaxContentWidth)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
    }
}

private struct ComposerCard: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var inputFocused: Bool
    @State private var slashMenuVisible: Bool = false
    @State private var slashMenuSelection: Int = 0
    @State private var atMenuVisible: Bool = false
    @State private var atMenuSelection: Int = 0
    @State private var atMenuQuery: String = ""
    /// Cached skill list — re-fetched whenever the @ popover opens so we
    /// pick up newly installed skills without recomputing on every
    /// keystroke.
    @State private var skillCatalog: [AgentSkillEntry] = []
    /// Strong ref to the coordinator so the @-token replacement helper
    /// can call back into it from SwiftUI callbacks.
    @State private var coordinatorRef = ComposerCoordinatorRef()

    private var filteredSlashCommands: [SlashCommand] {
        SlashCommand.filter(
            appState.agentInput,
            allCommands: SlashCommand.builtIn(state: appState)
        )
    }

    /// Unified entries for the `@` picker — skills + workspace shortcut
    /// + project files (from the already-cached Quick Open list, which
    /// honors the project file cache). All three are fuzzy-filtered by
    /// the same query and capped so a 10k-file repo doesn't carpet the
    /// popover.
    private var filteredAtEntries: [AtPickerEntry] {
        let q = atMenuQuery.lowercased()
        var entries: [AtPickerEntry] = []

        // Workspace shortcut — only shows when a folder is open, and
        // either the query is empty or matches "workspace".
        if appState.rootDirectory != nil,
           q.isEmpty || "workspace".contains(q) {
            entries.append(.workspace)
        }

        // Skills (cached once per popover open).
        let skills = q.isEmpty ? skillCatalog : skillCatalog.filter {
            $0.identifier.lowercased().contains(q)
                || $0.name.lowercased().contains(q)
                || $0.description.lowercased().contains(q)
        }
        entries.append(contentsOf: skills.map { .skill($0) })

        // Project files — limit to 30 matches so the popover stays
        // navigable. Match by last path component first, then full
        // relative path. Files already attached are filtered out so
        // the user can't double-add.
        let alreadyAttached = Set(appState.agentPendingFiles.map(\.url.standardizedFileURL.path))
        if let root = appState.rootDirectory?.standardizedFileURL.path {
            let files = appState.quickOpenFiles.lazy
                .filter { !alreadyAttached.contains($0.standardizedFileURL.path) }
                .filter { url in
                    if q.isEmpty { return true }
                    let name = url.lastPathComponent.lowercased()
                    if name.hasPrefix(q) || name.contains(q) { return true }
                    let rel = String(url.standardizedFileURL.path
                        .dropFirst(root.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        .lowercased()
                    return rel.contains(q)
                }
                .prefix(30)
                .map { url -> AtPickerEntry in
                    let rel = String(url.standardizedFileURL.path
                        .dropFirst(root.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    return .file(url: url, relativePath: rel.isEmpty ? url.lastPathComponent : rel)
                }
            entries.append(contentsOf: files)
        }

        return entries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !appState.agentPendingImages.isEmpty {
                AgentComposerImageStrip(images: appState.agentPendingImages) { id in
                    appState.removeAgentImage(id: id)
                }
            }

            if !appState.agentPendingSkills.isEmpty {
                AgentComposerSkillStrip(skills: appState.agentPendingSkills) { identifier in
                    appState.detachAgentSkill(identifier: identifier)
                }
            }

            if !appState.agentPendingFiles.isEmpty || appState.agentPendingIncludeWorkspaceOverview {
                AgentComposerAttachmentStrip(
                    includeWorkspace: appState.agentPendingIncludeWorkspaceOverview,
                    files: appState.agentPendingFiles,
                    onRemoveWorkspace: { appState.toggleAgentWorkspaceOverview() },
                    onRemoveFile: { appState.detachAgentFile(id: $0) }
                )
            }

            ZStack(alignment: .topLeading) {
                ComposerTextEditor(
                    text: $appState.agentInput,
                    onSubmit: { appState.sendAgentMessage() },
                    onPasteImage: handlePastedImage,
                    historyProvider: { appState.agentMessages
                        .filter { $0.role == .user }
                        .map(\.content)
                        .filter { !$0.isEmpty }
                    },
                    slashMenuVisible: $slashMenuVisible,
                    slashMenuSelection: $slashMenuSelection,
                    slashMenuItemCount: { filteredSlashCommands.count },
                    onSlashCommit: { runSelectedSlashCommand() },
                    atMenuVisible: $atMenuVisible,
                    atMenuSelection: $atMenuSelection,
                    atMenuItemCount: { filteredAtEntries.count },
                    onAtCommit: { commitSelectedAtEntry() },
                    onAtQueryChange: { handleAtQueryChange($0) },
                    coordinatorRef: coordinatorRef
                )
                .focused($inputFocused)
                .frame(minHeight: 26, maxHeight: 116)
                .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                    handleDroppedProviders(providers)
                    return true
                }

                if slashMenuVisible {
                    SlashCommandMenu(
                        commands: filteredSlashCommands,
                        selection: $slashMenuSelection,
                        onPick: { index in
                            slashMenuSelection = index
                            _ = runSelectedSlashCommand()
                        }
                    )
                    .offset(y: -8)
                    .transition(.opacity)
                }

                if atMenuVisible {
                    AtPickerMenu(
                        entries: filteredAtEntries,
                        selection: $atMenuSelection,
                        onPick: { index in
                            atMenuSelection = index
                            _ = commitSelectedAtEntry()
                        }
                    )
                    .offset(y: -8)
                    .transition(.opacity)
                }
            }

            HStack(spacing: 6) {
                AttachButton(action: attachImageFromPanel)
                WorkspacePickerPill()
                ModelPickerPill()
                AgentModePickerPill()
                Spacer(minLength: 0)
                if !appState.agentQueuedMessages.isEmpty {
                    QueueBadge()
                }
                SendStopButton()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AgentDesign.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AgentDesign.inputCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AgentDesign.inputCornerRadius)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onAppear { inputFocused = true }
    }

    /// Runs the currently-highlighted slash command. Returns true when a
    /// command was executed so the text view swallows the key, false to
    /// let the keystroke fall through (no match → treat as a normal Enter).
    @discardableResult
    private func runSelectedSlashCommand() -> Bool {
        let commands = filteredSlashCommands
        guard !commands.isEmpty else { return false }
        let safeIndex = min(max(0, slashMenuSelection), commands.count - 1)
        let command = commands[safeIndex]
        slashMenuVisible = false
        appState.agentInput = ""
        command.action()
        return true
    }

    private func handleAtQueryChange(_ query: String?) {
        if let q = query {
            // Refresh the catalog on transition from closed → open so a
            // newly installed skill shows up the next time `@` is typed.
            if !atMenuVisible || skillCatalog.isEmpty {
                skillCatalog = AgentSkillDirectory.list()
            }
            atMenuQuery = q
        } else {
            atMenuQuery = ""
        }
    }

    @discardableResult
    private func commitSelectedAtEntry() -> Bool {
        let entries = filteredAtEntries
        guard !entries.isEmpty else { return false }
        let safeIndex = min(max(0, atMenuSelection), entries.count - 1)
        let entry = entries[safeIndex]
        // Drop the @-token from the buffer. AppState side-effects then
        // surface as chips above the composer; the actual context
        // (SKILL.md body, file contents, workspace overview) is
        // spliced into the prompt by composeAttachedPrompt at send time.
        _ = coordinatorRef.coordinator?.replaceCurrentAtToken(with: "")
        switch entry {
        case .workspace:
            if !appState.agentPendingIncludeWorkspaceOverview {
                appState.toggleAgentWorkspaceOverview()
            }
        case .skill(let skill):
            appState.attachAgentSkill(skill)
        case .file(let url, _):
            appState.attachAgentFile(url: url)
        }
        atMenuVisible = false
        atMenuQuery = ""
        return true
    }

    private func handlePastedImage() {
        for (data, mime) in AgentImagePasteboardHelper.readImages(from: NSPasteboard.general) {
            ingest(data: data, mimeType: mime)
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage,
                          let png = Self.pngData(for: image) else { return }
                    DispatchQueue.main.async { ingest(data: png, mimeType: "image/png") }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          let raw = try? Data(contentsOf: url),
                          let mime = AgentImagePasteboardHelper.mimeType(forPath: url.path) else { return }
                    DispatchQueue.main.async { ingest(data: raw, mimeType: mime) }
                }
            }
        }
    }

    private func attachImageFromPanel() {
        let panel = NSOpenPanel()
        panel.title = "Attach Image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            for url in panel.urls {
                guard let data = try? Data(contentsOf: url),
                      let mime = AgentImagePasteboardHelper.mimeType(forPath: url.path) else { continue }
                ingest(data: data, mimeType: mime)
            }
        }

        // Prefer attaching the panel as a sheet on the current key
        // window. `panel.begin { }` without a parent has been observed
        // to freeze the app on macOS 26 + SwiftUI MainActor isolation
        // (it interacts badly with the run loop). The sheet form is
        // explicitly modeless on the rest of the app.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func ingest(data: Data, mimeType: String) {
        guard data.count <= 8 * 1024 * 1024 else { return }
        appState.addAgentImage(data: data, mimeType: mimeType)
    }

    private static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

private struct AttachButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus.circle")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Attach image")
    }
}

private struct SendStopButton: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button {
            if appState.isAgentResponding {
                appState.stopAgentResponse()
            } else {
                appState.sendAgentMessage()
            }
        } label: {
            ZStack {
                // Stopping state used to be a fully-saturated red
                // circle — visually shouted "danger" out of all
                // proportion to "click to interrupt streaming". Now
                // it's a soft red-tinted disc with a red stroke and a
                // red-foreground glyph: still unmistakably the stop
                // action, but no longer alarm-bell red.
                if appState.isAgentResponding {
                    Circle()
                        .fill(Color.red.opacity(0.12))
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle()
                                .stroke(Color.red.opacity(0.55), lineWidth: 1.2)
                        )
                    Image(systemName: "square.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.red.opacity(0.85))
                } else {
                    Circle()
                        .fill(canSend ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 26, height: 26)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!appState.isAgentResponding && !canSend)
        .help(appState.isAgentResponding ? "Stop" : "Send (↩)")
    }

    private var canSend: Bool {
        !appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !appState.agentPendingImages.isEmpty
    }
}

private struct QueueBadge: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Menu {
            Button("Clear Queue", role: .destructive) {
                appState.clearAgentQueue()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "hourglass")
                    .font(.system(size: 9))
                Text("\(appState.agentQueuedMessages.count) queued")
                    .font(AgentDesign.captionFont)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.12))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

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
private struct WorkspacePickerPill: View {
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

private struct ModelPickerPill: View {
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Status bar

struct AgentChatStatusBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 14) {
            if let branch = appState.gitStatus.branchName {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text(branch)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let root = appState.rootDirectory {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                    Text(root.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("No workspace")
            }

            if appState.agentSessionDidEditFiles && !appState.agentWorktreeChanges.isEmpty {
                AgentWorktreeSummaryPill()
            }

            Spacer(minLength: 0)

            CompressButton()
            ContextRingIndicator()
        }
        .font(AgentDesign.captionFont)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: AgentDesign.statusBarHeight)
        .background(AgentDesign.statusBarBackground)
        .overlay(Divider(), alignment: .top)
    }
}

/// Button to manually compress the conversation. Surfaces only when the
/// estimated context usage crosses 50% so light conversations don't see
/// it. Replaced with a spinner while a compression is in flight.
private struct CompressButton: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.isCompressingAgentContext {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Compressing…")
                }
            } else if shouldOffer {
                Button {
                    appState.compressAgentContext()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "rectangle.compress.vertical")
                            .font(.system(size: 9))
                        Text("Compress")
                    }
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Summarize older messages to free context budget")
                .disabled(appState.isAgentResponding)
            }
        }
    }

    private var usedFraction: Double {
        let window = max(1, appState.agentContextWindow)
        return min(1.0, Double(appState.estimatedAgentTokens) / Double(window))
    }

    private var shouldOffer: Bool {
        usedFraction > 0.5 && appState.agentMessages.count > 6
    }

    private var tint: Color {
        if usedFraction > 0.9 { return .red }
        if usedFraction > 0.75 { return .orange }
        return .accentColor
    }
}

private struct ContextRingIndicator: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                    .frame(width: 12, height: 12)
                Circle()
                    .trim(from: 0, to: usedFraction)
                    .stroke(barColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 12, height: 12)
            }
            Text("\(percent)%")
                .monospacedDigit()
        }
        .help("Context: ~\(formatTokens(used)) / \(formatTokens(window)). \(formatTokens(remaining)) remaining (estimate).")
    }

    private var window: Int { max(1, appState.agentContextWindow) }
    private var used: Int { appState.estimatedAgentTokens }
    private var usedFraction: CGFloat { min(1, max(0, CGFloat(used) / CGFloat(window))) }
    private var remaining: Int { max(0, window - used) }
    private var percent: Int { Int(usedFraction * 100) }

    private var barColor: Color {
        if usedFraction > 0.9 { return .red }
        if usedFraction > 0.75 { return .orange }
        return .accentColor
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return "\(count / 1_000)k" }
        return "\(count)"
    }
}

// MARK: - NSTextView-backed composer (Cmd+V image intercept, Return submit)

struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onPasteImage: () -> Void
    /// Returns the user's prior messages in chronological order. `↑` walks
    /// from the most recent backwards; `↓` walks forward and eventually
    /// restores the draft the user was typing before they started cycling.
    let historyProvider: () -> [String]
    /// Bound state for the "/" slash command palette. The composer card
    /// owns these so the menu can render in SwiftUI above the text view.
    @Binding var slashMenuVisible: Bool
    @Binding var slashMenuSelection: Int
    let slashMenuItemCount: () -> Int
    /// Called when the user presses Enter / Tab with the slash menu
    /// visible. Returning true tells the text view to swallow the key.
    let onSlashCommit: () -> Bool
    /// Same shape as the slash palette, used for the "@" skill picker.
    @Binding var atMenuVisible: Bool
    @Binding var atMenuSelection: Int
    let atMenuItemCount: () -> Int
    let onAtCommit: () -> Bool
    /// Notifies the composer card that the @ token in the buffer has
    /// changed (e.g. user kept typing letters after `@`), so the popover
    /// can re-filter its entries.
    let onAtQueryChange: (String?) -> Void
    /// Holder the parent passes in so it can hand the coordinator
    /// pointer back to SwiftUI menu callbacks (used by the @-token
    /// replacement helper). Filled in inside `makeCoordinator`.
    let coordinatorRef: ComposerCoordinatorRef

    func makeCoordinator() -> Coordinator {
        let coord = Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onPasteImage: onPasteImage,
            historyProvider: historyProvider,
            slashMenuVisible: $slashMenuVisible,
            slashMenuSelection: $slashMenuSelection,
            slashMenuItemCount: slashMenuItemCount,
            onSlashCommit: onSlashCommit,
            atMenuVisible: $atMenuVisible,
            atMenuSelection: $atMenuSelection,
            atMenuItemCount: atMenuItemCount,
            onAtCommit: onAtCommit,
            onAtQueryChange: onAtQueryChange
        )
        coordinatorRef.coordinator = coord
        return coord
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = ComposerNSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.string = text
        textView.drawsBackground = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            // Track programmatic text changes so the history cursor
            // doesn't think the user kept typing on top of a recalled
            // message — this also covers the slash-command path
            // emptying the buffer after running an action.
            context.coordinator.markTextReplacedExternally(to: text)
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        let onSubmit: () -> Void
        let onPasteImage: () -> Void
        let historyProvider: () -> [String]
        var slashMenuVisible: Binding<Bool>
        var slashMenuSelection: Binding<Int>
        let slashMenuItemCount: () -> Int
        let onSlashCommit: () -> Bool
        var atMenuVisible: Binding<Bool>
        var atMenuSelection: Binding<Int>
        let atMenuItemCount: () -> Int
        let onAtCommit: () -> Bool
        let onAtQueryChange: (String?) -> Void

        // History cursor state. `historyIndex` counts back from the most
        // recent user message: 0 = newest, 1 = next-newest, etc. nil
        // means "not cycling — the buffer holds the user's own draft".
        private var historyIndex: Int? = nil
        private var savedDraft: String = ""
        /// The exact string the composer last published from history, so
        /// we can tell whether the user has edited on top of it.
        private var lastHistoryString: String? = nil
        /// Tracks the active NSTextView so textDidChange handlers can
        /// inspect the live selection (NSTextStorage's didChange fires
        /// before selection updates, so we use the cached pointer rather
        /// than relying on the notification's object).
        fileprivate weak var activeTextView: NSTextView?

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onPasteImage: @escaping () -> Void,
            historyProvider: @escaping () -> [String],
            slashMenuVisible: Binding<Bool>,
            slashMenuSelection: Binding<Int>,
            slashMenuItemCount: @escaping () -> Int,
            onSlashCommit: @escaping () -> Bool,
            atMenuVisible: Binding<Bool>,
            atMenuSelection: Binding<Int>,
            atMenuItemCount: @escaping () -> Int,
            onAtCommit: @escaping () -> Bool,
            onAtQueryChange: @escaping (String?) -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onPasteImage = onPasteImage
            self.historyProvider = historyProvider
            self.slashMenuVisible = slashMenuVisible
            self.slashMenuSelection = slashMenuSelection
            self.slashMenuItemCount = slashMenuItemCount
            self.onSlashCommit = onSlashCommit
            self.atMenuVisible = atMenuVisible
            self.atMenuSelection = atMenuSelection
            self.atMenuItemCount = atMenuItemCount
            self.onAtCommit = onAtCommit
            self.onAtQueryChange = onAtQueryChange
        }

        func markTextReplacedExternally(to newValue: String) {
            // If something other than the user typed (slash action,
            // history binding push), reset our cursor so the next ↑
            // starts fresh.
            if newValue != lastHistoryString {
                historyIndex = nil
                lastHistoryString = nil
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            activeTextView = textView
            let newValue = textView.string
            text.wrappedValue = newValue
            // Any user edit invalidates the history cursor and re-derives
            // slash + @ visibility.
            if newValue != lastHistoryString {
                historyIndex = nil
                lastHistoryString = nil
            }
            updateSlashMenuVisibility(for: newValue)
            updateAtMenuVisibility(for: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            activeTextView = textView
            // Slash command palette takes priority over history + submit
            // while it's open.
            if slashMenuVisible.wrappedValue {
                switch commandSelector {
                case #selector(NSResponder.moveUp(_:)):
                    let count = slashMenuItemCount()
                    guard count > 0 else { return true }
                    slashMenuSelection.wrappedValue = (slashMenuSelection.wrappedValue - 1 + count) % count
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    let count = slashMenuItemCount()
                    guard count > 0 else { return true }
                    slashMenuSelection.wrappedValue = (slashMenuSelection.wrappedValue + 1) % count
                    return true
                case #selector(NSResponder.insertNewline(_:)),
                     #selector(NSResponder.insertTab(_:)):
                    return onSlashCommit()
                case #selector(NSResponder.cancelOperation(_:)):
                    slashMenuVisible.wrappedValue = false
                    return true
                default:
                    break
                }
            }

            // @ skill picker takes priority over submit while it's open,
            // but defers caret motion (↑/↓) ONLY when the menu actually
            // has items to step through — keeps multi-line composition
            // unaffected when there are no skill matches.
            if atMenuVisible.wrappedValue {
                switch commandSelector {
                case #selector(NSResponder.moveUp(_:)):
                    let count = atMenuItemCount()
                    guard count > 0 else { break }
                    atMenuSelection.wrappedValue = (atMenuSelection.wrappedValue - 1 + count) % count
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    let count = atMenuItemCount()
                    guard count > 0 else { break }
                    atMenuSelection.wrappedValue = (atMenuSelection.wrappedValue + 1) % count
                    return true
                case #selector(NSResponder.insertNewline(_:)),
                     #selector(NSResponder.insertTab(_:)):
                    if onAtCommit() { return true }
                case #selector(NSResponder.cancelOperation(_:)):
                    atMenuVisible.wrappedValue = false
                    return true
                default:
                    break
                }
            }

            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let wantsLineBreak = modifiers.contains(.shift)
                    || modifiers.contains(.option)
                    || modifiers.contains(.control)
                if !wantsLineBreak {
                    onSubmit()
                    historyIndex = nil
                    lastHistoryString = nil
                    return true
                }
            }

            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                if let recalled = stepHistory(direction: -1, currentText: textView.string) {
                    applyHistory(recalled, to: textView)
                    return true
                }
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                if let recalled = stepHistory(direction: +1, currentText: textView.string) {
                    applyHistory(recalled, to: textView)
                    return true
                }
            }
            return false
        }

        /// Returns the next/previous history entry (or the saved draft on
        /// the way back down) — or nil to let the text view's normal
        /// caret-movement command run.
        private func stepHistory(direction: Int, currentText: String) -> String? {
            let history = historyProvider()
            guard !history.isEmpty else { return nil }

            // Only intercept ↑/↓ when the buffer is empty OR currently
            // showing a recalled history entry. Anything else means the
            // user is editing prose and expects caret motion.
            let isOnHistory = historyIndex != nil && currentText == lastHistoryString
            let isEmpty = currentText.isEmpty
            guard isEmpty || isOnHistory else { return nil }

            if direction < 0 {
                // ↑ — walk further back. If we weren't cycling yet, save
                // whatever was in the buffer (probably empty) as the draft.
                if historyIndex == nil {
                    savedDraft = currentText
                    historyIndex = 0
                } else if let i = historyIndex, i + 1 < history.count {
                    historyIndex = i + 1
                } else {
                    return nil // already at oldest
                }
            } else {
                // ↓ — walk forward toward the draft.
                guard let i = historyIndex else { return nil }
                if i == 0 {
                    historyIndex = nil
                    return savedDraft
                }
                historyIndex = i - 1
            }
            guard let i = historyIndex else { return savedDraft }
            return history[history.count - 1 - i]
        }

        private func applyHistory(_ value: String, to textView: NSTextView) {
            textView.string = value
            text.wrappedValue = value
            lastHistoryString = value
            // Park the caret at end so the user can keep typing.
            let end = (value as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }

        private func updateSlashMenuVisibility(for newValue: String) {
            // Show the palette only when the buffer starts with "/" and
            // has no embedded newline yet. A trailing space ends the
            // command name and dismisses the menu.
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            let shouldShow = newValue.hasPrefix("/")
                && !newValue.contains("\n")
                && !trimmed.isEmpty
            if slashMenuVisible.wrappedValue != shouldShow {
                slashMenuVisible.wrappedValue = shouldShow
                if shouldShow {
                    slashMenuSelection.wrappedValue = 0
                }
            }
        }

        /// Looks at the caret position and decides whether the user is
        /// inside an `@token` (counting backwards from the caret to the
        /// nearest `@`, stopping at whitespace/newline/another `@`).
        /// Returns the substring after `@` so the popover can filter.
        fileprivate func currentAtQuery(in textView: NSTextView) -> String? {
            let nsString = textView.string as NSString
            let caret = textView.selectedRange().location
            guard caret > 0, caret <= nsString.length else { return nil }
            var i = caret - 1
            while i >= 0 {
                let ch = nsString.character(at: i)
                let scalar = UnicodeScalar(ch)
                if ch == 0x40 { // '@'
                    // Require that '@' sits at the start of the buffer
                    // or right after whitespace — avoids matching email
                    // addresses, file paths, etc.
                    if i == 0 {
                        return (nsString.substring(with: NSRange(location: i + 1, length: caret - i - 1)))
                    }
                    let prev = nsString.character(at: i - 1)
                    if let prevScalar = UnicodeScalar(prev),
                       CharacterSet.whitespacesAndNewlines.contains(prevScalar) {
                        return (nsString.substring(with: NSRange(location: i + 1, length: caret - i - 1)))
                    }
                    return nil
                }
                if let s = scalar, CharacterSet.whitespacesAndNewlines.contains(s) {
                    return nil
                }
                i -= 1
            }
            return nil
        }

        private func updateAtMenuVisibility(for textView: NSTextView) {
            let query = currentAtQuery(in: textView)
            onAtQueryChange(query)
            let shouldShow = query != nil
            if atMenuVisible.wrappedValue != shouldShow {
                atMenuVisible.wrappedValue = shouldShow
                if shouldShow {
                    atMenuSelection.wrappedValue = 0
                }
            }
        }

        /// Replace the in-progress `@token` at the caret with the chosen
        /// skill's identifier (kept around for transparency — actual
        /// skill content gets spliced in at send time) and dismiss the
        /// popover. Returns true if it edited the buffer.
        func replaceCurrentAtToken(with replacement: String) -> Bool {
            guard let textView = activeTextView else { return false }
            let nsString = textView.string as NSString
            let caret = textView.selectedRange().location
            guard caret > 0, caret <= nsString.length else { return false }
            var i = caret - 1
            while i >= 0 {
                let ch = nsString.character(at: i)
                if ch == 0x40 { break }
                if let s = UnicodeScalar(ch), CharacterSet.whitespacesAndNewlines.contains(s) { return false }
                i -= 1
            }
            guard i >= 0 else { return false }
            let replaceRange = NSRange(location: i, length: caret - i)
            let mutable = NSMutableString(string: textView.string)
            mutable.replaceCharacters(in: replaceRange, with: replacement)
            textView.string = mutable as String
            text.wrappedValue = mutable as String
            let newCaret = i + (replacement as NSString).length
            textView.setSelectedRange(NSRange(location: newCaret, length: 0))
            atMenuVisible.wrappedValue = false
            return true
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {}
}

fileprivate final class ComposerNSTextView: NSTextView {
    fileprivate weak var coordinator: ComposerTextEditor.Coordinator?

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        // Use the shared helper instead of probing `.png`/`.tiff`
        // directly — many sources (Notes, Sketch, Figma, web browser
        // drag-out, Cmd+Shift+Ctrl+4 screen capture) advertise images
        // under `public.image` or an NSImage archive, which the
        // narrow check missed. Result: paste only worked for a
        // handful of apps. The helper also peeks via
        // `NSImage.canInit(with:)` to catch every variant AppKit
        // knows how to decode.
        if AgentImagePasteboardHelper.pasteboardHasImage(pasteboard) {
            coordinator?.onPasteImage()
            if let plain = pasteboard.string(forType: .string), !plain.isEmpty {
                insertText(plain, replacementRange: selectedRange())
            }
            return
        }
        // Non-image paste: force plain-text. The composer is a chat
        // input, not a rich editor — bringing in foreign fonts /
        // backgrounds from the source app (browser, terminal, Notes)
        // makes the bubble look broken and the next-turn payload bloat
        // with attributes the model can't read anyway.
        if let plain = pasteboard.string(forType: .string), !plain.isEmpty {
            insertText(plain, replacementRange: selectedRange())
            return
        }
        pasteAsPlainText(sender)
    }
}

// MARK: - Slash commands

/// A single command shown in the "/" palette. Pure local actions — no
/// network, no LLM round-trip. Each one runs synchronously against
/// AppState. The model-picker case opens the existing model picker
/// surface; the others call public AppState APIs directly.
struct SlashCommand: Identifiable {
    let id: String          // canonical name without slash, used for filter
    let title: String       // e.g. "/new"
    let subtitle: String    // one-liner shown under the title
    let symbol: String      // SF Symbol name
    let action: () -> Void

    static func builtIn(state: AppState) -> [SlashCommand] {
        [
            SlashCommand(id: "new", title: "/new", subtitle: "Start a fresh chat in this workspace", symbol: "square.and.pencil") {
                state.startNewAgentSession()
            },
            SlashCommand(id: "clear", title: "/clear", subtitle: "Clear the current chat's messages", symbol: "eraser") {
                state.clearAgentConversation()
            },
            SlashCommand(id: "compress", title: "/compress", subtitle: "Summarize older turns to free context", symbol: "rectangle.compress.vertical") {
                state.compressAgentContext()
            },
            SlashCommand(id: "stop", title: "/stop", subtitle: "Stop the current model response", symbol: "stop.circle") {
                state.stopAgentResponse()
            },
            SlashCommand(id: "clear-queue", title: "/clear-queue", subtitle: "Drop any pending queued messages", symbol: "tray.2") {
                state.clearAgentQueue()
            },
            SlashCommand(id: "copy-last", title: "/copy-last", subtitle: "Copy the last assistant message", symbol: "doc.on.doc") {
                guard let last = state.agentMessages.last(where: { $0.role == .assistant }) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(last.content, forType: .string)
            },
        ]
    }

    /// Filters by fuzzy-ish prefix on the slash-stripped query. The text
    /// view passes `"/cl"` etc. — we strip the leading slash and match
    /// either the canonical id or the title prefix. Empty query (just
    /// `/`) lists everything.
    static func filter(_ rawInput: String, allCommands: [SlashCommand]) -> [SlashCommand] {
        let trimmed = rawInput.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return [] }
        let query = String(trimmed.dropFirst()).lowercased()
        guard !query.isEmpty else { return allCommands }
        return allCommands.filter { c in
            c.id.lowercased().contains(query) || c.title.lowercased().contains(query)
        }
    }
}

private struct SlashCommandMenu: View {
    let commands: [SlashCommand]
    @Binding var selection: Int
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if commands.isEmpty {
                Text("No matching commands")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                    SlashCommandRow(
                        command: command,
                        isSelected: index == selection
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onPick(index) }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
        .alignmentGuide(.top) { $0[.bottom] }   // sit above the input
        .fixedSize()
    }
}

private struct SlashCommandRow: View {
    let command: SlashCommand
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: command.symbol)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Text(command.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor : Color.clear)
    }
}

// MARK: - @ skill picker

/// Thin holder so the composer card can hand its coordinator reference
/// out to SwiftUI menu callbacks. NSViewRepresentable's `makeCoordinator`
/// is the canonical owner; we just need to surface a way to call
/// `replaceCurrentAtToken` from outside the text view's own delegate.
final class ComposerCoordinatorRef {
    weak var coordinator: ComposerTextEditor.Coordinator?
}

/// Chips of currently-attached skills, sitting above the text editor so
/// the user always sees what's about to ride along with the next send.
struct AgentComposerSkillStrip: View {
    let skills: [AgentSkillEntry]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(skills) { skill in
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                        Text("@\(skill.identifier)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                        Button {
                            onRemove(skill.identifier)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.10))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.accentColor.opacity(0.30), lineWidth: 1)
                    )
                    .help(skill.description)
                }
            }
        }
    }
}

/// Chips for non-skill attachments: workspace overview + per-file
/// references. Same removable pill design as the skill strip, but in a
/// distinct accent so users can tell at a glance which kind of context
/// is riding along this turn.
struct AgentComposerAttachmentStrip: View {
    let includeWorkspace: Bool
    let files: [AgentFileAttachment]
    let onRemoveWorkspace: () -> Void
    let onRemoveFile: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if includeWorkspace {
                    chip(
                        symbol: "folder",
                        label: "@workspace",
                        help: "Workspace root + file list will ride along",
                        onRemove: onRemoveWorkspace
                    )
                }
                ForEach(files) { file in
                    chip(
                        symbol: "doc.text",
                        label: "@\(file.relativePath)",
                        help: file.url.path,
                        onRemove: { onRemoveFile(file.id) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func chip(symbol: String, label: String, help: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(Color.purple)
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.purple.opacity(0.10))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.purple.opacity(0.30), lineWidth: 1)
        )
        .help(help)
    }
}

/// One row in the `@` popover. Skills, project files, and the special
/// `workspace` shortcut are unified so the user can fuzzy-match across
/// every attachable thing in one list.
enum AtPickerEntry: Identifiable, Equatable {
    case workspace
    case skill(AgentSkillEntry)
    case file(url: URL, relativePath: String)

    var id: String {
        switch self {
        case .workspace: return "@workspace"
        case .skill(let s): return "skill:\(s.identifier)"
        case .file(let url, _): return "file:\(url.standardizedFileURL.path)"
        }
    }

    var symbol: String {
        switch self {
        case .workspace: return "folder"
        case .skill: return "wand.and.stars"
        case .file: return "doc.text"
        }
    }

    var title: String {
        switch self {
        case .workspace: return "workspace"
        case .skill(let s): return s.identifier
        case .file(_, let rel): return rel
        }
    }

    var subtitle: String {
        switch self {
        case .workspace: return "Attach the current workspace root + file list"
        case .skill(let s): return s.description
        case .file(let url, _): return url.deletingLastPathComponent().lastPathComponent
        }
    }
}

private struct AtPickerMenu: View {
    let entries: [AtPickerEntry]
    @Binding var selection: Int
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                Text("No matching skills, files, or shortcuts")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    AtPickerRow(entry: entry, isSelected: index == selection)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(index) }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
        .fixedSize()
    }
}

private struct AtPickerRow: View {
    let entry: AtPickerEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.symbol)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor : Color.clear)
    }
}

// MARK: - Sidebar session mode badges

/// Tiny right-aligned indicators on each session row that summarise the
/// session's plan/goal progress at a glance. Plan badge shows
/// `done/total`; goal badge shows `done/total` of the checklist. Skipped
/// here for sessions in Normal mode or with empty plan/goal so we don't
/// add visual noise to ordinary chats.
struct AgentSessionModeBadges: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 4) {
            if let plan = session.currentPlan, !plan.steps.isEmpty {
                badge(
                    symbol: "list.number",
                    color: planBadgeColor(plan),
                    text: planProgress(plan),
                    help: planHelp(plan)
                )
            }
            if let goal = session.currentGoal, !goal.checklist.isEmpty {
                let doneCount = goal.checklist.filter(\.done).count
                badge(
                    symbol: "target",
                    color: doneCount == goal.checklist.count ? .green : .accentColor,
                    text: "\(doneCount)/\(goal.checklist.count)",
                    help: goal.statement.isEmpty ? "Goal progress" : goal.statement
                )
            }
        }
    }

    @ViewBuilder
    private func badge(symbol: String, color: Color, text: String, help: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
            Text(text)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule(style: .continuous))
        .help(help)
    }

    private func planProgress(_ plan: AgentPlan) -> String {
        let done = plan.steps.filter { $0.status == .done }.count
        return "\(done)/\(plan.steps.count)"
    }

    private func planBadgeColor(_ plan: AgentPlan) -> Color {
        switch plan.status {
        case .proposed, .rejected: return .orange
        case .approved, .executing: return .accentColor
        case .done: return .green
        }
    }

    private func planHelp(_ plan: AgentPlan) -> String {
        switch plan.status {
        case .proposed: return "Plan awaiting approval"
        case .approved: return "Plan approved, not started"
        case .executing: return "Plan executing"
        case .done: return "Plan complete"
        case .rejected: return "Plan rejected"
        }
    }
}

// MARK: - Mode picker (Normal / Plan / Goal)

private struct AgentModePickerPill: View {
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

