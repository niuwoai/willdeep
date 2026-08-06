//
//  AgentSubagentInspectorView.swift
//  WillDeep
//
//  Round-by-round inspector for one `spawn_agent` run.
//
//  Before this existed, a child loop's transcript lived only inside the
//  runner and was discarded when it returned — the parent turn kept the
//  final report and three counters, so "what did the subagent actually do"
//  was unanswerable after the fact. The record now lands in
//  `AgentSubagentTranscriptStore`; this is the surface that reads it.
//
//  Opened as its own window rather than a side-panel tab: an inspector is
//  scoped to one run, and several runs are usually worth comparing
//  side by side. Mirrors `AgentImagePreviewWindowRegistry`.
//

import AppKit
import SwiftUI

@MainActor
final class AgentSubagentInspectorWindowRegistry {
    static let shared = AgentSubagentInspectorWindowRegistry()

    private var windows: [UUID: AgentSubagentInspectorWindowController] = [:]

    func open(runID: UUID, fallbackLabel: String? = nil) {
        if let existing = windows[runID] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = AgentSubagentInspectorWindowController(
            runID: runID,
            fallbackLabel: fallbackLabel
        )
        controller.onClose = { [weak self] closedID in
            self?.windows.removeValue(forKey: closedID)
        }
        windows[runID] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class AgentSubagentInspectorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: ((UUID) -> Void)?

    private let runID: UUID
    private var keyMonitor: Any?

    init(runID: UUID, fallbackLabel: String?) {
        self.runID = runID
        let transcript = AgentSubagentTranscriptStore.load(runID: runID)
        let title = transcript?.label ?? fallbackLabel ?? L10n.AgentDelegation.inspectorTitle
        let hostingView = NSHostingView(
            rootView: AgentSubagentInspectorView(runID: runID, transcript: transcript)
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320)

        super.init(window: window)
        window.delegate = self
        keyMonitor = AuxiliaryWindowCloseShortcut.install(on: window, closesOnEscape: true)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        onClose?(runID)
    }
}

// MARK: - Content

struct AgentSubagentInspectorView: View {
    let runID: UUID
    /// Loaded once when the window opens. A finished run's record is
    /// immutable, so there is nothing to observe.
    let transcript: AgentSubagentTranscript?

    @State private var expandedRounds: Set<Int> = []

    var body: some View {
        Group {
            if let transcript {
                content(for: transcript)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(L10n.AgentDelegation.inspectorEmpty)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(for transcript: AgentSubagentTranscript) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(for: transcript)
                section(title: L10n.AgentDelegation.inspectorPrompt, body: transcript.prompt)
                ForEach(transcript.rounds) { round in
                    roundCard(round)
                }
                if !transcript.report.isEmpty {
                    section(title: L10n.AgentDelegation.inspectorReport, body: transcript.report)
                }
                if transcript.didTruncate {
                    Label(L10n.AgentDelegation.inspectorTruncated, systemImage: "scissors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(for transcript: AgentSubagentTranscript) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(transcript.label)
                .font(.headline)
            Text(transcript.model)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let profileID = transcript.profileID {
                Text(L10n.AgentDelegation.inspectorProfile(profileID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // An escalation the user cannot see is indistinguishable from one
            // that never fired — this row is the whole point of recording it.
            if let escalatedFrom = transcript.escalatedFromModel {
                Label(
                    L10n.AgentDelegation.escalatedFrom(escalatedFrom),
                    systemImage: "arrow.up.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            Text(L10n.AgentDelegation.inspectorStats(
                "\(transcript.rounds.count)",
                "\(transcript.toolInvocationCount)",
                "\(transcript.usageTokens)"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func roundCard(_ round: AgentSubagentTranscript.Round) -> some View {
        let isExpanded = expandedRounds.contains(round.index)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if isExpanded {
                    expandedRounds.remove(round.index)
                } else {
                    expandedRounds.insert(round.index)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(L10n.AgentDelegation.inspectorRound("\(round.index)"))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(roundSummary(round))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if let reasoning = round.reasoning, !reasoning.isEmpty {
                    section(title: L10n.AgentDelegation.inspectorReasoning, body: reasoning)
                }
                if !round.content.isEmpty {
                    monospacedBlock(round.content)
                }
                ForEach(round.toolCalls) { call in
                    toolCallCard(call)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
    }

    private func roundSummary(_ round: AgentSubagentTranscript.Round) -> String {
        var parts: [String] = []
        if !round.toolCalls.isEmpty {
            parts.append("\(round.toolCalls.count) ×")
        }
        if round.usageTokens > 0 {
            parts.append("\(round.usageTokens) tok")
        }
        if let finishedAt = round.finishedAt {
            parts.append(String(format: "%.1fs", finishedAt.timeIntervalSince(round.startedAt)))
        }
        return parts.joined(separator: " · ")
    }

    private func toolCallCard(_ call: AgentSubagentTranscript.ToolCall) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(call.name)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(String(format: "%.1fs", call.durationSeconds))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !call.argumentsJSON.isEmpty {
                labeledBlock(L10n.AgentDelegation.inspectorArguments, call.argumentsJSON)
            }
            if !call.result.isEmpty {
                labeledBlock(L10n.AgentDelegation.inspectorToolResult, call.result)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
        )
    }

    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            monospacedBlock(body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labeledBlock(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            monospacedBlock(body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func monospacedBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
