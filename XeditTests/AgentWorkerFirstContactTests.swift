import Foundation
import Testing
@testable import WillDeep

/// A Worker whose first request never produces an event must fail fast with
/// an explicit error — not a cancellation, which the runner reads as the
/// user pressing Stop — so the parent's spawn failure branch runs and the
/// delegate-first fence is lifted.
@Suite
struct AgentWorkerFirstContactTests {
    @Test("no contact by the deadline fails with the first-contact error")
    func timesOutWithoutContact() async {
        let started = Date()
        await #expect(throws: AgentSubagentError.self) {
            try await AgentWorkerFirstContact.race(
                timeout: 0.2,
                hasMadeContact: { false },
                operation: { () async throws -> Int in
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return 1
                }
            )
        }
        // It did not wait for the five-second operation.
        #expect(Date().timeIntervalSince(started) < 2)
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
