//
//  AgentChildSessionPersistenceTests.swift
//  XeditTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite("子会话关系持久化", .serialized)
@MainActor
struct AgentChildSessionPersistenceTests {
    @Test("旧会话与旧目录记录缺少子会话字段时仍可读取")
    func legacySessionAndCatalogFallback() throws {
        let id = UUID()
        let legacy = """
        {
          "id": "\(id.uuidString)",
          "title": "Old chat",
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z",
          "messages": []
        }
        """
        let session = try JSONDecoder.iso8601SessionDecoder.decode(AgentSession.self, from: Data(legacy.utf8))
        #expect(session.parentSessionID == nil)
        #expect(session.childSessionAssignment == nil)

        let url = AgentSessionStore.fileURL(for: id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: url)
        defer { AgentSessionStore.delete(id: id) }

        let fromCatalog = try #require(AgentSessionStore.loadAll().first { $0.id == id })
        #expect(fromCatalog.parentSessionID == nil)
        #expect(fromCatalog.childSessionAssignment == nil)
    }

    @Test("子会话主文件与目录侧车保留关联和委派状态")
    func childSessionAndCatalogRoundTrip() throws {
        let parentID = UUID()
        let prompt = String(repeating: "委派🌍", count: 250)
        let excerpt = String(repeating: "结果✨", count: 250)
        let assignment = AgentChildSessionAssignment(
            id: UUID(),
            prompt: prompt,
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 760_000_000),
            completedAt: Date(timeIntervalSince1970: 760_000_100),
            resultNotificationID: UUID(),
            resultExcerpt: excerpt
        )
        let child = AgentSession(
            title: "Delegated task",
            parentSessionID: parentID,
            childSessionAssignment: assignment,
            messages: [AgentMessage(role: .assistant, content: "child transcript must remain separate")]
        )
        defer { AgentSessionStore.delete(id: child.id) }
        #expect(AgentSessionStore.save(child))

        let full = try #require(AgentSessionStore.load(id: child.id))
        #expect(full.parentSessionID == parentID)
        #expect(full.childSessionAssignment == assignment)
        #expect(full.messages.first?.content == "child transcript must remain separate")

        let cached = try #require(AgentSessionStore.loadAll().first { $0.id == child.id })
        #expect(cached.parentSessionID == parentID)
        #expect(cached.childSessionAssignment?.id == assignment.id)
        #expect(cached.childSessionAssignment?.status == .completed)
        #expect(cached.childSessionAssignment?.createdAt == assignment.createdAt)
        #expect(cached.childSessionAssignment?.completedAt == assignment.completedAt)
        #expect(cached.childSessionAssignment?.resultNotificationID == assignment.resultNotificationID)
        #expect(cached.childSessionAssignment?.prompt == String(prompt.prefix(AgentChildSessionAssignment.catalogTextLimit)))
        #expect(cached.childSessionAssignment?.resultExcerpt == String(excerpt.prefix(AgentChildSessionAssignment.catalogTextLimit)))
        #expect(cached.messages.isEmpty)

        let data = try Data(contentsOf: AgentSessionStore.catalogURL(for: child.id))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let record = try #require(json["session"] as? [String: Any])
        #expect((record["messages"] as? [Any])?.isEmpty == true)
        let catalogAssignment = try #require(record["childSessionAssignment"] as? [String: Any])
        #expect(catalogAssignment["prompt"] as? String == String(
            prompt.prefix(AgentChildSessionAssignment.catalogTextLimit)
        ))

        // A missing catalog must rebuild through the lightweight SessionIndex
        // decoder rather than silently dropping the new relationship.
        try FileManager.default.removeItem(at: AgentSessionStore.catalogURL(for: child.id))
        let rebuilt = try #require(AgentSessionStore.loadAll().first { $0.id == child.id })
        #expect(rebuilt.parentSessionID == parentID)
        #expect(rebuilt.childSessionAssignment == cached.childSessionAssignment)
        #expect(rebuilt.messages.isEmpty)
    }

    @Test("任务文本与结果中的凭据不会写入目录侧车")
    func childCatalogRedactsCredentialLikeText() throws {
        let syntheticCredential = "sk-" + String(repeating: "a", count: 20)
        let assignment = AgentChildSessionAssignment(
            prompt: "Inspect \(syntheticCredential)",
            status: .completed,
            resultExcerpt: "Found \(syntheticCredential)"
        )
        let child = AgentSession(
            title: "Inspect \(syntheticCredential)",
            parentSessionID: UUID(),
            childSessionAssignment: assignment
        )
        defer { AgentSessionStore.delete(id: child.id) }
        #expect(AgentSessionStore.save(child))

        let sessionJSON = try String(contentsOf: AgentSessionStore.fileURL(for: child.id), encoding: .utf8)
        let catalogJSON = try String(contentsOf: AgentSessionStore.catalogURL(for: child.id), encoding: .utf8)
        #expect(!sessionJSON.contains(syntheticCredential))
        #expect(!catalogJSON.contains(syntheticCredential))
        #expect(catalogJSON.contains("[REDACTED:API-KEY]"))
    }

    @Test("子会话工具错误中的凭据不会进入用量侧车或数据库")
    func childUsageCacheRedactsCredentialLikeText() throws {
        let syntheticCredential = "sk-" + String(repeating: "b", count: 20)
        let child = AgentSession(
            parentSessionID: UUID(),
            childSessionAssignment: AgentChildSessionAssignment(prompt: "Inspect"),
            messages: [AgentMessage(
                role: .tool, content: "Failed", toolErrorMessage: "Denied \(syntheticCredential)"
            )]
        )
        defer { AgentSessionStore.delete(id: child.id) }
        #expect(AgentSessionStore.save(child))

        let sidecar = try String(
            contentsOf: AgentSessionStore.usageCatalogURL(for: child.id), encoding: .utf8
        )
        #expect(!sidecar.contains(syntheticCredential))
        #expect(sidecar.contains("[REDACTED:API-KEY]"))
        let snapshot = try #require(AgentSessionStore.loadUsageSnapshots().first { $0.id == child.id })
        #expect(snapshot.messages.first?.toolErrorMessage?.contains(syntheticCredential) == false)
        #expect(snapshot.messages.first?.toolErrorMessage?.contains("[REDACTED:API-KEY]") == true)
    }

    @Test("尚未收到消息的子会话不会被空会话清理删除")
    func pendingChildSessionSurvivesEmptySessionSweep() throws {
        let child = AgentSession(
            parentSessionID: UUID(),
            childSessionAssignment: AgentChildSessionAssignment(prompt: "Run delegated work")
        )
        defer { AgentSessionStore.delete(id: child.id) }
        #expect(AgentSessionStore.save(child))
        #expect(!AgentSessionStore.isAbandonedPlaceholder(child))
        #expect(!AgentSessionStore.deleteIfStillEmptyAndUnattached(id: child.id))
        #expect(AgentSessionStore.load(id: child.id) != nil)
    }

    @Test("空消息子会话不会被侧车预览覆盖完整任务")
    func catalogSnapshotCannotTruncateEmptyChildSession() throws {
        let prompt = String(repeating: "委派", count: 300)
        let child = AgentSession(
            parentSessionID: UUID(),
            childSessionAssignment: AgentChildSessionAssignment(prompt: prompt)
        )
        defer { AgentSessionStore.delete(id: child.id) }
        #expect(AgentSessionStore.save(child))

        let preview = try #require(AgentSessionStore.loadAll().first { $0.id == child.id })
        #expect(preview.messages.isEmpty)
        #expect(preview.childSessionAssignment?.prompt.count == AgentChildSessionAssignment.catalogTextLimit)
        #expect(!AgentSessionStore.save(preview))
        #expect(AgentSessionStore.load(id: child.id)?.childSessionAssignment?.prompt == prompt)
    }
}

private extension JSONDecoder {
    static var iso8601SessionDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
