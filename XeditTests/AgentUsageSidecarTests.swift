//
//  AgentUsageSidecarTests.swift
//  XeditTests
//
//  统计面板 usage 扫描的 usage-v1 侧车缓存回归测试：保存会话时由内存
//  会话对象直接写出小索引文件；冷扫描先验源文件签名走快路径，签名或
//  schemaVersion 失效时回退整份会话 JSON 的全量解码并自愈回写；删除
//  会话时侧车一并清理。
//
//  与 AgentSessionStoreAsyncWriteTests 相同，使用测试进程自动重定向的
//  沙盒 session 目录，defer delete 收尾，不触碰真实用户数据。
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentUsageSidecarTests {

    /// 一个覆盖 usage 快照全部取数维度的会话：正文、思考痕迹、粘贴
    /// 附件、工具调用（含 spawn_agent）、token 计数、工具结果、编辑
    /// 与产物路径。侧车与全量解码若在任何维度上分叉，相等断言会挂。
    private func makeRichSession() -> AgentSession {
        var session = AgentSession(
            title: "usage-sidecar-probe",
            workspaceRootPath: "/tmp/usage-sidecar-workspace",
            modelID: "deepseek-v4",
            providerID: "deepseek",
            providerDisplayName: "DeepSeek"
        )
        session.agentEditedPaths = ["Sources/A.swift", "Sources/B.swift"]
        session.agentArtifactPaths = ["report.md"]
        session.messages = [
            AgentMessage(
                role: .user,
                content: "统计我的使用情况",
                textAttachments: [
                    AgentTextAttachment(content: String(repeating: "粘贴的长文本段落。", count: 64))
                ]
            ),
            AgentMessage(
                role: .assistant,
                content: "已完成统计",
                reasoningContent: "先扫 usage 快照，再聚合到面板。",
                toolCalls: [
                    AgentMessageToolCall(
                        externalID: "call_1",
                        toolName: "spawn_agent",
                        argumentsJSON: #"{"profile":"deep"}"#
                    ),
                    AgentMessageToolCall(
                        externalID: "call_2",
                        toolName: "run_command",
                        argumentsJSON: #"{"command":"ls -la"}"#
                    ),
                ],
                usageTokens: 320,
                promptTokens: 200,
                completionTokens: 120,
                cachedPromptTokens: 64,
                reasoningTokens: 30,
                requestModelID: "deepseek-v4",
                requestProviderID: "deepseek",
                requestStablePrefixCharacters: 512
            ),
            AgentMessage(
                role: .tool,
                content: "total 0",
                toolCallID: "call_2",
                toolCallStatus: .succeeded
            ),
        ]
        return session
    }

    private func sessionFileURL(for id: UUID) -> URL {
        AgentSessionStore.directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// The scan contract covers the entire library, so it must not share a
    /// mutable directory with other suites. Use full session JSON as input;
    /// production scans still build and validate their own sidecars/database.
    private func makeScanLibrary(_ sessions: [AgentSession]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            for session in sessions {
                try encoder.encode(session).write(
                    to: root.appendingPathComponent("\(session.id.uuidString).json"), options: .atomic
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        return root
    }

    /// 篡改侧车用的"诱饵"快照：id 相同，数据故意与真实会话完全不同。
    private func decoySnapshot(id: UUID) -> AgentUsageSessionSnapshot {
        AgentUsageSessionSnapshot(
            id: id,
            modelID: "decoy-model",
            providerID: "decoy",
            providerDisplayName: "Decoy",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            messages: [
                AgentUsageMessageSnapshot(
                    role: .assistant,
                    contentCharacterCount: 424_242,
                    usageTokens: 999_999,
                    createdAt: Date(timeIntervalSince1970: 1_500)
                ),
            ]
        )
    }

    @Test("保存会话即写出 usage 侧车，内容与整份 JSON 全量解码一致")
    func saveWritesSidecarMatchingFullDecode() throws {
        let session = makeRichSession()
        let id = session.id
        defer { AgentSessionStore.delete(id: id) }

        #expect(AgentSessionStore.save(session))

        let sidecarData = try Data(contentsOf: AgentSessionStore.usageCatalogURL(for: id))
        let sidecar = try AgentSessionStore.decodeUsageCatalogEntryForTesting(sidecarData)
        let fullData = try Data(contentsOf: sessionFileURL(for: id))
        let fullDecode = try AgentSessionStore.decodeUsageSnapshot(from: fullData)

        #expect(sidecar.schemaVersion == AgentSessionStore.usageCatalogSchemaVersionForTesting)
        #expect(sidecar.snapshot == fullDecode)
        // sanity：确认快照真的带上了各取数维度，不是空对空的相等。
        #expect(sidecar.snapshot.messages.count == 3)
        #expect(sidecar.snapshot.messages.contains { $0.toolCallNames.contains("spawn_agent") })
        #expect(sidecar.snapshot.messages.contains { !$0.subagentProfileIDs.isEmpty })
        #expect(sidecar.snapshot.messages.contains { $0.usageTokens == 320 })
        #expect(sidecar.snapshot.editedFileCount == 2)
        #expect(sidecar.snapshot.artifactPaths == ["report.md"])
    }

    @Test("异步保存管线同样维护 usage 侧车")
    func asyncSaveMaintainsSidecar() throws {
        let session = makeRichSession()
        let id = session.id
        defer { AgentSessionStore.delete(id: id) }

        AgentSessionStore.saveAsync(session)
        AgentSessionStore.flushPendingWrites()

        let sidecarData = try Data(contentsOf: AgentSessionStore.usageCatalogURL(for: id))
        let sidecar = try AgentSessionStore.decodeUsageCatalogEntryForTesting(sidecarData)
        let fullData = try Data(contentsOf: sessionFileURL(for: id))
        let fullDecode = try AgentSessionStore.decodeUsageSnapshot(from: fullData)
        #expect(sidecar.snapshot == fullDecode)
    }

    /// 并行扫描必须和串行扫描给出同一批数据。
    ///
    /// 并行版本是首次打开统计面板的正路——串行走 299 个侧车要一秒上下，
    /// 面板在那一秒里显示的是零。并行之后每个子任务用自己的编解码器，
    /// 这条用例同时兜住「结果集一致」和「并发解码没把数据搅坏」。
    @Test("并行扫描与串行扫描返回同一批快照")
    func concurrentScanMatchesTheSerialScan() async throws {
        let sessions = (0..<12).map { index in
            var session = makeRichSession()
            session.title = "usage-parallel-\(index)"
            return session
        }
        let ids = sessions.map(\.id)
        let root = try makeScanLibrary(sessions)
        defer { try? FileManager.default.removeItem(at: root) }

        let serial = AgentSessionStore.loadUsageSnapshots(in: root)
        let concurrent = await AgentSessionStore.scanUsageSidecarsConcurrently(in: root)

        // 按 id 排序再比：两边都按 updatedAt 倒序，而 Swift 的 sort 不
        // 稳定，同一毫秒创建的会话之间谁在前是没有保证的。这里要钉的是
        // 「同一批数据」，不是那个本来就不存在的顺序保证。
        #expect(concurrent.sorted { $0.id.uuidString < $1.id.uuidString }
            == serial.sorted { $0.id.uuidString < $1.id.uuidString })
        #expect(Set(concurrent.map(\.id)) == Set(ids))
        for id in ids {
            #expect(concurrent.contains { $0.id == id })
        }
    }

    /// 统计库与侧车必须给出逐字段相同的快照。
    ///
    /// 库是快路径，侧车是退路，两者随时可能互相替换。任何一个字段在库
    /// 里丢了或变了形，面板上的数字就会悄悄变小，而且没有任何报错——
    /// 这是这类缓存最难查的一种坏法。样本用的是同一份富会话，覆盖正文、
    /// 思考痕迹、工具调用、token 计数、编辑与产物路径。
    @Test("统计库往返与侧车逐字段等价")
    func databaseRoundTripMatchesTheSidecar() async throws {
        let sessions = (0..<5).map { index in
            var session = makeRichSession()
            session.title = "usage-db-\(index)"
            return session
        }
        let ids = sessions.map(\.id)
        let root = try makeScanLibrary(sessions)
        defer { try? FileManager.default.removeItem(at: root) }

        let fromSidecars = await AgentSessionStore.scanUsageSidecarsConcurrently(in: root)
        let fromDatabase = await AgentSessionStore.loadUsageSnapshotsConcurrently(in: root)
        let database = try #require(AgentUsageDatabase(url: AgentUsageDatabase.defaultURL(in: root)))
        #expect(database.loadAll().sorted { $0.id.uuidString < $1.id.uuidString }
            == fromDatabase.sorted { $0.id.uuidString < $1.id.uuidString })

        let sidecarByID = Dictionary(uniqueKeysWithValues: fromSidecars.map { ($0.id, $0) })
        let databaseByID = Dictionary(uniqueKeysWithValues: fromDatabase.map { ($0.id, $0) })
        #expect(Set(databaseByID.keys) == Set(sidecarByID.keys))
        #expect(Set(databaseByID.keys) == Set(ids))
        for id in ids {
            let sidecar = try #require(sidecarByID[id])
            let stored = try #require(databaseByID[id])
            #expect(stored == sidecar)
        }
    }

    @Test("复用统计写语句后可清空可选字段、替换工具列表并删除重建")
    func databaseReusedStatementsDoNotLeakPreviousBindings() throws {
        var session = makeRichSession()
        let root = try makeScanLibrary([])
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try #require(AgentUsageDatabase(url: AgentUsageDatabase.defaultURL(in: root)))
        let stamp = AgentUsageSourceStamp(fileSize: 123, modificationTime: 456)
        #expect(database.upsert(AgentUsageSessionSnapshot(session: session), signature: stamp))
        session.providerDisplayName = nil
        session.messages = [AgentMessage(role: .user, content: "replacement")]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let expected = try decoder.decode(
            AgentUsageSessionSnapshot.self,
            from: encoder.encode(AgentUsageSessionSnapshot(session: session))
        )
        #expect(database.upsert(expected, signature: stamp))
        #expect(database.loadAll() == [expected])
        #expect(database.delete(id: session.id))
        #expect(database.loadAll().isEmpty)
        #expect(database.replaceAll(with: [(expected, stamp)]))
        #expect(database.loadAll() == [expected])
    }

    @Test("不同目录的同 ID 会话并发扫描不串库，侧车留在各自目录")
    func concurrentLibrariesKeepIdenticalIDsIsolated() async throws {
        let first = makeRichSession()
        var second = first
        second.messages.append(AgentMessage(role: .user, content: "only in second library"))
        let firstRoot = try makeScanLibrary([first])
        defer { try? FileManager.default.removeItem(at: firstRoot) }
        let secondRoot = try makeScanLibrary([second])
        defer { try? FileManager.default.removeItem(at: secondRoot) }

        async let firstScan = AgentSessionStore.loadUsageSnapshotsConcurrently(in: firstRoot)
        async let secondScan = AgentSessionStore.loadUsageSnapshotsConcurrently(in: secondRoot)
        let (firstResult, secondResult) = await (firstScan, secondScan)
        #expect(firstResult.count == 1)
        #expect(secondResult.count == 1)
        #expect(firstResult.first?.messages.count == first.messages.count)
        #expect(secondResult.first?.messages.count == second.messages.count)
        #expect(firstResult != secondResult)
        for (root, expected) in [(firstRoot, firstResult), (secondRoot, secondResult)] {
            let sidecars = await AgentSessionStore.scanUsageSidecarsConcurrently(in: root)
            #expect(sidecars == expected)
            let sidecarURL = root.appendingPathComponent("usage-v1/\(first.id.uuidString).json")
            #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
            let database = try #require(AgentUsageDatabase(url: AgentUsageDatabase.defaultURL(in: root)))
            #expect(database.loadAll() == expected)
        }
    }

    /// 会话被外部改动后，库要跟着重建那一条，而不是端出旧数字。
    @Test("源文件指纹变了，统计库重建该会话")
    func databaseRebuildsWhenTheSourceChanges() async throws {
        var session = makeRichSession()
        let id = session.id
        defer { AgentSessionStore.delete(id: id) }
        #expect(AgentSessionStore.save(session))
        _ = await AgentSessionStore.loadUsageSnapshotsConcurrently()

        // 绕过 store 直接改写会话文件，模拟另一个进程写入。
        session.messages.append(AgentMessage(role: .user, content: "外部进程补写的一条消息"))
        session.updatedAt = session.updatedAt.addingTimeInterval(60)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: sessionFileURL(for: id), options: .atomic)

        let reloaded = await AgentSessionStore.loadUsageSnapshotsConcurrently()
        let stored = try #require(reloaded.first { $0.id == id })
        #expect(stored.messages.count == session.messages.count)
    }

    @Test("签名匹配时冷扫描走侧车快路径，不做全量解码")
    func validSidecarServesFastPathWithoutFullDecode() throws {
        let session = makeRichSession()
        let id = session.id
        defer { AgentSessionStore.delete(id: id) }
        #expect(AgentSessionStore.save(session))

        // 植入一个签名匹配、内容却故意不同的侧车。loadUsageSnapshots
        // 返回诱饵内容 ⇒ 它只读了侧车（快路径）；若它偷偷全量解码，
        // 返回的会是真实会话数据，下面的断言随即失败。
        try AgentSessionStore.writeUsageCatalogEntryForTesting(
            snapshot: decoySnapshot(id: id),
            sourceURL: sessionFileURL(for: id)
        )

        let loaded = AgentSessionStore.loadUsageSnapshots().first { $0.id == id }
        #expect(loaded?.modelID == "decoy-model")
        #expect(loaded?.messages.first?.contentCharacterCount == 424_242)
    }

    @Test("会话文件被外部改动后，失效侧车触发重建并回写正确内容")
    func staleSignatureRebuildsAndRepairsSidecar() throws {
        var session = makeRichSession()
        let id = session.id
        defer { AgentSessionStore.delete(id: id) }
        #expect(AgentSessionStore.save(session))

        // 先植入对着旧文件签名的诱饵侧车，再绕过 store 直接改写会话
        // 文件模拟外部进程写入——侧车签名随即失效。
        try AgentSessionStore.writeUsageCatalogEntryForTesting(
            snapshot: decoySnapshot(id: id),
            sourceURL: sessionFileURL(for: id)
        )
        session.messages.append(
            AgentMessage(role: .user, content: "外部进程补写的一条消息")
        )
        session.updatedAt = session.updatedAt.addingTimeInterval(60)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: sessionFileURL(for: id), options: .atomic)

        let loaded = AgentSessionStore.loadUsageSnapshots().first { $0.id == id }
        let fullData = try Data(contentsOf: sessionFileURL(for: id))
        let expected = try AgentSessionStore.decodeUsageSnapshot(from: fullData)
        #expect(loaded == expected)
        #expect(loaded?.messages.count == 4)
        #expect(loaded?.modelID != "decoy-model")

        // 侧车已被自愈回写；下一次扫描走快路径也拿到同样的结果。
        let repairedData = try Data(contentsOf: AgentSessionStore.usageCatalogURL(for: id))
        let repaired = try AgentSessionStore.decodeUsageCatalogEntryForTesting(repairedData)
        #expect(repaired.snapshot == expected)
    }

    @Test("schemaVersion 不匹配的侧车视为失效，触发重建")
    func schemaVersionMismatchRebuilds() throws {
        let session = makeRichSession()
        let id = session.id
        defer { AgentSessionStore.delete(id: id) }
        #expect(AgentSessionStore.save(session))

        // 诱饵侧车签名与当前文件完全匹配，但 schemaVersion 是未来版本。
        try AgentSessionStore.writeUsageCatalogEntryForTesting(
            snapshot: decoySnapshot(id: id),
            sourceURL: sessionFileURL(for: id),
            schemaVersion: AgentSessionStore.usageCatalogSchemaVersionForTesting + 1
        )

        let loaded = AgentSessionStore.loadUsageSnapshots().first { $0.id == id }
        let fullData = try Data(contentsOf: sessionFileURL(for: id))
        let expected = try AgentSessionStore.decodeUsageSnapshot(from: fullData)
        #expect(loaded == expected)
        #expect(loaded?.modelID != "decoy-model")

        let repairedData = try Data(contentsOf: AgentSessionStore.usageCatalogURL(for: id))
        let repaired = try AgentSessionStore.decodeUsageCatalogEntryForTesting(repairedData)
        #expect(repaired.schemaVersion == AgentSessionStore.usageCatalogSchemaVersionForTesting)
        #expect(repaired.snapshot == expected)
    }

    @Test("删除会话时 usage 侧车一并删除")
    func deleteRemovesUsageSidecar() throws {
        let session = makeRichSession()
        let id = session.id
        #expect(AgentSessionStore.save(session))
        let sidecarURL = AgentSessionStore.usageCatalogURL(for: id)
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))

        #expect(AgentSessionStore.delete(id: id))
        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path))
    }
}
