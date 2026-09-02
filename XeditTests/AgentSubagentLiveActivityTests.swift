import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentSubagentLiveActivityTests {
    private func activity(
        profileID: String = "scout",
        workerName: String = "侦察兵",
        round: Int = 1,
        maximumRounds: Int = 8,
        completedToolInvocations: Int = 0,
        activityText: String = "正在思考",
        startedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> AgentSubagentLiveActivity {
        AgentSubagentLiveActivity(
            profileID: profileID,
            workerName: workerName,
            model: "deepseek-v4-flash",
            round: round,
            maximumRounds: maximumRounds,
            completedToolInvocations: completedToolInvocations,
            activityText: activityText,
            startedAt: startedAt
        )
    }

    private func backgroundActivity(
        workerName: String = "后台工",
        round: Int = 1,
        finishedAt: Date? = nil
    ) -> AgentSubagentLiveActivity {
        var live = activity(workerName: workerName, round: round)
        live.isBackground = true
        live.finishedAt = finishedAt
        return live
    }

    private func spawnCall(
        status: AgentToolCallStatus,
        activity: AgentSubagentLiveActivity? = nil,
        workerName: String? = nil,
        progress: String? = nil,
        profileArgument: String? = nil
    ) -> AgentToolCall {
        var arguments: [String: AgentJSONValue] = [:]
        if let profileArgument { arguments["profile"] = .string(profileArgument) }
        var call = AgentToolCall(
            messageID: UUID(),
            externalID: UUID().uuidString,
            toolName: "spawn_agent",
            arguments: arguments,
            risk: .write,
            status: status,
            subagentWorkerName: workerName,
            subagentProgress: progress
        )
        call.subagentLiveActivity = activity
        return call
    }

    // MARK: Utterances

    @Test("an utterance carries the round's public text, its tools and their objects")
    func recordsUtterance() {
        var live = activity()
        live.recordUtterance(
            round: 1,
            text: "  先看路由表  ",
            tools: [
                AgentSubagentToolMention(name: "grep_files", object: "AppState.swift"),
                AgentSubagentToolMention(name: "read_file")
            ]
        )

        #expect(live.utterances.count == 1)
        #expect(live.utterances[0].round == 1)
        #expect(live.utterances[0].text == "先看路由表")
        #expect(live.utterances[0].tools.map(\.name) == ["grep_files", "read_file"])
        #expect(live.utterances[0].tools[0].object == "AppState.swift")
        #expect(live.utterances[0].tools[1].object == nil)
    }

    /// A round publishes more than once — text arrives with the assistant
    /// message, tool names with the same heartbeat. Stacking both would show
    /// the round twice in the card.
    @Test("re-publishing the same round replaces its utterance instead of stacking")
    func republishingRoundReplaces() {
        var live = activity()
        live.recordUtterance(round: 2, text: "第一版", tools: [])
        live.recordUtterance(
            round: 2,
            text: "第二版",
            tools: [AgentSubagentToolMention(name: "run_command", object: "yarn test")]
        )

        #expect(live.utterances.count == 1)
        #expect(live.utterances[0].text == "第二版")
        #expect(live.utterances[0].tools.map(\.name) == ["run_command"])
    }

    @Test("a heartbeat with neither text nor tools records nothing")
    func emptyHeartbeatIsIgnored() {
        var live = activity()
        live.recordUtterance(round: 1, text: "   \n  ", tools: [])

        #expect(live.utterances.isEmpty)
    }

    /// The card is not the inspector. Keeping every round of a long run would
    /// grow one transcript cell without bound; the tail is what is being read.
    @Test("only the newest rounds are kept, oldest dropped first")
    func utterancesAreCappedToTheTail() {
        var live = activity()
        for round in 1...(AgentSubagentLiveActivity.maxUtterances + 3) {
            live.recordUtterance(round: round, text: "round \(round)", tools: [])
        }

        #expect(live.utterances.count == AgentSubagentLiveActivity.maxUtterances)
        #expect(live.utterances.first?.round == 4)
        #expect(live.utterances.last?.round == AgentSubagentLiveActivity.maxUtterances + 3)
    }

    @Test("utterance text and tool lists are clamped")
    func utteranceContentIsClamped() {
        var live = activity()
        let long = String(repeating: "字", count: AgentSubagentLiveActivity.utteranceCharacterLimit + 200)
        let manyTools = (0..<(AgentSubagentLiveActivity.maxToolMentionsPerUtterance + 5))
            .map { AgentSubagentToolMention(name: "tool\($0)") }
        live.recordUtterance(round: 1, text: long, tools: manyTools)

        #expect(live.utterances[0].text.count == AgentSubagentLiveActivity.utteranceCharacterLimit)
        #expect(live.utterances[0].tools.count == AgentSubagentLiveActivity.maxToolMentionsPerUtterance)
    }

    // MARK: Detail line

    @Test("the detail line omits the tool count until a tool has actually run")
    func detailLineOmitsZeroToolCount() {
        let quiet = activity(completedToolInvocations: 0).detailLine
        let busy = activity(completedToolInvocations: 5).detailLine

        #expect(!quiet.contains("5"))
        #expect(quiet.contains("正在思考"))
        #expect(busy.contains("5"))
    }

    // MARK: Fleet status

    @Test("no running spawn leaves the strip alone")
    func fleetIsNilWithoutRunningWorkers() {
        let calls = [
            spawnCall(status: .succeeded, activity: activity()),
            spawnCall(status: .denied),
        ]

        #expect(AgentSubagentFleetStatus.make(from: calls, fallbackWorkerName: { _ in "X" }) == nil)
    }

    // MARK: Liveness — two regimes

    /// A foreground Worker lives and dies inside its tool call, so the
    /// record's status is the fact. Nothing to remember to stamp.
    @Test("a foreground Worker's liveness follows its tool call status")
    func foregroundLivenessFollowsRecordStatus() {
        #expect(spawnCall(status: .running, activity: activity()).subagentIsWorking)
        for done in [AgentToolCallStatus.succeeded, .failed, .denied] {
            #expect(!spawnCall(status: done, activity: activity()).subagentIsWorking)
        }
    }

    /// The case the whole split exists for: a background spawn settles to
    /// `.succeeded` the instant it hands back a handle, while its Worker runs
    /// on for minutes. Reading the record's status would drop it off the
    /// strip immediately.
    @Test("a background Worker keeps working after its spawn record settles")
    func backgroundWorkerOutlivesItsRecord() {
        let call = spawnCall(status: .succeeded, activity: backgroundActivity())

        #expect(call.subagentIsWorking)
    }

    @Test("a background Worker stops once the registry seals it")
    func backgroundWorkerStopsWhenSealed() {
        let call = spawnCall(
            status: .succeeded,
            activity: backgroundActivity(finishedAt: Date())
        )

        #expect(!call.subagentIsWorking)
    }

    @Test("a spawn with no activity at all still reads its status")
    func livenessWithoutActivityReadsStatus() {
        #expect(spawnCall(status: .running).subagentIsWorking)
        #expect(!spawnCall(status: .succeeded).subagentIsWorking)
    }

    @Test("a live background Worker holds the strip on its own")
    func fleetIncludesBackgroundWorker() throws {
        let calls = [spawnCall(status: .succeeded, activity: backgroundActivity(workerName: "后台工"))]

        let fleet = try #require(
            AgentSubagentFleetStatus.make(from: calls, fallbackWorkerName: { _ in "X" })
        )

        #expect(fleet.runningCount == 1)
        #expect(fleet.primaryWorkerName == "后台工")
    }

    @Test("foreground and background Workers are counted together")
    func fleetMixesBothRegimes() throws {
        let calls = [
            spawnCall(status: .running, activity: activity(workerName: "前台工", round: 2)),
            spawnCall(status: .succeeded, activity: backgroundActivity(workerName: "后台工", round: 5)),
            // Sealed background Worker — finished, must not be counted.
            spawnCall(
                status: .succeeded,
                activity: backgroundActivity(workerName: "已收工", round: 9, finishedAt: Date())
            ),
        ]

        let fleet = try #require(
            AgentSubagentFleetStatus.make(from: calls, fallbackWorkerName: { _ in "X" })
        )

        #expect(fleet.runningCount == 2)
        #expect(fleet.primaryWorkerName == "后台工")
    }

    /// The closing heartbeat exists only to flip liveness. If it were folded
    /// in like an ordinary update, its zeroes would blank the round and tool
    /// counts the card should keep showing.
    @Test("the closing heartbeat carries no counts to overwrite with")
    func closingHeartbeatIsCountless() {
        let update = AgentSubagentProgressUpdate.runFinished

        #expect(update.activity == .finished)
        #expect(update.displayText.isEmpty)
        #expect(update.round == 0)
        #expect(update.completedToolInvocations == 0)
    }

    /// The bug this replaced: the strip described whichever call happened to
    /// be last in the array and never said that others existed.
    @Test("several running Workers are counted, and the count leads the label")
    func fleetCountsEveryRunningWorker() throws {
        let calls = [
            spawnCall(status: .running, activity: activity(profileID: "scout", workerName: "侦察兵", round: 1)),
            spawnCall(status: .running, activity: activity(profileID: "tester", workerName: "测试员", round: 4)),
            spawnCall(status: .running, activity: activity(profileID: "reader", workerName: "阅读者", round: 2)),
            // Foreground and settled: its Worker died with the record, so it
            // must not be counted however high its round got.
            spawnCall(status: .succeeded, activity: activity(round: 9)),
        ]

        let fleet = try #require(
            AgentSubagentFleetStatus.make(from: calls, fallbackWorkerName: { _ in "X" })
        )

        #expect(fleet.runningCount == 3)
        // Freshest reporter wins, not array position.
        #expect(fleet.primaryWorkerName == "测试员")
        #expect(fleet.composerLabel.contains("3"))
        #expect(fleet.composerLabel.contains("测试员"))
        #expect(fleet.members.count == 3)
        #expect(fleet.members.map(\.workerName) == ["侦察兵", "测试员", "阅读者"])
    }

    @Test("one parent session exposes five concurrent Worker slots")
    func fleetConcurrencyLimitIsFive() throws {
        #expect(AgentSubagentRegistry.maxConcurrentPerRuntime == 5)

        let calls = (1...5).map { index in
            spawnCall(
                status: .running,
                activity: activity(workerName: "Worker \(index)", round: index)
            )
        }
        let fleet = try #require(
            AgentSubagentFleetStatus.make(from: calls, fallbackWorkerName: { _ in "X" })
        )

        #expect(fleet.runningCount == 5)
        #expect(fleet.members.count == 5)
        #expect(fleet.primaryWorkerName == "Worker 5")
    }

    @Test("a sixth background Worker is rejected while five remain active")
    func sixthBackgroundWorkerIsRejected() throws {
        let registry = AgentSubagentRegistry()
        let parentID = UUID()
        registry.runOperation = { _, _, _, _, _, _, _, _, _, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return .init(report: "done", usageTokens: 0, roundCount: 0, toolInvocationCount: 0)
        }
        let configuration = AgentConfiguration(
            providerID: "test",
            baseURL: "https://example.invalid",
            model: "test-model",
            flashModel: "",
            proModel: "",
            routingMode: .pro,
            apiKey: "test"
        )
        defer { registry.cancelAll(forParentRuntime: parentID) }

        for index in 1...5 {
            _ = try registry.startBackground(
                prompt: "task \(index)",
                label: "Worker \(index)",
                configuration: configuration,
                workspaceURL: nil,
                parentRuntimeID: parentID
            )
        }
        #expect(registry.activeCount(forParentRuntime: parentID) == 5)
        #expect(throws: AgentSubagentError.self) {
            _ = try registry.startBackground(
                prompt: "task 6",
                label: "Worker 6",
                configuration: configuration,
                workspaceURL: nil,
                parentRuntimeID: parentID
            )
        }
    }

    @Test("a single Worker keeps the familiar delegation wording")
    func singleWorkerKeepsDelegationWording() throws {
        let calls = [spawnCall(status: .running, activity: activity(workerName: "运维查询员"))]

        let fleet = try #require(
            AgentSubagentFleetStatus.make(from: calls, fallbackWorkerName: { _ in "X" })
        )

        #expect(fleet.runningCount == 1)
        #expect(fleet.composerLabel == L10n.AgentDelegation.delegatedToWorker("运维查询员")
            + " · " + activity(workerName: "运维查询员").detailLine)
    }

    /// A Worker that has not reported yet has nothing to say. Picking it
    /// would blank a line another Worker could have filled.
    @Test("a silent Worker never becomes the primary while another is reporting")
    func silentWorkerIsNotPrimary() throws {
        let calls = [
            spawnCall(status: .running, activity: activity(workerName: "已汇报", round: 3)),
            spawnCall(status: .running, workerName: "还没汇报"),
        ]

        let fleet = try #require(
            AgentSubagentFleetStatus.make(from: calls, fallbackWorkerName: { _ in "X" })
        )

        #expect(fleet.primaryWorkerName == "已汇报")
        #expect(fleet.runningCount == 2)
    }

    @Test("with no structured activity the strip falls back to the progress string, then the name resolver")
    func fallsBackToProgressStringAndResolver() throws {
        let calls = [spawnCall(status: .running, progress: "启动中…", profileArgument: "scout")]

        let fleet = try #require(
            AgentSubagentFleetStatus.make(from: calls, fallbackWorkerName: { _ in "回退名" })
        )

        #expect(fleet.primaryWorkerName == "回退名")
        #expect(fleet.primaryDetail == "启动中…")
        // No structured activity means no per-Worker clock; the strip keeps
        // timing the turn rather than inventing a start.
        #expect(fleet.primaryStartedAt == nil)
    }

    @Test("the strip's clock reads the Worker's own start, not the turn's")
    func fleetCarriesWorkerStartTime() throws {
        let started = Date(timeIntervalSince1970: 42_000)
        let calls = [spawnCall(status: .running, activity: activity(startedAt: started))]

        let fleet = try #require(
            AgentSubagentFleetStatus.make(from: calls, fallbackWorkerName: { _ in "X" })
        )

        #expect(fleet.primaryStartedAt == started)
    }

    // MARK: Trade palette

    /// `hashValue` is seeded per process; a Worker whose colour changed
    /// between launches would be worse than no colour at all.
    @Test("a trade's colour is stable across calls")
    func tradeColourIsStable() {
        #expect(
            AgentSubagentTradePalette.color(forProfileID: "scout")
                == AgentSubagentTradePalette.color(forProfileID: "scout")
        )
    }

    /// The roster shows seven trades, and all seven can run in one turn. A shared
    /// colour there is not a near-miss, it is the feature failing. An earlier
    /// `distinct.count >= 4` assertion passed while `reader`, `tester` and
    /// `ops_runner` all rendered the same green — half the roster.
    @Test("every public trade gets its own colour")
    func publicTradeColoursAreAllDistinct() {
        let ids = AgentSubagentProfileCatalog.publicBuiltIn.map(\.id)
        let colors = ids.map { String(describing: AgentSubagentTradePalette.color(forProfileID: $0)) }

        #expect(ids.count == 5)
        #expect(Set(colors).count == ids.count)
    }

    /// Eighteen internal trades are presented as seven. Two runs that both
    /// say "阅读者" must look the same, so the colour keys on the public id.
    @Test("internal trades inherit the colour of the public trade they fold into")
    func internalTradesFollowTheirPublicTrade() {
        let reader = AgentSubagentTradePalette.color(forProfileID: "reader")
        for folded in ["scout", "log_inspector", "git_detective"] {
            #expect(AgentSubagentTradePalette.color(forProfileID: folded) == reader)
        }

        let implementer = AgentSubagentTradePalette.color(forProfileID: "implementer")
        for folded in ["editor", "small_implementer", "test_fixer", "build_fixer"] {
            #expect(AgentSubagentTradePalette.color(forProfileID: folded) == implementer)
        }

        #expect(
            AgentSubagentTradePalette.color(forProfileID: "terminal_operator")
                == AgentSubagentTradePalette.color(forProfileID: "ops_runner")
        )
        #expect(
            AgentSubagentTradePalette.color(forProfileID: "security_guard")
                == AgentSubagentTradePalette.color(forProfileID: "judge")
        )
    }

    @Test("a trade outside the built-in roster still gets a stable colour")
    func customTradeFallsBackToAStableColour() {
        let first = AgentSubagentTradePalette.color(forProfileID: "my_custom_trade")
        let second = AgentSubagentTradePalette.color(forProfileID: " My_Custom_Trade ")

        #expect(first == second)
    }

    // MARK: Progress plumbing

    @Test("a progress update defaults to no speech, so plain heartbeats stay quiet")
    func progressUpdateDefaultsToSilence() {
        let update = AgentSubagentProgressUpdate(
            round: 2,
            maximumRounds: 8,
            completedToolInvocations: 1,
            activity: .thinking
        )

        #expect(update.speech.isEmpty)
        #expect(update.tools.isEmpty)
        #expect(update.displayText.contains("2"))
    }

    // MARK: Step duration

    private func timedCall(status: AgentToolCallStatus, startedAt: Date) -> AgentToolCall {
        AgentToolCall(
            messageID: UUID(),
            externalID: UUID().uuidString,
            toolName: "run_command",
            arguments: [:],
            risk: .write,
            status: status,
            startedAt: startedAt
        )
    }

    @Test("a step in flight has no finish time, so its row keeps ticking")
    func inFlightStepHasNoFinishTime() {
        for status in [AgentToolCallStatus.running, .pendingApproval, .awaitingConfirm, .awaitingUserAnswer] {
            #expect(timedCall(status: status, startedAt: Date()).finishedAt == nil)
        }
    }

    /// `didSet` never fires from `init`, so a record born terminal — a denial
    /// written after the fact — would otherwise count upward forever.
    @Test("a step born terminal is sealed at creation")
    func stepBornTerminalIsSealed() {
        let started = Date(timeIntervalSince1970: 5_000)
        for status in [AgentToolCallStatus.succeeded, .failed, .denied] {
            let call = timedCall(status: status, startedAt: started)
            #expect(call.finishedAt == started)
        }
    }

    /// Status is written from a dozen places; the stamp lives on `didSet` so
    /// none of them can forget it.
    @Test("reaching a terminal status stamps the finish time exactly once")
    func terminalStatusStampsFinishTime() throws {
        var call = timedCall(status: .running, startedAt: Date())
        #expect(call.finishedAt == nil)

        call.status = .succeeded
        let firstStamp = try #require(call.finishedAt)

        // Re-asserting the same terminal status must not move the clock.
        call.status = .succeeded
        #expect(call.finishedAt == firstStamp)
    }

    /// A sandbox escalation puts a settled call back to work. Leaving the old
    /// finish time in place would show a frozen duration on a running step.
    @Test("a settled step that resumes drops its finish time and ticks again")
    func resumedStepClearsFinishTime() {
        var call = timedCall(status: .running, startedAt: Date())
        call.status = .failed
        #expect(call.finishedAt != nil)

        call.status = .running
        #expect(call.finishedAt == nil)
    }

    @Test("the row presentation carries both instants through")
    func presentationCarriesTiming() {
        let started = Date(timeIntervalSince1970: 9_000)
        var call = timedCall(status: .running, startedAt: started)
        call.status = .succeeded

        let presentation = AgentToolActivityRowPresentation(call: call)
        #expect(presentation.startedAt == started)
        #expect(presentation.finishedAt == call.finishedAt)
    }

    @Test("durations read as seconds, then minutes, then hours")
    func durationFormatting() {
        #expect(AgentToolActivityRowPresentation.formatDuration(0) == "0s")
        #expect(AgentToolActivityRowPresentation.formatDuration(42) == "42s")
        #expect(AgentToolActivityRowPresentation.formatDuration(60) == "1m 0s")
        #expect(AgentToolActivityRowPresentation.formatDuration(1_482) == "24m 42s")
        #expect(AgentToolActivityRowPresentation.formatDuration(3_600) == "1h 0m")
        // A clock that briefly reads backwards (system time adjustment)
        // must not render a negative duration.
        #expect(AgentToolActivityRowPresentation.formatDuration(-5) == "0s")
    }
}
