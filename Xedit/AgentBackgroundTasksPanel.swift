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

/// Neutral palette for the scope switch at the top of the panel. Mirrors the
/// terminal tab strip's `TerminalTabChrome`: permanent chrome carries no
/// accent colour, and selection is expressed through fill density, a border,
/// and text weight instead.
private enum BackgroundTaskScopeChrome {
    static let trackFillOpacity: Double = 0.05
    static let selectedFillOpacity: Double = 0.10
    static let selectedStrokeOpacity: Double = 0.22
    static let selectedTextOpacity: Double = 0.88
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

    /// Takes `processName` pre-computed by the caller. Deriving it here meant
    /// splitting and path-parsing every job's command line on every keystroke
    /// *and* again in each card body; `AgentBackgroundTaskRow` now computes it
    /// exactly once per job per rebuild.
    static func matches(
        job: AgentBackgroundJob,
        processName: String,
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
            processName,
            job.command,
            job.workingDirectoryPath ?? "",
            job.displayHandle,
        ].contains { value in
            value.localizedCaseInsensitiveContains(needle)
        }
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let remainder = total % 60
        if minutes < 60 { return "\(minutes)m \(remainder)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
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

/// A job plus the display values derived from it.
///
/// `processName(command:)` splits the command line and builds a `URL` to take
/// its last path component. That ran once per job inside `matches`, once more
/// in each card body, and again in the detail pane's metadata grid — every
/// time the panel rebuilt. Deriving it once here keeps the work proportional to
/// the job list rather than to the render count, and makes the row `Equatable`
/// so `ForEach` can skip untouched cards.
struct AgentBackgroundTaskRow: Identifiable, Equatable {
    let job: AgentBackgroundJob
    let processName: String

    var id: AgentBackgroundJob.ID { job.id }

    init(job: AgentBackgroundJob) {
        self.job = job
        self.processName = AgentBackgroundTaskPresentation.processName(command: job.command)
    }

    /// Splits rows into running and finished in a single pass. The panel used
    /// to call `filter` twice over the same array on every rebuild.
    static func partitioned(
        _ rows: [AgentBackgroundTaskRow]
    ) -> (running: [AgentBackgroundTaskRow], finished: [AgentBackgroundTaskRow]) {
        var running: [AgentBackgroundTaskRow] = []
        var finished: [AgentBackgroundTaskRow] = []
        running.reserveCapacity(rows.count)
        finished.reserveCapacity(rows.count)
        for row in rows {
            if row.job.isAlive {
                running.append(row)
            } else {
                finished.append(row)
            }
        }
        return (running, finished)
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
        // The per-second tick lives in `AgentBackgroundTaskDurationLabel`, not
        // here. Wrapping the whole body in a `TimelineView` rebuilt the scope
        // picker, the search field, and every card once a second just to
        // advance a handful of elapsed-time labels.
        VStack(spacing: 0) {
            filters
            Rectangle()
                .fill(palette.hairline.opacity(0.7))
                .frame(height: 1)
            content
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
            scopeTabs

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

    /// Hand-drawn instead of `.pickerStyle(.segmented)`: the native control
    /// paints its selected segment with the system accent (blue under the
    /// `system` skin), and this row is permanent panel chrome that has no
    /// business holding a high-priority colour signal all day. Same neutral
    /// treatment the terminal tab strip and the error banner already moved to
    /// — selection reads through a denser fill, a border, and weight.
    private var scopeTabs: some View {
        HStack(spacing: 2) {
            scopeTab(.currentSession, title: L10n.AgentJobs.currentSession)
            scopeTab(.allSessions, title: L10n.AgentJobs.allSessions)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.primaryText.opacity(BackgroundTaskScopeChrome.trackFillOpacity))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.AgentJobs.scope)
    }

    private func scopeTab(
        _ value: AgentBackgroundTaskScopeFilter,
        title: String
    ) -> some View {
        let isSelected = scope == value
        return Button {
            scope = value
        } label: {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(
                    isSelected
                        ? palette.primaryText.opacity(BackgroundTaskScopeChrome.selectedTextOpacity)
                        : palette.secondaryText
                )
                .frame(maxWidth: .infinity)
                .frame(height: 21)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    isSelected
                        ? palette.primaryText.opacity(BackgroundTaskScopeChrome.selectedFillOpacity)
                        : Color.clear
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(
                    isSelected
                        ? palette.primaryText.opacity(BackgroundTaskScopeChrome.selectedStrokeOpacity)
                        : Color.clear,
                    lineWidth: 1
                )
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var content: some View {
        let rows = filteredRows
        if rows.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    let split = AgentBackgroundTaskRow.partitioned(rows)
                    if !split.running.isEmpty {
                        taskSection(
                            title: L10n.AgentJobs.runningSection(split.running.count),
                            rows: split.running
                        )
                    }
                    if !split.finished.isEmpty {
                        taskSection(
                            title: L10n.AgentJobs.recentSection(split.finished.count),
                            rows: split.finished
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
        rows: [AgentBackgroundTaskRow]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 7) {
                ForEach(rows) { row in
                    taskCard(row: row)
                    if selectedJobID == row.id {
                        selectedTaskDetail(row: row)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }

    private func taskCard(row: AgentBackgroundTaskRow) -> some View {
        let job = row.job
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
                    Text(row.processName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    statusBadge(for: job)
                    Spacer(minLength: 4)
                    AgentBackgroundTaskDurationLabel(
                        startedAt: job.startedAt,
                        finishedAt: job.finishedAt
                    )
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

    private func selectedTaskDetail(row: AgentBackgroundTaskRow) -> some View {
        let job = row.job
        return VStack(alignment: .leading, spacing: 12) {
            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.processName)
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

            metadata(row: row)
            logControls
            logs(job: job)
        }
        .padding(.top, 2)
    }

    private func metadata(row: AgentBackgroundTaskRow) -> some View {
        let job = row.job
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            metadataRow(L10n.AgentJobs.processName, row.processName)
            metadataRow(L10n.AgentJobs.workingDirectory, job.workingDirectoryPath ?? L10n.AgentJobs.noWorkingDirectory)
            metadataRow(L10n.AgentJobs.command, job.command)
            metadataRow(L10n.AgentJobs.pid, String(job.pid))
            metadataRow(L10n.AgentJobs.startedAt, job.startedAt.formatted(date: .omitted, time: .standard))
            // Spelled out rather than routed through `metadataRow` so the
            // elapsed value can own its own tick; the styling matches what
            // `metadataRow` would produce for a non-command label.
            GridRow {
                Text(L10n.AgentJobs.duration)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.leading)
                AgentBackgroundTaskDurationLabel(
                    startedAt: job.startedAt,
                    finishedAt: job.finishedAt
                )
                .font(.system(size: 10.5))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.system(size: 10.5, design: label == L10n.AgentJobs.command ? .monospaced : .default))
                .foregroundStyle(.primary)
                .lineLimit(label == L10n.AgentJobs.command ? 3 : 2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                // Without a width to work against, a long command line reports
                // its full single-line width as its ideal size: the grid column
                // stretches past the panel, `lineLimit` never has a reason to
                // wrap, and the text paints straight over the rows beneath it.
                // Filling the available width forces the wrap-then-truncate the
                // line limit is there to produce.
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
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
            // Each console already scrolls on both axes internally, so the
            // panes must stay bounded by the panel width. An outer horizontal
            // ScrollView here handed them an unbounded width proposal and each
            // pane grew to its longest log line, shoving stderr off-panel.
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
        // `maxWidth: .infinity` rather than a `minWidth` floor: in the split
        // HStack this makes the two panes share the panel evenly, and a floor
        // would let them overflow instead of shrinking.
        .frame(maxWidth: .infinity)
        // One scroll position per (job, stream). Without a distinct identity
        // SwiftUI reuses the same console across tab switches, so stdout
        // inherited whatever offset combined/stderr was left at — including a
        // horizontal one the user never chose for this stream.
        .id("\(job.id.uuidString)-\(stream.rawValue)")
    }

    /// Builds each row once — `processName` included — then filters and sorts.
    /// `content` reads this a single time per rebuild and hands the result to
    /// `partitioned`, so the job list is walked a bounded number of times
    /// instead of once per `filter` call plus once per card body.
    private var filteredRows: [AgentBackgroundTaskRow] {
        appState.agentJobRegistry.jobs
            .map(AgentBackgroundTaskRow.init(job:))
            .filter { row in
                AgentBackgroundTaskPresentation.matches(
                    job: row.job,
                    processName: row.processName,
                    activeSessionID: appState.activeAgentSessionID,
                    scope: scope,
                    status: status,
                    query: query
                )
            }
            .sorted { lhs, rhs in
                if lhs.job.isAlive != rhs.job.isAlive { return lhs.job.isAlive }
                return lhs.job.startedAt > rhs.job.startedAt
            }
    }

    private var selectedJobExists: Bool {
        guard let selectedJobID else { return false }
        return filteredRows.contains(where: { $0.id == selectedJobID })
    }

    private func selectInitialJobIfNeeded() {
        if selectedJobExists { return }
        selectedJobID = filteredRows.first?.id
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

}

/// Elapsed-time text that owns its own per-second tick.
///
/// This used to be a plain `Text` fed by a `TimelineView` wrapped around the
/// entire panel body, which meant one tick rebuilt the scope picker, the search
/// field, every card, and the expanded detail pane. Scoping the timeline to the
/// label keeps the invalidated subtree to the text itself.
///
/// A finished job's duration never changes, so it renders as a static `Text`
/// with no timeline at all — a panel showing only completed tasks now sits
/// completely idle instead of ticking once a second forever.
struct AgentBackgroundTaskDurationLabel: View {
    let startedAt: Date
    let finishedAt: Date?

    var body: some View {
        if let finishedAt {
            Text(AgentBackgroundTaskPresentation.formatDuration(
                finishedAt.timeIntervalSince(startedAt)
            ))
        } else {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(AgentBackgroundTaskPresentation.formatDuration(
                    context.date.timeIntervalSince(startedAt)
                ))
            }
        }
    }
}

/// Scroll behaviour for the job log consoles. Pulled out of the view body so
/// the anchor is a named value a test can pin rather than a literal nobody
/// reviews.
enum AgentBackgroundTaskLogScroll {
    static let bottomSentinelID = "agent-background-task-log-bottom"

    /// `ScrollViewProxy.scrollTo` applies its anchor to **both** axes, and
    /// `.bottom` carries `x == 0.5`. Following the tail with that anchor also
    /// told the scroll view to centre the content horizontally, so opening
    /// stdout landed in the middle of the longest line instead of at its first
    /// character. `.bottomLeading` keeps the vertical follow and pins x to the
    /// start of the line.
    static let followAnchor: UnitPoint = .bottomLeading
}

private struct AgentBackgroundTaskLogConsole: View {
    let title: String
    let tint: Color
    let output: String
    let followsLatestOutput: Bool
    let copyOutput: () -> Void

    private static let bottomID = AgentBackgroundTaskLogScroll.bottomSentinelID

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
                    // Explicit leading-aligned stack. The tail sentinel must
                    // sit at the content's leading edge: `scrollTo` positions
                    // the *target* view inside the viewport, so a sentinel
                    // centred by the default VStack alignment would drag the
                    // whole log to the middle even with a leading anchor.
                    VStack(alignment: .leading, spacing: 0) {
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
            proxy.scrollTo(
                Self.bottomID,
                anchor: AgentBackgroundTaskLogScroll.followAnchor
            )
        }
    }
}
