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
            VStack(spacing: 6) {
                if !appState.agentWorktreeChanges.isEmpty {
                    AgentComposerWorktreeSummaryBar()
                        .frame(maxWidth: AgentDesign.chatMaxContentWidth)
                }

                ComposerCard()
                    .frame(maxWidth: AgentDesign.chatMaxContentWidth)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
        .onAppear {
            appState.refreshActiveAgentWorktreeChanges()
        }
        .onChange(of: appState.activeAgentSessionID) { _, _ in
            appState.refreshActiveAgentWorktreeChanges()
        }
        .sheet(item: $appState.agentWorktreeDiffPreview) { preview in
            AgentWorktreeDiffPreviewSheet(preview: preview)
        }
    }
}

private struct AgentComposerWorktreeSummaryBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 6) {
            Text("\(appState.agentWorktreeChanges.fileCount) 个文件已更改")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text("+\(appState.agentWorktreeChanges.totalAddedLines)")
                .foregroundStyle(.green)
            Text("-\(appState.agentWorktreeChanges.totalDeletedLines)")
                .foregroundStyle(.red)

            Spacer(minLength: 8)

            Button {
                appState.showAgentWorktreeDiff()
            } label: {
                Text("审查")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .help("查看当前未提交 diff")
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .padding(.horizontal, 12)
        .frame(height: 24)
    }
}

struct AgentWorktreeDiffPreviewSheet: View {
    let preview: AgentWorktreeDiffPreview
    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(preview.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                Button {
                    copyDiff()
                } label: {
                    Label(didCopy ? "已复制" : "复制", systemImage: didCopy ? "checkmark" : "square.on.square")
                }
                .buttonStyle(.borderless)

                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider()

            ScrollView([.vertical, .horizontal]) {
                Text(preview.diff)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private func copyDiff() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(preview.diff, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            didCopy = false
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

