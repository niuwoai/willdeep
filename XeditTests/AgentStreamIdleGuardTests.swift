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

    @Test("lines pass through unchanged and the stream ends when the source ends", .timeLimit(.minutes(1)))
    func passThrough() async throws {
        let source = AsyncStream<String> { continuation in
            continuation.yield("data: a")
            continuation.yield("")
            continuation.yield("data: b")
            continuation.finish()
        }
        var seen: [String] = []
        for try await line in AgentStreamIdleGuard.lines(source, idleTimeout: 120) {
            seen.append(line)
        }
        #expect(seen == ["data: a", "", "data: b"])
    }

    @Test("取消消费立即终止上游读取，不等待空闲计时器", .timeLimit(.minutes(1)))
    func cancellationReachesSource() async throws {
        let (source, sourceContinuation) = AsyncStream<String>.makeStream()
        let (received, receivedContinuation) = AsyncStream<Void>.makeStream()
        let (terminated, terminatedContinuation) = AsyncStream<Void>.makeStream()
        sourceContinuation.onTermination = { _ in
            terminatedContinuation.yield(())
            terminatedContinuation.finish()
        }
        let consumer = Task {
            for try await _ in AgentStreamIdleGuard.lines(source, idleTimeout: 120) {
                receivedContinuation.yield(())
            }
        }
        defer {
            consumer.cancel()
            sourceContinuation.finish()
            receivedContinuation.finish()
        }
        sourceContinuation.yield("data: first")
        for await _ in received { break }
        consumer.cancel()
        _ = await consumer.result
        for await _ in terminated { break }
    }

    @Test("keepalives alone do not hold the stream open past the idle limit")
    func keepalivesDoNotCountAsProgress() async {
        let source = AsyncStream<String> { continuation in
            let producer = Task {
                // A gateway pinging forever with no payload.
                while !Task.isCancelled {
                    continuation.yield(": ping")
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
        let started = Date()
        await #expect(throws: AgentClientError.self) {
            for try await _ in AgentStreamIdleGuard.lines(source, idleTimeout: 0.4) {}
        }
        #expect(Date().timeIntervalSince(started) < 6)
    }

    /// 判据是两条同时成立：每一段间隔都短于空转上限（所以时钟被续上），而
    /// 整条流的总时长超过空转上限（所以「没续命也能过」被排除）。
    ///
    /// 余量刻意拉到十倍。原本是 4 个 payload × 150ms 对 0.4s 上限，余量 2.7
    /// 倍，满载时一次 `Task.sleep` 被拖过线就误报 streamStalled——满载跑全量
    /// 时它就是这么红的。现在 20 × 100ms 对 1.0s：间隔要被拖慢十倍才会误报，
    /// 而总时长 2s 仍是上限的两倍，判据没有被削弱。
    @Test("payload arriving in time keeps the stream alive")
    func payloadResetsTheClock() async throws {
        let payloadCount = 20
        let source = AsyncStream<String> { continuation in
            let producer = Task {
                for index in 0..<payloadCount {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continuation.yield("data: \(index)")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
        var count = 0
        for try await _ in AgentStreamIdleGuard.lines(source, idleTimeout: 1.0) {
            count += 1
        }
        #expect(count == payloadCount)
    }

    @Test("the stall error names the idle limit")
    func stallErrorShape() {
        let error = AgentClientError.streamStalled(idleSeconds: 180)
        #expect(error.errorDescription?.contains("180") == true)
    }
}
