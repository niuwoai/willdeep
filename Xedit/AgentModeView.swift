//
//  AgentModeView.swift
//  VeilWriter
//
//  Top-level Agent mode: a project-grouped session sidebar on the left
//  and a chat pane on the right. The chat pane reuses the message bubble,
//  tool-call card, and patch proposal card from AgentPanelView so the
//  panel form and the mode form stay visually consistent.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AgentModeView: View {
    @EnvironmentObject var appState: AppState
    @State private var sidebarWidth: CGFloat = 240

    private let minSidebarWidth: CGFloat = 200
    private let maxSidebarWidth: CGFloat = 380

    var body: some View {
        HStack(spacing: 0) {
            AgentSessionsSidebar()
                .frame(width: sidebarWidth)
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            AgentChatPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

// MARK: - Sessions sidebar

private struct AgentSessionsSidebar: View {
    @EnvironmentObject var appState: AppState
    @State private var collapsedWorkspaces: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groupedSessions, id: \.0) { workspace, sessions in
                        sectionHeader(for: workspace, count: sessions.count)
                        if !collapsedWorkspaces.contains(workspace) {
                            ForEach(sessions) { session in
                                sessionRow(session)
                            }
                        }
                    }
                    if appState.agentSessions.isEmpty {
                        Text("No chats yet. Start one with New Chat.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Chats")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Button {
                appState.startNewAgentSession()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("New Chat")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private func sectionHeader(for workspace: String, count: Int) -> some View {
        Button {
            if collapsedWorkspaces.contains(workspace) {
                collapsedWorkspaces.remove(workspace)
            } else {
                collapsedWorkspaces.insert(workspace)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: collapsedWorkspaces.contains(workspace) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                Text(workspaceDisplayName(workspace))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        let isActive = appState.activeAgentSessionID == session.id
        return Button {
            appState.selectAgentSession(id: session.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(relativeTime(session.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
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
                let lhsMostRecent = lhs.1.first?.updatedAt ?? .distantPast
                let rhsMostRecent = rhs.1.first?.updatedAt ?? .distantPast
                return lhsMostRecent > rhsMostRecent
            }
    }

    private func workspaceDisplayName(_ key: String) -> String {
        if key == "_no_workspace_" { return "No workspace" }
        return URL(fileURLWithPath: key).lastPathComponent
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Chat pane

private struct AgentChatPane: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(currentSessionTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(workspaceLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            ModelPicker()
                .frame(minWidth: 200, maxWidth: 280)

            ContextProgress()
                .frame(width: 130)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if appState.agentMessages.isEmpty {
                        AgentModeEmptyState()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 56)
                    } else {
                        ForEach(visibleMessages) { message in
                            AgentMessageBubble(message: message)
                                .id(message.id)
                            ForEach(toolCalls(for: message.id)) { call in
                                AgentToolCallCard(call: call)
                                    .id(call.id)
                            }
                        }
                    }

                    ForEach(appState.agentQueuedMessages) { queued in
                        QueuedMessageBubble(message: queued)
                    }

                    if let error = appState.agentErrorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    ForEach(appState.agentPatchProposals) { proposal in
                        AgentPatchProposalCard(proposal: proposal)
                    }
                }
                .padding(14)
            }
            .onChange(of: appState.agentMessages) { _, messages in
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: appState.agentToolCalls.count) { _, _ in
                if let last = appState.agentToolCalls.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !appState.agentPendingImages.isEmpty {
                AgentComposerImageStrip(images: appState.agentPendingImages) { id in
                    appState.removeAgentImage(id: id)
                }
            }

            HStack(alignment: .top, spacing: 8) {
                ComposerTextEditor(
                    text: $appState.agentInput,
                    onSubmit: { appState.sendAgentMessage() },
                    onPasteImage: handlePastedImage
                )
                .focused($inputFocused)
                .frame(minHeight: 70, maxHeight: 140)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                    handleDroppedProviders(providers)
                    return true
                }

                VStack(spacing: 6) {
                    Button {
                        attachImageFromPanel()
                    } label: {
                        Image(systemName: "photo.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Attach Image")

                    if appState.isAgentResponding {
                        Button {
                            appState.stopAgentResponse()
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("Stop")
                    } else {
                        Button {
                            appState.sendAgentMessage()
                        } label: {
                            Image(systemName: "paperplane.fill")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!hasSomethingToSend)
                        .help("Send")
                    }
                }
            }

            HStack(spacing: 6) {
                if appState.agentQueuedMessages.isEmpty {
                    Text(composerHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(appState.agentQueuedMessages.count) queued")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Button("Clear Queue") {
                        appState.clearAgentQueue()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                }
                Spacer(minLength: 0)
                if appState.isAgentResponding {
                    ProgressView()
                        .controlSize(.small)
                    Text("Sending…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .onAppear { inputFocused = true }
    }

    private var hasSomethingToSend: Bool {
        !appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !appState.agentPendingImages.isEmpty
    }

    private var composerHint: String {
        if appState.rootDirectory == nil {
            return "Open a folder from the menu to enable workspace tools."
        }
        return "Cmd+Return to send · Paste or drop to attach images"
    }

    private var visibleMessages: [AgentMessage] {
        appState.agentMessages.filter { $0.role != .tool }
    }

    private var currentSessionTitle: String {
        guard let id = appState.activeAgentSessionID,
              let session = appState.agentSessions.first(where: { $0.id == id }) else {
            return "New Chat"
        }
        return session.title
    }

    private var workspaceLabel: String {
        if let root = appState.rootDirectory {
            return root.lastPathComponent
        }
        return "No workspace"
    }

    private func toolCalls(for messageID: AgentMessage.ID) -> [AgentToolCall] {
        appState.agentToolCalls.filter { $0.messageID == messageID }
    }

    // MARK: image intake

    private func handlePastedImage() {
        let images = AgentImagePasteboardHelper.readImages(from: NSPasteboard.general)
        for (data, mime) in images {
            ingest(data: data, mimeType: mime)
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage,
                          let png = Self.pngData(for: image) else { return }
                    DispatchQueue.main.async {
                        ingest(data: png, mimeType: "image/png")
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          let raw = try? Data(contentsOf: url),
                          let mime = AgentImagePasteboardHelper.mimeType(forPath: url.path) else {
                        return
                    }
                    DispatchQueue.main.async {
                        ingest(data: raw, mimeType: mime)
                    }
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
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url),
                  let mime = AgentImagePasteboardHelper.mimeType(forPath: url.path) else { continue }
            ingest(data: data, mimeType: mime)
        }
    }

    private func ingest(data: Data, mimeType: String) {
        if data.count > 8 * 1024 * 1024 {
            // Skip absurdly large attachments. A warning toast would be
            // nicer, but for now we just drop them.
            return
        }
        appState.addAgentImage(data: data, mimeType: mimeType)
    }

    private static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Model picker

private struct ModelPicker: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Menu {
            let configured = appState.agentConfiguration.model
            if !configured.isEmpty {
                Button {
                    appState.setAgentSessionModel(nil)
                } label: {
                    HStack {
                        Text(configured)
                        if appState.agentSessionModelOverride == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                Text("Default (from Settings)")
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
                Text("No fetched models. Use Settings > Agent.")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cube")
                    .font(.system(size: 11))
                Text(currentModel.isEmpty ? "Select model" : currentModel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 11))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private var currentModel: String {
        appState.agentSessionModelOverride ?? appState.agentConfiguration.model
    }
}

// MARK: - Context progress

private struct ContextProgress: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 4) {
                Text(remainingLabel)
                    .font(.caption2)
                    .foregroundStyle(remainingColor)
                Text("/ \(formatTokens(window))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: proxy.size.width * CGFloat(usedFraction))
                }
            }
            .frame(height: 4)
        }
    }

    private var window: Int { max(1, appState.agentContextWindow) }
    private var used: Int { appState.estimatedAgentTokens }
    private var usedFraction: Double { min(1.0, Double(used) / Double(window)) }
    private var remaining: Int { max(0, window - used) }
    private var remainingLabel: String { "≈ \(formatTokens(remaining)) left" }

    private var remainingColor: Color {
        if usedFraction > 0.9 { return .red }
        if usedFraction > 0.75 { return .orange }
        return .secondary
    }

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

// MARK: - Queued bubble + empty state

private struct QueuedMessageBubble: View {
    let message: AgentQueuedMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "hourglass")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text("Queued")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !message.images.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "photo")
                    Text("\(message.images.count) image\(message.images.count == 1 ? "" : "s")")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

private struct AgentModeEmptyState: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Start a new chat")
                .font(.system(size: 16, weight: .semibold))
            Text(appState.rootDirectory == nil
                ? "Open a folder from the menu to chat about a project, or just ask anything."
                : "Chatting about \(appState.rootDirectory?.lastPathComponent ?? "this project"). Paste images, switch models, queue follow-ups.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
    }
}

// MARK: - NSTextView-backed composer that hooks Cmd+V for images

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
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 4)
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
            // Cmd+Return submits; plain Return inserts newline.
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let modifiers = NSEvent.modifierFlags
                if modifiers.contains(.command) {
                    onSubmit()
                    return true
                }
            }
            return false
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        // No teardown needed.
    }
}

/// Custom NSTextView that intercepts Cmd+V to ingest image data from the
/// pasteboard before falling back to the default paste behavior.
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
            // Also let the default paste run for any string content alongside
            // the image, but only if there's a text representation.
            if pasteboard.string(forType: .string) != nil {
                super.paste(sender)
            }
            return
        }
        super.paste(sender)
    }
}
