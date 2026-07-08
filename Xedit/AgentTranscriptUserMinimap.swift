//
//  AgentTranscriptUserMinimap.swift
//  WillDeep
//
//  Left-edge "user input" minimap for the Agent transcript: one equal-sized,
//  evenly-spaced tick per user turn, vertically centered. Hovering a tick grows
//  it and floats a small card summarizing that turn (what the user said, what
//  the AI replied, which files changed). Clicking scrolls the transcript to that
//  user message (via AgentChatHistoryNSTextView.scrollToUserMessage).
//

import SwiftUI

/// One rendered user turn, distilled for the minimap hover card.
struct AgentTranscriptTurnSummary: Identifiable, Equatable {
    let id: UUID            // the user message id (matches agentChatHistoryUserMessageID)
    let userText: String
    let assistantText: String
    let changedFiles: [String]

    private static let editToolNames: Set<String> = [
        "create_file", "apply_patch", "edit_file", "write_file", "edit_generated_image"
    ]

    /// Build one summary per user message in `messages`, folding in the
    /// following assistant reply and the files its tool calls edited.
    static func build(
        from messages: [AgentMessage],
        toolCalls: [AgentToolCall]
    ) -> [AgentTranscriptTurnSummary] {
        var result: [AgentTranscriptTurnSummary] = []
        for (index, message) in messages.enumerated() where message.role == .user {
            var assistantText = ""
            var files: [String] = []
            var cursor = index + 1
            while cursor < messages.count, messages[cursor].role != .user {
                let next = messages[cursor]
                if next.role == .assistant {
                    if assistantText.isEmpty {
                        let content = next.content.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !content.isEmpty { assistantText = content }
                    }
                    for call in toolCalls where call.messageID == next.id
                        && editToolNames.contains(call.toolName) {
                        if let path = call.arguments["path"]?.stringValue()?
                            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                            files.append(path)
                        }
                    }
                }
                cursor += 1
            }
            var seen = Set<String>()
            let uniqueFiles = files.filter { seen.insert($0).inserted }
            result.append(
                AgentTranscriptTurnSummary(
                    id: message.id,
                    userText: userVisibleText(message),
                    assistantText: assistantText,
                    changedFiles: uniqueFiles
                )
            )
        }
        return result
    }

    private static func userVisibleText(_ message: AgentMessage) -> String {
        let display = AgentAttachedPromptDisplay.transform(message.content)
        let source = display.isSplicedPrelude ? display.visibleContent : message.content
        let visible = AgentUserContentSplitter.split(source).visible
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if visible.isEmpty, !message.images.isEmpty {
            return "🖼 ×\(message.images.count)"
        }
        return visible
    }
}

struct AgentTranscriptUserMinimap: View {
    let turns: [AgentTranscriptTurnSummary]
    let onSelect: (UUID) -> Void

    @State private var hoveredIndex: Int?

    private let rowHeight: CGFloat = 12
    private let tickHeight: CGFloat = 2
    private let tickWidth: CGFloat = 11
    private let tickHoverWidth: CGFloat = 22
    private let stripWidth: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                tickRow(index: index, turn: turn)
            }
        }
        .frame(width: stripWidth)
        .frame(maxHeight: .infinity, alignment: .center)
        .padding(.leading, 4)
    }

    private func tickRow(index: Int, turn: AgentTranscriptTurnSummary) -> some View {
        let hovered = hoveredIndex == index
        return RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(hovered ? Color.accentColor : Color.secondary.opacity(0.4))
            .frame(width: hovered ? tickHoverWidth : tickWidth, height: tickHeight)
            .frame(width: stripWidth, height: rowHeight, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    hoveredIndex = index
                } else if hoveredIndex == index {
                    hoveredIndex = nil
                }
            }
            .onTapGesture { onSelect(turn.id) }
            .overlay(alignment: .leading) {
                if hovered {
                    card(for: turn)
                        .offset(x: tickHoverWidth + 14)
                        .allowsHitTesting(false)
                        .fixedSize()
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .zIndex(hovered ? 1 : 0)
    }

    private func card(for turn: AgentTranscriptTurnSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            cardLine(
                systemImage: "person.crop.circle",
                text: turn.userText.isEmpty ? L10n.Transcript.minimapEmptyUserText : turn.userText,
                color: .primary,
                lineLimit: 3
            )
            if !turn.assistantText.isEmpty {
                cardLine(systemImage: "sparkles", text: turn.assistantText, color: .secondary, lineLimit: 3)
            }
            if !turn.changedFiles.isEmpty {
                cardLine(
                    systemImage: "doc.text",
                    text: turn.changedFiles.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "),
                    color: .secondary,
                    lineLimit: 2
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 268, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 9, x: 0, y: 2)
    }

    private func cardLine(systemImage: String, text: String, color: Color, lineLimit: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
        }
    }
}
