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

nonisolated enum AgentJobOutputStream: String, CaseIterable, Identifiable {
    case combined
    case stdout
    case stderr

    var id: String { rawValue }
}

/// Host-enforced ownership for background commands. Goal dev servers are
/// phase-scoped by default, so finishing QA cannot leave an old server (or its
/// browser children) consuming resources indefinitely.
nonisolated enum AgentBackgroundJobLifetime: String, CaseIterable, Equatable {
    case turn
    case phase
    case goal
    case persistent
}

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
    /// Present for structured Claude/Codex sessions. Generic shell jobs keep
    /// these fields nil and retain their existing behavior.
    var executor: AgentExecutionAgent? = nil
    var executorSessionID: String? = nil
    var latestExecutorEvent: AgentExecutorEvent? = nil
    var executorUsage: AgentExecutorUsage? = nil
    var lifetime: AgentBackgroundJobLifetime = .turn
    var goalPhaseID: String? = nil

    nonisolated var isAlive: Bool { status == .running }
    nonisolated var needsAttention: Bool {
        switch status {
        case .failed, .timedOut, .launchFailed:
            return true
        case .running, .completed, .killed:
            return false
        }
    }
    nonisolated var duration: TimeInterval {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }
    nonisolated var displayHandle: String { "job_\(shortID)" }
}

/// Host-only replay material for a sandboxed background command. The public
/// job snapshot intentionally keeps only redacted display data; this side
/// table is discarded with the process and is never persisted or rendered.
private struct AgentBackgroundSandboxRetrySpecification {
    let command: String
    let workingDirectory: URL?
    let additionalWorkspaceRoots: [URL]
    let runtimeID: UUID
    let turnID: UUID?
    let timeoutSeconds: Double?
    let environment: [String: String]?
    let runtimeDisplayName: String?
    let runtimeIDForDisplay: UUID?
    let remotePID: Int32?
    let displayCommand: String?
    let secretRedactionValues: [String]
    let sandboxMode: AgentSandboxMode
    let approvalSource: AgentToolApprovalSource
    let lifetime: AgentBackgroundJobLifetime
    let goalPhaseID: String?
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
    /// Process termination and timeout escalation must not share the
    /// global utility queue. Under a cold Xcode test build that queue can
    /// be starved long enough for a requested kill to miss its UI budget.
    private static let lifecycleQueue = DispatchQueue(
        label: "com.willdeep.agent-background-jobs.lifecycle",
        qos: .userInitiated
    )

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

    /// Runtime id answers "which conversation?"; this side table answers the
    /// narrower Stop question: "which exact turn created it?". Keeping the
    /// token host-only avoids changing the public/persisted job snapshot.
    private var originatingTurnIDs: [UUID: UUID] = [:]

    /// Jobs killed as part of a user Stop already receive a local transcript
    /// acknowledgement. Suppress their normal completion wake-up so the app
    /// does not immediately start another model turn just to announce the
    /// same kill a second time.
    private var suppressedCompletionJobIDs: Set<UUID> = []

    /// Optional host hook for UI paths that need to surface a finished
    /// background job without waiting for the next model turn.
    var onJobFinished: ((AgentBackgroundJob) -> Void)?

    /// Live `Process` + buffer state, keyed by job id. Stripped from
    /// `jobs` (the publishable snapshot) so SwiftUI diffs only the
    /// cheap metadata.
    private var processes: [UUID: AgentJobProcess] = [:]
    /// Sandboxed unattended commands may finish after their originating tool
    /// call has already returned a job handle. Retain one bounded replay spec
    /// so an EPERM can take the same escalation path as foreground commands.
    private var sandboxRetrySpecifications: [UUID: AgentBackgroundSandboxRetrySpecification] = [:]

    /// Bidirectional protocol sessions own their Process inside the protocol
    /// driver. The registry keeps only cancellation, timeout, and normalized
    /// event state so the regular job UI can manage both transport styles.
    private var managedExecutorEvents: [UUID: [AgentExecutorEvent]] = [:]
    private var managedExecutorCancellations: [UUID: @Sendable () -> Void] = [:]
    private var managedExecutorTimeouts: [UUID: DispatchWorkItem] = [:]

    // MARK: - Spawn

    /// Start a background shell job. Returns the `AgentBackgroundJob`
    /// snapshot or throws if the process fails to launch (e.g. bad
    /// shell, permission denied).
    @discardableResult
    func start(
        command: String,
        workingDirectory: URL?,
        /// Extra writable roots for the seatbelt profile — the other folders
        /// of a multi-folder project. The foreground command path has carried
        /// these since projects grew multiple folders; background jobs
        /// dropped them, so an `npm install` that succeeded interactively
        /// hit EPERM the moment it ran as a job in a secondary folder.
        additionalWorkspaceRoots: [URL] = [],
        runtimeID: UUID,
        turnID: UUID? = nil,
        timeoutSeconds: Double?,
        sandboxMode: AgentSandboxMode = .readOnly,
        environment: [String: String]? = nil,
        runtimeDisplayName: String? = nil,
        runtimeIDForDisplay: UUID? = nil,
        remotePID: Int32? = nil,
        displayCommand: String? = nil,
        secretRedactionValues: [String] = [],
        lifetime: AgentBackgroundJobLifetime = .turn,
        goalPhaseID: String? = nil,
        automaticSandboxRetryApprovalSource: AgentToolApprovalSource? = nil
    ) throws -> AgentBackgroundJob {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentJobError.emptyCommand
        }
        let visibleCommand = (displayCommand ?? AgentSecretStore.redact(trimmed, secretValues: secretRedactionValues))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let id = UUID()
        let shortID = String(id.uuidString.prefix(6)).lowercased()
        let workingDirectoryPath = workingDirectory?.path
        if let turnID {
            originatingTurnIDs[id] = turnID
        }
        if sandboxMode != .escalated,
           let automaticSandboxRetryApprovalSource {
            sandboxRetrySpecifications[id] = AgentBackgroundSandboxRetrySpecification(
                command: trimmed,
                workingDirectory: workingDirectory,
                additionalWorkspaceRoots: additionalWorkspaceRoots,
                runtimeID: runtimeID,
                turnID: turnID,
                timeoutSeconds: timeoutSeconds,
                environment: environment,
                runtimeDisplayName: runtimeDisplayName,
                runtimeIDForDisplay: runtimeIDForDisplay,
                remotePID: remotePID,
                displayCommand: visibleCommand,
                secretRedactionValues: secretRedactionValues,
                sandboxMode: sandboxMode,
                approvalSource: automaticSandboxRetryApprovalSource,
                lifetime: lifetime,
                goalPhaseID: goalPhaseID
            )
        }

        let process = Process()
        let launch = AgentSandboxPolicy.shellLaunch(
            command: trimmed,
            mode: sandboxMode,
            rootDirectory: workingDirectory,
            additionalWorkspaceRoots: additionalWorkspaceRoots
        )
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.currentDirectoryURL = workingDirectory
        var processEnvironment = AgentSandboxPolicy.sandboxedEnvironment(
            mode: sandboxMode,
            rootDirectory: workingDirectory,
            command: trimmed,
            base: environment ?? AgentToolRunner.shellEnvironment()
        )
        processEnvironment["PWD"] = workingDirectory?.path
            ?? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        process.environment = processEnvironment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        AgentToolRunner.closeStandardInput(for: process)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = AgentJobOutputCollector(limit: Self.maxOutputBytes, secretRedactionValues: secretRedactionValues)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.append(data, stream: .stdout) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.append(data, stream: .stderr) }
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
                command: visibleCommand.isEmpty ? "[secret]" : visibleCommand,
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
                outputByteCount: 0,
                lifetime: lifetime,
                goalPhaseID: goalPhaseID
            )
            insertOrUpdate(job)
            collector.appendString(error.localizedDescription, stream: .stderr)
            processes[id] = AgentJobProcess(process: process, collector: collector)
            pendingCompletionEvents[runtimeID, default: []].append(id)
            return job
        }

        let pid = process.processIdentifier
        let startedAt = Date()
        let initial = AgentBackgroundJob(
            id: id,
            shortID: shortID,
            command: visibleCommand.isEmpty ? "[secret]" : visibleCommand,
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
            outputByteCount: 0,
            lifetime: lifetime,
            goalPhaseID: goalPhaseID
        )
        let processBox = AgentJobProcess(process: process, collector: collector)
        processes[id] = processBox
        insertOrUpdate(initial)
        processBox.startTrackingDescendants(on: Self.lifecycleQueue)

        // Optional hard timeout — same shape as the foreground
        // runCommand, but we don't throw on timeout; we mark the
        // job as .timedOut so the notification reads cleanly.
        if let timeoutSeconds, timeoutSeconds > 0 {
            let work = DispatchWorkItem { [weak processBox] in
                guard let processBox else { return }
                if processBox.process.isRunning {
                    processBox.markTimedOut()
                    AgentProcessSupport.terminateProcessTree(processBox.process)
                }
            }
            Self.lifecycleQueue.asyncAfter(
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
                processBox.stopTrackingAndTerminateDescendants()
                processBox.collector.append(
                    stdoutPipe.fileHandleForReading.availableData,
                    stream: .stdout
                )
                processBox.collector.append(
                    stderrPipe.fileHandleForReading.availableData,
                    stream: .stderr
                )
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

    /// Start a structured coding-agent process without `/bin/sh -c`.
    /// The prompt is written to stdin after launch and never appears in argv,
    /// job metadata, process listings, or approval previews.
    @discardableResult
    func startExecutor(
        specification: AgentExecutorProcessSpecification,
        runtimeID: UUID,
        turnID: UUID? = nil,
        timeoutSeconds: Double?,
        publishesCompletion: Bool = true,
        secretRedactionValues: [String] = []
    ) throws -> AgentBackgroundJob {
        let id = UUID()
        let shortID = String(id.uuidString.prefix(6)).lowercased()
        let workingDirectoryPath = specification.workingDirectory?.path
        if let turnID {
            originatingTurnIDs[id] = turnID
        }
        if !publishesCompletion {
            suppressedCompletionJobIDs.insert(id)
        }

        let process = Process()
        let launch = AgentSandboxPolicy.processLaunch(
            executableURL: specification.executableURL,
            arguments: specification.arguments,
            mode: specification.sandboxMode,
            rootDirectory: specification.workingDirectory,
            additionalWorkspaceRoots: specification.additionalWorkspaceRoots
        )
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.currentDirectoryURL = specification.workingDirectory
        var processEnvironment = AgentSandboxPolicy.sandboxedEnvironment(
            mode: specification.sandboxMode,
            rootDirectory: specification.workingDirectory,
            base: specification.environment
        )
        processEnvironment["PWD"] = specification.workingDirectory?.path
            ?? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        process.environment = processEnvironment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = AgentJobOutputCollector(
            limit: Self.maxOutputBytes,
            secretRedactionValues: secretRedactionValues
        )
        let eventCollector = AgentExecutorEventCollector(
            decoder: specification.decoder,
            secretRedactionValues: secretRedactionValues
        )
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collector.append(data, stream: .stdout)
            let events = eventCollector.append(data)
            guard !events.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.recordExecutorEvents(id: id, events: events)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                collector.append(data, stream: .stderr)
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                AgentProcessSupport.terminateProcessTree(process)
            }
            try? stdinPipe.fileHandleForWriting.close()
            let job = AgentBackgroundJob(
                id: id,
                shortID: shortID,
                command: specification.displayCommand,
                workingDirectoryPath: workingDirectoryPath,
                runtimeID: runtimeID,
                startedAt: Date(),
                pid: process.isRunning ? process.processIdentifier : -1,
                status: .launchFailed,
                exitCode: -1,
                finishedAt: Date(),
                outputByteCount: 0,
                executor: specification.executor,
                latestExecutorEvent: AgentExecutorEvent(
                    kind: .warning,
                    detail: AgentSecretStore.redact(
                        error.localizedDescription,
                        secretValues: secretRedactionValues
                    ),
                    status: .failed
                )
            )
            collector.appendString(error.localizedDescription, stream: .stderr)
            processes[id] = AgentJobProcess(
                process: process,
                collector: collector,
                executorEventCollector: eventCollector
            )
            insertOrUpdate(job)
            if publishesCompletion {
                pendingCompletionEvents[runtimeID, default: []].append(id)
            } else {
                suppressedCompletionJobIDs.remove(id)
            }
            return job
        }

        let initial = AgentBackgroundJob(
            id: id,
            shortID: shortID,
            command: specification.displayCommand,
            workingDirectoryPath: workingDirectoryPath,
            runtimeID: runtimeID,
            startedAt: Date(),
            pid: process.processIdentifier,
            status: .running,
            exitCode: nil,
            finishedAt: nil,
            outputByteCount: 0,
            executor: specification.executor
        )
        let processBox = AgentJobProcess(
            process: process,
            collector: collector,
            executorEventCollector: eventCollector
        )
        processes[id] = processBox
        insertOrUpdate(initial)

        if let timeoutSeconds, timeoutSeconds > 0 {
            let work = DispatchWorkItem { [weak processBox] in
                guard let processBox, processBox.process.isRunning else { return }
                processBox.markTimedOut()
                AgentProcessSupport.terminateProcessTree(processBox.process)
            }
            Self.lifecycleQueue.asyncAfter(
                deadline: .now() + timeoutSeconds,
                execute: work
            )
            processBox.timeoutWork = work
        }

        process.terminationHandler = { [weak self, weak processBox] proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if let processBox {
                processBox.timeoutWork?.cancel()
                let remainingOutput = stdoutPipe.fileHandleForReading.availableData
                processBox.collector.append(remainingOutput, stream: .stdout)
                let remainingEvents = processBox.executorEventCollector?.append(
                    remainingOutput,
                    flush: true
                ) ?? []
                processBox.collector.append(
                    stderrPipe.fileHandleForReading.availableData,
                    stream: .stderr
                )
                if !remainingEvents.isEmpty {
                    Task { @MainActor [weak self] in
                        self?.recordExecutorEvents(
                            id: id,
                            events: remainingEvents
                        )
                    }
                }
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
        let standardInput = specification.standardInput
        Self.lifecycleQueue.async { [weak self, weak processBox] in
            do {
                if !standardInput.isEmpty {
                    try stdinPipe.fileHandleForWriting.write(
                        contentsOf: standardInput
                    )
                }
                try stdinPipe.fileHandleForWriting.close()
            } catch {
                try? stdinPipe.fileHandleForWriting.close()
                guard let processBox, processBox.process.isRunning else { return }
                let detail = AgentSecretStore.redact(
                    error.localizedDescription,
                    secretValues: secretRedactionValues
                )
                processBox.collector.appendString(detail, stream: .stderr)
                let warning = AgentExecutorEvent(
                    kind: .warning,
                    detail: detail,
                    status: .failed
                )
                processBox.executorEventCollector?.append(warning)
                Task { @MainActor [weak self] in
                    self?.recordExecutorEvents(id: id, events: [warning])
                }
                AgentProcessSupport.terminateProcessTree(processBox.process)
            }
        }
        return initial
    }

    /// Register a bidirectional executor whose protocol driver owns its
    /// Process. Events, cancellation, timeout, and completion remain visible
    /// through the same job registry API as one-shot structured executors.
    @discardableResult
    func registerManagedExecutor(
        id: UUID = UUID(),
        executor: AgentExecutionAgent,
        displayCommand: String,
        workingDirectory: URL,
        runtimeID: UUID,
        turnID: UUID? = nil,
        timeoutSeconds: Double?,
        publishesCompletion: Bool,
        runtimeDisplayName: String? = nil,
        remoteRuntimeID: UUID? = nil,
        remotePID: Int32? = nil,
        cancellation: @escaping @Sendable () -> Void
    ) -> AgentBackgroundJob {
        if let turnID {
            originatingTurnIDs[id] = turnID
        }
        if !publishesCompletion {
            suppressedCompletionJobIDs.insert(id)
        }
        managedExecutorEvents[id] = []
        managedExecutorCancellations[id] = cancellation
        let job = AgentBackgroundJob(
            id: id,
            shortID: String(id.uuidString.prefix(6)).lowercased(),
            command: displayCommand,
            workingDirectoryPath: workingDirectory.path,
            runtimeID: runtimeID,
            runtimeDisplayName: runtimeDisplayName,
            remoteRuntimeID: remoteRuntimeID,
            remotePID: remotePID,
            startedAt: Date(),
            pid: remotePID ?? -1,
            status: .running,
            exitCode: nil,
            finishedAt: nil,
            outputByteCount: 0,
            executor: executor
        )
        insertOrUpdate(job)

        if let timeoutSeconds, timeoutSeconds > 0 {
            let work = DispatchWorkItem { [weak self] in
                cancellation()
                Task { @MainActor [weak self] in
                    self?.finishManagedExecutor(
                        id: id,
                        status: .timedOut,
                        exitCode: -1
                    )
                }
            }
            managedExecutorTimeouts[id] = work
            Self.lifecycleQueue.asyncAfter(
                deadline: .now() + timeoutSeconds,
                execute: work
            )
        }
        return job
    }

    func updateManagedExecutorProcess(id: UUID, pid: Int32) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].isAlive else {
            return
        }
        jobs[index].pid = pid
    }

    func recordManagedExecutorEvents(
        id: UUID,
        events: [AgentExecutorEvent]
    ) {
        guard !events.isEmpty,
              let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        var collected = managedExecutorEvents[id] ?? []
        collected.append(contentsOf: events)
        if collected.count > 2_000 {
            collected.removeFirst(collected.count - 2_000)
        }
        managedExecutorEvents[id] = collected
        var updated = jobs[index]
        applyExecutorEvents(events, to: &updated)
        updated.outputByteCount = managedExecutorOutput(
            events: collected
        ).utf8.count
        jobs[index] = updated
    }

    func recordExecutorNotice(id: UUID, detail: String) {
        guard let process = processes[id] else { return }
        let event = AgentExecutorEvent(
            kind: .warning,
            detail: detail,
            status: .running
        )
        process.executorEventCollector?.append(event)
        process.collector.appendString(detail + "\n", stream: .stderr)
        recordExecutorEvents(id: id, events: [event])
    }

    func finishManagedExecutor(
        id: UUID,
        status: AgentBackgroundJob.Status,
        exitCode: Int32
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].isAlive else {
            return
        }
        managedExecutorTimeouts.removeValue(forKey: id)?.cancel()
        managedExecutorCancellations.removeValue(forKey: id)
        var updated = jobs[index]
        let collectedEvents = managedExecutorEvents[id] ?? []
        applyExecutorEvents(collectedEvents, to: &updated)
        updated.status = status
        updated.exitCode = exitCode
        updated.finishedAt = Date()
        if updated.latestExecutorEvent?.kind != .finished {
            let eventStatus: AgentExecutorEventStatus
            switch status {
            case .completed: eventStatus = .completed
            case .killed: eventStatus = .cancelled
            case .running, .failed, .timedOut, .launchFailed:
                eventStatus = .failed
            }
            // 失败收尾时，别用无信息的 "exit N" 当合成完成事件的 detail——
            // executorResultText 会优先取最后一条 .finished 的 detail，那会把前面
            // 记着真实原因的 .warning 永久遮蔽，用户只看到 "exit -1"。这里失败时
            // 先从前面的 warning / 失败 message 里捞真实原因，捞不到才回落 exit 码。
            let failureReason: String? = eventStatus == .failed
                ? collectedEvents.reversed().first(where: { event in
                    (event.kind == .warning || event.kind == .message)
                        && (event.detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                })?.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            let finished = AgentExecutorEvent(
                kind: .finished,
                sessionID: updated.executorSessionID,
                detail: failureReason ?? "exit \(exitCode)",
                status: eventStatus
            )
            managedExecutorEvents[id, default: []].append(finished)
            updated.latestExecutorEvent = finished
        }
        updated.outputByteCount = managedExecutorOutput(
            events: managedExecutorEvents[id] ?? []
        ).utf8.count
        jobs[index] = updated

        let suppressCompletion = suppressedCompletionJobIDs.remove(id) != nil
        if !suppressCompletion {
            pendingCompletionEvents[updated.runtimeID, default: []].append(id)
            AgentToolApprovalNotifier.notifyJobFinished(job: updated)
            onJobFinished?(updated)
        }
    }

    // MARK: - Queries

    func jobs(forRuntime runtimeID: UUID) -> [AgentBackgroundJob] {
        jobs.filter { $0.runtimeID == runtimeID }
    }

    func jobs(inWorkspaceRoot root: URL) -> [AgentBackgroundJob] {
        let rootPath = root.standardizedFileURL.path
        return jobs.filter { job in
            guard let path = job.workingDirectoryPath else { return false }
            let jobPath = URL(fileURLWithPath: path).standardizedFileURL.path
            return jobPath == rootPath || jobPath.hasPrefix(rootPath + "/")
        }
    }

    func aliveJobs(forRuntime runtimeID: UUID) -> [AgentBackgroundJob] {
        jobs.filter { $0.runtimeID == runtimeID && $0.isAlive }
    }

    func hasProgressRelevantAliveJobs(forRuntime runtimeID: UUID) -> Bool {
        aliveJobs(forRuntime: runtimeID).contains {
            $0.lifetime == .turn || $0.lifetime == .goal
        }
    }

    /// Alive shell jobs created by one exact Agent turn. Older jobs in the
    /// same conversation — especially dev servers and watchers — are excluded.
    func aliveJobs(forRuntime runtimeID: UUID, originatingTurnID turnID: UUID) -> [AgentBackgroundJob] {
        jobs.filter {
            $0.runtimeID == runtimeID
                && $0.isAlive
                && originatingTurnIDs[$0.id] == turnID
        }
    }

    func job(id: UUID) -> AgentBackgroundJob? {
        jobs.first(where: { $0.id == id })
    }

    #if DEBUG
    func replaceJobsForTesting(_ jobs: [AgentBackgroundJob]) {
        self.jobs = jobs
    }
    #endif

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
    func output(
        id: UUID,
        stream: AgentJobOutputStream = .combined,
        tailLines: Int? = nil
    ) -> String {
        let full: String
        if let proc = processes[id] {
            full = proc.collector.stringValue(for: stream)
        } else {
            switch stream {
            case .combined, .stdout:
                full = managedExecutorOutput(
                    events: managedExecutorEvents[id] ?? []
                )
            case .stderr:
                full = ""
            }
        }
        guard let tailLines, tailLines > 0 else { return full }
        let normalized = full.hasSuffix("\n") ? String(full.dropLast()) : full
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= tailLines { return full }
        return lines.suffix(tailLines).joined(separator: "\n")
    }

    func executorEvents(id: UUID) -> [AgentExecutorEvent] {
        processes[id]?.executorEventCollector?.snapshot
            ?? managedExecutorEvents[id]
            ?? []
    }

    func executorResultText(id: UUID) -> String {
        let events = executorEvents(id: id)
        if let final = events.reversed().first(where: {
            $0.kind == .finished
                && $0.detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        })?.detail {
            return final.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let messages = events.compactMap { event -> String? in
            guard (event.kind == .message && event.status != .running)
                    || event.kind == .warning else {
                return nil
            }
            return event.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if !messages.isEmpty {
            return messages.joined(separator: "\n\n")
        }
        return output(id: id)
    }

    // MARK: - Lifecycle ops

    /// Send SIGTERM (then SIGKILL after 2s) to a running job.
    /// Returns true if a process was actually signaled.
    @discardableResult
    func kill(id: UUID) -> Bool {
        if let proc = processes[id], proc.process.isRunning {
            proc.markExplicitKill()
            AgentProcessSupport.terminateProcessTree(proc.process)
            return true
        }
        guard let cancellation = managedExecutorCancellations[id],
              jobs.first(where: { $0.id == id })?.isAlive == true else {
            return false
        }
        cancellation()
        finishManagedExecutor(id: id, status: .killed, exitCode: SIGTERM)
        return true
    }

    /// Stop-cleanup variant: same TERM→KILL lifecycle, but without creating a
    /// background completion that wakes the just-stopped conversation.
    @discardableResult
    func killForStoppedTurn(id: UUID) -> Bool {
        suppressedCompletionJobIDs.insert(id)
        guard kill(id: id) else {
            suppressedCompletionJobIDs.remove(id)
            return false
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

    /// Lifecycle cleanup is intentionally quiet: the phase-transition turn
    /// already explains why the server ended, so no completion event should
    /// wake another model round merely to announce SIGTERM.
    @discardableResult
    func killAllAlive(forRuntime runtimeID: UUID, phaseID: String) -> Int {
        let targets = aliveJobs(forRuntime: runtimeID).filter {
            $0.lifetime == .phase && $0.goalPhaseID == phaseID
        }
        for job in targets {
            _ = killForStoppedTurn(id: job.id)
        }
        return targets.count
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

    /// Mark one completion event as already surfaced by a host-side
    /// UI path. Other pending jobs for the same runtime stay queued for
    /// the normal next-turn notification path.
    func markCompletionSurfaced(id: UUID, forRuntime runtimeID: UUID) {
        guard var ids = pendingCompletionEvents[runtimeID] else { return }
        ids.removeAll { $0 == id }
        if ids.isEmpty {
            pendingCompletionEvents.removeValue(forKey: runtimeID)
        } else {
            pendingCompletionEvents[runtimeID] = ids
        }
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

    private func recordExecutorEvents(
        id: UUID,
        events: [AgentExecutorEvent]
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        var updated = jobs[index]
        applyExecutorEvents(events, to: &updated)
        updated.outputByteCount = processes[id]?.collector.byteCount ?? 0
        jobs[index] = updated
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
            managedExecutorEvents.removeValue(forKey: entry.element.id)
            managedExecutorCancellations.removeValue(forKey: entry.element.id)
            managedExecutorTimeouts.removeValue(forKey: entry.element.id)?.cancel()
            originatingTurnIDs.removeValue(forKey: entry.element.id)
            suppressedCompletionJobIDs.remove(entry.element.id)
            sandboxRetrySpecifications.removeValue(forKey: entry.element.id)
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
        let collectedEvents = processes[id]?.executorEventCollector?.snapshot ?? []
        applyExecutorEvents(collectedEvents, to: &updated)
        let providerFinishedStatus = collectedEvents.reversed().first {
            $0.kind == .finished
        }?.status
        updated.finishedAt = Date()
        updated.exitCode = exitCode
        if wasKilled {
            updated.status = .killed
        } else if didTimeOut {
            updated.status = .timedOut
        } else if providerFinishedStatus == .failed {
            updated.status = .failed
        } else if providerFinishedStatus == .cancelled {
            updated.status = .killed
        } else if exitCode == 0 {
            updated.status = .completed
        } else {
            updated.status = .failed
        }
        updated.outputByteCount = processes[id]?.collector.byteCount ?? 0
        if updated.latestExecutorEvent?.kind != .finished {
            let status: AgentExecutorEventStatus
            if wasKilled {
                status = .cancelled
            } else if didTimeOut || exitCode != 0 {
                status = .failed
            } else {
                status = .completed
            }
            let finished = AgentExecutorEvent(
                kind: .finished,
                sessionID: updated.executorSessionID,
                detail: "exit \(exitCode)",
                status: status
            )
            processes[id]?.executorEventCollector?.append(finished)
            updated.latestExecutorEvent = finished
        }
        jobs[index] = updated

        if updated.status == .failed,
           let specification = sandboxRetrySpecifications.removeValue(forKey: id),
           let output = processes[id]?.collector.stringValue(for: .combined),
           AgentSandboxPolicy.looksLikeSandboxDenial(
               exitStatus: exitCode,
               output: output,
               sandboxMode: specification.sandboxMode
           ),
           let retry = try? start(
               command: specification.command,
               workingDirectory: specification.workingDirectory,
               additionalWorkspaceRoots: specification.additionalWorkspaceRoots,
               runtimeID: specification.runtimeID,
               turnID: specification.turnID,
               timeoutSeconds: specification.timeoutSeconds,
               sandboxMode: .escalated,
               environment: specification.environment,
               runtimeDisplayName: specification.runtimeDisplayName,
               runtimeIDForDisplay: specification.runtimeIDForDisplay,
               remotePID: specification.remotePID,
               displayCommand: specification.displayCommand,
               secretRedactionValues: specification.secretRedactionValues,
               lifetime: specification.lifetime,
               goalPhaseID: specification.goalPhaseID,
               automaticSandboxRetryApprovalSource: nil
           ) {
            processes[id]?.collector.appendString(
                "\n[WillDeep] Sandbox denial detected; automatically retried outside the sandbox as \(retry.displayHandle).\n",
                stream: .stderr
            )
            AgentSandboxAuditLog.append(
                toolName: "run_command",
                arguments: [
                    "command": .string(specification.displayCommand ?? "[redacted]")
                ],
                decision: AgentSandboxDecision(
                    mode: .escalated,
                    requiresUserApproval: false,
                    requiresTypedConfirmation: false,
                    reason: L10n.ToolCard.sandboxEscalationAutomaticApprovalReason,
                    prefixRule: nil
                ),
                approvalSource: specification.approvalSource,
                outcome: "background_sandbox_escalation_retry"
            )
            // Only the escalated replay wakes the model. Surfacing this
            // intermediate EPERM as a terminal failure would let an
            // unattended node declare itself blocked while recovery is live.
            suppressedCompletionJobIDs.remove(id)
            return
        }
        sandboxRetrySpecifications.removeValue(forKey: id)

        let suppressCompletion = suppressedCompletionJobIDs.remove(id) != nil
        if !suppressCompletion {
            pendingCompletionEvents[updated.runtimeID, default: []].append(id)
            AgentToolApprovalNotifier.notifyJobFinished(job: updated)
            onJobFinished?(updated)
        }
    }

    private func applyExecutorEvents(
        _ events: [AgentExecutorEvent],
        to job: inout AgentBackgroundJob
    ) {
        for event in events {
            if event.kind == .sessionStarted, let sessionID = event.sessionID {
                job.executorSessionID = sessionID
            }
            if let usage = event.usage, event.kind == .usage || event.kind == .finished {
                job.executorUsage = usage
            }
            if event.kind != .raw && event.kind != .usage {
                job.latestExecutorEvent = event
            }
        }
    }

    private func managedExecutorOutput(
        events: [AgentExecutorEvent]
    ) -> String {
        let lines = events.compactMap { event -> String? in
            let detail = event.detail?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty {
                return detail
            }
            let title = event.title?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let title, !title.isEmpty {
                return title
            }
            return nil
        }
        let output = lines.joined(separator: "\n")
        guard output.utf8.count > Self.maxOutputBytes else {
            return output
        }
        return String(output.suffix(Self.maxOutputBytes)) + "\n...[truncated]"
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
    let executorEventCollector: AgentExecutorEventCollector?
    var timeoutWork: DispatchWorkItem?
    private let stateLock = NSLock()
    private var _didTimeOut = false
    private var _didExplicitKill = false
    private var descendantTimer: DispatchSourceTimer?
    private var trackedDescendants: [pid_t: AgentProcessSupport.ProcessIdentity] = [:]

    init(
        process: Process,
        collector: AgentJobOutputCollector,
        executorEventCollector: AgentExecutorEventCollector? = nil
    ) {
        self.process = process
        self.collector = collector
        self.executorEventCollector = executorEventCollector
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

    func startTrackingDescendants(on queue: DispatchQueue) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(250),
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            guard let self, self.process.processIdentifier > 0 else { return }
            let identities = AgentProcessSupport.descendantProcessIdentities(
                of: self.process.processIdentifier
            )
            self.stateLock.lock()
            for identity in identities {
                self.trackedDescendants[identity.pid] = identity
            }
            self.stateLock.unlock()
        }
        stateLock.lock()
        descendantTimer = timer
        stateLock.unlock()
        timer.resume()
    }

    func stopTrackingAndTerminateDescendants() {
        stateLock.lock()
        let timer = descendantTimer
        descendantTimer = nil
        let identities = Array(trackedDescendants.values)
        trackedDescendants.removeAll()
        stateLock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
        AgentProcessSupport.terminateProcessIdentities(identities)
    }
}

private nonisolated final class AgentExecutorEventCollector: @unchecked Sendable {
    private static let eventLimit = 2_000
    private let decoder: any AgentExecutorEventDecoding
    private let secretRedactionValues: [String]
    private let lock = NSLock()
    private var buffer = Data()
    private var events: [AgentExecutorEvent] = []

    init(
        decoder: any AgentExecutorEventDecoding,
        secretRedactionValues: [String]
    ) {
        self.decoder = decoder
        self.secretRedactionValues = secretRedactionValues
    }

    func append(_ data: Data, flush: Bool = false) -> [AgentExecutorEvent] {
        guard !data.isEmpty || flush else { return [] }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var decoded: [AgentExecutorEvent] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            guard let line = String(data: lineData, encoding: .utf8),
                  !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            decoded.append(contentsOf: decoder.decode(line: line).map(redacted))
        }
        if flush, !buffer.isEmpty {
            if let line = String(data: buffer, encoding: .utf8),
               !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                decoded.append(contentsOf: decoder.decode(line: line).map(redacted))
            }
            buffer.removeAll(keepingCapacity: true)
        }
        appendLocked(decoded)
        return decoded
    }

    func append(_ event: AgentExecutorEvent) {
        lock.lock()
        appendLocked([event])
        lock.unlock()
    }

    var snapshot: [AgentExecutorEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    private func appendLocked(_ values: [AgentExecutorEvent]) {
        guard !values.isEmpty else { return }
        events.append(contentsOf: values)
        if events.count > Self.eventLimit {
            events.removeFirst(events.count - Self.eventLimit)
        }
    }

    private func redacted(_ event: AgentExecutorEvent) -> AgentExecutorEvent {
        func text(_ value: String?) -> String? {
            value.map {
                AgentSecretStore.redact(
                    $0,
                    secretValues: secretRedactionValues
                )
            }
        }
        var output = event
        output.sessionID = text(event.sessionID)
        output.itemID = text(event.itemID)
        output.parentID = text(event.parentID)
        output.title = text(event.title)
        output.detail = text(event.detail)
        output.toolName = text(event.toolName)
        output.filePath = text(event.filePath)
        output.rawJSON = text(event.rawJSON)
        return output
    }
}

/// Thread-safe rolling output buffer with a byte cap — same shape as
/// the foreground `CommandOutputCollector` but reusable across job
/// lifetimes and exposed for tail-reads.
private nonisolated final class AgentJobOutputCollector: @unchecked Sendable {
    private let limit: Int
    private let secretRedactionValues: [String]
    private let lock = NSLock()
    private var combinedData = Data()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var combinedTruncated = false
    private var stdoutTruncated = false
    private var stderrTruncated = false

    init(limit: Int, secretRedactionValues: [String] = []) {
        self.limit = limit
        self.secretRedactionValues = secretRedactionValues
    }

    func append(_ chunk: Data, stream: AgentJobOutputStream) {
        guard !chunk.isEmpty else { return }
        if !secretRedactionValues.isEmpty,
           let text = String(data: chunk, encoding: .utf8) {
            let redacted = AgentSecretStore.redact(text, secretValues: secretRedactionValues)
            guard let bytes = redacted.data(using: .utf8) else { return }
            appendRaw(bytes, stream: stream)
            return
        }
        appendRaw(chunk, stream: stream)
    }

    private func appendRaw(_ chunk: Data, stream: AgentJobOutputStream) {
        lock.lock(); defer { lock.unlock() }
        Self.appendBounded(
            chunk,
            to: &combinedData,
            truncated: &combinedTruncated,
            limit: limit
        )
        switch stream {
        case .combined:
            break
        case .stdout:
            Self.appendBounded(
                chunk,
                to: &stdoutData,
                truncated: &stdoutTruncated,
                limit: limit
            )
        case .stderr:
            Self.appendBounded(
                chunk,
                to: &stderrData,
                truncated: &stderrTruncated,
                limit: limit
            )
        }
    }

    private static func appendBounded(
        _ chunk: Data,
        to destination: inout Data,
        truncated: inout Bool,
        limit: Int
    ) {
        let remaining = max(0, limit - destination.count)
        if remaining > 0 {
            destination.append(chunk.prefix(remaining))
        }
        if chunk.count > remaining {
            truncated = true
        }
    }

    func appendString(
        _ s: String,
        stream: AgentJobOutputStream = .combined
    ) {
        guard let bytes = s.data(using: .utf8) else { return }
        append(bytes, stream: stream)
    }

    var byteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return combinedData.count
    }

    func stringValue(for stream: AgentJobOutputStream) -> String {
        lock.lock()
        let snapshot: Data
        let didTruncate: Bool
        switch stream {
        case .combined:
            snapshot = combinedData
            didTruncate = combinedTruncated
        case .stdout:
            snapshot = stdoutData
            didTruncate = stdoutTruncated
        case .stderr:
            snapshot = stderrData
            didTruncate = stderrTruncated
        }
        lock.unlock()
        var text = String(data: snapshot, encoding: .utf8) ?? ""
        if didTruncate { text += "\n...[truncated]" }
        return AgentSecretStore.redact(text, secretValues: secretRedactionValues)
    }
}
