//
//  AgentBackgroundTasksPanel.swift
//  WillDeep
//
//  Session-aware background process manager opened from the Composer's
//  attached activity card. The overview favors scanability; selecting a job
//  progressively reveals metadata and logs. A split stdout/stderr mode is
//  available when the panel is wide enough for engineering diagnostics.
//

import AppKit
import SwiftUI

nonisolated enum AgentBackgroundTaskScopeFilter: String, CaseIterable, Identifiable {
    case currentSession
    case allSessions

    var id: String { rawValue }
}

nonisolated enum AgentBackgroundTaskStatusFilter: String, CaseIterable, Identifiable {
    case all
    case running
    case finished

    var id: String { rawValue }
}

nonisolated enum AgentBackgroundTaskLogLayout: String, CaseIterable, Identifiable {
    case tabs
    case split

    var id: String { rawValue }
}

nonisolated enum AgentBackgroundTaskPresentation {
    static func processName(command: String) -> String {
        let tokens = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return "-" }

        var index = 0
        if tokens[index] == "env" { index += 1 }
        while index < tokens.count, isEnvironmentAssignment(tokens[index]) {
            index += 1
        }
        guard index < tokens.count else { return tokens[0] }
        return URL(fileURLWithPath: unquote(tokens[index])).lastPathComponent
    }

    static func matches(
        job: AgentBackgroundJob,
        activeSessionID: UUID?,
        scope: AgentBackgroundTaskScopeFilter,
        status: AgentBackgroundTaskStatusFilter,
        query: String
    ) -> Bool {
        if scope == .currentSession, job.runtimeID != activeSessionID {
            return false
        }
        switch status {
        case .all:
            break
        case .running where !job.isAlive:
            return false
        case .finished where job.isAlive:
            return false
        case .running, .finished:
            break
        }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return [
            processName(command: job.command),
            job.command,
            job.workingDirectoryPath ?? "",
            job.displayHandle,
        ].contains { value in
            value.localizedCaseInsensitiveContains(needle)
        }
    }

    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "=") else { return false }
        let key = token[..<equals]
        guard !key.isEmpty else { return false }
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func unquote(_ token: String) -> String {
        guard token.count >= 2 else { return token }
        let first = token.first
        let last = token.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(token.dropFirst().dropLast())
        }
        return token
    }
}

struct AgentBackgroundTasksPanel: View {
    @EnvironmentObject private var appState: AppState
    let width: CGFloat

    @State private var scope: AgentBackgroundTaskScopeFilter = .currentSession
    @State private var status: AgentBackgroundTaskStatusFilter = .all
    @State private var query = ""
    @State private var selectedJobID: UUID?
    @State private var selectedStream: AgentJobOutputStream = .combined
    @State private var logLayout: AgentBackgroundTaskLogLayout = .tabs
    @State private var followsLatestOutput = true

    init(width: CGFloat, initialSelectedJobID: UUID? = nil) {
        self.width = width
        _selectedJobID = State(initialValue: initialSelectedJobID)
        _logLayout = State(initialValue: width >= 520 ? .split : .tabs)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                filters
                Rectangle()
                    .fill(palette.hairline.opacity(0.7))
                    .frame(height: 1)
                content(now: context.date)
            }
        }
        .frame(width: width)
        .background(palette.panelFill)
        .onAppear(perform: selectInitialJobIfNeeded)
        .onCompatibleChange(of: appState.activeAgentSessionID) { _, _ in
            scope = .currentSession
            selectedJobID = nil
            selectInitialJobIfNeeded()
        }
        .onCompatibleChange(of: appState.agentJobRegistry.jobs.map(\.id)) { _, _ in
            selectInitialJobIfNeeded()
        }
    }

    private var palette: EditorInterfaceSkinPalette {
        appState.editorSettings.interfaceSkin.palette
    }

    private var filters: some View {
        VStack(spacing: 9) {
            Picker(L10n.AgentJobs.scope, selection: $scope) {
                Text(L10n.AgentJobs.currentSession).tag(AgentBackgroundTaskScopeFilter.currentSession)
                Text(L10n.AgentJobs.allSessions).tag(AgentBackgroundTaskScopeFilter.allSessions)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                TextField(L10n.AgentJobs.searchPlaceholder, text: $query)
                    .textFieldStyle(.roundedBorder)

                Picker(L10n.AgentJobs.statusFilter, selection: $status) {
                    Text(L10n.AgentJobs.filterAll).tag(AgentBackgroundTaskStatusFilter.all)
                    Text(L10n.AgentJobs.filterRunning).tag(AgentBackgroundTaskStatusFilter.running)
                    Text(L10n.AgentJobs.filterFinished).tag(AgentBackgroundTaskStatusFilter.finished)
                }
                .labelsHidden()
                .frame(width: 112)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let jobs = filteredJobs
        if jobs.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    let running = jobs.filter(\.isAlive)
                    let finished = jobs.filter { !$0.isAlive }
                    if !running.isEmpty {
                        taskSection(
                            title: L10n.AgentJobs.runningSection(running.count),
                            jobs: running,
                            now: now
                        )
                    }
                    if !finished.isEmpty {
                        taskSection(
                            title: L10n.AgentJobs.recentSection(finished.count),
                            jobs: finished,
                            now: now
                        )
                    }
                }
                .padding(12)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.65))
            Text(scope == .currentSession
                 ? L10n.AgentJobs.empty
                 : L10n.AgentJobs.emptyAllSessions)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func taskSection(
        title: String,
        jobs: [AgentBackgroundJob],
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 7) {
                ForEach(jobs) { job in
                    taskCard(job: job, now: now)
                    if selectedJobID == job.id {
                        selectedTaskDetail(job: job, now: now)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }

    private func taskCard(job: AgentBackgroundJob, now: Date) -> some View {
        let selected = selectedJobID == job.id
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                selectedJobID = selected ? nil : job.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(statusTint(for: job))
                        .frame(width: 8, height: 8)
                    Text(AgentBackgroundTaskPresentation.processName(command: job.command))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    statusBadge(for: job)
                    Spacer(minLength: 4)
                    Text(Self.formatDuration((job.finishedAt ?? now).timeIntervalSince(job.startedAt)))
                        .font(.system(size: 10, design: .monospaced).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: selected ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 9, weight: .semibold))
                    Text(job.workingDirectoryPath ?? L10n.AgentJobs.noWorkingDirectory)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if scope == .allSessions {
                        Spacer(minLength: 4)
                        Text(sessionTitle(for: job))
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

                Text(job.command.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? palette.accent.opacity(0.10) : palette.controlFill.opacity(0.42))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    selected ? palette.accent.opacity(0.50) : palette.hairline.opacity(0.75),
                    lineWidth: 1
                )
        )
    }

    private func statusBadge(for job: AgentBackgroundJob) -> some View {
        Text(statusText(for: job))
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(statusTint(for: job))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusTint(for: job).opacity(0.12))
            .clipShape(Capsule())
    }

    private func selectedTaskDetail(job: AgentBackgroundJob, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AgentBackgroundTaskPresentation.processName(command: job.command))
                        .font(.system(size: 13, weight: .semibold))
                    Text(job.displayHandle)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if job.isAlive {
                    Button(L10n.AgentJobs.stop) {
                        _ = appState.agentJobRegistry.kill(id: job.id)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                }
                Button {
                    copy(job.command)
                } label: {
                    Label(L10n.AgentJobs.copyCommand, systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            metadata(job: job, now: now)
            logControls
            logs(job: job)
        }
        .padding(.top, 2)
    }

    private func metadata(job: AgentBackgroundJob, now: Date) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            metadataRow(L10n.AgentJobs.processName, AgentBackgroundTaskPresentation.processName(command: job.command))
            metadataRow(L10n.AgentJobs.workingDirectory, job.workingDirectoryPath ?? L10n.AgentJobs.noWorkingDirectory)
            metadataRow(L10n.AgentJobs.command, job.command)
            metadataRow(L10n.AgentJobs.pid, String(job.pid))
            metadataRow(L10n.AgentJobs.startedAt, job.startedAt.formatted(date: .omitted, time: .standard))
            metadataRow(
                L10n.AgentJobs.duration,
                Self.formatDuration((job.finishedAt ?? now).timeIntervalSince(job.startedAt))
            )
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.controlFill.opacity(0.34))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.hairline.opacity(0.72), lineWidth: 1)
        )
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10.5, design: label == L10n.AgentJobs.command ? .monospaced : .default))
                .foregroundStyle(.primary)
                .lineLimit(label == L10n.AgentJobs.command ? 3 : 2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var logControls: some View {
        HStack(spacing: 8) {
            Picker(L10n.AgentJobs.logLayout, selection: $logLayout) {
                Label(L10n.AgentJobs.tabbedLogs, systemImage: "rectangle.stack")
                    .tag(AgentBackgroundTaskLogLayout.tabs)
                Label(L10n.AgentJobs.splitLogs, systemImage: "rectangle.split.2x1")
                    .tag(AgentBackgroundTaskLogLayout.split)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)

            Spacer(minLength: 4)

            Toggle(L10n.AgentJobs.autoFollow, isOn: $followsLatestOutput)
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    @ViewBuilder
    private func logs(job: AgentBackgroundJob) -> some View {
        if logLayout == .split {
            let axis = width >= 520 ? Axis.Set.horizontal : Axis.Set.vertical
            ScrollView(axis, showsIndicators: false) {
                if width >= 520 {
                    HStack(alignment: .top, spacing: 8) {
                        logConsole(job: job, stream: .stdout)
                        logConsole(job: job, stream: .stderr)
                    }
                } else {
                    VStack(spacing: 8) {
                        logConsole(job: job, stream: .stdout)
                        logConsole(job: job, stream: .stderr)
                    }
                }
            }
        } else {
            Picker(L10n.AgentJobs.outputStream, selection: $selectedStream) {
                Text(L10n.AgentJobs.combined).tag(AgentJobOutputStream.combined)
                Text(L10n.AgentJobs.stdout).tag(AgentJobOutputStream.stdout)
                Text(L10n.AgentJobs.stderr).tag(AgentJobOutputStream.stderr)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            logConsole(job: job, stream: selectedStream)
        }
    }

    private func logConsole(
        job: AgentBackgroundJob,
        stream: AgentJobOutputStream
    ) -> some View {
        let output = appState.agentJobRegistry.output(id: job.id, stream: stream, tailLines: 800)
        return AgentBackgroundTaskLogConsole(
            title: streamTitle(stream),
            tint: stream == .stderr ? .orange : palette.accent,
            output: output,
            followsLatestOutput: followsLatestOutput,
            copyOutput: { copy(output) }
        )
        .frame(minWidth: width >= 520 && logLayout == .split ? 220 : nil)
    }

    private var filteredJobs: [AgentBackgroundJob] {
        appState.agentJobRegistry.jobs
            .filter { job in
                AgentBackgroundTaskPresentation.matches(
                    job: job,
                    activeSessionID: appState.activeAgentSessionID,
                    scope: scope,
                    status: status,
                    query: query
                )
            }
            .sorted { lhs, rhs in
                if lhs.isAlive != rhs.isAlive { return lhs.isAlive }
                return lhs.startedAt > rhs.startedAt
            }
    }

    private var selectedJob: AgentBackgroundJob? {
        guard let selectedJobID else { return nil }
        return filteredJobs.first(where: { $0.id == selectedJobID })
    }

    private func selectInitialJobIfNeeded() {
        if selectedJob != nil { return }
        selectedJobID = filteredJobs.first?.id
    }

    private func sessionTitle(for job: AgentBackgroundJob) -> String {
        if job.runtimeID == appState.activeAgentSessionID {
            return L10n.AgentJobs.currentSessionBadge
        }
        return appState.agentSessions.first(where: { $0.id == job.runtimeID })?.title
            ?? job.runtimeDisplayName
            ?? job.displayHandle
    }

    private func statusText(for job: AgentBackgroundJob) -> String {
        switch job.status {
        case .running: return L10n.AgentJobs.statusRunning
        case .completed: return L10n.AgentJobs.statusCompleted
        case .failed: return L10n.AgentJobs.statusFailed
        case .killed: return L10n.AgentJobs.statusKilled
        case .timedOut: return L10n.AgentJobs.statusTimedOut
        case .launchFailed: return L10n.AgentJobs.statusLaunchFailed
        }
    }

    private func statusTint(for job: AgentBackgroundJob) -> Color {
        switch job.status {
        case .running: return .green
        case .completed: return .secondary
        case .failed, .launchFailed: return .red
        case .killed, .timedOut: return .orange
        }
    }

    private func streamTitle(_ stream: AgentJobOutputStream) -> String {
        switch stream {
        case .combined: return L10n.AgentJobs.combined
        case .stdout: return L10n.AgentJobs.stdout
        case .stderr: return L10n.AgentJobs.stderr
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let remainder = total % 60
        if minutes < 60 { return "\(minutes)m \(remainder)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

private struct AgentBackgroundTaskLogConsole: View {
    let title: String
    let tint: Color
    let output: String
    let followsLatestOutput: Bool
    let copyOutput: () -> Void

    private static let bottomID = "agent-background-task-log-bottom"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Spacer(minLength: 4)
                Text(L10n.AgentJobs.lineCount(lineCount))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button(action: copyOutput) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disabled(output.isEmpty)
                .help(L10n.AgentJobs.copyOutput)
            }
            .padding(.horizontal, 9)
            .frame(height: 32)

            Divider().opacity(0.55)

            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    Text(output.isEmpty ? L10n.AgentJobs.noOutput : output)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(
                            output.isEmpty
                                ? Color.secondary
                                : Color.primary.opacity(0.86)
                        )
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                    Color.clear.frame(width: 1, height: 1).id(Self.bottomID)
                }
                .frame(minHeight: 190, maxHeight: 320)
                .onAppear {
                    scrollToBottom(proxy)
                }
                .onCompatibleChange(of: output) { _, _ in
                    scrollToBottom(proxy)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.20), lineWidth: 1)
        )
    }

    private var lineCount: Int {
        guard !output.isEmpty else { return 0 }
        return output.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard followsLatestOutput else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }
}
