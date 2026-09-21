//
//  AgentCLIUsageLedgerTests.swift
//  WillDeepTests
//
//  willdeep-rs usage ledger reader and its merge into the stats dashboard
//  (docs/USAGE_LEDGER_DESIGN.md).
//

import Foundation
import Testing
@testable import WillDeep

@Suite("CLI 用量账本读取与合并", .serialized)
struct AgentCLIUsageLedgerTests {
    // MARK: - Fixtures

    private struct LedgerDirectory {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cli-usage-ledger-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func append(_ text: String, to name: String = "2026-09.jsonl") throws {
            let file = url.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }

        func remove() {
            do { try FileManager.default.removeItem(at: url) } catch { Issue.record("cleanup: \(error)") }
        }
    }

    private static func line(
        id: UUID = UUID(),
        ts: String = "2026-09-21T08:52:31.402Z",
        session: String = "2500b85b-9324-472a-8aeb-5e154cf41100",
        model: String? = "deepseek-v4-pro",
        provider: String? = "someim",
        local: Bool = false,
        input: Int? = 21_342,
        cached: Int? = 20_864,
        output: Int? = 1_036,
        total: Int? = 22_378,
        schema: String = AgentCLIUsageRecord.schema
    ) -> String {
        var object: [String: Any] = [
            "schema": schema, "id": id.uuidString.lowercased(), "ts": ts,
            "client": "tui", "execution": "daemon", "kind": "main",
            "session_id": session, "local": local, "outcome": "ok", "backfilled": false,
            "latency_ms": 5_820,
        ]
        object["model"] = model ?? NSNull()
        object["provider"] = provider ?? NSNull()
        object["input_tokens"] = input ?? NSNull()
        object["cache_read_tokens"] = cached ?? NSNull()
        object["output_tokens"] = output ?? NSNull()
        object["total_tokens"] = total ?? NSNull()
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func record(
        at date: Date,
        session: String = "cli-session",
        model: String = "deepseek-v4-pro",
        local: Bool = false,
        input: Int = 1_000,
        cached: Int = 800,
        output: Int = 100
    ) -> AgentCLIUsageRecord {
        AgentCLIUsageRecord(
            id: UUID(), timestamp: date, client: "tui", kind: "main", sessionID: session,
            providerID: local ? "ollama" : "someim", modelID: model, isLocal: local,
            inputTokens: input, cachedInputTokens: cached, outputTokens: output,
            totalTokens: input + output, latencySeconds: 2, succeeded: true
        )
    }

    private static func session(_ messages: [AgentMessage], model: String = "gpt-4.1") -> AgentUsageSessionSnapshot {
        AgentUsageSessionSnapshot(session: AgentSession(
            id: UUID(), title: "t", workspaceRootPath: nil, modelID: model,
            createdAt: Date(), updatedAt: Date(), messages: messages
        ))
    }

    private static func cell(on date: Date, in columns: [[AgentHeatmapCell]]) -> AgentHeatmapCell? {
        let day = Calendar.current.startOfDay(for: date)
        return columns.flatMap { $0 }.first { $0.date == day }
    }

    // MARK: - Reader

    @Test("解析 v1 行：字段、毫秒时间、缓存命中；不认识的 schema 与坏行跳过")
    func decodesRecordsAndSkipsGarbage() throws {
        let dir = try LedgerDirectory(); defer { dir.remove() }
        try dir.append(Self.line())
        try dir.append(Self.line(schema: "willdeep.usage-ledger.v9"))
        try dir.append("{not json\n")
        try dir.append(Self.line(model: nil, input: nil, cached: nil, output: nil, total: nil))

        var reader = AgentCLIUsageLedgerReader(directory: dir.url)
        let records = reader.readNewRecords()

        #expect(records.count == 2)
        #expect(reader.skippedLineCount == 2)
        let first = try #require(records.first)
        #expect(first.modelID == "deepseek-v4-pro")
        #expect(first.cachedInputTokens == 20_864)
        #expect(first.countedTokens == 22_378)
        #expect(first.latencySeconds == 5.82)
        #expect(abs(first.timestamp.timeIntervalSince1970 - 1_789_980_751.402) < 0.001)
        // 没报 usage 的调用仍算一次请求，Token 记 0，不估算。
        #expect(records.last?.countedTokens == 0)
        #expect(records.last?.modelID == nil)
    }

    @Test("增量读取：只读新增；写到一半的行留到下次；同 id 不重复计")
    func readsIncrementallyAndWaitsForCompleteLines() throws {
        let dir = try LedgerDirectory(); defer { dir.remove() }
        var reader = AgentCLIUsageLedgerReader(directory: dir.url)
        let duplicateID = UUID()
        try dir.append(Self.line(id: duplicateID) + Self.line())
        #expect(reader.readNewRecords().count == 2)
        #expect(reader.readNewRecords().isEmpty)

        let partial = Self.line()
        try dir.append(Self.line(id: duplicateID) + String(partial.dropLast(10)))
        #expect(reader.readNewRecords().isEmpty)
        try dir.append(String(partial.suffix(10)))
        #expect(reader.readNewRecords().count == 1)

        // 新的月份文件也会被读到。
        try dir.append(Self.line(ts: "2026-10-01T00:00:01Z"), to: "2026-10.jsonl")
        #expect(reader.readNewRecords().count == 1)
    }

    @Test("文件被替换（inode 变了）从头重读，靠 id 去重")
    func rereadsReplacedFileWithoutDoubleCounting() throws {
        let dir = try LedgerDirectory(); defer { dir.remove() }
        var reader = AgentCLIUsageLedgerReader(directory: dir.url)
        let kept = Self.line()
        try dir.append(kept)
        #expect(reader.readNewRecords().count == 1)

        let file = dir.url.appendingPathComponent("2026-09.jsonl")
        try FileManager.default.removeItem(at: file)
        try dir.append(kept + Self.line())
        #expect(reader.readNewRecords().count == 1)
    }

    @Test("目录不存在时静默返回空")
    func missingDirectoryIsEmpty() {
        var reader = AgentCLIUsageLedgerReader(
            directory: URL(fileURLWithPath: "/nonexistent-\(UUID())/usage")
        )
        #expect(reader.readNewRecords().isEmpty)
    }

    @Test("账本目录跟随 WILLDEEP_HOME，默认 ~/.willdeep/usage")
    func directoryFollowsWillDeepHome() {
        let home = URL(fileURLWithPath: "/Users/tester")
        #expect(AgentCLIUsageLedgerReader.defaultDirectory(environment: [:], homeDirectory: home).path
            == "/Users/tester/.willdeep/usage")
        #expect(AgentCLIUsageLedgerReader.defaultDirectory(
            environment: ["WILLDEEP_HOME": "/tmp/wd-home"], homeDirectory: home
        ).path == "/tmp/wd-home/usage")
    }

    // MARK: - Merge

    @Test("热力图按模型调用计请求，桌面与 CLI 分开，并算缓存命中")
    func heatmapCountsModelCallsPerSource() throws {
        let now = Date()
        let desktop = Self.session([
            AgentMessage(role: .user, content: "hi", createdAt: now),
            AgentMessage(role: .assistant, content: "ok", usageTokens: 300, promptTokens: 200,
                         completionTokens: 100, cachedPromptTokens: 100, createdAt: now),
        ])
        let cli = [Self.record(at: now), Self.record(at: now)]
        let cell = try #require(Self.cell(on: now, in: AgentUsageStats.heatmap(
            for: [desktop], cliRecords: cli, weekCount: 1, now: now
        )))

        #expect(cell.desktopRequestCount == 1)
        #expect(cell.cliRequestCount == 2)
        #expect(cell.requestCount == 3)
        #expect(cell.turnCount == 1)
        #expect(cell.cliTokenCount == 2_200)
        #expect(cell.tokenCount == cell.desktopTokenCount + 2_200)
        // (100 + 800 + 800) / (200 + 1000 + 1000)
        #expect(abs((cell.cacheHitRate ?? 0) - 1_700.0 / 2_200.0) < 0.0001)
    }

    /// 2026-09-21 的现场：定时巡检 20 日 22:18 发起、跑到 21 日 01:12，21 日
    /// 那格显示「请求 0 次」却有 32.5 万 Token。
    @Test("跨零点的回合次日也有请求，不再是「请求 0、Token > 0」")
    func turnPastMidnightStillCountsRequestsNextDay() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let lateYesterday = today.addingTimeInterval(-3_600)
        let afterMidnight = today.addingTimeInterval(1_800)
        let routine = Self.session([
            AgentMessage(role: .user, content: "巡检", createdAt: lateYesterday),
            AgentMessage(role: .assistant, content: "ok", usageTokens: 5_000,
                         requestModelID: "deepseek-v4-flash", createdAt: afterMidnight),
        ])
        let cell = try #require(Self.cell(on: afterMidnight, in: AgentUsageStats.heatmap(
            for: [routine], weekCount: 2, now: afterMidnight
        )))
        #expect(cell.tokenCount > 0)
        #expect(cell.requestCount == 1)
        #expect(cell.turnCount == 0)
    }

    @Test("worker 与辅助请求计入请求数和 Token")
    func workerAndAuxiliaryCallsCount() throws {
        let now = Date()
        var session = Self.session([AgentMessage(role: .user, content: "hi", createdAt: now)])
        session.auxiliaryModelRequests = [AgentAuxiliaryModelRequestRecord(
            purpose: .title, providerID: "someim", modelID: "m", isLocal: false,
            createdAt: now, promptTokens: 40, completionTokens: 10, elapsedSeconds: 1, succeeded: true
        )]
        let cell = try #require(Self.cell(on: now, in: AgentUsageStats.heatmap(
            for: [session], weekCount: 1, now: now
        )))
        #expect(cell.desktopRequestCount == 1)
        #expect(cell.desktopTokenCount >= 50)
    }

    @Test("总览合并 CLI：Token、会话数、活跃天数；最爱模型按逐次调用")
    func overviewMergesCLI() {
        let now = Date()
        let desktop = Self.session([
            AgentMessage(role: .user, content: "hi", createdAt: now),
            AgentMessage(role: .assistant, content: "ok", usageTokens: 100,
                         requestModelID: "gpt-4.1", createdAt: now),
        ])
        let cli = (0..<3).map { _ in Self.record(at: now, session: "s1", model: "deepseek-v4-pro") }
        let base = AgentUsageStats.overview(for: [desktop], now: now)
        let merged = AgentUsageStats.overview(for: [desktop], cliRecords: cli, now: now)

        #expect(merged.totalTokens == base.totalTokens + 3_300)
        #expect(merged.sessionCount == base.sessionCount + 1)
        #expect(merged.activeDays == 1)
        #expect(merged.favoriteModel == "deepseek-v4-pro")
        #expect(merged.hasAnyRealUsage)
    }

    @Test("模型拆分：同一模型两端合并成一行并标来源")
    func modelUsageMergesSources() throws {
        let now = Date()
        let desktop = Self.session([
            AgentMessage(role: .assistant, content: "ok", usageTokens: 300, promptTokens: 200,
                         completionTokens: 100, requestModelID: "deepseek-v4-pro",
                         requestProviderID: "someim", createdAt: now),
        ], model: "deepseek-v4-pro")
        let rows = AgentUsageStats.modelUsage(
            for: [desktop],
            cliRecords: [Self.record(at: now), Self.record(at: now, model: "glm-5")]
        )
        let cliOnly = try #require(rows.first { $0.modelID == "glm-5" })
        #expect(cliOnly.sources == [.cli])
        #expect(cliOnly.messageCount == 1)
        #expect(cliOnly.totalTokens == 1_100)
        #expect(rows.allSatisfy { $0.sources.isEmpty == false })
    }

    @Test("CLI 调用进请求页：本地调用计入「本地模型请求」，近 7 天合计两者都算")
    func cliCallsFeedRequestPages() {
        let now = Date()
        let snapshot = AgentRequestAnalytics.snapshot(
            for: [],
            cliRecords: [Self.record(at: now), Self.record(at: now, local: true)],
            now: now
        )
        #expect(snapshot.recentAPI.requestCount == 2)
        #expect(snapshot.recentAPI.sessionCount == 1)
        #expect(snapshot.localAllTime.requestCount == 1)
    }

    /// 1.395.0-rc1 上线后发现：热力图合并了 CLI，点进用量日历，21 日还是
    /// 桌面的 324.8k——日历与单日详情直接读桌面快照。
    @Test("用量日历按月汇总合并 CLI：Token、会话数、费用")
    func dailyUsageMergesCLI() throws {
        let now = Date()
        let cli = [
            Self.record(at: now, session: "a"),
            Self.record(at: now, session: "a"),
            Self.record(at: now, session: "b"),
        ]
        let desktopOnly = AgentUsageStats.dailyUsage(for: [], in: now)
        let merged = AgentUsageStats.dailyUsage(for: [], cliRecords: cli, in: now)
        let day = Calendar.current.startOfDay(for: now)
        let before = try #require(desktopOnly.first { $0.date == day })
        let after = try #require(merged.first { $0.date == day })
        #expect(before.tokenCount == 0)
        #expect(after.tokenCount == 3_300)
        #expect(after.sessionCount == 2)
    }

    @Test("单日详情合并 CLI：总览、模型行、最大上下文")
    func dailyDetailMergesCLI() throws {
        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)
        let detail = AgentUsageStats.dailyDetail(
            for: [],
            cliRecords: [
                Self.record(at: now, input: 50_000, cached: 40_000, output: 2_000),
                Self.record(at: yesterday),
            ],
            on: now
        )
        #expect(detail.overview.totalTokens == 52_000)
        #expect(detail.modelUsage.count == 1)
        #expect(detail.modelUsage.first?.sources == [.cli])
        #expect(detail.maximumContextTokens == 52_000)
        #expect(abs(detail.cacheHitRate - 0.8) < 0.0001)
    }

    @Test("没有 CLI 记录时模型拆分与原实现逐项相同")
    func desktopOnlyModelUsageIsUnchanged() {
        let now = Date()
        let desktop = Self.session([
            AgentMessage(role: .assistant, content: "ok", usageTokens: 300, promptTokens: 200,
                         completionTokens: 100, createdAt: now),
        ])
        #expect(AgentUsageStats.modelUsage(for: [desktop], cliRecords: [])
            == AgentUsageStats.modelUsage(for: [desktop]))
    }
}
