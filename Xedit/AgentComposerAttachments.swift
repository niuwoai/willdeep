//
//  AgentComposerAttachments.swift
//  WillDeep
//
//  Small composer chrome split out of AgentModeComposerView.swift in
//  rc42: three buttons sitting around the text editor —
//   - `AttachButton`: "+" image/document attachment trigger
//   - `SendStopButton`: sends normally when idle and becomes the red stop
//     disc while the agent is busy. Follow-up queueing remains available
//     through composer submit shortcuts without a competing always-on icon.
//   - `QueueBadge`: orange hourglass pill that shows up while
//     `appState.agentQueuedMessages` is non-empty, with a menu to clear.
//
//  Three pieces, ~85 lines total — they cluster naturally because they
//  all sit in the same horizontal row in the composer card and share
//  the AppState binding pattern. Previously `private struct`; now
//  internal so ComposerCard (still in the main file) can instantiate
//  them across file boundaries.
//

import SwiftUI

struct AttachButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus.circle")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(L10n.Composer.attachFileHelp)
    }
}

struct InsertSecretButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "lock.shield")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(L10n.Composer.insertSecretHelp)
    }
}

struct SendStopButton: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 6) {
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
            .help(
                appState.isAgentResponding
                    ? L10n.Composer.stopHelp
                    : (appState.hasParsingAgentFileAttachments
                        ? L10n.Composer.waitForAttachmentParsing
                        : L10n.Composer.sendHelp)
            )
        }
        .fixedSize()
    }

    private var canSend: Bool {
        !appState.hasParsingAgentFileAttachments
            && (!appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !appState.agentPendingImages.isEmpty
            || !appState.agentPendingTextAttachments.isEmpty
            || !appState.agentPendingSkills.isEmpty
            || !appState.agentPendingFiles.isEmpty
            || appState.agentPendingIncludeWorkspaceOverview)
    }
}

struct AgentComposerTextAttachmentStrip: View {
    let attachments: [AgentTextAttachment]
    let onRemove: (AgentTextAttachment.ID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    AgentTextAttachmentChip(attachment: attachment, allowsRemoval: true) {
                        onRemove(attachment.id)
                    }
                }
            }
        }
    }
}

struct AgentTextAttachmentChip: View {
    let attachment: AgentTextAttachment
    var allowsRemoval: Bool = false
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Text(attachment.displayName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Text(attachment.byteLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if allowsRemoval, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.AgentTextAttachment.removeHelp)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .help(attachment.displayName)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct QueueBadge: View {
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
                    .agentChatSupportingFont()
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
