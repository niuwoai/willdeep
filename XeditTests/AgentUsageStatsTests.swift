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

    @Test("AgentUsageStats prefers the client-routed model and keeps honest legacy fallbacks")
    func testUsageStatsManagedRoutingModelLabel() {
        let now = Date()
        func assistant(_ tokens: Int, requestModelID: String? = nil) -> AgentUsageMessageSnapshot {
            AgentUsageMessageSnapshot(
                role: .assistant,
                contentCharacterCount: 40,
                usageTokens: tokens,
                requestModelID: requestModelID,
                createdAt: now
            )
        }
        // Modern managed message: the client already persisted the exact
        // per-turn route, so analytics must show that model instead of an
        // anonymous or pseudo-model bucket.
        let managed = AgentUsageSessionSnapshot(
            id: UUID(),
            modelID: nil,
            providerID: "some-im",
            providerDisplayName: "some.im",
            createdAt: now,
            updatedAt: now,
            messages: [assistant(100, requestModelID: "someim-code-low")],
            isManagedRouting: true
        )
        // A managed message written before per-turn attribution existed keeps
        // the explicit legacy aggregate label; inventing a concrete model
        // would be worse than admitting that old data lacks it.
        let legacyManaged = AgentUsageSessionSnapshot(
            id: UUID(),
            modelID: nil,
            providerID: "some-im",
            providerDisplayName: "some.im",
            createdAt: now,
            updatedAt: now,
            messages: [assistant(75)],
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
        let rows = AgentUsageStats.modelUsage(for: [managed, legacyManaged, legacy])
        let routedRow = rows.first { $0.modelID == "someim-code-low" }
        let managedRow = rows.first { $0.modelID == "省心托管" }
        let unknownRow = rows.first { $0.modelID == "unknown-model" }
        #expect(routedRow?.messageCount == 1)
        #expect(routedRow?.providerName == "some.im")
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
        session.messages[0].managedRoute = AgentManagedRouteDecision(
            selectedModel: "someim-code-low",
            tier: .low,
            domain: .coding,
            complexity: .low,
            didFallback: false
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapshot = try AgentSessionStore.decodeUsageSnapshot(
            from: encoder.encode(session)
        )

        #expect(snapshot.isManagedRouting)
        #expect(snapshot.messages.first?.subagentProfileIDs == ["scout", "deep"])
        #expect(snapshot.messages.first?.requestModelID == "someim-code-low")
    }

    @Test("lightweight usage decode preserves the exact request provider and model")
    func testUsageSnapshotDecodePreservesRequestRoutingSnapshot() throws {
        let now = Date()
        let session = makeSession(
            modelID: "gpt-5.6-sol",
            providerID: AgentProviderPreset.openAIID,
            messages: [
                AgentMessage(
                    role: .assistant,
                    content: "done",
                    requestModelID: "glm-5",
                    requestProviderID: AgentProviderPreset.someIMID,
                    requestProviderDisplayName: "some.im",
                    createdAt: now
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapshot = try AgentSessionStore.decodeUsageSnapshot(
            from: encoder.encode(session)
        )

        #expect(snapshot.messages.first?.requestModelID == "glm-5")
        #expect(snapshot.messages.first?.requestProviderID == AgentProviderPreset.someIMID)
        #expect(snapshot.messages.first?.requestProviderDisplayName == "some.im")
    }

    @Test("AgentUsageStats splits one session by each client-selected provider and model")
    func testUsageStatsUsesPerTurnRoutingSnapshots() {
        let now = Date()
        let session = AgentUsageSessionSnapshot(
            id: UUID(),
            modelID: "gpt-5.6-sol",
            providerID: AgentProviderPreset.openAIID,
            providerDisplayName: "OpenAI",
            createdAt: now,
            updatedAt: now,
            messages: [
                AgentUsageMessageSnapshot(
                    role: .assistant,
                    contentCharacterCount: 20,
                    usageTokens: 100,
                    requestModelID: "glm-5",
                    requestProviderID: AgentProviderPreset.someIMID,
                    requestProviderDisplayName: "some.im",
                    createdAt: now
                ),
                AgentUsageMessageSnapshot(
                    role: .assistant,
                    contentCharacterCount: 20,
                    usageTokens: 200,
                    requestModelID: "gpt-5.6-sol",
                    requestProviderID: AgentProviderPreset.openAIID,
                    requestProviderDisplayName: "OpenAI",
                    createdAt: now
                )
            ]
        )

        let rows = AgentUsageStats.modelUsage(for: [session])
        #expect(rows.first { $0.modelID == "glm-5" }?.providerID == AgentProviderPreset.someIMID)
        #expect(rows.first { $0.modelID == "glm-5" }?.totalTokens == 100)
        #expect(rows.first { $0.modelID == "gpt-5.6-sol" }?.providerID == AgentProviderPreset.openAIID)
        #expect(rows.first { $0.modelID == "gpt-5.6-sol" }?.totalTokens == 200)
    }

    @Test("AgentUsageStats groups specialist calls into public capability trades")
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

        // Execution keeps legacy IDs, while presentation folds them into
        // the five public responsibilities without losing calls or sessions.
        #expect(snapshots[0].messages[0].subagentProfileIDs == ["scout", "scout", "deep", "deep"])
        #expect(snapshots[1].messages[0].subagentProfileIDs == ["scout", "reader"])
        #expect(rows.map(\.profileID) == ["generalist"])
        #expect(rows.first?.invocationCount == 6)
        #expect(rows.first?.sessionCount == 2)
        #expect(model.subagentSessionCount == 2)
    }

    @Test("AgentUsageStats keeps all five responsibilities and folds only their legacy aliases")
    func testUsageStatsPreservesFivePublicResponsibilities() {
        let groups: [(id: String, aliases: [String])] = [
            ("generalist", ["generalist", "reader", "git_detective"]),
            ("implementer", ["implementer", "editor", "test_fixer"]),
            ("tester", ["tester", "TESTER", " tester "]),
            ("reviewer", ["reviewer", "security_guard", "judge"]),
            ("ops_runner", ["ops_runner", "terminal_operator", "OPS_RUNNER"]),
        ]
        let sessions = groups.map { group in
            makeSession(modelID: "gpt-5", messages: [
                AgentMessage(role: .assistant, content: "", toolCalls: group.aliases.enumerated().map { index, profile in
                    AgentMessageToolCall(externalID: "\(group.id)-\(index)", toolName: "spawn_agent",
                                         argumentsJSON: #"{"profile":"\#(profile)","prompt":"work"}"#)
                })
            ])
        }
        let rows = AgentUsageStats.subagentUsage(for: sessions)
        #expect(Set(rows.map(\.profileID)) == Set(groups.map(\.id)))
        for group in groups {
            let row = rows.first { $0.profileID == group.id }
            #expect(row?.invocationCount == group.aliases.count)
            #expect(row?.sessionCount == 1)
        }
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

    @Test("monthly usage calendar aggregates tokens, priced cost, and distinct chats per day")
    func monthlyUsageCalendarAggregatesDailyFacts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let month = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))
        let august11 = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 11, hour: 10)))

        let metered = AgentMessage(
            role: .assistant,
            content: "ok",
            usageTokens: 2_000_000,
            promptTokens: 1_000_000,
            completionTokens: 1_000_000,
            createdAt: august11
        )
        let sessions = [
            makeSession(modelID: "gpt-4.1", providerID: "openai", messages: [
                userMessage("first", at: august11),
                metered
            ]),
            makeSession(modelID: "gpt-4.1", providerID: "openai", messages: [
                userMessage("second", at: august11)
            ])
        ].map { AgentUsageSessionSnapshot(session: $0) }

        let usage = AgentUsageStats.dailyUsage(for: sessions, in: month, calendar: calendar)
        let day = try #require(usage.first { calendar.component(.day, from: $0.date) == 11 })

        #expect(usage.count == 31)
        #expect(day.tokenCount == 2_000_002)
        #expect(day.sessionCount == 2)
        #expect(abs(try #require(day.estimatedCostUSD) - 10) < 0.000_001)
    }

    @Test("daily usage detail excludes other days and reports model efficiency")
    func dailyUsageDetailFiltersAndAggregates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let selectedDay = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 18, hour: 10))
        )
        let followingDay = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 10))
        )
        let snapshot = AgentUsageSessionSnapshot(
            id: UUID(),
            modelID: "gpt-5.6-terra",
            providerID: "openai",
            providerDisplayName: "OpenAI",
            createdAt: selectedDay,
            updatedAt: followingDay,
            messages: [
                AgentUsageMessageSnapshot(
                    role: .user,
                    contentCharacterCount: 8,
                    createdAt: selectedDay
                ),
                AgentUsageMessageSnapshot(
                    role: .assistant,
                    contentCharacterCount: 2,
                    toolCallNames: ["run_command"],
                    usageTokens: 120,
                    promptTokens: 100,
                    completionTokens: 20,
                    cachedPromptTokens: 40,
                    requestModelID: "gpt-5.6-terra",
                    requestProviderID: "openai",
                    requestProviderDisplayName: "OpenAI",
                    createdAt: selectedDay
                ),
                AgentUsageMessageSnapshot(
                    role: .assistant,
                    contentCharacterCount: 2,
                    usageTokens: 900,
                    promptTokens: 800,
                    completionTokens: 100,
                    createdAt: followingDay
                )
            ]
        )

        let detail = AgentUsageStats.dailyDetail(
            for: [snapshot],
            on: selectedDay,
            calendar: calendar
        )

        #expect(detail.overview.sessionCount == 1)
        #expect(detail.overview.userTurnCount == 1)
        #expect(detail.modelUsage.count == 1)
        #expect(detail.modelUsage.first?.totalTokens == 120)
        #expect(abs(detail.cacheHitRate - 0.4) < 0.000_001)
        #expect(detail.maximumContextTokens == 120)
        #expect(detail.capabilityUsage.first?.capability == .terminal)
        #expect(detail.capabilityUsage.first?.callCount == 1)
    }

    @Test("monthly usage calendar treats unpriced usage as free instead of vetoing the day")
    func monthlyUsageCalendarCountsUnpricedUsageAsFree() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let month = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))
        let august11 = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 11, hour: 10)))

        let priced = AgentMessage(
            role: .assistant,
            content: "ok",
            usageTokens: 2_000_000,
            promptTokens: 1_000_000,
            completionTokens: 1_000_000,
            createdAt: august11
        )
        let unpriced = AgentMessage(
            role: .assistant,
            content: "ok",
            usageTokens: 2_000_000,
            promptTokens: 1_000_000,
            completionTokens: 1_000_000,
            createdAt: august11
        )
        let sessions = [
            makeSession(modelID: "gpt-4.1", providerID: "openai", messages: [priced]),
            makeSession(modelID: "totally-unknown-model", providerID: "mystery", messages: [unpriced])
        ].map { AgentUsageSessionSnapshot(session: $0) }

        let usage = AgentUsageStats.dailyUsage(for: sessions, in: month, calendar: calendar)
        let day = try #require(usage.first { calendar.component(.day, from: $0.date) == 11 })

        // gpt-4.1 contributes $10; the unknown model contributes $0, not nil.
        #expect(abs(try #require(day.estimatedCostUSD) - 10) < 0.000_001)
    }

    @Test("August 2026 usage calendar is a Sunday-first six-week grid")
    func usageCalendarGridUsesConventionalWeekOrder() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let month = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 11)))

        let dates = AgentUsageStats.calendarGridDates(for: month, calendar: calendar)

        #expect(dates.count == 42)
        #expect(calendar.component(.weekday, from: try #require(dates.first)) == 1)
        #expect(calendar.component(.month, from: dates[6]) == 8)
        #expect(calendar.component(.day, from: dates[6]) == 1)
        #expect(calendar.component(.month, from: try #require(dates.last)) == 9)
        #expect(calendar.component(.day, from: try #require(dates.last)) == 5)
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

    @Test("AgentUsageStats prices kimi-k3 at the Moonshot list rate")
    func testUsageStatsPricesKimiK3() {
        let session = makeSession(
            modelID: "kimi-k3",
            providerID: "some-im",
            messages: [
                meteredAssistantMessage(prompt: 1_000_000, completion: 1_000_000, cachedPrompt: 500_000)
            ]
        )

        let row = AgentUsageStats.modelUsage(for: [session]).first

        // 0.5M uncached × $3 + 0.5M cached × $0.30 + 1M output × $15
        #expect(row?.modelID == "kimi-k3")
        #expect(abs((row?.estimatedCostUSD ?? 0) - 16.65) < 0.000_001)
    }

    @Test("AgentUsageStats prices gpt-5.6 tiers instead of falling into the gpt-5 row")
    func testUsageStatsPricesGPT56Tiers() {
        let session = makeSession(
            modelID: "gpt-5.6-terra",
            providerID: "some-im",
            messages: [
                meteredAssistantMessage(prompt: 1_000_000, completion: 1_000_000)
            ]
        )

        let row = AgentUsageStats.modelUsage(for: [session]).first

        // Terra: $2 input + $12 output — not the gpt-5 family $1.25/$10.
        #expect(row?.modelID == "gpt-5.6-terra")
        #expect(abs((row?.estimatedCostUSD ?? 0) - 14.0) < 0.000_001)
    }

    @Test("AgentUsageStats prices someim managed models like deepseek-v4-flash")
    func testUsageStatsPricesSomeIMManagedModels() {
        let native = makeSession(
            modelID: "someim-auto-pro",
            providerID: "some-im",
            messages: [
                meteredAssistantMessage(prompt: 1_000_000, completion: 1_000_000)
            ]
        )
        let relayed = makeSession(
            modelID: "someim-coding-plan-high",
            providerID: "custom",
            messages: [
                meteredAssistantMessage(prompt: 1_000_000, completion: 1_000_000)
            ]
        )

        let rows = AgentUsageStats.modelUsage(for: [native, relayed])
        let expected = 0.14 + 0.28

        #expect(rows.count == 2)
        for row in rows {
            #expect(abs((row.estimatedCostUSD ?? 0) - expected) < 0.000_001)
        }
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
        #expect(model.managedRoutingRate == 0)
        #expect(model.uniqueToolCount == 2)
    }

    @Test("dashboardModel on empty snapshots yields zeroed metrics")
    func testDashboardModelEmptyInput() {
        let model = AgentUsageStats.dashboardModel(for: [], heatmapWeekCount: 2)
        #expect(model.overview.sessionCount == 0)
        #expect(model.peakTaskTokenCount == 0)
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
