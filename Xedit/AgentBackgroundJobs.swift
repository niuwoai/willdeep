//
//  AgentBackgroundJobs.swift
//  WillDeep
//
//  Long-running shell jobs spawned by `run_command` with
//  `run_in_background: true`. The Claude Code-style design:
//
//   1. Tool call returns instantly with a job id; the Process keeps
//      running on a background queue.
//   2. The agent loop pulls completed-but-unconsumed jobs at the top
//      of each new turn and injects a `<background-task-notification>`
//      system message into the request so the model sees the result
//      next time it speaks — no polling tools needed for the basic
//      "did it finish" question.
//   3. UI shows alive + recently-finished jobs in a right-side
//      drawer; user can tail output or kill a job from there.
//
//  We deliberately do NOT keep the original `Process` reachable from
//  the model side — only id-keyed reads (output / kill) — so a model
//  loop can never accidentally re-attach to or leak a process handle.
//

import Foundation
import Combine
import Darwin
import UserNotifications
import AppKit

/// A single background `run_command` invocation tracked by the
/// `AgentJobRegistry`. Identifiable + Equatable so SwiftUI lists can
/// diff it cheaply. The full output buffer lives on a private actor
/// inside the registry; this snapshot only carries display metadata.
struct AgentBackgroundJob: Identifiable, Equatable {
    enum Status: String, Equatable {
        case running
        case completed
        case failed
        case killed
        case timedOut
        case launchFailed
    }

    let id: UUID
    /// First 6 chars of the UUID, lowercased — short, copy-pasteable
    /// human handle that we show in chat + drawer ("job_ab12cd").
    let shortID: String
    let command: String
    let workingDirectoryPath: String?
    let runtimeID: UUID
    var runtimeDisplayName: String?
    var remoteRuntimeID: UUID?
    var remotePID: Int32?
    let startedAt: Date
    var pid: Int32
    var status: Status
    var exitCode: Int32?
    var finishedAt: Date?
    /// Output buffer size in bytes — cheap UI summary, the real text
    /// comes from `AgentJobRegistry.output(_:tailLines:)`.
    var outputByteCount: Int

    var isAlive: Bool { status == .running }
    nonisolated var duration: TimeInterval {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }
    nonisolated var displayHandle: String { "job_\(shortID)" }
}

/// Per-app registry of background jobs. One instance lives on
/// `AppState`; views observe it directly, the agent loop pulls
/// completion events from it at the top of each turn.
///
/// Threading model: the public API is @MainActor (UI binds to
/// @Published state). The actual `Process` + readabilityHandler ride
/// on a private queue; their completion callback hops back to the
/// main actor to mutate state.
@MainActor
final class AgentJobRegistry: ObservableObject {
    /// All jobs the app has ever seen this launch, newest-first.
    /// Capped at `historyLimit` per runtime so a chatty agent can't
    /// blow the array up.
    @Published private(set) var jobs: [AgentBackgroundJob] = []

    /// Maximum output bytes we keep in memory per job. Anything past
    /// this is dropped with a `[truncated]` marker — matches the
    /// foreground `run_command` cap.
    static let maxOutputBytes = 64 * 1024

    /// Jobs older than this per runtime are evicted from `jobs`.
    /// Alive jobs are never evicted.
    private static let historyLimit = 50

    /// Side table of completed jobs the agent loop hasn't yet
    /// surfaced as a `<background-task-notification>` into the model
    /// turn. Keyed by runtime so two concurrent sessions can't steal
    /// each other's notifications.
    private var pendingCompletionEvents: [UUID: [UUID]] = [:]

    /// Live `Process` + buffer state, keyed by job id. Stripped from
    /// `jobs` (the publishable snapshot) so SwiftUI diffs only the
    /// cheap metadata.
    private var processes: [UUID: AgentJobProcess] = [:]

    // MARK: - Spawn

    /// Start a background shell job. Returns the `AgentBackgroundJob`
    /// snapshot or throws if the process fails to launch (e.g. bad
    /// shell, permission denied).
    @discardableResult
    func start(
        command: String,
        workingDirectory: URL?,
        runtimeID: UUID,
        timeoutSeconds: Double?,
        sandboxMode: AgentSandboxMode = .readOnly,
        runtimeDisplayName: String? = nil,
        runtimeIDForDisplay: UUID? = nil,
        remotePID: Int32? = nil
    ) throws -> AgentBackgroundJob {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentJobError.emptyCommand
        }

        let id = UUID()
        let shortID = String(id.uuidString.prefix(6)).lowercased()
        let workingDirectoryPath = workingDirectory?.path

        let process = Process()
        let launch = AgentSandboxPolicy.shellLaunch(
            command: trimmed,
            mode: sandboxMode,
            rootDirectory: workingDirectory
        )
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = AgentSandboxPolicy.sandboxedEnvironment(
            mode: sandboxMode,
            rootDirectory: workingDirectory,
            base: AgentToolRunner.shellEnvironment()
        )

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        AgentToolRunner.closeStandardInput(for: process)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = AgentJobOutputCollector(limit: Self.maxOutputBytes)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.append(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.append(data) }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            // Insert a synthetic .launchFailed record so the user can
            // see why their job didn't take.
            let job = AgentBackgroundJob(
                id: id,
                shortID: shortID,
                command: trimmed,
                workingDirectoryPath: workingDirectoryPath,
                runtimeID: runtimeID,
                runtimeDisplayName: runtimeDisplayName,
                remoteRuntimeID: runtimeIDForDisplay,
                remotePID: remotePID,
                startedAt: Date(),
                pid: -1,
                status: .launchFailed,
                exitCode: -1,
                finishedAt: Date(),
                outputByteCount: 0
            )
            insertOrUpdate(job)
            collector.appendString(error.localizedDescription)
            processes[id] = AgentJobProcess(process: process, collector: collector)
            pendingCompletionEvents[runtimeID, default: []].append(id)
            return job
        }

        let pid = process.processIdentifier
        let startedAt = Date()
        let initial = AgentBackgroundJob(
            id: id,
            shortID: shortID,
            command: trimmed,
            workingDirectoryPath: workingDirectoryPath,
            runtimeID: runtimeID,
            runtimeDisplayName: runtimeDisplayName,
            remoteRuntimeID: runtimeIDForDisplay,
            remotePID: remotePID,
            startedAt: startedAt,
            pid: pid,
            status: .running,
            exitCode: nil,
            finishedAt: nil,
            outputByteCount: 0
        )
        let processBox = AgentJobProcess(process: process, collector: collector)
        processes[id] = processBox
        insertOrUpdate(initial)

        // Optional hard timeout — same shape as the foreground
        // runCommand, but we don't throw on timeout; we mark the
        // job as .timedOut so the notification reads cleanly.
        if let timeoutSeconds, timeoutSeconds > 0 {
            let work = DispatchWorkItem { [weak processBox] in
                guard let processBox else { return }
                if processBox.process.isRunning {
                    processBox.markTimedOut()
                    processBox.process.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                        if processBox.process.isRunning {
                            Darwin.kill(processBox.process.processIdentifier, SIGKILL)
                        }
                    }
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeoutSeconds,
                execute: work
            )
            processBox.timeoutWork = work
        }

        // Termination handler runs on a private queue; hop back to the
        // main actor to mutate state and post the notification.
        process.terminationHandler = { [weak self, weak processBox] proc in
            // Drain any remaining buffered output before the pipes go
            // away — readabilityHandler can race with terminate().
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if let processBox {
                processBox.timeoutWork?.cancel()
                processBox.collector.append(stdoutPipe.fileHandleForReading.availableData)
                processBox.collector.append(stderrPipe.fileHandleForReading.availableData)
            }
            let exitStatus = proc.terminationStatus
            let didTimeOut = processBox?.didTimeOut ?? false
            let wasKilled = processBox?.didExplicitKill ?? false
            Task { @MainActor [weak self] in
                self?.markFinished(
                    id: id,
                    exitCode: exitStatus,
                    didTimeOut: didTimeOut,
                    wasKilled: wasKilled
                )
            }
        }

        return initial
    }

    // MARK: - Queries

    func jobs(forRuntime runtimeID: UUID) -> [AgentBackgroundJob] {
        jobs.filter { $0.runtimeID == runtimeID }
    }

    func aliveJobs(forRuntime runtimeID: UUID) -> [AgentBackgroundJob] {
        jobs.filter { $0.runtimeID == runtimeID && $0.isAlive }
    }

    func job(id: UUID) -> AgentBackgroundJob? {
        jobs.first(where: { $0.id == id })
    }

    /// Resolve a model-supplied id — either the full UUID or a
    /// 6-char short id — to a job. Returns nil on miss.
    func job(matchingHandle handle: String, runtimeID: UUID) -> AgentBackgroundJob? {
        let normalized = handle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "job_", with: "")
            .lowercased()
        return jobs.first { job in
            job.runtimeID == runtimeID && (
                job.shortID == normalized
                || job.id.uuidString.lowercased() == normalized
            )
        }
    }

    /// Tail of the live output buffer. `tailLines == nil` returns all
    /// captured output (still capped at `maxOutputBytes`).
    ///
    /// Trailing-newline handling: a normal `echo`/`printf` ends the
    /// last line with `\n`, which `split(omittingEmptySubsequences:
    /// false)` would treat as an extra empty segment — and `suffix(N)`
    /// would then return one fewer real line than the caller asked
    /// for. Drop a single trailing newline before splitting so the
    /// tail count matches user intuition.
    func output(id: UUID, tailLines: Int? = nil) -> String {
        guard let proc = processes[id] else { return "" }
        let full = proc.collector.stringValue
        guard let tailLines, tailLines > 0 else { return full }
        let normalized = full.hasSuffix("\n") ? String(full.dropLast()) : full
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= tailLines { return full }
        return lines.suffix(tailLines).joined(separator: "\n")
    }

    // MARK: - Lifecycle ops

    /// Send SIGTERM (then SIGKILL after 2s) to a running job.
    /// Returns true if a process was actually signaled.
    @discardableResult
    func kill(id: UUID) -> Bool {
        guard let proc = processes[id], proc.process.isRunning else { return false }
        proc.markExplicitKill()
        proc.process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak proc] in
            guard let proc, proc.process.isRunning else { return }
            Darwin.kill(proc.process.processIdentifier, SIGKILL)
        }
        return true
    }

    /// Best-effort terminate-all for a given runtime — used when a
    /// session is being cleared / closed and the user opted into
    /// killing leftover jobs.
    func killAllAlive(forRuntime runtimeID: UUID) {
        for job in aliveJobs(forRuntime: runtimeID) {
            _ = kill(id: job.id)
        }
    }

    // MARK: - Completion event drain (agent loop hook)

    /// Pop all completion events that the loop hasn't seen yet for
    /// this runtime, in completion order. The agent loop renders each
    /// into a single `<background-task-notification>` system message
    /// for the upcoming turn.
    func consumePendingCompletions(forRuntime runtimeID: UUID) -> [AgentBackgroundJob] {
        guard let ids = pendingCompletionEvents.removeValue(forKey: runtimeID), !ids.isEmpty else {
            return []
        }
        return ids.compactMap { id in jobs.first(where: { $0.id == id }) }
    }

    /// Non-destructive peek for UI ("⚠ N untold completions") —
    /// currently unused but cheap to expose for the drawer badge.
    func pendingCompletionCount(forRuntime runtimeID: UUID) -> Int {
        pendingCompletionEvents[runtimeID]?.count ?? 0
    }

    // MARK: - Internal mutations

    private func insertOrUpdate(_ job: AgentBackgroundJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
        evictOldHistory(for: job.runtimeID)
    }

    private func evictOldHistory(for runtimeID: UUID) {
        let scoped = jobs.enumerated().filter { $0.element.runtimeID == runtimeID }
        guard scoped.count > Self.historyLimit else { return }
        // Drop oldest finished entries first; keep all alive jobs.
        let removable = scoped
            .filter { !$0.element.isAlive }
            .sorted { ($0.element.finishedAt ?? .distantPast) < ($1.element.finishedAt ?? .distantPast) }
        let drop = max(0, scoped.count - Self.historyLimit)
        for entry in removable.prefix(drop) {
            jobs.removeAll(where: { $0.id == entry.element.id })
            processes.removeValue(forKey: entry.element.id)
        }
    }

    private func markFinished(
        id: UUID,
        exitCode: Int32,
        didTimeOut: Bool,
        wasKilled: Bool
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        var updated = jobs[index]
        updated.finishedAt = Date()
        updated.exitCode = exitCode
        if wasKilled {
            updated.status = .killed
        } else if didTimeOut {
            updated.status = .timedOut
        } else if exitCode == 0 {
            updated.status = .completed
        } else {
            updated.status = .failed
        }
        updated.outputByteCount = processes[id]?.collector.byteCount ?? 0
        jobs[index] = updated

        pendingCompletionEvents[updated.runtimeID, default: []].append(id)

        AgentToolApprovalNotifier.notifyJobFinished(job: updated)
    }
}

enum AgentJobError: LocalizedError {
    case emptyCommand
    case jobNotFound(String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand: return "Background job command is empty."
        case .jobNotFound(let handle): return "No background job matches \(handle)."
        }
    }
}

// MARK: - Internal process box

/// Holds the live Process + output buffer for a single job. Kept
/// private to the registry so the model surface can't reach into it.
/// `nonisolated` because we touch the box from `readabilityHandler` /
/// `terminationHandler`, both of which run off the main actor.
private nonisolated final class AgentJobProcess: @unchecked Sendable {
    let process: Process
    let collector: AgentJobOutputCollector
    var timeoutWork: DispatchWorkItem?
    private let stateLock = NSLock()
    private var _didTimeOut = false
    private var _didExplicitKill = false

    init(process: Process, collector: AgentJobOutputCollector) {
        self.process = process
        self.collector = collector
    }

    func markTimedOut() {
        stateLock.lock(); defer { stateLock.unlock() }
        _didTimeOut = true
    }

    func markExplicitKill() {
        stateLock.lock(); defer { stateLock.unlock() }
        _didExplicitKill = true
    }

    var didTimeOut: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _didTimeOut
    }

    var didExplicitKill: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _didExplicitKill
    }
}

/// Thread-safe rolling output buffer with a byte cap — same shape as
/// the foreground `CommandOutputCollector` but reusable across job
/// lifetimes and exposed for tail-reads.
private nonisolated final class AgentJobOutputCollector: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        if remaining > 0 {
            data.append(chunk.prefix(remaining))
        }
        if chunk.count > remaining {
            truncated = true
        }
    }

    func appendString(_ s: String) {
        guard let bytes = s.data(using: .utf8) else { return }
        append(bytes)
    }

    var byteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return data.count
    }

    var stringValue: String {
        lock.lock()
        let snapshot = data
        let didTruncate = truncated
        lock.unlock()
        var text = String(data: snapshot, encoding: .utf8) ?? ""
        if didTruncate { text += "\n...[truncated]" }
        return text
    }
}
