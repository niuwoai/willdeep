import Foundation
import Testing
@testable import WillDeep

/// The delegation card's job is to let someone decide whether to interrupt a
/// running Worker. Everything here defends one of the two things that made
/// that decision impossible to reach:
///
///  - chips that named a verb and dropped the object ("运行命令" three times
///    in a column, never saying which command);
///  - one row per utterance, so a Worker that spent three rounds calling one
///    tool each drew three lines holding one chip apiece.
@Suite
struct AgentSubagentCardLegibilityTests {

    // MARK: Tool objects

    @Test("file tools name the file, not the whole path")
    func fileToolsReportFileName() {
        let summary = AgentToolDisplay.objectSummary(
            toolName: "read_file",
            arguments: ["path": .string("/Users/rocky/Sites/Xedit/Xedit/AppState.swift")]
        )

        #expect(summary == "AppState.swift")
    }

    @Test("a command reports what it actually runs, label first")
    func commandsReportTheCommand() {
        let bare = AgentToolDisplay.objectSummary(
            toolName: "run_command",
            arguments: ["command": .string("yarn test --watch=false")]
        )
        let labelled = AgentToolDisplay.objectSummary(
            toolName: "run_command",
            arguments: [
                "command": .string("yarn test --watch=false"),
                "label": .string("跑前端单测")
            ]
        )

        #expect(bare == "yarn test --watch=false")
        #expect(labelled == "跑前端单测")
    }

    @Test("search tools report the pattern, falling back to the path")
    func searchToolsReportPattern() {
        #expect(
            AgentToolDisplay.objectSummary(
                toolName: "grep_files",
                arguments: ["pattern": .string("subagentIsWorking")]
            ) == "subagentIsWorking"
        )
        #expect(
            AgentToolDisplay.objectSummary(
                toolName: "grep_files",
                arguments: ["path": .string("Xedit/AgentSubagents.swift")]
            ) == "AgentSubagents.swift"
        )
    }

    @Test("a fetch reports the host rather than a URL nobody can read in a chip")
    func fetchReportsHost() {
        let summary = AgentToolDisplay.objectSummary(
            toolName: "web_fetch",
            arguments: ["url": .string("https://willdeep.com/docs/agent?section=subagents")]
        )

        #expect(summary == "willdeep.com")
    }

    /// A chip is one line inside a wrapping row. An unbounded command would
    /// push every sibling chip off it.
    @Test("an object longer than the chip budget is truncated with an ellipsis")
    func longObjectsAreTruncated() throws {
        let long = String(repeating: "x", count: AgentToolDisplay.objectSummaryCharacterLimit + 40)
        let summary = try #require(
            AgentToolDisplay.objectSummary(toolName: "run_command", arguments: ["command": .string(long)])
        )

        #expect(summary.count == AgentToolDisplay.objectSummaryCharacterLimit + 1)
        #expect(summary.hasSuffix("…"))
    }

    /// Same redaction the failed-command card already applies: which stored
    /// credential a command reaches for is not something to print in the
    /// transcript. This covers the placeholder form only — a key typed
    /// literally into a command is shown as typed, here as everywhere else.
    @Test("a secret placeholder is replaced before an object reaches a chip")
    func secretPlaceholdersAreRedacted() throws {
        let raw = "deploy --token ${secret:openai-key}"
        let summary = try #require(
            AgentToolDisplay.objectSummary(toolName: "run_command", arguments: ["command": .string(raw)])
        )

        #expect(summary == "deploy --token [secret]")

        // Redaction runs before truncation, so a placeholder far enough into
        // a long command loses its tail to the ellipsis rather than leaking
        // the identifier it named.
        let long = "curl -H 'Authorization: Bearer ${secret:openai-key}' https://api.example.com"
        let clipped = try #require(
            AgentToolDisplay.objectSummary(toolName: "run_command", arguments: ["command": .string(long)])
        )

        #expect(!clipped.contains("openai-key"))
    }

    @Test("a tool with nothing worth naming reports no object instead of inventing one")
    func unknownToolsReportNoObject() {
        #expect(AgentToolDisplay.objectSummary(toolName: "git_status", arguments: [:]) == nil)
        #expect(AgentToolDisplay.objectSummary(toolName: "read_file", arguments: [:]) == nil)
    }

    @Test("raw provider JSON takes the same path as parsed arguments")
    func rawArgumentsJSONIsDecoded() {
        let summary = AgentToolDisplay.objectSummary(
            toolName: "read_file",
            argumentsJSON: #"{"path":"Xedit/AgentSubagents.swift"}"#
        )

        #expect(summary == "AgentSubagents.swift")
        #expect(AgentToolDisplay.objectSummary(toolName: "read_file", argumentsJSON: "") == nil)
        #expect(AgentToolDisplay.objectSummary(toolName: "read_file", argumentsJSON: "not json") == nil)
    }

    // MARK: Row merging

    private func utterance(
        round: Int,
        text: String = "",
        tools: [String] = []
    ) -> AgentSubagentLiveActivity.Utterance {
        AgentSubagentLiveActivity.Utterance(
            round: round,
            text: text,
            tools: tools.map { AgentSubagentToolMention(name: $0) }
        )
    }

    @Test("consecutive rounds that only called tools collapse into one row")
    func silentRoundsMerge() throws {
        let rows = AgentSubagentSpeechTimeline.rows(
            utterances: [
                utterance(round: 11, tools: ["运行命令"]),
                utterance(round: 12, tools: ["运行命令"]),
                utterance(round: 13, tools: ["运行命令", "读取文件"])
            ],
            interventions: []
        )

        #expect(rows.count == 1)
        guard case .tools(let firstRound, let lastRound, let mentions) = try #require(rows.first) else {
            Issue.record("expected a merged tool row, got \(String(describing: rows.first))")
            return
        }
        #expect(firstRound == 11)
        #expect(lastRound == 13)
        #expect(mentions.map(\.name) == ["运行命令", "运行命令", "运行命令", "读取文件"])
    }

    /// A round the Worker spoke in is the card's anchor — it keeps its own
    /// row and its own round marker, and the silent runs on either side stay
    /// separate rather than swallowing it.
    @Test("a round with text splits the runs around it")
    func spokenRoundBreaksTheRun() {
        let rows = AgentSubagentSpeechTimeline.rows(
            utterances: [
                utterance(round: 1, tools: ["读取文件"]),
                utterance(round: 2, text: "先看看路由表", tools: ["grep_files"]),
                utterance(round: 3, tools: ["运行命令"]),
                utterance(round: 4, tools: ["运行命令"])
            ],
            interventions: []
        )

        #expect(rows.map(\.id) == ["tools-1-1", "speech-2", "tools-3-4"])
    }

    @Test("a correction lands above the round it takes effect in and breaks the run")
    func interventionBreaksTheRun() {
        let receipt = AgentSubagentLiveActivity.InterventionReceipt(
            id: UUID(),
            text: "先别改编码",
            mode: .nextRound,
            submittedAt: Date(timeIntervalSince1970: 10),
            requestedRound: 3,
            deliveryState: .applied(effectiveRound: 3)
        )
        let rows = AgentSubagentSpeechTimeline.rows(
            utterances: [
                utterance(round: 2, tools: ["读取文件"]),
                utterance(round: 3, tools: ["运行命令"])
            ],
            interventions: [receipt]
        )

        #expect(rows.count == 3)
        #expect(rows[0].id == "tools-2-2")
        if case .intervention(let carried) = rows[1] {
            #expect(carried.id == receipt.id)
        } else {
            Issue.record("expected the receipt to sit between the two rounds, got \(rows[1])")
        }
        #expect(rows[2].id == "tools-3-3")
    }

    /// Merging is meant to remove a wall of chips, so it must not build a
    /// bigger one: six silent rounds of eight tools each would otherwise put
    /// 48 chips on a single row.
    @Test("a merged run stops accumulating chips at the cap")
    func mergedRunIsCapped() throws {
        let utterances = (1...6).map {
            utterance(round: $0, tools: (0..<8).map { index in "tool\(index)" })
        }
        let rows = AgentSubagentSpeechTimeline.rows(utterances: utterances, interventions: [])

        guard case .tools(_, _, let mentions) = try #require(rows.first) else {
            Issue.record("expected a merged tool row")
            return
        }
        #expect(mentions.count == AgentSubagentSpeechTimeline.maximumMergedMentions)
    }

    @Test("a round that produced neither text nor tools contributes no row")
    func emptyRoundsAreDropped() {
        let rows = AgentSubagentSpeechTimeline.rows(
            utterances: [utterance(round: 1), utterance(round: 2, tools: ["读取文件"])],
            interventions: []
        )

        #expect(rows.map(\.id) == ["tools-2-2"])
    }

    // MARK: Row title

    @MainActor
    private func spawnCall(
        status: AgentToolCallStatus,
        activity: AgentSubagentLiveActivity?
    ) -> AgentToolCall {
        var call = AgentToolCall(
            messageID: UUID(),
            externalID: UUID().uuidString,
            toolName: "spawn_agent",
            arguments: ["label": .string("trace-all-gateway-requests")],
            risk: .write,
            status: status
        )
        call.subagentLiveActivity = activity
        return call
    }

    @MainActor
    private func liveActivity(round: Int, finishedAt: Date? = nil) -> AgentSubagentLiveActivity {
        var live = AgentSubagentLiveActivity(
            profileID: "scout",
            workerName: "侦察兵",
            model: "glm-5",
            round: round,
            maximumRounds: 18,
            completedToolInvocations: 16,
            activityText: "正在思考下一步",
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        live.finishedAt = finishedAt
        return live
    }

    /// Spawning takes milliseconds; the Worker then runs for minutes. A row
    /// still reading 「正在派生子代理」 at round 15 names a phase that ended
    /// fourteen rounds ago.
    @Test("the row stops claiming to be spawning once the Worker is reporting rounds")
    @MainActor
    func rowTitleFollowsThePhase() {
        let working = AgentToolActivityRowPresentation(
            call: spawnCall(status: .running, activity: liveActivity(round: 15))
        )
        let stillSpawning = AgentToolActivityRowPresentation(
            call: spawnCall(status: .running, activity: nil)
        )

        #expect(working.title == "子代理运行中")
        #expect(stillSpawning.title.contains("派生子代理"))
        #expect(working.detail == "trace-all-gateway-requests")
    }

    @Test("a finished Worker goes back to the settled spawn wording")
    @MainActor
    func finishedWorkerKeepsSettledTitle() {
        let finished = AgentToolActivityRowPresentation(
            call: spawnCall(
                status: .succeeded,
                activity: liveActivity(round: 15, finishedAt: Date(timeIntervalSince1970: 2_000))
            )
        )

        #expect(finished.title == "已派生子代理")
    }
}
