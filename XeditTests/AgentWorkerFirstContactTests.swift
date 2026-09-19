import Foundation
import Testing
@testable import WillDeep

/// A Worker whose first request never produces an event must fail fast with
/// an explicit error — not a cancellation, which the runner reads as the
/// user pressing Stop — so the parent's spawn failure branch runs and the
/// delegate-first fence is lifted.
@Suite
struct AgentWorkerFirstContactTests {
    /// 判据是「超时路径走通、没有去等那个操作」，不看墙钟。
    ///
    /// 之前用 `< 10s` 的墙钟窗口证明「没等」：从 2 秒放宽到 10 秒后，满载
    /// 全量下仍被调度饥饿击穿（实测 11.2s），两次挡住发布测试关
    /// （1.390.0-rc5、1.392.0-rc1）。现在操作睡一小时、只在被取消时提前醒：
    /// race 能返回，就只能是超时抛错 + 取消了操作；若超时路径坏了，它会一直
    /// 等下去，由 timeLimit 判红。负载只会让它变慢，不会误报。
    @Test("no contact by the deadline fails with the first-contact error", .timeLimit(.minutes(1)))
    func timesOutWithoutContact() async {
        let operationCancelled = ContactFlag()
        await #expect(throws: AgentSubagentError.self) {
            try await AgentWorkerFirstContact.race(
                timeout: 0.2,
                hasMadeContact: { false },
                operation: { () async throws -> Int in
                    do {
                        try await Task.sleep(nanoseconds: 3_600_000_000_000)
                    } catch {
                        await operationCancelled.set()
                        throw error
                    }
                    return 1
                }
            )
        }
        // race 返回前会等被取消的操作退出，所以这里读到的一定是最终状态。
        #expect(await operationCancelled.value)
    }

    @Test("the error names the deadline and is not a cancellation")
    func errorShape() async {
        do {
            _ = try await AgentWorkerFirstContact.race(
                timeout: 0.05,
                hasMadeContact: { false },
                operation: { () async throws -> Int in
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    return 1
                }
            )
            Issue.record("expected a timeout")
        } catch let error as AgentSubagentError {
            guard case .firstContactTimeout(let seconds) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(seconds == 0.05)
            #expect(error.errorDescription?.isEmpty == false)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    /// Contact made before the deadline means the clock stands down and the
    /// operation is allowed to take as long as it needs.
    @Test("contact before the deadline lets a slow operation finish")
    func contactDisarmsTheClock() async throws {
        let contact = ContactFlag()
        let value = try await AgentWorkerFirstContact.race(
            timeout: 0.1,
            hasMadeContact: { await contact.value },
            operation: { () async throws -> String in
                await contact.set()
                try await Task.sleep(nanoseconds: 300_000_000)
                return "done"
            }
        )
        #expect(value == "done")
    }

    @Test("a fast operation returns before the clock is consulted")
    func fastOperationWins() async throws {
        let value = try await AgentWorkerFirstContact.race(
            timeout: 1,
            hasMadeContact: { false },
            operation: { 42 }
        )
        #expect(value == 42)
    }

    /// The operation's own failure must surface as itself, not be masked
    /// by the clock.
    @Test("an operation error propagates unchanged")
    func operationErrorPropagates() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await AgentWorkerFirstContact.race(
                timeout: 1,
                hasMadeContact: { false },
                operation: { () async throws -> Int in throw Boom() }
            )
        }
    }

    private actor ContactFlag {
        var value = false
        func set() { value = true }
    }
}
