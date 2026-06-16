//
//  AgentPanelJobs.swift
//  WillDeep
//
//  Created by Codex on 2026/6/16.
//

import SwiftUI

/// Right-side companion panel listing background `run_command` jobs
/// for the active runtime. Lives only as long as the drawer is open
/// (parent `if isJobsDrawerOpen` gates it), so SwiftUI tears it down
/// when the user collapses the panel -- no need to manually manage
/// observation lifecycles. Reads from
/// `appState.agentJobRegistry` (auto-republished through AppState).
struct AgentJobsDrawer: View {
    @EnvironmentObject var appState: AppState
    @Binding var isOpen: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let runtimeID = appState.activeAgentSessionID {
                let jobs = appState.agentJobRegistry.jobs(forRuntime: runtimeID)
                if jobs.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(jobs) { job in
                                AgentJobRow(job: job)
                            }
                        }
                        .padding(10)
                    }
                }
            } else {
                emptyState
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(.secondary)
            Text(L10n.AgentJobs.title)
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            Button {
                isOpen = false
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help(L10n.AgentJobs.collapseHelp)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "play.circle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary.opacity(0.6))
            Text(L10n.AgentJobs.empty)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One row per background job. Shows the short handle, status badge,
/// duration ticker (live for alive jobs), the command, and a kill /
/// view-output cluster. Expanded view tails the captured output.
struct AgentJobRow: View {
    @EnvironmentObject var appState: AppState
    let job: AgentBackgroundJob
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                statusDot
                Text(job.displayHandle)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                durationText
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? L10n.ToolCard.collapse : L10n.ToolCard.expand)
                if job.isAlive {
                    Button {
                        _ = appState.agentJobRegistry.kill(id: job.id)
                    } label: {
                        Image(systemName: "stop.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.AgentJobs.kill)
                }
            }
            Text(job.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(isExpanded ? nil : 2)
                .truncationMode(.tail)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                statusLabel
                if let exit = job.exitCode {
                    Text("exit \(exit)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(exit == 0 ? .green : .red)
                }
                Text("pid \(job.pid)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if isExpanded {
                let output = appState.agentJobRegistry.output(id: job.id, tailLines: 200)
                ScrollView {
                    Text(output.isEmpty ? L10n.AgentJobs.noOutput : output)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusDot: some View {
        switch job.status {
        case .running:
            Circle().fill(Color.green).frame(width: 8, height: 8)
        case .completed:
            Circle().fill(Color.gray.opacity(0.5)).frame(width: 8, height: 8)
        case .failed:
            Circle().fill(Color.red).frame(width: 8, height: 8)
        case .killed, .timedOut, .launchFailed:
            Circle().fill(Color.orange).frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private var durationText: some View {
        if job.isAlive {
            TimelineView(.periodic(from: job.startedAt, by: 1)) { ctx in
                Text(Self.formatDuration(ctx.date.timeIntervalSince(job.startedAt)))
                    .font(.system(size: 10).monospacedDigit())
            }
        } else {
            Text(Self.formatDuration(job.duration))
                .font(.system(size: 10).monospacedDigit())
        }
    }

    private var statusLabel: some View {
        Text(localizedStatus)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(statusBackground)
            .foregroundStyle(statusForeground)
            .clipShape(Capsule())
    }

    private var localizedStatus: String {
        switch job.status {
        case .running: return L10n.AgentJobs.statusRunning
        case .completed: return L10n.AgentJobs.statusCompleted
        case .failed: return L10n.AgentJobs.statusFailed
        case .killed: return L10n.AgentJobs.statusKilled
        case .timedOut: return L10n.AgentJobs.statusTimedOut
        case .launchFailed: return L10n.AgentJobs.statusLaunchFailed
        }
    }

    private var statusForeground: Color {
        switch job.status {
        case .running: return .green
        case .completed: return .secondary
        case .failed, .launchFailed: return .red
        case .killed, .timedOut: return .orange
        }
    }

    private var statusBackground: Color {
        statusForeground.opacity(0.14)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        let m = total / 60, s = total % 60
        if m < 60 { return "\(m)m\(s)s" }
        let h = m / 60, mm = m % 60
        return "\(h)h\(mm)m"
    }
}
