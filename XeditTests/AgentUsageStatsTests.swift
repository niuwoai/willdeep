//
//  AgentUsageStatsTests.swift
//  WillDeepTests
//
//  Split from AgentToolIntegrationTests.swift to keep files under the
//  repository file-size limit. Usage overview totals, streaks, heatmap,
//  price fallbacks, and delegated external usage separation.
//

import Testing
import Foundation
@testable import WillDeep

extension WillDeepTests {
    // MARK: - Usage stats

    private func makeSession(
        modelID: String?,
        providerID: String? = nil,
        providerDisplayName: String? = nil,
        messages: [AgentMessage]
    ) -> AgentSession {
        AgentSession(
            id: UUID(),
            title: "test",
            workspaceRootPath: nil,
            modelID: modelID,
            providerID: providerID,
            providerDisplayName: providerDisplayName,
            createdAt: Date(),
            updatedAt: Date(),
            messages: messages
        )
    }

    private func userMessage(_ text: String, at date: Date) -> AgentMessage {
        AgentMessage(role: .user, content: text, createdAt: date)
    }

    private func assistantMessage(_ text: String, usage: Int?, at date: Date) -> AgentMessage {
        AgentMessage(role: .assistant, content: text, usageTokens: usage, createdAt: date)
    }

    private func meteredAssistantMessage(
        prompt: Int,
        completion: Int,
        cachedPrompt: Int = 0,
        cacheWritePrompt: Int = 0
    ) -> AgentMessage {
        AgentMessage(
            role: .assistant,
            content: "ok",
            usageTokens: prompt + completion,
            promptTokens: prompt,
            completionTokens: completion,
            cachedPromptTokens: cachedPrompt,
            cacheWritePromptTokens: cacheWritePrompt
        )
    }

    @Test("AgentUsageStats overview totals across sessions and prefers real usage")
    func testUsageStatsBasicTotals() {
        let now = Date()
        let calendar = Calendar.current
        let session = makeSession(modelID: "gpt-4.1", messages: [
            userMessage("hello", at: now),
            assistantMessage("hi", usage: 100, at: now),
            userMessage("hello again", at: now),
            // No real usage → fall back to chars/4 estimate (≈ 20/4 = 5)
            assistantMessage(String(repeating: "x", count: 20), usage: nil, at: now)
        ])
        let stats = AgentUsageStats.overview(for: [session], now: now)
        #expect(stats.sessionCount == 1)
        #expect(stats.messageCount == 4)
        #expect(stats.hasAnyRealUsage == true)
        // 100 (real) + 5 (estimate from 20 chars) ≥ 105 plus the
        // user messages and system-prompt baseline are 0 for users
        // (estimator only on assistant in production? our estimate
        // function is applied to all messages without usage — verify).
        #expect(stats.totalTokens >= 100)
        #expect(stats.favoriteModel == "gpt-4.1")
        _ = calendar
    }

    @Test("AgentUsageStats measures persisted work ledgers and used capabilities")
    func testUsageStatsTracksWorkAndCapabilityData() {
        let now = Date()
        let toolCalls = [
            AgentMessageToolCall(externalID: "read", toolName: "read_file", argumentsJSON: "{}"),
            AgentMessageToolCall(externalID: "command", toolName: "run_command", argumentsJSON: "{}"),
            AgentMessageToolCall(externalID: "research", toolName: "web_search", argumentsJSON: "{}"),
            AgentMessageToolCall(externalID: "image", toolName: "generate_image", argumentsJSON: "{}")
        ]
        let session = AgentSession(
            title: "dashboard work",
            workspaceRootPath: "/tmp/dashboard-work",
            createdAt: now,
            updatedAt: now,
            messages: [
                userMessage("build the dashboard", at: now),
                AgentMessage(role: .assistant, content: "working", toolCalls: toolCalls, createdAt: now),
                AgentMessage(role: .workflowReport, content: "", createdAt: now)
            ],
            agentEditedPaths: ["Xedit/AgentUsageStats.swift", "Xedit/AgentStatusIndicators.swift"],
            agentArtifactPaths: ["docs/dashboard-notes.md"]
        )

        let stats = AgentUsageStats.overview(for: [session], now: now)
        let capabilityCounts = Dictionary(
            uniqueKeysWithValues: AgentUsageStats.capabilityUsage(for: [session]).map { ($0.capability, $0.callCount) }
        )

        #expect(stats.userTurnCount == 1)
        #expect(stats.toolCallCount == 4)
        #expect(stats.editedFileCount == 2)
        #expect(stats.artifactCount == 1)
        #expect(stats.workflowCount == 1)
        #expect(stats.workspaceCount == 1)
        #expect(capabilityCounts[.workspace] == 1)
        #expect(capabilityCounts[.terminal] == 1)
        #expect(capabilityCounts[.research] == 1)
        #expect(capabilityCounts[.media] == 1)
    }

    @Test("AgentUsageStats builds this week's deliverables and explicit failure review")
    func testUsageStatsBuildsWorkbenchRows() {
        let calendar = Calendar(identifier: .gregorian)
        let now = ISO8601DateFormatter().date(from: "2026-07-13T08:00:00Z")!
        let recent = AgentUsageSessionSnapshot(
            id: UUID(),
            modelID: nil,
            providerID: nil,
            providerDisplayName: nil,
            createdAt: now,
            updatedAt: now,
            messages: [
                AgentUsageMessageSnapshot(
                    role: .assistant,
                    contentCharacterCount: 0,
                    toolCallNames: ["run_command"],
                    toolCallExternalIDs: ["command-1"],
                    createdAt: now
                ),
                AgentUsageMessageSnapshot(
                    role: .tool,
                    contentCharacterCount: 0,
                    toolCallID: "command-1",
                    toolCallStatus: .failed,
                    toolErrorMessage: "Command exited with status 1",
                    createdAt: now
                )
            ],
            artifactPaths: ["reports/weekly-summary.md"]
        )
        let old = AgentUsageSessionSnapshot(
            id: UUID(),
            modelID: nil,
            providerID: nil,
            providerDisplayName: nil,
            createdAt: now.addingTimeInterval(-14 * 86_400),
            updatedAt: now.addingTimeInterval(-14 * 86_400),
            messages: [],
            artifactPaths: ["reports/old-summary.md"]
        )

        let deliverables = AgentUsageStats.weeklyDeliverables(for: [recent, old], now: now, calendar: calendar)
        let failures = AgentUsageStats.failedToolCallReview(for: [recent, old], now: now, calendar: calendar)

        #expect(deliverables.map(\.displayName) == ["weekly-summary.md"])
        #expect(deliverables.first?.sessionCount == 1)
        #expect(failures.count == 1)
        #expect(failures.first?.toolName == "run_command")
        #expect(failures.first?.errorSummary == "Command exited with status 1")
    }

    @Test("AgentUsageStats labels managed-routing sessions 省心托管, leaves legacy nils as unknown-model")
    func testUsageStatsManagedRoutingModelLabel() {
        let now = Date()
        func assistant(_ tokens: Int) -> AgentUsageMessageSnapshot {
            AgentUsageMessageSnapshot(
                role: .assistant,
                contentCharacterCount: 40,
                usageTokens: tokens,
                createdAt: now
            )
        }
        // Managed session: modelID is nil (cleared at persist because routing
        // is per-turn) but isManagedRouting is true → one "省心托管" row.
        let managed = AgentUsageSessionSnapshot(
            id: UUID(),
            modelID: nil,
            providerID: "some-im",
            providerDisplayName: "some.im",
            createdAt: now,
            updatedAt: now,
            messages: [assistant(100)],
            isManagedRouting: true
        )
        // Legacy session: modelID also nil, but NOT managed → must stay
        // unknown-model, never fold into 省心托管.
        let legacy = AgentUsageSessionSnapshot(
            id: UUID(),
            modelID: nil,
            providerID: "some-im",
            providerDisplayName: "some.im (Rocky's relay)",
            createdAt: now,
            updatedAt: now,
            messages: [assistant(50)],
            isManagedRouting: false
        )
        let rows = AgentUsageStats.modelUsage(for: [managed, legacy])
        let managedRow = rows.first { $0.modelID == "省心托管" }
        let unknownRow = rows.first { $0.modelID == "unknown-model" }
        #expect(managedRow != nil)
        #expect(managedRow?.messageCount == 1)
        #expect(managedRow?.providerName == "some.im")
        #expect(unknownRow != nil)
        #expect(unknownRow?.messageCount == 1)
        #expect(unknownRow?.providerName == "some.im")
    }

    @Test("lightweight usage decode preserves managed routing and worker profiles")
    func testUsageSnapshotDecodePreservesManagedRoutingAndWorkers() throws {
        let now = Date()
        let calls = [
            AgentMessageToolCall(
                externalID: "scout",
                toolName: "spawn_agent",
                argumentsJSON: #"{"profile":"scout","prompt":"locate it"}"#
            ),
            AgentMessageToolCall(
                externalID: "default",
                toolName: "spawn_agent",
                argumentsJSON: #"{"prompt":"investigate it"}"#
            )
        ]
        var session = makeSession(
            modelID: nil,
            providerID: AgentProviderPreset.someIMID,
            messages: [
                AgentMessage(role: .assistant, content: "working", toolCalls: calls, createdAt: now)
            ]
        )
        session.managedRouting = AgentManagedRoutingState()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapshot = try AgentSessionStore.decodeUsageSnapshot(
            from: encoder.encode(session)
        )

        #expect(snapshot.isManagedRouting)
        #expect(snapshot.messages.first?.subagentProfileIDs == ["scout", "deep"])
    }

    @Test("AgentUsageStats groups worker calls and distinct chats by normalized profile")
    func testUsageStatsGroupsSubagentWorkers() {
        func spawn(_ id: String, profile: String?) -> AgentMessageToolCall {
            let arguments: String
            if let profile {
                arguments = #"{"profile":"\#(profile)","prompt":"work"}"#
            } else {
                arguments = #"{"prompt":"work"}"#
            }
            return AgentMessageToolCall(
                externalID: id,
                toolName: "spawn_agent",
                argumentsJSON: arguments
            )
        }

        let first = makeSession(modelID: "gpt-5", messages: [
            AgentMessage(role: .assistant, content: "", toolCalls: [
                spawn("s1", profile: "scout"),
                spawn("s2", profile: "SCOUT"),
                spawn("d1", profile: nil),
                spawn("unknown", profile: "retired-worker")
            ])
        ])
        let second = makeSession(modelID: "gpt-5", messages: [
            AgentMessage(role: .assistant, content: "", toolCalls: [
                spawn("s3", profile: "scout"),
                spawn("r1", profile: "reader")
            ])
        ])

        let snapshots = [first, second].map(AgentUsageSessionSnapshot.init(session:))
        let rows = AgentUsageStats.subagentUsage(for: snapshots)
        let model = AgentUsageStats.dashboardModel(for: snapshots)

        #expect(rows.first { $0.profileID == "scout" }?.invocationCount == 3)
        #expect(rows.first { $0.profileID == "scout" }?.sessionCount == 2)
        #expect(rows.first { $0.profileID == "deep" }?.invocationCount == 2)
        #expect(rows.first { $0.profileID == "deep" }?.sessionCount == 1)
        #expect(rows.first { $0.profileID == "reader" }?.invocationCount == 1)
        #expect(model.subagentSessionCount == 2)
    }

    @Test("AgentUsageStats current streak counts contiguous days ending today")
    func testUsageStatsCurrentStreak() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let dayBefore = calendar.date(byAdding: .day, value: -2, to: today)!
        let oldDay = calendar.date(byAdding: .day, value: -10, to: today)!

        let messages = [
            userMessage("a", at: oldDay),
            userMessage("b", at: dayBefore),
            userMessage("c", at: yesterday),
            userMessage("d", at: today)
        ]
        let session = makeSession(modelID: nil, messages: messages)
        let stats = AgentUsageStats.overview(for: [session], now: now)
        #expect(stats.activeDays == 4)
        #expect(stats.currentStreak == 3)
        #expect(stats.longestStreak == 3)
    }

    @Test("AgentUsageStats current streak preserves yesterday run when today is empty")
    func testUsageStatsCurrentStreakPreservesYesterdayRunWhenTodayEmpty() {
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let dayBefore = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: now))!

        let messages = [
            userMessage("a", at: dayBefore),
            userMessage("b", at: yesterday)
        ]
        let session = makeSession(modelID: nil, messages: messages)
        let stats = AgentUsageStats.overview(for: [session], now: now)
        #expect(stats.currentStreak == 2)
        #expect(stats.longestStreak == 2)
    }

    @Test("AgentUsageStats current streak is zero after missing yesterday and today")
    func testUsageStatsCurrentStreakZeroAfterGap() {
        let calendar = Calendar.current
        let now = Date()
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: now))!
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: now))!

        let messages = [
            userMessage("a", at: threeDaysAgo),
            userMessage("b", at: twoDaysAgo)
        ]
        let session = makeSession(modelID: nil, messages: messages)
        let stats = AgentUsageStats.overview(for: [session], now: now)
        #expect(stats.currentStreak == 0)
        #expect(stats.longestStreak == 2)
    }

    @Test("AgentUsageStats streaks stay all-time when dashboard range is filtered")
    func testUsageStatsStreaksIgnoreDashboardRange() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let messages = (0..<31).map { offset in
            userMessage(
                "day \(offset)",
                at: calendar.date(byAdding: .day, value: -offset, to: today)!
            )
        }
        let fullSnapshot = AgentUsageSessionSnapshot(
            session: makeSession(modelID: nil, messages: messages)
        )
        var filteredSnapshot = fullSnapshot
        filteredSnapshot.messages = fullSnapshot.messages.filter {
            $0.createdAt >= calendar.date(byAdding: .hour, value: -24, to: now)!
        }

        let stats = AgentUsageStats.overview(
            for: [filteredSnapshot],
            allTimeStreakSessions: [fullSnapshot],
            now: now
        )

        #expect(stats.activeDays <= 2)
        #expect(stats.currentStreak == 31)
        #expect(stats.longestStreak == 31)
    }

    @Test("AgentUsageStats heatmap returns daily request and Token totals in chronological order")
    func testUsageStatsHeatmapShape() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today)!

        let messages = [
            AgentMessage(role: .user, content: "first", usageTokens: 10, createdAt: today),
            AgentMessage(role: .user, content: "second", usageTokens: 20, createdAt: today),
            assistantMessage("a", usage: 120, at: today),
            assistantMessage("b", usage: 80, at: today),
            AgentMessage(role: .user, content: "earlier", usageTokens: 5, createdAt: threeDaysAgo),
            assistantMessage("c", usage: 50, at: threeDaysAgo)
        ]
        let session = makeSession(modelID: nil, messages: messages)
        let cells = AgentUsageStats.heatmap(for: [session], weekCount: 4, now: now)

        #expect(cells.count == 4)
        for column in cells { #expect(column.count == 7) }

        let flat = cells.flatMap { $0 }
        let todayCell = flat.first { calendar.isDate($0.date, inSameDayAs: today) }
        let earlierCell = flat.first { calendar.isDate($0.date, inSameDayAs: threeDaysAgo) }
        #expect(todayCell?.requestCount == 2)
        #expect(todayCell?.tokenCount == 230)
        #expect(earlierCell?.requestCount == 1)
        #expect(earlierCell?.tokenCount == 55)
    }

    @Test("AgentUsageStats falls back to built-in public prices for custom GPT models")
    func testUsageStatsPublicPriceFallbackForGPTModels() {
        let session = makeSession(
            modelID: "openai/gpt-5.5",
            providerID: "custom",
            providerDisplayName: "Relay",
            messages: [
                meteredAssistantMessage(prompt: 1_000_000, completion: 1_000_000, cachedPrompt: 200_000)
            ]
        )

        let row = AgentUsageStats.modelUsage(for: [session]).first

        #expect(row?.providerID == "custom")
        #expect(row?.modelID == "openai/gpt-5.5")
        #expect(abs((row?.estimatedCostUSD ?? 0) - 34.1) < 0.000_001)
    }

    @Test("AgentUsageStats falls back to built-in public prices for DeepSeek aliases")
    func testUsageStatsPublicPriceFallbackForDeepSeekAliases() {
        let session = makeSession(
            modelID: "deepseek-chat",
            providerID: "openai-compatible",
            messages: [
                meteredAssistantMessage(prompt: 1_000_000, completion: 1_000_000, cachedPrompt: 500_000)
            ]
        )

        let row = AgentUsageStats.modelUsage(for: [session]).first

        #expect(row?.modelID == "deepseek-chat")
        #expect(abs((row?.estimatedCostUSD ?? 0) - 0.3514) < 0.000_001)
    }

    @Test("AgentUsageStats falls back to built-in public prices for Qwen models")
    func testUsageStatsPublicPriceFallbackForQwenModels() {
        let session = makeSession(
            modelID: "qwen-plus",
            providerID: "custom",
            messages: [
                meteredAssistantMessage(prompt: 1_000_000, completion: 1_000_000)
            ]
        )

        let row = AgentUsageStats.modelUsage(for: [session]).first

        #expect(row?.modelID == "qwen-plus")
        #expect(abs((row?.estimatedCostUSD ?? 0) - 0.39) < 0.000_001)
    }

    @Test("AgentUsageStats falls back to built-in public prices for Kimi models")
    func testUsageStatsPublicPriceFallbackForKimiModels() {
        let session = makeSession(
            modelID: "kimi-k2.6",
            providerID: "openai-compatible",
            messages: [
                meteredAssistantMessage(prompt: 1_000_000, completion: 1_000_000, cachedPrompt: 500_000)
            ]
        )

        let row = AgentUsageStats.modelUsage(for: [session]).first
        let expected = 30.8 / 7.2

        #expect(row?.modelID == "kimi-k2.6")
        #expect(abs((row?.estimatedCostUSD ?? 0) - expected) < 0.000_001)
    }

    @Test("AgentUsageStats falls back to built-in public prices for Moonshot V1 models")
    func testUsageStatsPublicPriceFallbackForMoonshotModels() {
        let session = makeSession(
            modelID: "moonshot-v1-8k",
            providerID: "custom",
            messages: [
                meteredAssistantMessage(prompt: 1_000_000, completion: 1_000_000)
            ]
        )

        let row = AgentUsageStats.modelUsage(for: [session]).first
        let expected = 12.0 / 7.2

        #expect(row?.modelID == "moonshot-v1-8k")
        #expect(abs((row?.estimatedCostUSD ?? 0) - expected) < 0.000_001)
    }

    @Test("AgentUsageStats falls back to built-in public prices for GLM models")
    func testUsageStatsPublicPriceFallbackForGLMModels() {
        let session = makeSession(
            modelID: "glm-4.5",
            providerID: "custom",
            messages: [
                meteredAssistantMessage(prompt: 1_000_000, completion: 1_000_000)
            ]
        )

        let row = AgentUsageStats.modelUsage(for: [session]).first
        let expected = 2.8 / 7.2

        #expect(row?.modelID == "glm-4.5")
        #expect(abs((row?.estimatedCostUSD ?? 0) - expected) < 0.000_001)
    }

    @Test("AgentUsageStats keeps delegated external CLI usage separate")
    func testUsageStatsSeparatesDelegatedExternalUsage() {
        let delegated = AgentMessage(
            role: .assistant,
            content: "done by codex",
            origin: .delegatedExternal,
            originLabel: "Codex"
        )
        let session = makeSession(
            modelID: "gpt-5",
            providerID: "openai",
            messages: [
                meteredAssistantMessage(prompt: 1_000, completion: 200, cachedPrompt: 500),
                delegated
            ]
        )

        let rows = AgentUsageStats.modelUsage(for: [session])
        let native = rows.first { $0.providerID == "openai" }
        let external = rows.first { $0.providerID == "delegated-external" }

        #expect(native?.messageCount == 1)
        #expect(native?.cacheHitRate == 0.5)
        #expect(external?.modelID == "Codex")
        #expect(external?.isDelegatedExternal == true)
        #expect(external?.estimatedCostUSD == nil)
    }

    // MARK: - Dashboard model bundle & memoization

    @Test("dashboardModel bundles the same aggregates as the individual helpers")
    func testDashboardModelMatchesIndividualHelpers() {
        let now = Date()
        let earlier = now.addingTimeInterval(-90)
        let toolCalls = [
            AgentMessageToolCall(externalID: "a", toolName: "read_file", argumentsJSON: "{}"),
            AgentMessageToolCall(externalID: "b", toolName: "read_file", argumentsJSON: "{}"),
            AgentMessageToolCall(externalID: "c", toolName: "web_search", argumentsJSON: "{}")
        ]
        let sessions = [
            makeSession(modelID: "gpt-4.1", messages: [
                userMessage("hi", at: earlier),
                AgentMessage(role: .assistant, content: "ok", toolCalls: toolCalls, usageTokens: 4_000, createdAt: now)
            ]),
            makeSession(modelID: "claude-sonnet-5", messages: [
                userMessage("solo", at: now)
            ])
        ].map { AgentUsageSessionSnapshot(session: $0) }

        let model = AgentUsageStats.dashboardModel(for: sessions, heatmapWeekCount: 4, now: now)

        #expect(model.overview == AgentUsageStats.overview(for: sessions, now: now))
        #expect(model.modelUsage == AgentUsageStats.modelUsage(for: sessions))
        #expect(model.capabilityUsage == AgentUsageStats.capabilityUsage(for: sessions))
        #expect(model.heatmapCells == AgentUsageStats.heatmap(for: sessions, weekCount: 4, now: now))
        // 4_000 real-usage tokens dominate the first session; the second
        // has a single estimated user message.
        #expect(model.peakTaskTokenCount >= 4_000)
        #expect(abs(model.longestTaskDuration - 90) < 0.001)
        #expect(model.managedRoutingRate == 0)
        #expect(model.uniqueToolCount == 2)
    }

    @Test("longest task duration bills active work, not the session's shelf life")
    func testLongestTaskDurationCapsIdleGaps() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let cap = AgentUsageStats.taskIdleCapSeconds

        // Reproduces the shape that made the dashboard read 8d3h5m: a busy
        // conversation interrupted by two multi-day pauses.
        let interrupted = makeSession(modelID: "gpt-4.1", messages: [
            userMessage("start", at: start),
            assistantMessage("ok", usage: 10, at: start.addingTimeInterval(60)),
            userMessage("resumed three days later", at: start.addingTimeInterval(3 * 86_400)),
            assistantMessage("ok", usage: 10, at: start.addingTimeInterval(3 * 86_400 + 120)),
            userMessage("and again", at: start.addingTimeInterval(8 * 86_400)),
            assistantMessage("ok", usage: 10, at: start.addingTimeInterval(8 * 86_400 + 30))
        ])
        let snapshots = [interrupted].map { AgentUsageSessionSnapshot(session: $0) }
        let model = AgentUsageStats.dashboardModel(for: snapshots, heatmapWeekCount: 2, now: start)

        // 60 + 120 + 30 seconds of real work, plus the two pauses billed at
        // the cap instead of at three and five days.
        #expect(abs(model.longestTaskDuration - (210 + 2 * cap)) < 0.001)
        #expect(model.longestTaskDuration < 86_400)
    }

    @Test("a gap shorter than the idle cap is billed in full")
    func testLongestTaskDurationKeepsShortGaps() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = makeSession(modelID: "gpt-4.1", messages: [
            userMessage("hi", at: start),
            assistantMessage("thinking", usage: 10, at: start.addingTimeInterval(300)),
            userMessage("more", at: start.addingTimeInterval(600))
        ])
        let snapshots = [session].map { AgentUsageSessionSnapshot(session: $0) }
        let model = AgentUsageStats.dashboardModel(for: snapshots, heatmapWeekCount: 2, now: start)

        #expect(abs(model.longestTaskDuration - 600) < 0.001)
    }

    @Test("a single-message session has no measurable duration")
    func testLongestTaskDurationIgnoresSoloMessages() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = makeSession(modelID: "gpt-4.1", messages: [userMessage("solo", at: start)])
        let snapshots = [session].map { AgentUsageSessionSnapshot(session: $0) }
        let model = AgentUsageStats.dashboardModel(for: snapshots, heatmapWeekCount: 2, now: start)

        #expect(model.longestTaskDuration == 0)
    }

    @Test("dashboardModel on empty snapshots yields zeroed metrics")
    func testDashboardModelEmptyInput() {
        let model = AgentUsageStats.dashboardModel(for: [], heatmapWeekCount: 2)
        #expect(model.overview.sessionCount == 0)
        #expect(model.peakTaskTokenCount == 0)
        #expect(model.longestTaskDuration == 0)
        #expect(model.managedRoutingRate == 0)
        #expect(model.reasoningUsageRate == 0)
        #expect(model.subagentUsage.isEmpty)
        #expect(model.subagentSessionCount == 0)
        #expect(model.uniqueToolCount == 0)
    }

    @Test("AppState memoizes the dashboard model until snapshots change")
    func testAppStateDashboardModelMemoization() {
        let appState = AppState()
        let baseline = appState.agentUsageStatsRevision
        let session = makeSession(modelID: "gpt-4.1", messages: [
            userMessage("hello", at: Date())
        ])

        let emptyModel = appState.agentUsageDashboardModel()
        #expect(emptyModel.overview.sessionCount == 0)
        // Cache hit: same revision, no snapshot writes in between.
        #expect(appState.agentUsageDashboardModel() == emptyModel)
        #expect(appState.agentUsageStatsRevision == baseline)

        appState.agentUsageSnapshots = [AgentUsageSessionSnapshot(session: session)]
        #expect(appState.agentUsageStatsRevision > baseline)
        let updated = appState.agentUsageDashboardModel()
        #expect(updated.overview.sessionCount == 1)
        #expect(updated.overview.userTurnCount == 1)
    }

    @Test("startNewAgentSession keeps usage snapshots most-recent-first without a full sort")
    func testUsageSnapshotOrderAfterNewSessions() {
        let appState = AppState()
        let first = appState.startNewAgentSession()
        let second = appState.startNewAgentSession()

        let ids = appState.agentUsageSnapshots.map(\.id)
        #expect(ids.contains(first.id))
        #expect(ids.contains(second.id))
        let stamps = appState.agentUsageSnapshots.map(\.updatedAt)
        #expect(stamps == stamps.sorted(by: >))
    }
}
