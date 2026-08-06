//
//  AgentTranscriptUserMinimap.swift
//  WillDeep
//
//  Left-edge "user input" minimap for the Agent transcript: one short tick per
//  user turn, vertically centered, with the resting ticks gently darkening from
//  top to bottom. Hovering a tick grows it and floats a small card summarizing
//  that turn (what the user said, what the AI replied, which files changed).
//  Clicking scrolls the transcript to that user message (via
//  AgentChatHistoryNSTextView.scrollToUserMessage).
//

import SwiftUI

/// Memoizes the minimap turn summaries across `body` evaluations.
///
/// The minimap hangs off an `.overlay` on the transcript root, so SwiftUI
/// re-evaluates that closure several times per layout pass, and each run used
/// to rebuild `visibleMessages` and every turn summary from scratch. A 5s
/// main-thread sample of 1.228.0-rc10 showed the overlay alone taking ~12% of
/// the samples on a window nobody was even touching.
///
/// Deliberately a reference type parked in `@State`: recomputing during a
/// `body` evaluation must NOT invalidate the view, or the cache would feed the
/// very re-render loop it exists to damp.
final class AgentTranscriptMinimapCache {
    private var fingerprint: Int?
    private var cached: [AgentTranscriptTurnSummary] = []

    /// Returns the memoized summaries when `fingerprint` is unchanged,
    /// otherwise runs `rebuild` and stores its result.
    func turns(
        fingerprint incoming: Int,
        rebuild: () -> [AgentTranscriptTurnSummary]
    ) -> [AgentTranscriptTurnSummary] {
        if incoming == fingerprint { return cached }
        let fresh = rebuild()
        fingerprint = incoming
        cached = fresh
        return fresh
    }
}

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
        let editedPaths = editedPathsByMessageID(in: toolCalls)
        var result: [AgentTranscriptTurnSummary] = []
        for (index, message) in messages.enumerated() where message.isOperatorInput {
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
                    if let paths = editedPaths[next.id] {
                        files.append(contentsOf: paths)
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

    /// Edit-tool paths grouped by the assistant message that issued them.
    ///
    /// Built once per `build` call (O(toolCalls)) instead of rescanning the
    /// whole `toolCalls` array for every assistant message of every turn.
    /// The old nested scan was O(messages × toolCalls) — a long session has
    /// hundreds of messages and thousands of calls, and each inner iteration
    /// also copy/retain/released a whole `AgentToolCall`, which a main-thread
    /// sample showed dominating this function.
    private static func editedPathsByMessageID(
        in toolCalls: [AgentToolCall]
    ) -> [UUID: [String]] {
        var grouped: [UUID: [String]] = [:]
        for call in toolCalls where editToolNames.contains(call.toolName) {
            guard let path = call.arguments["path"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                continue
            }
            grouped[call.messageID, default: []].append(path)
        }
        return grouped
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
    static let minimumVisibleTurnCount = 6

    let turns: [AgentTranscriptTurnSummary]
    let onSelect: (UUID) -> Void

    @State private var hoveredIndex: Int?

    private let rowHeight: CGFloat = 12
    private let tickHeight: CGFloat = 2
    private let tickWidth: CGFloat = 6
    private let tickHoverWidth: CGFloat = 12
    private let stripWidth: CGFloat = 20
    private let restingRampLength: CGFloat = 8
    private let restingTopOpacity: CGFloat = 0.18
    private let restingBottomOpacity: CGFloat = 0.48
    private let hoverOpacityBoost: CGFloat = 0.22
    /// Fisheye reach: how many ticks on each side of the hovered one still
    /// grow/darken. The focused tick has weight 1 (longest, darkest); the
    /// weight falls off linearly to 0 at `hoverRadius`, so a tick this far
    /// out already sits at its resting size — no hard color step at the edge.
    private let hoverRadius = 3

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
        let focused = hoveredIndex == index
        let weight = hoverWeight(for: index)
        let width = tickWidth + (tickHoverWidth - tickWidth) * weight
        return RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(tickFill(index: index, weight: weight))
            .frame(width: width, height: tickHeight)
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
                if focused {
                    card(for: turn)
                        .offset(x: tickHoverWidth + 12)
                        .allowsHitTesting(false)
                        .fixedSize()
                        // Appear directly (no slide). Switching between ticks
                        // just swaps the card in place instead of animating one
                        // out to the left while the next slides in.
                        .transition(.identity)
                }
            }
            // Animate the fisheye (widths + colors of the whole neighborhood)
            // on `hoveredIndex`, so moving between ticks glides; the card above
            // opts out via `.identity` and stays instant.
            .animation(.easeOut(duration: 0.12), value: hoveredIndex)
            .zIndex(focused ? 1 : 0)
    }

    /// Fisheye weight for a tick given the current hover: 1 at the focused
    /// tick, falling off linearly to 0 at `hoverRadius` ticks away, 0 when
    /// nothing is hovered.
    private func hoverWeight(for index: Int) -> CGFloat {
        guard let hovered = hoveredIndex else { return 0 }
        let distance = abs(index - hovered)
        guard distance < hoverRadius else { return 0 }
        return 1 - CGFloat(distance) / CGFloat(hoverRadius)
    }

    /// Resting ticks gently darken down the rail, then clamp, matching Codex's
    /// subtle "more history below" cue without turning into a full scrollbar.
    private func restingDepth(for index: Int) -> CGFloat {
        min(CGFloat(index) / restingRampLength, 1)
    }

    private func tickOpacity(index: Int, weight: CGFloat) -> CGFloat {
        let base = restingTopOpacity
            + (restingBottomOpacity - restingTopOpacity) * restingDepth(for: index)
        return min(base + hoverOpacityBoost * weight, 0.68)
    }

    private func tickFill(index: Int, weight: CGFloat) -> LinearGradient {
        let opacity = tickOpacity(index: index, weight: weight)
        let topOpacity = max(opacity - 0.05, 0.08)
        let bottomOpacity = min(opacity + 0.04, 0.72)
        return LinearGradient(
            colors: [
                Color.primary.opacity(topOpacity),
                Color.primary.opacity(bottomOpacity)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
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
