//
//  AgentMemoryProjectScopeTests.swift
//  WillDeepTests
//
//  Covers workspace-scoped memories: the readable projectPath binding, the
//  fingerprint self-heal + path fallback matching, per-workspace retrieval
//  isolation, and the add_memory default-scope inference.
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
struct AgentMemoryProjectScopeTests {
    private let rootA = URL(fileURLWithPath: "/tmp/WillDeepProjectA")
    private let rootB = URL(fileURLWithPath: "/tmp/WillDeepProjectB")

    private func projectRecord(
        content: String,
        root: URL,
        fingerprint: String? = nil,
        path: String? = nil
    ) -> AgentMemoryRecord {
        AgentMemoryRecord(
            content: content,
            source: .manual,
            scope: .project,
            projectFingerprint: fingerprint ?? AgentMemoryEngine.projectFingerprint(for: root),
            projectPath: path ?? root.standardizedFileURL.path
        )
    }

    @Test
    func normalizedRecomputesMissingFingerprintFromPath() {
        let record = AgentMemoryRecord(
            content: "This repo uses yarn for package scripts.",
            source: .manual,
            scope: .project,
            projectFingerprint: nil,
            projectPath: rootA.standardizedFileURL.path
        ).normalized
        #expect(record.projectFingerprint == AgentMemoryEngine.projectFingerprint(for: rootA))
    }

    @Test
    func normalizedClearsProjectPathForGlobalScope() {
        let record = AgentMemoryRecord(
            content: "Reply in Simplified Chinese.",
            source: .manual,
            scope: .global,
            projectPath: rootA.standardizedFileURL.path
        ).normalized
        #expect(record.projectPath == nil)
    }

    @Test
    func projectDisplayNameUsesLastPathComponent() {
        let record = projectRecord(content: "Repo rule here.", root: rootA)
        #expect(record.projectDisplayName == "WillDeepProjectA")
    }

    @Test
    func retrievalIsolatesProjectMemoriesByWorkspace() {
        let records = [
            projectRecord(content: "ProjectA convention: run scripts with yarn build.", root: rootA)
        ]
        let inA = AgentMemoryEngine.retrieve(
            query: "how do I run yarn build here",
            records: records,
            settings: .default,
            rootDirectory: rootA,
            openedFileURL: nil
        )
        #expect(inA.count == 1)

        let inB = AgentMemoryEngine.retrieve(
            query: "how do I run yarn build here",
            records: records,
            settings: .default,
            rootDirectory: rootB,
            openedFileURL: nil
        )
        #expect(inB.isEmpty)

        let noWorkspace = AgentMemoryEngine.retrieve(
            query: "how do I run yarn build here",
            records: records,
            settings: .default,
            rootDirectory: nil,
            openedFileURL: nil
        )
        #expect(noWorkspace.isEmpty)
    }

    @Test
    func staleFingerprintStillMatchesViaPathFallback() {
        // A record whose fingerprint was produced by an older scheme keeps
        // matching as long as its readable path equals the workspace root.
        let record = projectRecord(
            content: "ProjectA convention: bump the changelog before pushing.",
            root: rootA,
            fingerprint: "stale-fingerprint-scheme"
        )
        #expect(AgentMemoryEngine.applies(
            record,
            projectID: AgentMemoryEngine.projectFingerprint(for: rootA),
            rootPath: rootA.standardizedFileURL.path
        ))
        #expect(!AgentMemoryEngine.applies(
            record,
            projectID: AgentMemoryEngine.projectFingerprint(for: rootB),
            rootPath: rootB.standardizedFileURL.path
        ))
    }

    @Test
    func candidatesCarryReadableProjectPath() throws {
        let records = AgentMemoryEngine.candidates(
            fromUser: "记住：这个项目每次改版本号必须同步 CHANGELOG。",
            assistantText: "",
            rootDirectory: rootA
        )
        let projectCandidate = try #require(records.first { $0.scope == .project })
        #expect(projectCandidate.projectPath == rootA.standardizedFileURL.path)
    }

    @Test @MainActor
    func addMemoryStoresProjectPathAndBackfillHealsLegacyRecords() throws {
        let state = AgentMemoryState(settings: .default, memories: [])
        state.addMemory(
            content: "This project must use yarn for all package scripts.",
            lifetime: .longTerm,
            scope: .project,
            rootDirectory: rootA
        )
        #expect(state.memories.first?.projectPath == rootA.standardizedFileURL.path)

        // Legacy record: fingerprint only, no readable path.
        var legacy = projectRecord(content: "Legacy record without path.", root: rootA)
        legacy.projectPath = nil
        state.memories.append(legacy)
        state.backfillProjectPaths(rootDirectory: rootA)
        let healed = try #require(state.memories.first { $0.content.contains("Legacy record") })
        #expect(healed.projectPath == rootA.standardizedFileURL.path)
    }

    @Test
    func resolveScopeExplicitArgumentWins() {
        #expect(AgentSelfLearning.resolveScope(
            "global",
            content: "这个项目的测试必须用 yarn。",
            rootDirectory: rootA
        ) == .global)
        #expect(AgentSelfLearning.resolveScope(
            "project",
            content: "Reply politely.",
            rootDirectory: rootA
        ) == .project)
    }

    @Test
    func resolveScopeInfersProjectFromContentWhenOmitted() {
        #expect(AgentSelfLearning.resolveScope(
            nil,
            content: "这个项目每次 bump 版本号要同步 CHANGELOG。",
            rootDirectory: rootA
        ) == .project)
        #expect(AgentSelfLearning.resolveScope(
            nil,
            content: "用户喜欢简洁的回复风格。",
            rootDirectory: rootA
        ) == .global)
        // Without a workspace there is nothing to bind to — always global.
        #expect(AgentSelfLearning.resolveScope(
            nil,
            content: "这个项目每次 bump 版本号要同步 CHANGELOG。",
            rootDirectory: nil
        ) == .global)
    }
}
