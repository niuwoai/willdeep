//
//  AgentPanelCards.swift
//  WillDeep
//
//  Leaf cards used by the compact right-side Agent panel. Split from
//  AgentPanelView.swift so the panel shell can focus on layout and state.
//

import AppKit
import SwiftUI

struct AgentPatchProposalCard: View {
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

            // rc16:Reject 放最左,Apply 放右,Spacer 留在右侧把它们顶到左边
            // 簇集 —— 仍然按「负 → 正」从左到右,误触概率低于「正 → 负」。
            HStack {
                Button {
                    appState.rejectAgentPatchProposal(id: proposal.id)
                } label: {
                    Label("Reject", systemImage: "xmark.circle")
                }
                .disabled(proposal.status != .pending)

                Button {
                    appState.applyAgentPatchProposal(id: proposal.id)
                } label: {
                    Label("Apply", systemImage: "checkmark.circle")
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

struct AgentPanelEmptyState: View {
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

struct AgentMessageBubble: View {
    let message: AgentMessage

    @State private var didJustCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !message.textAttachments.isEmpty {
                AgentTextAttachmentBubbleStrip(attachments: message.textAttachments)
            }
            if !displayContent.isEmpty {
                Text(displayContent)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            if shouldShowFooter {
                footer
            }
        }
        .padding(9)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var shouldShowFooter: Bool {
        switch message.role {
        case .system, .tool, .workflowReport, .widget: return false
        case .user, .assistant:
            return !message.content.isEmpty || !message.textAttachments.isEmpty
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: copyToClipboard) {
                Image(systemName: didJustCopy ? "checkmark" : "square.on.square")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(didJustCopy ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(didJustCopy ? "Copied" : "Copy message")

            if message.role == .assistant, let elapsed = message.elapsedSeconds, elapsed > 0 {
                Text(formatElapsed(elapsed))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if message.role == .assistant, let summary = tokenSummary {
                Text(summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    private var tokenSummary: String? {
        if let prompt = message.promptTokens, let completion = message.completionTokens {
            return "\(formatTokens(prompt))→\(formatTokens(completion))"
        }
        if let total = message.usageTokens, total > 0 {
            return "\(formatTokens(total))t"
        }
        return nil
    }

    private func formatElapsed(_ seconds: Double) -> String {
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        return "\(Int(seconds) / 60)m\(Int(seconds) % 60)s"
    }

    private func formatTokens(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000.0) : String(count)
    }

    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(message.copyableContent, forType: .string)
        didJustCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            didJustCopy = false
        }
    }

    private var displayContent: String {
        if message.content.isEmpty {
            if !message.toolCalls.isEmpty {
                return "Using tools…"
            }
            if !message.images.isEmpty {
                return ""
            }
            if !message.textAttachments.isEmpty {
                return ""
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
        case .workflowReport: return "Workflow"
        case .widget: return "Widget"
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
        case .tool, .workflowReport, .widget:
            return Color(nsColor: .controlBackgroundColor).opacity(0.4)
        }
    }
}
