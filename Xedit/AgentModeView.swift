//
//  AgentModeView.swift
//  VeilWriter
//
//  Top-level Agent mode. Layout inspired by Cursor: a project-grouped
//  session sidebar on the left, a chat pane on the right, and a thin
//  status bar at the bottom of the chat pane.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AgentModeView: View {
    @EnvironmentObject var appState: AppState
    @State private var sidebarWidth: CGFloat = 230

    var body: some View {
        HStack(spacing: 0) {
            AgentSessionsSidebar()
                .frame(width: sidebarWidth)
                .background(
                    AgentDesign.sidebarBackground
                        .overlay(AgentDesign.sidebarTint)
                )

            Divider()

            VStack(spacing: 0) {
                AgentChatHeader()
                Divider().opacity(0.5)
                AgentChatTranscript()
                AgentChatComposer()
                AgentChatStatusBar()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AgentDesign.chatBackground)
        }
        .background(AgentDesign.chatBackground)
    }
}

// MARK: - Design tokens
//
// Centralized so the next time we want to tweak spacing/colors, it's all
// in one place. Uses macOS semantic colors so the look follows system
// appearance (light / dark) automatically.

enum AgentDesign {
    // Backgrounds — semantic so light/dark adapt for free. Earlier
    // revisions used `underPageBackgroundColor` for the sidebar and the
    // status bar; on light appearance that paints a fairly dark grey
    // band that fights with the white chat area. Now everything sits on
    // a single `windowBackgroundColor` plane, separated by dividers and
    // very light overlays so the eye reads it as one calm canvas.
    static let chatBackground = Color(nsColor: .windowBackgroundColor)
    static let sidebarBackground = Color(nsColor: .windowBackgroundColor)
    static let statusBarBackground = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let subtleBackground = Color(nsColor: .quaternaryLabelColor).opacity(0.18)
    /// Very faint tint to set the sidebar apart from the chat without
    /// the heavy grey of `underPageBackgroundColor`.
    static let sidebarTint = Color(nsColor: .labelColor).opacity(0.025)

    // Corner radii.
    static let cardCornerRadius: CGFloat = 8
    static let pillCornerRadius: CGFloat = 6
    static let inputCornerRadius: CGFloat = 10

    // Paddings & sizes.
    static let chatMaxContentWidth: CGFloat = 720
    static let messageVerticalSpacing: CGFloat = 18
    static let composerHeight: CGFloat = 124
    static let headerHeight: CGFloat = 42
    static let statusBarHeight: CGFloat = 26
    static let sidebarRowHeight: CGFloat = 26

    // Typography.
    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let bodyFont = Font.system(size: 13)
    static let secondaryFont = Font.system(size: 11)
    static let captionFont = Font.system(size: 10)
    static let sidebarSectionFont = Font.system(size: 11, weight: .semibold)
    static let sidebarRowFont = Font.system(size: 12)
}

// MARK: - Sessions sidebar

private struct AgentSessionsSidebar: View {
    @EnvironmentObject var appState: AppState
    @State private var expandedWorkspaces: Set<String> = []

    private let initialRowCount = 5

    /// Vertical room left at the top of the sidebar for the macOS
    /// traffic-light buttons. The window uses `titlebarAppearsTransparent`,
    /// so close/minimize/zoom float over the first ~28pt of sidebar
    /// content — anything we draw inside this band gets hidden behind
    /// the buttons.
    private let trafficLightReserve: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            // Spacer reserves space for the traffic lights; the "CHATS"
            // header drops to the row below them so it stays visible.
            Color.clear.frame(height: trafficLightReserve)
            sidebarHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    primaryActions
                    Spacer().frame(height: 18)
                    workspacesSection
                    if appState.agentSessions.isEmpty {
                        Text("Sessions you start will appear here.")
                            .font(AgentDesign.secondaryFont)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 16)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var sidebarHeader: some View {
        HStack {
            Text("Chats")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
    }

    private var primaryActions: some View {
        // Automations / Customize used to live here as dimmed
        // placeholders — they had no behavior and just took up real
        // estate, so they've been removed. Add them back when there's
        // a real feature to attach.
        VStack(spacing: 0) {
            SidebarActionRow(icon: "square.and.pencil", title: "New Chat", shortcut: "⌘N") {
                appState.startNewAgentSession()
            }
        }
    }

    private var workspacesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Workspaces")
                    .font(AgentDesign.sidebarSectionFont)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            ForEach(groupedSessions, id: \.0) { workspace, sessions in
                workspaceGroup(workspace: workspace, sessions: sessions)
            }
        }
    }

    @ViewBuilder
    private func workspaceGroup(workspace: String, sessions: [AgentSession]) -> some View {
        let isExpanded = expandedWorkspaces.contains(workspace)
        let visible = isExpanded ? sessions : Array(sessions.prefix(initialRowCount))

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(workspaceDisplayName(workspace))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)

            ForEach(visible) { session in
                sessionRow(session)
            }

            if sessions.count > initialRowCount {
                Button {
                    if isExpanded {
                        expandedWorkspaces.remove(workspace)
                    } else {
                        expandedWorkspaces.insert(workspace)
                    }
                } label: {
                    Text(isExpanded ? "Show less" : "See more")
                        .font(AgentDesign.secondaryFont)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 34)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }

            Spacer().frame(height: 10)
        }
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        let isActive = appState.activeAgentSessionID == session.id
        return Button {
            appState.selectAgentSession(id: session.id)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 5, height: 5)
                Text(session.title)
                    .font(AgentDesign.sidebarRowFont)
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .frame(height: AgentDesign.sidebarRowHeight)
            .contentShape(Rectangle())
            .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete Chat", role: .destructive) {
                appState.deleteAgentSession(id: session.id)
            }
        }
    }

    private var groupedSessions: [(String, [AgentSession])] {
        let groups = Dictionary(grouping: appState.agentSessions) { session in
            session.workspaceRootPath ?? "_no_workspace_"
        }
        return groups
            .map { ($0.key, $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { lhs, rhs in
                let l = lhs.1.first?.updatedAt ?? .distantPast
                let r = rhs.1.first?.updatedAt ?? .distantPast
                return l > r
            }
    }

    private func workspaceDisplayName(_ key: String) -> String {
        if key == "_no_workspace_" { return "No workspace" }
        return URL(fileURLWithPath: key).lastPathComponent
    }
}

private struct SidebarActionRow: View {
    let icon: String
    let title: String
    let shortcut: String?
    var isDimmed: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 14)
                    .foregroundStyle(isDimmed ? .tertiary : .secondary)
                Text(title)
                    .font(AgentDesign.sidebarRowFont)
                    .foregroundStyle(isDimmed ? .secondary : .primary)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(isHovered ? AgentDesign.subtleBackground : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(isDimmed)
    }
}

// MARK: - Header

private struct AgentChatHeader: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(AgentDesign.titleFont)
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                copyTitle()
            } label: {
                Image(systemName: "square.on.square")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy title")

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                Button {
                    appState.startNewAgentSession()
                } label: {
                    Image(systemName: "plus.bubble")
                }
                .buttonStyle(.plain)
                .help("New Chat")

                Button {
                    appState.setAppMode(.editor)
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .buttonStyle(.plain)
                .help("Switch to Editor Mode")
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .frame(height: AgentDesign.headerHeight)
    }

    private var title: String {
        guard let id = appState.activeAgentSessionID,
              let session = appState.agentSessions.first(where: { $0.id == id }) else {
            return "New Chat"
        }
        return session.title
    }

    private func copyTitle() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(title, forType: .string)
    }
}

// MARK: - Transcript

private struct AgentChatTranscript: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AgentDesign.messageVerticalSpacing) {
                    if appState.agentMessages.isEmpty {
                        AgentEmptyState()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    } else {
                        ForEach(visibleMessages) { message in
                            if shouldShowMessageBubble(message) {
                                AgentModeMessageView(message: message)
                                    .id(message.id)
                            }
                            let calls = toolCalls(for: message.id)
                            if !calls.isEmpty {
                                let segments = AgentToolCallGrouping.group(calls)
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(segments) { segment in
                                        AgentToolCallGroup(
                                            calls: segment.calls,
                                            headline: segment.kind.groupTitle(segment.count),
                                            headlineIcon: segment.kind.groupIcon
                                        )
                                    }
                                }
                                .id(toolGroupScrollID(for: message.id))
                                .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                            }
                        }
                    }

                    if appState.shouldShowAgentThinkingIndicator {
                        AgentThinkingDivider()
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth)
                    }

                    ForEach(appState.agentQueuedMessages) { queued in
                        QueuedMessageRow(message: queued)
                    }

                    if appState.isCompressingAgentContext {
                        AgentContextCompressionDivider()
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth)
                    }

                    if let error = appState.agentErrorMessage {
                        AgentErrorCard(message: error, details: appState.agentErrorDetails)
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                    }

                    ForEach(appState.agentPatchProposals) { proposal in
                        AgentPatchProposalCard(proposal: proposal)
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                    }

                    if !appState.agentWorktreeChanges.isEmpty {
                        AgentWorktreeChangeCard()
                            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: appState.agentMessages) { _, messages in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: appState.agentToolCalls.count) { _, _ in
                if let last = appState.agentToolCalls.last {
                    proxy.scrollTo(toolGroupScrollID(for: last.messageID), anchor: .bottom)
                }
            }
        }
    }

    private var visibleMessages: [AgentMessage] {
        appState.agentMessages.filter { message in
            message.role != .tool && !isEmptyThinkingPlaceholder(message)
        }
    }

    private func toolCalls(for messageID: AgentMessage.ID) -> [AgentToolCall] {
        appState.agentToolCalls.filter { $0.messageID == messageID }
    }

    private func isEmptyThinkingPlaceholder(_ message: AgentMessage) -> Bool {
        message.role == .assistant && message.content.isEmpty && message.toolCalls.isEmpty
    }

    private func shouldShowMessageBubble(_ message: AgentMessage) -> Bool {
        !(message.role == .assistant && message.content.isEmpty && !message.toolCalls.isEmpty)
    }

    private func toolGroupScrollID(for messageID: AgentMessage.ID) -> String {
        "agent-tools-\(messageID.uuidString)"
    }
}

// MARK: - Message bubbles for Agent mode

private struct AgentModeMessageView: View {
    let message: AgentMessage

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantContent
        case .system: assistantContent
        case .tool: EmptyView()
        }
    }

    private var userBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.content.isEmpty {
                Text(message.content)
                    .font(AgentDesign.bodyFont)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !message.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(message.images) { image in
                            AgentImageThumbnail(image: image, size: 96, allowsRemoval: false, onRemove: nil)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
        .background(AgentDesign.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AgentDesign.cardCornerRadius))
    }

    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.content.isEmpty {
                Text(message.content)
                    .font(AgentDesign.bodyFont)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
    }
}

// MARK: - Queued message

private struct QueuedMessageRow: View {
    let message: AgentQueuedMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hourglass")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Queued")
                    .font(AgentDesign.captionFont)
                    .foregroundStyle(.orange)
                    .textCase(.uppercase)
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(AgentDesign.bodyFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if !message.images.isEmpty {
                    Text("\(message.images.count) image\(message.images.count == 1 ? "" : "s")")
                        .font(AgentDesign.captionFont)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
        .background(Color.orange.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: AgentDesign.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AgentDesign.cardCornerRadius)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Empty state

private struct AgentEmptyState: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("How can I help today?")
                .font(.system(size: 16, weight: .medium))
            Text(subtitle)
                .font(AgentDesign.secondaryFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .foregroundStyle(.secondary)
    }

    private var subtitle: String {
        if appState.rootDirectory == nil {
            return "Open a folder from the menu to chat about a project."
        }
        return "Chatting about \(appState.rootDirectory?.lastPathComponent ?? ""). Paste images, switch models, queue follow-ups."
    }
}

// MARK: - Composer

private struct AgentChatComposer: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !appState.agentPendingImages.isEmpty {
                AgentComposerImageStrip(images: appState.agentPendingImages) { id in
                    appState.removeAgentImage(id: id)
                }
            }

            ComposerTextEditor(
                text: $appState.agentInput,
                onSubmit: { appState.sendAgentMessage() },
                onPasteImage: handlePastedImage
            )
            .focused($inputFocused)
            .frame(minHeight: 40, maxHeight: 130)
            .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                handleDroppedProviders(providers)
                return true
            }

            HStack(spacing: 6) {
                AttachButton(action: attachImageFromPanel)
                ModelPickerPill()
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
                Circle()
                    .fill(appState.isAgentResponding ? Color.red : (canSend ? Color.accentColor : Color.secondary.opacity(0.3)))
                    .frame(width: 26, height: 26)
                Image(systemName: appState.isAgentResponding ? "stop.fill" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
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

// MARK: - Model picker pill

private struct ModelPickerPill: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Menu {
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
            ForEach(appState.agentKnownModelIDs, id: \.self) { model in
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
            if appState.agentKnownModelIDs.isEmpty {
                Text("Fetch models in Settings > Agent")
            }
        } label: {
            HStack(spacing: 3) {
                Text(currentModel.isEmpty ? "Select model" : currentModel)
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
    }

    private var currentModel: String {
        appState.agentModelStatusText
    }
}

// MARK: - Status bar

private struct AgentChatStatusBar: View {
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

            if !appState.agentWorktreeChanges.isEmpty {
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

private struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onPasteImage: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onPasteImage: onPasteImage)
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
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        let onSubmit: () -> Void
        let onPasteImage: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void, onPasteImage: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
            self.onPasteImage = onPasteImage
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let wantsLineBreak = modifiers.contains(.shift)
                    || modifiers.contains(.option)
                    || modifiers.contains(.control)
                if !wantsLineBreak {
                    onSubmit()
                    return true
                }
            }
            return false
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {}
}

fileprivate final class ComposerNSTextView: NSTextView {
    fileprivate weak var coordinator: ComposerTextEditor.Coordinator?

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let hasImage = (pasteboard.pasteboardItems ?? []).contains { item in
            item.data(forType: .png) != nil
                || item.data(forType: .tiff) != nil
        }
        if hasImage {
            coordinator?.onPasteImage()
            if pasteboard.string(forType: .string) != nil {
                super.paste(sender)
            }
            return
        }
        super.paste(sender)
    }
}
