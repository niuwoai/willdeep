//
//  AgentPinnedWorkerTests.swift
//  XeditTests
//
//  操作员在 composer 里 `@` 点名一个工种。
//
//  这跟关键词打分、模型判断都不是一回事：那两条是「猜」，点名是明确指令。
//  所以它满分、强制委派、不被模型推翻，也不进预跑（预跑是宿主替用户抢跑，
//  点名要的是「派给他」而不是「现在就跑」）。
//
//  刻意独立成 @Suite 而不并进路由契约那个文件：函数级 -only-testing 选不中
//  聚合 suite（静默跑 0 个用例还报 TEST SUCCEEDED）。
//

import Foundation
import Testing
@testable import WillDeep

@Suite("Operator-pinned worker", .serialized)
@MainActor
struct AgentPinnedWorkerTests {
    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-pinned-worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    @Test("点名的判决是明确指令：满分、强制委派、不预跑")
    func pinnedDecisionIsAnInstructionNotAGuess() {
        let decision = AgentRequestRouter.pinnedDecision(profileID: AgentSubagentProfileCatalog.testerID)
        #expect(decision.profileID == AgentSubagentProfileCatalog.testerID)
        #expect(decision.confidence == 100)
        #expect(decision.requiresDelegatedExecution, "点了名还让根模型自己上手，等于没点")
        #expect(decision.autoDispatchEligible == false, "预跑是宿主抢跑，用户点名的是「派给他」")
        #expect(decision.preflightProfileID == nil)
        #expect(decision.isOperatorPinned)
        // 关键词判出来的同一个工种不该被误认成点名
        #expect(AgentRequestRouter.classify("跑一下测试").isOperatorPinned == false)
    }

    @Test("点名的 steering 说的是「操作员指定」而不是「我分类成」")
    func pinnedSteeringSaysWhoDecided() throws {
        let steering = try #require(
            AgentRequestRouter.pinnedDecision(profileID: AgentSubagentProfileCatalog.readerID).steering
        )
        #expect(steering.contains("operator named"))
        #expect(steering.contains("do not re-route"))
        #expect(!steering.contains("WillDeep classified"))
    }

    @Test("点名单槽位：再点一个就换人，不会同时挂着两个")
    func pinningIsSingleSlot() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let appState = AppState()
        _ = appState.startNewAgentSession(inWorkspaceAt: workspace.path)

        appState.agentPendingWorkerProfileID = AgentSubagentProfileCatalog.readerID
        appState.agentPendingWorkerProfileID = AgentSubagentProfileCatalog.testerID
        #expect(appState.agentPendingWorkerProfileID == AgentSubagentProfileCatalog.testerID)

        appState.agentPendingWorkerProfileID = nil
        #expect(appState.agentPendingWorkerProfileID == nil)
    }

    @Test("点了名又 /no-subagent：拒绝发送并把矛盾讲清楚")
    func pinningConflictsWithForbiddenDelegation() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let appState = AppState()
        let session = appState.startNewAgentSession(inWorkspaceAt: workspace.path)
        appState.agentPendingWorkerProfileID = AgentSubagentProfileCatalog.opsRunnerID

        appState.sendAgentMessage(withDelegationPolicy: .forbidden, text: "重启一下服务")

        let runtime = try #require(appState.runtime(for: session.id))
        #expect(runtime.errorMessage == L10n.AgentDelegation.pinnedWorkerConflict)
        // 消息没被发出去，点名也还留着——让用户自己撤其中一条
        #expect(runtime.messages.isEmpty)
        #expect(appState.agentPendingWorkerProfileID == AgentSubagentProfileCatalog.opsRunnerID)
    }

    @Test("@ 菜单里的工种就是那份「给人看的」清单")
    func pickerOffersThePublicTrades() {
        let ids = AgentSubagentProfileCatalog.publicBuiltIn.map(\.id)
        // 特权工种可以被点名——用户明确点名与「小模型猜」是两回事，
        // 它自己带审批。
        #expect(ids.contains(AgentSubagentProfileCatalog.opsRunnerID))
        // 分档/升级用的内部工种不该出现在人面前
        #expect(!ids.contains(AgentSubagentProfileCatalog.smallImplementerID))
        #expect(!ids.contains(AgentSubagentProfileCatalog.smallReviewerID))
        #expect(!ids.contains(AgentSubagentProfileCatalog.securityGuardID))
        for profile in AgentSubagentProfileCatalog.publicBuiltIn {
            #expect(!profile.localizedDisplayName.isEmpty)
            #expect(!profile.localizedPurpose.isEmpty)
        }
    }
}
