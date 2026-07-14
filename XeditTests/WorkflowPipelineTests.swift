//
//  WorkflowPipelineTests.swift
//  XeditTests
//
//  1.85.0-rc19:WorkflowEngine.pipeline + WorkflowState 行为回归。
//  pipeline 自身是 parallel 的语法糖,这里只验「形态对」(items 都
//  跑了 / 失败返回 nil / shared state actor 在并发下不丢更新)。
//
//  没造 AgentSubagent runner 真跑,而是直接验内部行为 —— phase 1 的
//  AgentStructuredSchemaTests 已经覆盖 schema 校验路径;phase 3 重写
//  DeepResearchWorkflow 时再做端到端冒烟。
//

import Foundation
import Testing
@testable import WillDeep

extension WillDeepTests {
    @MainActor
    @Test("WorkflowState actor:并发 update 不丢任何值")
    func workflowStateActorAggregatesAllUpdatesUnderContention() async {
        let counter = WorkflowState(0)
        // 100 个并发 task 各自 +1,最后必须读到 100,且每次 update 闭包
        // 也能拿到当时的 new value(给 caller 反馈用)。
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await counter.update { value -> Int in
                        value += 1
                        return value
                    }
                }
            }
            var observed: Set<Int> = []
            for await new in group {
                observed.insert(new)
            }
            // 100 个 new value 应该是 1..100 每个出现一次。
            #expect(observed == Set(1...100))
        }
        let final = await counter.snapshot()
        #expect(final == 100)
    }

    @MainActor
    @Test("WorkflowState 配 Set 跑 URL dedup,重复 url 被吃掉")
    func workflowStateDedupesURLsAcrossConcurrentInserters() async {
        let seen = WorkflowState(Set<String>())
        let urls = [
            "https://a.com/p1", "https://b.com/p2", "https://a.com/p1",
            "https://c.com/p3", "https://b.com/p2", "https://d.com/p4",
            "https://a.com/p1",
        ]
        var insertedFlags: [Bool] = []
        await withTaskGroup(of: (Int, Bool).self) { group in
            for (i, url) in urls.enumerated() {
                group.addTask {
                    let inserted = await seen.update { $0.insert(url).inserted }
                    return (i, inserted)
                }
            }
            // 按原 index 排序结果,断言才稳。
            var collected: [(Int, Bool)] = []
            for await pair in group { collected.append(pair) }
            collected.sort { $0.0 < $1.0 }
            insertedFlags = collected.map(\.1)
        }
        let finalCount = await seen.snapshot().count
        #expect(finalCount == 4)
        // inserted 标志:7 个 url 里有 4 个唯一,所以应该有 4 个 true。
        #expect(insertedFlags.filter { $0 }.count == 4)
    }

    @MainActor
    @Test("Workflow watchdog times out without waiting for a stuck operation")
    func workflowWatchdogDoesNotWaitForUncancellableOperation() async {
        let startedAt = Date()
        var didTimeout = false

        do {
            _ = try await AppState.runWorkflowWithWatchdog(seconds: 0.05) {
                await withCheckedContinuation { continuation in
                    Task.detached {
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        continuation.resume()
                    }
                }
                return "late result"
            }
            #expect(Bool(false), "watchdog should time out before the operation completes")
        } catch {
            if case WorkflowError.timedOut = error {
                didTimeout = true
            } else {
                #expect(Bool(false), "expected WorkflowError.timedOut, got \(error)")
            }
        }

        #expect(didTimeout)
        #expect(Date().timeIntervalSince(startedAt) < 0.5)
    }

    // MARK: - 省心托管 workflow 模型解析 (1.155.0-rc4)
    //
    // 主循环每回合跑 routing judge,workflow 子 agent 之前直接拿静态
    // 配置模型、绕过托管路由。修复后:floor 与 high 取高者,按 workflow
    // 声明的任务域解析成 some.im 虚拟模型。

    @MainActor
    @Test("省心托管:workflow 模型 floor 与 high 取高者、按域映射")
    func managedWorkflowModelResolvesFloorAndDomain() {
        // 默认 floor(.low)抬到 high。
        #expect(
            AppState.managedWorkflowModel(floor: .low, domain: .general, hasCodingPlan: false)
                == SomeIMManagedModel.autoPro
        )
        // 会话 floor 已升到 premium 时不降档。
        #expect(
            AppState.managedWorkflowModel(floor: .premium, domain: .general, hasCodingPlan: false)
                == SomeIMManagedModel.autoPremium
        )
        // coding 域走 code* 梯子。
        #expect(
            AppState.managedWorkflowModel(floor: .low, domain: .coding, hasCodingPlan: false)
                == SomeIMManagedModel.codeHigh
        )
        // coding plan 生效时统一走 coding-plan 梯子。
        #expect(
            AppState.managedWorkflowModel(floor: .low, domain: .general, hasCodingPlan: true)
                == SomeIMManagedModel.codingPlanHigh
        )
    }

    @MainActor
    @Test("workflow 任务域声明:读代码的 coding,其余默认 general")
    func workflowManagedDomainDeclarations() {
        #expect(CodeReviewWorkflow().managedDomain == .coding)
        #expect(BugHuntWorkflow().managedDomain == .coding)
        #expect(PRReviewWorkflow().managedDomain == .coding)
        #expect(DeepResearchWorkflow().managedDomain == .general)
    }
}
