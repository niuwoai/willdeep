import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentSubagentInterventionTests {
    /// Bounded wait on a MainActor condition. The sleep between checks is
    /// what lets the task under test make progress on the same actor — this
    /// suite is `@MainActor`, so a spin loop would starve exactly the work
    /// it is waiting for.
    private func waitUntil(
        attempts: Int = 3_000,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @Test("normal intervention queues for the next round without cancelling the active step")
    func normalSubmissionWaitsForBoundary() async throws {
        let channel = AgentSubagentInterventionChannel()
        channel.beginRound(3)

        let step = Task { @MainActor in
            try await channel.runCancellableStep {
                try await Task.sleep(nanoseconds: 20_000_000)
                return 42
            }
        }
        try await waitUntil { channel.hasActiveStep }
        let submission = try channel.submit(
            text: "  改用 UTF-8 继续  ",
            mode: .nextRound
        )

        #expect(try await step.value == 42)
        #expect(submission.text == "改用 UTF-8 继续")
        #expect(submission.requestedRound == 4)
        #expect(channel.hasPendingSubmission)
        #expect(!channel.hasPendingInterruption)
    }

    @Test("interrupt submission cancels only the active child step", .timeLimit(.minutes(1)))
    func interruptCancelsActiveStep() async throws {
        let channel = AgentSubagentInterventionChannel()
        channel.beginRound(5)
        let (blocked, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        var stepFinished = false

        let step = Task { @MainActor in
            defer { stepFinished = true }
            do {
                _ = try await channel.runCancellableStep {
                    for await _ in blocked { }
                    try Task.checkCancellation()
                    return true
                }
                return false
            } catch is CancellationError {
                return true
            }
        }
        defer { step.cancel() }
        // Registration alone is insufficient if a finite sleep has already
        // ended while the actor was busy. This operation cannot finish normally
        // until teardown, so the assertion measures cancellation, not scheduling.
        try await waitUntil { channel.hasActiveStep }
        try #require(channel.hasActiveStep)

        _ = try channel.submit(
            text: "不要继续读这个文件，先检查环境变量",
            mode: .interruptCurrentStep
        )

        try await waitUntil { stepFinished }
        #expect(stepFinished, "Interrupt must finish the active step before teardown releases it")
        release.finish()
        let wasCancelled = try await step.value
        #expect(wasCancelled)
        #expect(!Task.isCancelled)
        #expect(channel.hasPendingInterruption)
        let drained = channel.drainPending(effectiveRound: 6)
        #expect(drained.count == 1)
        #expect(!channel.hasPendingSubmission)
    }

    @Test("queued and applied receipt events preserve submission order")
    func receiptEventsPreserveOrder() throws {
        let channel = AgentSubagentInterventionChannel()
        channel.beginRound(2)
        var events: [AgentSubagentInterventionEvent] = []
        channel.onEvent = { events.append($0) }

        let first = try channel.submit(text: "先看配置", mode: .nextRound)
        let second = try channel.submit(text: "再检查编码", mode: .nextRound)
        let drained = channel.drainPending(effectiveRound: 3)

        #expect(drained.map(\.id) == [first.id, second.id])
        #expect(events == [
            .queued(first),
            .queued(second),
            .applied(first, effectiveRound: 3),
            .applied(second, effectiveRound: 3),
        ])
    }

    @Test("live activity upgrades a queued receipt when the instruction is applied")
    func liveActivityUpgradesReceipt() throws {
        let channel = AgentSubagentInterventionChannel()
        channel.beginRound(1)
        var live = AgentSubagentLiveActivity(
            profileID: "reader",
            workerName: "阅读者",
            model: "glm-5",
            round: 1,
            maximumRounds: 12,
            completedToolInvocations: 0,
            activityText: "正在思考下一步",
            startedAt: Date()
        )
        channel.onEvent = { live.recordIntervention($0) }

        let submission = try channel.submit(text: "换一条路线", mode: .nextRound)
        #expect(live.interventionReceipts.count == 1)
        #expect(live.interventionReceipts[0].deliveryState == .queued)

        _ = channel.drainPending(effectiveRound: 2)
        #expect(live.interventionReceipts[0].id == submission.id)
        #expect(live.interventionReceipts[0].deliveryState == .applied(effectiveRound: 2))
    }

    @Test("provider wrapper keeps exact user text and intervention mode")
    func providerMessageCarriesVisibleInstruction() {
        let submission = AgentSubagentInterventionSubmission(
            id: UUID(),
            text: "直接使用 UTF-8 运行脚本。",
            mode: .interruptCurrentStep,
            submittedAt: Date(),
            requestedRound: 4
        )

        let message = AgentSubagentRunner.interventionMessage([submission])

        #expect(message.contains("[interrupt]"))
        #expect(message.contains("直接使用 UTF-8 运行脚本。"))
    }

    @Test("registry exposes a channel only for the lifetime of the run")
    func registryLifetime() throws {
        let registry = AgentSubagentRegistry()
        let runID = UUID()
        let runtimeID = UUID()
        let channel = AgentSubagentInterventionChannel()
        registry.registerInterventionChannel(
            channel,
            runID: runID,
            parentRuntimeID: runtimeID
        )

        #expect(registry.canIntervene(runID: runID))
        #expect(registry.parentRuntimeID(forInterventionRunID: runID) == runtimeID)
        _ = try registry.submitIntervention(
            runID: runID,
            text: "继续",
            mode: .nextRound
        )

        registry.unregisterInterventionChannel(runID: runID)
        #expect(!registry.canIntervene(runID: runID))
        #expect(throws: AgentSubagentInterventionError.runUnavailable) {
            try registry.submitIntervention(
                runID: runID,
                text: "太晚了",
                mode: .nextRound
            )
        }
    }

    @Test("render collapsed and expanded intervention states for design QA")
    func rendersSelectedInterventionVariantForDesignQA() throws {
        let appState = AppState()
        var activity = AgentSubagentLiveActivity(
            profileID: AgentSubagentProfileCatalog.opsRunnerID,
            workerName: "运维查询员",
            model: "glm-5",
            round: 5,
            maximumRounds: 32,
            completedToolInvocations: 7,
            activityText: "正在运行命令",
            startedAt: Date()
        )
        // Shaped like a real run rather than a tidy one: three silent rounds
        // that each called a tool or two, then a round the Worker spoke in.
        // That is the case the card used to draw as a column of single-chip
        // lines, so it is the case the QA render has to cover.
        activity.recordUtterance(
            round: 1,
            text: "",
            tools: [AgentSubagentToolMention(name: "运行命令", object: "ruby sync.rb")]
        )
        activity.recordUtterance(
            round: 2,
            text: "",
            tools: [AgentSubagentToolMention(name: "运行命令", object: "file -I .env.local")]
        )
        activity.recordUtterance(
            round: 3,
            text: "",
            tools: [
                AgentSubagentToolMention(name: "读取文件", object: ".env.local"),
                AgentSubagentToolMention(name: "读取文件", object: "sync.rb")
            ]
        )
        // A build report, which is what Workers actually write: a table, a
        // fenced command, bold verdicts. This used to print raw on the card.
        activity.recordUtterance(
            round: 4,
            text: """
            所有步骤通过，明细如下：

            | 步骤 | 命令 | 结果 |
            |---|---|---|
            | 1 | `go build ./...` | 编译成功 |
            | 2 | `gofmt -l` | 两个文件待格式化 |

            **`gofmt -l` 退出码为 0**，它只列出待格式化的文件。
            """,
            tools: [AgentSubagentToolMention(name: "应用补丁", object: "sync.rb")]
        )
        let intervention = AgentSubagentInterventionSubmission(
            id: UUID(),
            text: "先别改编码，确认脚本是否支持直接传入 UTF-8 参数。",
            mode: .nextRound,
            submittedAt: Date(),
            requestedRound: 5
        )
        activity.recordIntervention(.applied(intervention, effectiveRound: 5))
        activity.recordUtterance(
            round: 5,
            text: "收到，我先检查脚本参数，不再修改环境配置。",
            tools: [AgentSubagentToolMention(name: "运行命令", object: "ruby sync.rb --encoding utf-8")]
        )

        let runID = UUID()
        let fixture = VStack(alignment: .leading, spacing: 22) {
            qaState(
                title: "默认状态",
                activity: activity,
                runID: runID,
                appState: appState,
                expanded: false
            )
            qaState(
                title: "点击「干预子代理」后",
                activity: activity,
                runID: runID,
                appState: appState,
                expanded: true
            )
        }
        .padding(18)
        .frame(width: 1_024, height: 880, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.light)

        let path = ProcessInfo.processInfo.environment[
            "XEDIT_SUBAGENT_INTERVENTION_SNAPSHOT"
        ] ?? "/tmp/Xedit-subagent-intervention-implementation.png"
        try renderPNG(
            fixture,
            size: NSSize(width: 1_024, height: 880),
            to: URL(fileURLWithPath: path)
        )
        #expect(FileManager.default.fileExists(atPath: path))
    }

    private func qaState(
        title: String,
        activity: AgentSubagentLiveActivity,
        runID: UUID,
        appState: AppState,
        expanded: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
            AgentSubagentSpeechView(
                activity: activity,
                runID: runID,
                isRunning: true,
                initiallyShowsIntervention: expanded
            )
            .environmentObject(appState)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func renderPNG<V: View>(
        _ view: V,
        size: NSSize,
        to outputURL: URL
    ) throws {
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try #require(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: outputURL, options: .atomic)
    }
}
