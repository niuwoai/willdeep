//
//  AgentPanelView.swift
//  VeilWriter
//
//  Right-side chat panel for the project agent.
//

import SwiftUI

struct AgentPanelView: View {
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
        .frame(minWidth: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) {
            Divider()
        }
        .onAppear {
            inputFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent")
                    .font(.system(size: 13, weight: .semibold))
                Text(appState.agentConfiguration.model)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                appState.clearAgentConversation()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Clear Chat")
            .disabled(appState.agentMessages.isEmpty && appState.agentErrorMessage == nil && appState.agentToolCalls.isEmpty)

            Button {
                appState.isAgentPanelVisible = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close Agent")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if appState.agentMessages.isEmpty {
                        AgentEmptyState()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 44)
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
                .padding(10)
            }
            .onChange(of: appState.agentMessages) { _, messages in
                guard let last = messages.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            .onChange(of: appState.agentToolCalls.count) { _, _ in
                guard let last = appState.agentToolCalls.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var visibleMessages: [AgentMessage] {
        appState.agentMessages.filter { $0.role != .tool }
    }

    private func toolCalls(for messageID: AgentMessage.ID) -> [AgentToolCall] {
        appState.agentToolCalls.filter { $0.messageID == messageID }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: appState.rootDirectory == nil ? "folder.badge.questionmark" : "folder")
                    .foregroundStyle(.secondary)
                Text(contextLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }

            TextEditor(text: $appState.agentInput)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .focused($inputFocused)
                .frame(minHeight: 64, maxHeight: 110)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Text(contextHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    appState.sendAgentMessage()
                } label: {
                    Label(appState.isAgentResponding ? "Sending" : "Send", systemImage: "paperplane.fill")
                }
                .disabled(appState.isAgentResponding || appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
    }

    private var contextLabel: String {
        if let openedFileURL = appState.openedFileURL {
            return openedFileURL.lastPathComponent
        }
        if let rootDirectory = appState.rootDirectory {
            return rootDirectory.lastPathComponent
        }
        return "No workspace"
    }

    private var contextHint: String {
        if appState.rootDirectory == nil {
            return "Open a folder to enable tools"
        }
        if appState.selectedCharacterCount > 0 {
            return "Selection included · Tools available"
        }
        return "Active file included · Tools available"
    }
}

private struct AgentToolCallCard: View {
    @EnvironmentObject var appState: AppState
    let call: AgentToolCall
    @State private var isExpanded = false
    @State private var confirmInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(call.toolName)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Text(riskBadge)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(riskBadgeColor.opacity(0.18))
                            .foregroundStyle(riskBadgeColor)
                            .clipShape(Capsule())
                    }
                    Text(argumentsSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Collapse" : "Expand")
            }

            if isExpanded {
                if !argumentsLines.isEmpty {
                    expandableBlock(title: "Arguments", text: argumentsLines)
                }
                if let payload = call.result?.payload, !payload.isEmpty {
                    expandableBlock(title: "Output", text: payload)
                }
                if let errorMessage = call.errorMessage, !errorMessage.isEmpty {
                    expandableBlock(title: "Error", text: errorMessage)
                }
            }

            if call.status == .pendingApproval {
                HStack {
                    Button("Allow") { appState.approveAgentToolCall(id: call.id) }
                    Button("Deny") { appState.denyAgentToolCall(id: call.id) }
                    Spacer(minLength: 0)
                }
                .font(.caption)
            } else if call.status == .awaitingConfirm {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This is a destructive command. Type \"confirm\" to allow.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    HStack {
                        TextField("confirm", text: $confirmInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: 140)
                        Button("Run") {
                            _ = appState.confirmAgentToolCall(id: call.id, typedConfirmation: confirmInput)
                            confirmInput = ""
                        }
                        .disabled(confirmInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "confirm")
                        Button("Deny") {
                            appState.denyAgentToolCall(id: call.id)
                            confirmInput = ""
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                }
            }
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private func expandableBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private var argumentsSummary: String {
        guard !call.arguments.isEmpty else { return "(no arguments)" }
        return call.arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.displaySummary)" }
            .joined(separator: " · ")
    }

    private var argumentsLines: String {
        call.arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.displaySummary)" }
            .joined(separator: "\n")
    }

    private var iconName: String {
        switch call.status {
        case .pendingApproval, .awaitingConfirm: return "questionmark.circle"
        case .running: return "hourglass"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .denied: return "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch call.status {
        case .pendingApproval, .awaitingConfirm: return .blue
        case .running: return .secondary
        case .succeeded: return .green
        case .failed: return .orange
        case .denied: return .secondary
        }
    }

    private var statusText: String {
        switch call.status {
        case .pendingApproval: return "Awaiting approval"
        case .awaitingConfirm: return "Confirm required"
        case .running: return "Running…"
        case .succeeded:
            if let summary = call.result?.summary, !summary.isEmpty {
                return summary
            }
            return "Done"
        case .failed: return "Failed"
        case .denied: return "Denied"
        }
    }

    private var riskBadge: String {
        switch call.risk {
        case .read: return "READ"
        case .write: return "WRITE"
        case .danger: return "DANGER"
        }
    }

    private var riskBadgeColor: Color {
        switch call.risk {
        case .read: return .secondary
        case .write: return .blue
        case .danger: return .orange
        }
    }

    private var borderColor: Color {
        switch call.status {
        case .pendingApproval, .awaitingConfirm: return Color.blue.opacity(0.4)
        case .failed: return Color.orange.opacity(0.4)
        case .denied: return Color.secondary.opacity(0.3)
        default: return Color.clear
        }
    }
}

private struct AgentPatchProposalCard: View {
    @EnvironmentObject var appState: AppState
    let proposal: AgentPatchProposal
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Hide Diff" : "Show Diff")
            }

            if isExpanded {
                ScrollView(.horizontal) {
                    Text(proposal.diff)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 180)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Button {
                    appState.applyAgentPatchProposal(id: proposal.id)
                } label: {
                    Label("Apply", systemImage: "checkmark.circle")
                }
                .disabled(proposal.status != .pending)

                Button {
                    appState.rejectAgentPatchProposal(id: proposal.id)
                } label: {
                    Label("Reject", systemImage: "xmark.circle")
                }
                .disabled(proposal.status != .pending)

                Spacer(minLength: 0)
            }
            .labelStyle(.titleAndIcon)
            .font(.caption)
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var iconName: String {
        switch proposal.status {
        case .pending:
            return "doc.text.magnifyingglass"
        case .applied:
            return "checkmark.circle.fill"
        case .rejected:
            return "xmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch proposal.status {
        case .pending:
            return .secondary
        case .applied:
            return .green
        case .rejected:
            return .secondary
        case .failed:
            return .orange
        }
    }

    private var statusText: String {
        proposal.statusMessage ?? proposal.status.rawValue.capitalized
    }
}

private struct AgentEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("Ask about this project")
                .font(.system(size: 14, weight: .semibold))
            Text("The agent can read files, search, list directories, run commands (with approval), and check Git status.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
    }
}

private struct AgentMessageBubble: View {
    let message: AgentMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(displayContent)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var displayContent: String {
        if message.content.isEmpty {
            if !message.toolCalls.isEmpty {
                return "Using tools…"
            }
            return "…"
        }
        return message.content
    }

    private var title: String {
        switch message.role {
        case .system: return "System"
        case .user: return "You"
        case .assistant: return "Agent"
        case .tool: return "Tool"
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .system:
            return Color(nsColor: .controlBackgroundColor).opacity(0.45)
        case .user:
            return Color.accentColor.opacity(0.12)
        case .assistant:
            return Color(nsColor: .controlBackgroundColor).opacity(0.75)
        case .tool:
            return Color(nsColor: .controlBackgroundColor).opacity(0.4)
        }
    }
}
