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

    @Test("an utterance carries the round's public text and its tool names")
    func recordsUtterance() {
        var live = activity()
        live.recordUtterance(round: 1, text: "  先看路由表  ", toolNames: ["grep_files", "read_file"])

        #expect(live.utterances.count == 1)
        #expect(live.utterances[0].round == 1)
        #expect(live.utterances[0].text == "先看路由表")
        #expect(live.utterances[0].toolNames == ["grep_files", "read_file"])
    }

    /// A round publishes more than once — text arrives with the assistant
    /// message, tool names with the same heartbeat. Stacking both would show
    /// the round twice in the card.
    @Test("re-publishing the same round replaces its utterance instead of stacking")
    func republishingRoundReplaces() {
        var live = activity()
        live.recordUtterance(round: 2, text: "第一版", toolNames: [])
        live.recordUtterance(round: 2, text: "第二版", toolNames: ["run_command"])

        #expect(live.utterances.count == 1)
        #expect(live.utterances[0].text == "第二版")
        #expect(live.utterances[0].toolNames == ["run_command"])
    }

    @Test("a heartbeat with neither text nor tools records nothing")
    func emptyHeartbeatIsIgnored() {
        var live = activity()
        live.recordUtterance(round: 1, text: "   \n  ", toolNames: [])

        #expect(live.utterances.isEmpty)
    }

    /// The card is not the inspector. Keeping every round of a long run would
    /// grow one transcript cell without bound; the tail is what is being read.
    @Test("only the newest rounds are kept, oldest dropped first")
    func utterancesAreCappedToTheTail() {
        var live = activity()
        for round in 1...(AgentSubagentLiveActivity.maxUtterances + 3) {
            live.recordUtterance(round: round, text: "round \(round)", toolNames: [])
        }

        #expect(live.utterances.count == AgentSubagentLiveActivity.maxUtterances)
        #expect(live.utterances.first?.round == 4)
        #expect(live.utterances.last?.round == AgentSubagentLiveActivity.maxUtterances + 3)
    }

    @Test("utterance text and tool lists are clamped")
    func utteranceContentIsClamped() {
        var live = activity()
        let long = String(repeating: "字", count: AgentSubagentLiveActivity.utteranceCharacterLimit + 200)
        let manyTools = (0..<(AgentSubagentLiveActivity.maxToolNamesPerUtterance + 5)).map { "tool\($0)" }
        live.recordUtterance(round: 1, text: long, toolNames: manyTools)

        #expect(live.utterances[0].text.count == AgentSubagentLiveActivity.utteranceCharacterLimit)
        #expect(live.utterances[0].toolNames.count == AgentSubagentLiveActivity.maxToolNamesPerUtterance)
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

    /// The bug this replaced: the strip described whichever call happened to
    /// be last in the array and never said that others existed.
    @Test("several running Workers are counted, and the count leads the label")
    func fleetCountsEveryRunningWorker() throws {
        let calls = [
            spawnCall(status: .running, activity: activity(profileID: "scout", workerName: "侦察兵", round: 1)),
            spawnCall(status: .running, activity: activity(profileID: "tester", workerName: "测试员", round: 4)),
            spawnCall(status: .running, activity: activity(profileID: "reader", workerName: "阅读者", round: 2)),
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
    @Test("trade colours are stable and spread across the palette")
    func tradeColoursAreStableAndDistinct() {
        #expect(
            AgentSubagentTradePalette.color(forProfileID: "scout")
                == AgentSubagentTradePalette.color(forProfileID: "scout")
        )
        let ids = ["scout", "reader", "deep", "editor", "tester", "reviewer", "ops_runner"]
        let distinct = Set(ids.map { String(describing: AgentSubagentTradePalette.color(forProfileID: $0)) })
        #expect(distinct.count >= 4)
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
        #expect(update.toolNames.isEmpty)
        #expect(update.displayText.contains("2"))
    }
}
