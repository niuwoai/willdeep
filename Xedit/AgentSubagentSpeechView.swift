//
//  AgentSubagentSpeechView.swift
//  WillDeep
//
//  A Worker talking, inside the delegation card that spawned it.
//
//  Placement is deliberate. The obvious alternative — give the child its own
//  message role and let its rounds land in the transcript as separate
//  bubbles — reads well with one Worker and falls apart with three: their
//  rounds interleave by arrival time, and the transcript stops being a record
//  of who said what to whom. Nesting the speech under the delegation keeps
//  every Worker's narration attached to the task it was given, and keeps the
//  parent's own turn readable.
//
//  What makes it legible as *someone else* speaking:
//   - a left rail and a tint derived from the trade id, stable across runs,
//     so two Workers in one turn never wear the same colour;
//   - the trade name and model on the header row, not just "subagent";
//   - round numbers on each utterance, matching the inspector's numbering.
//

import SwiftUI

/// Deterministic per-trade colour. Same trade, same colour, every session —
/// a Worker whose colour changed between runs would be worse than no colour.
nonisolated enum AgentSubagentTradePalette {
    /// Hand-picked rather than hue-rotated: these all stay legible against
    /// both chat backgrounds, which an evenly spaced hue wheel does not.
    private static let colors: [Color] = [
        .blue, .purple, .teal, .orange, .pink, .indigo, .green, .brown,
    ]

    static func color(forProfileID id: String) -> Color {
        guard !id.isEmpty else { return .accentColor }
        // FNV-1a over the id's bytes. `hashValue` is seeded per process and
        // would repaint every Worker on relaunch.
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return colors[Int(hash % UInt32(colors.count))]
    }
}

struct AgentSubagentSpeechView: View {
    @EnvironmentObject var appState: AppState

    let activity: AgentSubagentLiveActivity
    /// Drives the header spinner and the round line. A finished Worker keeps
    /// its transcript on screen — that is the point — but stops claiming to
    /// still be working.
    let isRunning: Bool

    private var tint: Color {
        AgentSubagentTradePalette.color(forProfileID: activity.profileID)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Capsule()
                .fill(tint.opacity(0.55))
                .frame(width: 2.5)
            VStack(alignment: .leading, spacing: 6) {
                header
                ForEach(activity.utterances) { utterance in
                    utteranceRow(utterance)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 2)
        .padding(.vertical, 6)
        .padding(.trailing, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "person.wave.2.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tint)
            Text(activity.workerName)
                .font(AgentDesign.chatSupportingFont(
                    baseFontSize: appState.agentChatBaseFontSize,
                    visualMinimum: 10,
                    weight: .semibold
                ))
                .foregroundStyle(tint)
                .lineLimit(1)
            if !activity.model.isEmpty {
                Text(activity.model)
                    .font(AgentDesign.chatSupportingFont(
                        baseFontSize: appState.agentChatBaseFontSize,
                        visualMinimum: 9,
                        weight: .regular
                    ))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if isRunning {
                Text(activity.detailLine)
                    .font(AgentDesign.chatSupportingFont(
                        baseFontSize: appState.agentChatBaseFontSize,
                        visualMinimum: 9,
                        weight: .regular
                    ))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.5)
                    .frame(width: 11, height: 11)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func utteranceRow(_ utterance: AgentSubagentLiveActivity.Utterance) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !utterance.text.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(L10n.AgentDelegation.speechRoundMarker(utterance.round))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tint.opacity(0.7))
                        .monospacedDigit()
                    // Plain text on purpose. Rendering a Worker's markdown
                    // live is the shape that previously melted the main
                    // thread in SwiftUI layout; the full report still gets
                    // rich treatment once the run returns.
                    Text(utterance.text)
                        .font(AgentDesign.chatSupportingFont(
                            baseFontSize: appState.agentChatBaseFontSize,
                            visualMinimum: 10,
                            weight: .regular
                        ))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !utterance.toolNames.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(utterance.toolNames.enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(tint.opacity(0.12))
                            .foregroundStyle(tint.opacity(0.9))
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, utterance.text.isEmpty ? 0 : 18)
            }
        }
    }
}
