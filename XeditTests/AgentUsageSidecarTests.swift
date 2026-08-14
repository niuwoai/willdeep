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
