import Foundation
import Testing
@testable import WillDeep

@Suite
nonisolated struct AgentAutomaticCodingPolicyTests {
    private func plan(
        writeFiles: [String] = ["Sources/Feature.swift"],
        verifier: String = "swift test",
        suggestedRisk: AgentCodingRiskLevel = .green,
        riskFlags: [String] = [],
        unresolved: [String] = []
    ) -> AgentCodingTaskPlan {
        AgentCodingTaskPlan(
            goal: "Implement the bounded feature",
            readFiles: ["Sources/Support.swift"],
            writeFiles: writeFiles,
            symbols: ["Feature.run()"],
            knownFacts: ["The existing API is synchronous"],
            constraints: ["Preserve the public signature"],
            verifierCommand: verifier,
            suggestedRiskLevel: suggestedRisk,
            riskFlags: riskFlags,
            unresolved: unresolved
        )
    }

    @Test("one to three ordinary source files can enter the automatic lane")
    func boundedSourceChangesAreEligible() {
        #expect(plan().automaticIneligibilityReason(requestText: "实现这个功能") == nil)
        #expect(plan(writeFiles: ["a.swift", "b.swift", "c.swift"])
            .automaticIneligibilityReason(requestText: "实现这个功能") == nil)
    }

    @Test("host policy rejects ambiguity, missing verification and wide scope")
    func deterministicEligibilityGates() {
        #expect(plan(verifier: "").automaticIneligibilityReason(requestText: "实现") != nil)
        #expect(plan(unresolved: ["Product must choose the behavior"])
            .automaticIneligibilityReason(requestText: "实现") != nil)
        #expect(plan(writeFiles: ["a.swift", "b.swift", "c.swift", "d.swift"])
            .automaticIneligibilityReason(requestText: "实现") != nil)
    }

    @Test("host risk markers override an optimistic scout label")
    func hostRiskOverridesScout() {
        let candidate = plan(suggestedRisk: .green)

        #expect(AgentCodingRiskPolicy.assess(
            requestText: "修改生产环境的权限认证",
            plan: candidate
        ) == .red)
        #expect(candidate.automaticIneligibilityReason(requestText: "修改生产环境的权限认证") != nil)
    }

    @Test("project and secret-bearing files never enter straight-through coding")
    func sensitivePathsAreRejected() {
        for path in ["Xedit.xcodeproj/project.pbxproj", ".env", "yarn.lock"] {
            #expect(plan(writeFiles: [path])
                .automaticIneligibilityReason(requestText: "修改配置") != nil)
        }
    }

    @Test("independent review must be unanimously clean")
    func reviewAcceptanceIsStrict() {
        let accepted = AgentCodingReview(
            verdict: .accept,
            scopeCompliant: true,
            goalSatisfied: true,
            requiresHighModel: false,
            issues: [],
            userSummary: "完成"
        )
        #expect(accepted.acceptsStraightThroughDelivery)

        var rejected = accepted
        rejected.issues = ["Unrelated edit"]
        #expect(!rejected.acceptsStraightThroughDelivery)
    }

    @Test("task packet preserves the scout's read/write split and two-attempt budget")
    func taskPacketIsBounded() {
        let packet = plan(writeFiles: ["a.swift", "b.swift"]).taskPacket()

        #expect(packet.readFiles == ["Sources/Support.swift"])
        #expect(packet.writeFiles == ["a.swift", "b.swift"])
        #expect(packet.maxAttempts == 2)
        #expect(packet.verifierCommand == "swift test")
    }

    @Test("task-packet cache key changes with request or any worktree digest")
    func artifactCacheKeyTracksWorkspaceRevision() {
        let baseline = AgentWorkspaceRevision(
            repositoryRootPath: "/tmp/repo",
            repositoryCommonDirectoryPath: "/tmp/repo/.git",
            headOID: "abc",
            branchName: "main",
            stagedDigest: "staged-a",
            operationDigest: "operation-a",
            fileStates: ["a.swift": "modified|digest-a"]
        )
        let drifted = AgentWorkspaceRevision(
            repositoryRootPath: baseline.repositoryRootPath,
            repositoryCommonDirectoryPath: baseline.repositoryCommonDirectoryPath,
            headOID: baseline.headOID,
            branchName: baseline.branchName,
            stagedDigest: baseline.stagedDigest,
            operationDigest: baseline.operationDigest,
            fileStates: ["a.swift": "modified|digest-b"]
        )

        let key = AgentCodingArtifactCache.key(requestText: "实现 A", revision: baseline)
        #expect(key != AgentCodingArtifactCache.key(requestText: "实现 B", revision: baseline))
        #expect(key != AgentCodingArtifactCache.key(requestText: "实现 A", revision: drifted))
    }
}
