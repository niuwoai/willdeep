import Foundation
import Testing
@testable import WillDeep

/// SSE keepalives are bytes, so the URLSession request timeout never fires
/// on a gateway that pings a dead upstream. The idle guard counts only
/// payload lines; these pin what counts and that the stall surfaces as an
/// explicit error.
@Suite
struct AgentStreamIdleGuardTests {
    @Test("comment and blank lines are keepalives; data and event lines are payload")
    func payloadClassification() {
        #expect(!AgentStreamIdleGuard.isPayloadLine(": ping"))
        #expect(!AgentStreamIdleGuard.isPayloadLine(""))
        #expect(AgentStreamIdleGuard.isPayloadLine("data: {}"))
        #expect(AgentStreamIdleGuard.isPayloadLine("event: message_start"))
    }

    @Test("lines pass through unchanged and the stream ends when the source ends")
    func passThrough() async throws {
        let source = AsyncStream<String> { continuation in
            continuation.yield("data: a")
            continuation.yield("")
            continuation.yield("data: b")
            continuation.finish()
        }
        var seen: [String] = []
        for try await line in AgentStreamIdleGuard.lines(source, idleTimeout: 5) {
            seen.append(line)
        }
        #expect(seen == ["data: a", "", "data: b"])
    }

    @Test("keepalives alone do not hold the stream open past the idle limit")
    func keepalivesDoNotCountAsProgress() async {
        let source = AsyncStream<String> { continuation in
            Task {
                // A gateway pinging forever with no payload.
                while !Task.isCancelled {
                    continuation.yield(": ping")
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
        let started = Date()
        await #expect(throws: AgentClientError.self) {
            for try await _ in AgentStreamIdleGuard.lines(source, idleTimeout: 0.4) {}
        }
        #expect(Date().timeIntervalSince(started) < 6)
    }

    @Test("payload arriving in time keeps the stream alive")
    func payloadResetsTheClock() async throws {
        let source = AsyncStream<String> { continuation in
            Task {
                for index in 0..<4 {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    continuation.yield("data: \(index)")
                }
                continuation.finish()
            }
        }
        var count = 0
        for try await _ in AgentStreamIdleGuard.lines(source, idleTimeout: 0.4) {
            count += 1
        }
        #expect(count == 4)
    }

    @Test("the stall error names the idle limit")
    func stallErrorShape() {
        let error = AgentClientError.streamStalled(idleSeconds: 180)
        #expect(error.errorDescription?.contains("180") == true)
    }
}
