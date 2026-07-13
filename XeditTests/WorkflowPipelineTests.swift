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
}
