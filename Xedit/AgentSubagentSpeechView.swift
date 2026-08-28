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
//   - a left rail and a tint assigned per public trade, stable across runs,
//     so the six built-in trades never wear the same colour as each other;
//   - the trade name and model on the header row, not just "subagent";
//   - round numbers on each utterance, matching the inspector's numbering.
//

import SwiftUI

/// Deterministic per-trade colour. Same trade, same colour, every session —
/// a Worker whose colour changed between runs would be worse than no colour.
///
/// Keyed on the *public* trade, not the raw profile id. The catalog carries
/// seventeen internal trades but shows six: `publicID(for:)` folds `scout`,
/// `log_inspector` and `git_detective` all into `reader`. Colouring the raw
/// id would paint two runs that both say "阅读者" in different colours, which
/// is worse than not colouring them at all.
///
/// The six are assigned by hand rather than hashed. Hashing is the wrong tool
/// for a domain of six known values: FNV-1a over the public ids happens to
/// collide `reader`, `tester` and `ops_runner` onto the same slot — half the
/// roster sharing one colour. A table cannot collide.
nonisolated enum AgentSubagentTradePalette {
    /// Fallback ramp for custom trades outside the built-in six. Hand-picked
    /// rather than hue-rotated: these all stay legible against both chat
    /// backgrounds, which an evenly spaced hue wheel does not.
    private static let fallbackColors: [Color] = [
        .blue, .purple, .teal, .orange, .pink, .indigo, .green, .brown,
    ]

    private static let publicColors: [String: Color] = [
        AgentSubagentProfileCatalog.readerID: .blue,
        AgentSubagentProfileCatalog.implementerID: .purple,
        AgentSubagentProfileCatalog.testerID: .green,
        AgentSubagentProfileCatalog.opsRunnerID: .orange,
        AgentSubagentProfileCatalog.judgeID: .pink,
        AgentSubagentProfileCatalog.deepID: .teal,
    ]

    static func color(forProfileID id: String) -> Color {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .accentColor }
        let publicID = AgentSubagentProfileCatalog.publicID(for: trimmed)
        if let assigned = publicColors[publicID] { return assigned }
        // A user-defined trade still deserves a stable colour. FNV-1a rather
        // than `hashValue`, which is seeded per process and would repaint the
        // Worker on every relaunch.
        var hash: UInt32 = 2_166_136_261
        for byte in publicID.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return fallbackColors[Int(hash % UInt32(fallbackColors.count))]
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
