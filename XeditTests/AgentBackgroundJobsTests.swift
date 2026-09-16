//
//  AgentBackgroundJobsTests.swift
//  XeditTests
//
//  Covers the background `run_command` substrate introduced in 1.57:
//  `AgentBackgroundJob` schema invariants, `AgentJobRegistry`
//  lifecycle (spawn / kill / timeout), output capture + tail, the
//  per-runtime isolation that keeps two concurrent sessions from
//  stealing each other's completion notifications, and the
//  `<background-task-notification>` notice text the agent loop pushes
//  into history.
//
//  These tests spawn real `/bin/sh -c` processes — there is no fake
//  Process indirection — so they need a polling wait helper to bridge
//  the gap between "registry.start() returned" and "terminationHandler
//  has run and updated state on the main actor". 5s timeout is enough
//  for any of the test scripts (`true`, `echo hello`, `printf`) and
//  forgiving enough to survive a loaded CI box. Long-running samples
//  install a TERM trap so the test is about registry state, not shell
//  child-process shutdown quirks.
//

import Testing
import Foundation
import AppKit
import SwiftUI
@testable import WillDeep

@Suite
@MainActor
struct AgentBackgroundJobsTests {

    // MARK: - Pure schema / formatting

    /// Status raw values are part of the in-memory contract the agent
    /// loop's completion-notice helper renders into the system message
    /// the model reads. Renaming a case silently here would change the
    /// observable text in `<background-task-notification>` blocks and
    /// could confuse models trained on prior versions. Lock them in.
    @Test
    func statusRawValuesAreStable() {
        #expect(AgentBackgroundJob.Status.running.rawValue == "running")
        #expect(AgentBackgroundJob.Status.completed.rawValue == "completed")
        #expect(AgentBackgroundJob.Status.failed.rawValue == "failed")
        #expect(AgentBackgroundJob.Status.killed.rawValue == "killed")
        #expect(AgentBackgroundJob.Status.timedOut.rawValue == "timedOut")
        #expect(AgentBackgroundJob.Status.launchFailed.rawValue == "launchFailed")
        #expect(AgentBackgroundJobLifetime.turn.rawValue == "turn")
        #expect(AgentBackgroundJobLifetime.phase.rawValue == "phase")
        #expect(AgentBackgroundJobLifetime.goal.rawValue == "goal")
        #expect(AgentBackgroundJobLifetime.persistent.rawValue == "persistent")
    }

    /// `displayHandle` is the user- and model-facing short id. The
    /// model is told in the system prompt + tool descriptions to call
    /// `get_job_output(job_id: "job_xxxxxx")` — so the prefix MUST be
    /// the literal "job_" and the body must be exactly 6 lowercase
    /// hex chars derived from the UUID. Anything else and the
    /// `matchingHandle` resolver below stops finding things.
    @Test
    func displayHandleHasJobPrefixAndSixCharBody() async throws {
        let registry = AgentJobRegistry()
        let runtimeID = UUID()
        let job = try registry.start(
            command: "true",
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil
        )
        #expect(job.displayHandle.hasPrefix("job_"))
        #expect(job.shortID.count == 6)
        #expect(job.shortID == job.shortID.lowercased())
        #expect(job.displayHandle == "job_\(job.shortID)")
        // Drain to avoid leaking the running process into later tests.
        _ = await waitUntilFinished(registry: registry, id: job.id)
    }

    /// `isAlive` is computed from `status` and is the predicate the
    /// drawer + agent loop alive-check both use. A drift here would
    /// either leave killed jobs forever "alive" in the UI or cause the
    /// loop to think a finished job is still pending.
    @Test
    func isAliveOnlyMirrorsRunningStatus() {
        for (status, expectedAlive) in [
            (AgentBackgroundJob.Status.running, true),
            (.completed, false),
            (.failed, false),
            (.killed, false),
            (.timedOut, false),
            (.launchFailed, false)
        ] {
            let job = makeStubJob(status: status)
            #expect(job.isAlive == expectedAlive, "status \(status.rawValue) should be alive=\(expectedAlive)")
        }
    }

    /// Only failure-like terminal states should be treated as
    /// attention-worthy. A user-initiated kill is visible in the
    /// monitor, but should not be dressed up as an unexpected failure.
    @Test
    func attentionStatusesOnlyCoverFailuresAndTimeouts() {
        for (status, expectedAttention) in [
            (AgentBackgroundJob.Status.running, false),
            (.completed, false),
            (.failed, true),
            (.killed, false),
            (.timedOut, true),
            (.launchFailed, true)
        ] {
            let job = makeStubJob(status: status)
            #expect(job.needsAttention == expectedAttention, "status \(status.rawValue) should needAttention=\(expectedAttention)")
        }
    }

    /// Clicking a job in the task monitor pre-fills the composer with
    /// the model-facing output tool call. Keep that generated prompt
    /// anchored to the stable handle and tool name.
    @Test
    func inspectionPromptIncludesHandleAndOutputToolCall() {
        let prompt = L10n.AgentJobs.inspectOutputPrompt("job_ab12cd")
        #expect(prompt.contains("job_ab12cd"))
        #expect(prompt.contains("get_job_output"))
        #expect(prompt.contains("job_id"))
    }

    @Test
    func taskManagerExtractsProcessNameAfterEnvironmentAssignments() {
        let process = AgentBackgroundTaskPresentation.processName(
            command: "env CI=1 SDKROOT=macosx /usr/bin/xcodebuild test"
        )

        #expect(process == "xcodebuild")
    }

    @Test
    func taskManagerFiltersBySessionStatusAndQuery() {
        let activeRuntimeID = UUID()
        let running = makeStubJob(
            command: "yarn test",
            workingDirectoryPath: "/tmp/current",
            runtimeID: activeRuntimeID
        )
        let finished = makeStubJob(
            command: "go test ./...",
            status: .completed,
            finishedAfter: 2,
            workingDirectoryPath: "/tmp/other",
            runtimeID: UUID()
        )

        let runningRow = AgentBackgroundTaskRow(job: running)
        let finishedRow = AgentBackgroundTaskRow(job: finished)

        #expect(AgentBackgroundTaskPresentation.matches(
            job: runningRow.job,
            processName: runningRow.processName,
            activeSessionID: activeRuntimeID,
            scope: .currentSession,
            status: .running,
            query: "yarn"
        ))
        #expect(!AgentBackgroundTaskPresentation.matches(
            job: finishedRow.job,
            processName: finishedRow.processName,
            activeSessionID: activeRuntimeID,
            scope: .currentSession,
            status: .all,
            query: ""
        ))
        #expect(AgentBackgroundTaskPresentation.matches(
            job: finishedRow.job,
            processName: finishedRow.processName,
            activeSessionID: activeRuntimeID,
            scope: .allSessions,
            status: .finished,
            query: "/tmp/other"
        ))
    }

    /// The row carries the derived process name so `matches` and every card
    /// body stop re-splitting the command line on each rebuild.
    @Test
    func taskRowDerivesProcessNameOnce() {
        let job = makeStubJob(command: "env CI=1 /usr/bin/xcodebuild test")
        let row = AgentBackgroundTaskRow(job: job)

        #expect(row.processName == "xcodebuild")
        #expect(row.id == job.id)
        #expect(row.processName == AgentBackgroundTaskPresentation.processName(command: job.command))
    }

    /// The panel used to run `filter` twice over the same array to split
    /// running from finished. One pass, same ordering within each bucket.
    @Test
    func taskRowPartitionSplitsInOnePassPreservingOrder() {
        let firstRunning = makeStubJob(command: "yarn test")
        let done = makeStubJob(command: "go test ./...", status: .completed, finishedAfter: 2)
        let secondRunning = makeStubJob(command: "swift build")

        let split = AgentBackgroundTaskRow.partitioned(
            [firstRunning, done, secondRunning].map(AgentBackgroundTaskRow.init(job:))
        )

        #expect(split.running.map(\.id) == [firstRunning.id, secondRunning.id])
        #expect(split.finished.map(\.id) == [done.id])
    }

    /// The composer bar reports work in flight, not history. No live job means
    /// no bar at all — it must not linger summarizing finished tasks.
    @Test
    func composerCardOnlyAppearsWhileSomethingIsRunning() {
        #expect(!AgentBackgroundTaskComposerCardVisibility.shouldShow(runningJobCount: 0))
        #expect(AgentBackgroundTaskComposerCardVisibility.shouldShow(runningJobCount: 1))
        #expect(AgentBackgroundTaskComposerCardVisibility.shouldShow(runningJobCount: 7))
    }

    /// 1.272.0-rc14 摘掉了状态条上「打开后台任务面板」的入口,因为调度台
    /// 会话点开只有空面板——但它把普通会话的入口一并摘了。入口是否存在只看
    /// 会话作用域,与运行中任务数无关。
    @Test
    func composerCardOpensManagerOutsideDispatchBoard() {
        #expect(AgentBackgroundTaskComposerCardVisibility.allowsOpeningManager(presentationScope: .workspace))
        #expect(AgentBackgroundTaskComposerCardVisibility.allowsOpeningManager(presentationScope: .roundtable))
        #expect(!AgentBackgroundTaskComposerCardVisibility.allowsOpeningManager(presentationScope: .dispatchBoard))
    }

    /// The summary counts only running jobs. It used to lead with a total that
    /// folded in finished ones ("7 background tasks · 1 running").
    @Test
    func composerSummaryCountsOnlyRunningJobs() {
        #expect(L10n.AgentJobs.composerRunningSummary(1).contains("1"))
        #expect(!L10n.AgentJobs.composerRunningSummary(1).contains("7"))
    }

    @Test
    func durationFormattingRollsUpSecondsAndMinutes() {
        #expect(AgentBackgroundTaskPresentation.formatDuration(-5) == "0s")
        #expect(AgentBackgroundTaskPresentation.formatDuration(42) == "42s")
        #expect(AgentBackgroundTaskPresentation.formatDuration(90) == "1m 30s")
        #expect(AgentBackgroundTaskPresentation.formatDuration(3661) == "1h 1m")
    }

    /// Empty / whitespace-only commands are rejected at the registry
    /// boundary — runCommand never makes it to the Process. The error
    /// is the typed `.emptyCommand`, not a generic launch failure,
    /// so the call site can route it through the right surface.
    @Test
    func emptyCommandThrowsTypedError() {
        let registry = AgentJobRegistry()
        #expect(throws: AgentJobError.self) {
            _ = try registry.start(
                command: "   \n\t  ",
                workingDirectory: nil,
                runtimeID: UUID(),
                timeoutSeconds: nil
            )
        }
    }

    /// The kill_job tool path throws `.jobNotFound` when the model
    /// hands it a handle that doesn't match anything in this runtime.
    /// We assert against the registry's `job(matchingHandle:)` lookup
    /// because that's the same predicate the tool wires into — same
    /// negative space.
    @Test
    func matchingHandleReturnsNilForUnknown() {
        let registry = AgentJobRegistry()
        #expect(registry.job(matchingHandle: "job_zzzzzz", runtimeID: UUID()) == nil)
        #expect(registry.job(matchingHandle: "garbage", runtimeID: UUID()) == nil)
    }

    /// Dev Server is a workspace-level surface: two Agent sessions in
    /// the same repository should see and control the same port-holding
    /// background jobs instead of each session pretending it owns a
    /// separate server list.
    @Test
    func workspaceJobQueryIncludesNestedJobsAcrossRuntimes() {
        let registry = AgentJobRegistry()
        let root = URL(fileURLWithPath: "/tmp/willdeep-dev-root").standardizedFileURL
        let frontend = makeStubJob(
            command: "yarn dev",
            workingDirectoryPath: root.appendingPathComponent("web").path,
            runtimeID: UUID()
        )
        let backend = makeStubJob(
            command: "go run .",
            workingDirectoryPath: root.path,
            runtimeID: UUID()
        )
        let sibling = makeStubJob(
            command: "yarn dev",
            workingDirectoryPath: "/tmp/willdeep-dev-root-other",
            runtimeID: UUID()
        )
        registry.replaceJobsForTesting([frontend, backend, sibling])

        let jobs = registry.jobs(inWorkspaceRoot: root)

        #expect(jobs.map(\.id).contains(frontend.id))
        #expect(jobs.map(\.id).contains(backend.id))
        #expect(jobs.map(\.id).contains(sibling.id) == false)
    }

    /// The completion notice that goes into history is the only way
    /// the model learns about a finished background job. Verify the
    /// rendered text carries every piece the model needs to act:
    /// handle, command, status, exit code, output hint.
    @Test
    func completionNoticeIncludesAllFields() {
        var job = makeStubJob(
            command: "npm test",
            status: .completed,
            exitCode: 0,
            finishedAfter: 12.9,
            outputByteCount: 432
        )

        let notice = AppState.backgroundJobCompletionNotice(
            for: job,
            recentOutput: "ok\n",
            outputPath: "/tmp/jobs/\(job.displayHandle)/output.log",
            omittedBytes: 7
        )
        #expect(notice == """
        <background-task-notification>
        id: \(job.displayHandle)
        kind: shell
        label: npm test
        status: completed
        exit_code: 0
        duration: 12s
        output_path: /tmp/jobs/\(job.displayHandle)/output.log
        stderr_path: none
        omitted_bytes: 7
        output_tail (last 10 lines, secrets redacted):
        ```text
        ok
        ```
        </background-task-notification>
        """)

        job.label = "运行前端测试"
        #expect(AppState.backgroundJobCompletionNotice(for: job).contains("label: 运行前端测试\n"))
    }

    /// A job with no captured output renders the contract's empty tail
    /// marker, and a host without a log file reports `output_path: none`.
    @Test
    func completionNoticeRendersEmptyTailWhenNoOutput() {
        let job = makeStubJob(
            command: "true",
            status: .completed,
            exitCode: 0,
            finishedAfter: 1,
            outputByteCount: 0
        )

        let notice = AppState.backgroundJobCompletionNotice(for: job)
        #expect(notice.contains("output_path: none\n"))
        #expect(notice.contains("output_tail: (empty)\n"))
        #expect(notice.contains("output_tail (") == false)
    }

    /// Failed jobs (e.g. a backgrounded `docker build`) inline a tail of
    /// recent output so the model can diagnose *why* it failed in the same
    /// turn, instead of burning a round on get_job_output.
    @Test
    func completionNoticeInlinesRecentOutputForFailure() {
        let job = makeStubJob(
            command: "docker build .",
            status: .failed,
            exitCode: 1,
            finishedAfter: 3_725,
            outputByteCount: 2048
        )

        let notice = AppState.backgroundJobCompletionNotice(
            for: job,
            recentOutput: "Step 7/9 : RUN make\nmake: *** [build] Error 2"
        )
        #expect(notice.contains("status: failed\nexit_code: 1\nduration: 1h2m5s\n"))
        #expect(notice.contains("output_tail (last 40 lines, secrets redacted):\n```text\nStep 7/9"))
        #expect(notice.contains("make: *** [build] Error 2\n```"))
    }

    /// Host-side states map onto the contract's snake_case statuses: a lost
    /// monitoring channel is a failure, a launch failure has no exit code,
    /// and executor jobs expose their reusable session on one extra line.
    @Test
    func completionNoticeMapsHostStatesOntoContract() {
        var timedOut = makeStubJob(status: .timedOut, exitCode: 15, finishedAfter: 2)
        #expect(AppState.backgroundJobCompletionNotice(for: timedOut).contains("status: timed_out\n"))
        timedOut.monitoringFailure = "stream lost"
        #expect(AppState.backgroundJobCompletionNotice(for: timedOut).contains("status: failed\n"))

        let launchFailed = makeStubJob(status: .launchFailed, exitCode: -1, finishedAfter: 0)
        let launchNotice = AppState.backgroundJobCompletionNotice(for: launchFailed)
        #expect(launchNotice.contains("status: launch_failed\nexit_code: unknown\nduration: 0s\n"))

        let running = makeStubJob(status: .running)
        #expect(AppState.backgroundJobCompletionNotice(for: running).contains("status: vanished\n"))
        #expect(AppState.backgroundJobCompletionNotice(for: running).contains("duration: unknown\n"))

        var executor = makeStubJob(status: .completed, exitCode: 0, finishedAfter: 3)
        executor.executor = .codexCLI
        executor.executorSessionID = "session-123"
        let executorNotice = AppState.backgroundJobCompletionNotice(for: executor)
        #expect(executorNotice.contains("kind: executor\n"))
        #expect(executorNotice.contains("omitted_bytes: 0\nsession: codexCLI session-123\n"))
    }

    /// The tail the agent loop inlines is run through
    /// `AgentSandboxPolicy.scrub` first — that's the layer that keeps
    /// tokens/keys out of persisted model history. Pin the contract so a
    /// refactor can't silently drop the redaction step.
    @Test
    func scrubRedactsSecretsBeforeInlining() {
        let raw = "fatal: push rejected\ntoken=ghp_0123456789abcdefghij0123456789"
        let scrubbed = AgentSandboxPolicy.scrub(raw)
        #expect(scrubbed.contains("[REDACTED]"))
        #expect(scrubbed.contains("ghp_0123456789abcdefghij0123456789") == false)
    }

    // MARK: - Lifecycle (real /bin/sh)

    /// End-to-end: a trivial `true` command exits 0 quickly, the
    /// terminationHandler hops back to the main actor, the job
    /// flips to `.completed`, and a completion event lands in the
    /// per-runtime pending queue. This is the load-bearing happy
    /// path the entire feature rests on.
    @Test
    func echoCommandCompletesWithExitZero() async throws {
        let registry = AgentJobRegistry()
        let runtimeID = UUID()
        let job = try registry.start(
            command: "true",
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil
        )

        let finished = await waitUntilFinished(registry: registry, id: job.id)
        #expect(finished)
        let updated = registry.job(id: job.id)
        #expect(updated?.status == .completed)
        #expect(updated?.exitCode == 0)

        let pending = registry.consumePendingCompletions(forRuntime: runtimeID)
        #expect(pending.count == 1)
        #expect(pending.first?.id == job.id)
        // Drained — second consume MUST be empty so the agent loop
        // doesn't double-inject the same notice.
        #expect(registry.consumePendingCompletions(forRuntime: runtimeID).isEmpty)
    }

    /// 多文件夹项目：后台任务的 seatbelt 必须把项目的其余文件夹也当可写根。
    /// 此前 `AgentJobRegistry.start` 根本没有这个参数，前台命令能写的
    /// 第二个文件夹，后台 `npm install` 直接 EPERM。
    ///
    /// 两个目录都放在 /tmp 下——profile 的固定放行清单里有
    /// `FileManager.temporaryDirectory`（$TMPDIR），放那儿的"第二个根"
    /// 不加参数也能写，测了等于没测。
    @Test
    func backgroundJobWritesIntoAdditionalProjectRoot() async throws {
        let fm = FileManager.default
        let primary = URL(fileURLWithPath: "/tmp/willdeep-bg-primary-\(UUID().uuidString.prefix(6))")
        let secondary = URL(fileURLWithPath: "/tmp/willdeep-bg-secondary-\(UUID().uuidString.prefix(6))")
        try fm.createDirectory(at: primary, withIntermediateDirectories: true)
        try fm.createDirectory(at: secondary, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: primary)
            try? fm.removeItem(at: secondary)
        }
        let target = secondary.appendingPathComponent("generated.txt")

        let registry = AgentJobRegistry()
        let job = try registry.start(
            command: "touch '\(target.path)'",
            workingDirectory: primary,
            additionalWorkspaceRoots: [secondary],
            runtimeID: UUID(),
            timeoutSeconds: nil,
            sandboxMode: .workspaceWrite
        )

        #expect(await waitUntilFinished(registry: registry, id: job.id))
        #expect(registry.job(id: job.id)?.status == .completed)
        #expect(fm.fileExists(atPath: target.path))
    }

    /// 负向对照：不带 additionalWorkspaceRoots 时同一条写入必须被沙箱拦下。
    /// 没有这条，上面的正向用例在"seatbelt 悄悄失效"时照样全绿。
    @Test
    func backgroundJobStillBlocksWritesOutsideItsRoots() async throws {
        let fm = FileManager.default
        let primary = URL(fileURLWithPath: "/tmp/willdeep-bg-primary-\(UUID().uuidString.prefix(6))")
        let secondary = URL(fileURLWithPath: "/tmp/willdeep-bg-secondary-\(UUID().uuidString.prefix(6))")
        try fm.createDirectory(at: primary, withIntermediateDirectories: true)
        try fm.createDirectory(at: secondary, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: primary)
            try? fm.removeItem(at: secondary)
        }
        let target = secondary.appendingPathComponent("blocked.txt")

        let registry = AgentJobRegistry()
        let job = try registry.start(
            command: "touch '\(target.path)'",
            workingDirectory: primary,
            runtimeID: UUID(),
            timeoutSeconds: nil,
            sandboxMode: .workspaceWrite
        )

        #expect(await waitUntilFinished(registry: registry, id: job.id))
        #expect(registry.job(id: job.id)?.status == .failed)
        #expect(!fm.fileExists(atPath: target.path))
    }

    @Test
    func backgroundCommandUsesInjectedEnvironment() async throws {
        let registry = AgentJobRegistry()
        let runtimeID = UUID()
        let job = try registry.start(
            command: "printf '%s' \"$WILLDEEP_BACKGROUND_ENV\"",
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil,
            environment: [
                "PATH": "/usr/bin:/bin",
                "WILLDEEP_BACKGROUND_ENV": "from-terminal-settings"
            ]
        )

        #expect(await waitUntilFinished(registry: registry, id: job.id))
        #expect(registry.output(id: job.id).contains("from-terminal-settings"))
    }

    /// Host-side transcript surfacing can consume exactly one finished
    /// background job while leaving unrelated completions queued for
    /// the normal next-turn agent notification path.
    @Test
    func markCompletionSurfacedRemovesOnlyThatJob() async throws {
        let registry = AgentJobRegistry()
        let runtimeID = UUID()
        let surfacedJob = try registry.start(
            command: "true",
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil
        )
        let queuedJob = try registry.start(
            command: "true",
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil
        )

        _ = await waitUntilFinished(registry: registry, id: surfacedJob.id)
        _ = await waitUntilFinished(registry: registry, id: queuedJob.id)

        registry.markCompletionSurfaced(id: surfacedJob.id, forRuntime: runtimeID)

        let pending = registry.consumePendingCompletions(forRuntime: runtimeID)
        #expect(pending.count == 1)
        #expect(pending.first?.id == queuedJob.id)
        #expect(registry.consumePendingCompletions(forRuntime: runtimeID).isEmpty)
    }

    /// A non-zero exit flips status to `.failed` (not `.completed`).
    /// The model uses this distinction to decide whether to react.
    @Test
    func nonZeroExitFlipsToFailed() async throws {
        let registry = AgentJobRegistry()
        let runtimeID = UUID()
        let job = try registry.start(
            command: "exit 7",
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil
        )
        let finished = await waitUntilFinished(registry: registry, id: job.id)
        #expect(finished)
        let updated = registry.job(id: job.id)
        #expect(updated?.status == .failed)
        #expect(updated?.exitCode == 7)
    }

    /// Dispatch children have no operator attached. A background verification
    /// command therefore cannot leave a normal foreground escalation card
    /// behind after it exits. The registry must recognize the sandbox marker,
    /// replay exactly once without seatbelt, and surface only that replay as
    /// the terminal completion event.
    @Test
    func unattendedSandboxDenialAutomaticallyReplaysOnceEscalated() async throws {
        let registry = AgentJobRegistry()
        let runtimeID = UUID()
        let first = try registry.start(
            command: "printf 'listen EPERM: Operation not permitted\\n' >&2; exit 1",
            workingDirectory: FileManager.default.temporaryDirectory,
            runtimeID: runtimeID,
            timeoutSeconds: nil,
            sandboxMode: .workspaceWrite,
            automaticSandboxRetryApprovalSource: .dispatchTask
        )

        #expect(await waitUntilFinished(registry: registry, id: first.id))
        for _ in 0..<100 where registry.jobs.count < 2 || registry.jobs.first?.isAlive == true {
            try await Task.sleep(for: .milliseconds(20))
        }

        let replay = try #require(registry.jobs.first { $0.id != first.id })
        #expect(replay.status == .failed)
        #expect(registry.jobs.count == 2)
        #expect(registry.output(id: first.id).contains("automatically retried outside the sandbox"))
        let completions = registry.consumePendingCompletions(forRuntime: runtimeID)
        #expect(completions.map(\.id) == [replay.id])
    }

    /// Explicit `kill_job` path: SIGTERM is delivered, the
    /// terminationHandler runs, and the resulting status is `.killed`
    /// (NOT `.timedOut` and NOT `.completed`). This is what lets the
    /// UI / model distinguish "user terminated" from "exited normally"
    /// in the post-mortem.
    @Test
    func longRunningCommandCanBeKilled() async throws {
        let registry = AgentJobRegistry()
        let runtimeID = UUID()
        let job = try registry.start(
            command: AgentJobFixtureCommand.idle(),
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil
        )
        // Give the Process a moment to actually start before we
        // SIGTERM it. Without this, terminate() can race against
        // process.run() on slow CI boxes.
        try await Task.sleep(nanoseconds: 50_000_000)
        let signaled = registry.kill(id: job.id)
        #expect(signaled == true)

        let finished = await waitUntilFinished(registry: registry, id: job.id)
        #expect(finished)
        #expect(registry.job(id: job.id)?.status == .killed)
    }

    @Test
    func phaseCleanupStopsOnlyTheCompletedPhaseWithoutWakingGoalLoop() async throws {
        let registry = AgentJobRegistry()
        let runtimeID = UUID()
        let command = AgentJobFixtureCommand.idle()
        let phaseOne = try registry.start(
            command: command,
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil,
            lifetime: .phase,
            goalPhaseID: "PHASE-1"
        )
        let phaseTwo = try registry.start(
            command: command,
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil,
            lifetime: .phase,
            goalPhaseID: "PHASE-2"
        )
        let persistent = try registry.start(
            command: command,
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil,
            lifetime: .persistent
        )

        #expect(registry.hasProgressRelevantAliveJobs(forRuntime: runtimeID) == false)
        #expect(registry.killAllAlive(forRuntime: runtimeID, phaseID: "PHASE-1") == 1)
        #expect(await waitUntilFinished(registry: registry, id: phaseOne.id))
        #expect(registry.job(id: phaseOne.id)?.status == .killed)
        #expect(registry.job(id: phaseTwo.id)?.isAlive == true)
        #expect(registry.job(id: persistent.id)?.isAlive == true)
        #expect(registry.consumePendingCompletions(forRuntime: runtimeID).isEmpty)

        registry.killAllAlive(forRuntime: runtimeID)
        #expect(await waitUntilFinished(registry: registry, id: phaseTwo.id))
        #expect(await waitUntilFinished(registry: registry, id: persistent.id))
    }

    /// `kill` on an already-finished job is a no-op and returns
    /// false. Important: prevents the UI's stop button from
    /// firing a spurious "killed" notice after a job exited
    /// normally a millisecond earlier.
    @Test
    func killOfFinishedJobReturnsFalse() async throws {
        let registry = AgentJobRegistry()
        let runtimeID = UUID()
        let job = try registry.start(
            command: "true",
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil
        )
        _ = await waitUntilFinished(registry: registry, id: job.id)
        let signaled = registry.kill(id: job.id)
        #expect(signaled == false)
    }

    /// Hard timeout flips status to `.timedOut` (NOT `.killed`).
    /// The agent loop uses this distinction in the completion notice
    /// so the model can tell whether the user gave up vs whether
    /// the host enforced a budget.
    ///
    /// Timeout enforcement uses the registry's dedicated lifecycle queue,
    /// so even a loaded shared CI box must deliver SIGTERM/SIGKILL without
    /// relying on a starved global utility queue.
    @Test
    func timeoutSurfacesTimedOutStatus() async throws {
        let registry = AgentJobRegistry()
        let runtimeID = UUID()
        let job = try registry.start(
            command: AgentJobFixtureCommand.idle(),
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: 0.4
        )
        let finished = await waitUntilFinished(registry: registry, id: job.id)
        #expect(finished)
        #expect(registry.job(id: job.id)?.status == .timedOut)
    }

    // MARK: - Output capture

    /// stdout bytes flow through the readabilityHandler into the
    /// collector, and `output(id:tailLines:)` returns the captured
    /// text. Without this, `get_job_output` would return empty even
    /// for completed jobs, breaking the model's only path to a
    /// background job's payload.
    @Test
    func capturedOutputContainsStdout() async throws {
        let registry = AgentJobRegistry()
        let runtimeID = UUID()
        let job = try registry.start(
            command: "echo 'hello-from-bg'",
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil
        )
        _ = await waitUntilFinished(registry: registry, id: job.id)
        let output = registry.output(id: job.id, tailLines: nil)
        #expect(output.contains("hello-from-bg"))
    }

    @Test
    func capturedOutputKeepsStdoutAndStderrSeparate() async throws {
        let registry = AgentJobRegistry()
        let runtimeID = UUID()
        let job = try registry.start(
            command: "printf 'stdout-only\\n'; printf 'stderr-only\\n' >&2",
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil
        )
        _ = await waitUntilFinished(registry: registry, id: job.id)

        let stdout = registry.output(id: job.id, stream: .stdout)
        let stderr = registry.output(id: job.id, stream: .stderr)
        let combined = registry.output(id: job.id)

        #expect(stdout.contains("stdout-only"))
        #expect(stdout.contains("stderr-only") == false)
        #expect(stderr.contains("stderr-only"))
        #expect(stderr.contains("stdout-only") == false)
        #expect(combined.contains("stdout-only"))
        #expect(combined.contains("stderr-only"))
    }

    @Test("render selected background task manager design for visual QA")
    func rendersBackgroundTaskManagerForVisualQA() async throws {
        let outputURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/visual-qa/background-task-manager/implementation.png")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let appState = AppState()
        let session = AgentSession(title: "后台构建与测试")
        appState.agentSessions = [session]
        appState.activeAgentSessionID = session.id
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let completedJob = try appState.agentJobRegistry.start(
            command: "swift test --filter AgentBackgroundJobsTests",
            workingDirectory: workspace,
            runtimeID: session.id,
            timeoutSeconds: nil
        )
        _ = await waitUntilFinished(
            registry: appState.agentJobRegistry,
            id: completedJob.id
        )

        let runningJob = try appState.agentJobRegistry.start(
            command: AgentJobFixtureCommand.idle(
                prefix: "printf 'Compiling AgentBackgroundTasksPanel.swift\\nLinking WillDeep\\n'; "
                    + "printf 'warning: preview fixture uses sample output\\n' >&2; "
            ),
            workingDirectory: workspace,
            runtimeID: session.id,
            timeoutSeconds: nil
        )
        // Registered before the first `await`, so a throw anywhere below
        // still signals the shell. The rendering path underneath is the
        // heaviest in this suite, and it was an abandoned run of exactly
        // this test that stranded two orphan shells for days.
        defer { _ = appState.agentJobRegistry.kill(id: runningJob.id) }
        try await Task.sleep(nanoseconds: 120_000_000)

        // Match the selected ImageGen reference's right-side panel viewport so
        // the Design QA comparison is spatially meaningful rather than scaled.
        let size = NSSize(width: 626, height: 1_024)
        let fixture = VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: AgentSidePanelKind.backgroundTasks.systemImage)
                Text(L10n.AgentJobs.managerTitle)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            Divider()
            AgentBackgroundTasksPanel(
                width: size.width,
                initialSelectedJobID: runningJob.id
            )
        }
        .environmentObject(appState)
        .frame(width: size.width, height: size.height)
        .background(appState.editorSettings.interfaceSkin.palette.panelFill)
        .preferredColorScheme(.light)

        let hostingView = NSHostingView(rootView: fixture)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try #require(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: outputURL, options: .atomic)

        #expect(png.count > 20_000)
        #expect(FileManager.default.fileExists(atPath: outputURL.path))

        // Reap before returning rather than leaving it to `defer`, which
        // cannot await: the test must not finish while the shell is still
        // draining its TERM.
        _ = appState.agentJobRegistry.kill(id: runningJob.id)
        #expect(
            await waitUntilFinished(
                registry: appState.agentJobRegistry,
                id: runningJob.id
            )
        )
    }

    /// `tail_lines` only returns the last N lines. Saves the model
    /// from context-bombing itself with a megabyte of build log
    /// when it really only needs to know whether the last line said
    /// "PASS" or "FAIL".
    @Test
    func tailLinesReturnsLastLinesOnly() async throws {
        let registry = AgentJobRegistry()
        let runtimeID = UUID()
        let job = try registry.start(
            command: "printf 'line1\\nline2\\nline3\\nline4\\n'",
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil
        )
        _ = await waitUntilFinished(registry: registry, id: job.id)

        let tailed = registry.output(id: job.id, tailLines: 2)
        #expect(tailed.contains("line3"))
        #expect(tailed.contains("line4"))
        #expect(tailed.contains("line1") == false)
        #expect(tailed.contains("line2") == false)

        // Full output should still carry every line — the tail
        // accessor is non-destructive.
        let full = registry.output(id: job.id, tailLines: nil)
        #expect(full.contains("line1"))
        #expect(full.contains("line4"))
    }

    /// Contract v1: memory keeps the LAST 64KB (the verdict lives at the end)
    /// while the full combined stream lands in `<handle>/output.log`, with
    /// the tail sidecar written on termination.
    @Test
    func largeOutputKeepsTailInMemoryAndFullLogOnDisk() async throws {
        let logRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-job-logs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: logRoot) }
        let registry = AgentJobRegistry(outputLogRootDirectory: logRoot)
        let job = try registry.start(
            command: "i=0; while [ $i -lt 3000 ]; do echo \"line $i padding-padding-padding-padding\"; i=$((i+1)); done; echo RESULT=42",
            workingDirectory: nil,
            runtimeID: UUID(),
            timeoutSeconds: nil
        )
        #expect(await waitUntilFinished(registry: registry, id: job.id))

        let output = registry.output(id: job.id, tailLines: nil)
        #expect(output.hasPrefix("...[earlier output omitted]\n"))
        #expect(output.hasSuffix("RESULT=42\n"))
        #expect(output.contains("line 0 ") == false)

        let logURL = try #require(registry.outputLogURL(id: job.id))
        #expect(logURL.path == logRoot.appendingPathComponent("\(job.displayHandle)/output.log").path)
        let log = try String(contentsOf: logURL, encoding: .utf8)
        #expect(log.hasPrefix("line 0 "))
        #expect(log.components(separatedBy: "\n").count == 3_002)
        #expect(registry.outputLogDroppedBytes(id: job.id) == 0)
        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let tail = try String(contentsOf: logURL.appendingPathExtension("tail"), encoding: .utf8)
        #expect(tail.hasSuffix("RESULT=42\n"))
        #expect(FileManager.default.fileExists(atPath: logURL.appendingPathExtension("dropped").path) == false)

        let notice = AppState.backgroundJobCompletionNotice(
            for: try #require(registry.job(id: job.id)),
            recentOutput: registry.output(id: job.id, tailLines: 40),
            outputPath: logURL.path
        )
        #expect(notice.contains("RESULT=42\n```"))
        #expect(notice.contains("output_path: \(logURL.path)\n"))

        let context = AgentToolContext(rootDirectory: nil, runtimeID: job.runtimeID,
                                       jobRegistry: registry, sandboxMode: .escalated)
        let defaultRead = try await AgentToolRunner.getJobOutput(
            arguments: ["job_id": .string(job.displayHandle)], context: context)
        #expect(defaultRead.payload.hasPrefix("""
        \(job.displayHandle)
        status: completed
        exit_code: 0
        """))
        #expect(defaultRead.payload.contains("output_path: \(logURL.path)\nstderr_path: none\nomitted_bytes: 0\n--- output (last 200 lines) ---\n"))
        #expect(defaultRead.payload.hasSuffix("RESULT=42"))
        let shortRead = try await AgentToolRunner.getJobOutput(
            arguments: ["job_id": .string(job.displayHandle), "tail_lines": .number(5)], context: context)
        #expect(shortRead.payload.components(separatedBy: "---\n").last?.components(separatedBy: "\n").count == 5)
    }

    /// Retention: finished job directories older than 7 days, or beyond the
    /// newest 200, are removed; explicitly alive ones never are.
    @Test
    func outputLogRetentionPrunesOldAndOverflowDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-job-prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        func makeDirectory(_ name: String, age: TimeInterval) throws {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try makeDirectory("job_old001", age: 8 * 24 * 3600)
        try makeDirectory("job_alive1", age: 9 * 24 * 3600)
        for index in 0..<201 {
            try makeDirectory(String(format: "job_n%05d", index), age: TimeInterval(index))
        }
        let removed = AgentJobOutputLogSink.prune(rootDirectory: root, now: now, excluding: ["job_alive1"])
            .map(\.lastPathComponent)
        #expect(Set(removed) == ["job_old001", "job_n00200"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("job_alive1").path))
    }

    /// Empty / not-yet-started buffer returns an empty string,
    /// not a crash. `get_job_output` tolerates "I asked too early".
    @Test
    func outputForUnknownIdIsEmpty() {
        let registry = AgentJobRegistry()
        #expect(registry.output(id: UUID(), tailLines: nil).isEmpty)
    }

    // MARK: - Registry scoping

    /// Two runtimes must not see each other's jobs, alive lists, or
    /// completion events. This is the core promise of the scoping
    /// design (the user picked "per-session作用域" explicitly) — if
    /// it leaks, a routine session could surface jobs into the
    /// user's interactive transcript.
    @Test
    func runtimesAreIsolated() async throws {
        let registry = AgentJobRegistry()
        let runtimeA = UUID()
        let runtimeB = UUID()
        let jobA = try registry.start(
            command: "true",
            workingDirectory: nil,
            runtimeID: runtimeA,
            timeoutSeconds: nil
        )
        let jobB = try registry.start(
            command: "true",
            workingDirectory: nil,
            runtimeID: runtimeB,
            timeoutSeconds: nil
        )
        _ = await waitUntilFinished(registry: registry, id: jobA.id)
        _ = await waitUntilFinished(registry: registry, id: jobB.id)

        let listA = registry.jobs(forRuntime: runtimeA)
        let listB = registry.jobs(forRuntime: runtimeB)
        #expect(listA.count == 1)
        #expect(listB.count == 1)
        #expect(listA.first?.id == jobA.id)
        #expect(listB.first?.id == jobB.id)

        // Consuming runtime A's completions must NOT drain
        // runtime B's queue.
        let drainedA = registry.consumePendingCompletions(forRuntime: runtimeA)
        #expect(drainedA.count == 1)
        let stillPendingB = registry.consumePendingCompletions(forRuntime: runtimeB)
        #expect(stillPendingB.count == 1)
        #expect(stillPendingB.first?.id == jobB.id)
    }

    /// `aliveJobs` excludes finished entries — the drawer's badge
    /// counts this, and the agent loop's "you still have N running
    /// jobs" check (future rc) will too.
    @Test
    func aliveJobsFilterDropsFinished() async throws {
        let registry = AgentJobRegistry()
        let runtimeID = UUID()
        let finishedJob = try registry.start(
            command: "true",
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil
        )
        _ = await waitUntilFinished(registry: registry, id: finishedJob.id)

        let liveJob = try registry.start(
            command: AgentJobFixtureCommand.idle(),
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil
        )
        let alive = registry.aliveJobs(forRuntime: runtimeID)
        #expect(alive.count == 1)
        #expect(alive.first?.id == liveJob.id)
        // Cleanup so we don't strand a 10-second sleep.
        _ = registry.kill(id: liveJob.id)
        _ = await waitUntilFinished(registry: registry, id: liveJob.id)
    }

    // MARK: - Handle resolution

    /// `matchingHandle` is what the three model-facing tools use to
    /// resolve a string back to a job. It must accept three input
    /// shapes the model is likely to produce: `job_<6>`, just the
    /// 6-char id, and the full UUID. Anything else returns nil
    /// (covered by `matchingHandleReturnsNilForUnknown` above).
    @Test
    func handleResolverAcceptsShortFullAndPrefixedForms() async throws {
        let registry = AgentJobRegistry()
        let runtimeID = UUID()
        let job = try registry.start(
            command: "true",
            workingDirectory: nil,
            runtimeID: runtimeID,
            timeoutSeconds: nil
        )

        let viaShort = registry.job(matchingHandle: job.shortID, runtimeID: runtimeID)
        let viaPrefixed = registry.job(matchingHandle: "job_\(job.shortID)", runtimeID: runtimeID)
        let viaFull = registry.job(matchingHandle: job.id.uuidString, runtimeID: runtimeID)
        let viaUpper = registry.job(matchingHandle: job.id.uuidString.uppercased(), runtimeID: runtimeID)

        #expect(viaShort?.id == job.id)
        #expect(viaPrefixed?.id == job.id)
        #expect(viaFull?.id == job.id)
        #expect(viaUpper?.id == job.id)

        // Same short id under a different runtime resolves to nil —
        // the runtime guard is part of the resolver, not a separate
        // post-filter.
        let crossRuntime = registry.job(matchingHandle: job.shortID, runtimeID: UUID())
        #expect(crossRuntime == nil)

        _ = await waitUntilFinished(registry: registry, id: job.id)
    }

    // MARK: - Running-task count (transcript status row)

    /// The Claude Code-style「✳ N 个任务运行中」status row reads
    /// `AppState.agentRunningTaskCount`. Lock in its two-source
    /// contract: foreground `.running` tool calls count ONLY while
    /// the turn is live (leftover `.running` records from a dead turn
    /// must not pin the row forever), while alive background jobs
    /// count even after the turn ends — that post-turn persistence
    /// is the whole point of the row.
    @Test
    func appStateRunningTaskCountCombinesToolsAndJobs() async throws {
        let appState = AppState()
        let session = appState.startNewAgentSession()

        #expect(appState.agentRunningTaskCount == 0)
        #expect(appState.agentRunningTaskSummary == nil)

        // Foreground tool calls: only `.running` ones count, and only
        // while the turn is responding.
        appState.isAgentResponding = true
        appState.agentToolCalls = [
            AgentToolCall(
                messageID: UUID(),
                externalID: "t1",
                toolName: "run_command",
                arguments: [:],
                risk: .write,
                status: .running
            ),
            AgentToolCall(
                messageID: UUID(),
                externalID: "t2",
                toolName: "read_file",
                arguments: [:],
                risk: .read,
                status: .succeeded
            )
        ]
        #expect(appState.agentRunningTaskCount == 1)
        #expect(appState.agentRunningTaskSummary == "run_command")

        appState.isAgentResponding = false
        #expect(appState.agentRunningTaskCount == 0)
        #expect(appState.agentRunningTaskSummary == nil)

        // Alive background job: counts with no live turn at all. Use a
        // synthetic registry snapshot here; process launch/termination is
        // covered by dedicated AgentJobRegistry tests, while this test locks
        // AppState's derived-count contract.
        let job = makeStubJob(command: "sleep 1", status: .running, runtimeID: session.id)
        appState.agentJobRegistry.replaceJobsForTesting([job])
        #expect(appState.agentRunningTaskCount == 1)
        #expect(appState.agentRunningTaskSummary?.contains(job.displayHandle) == true)

        var finishedJob = job
        finishedJob.status = .completed
        finishedJob.exitCode = 0
        finishedJob.finishedAt = Date()
        appState.agentJobRegistry.replaceJobsForTesting([finishedJob])
        #expect(appState.agentRunningTaskCount == 0)
    }

    @Test
    func taskMonitorSnapshotDoesNotAutoOpenForApprovalOnly() {
        let appState = AppState()
        appState.startNewAgentSession()
        appState.isAgentResponding = true
        appState.agentToolCalls = [
            AgentToolCall(
                messageID: UUID(),
                externalID: "approval",
                toolName: "run_command",
                arguments: [:],
                risk: .write,
                status: .pendingApproval
            )
        ]

        let approvalOnly = AgentTaskMonitorSnapshot.capture(from: appState)
        #expect(approvalOnly.isAgentActivityActive)
        #expect(approvalOnly.hasVisibleMonitorContent)
        #expect(!approvalOnly.hasAutoOpenMonitorContent)

        appState.agentToolCalls[0].status = .running
        let runningTool = AgentTaskMonitorSnapshot.capture(from: appState)
        #expect(runningTool.isAgentActivityActive)
        #expect(runningTool.hasVisibleMonitorContent)
        #expect(!runningTool.hasAutoOpenMonitorContent)
    }

    @Test
    func taskMonitorSnapshotAutoOpenDigestIgnoresForegroundVerification() {
        let sessionID = UUID()
        let baseline = AgentTaskMonitorSnapshot(
            sessionID: sessionID,
            isAgentResponding: true,
            isCompressingContext: false,
            runningTaskCount: 0,
            attentionToolIDs: [],
            jobDigest: [],
            mediaTaskDigest: [],
            todoDigest: ["goal:write tests"],
            artifactDigest: [],
            workFileDigest: [],
            learningDigest: []
        )
        let verifying = AgentTaskMonitorSnapshot(
            sessionID: sessionID,
            isAgentResponding: true,
            isCompressingContext: false,
            runningTaskCount: 1,
            attentionToolIDs: ["tool:running:run_command"],
            jobDigest: [],
            mediaTaskDigest: [],
            todoDigest: ["goal:write tests"],
            artifactDigest: [],
            workFileDigest: [],
            learningDigest: []
        )

        #expect(baseline.hasAutoOpenMonitorContent)
        #expect(verifying.hasAutoOpenMonitorContent)
        #expect(verifying != baseline)
        #expect(verifying.autoOpenDigest == baseline.autoOpenDigest)
    }

    @Test
    func conversationMediaSummaryIsStrictlySessionScoped() {
        let firstRuntimeID = UUID()
        let secondRuntimeID = UUID()
        let firstTask = AgentMediaTask(
            provider: .someIM,
            kind: .imageGeneration,
            title: "first session image",
            runtimeID: firstRuntimeID,
            status: .succeeded
        )
        let secondTask = AgentMediaTask(
            provider: .replicate,
            kind: .videoGeneration,
            title: "second session video",
            runtimeID: secondRuntimeID,
            status: .processing
        )
        let canceledTask = AgentMediaTask(
            provider: .local,
            kind: .imageEdit,
            title: "canceled",
            runtimeID: firstRuntimeID,
            status: .canceled
        )

        let scoped = AgentSessionMediaSummary.scopedTasks(
            [firstTask, secondTask, canceledTask],
            runtimeID: firstRuntimeID
        )

        #expect(scoped.map(\.id) == [firstTask.id])
    }

    @Test
    func devServerPreviewUsesReportedWorkspaceURL() throws {
        let job = makeStubJob(command: "yarn dev", workingDirectoryPath: "/tmp/project")

        let url = try #require(
            AgentWorkspaceDevServerSupport.previewURL(for: [job]) { _ in
                "Local: http://localhost:4317/"
            }
        )

        #expect(url.absoluteString == "http://localhost:4317/")
    }

    @Test
    func devServerPreviewFallsBackToCommandPort() throws {
        let explicit = makeStubJob(command: "yarn dev --port 4321")
        let viteDefault = makeStubJob(command: "vite")

        let explicitURL = try #require(
            AgentWorkspaceDevServerSupport.previewURL(for: [explicit]) { _ in "" }
        )
        let defaultURL = try #require(
            AgentWorkspaceDevServerSupport.previewURL(for: [viteDefault]) { _ in "" }
        )

        #expect(explicitURL.port == 4321)
        #expect(defaultURL.port == 5173)
    }

    @Test
    func activityCardDismissalKeysOnlyChangeForMeaningfulUpdates() {
        let runtimeID = UUID()
        let taskID = UUID()
        let earlyTask = AgentMediaTask(
            id: taskID,
            provider: .someIM,
            kind: .imageGeneration,
            title: "image",
            runtimeID: runtimeID,
            status: .processing,
            updatedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        var polledTask = earlyTask
        polledTask.updatedAt = Date(timeIntervalSinceReferenceDate: 20)
        let earlyMedia = AgentSessionMediaSummary(
            tasks: [earlyTask],
            artifacts: [],
            activeCount: 1,
            attentionCount: 0,
            imageCount: 0,
            videoCount: 0
        )
        let polledMedia = AgentSessionMediaSummary(
            tasks: [polledTask],
            artifacts: [],
            activeCount: 1,
            attentionCount: 0,
            imageCount: 0,
            videoCount: 0
        )

        #expect(earlyMedia.identityDigest != polledMedia.identityDigest)
        #expect(earlyMedia.dismissalDigest == polledMedia.dismissalDigest)

        var noisyJob = makeStubJob(command: "yarn dev", outputByteCount: 12)
        let quietSummary = AgentWorkspaceDevServerSummary(
            workspaceRoot: URL(fileURLWithPath: "/tmp/project"),
            jobs: [noisyJob],
            previewURL: URL(string: "http://127.0.0.1:5173")
        )
        noisyJob.outputByteCount = 4_096
        let noisySummary = AgentWorkspaceDevServerSummary(
            workspaceRoot: URL(fileURLWithPath: "/tmp/project"),
            jobs: [noisyJob],
            previewURL: URL(string: "http://127.0.0.1:5173")
        )

        #expect(quietSummary.identityDigest != noisySummary.identityDigest)
        #expect(quietSummary.dismissalDigest == noisySummary.dismissalDigest)

        let firstArtifacts = AgentConversationActivitySnapshot(
            sessionID: runtimeID,
            sessionArtifacts: [URL(fileURLWithPath: "/tmp/a.html")],
            mediaSummary: nil,
            devServerSummary: nil
        )
        let newArtifacts = AgentConversationActivitySnapshot(
            sessionID: runtimeID,
            sessionArtifacts: [
                URL(fileURLWithPath: "/tmp/a.html"),
                URL(fileURLWithPath: "/tmp/b.png"),
            ],
            mediaSummary: nil,
            devServerSummary: nil
        )

        #expect(firstArtifacts.artifactDismissalKey != newArtifacts.artifactDismissalKey)
    }

    // MARK: - Helpers

    /// Poll the registry until the job leaves `.running` or the
    /// budget runs out. 20ms cadence is fast enough that even a
    /// `true` finish doesn't waste much wall-clock; 15s default is
    /// generous enough to survive a loaded CI box running the whole
    /// Swift Testing target concurrently without false failures.
    /// How long a test will wait for a job to reach a terminal state. This is
    /// a liveness budget, not an assertion about speed: the jobs here are
    /// `true` or a trapped `sleep` loop, which finish in milliseconds when the
    /// box is idle. Under a full-load parallel run the spawn alone can outlast
    /// a tight budget — 15s lost three of these at once while the rest of the
    /// suite ran, and the same suite passed in 9.8s on its own.
    private static let finishBudgetMs = 60_000

    private func waitUntilFinished(
        registry: AgentJobRegistry,
        id: UUID,
        timeoutMs: Int = Self.finishBudgetMs
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if let job = registry.job(id: id), !job.isAlive {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    /// Synthetic job for pure-formatting tests. Bypasses the
    /// registry so we can assemble unusual states (e.g. .completed
    /// with zero output) without a Process roundtrip. Builds a
    /// fresh AgentBackgroundJob each call — `command` and other
    /// `let` fields are set once via the initializer.
    private func makeStubJob(
        command: String = "echo stub",
        status: AgentBackgroundJob.Status = .running,
        exitCode: Int32? = nil,
        finishedAfter seconds: TimeInterval? = nil,
        outputByteCount: Int = 0,
        workingDirectoryPath: String? = nil,
        runtimeID: UUID = UUID()
    ) -> AgentBackgroundJob {
        let id = UUID()
        let started = Date(timeIntervalSinceReferenceDate: 0)
        return AgentBackgroundJob(
            id: id,
            shortID: String(id.uuidString.prefix(6)).lowercased(),
            command: command,
            workingDirectoryPath: workingDirectoryPath,
            runtimeID: runtimeID,
            startedAt: started,
            pid: 12345,
            status: status,
            exitCode: exitCode,
            finishedAt: seconds.map { started.addingTimeInterval($0) },
            outputByteCount: outputByteCount
        )
    }
}
