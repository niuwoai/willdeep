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
        // 判据是「没被 keepalive 续命，所以会结束」，不是「结束得多快」。
        // 上限 0.4s 对窗口 6s 只有 15 倍余量，而这里每 50ms 一次 keepalive、
        // 每次都要过一趟 Task.sleep，满载全量下实测 7.52s 就把 6s 击穿了。
        // 放到 30s：要证伪的是「无限挂着」，30s 同样证得了，而余量从 15 倍
        // 提到 75 倍，判据没有被削弱。
        #expect(Date().timeIntervalSince(started) < 30)
    }

    /// 判据是两条同时成立：每一段间隔都短于空转上限（所以时钟被续上），而
    /// 整条流的总时长远超空转上限（所以「没续命也能过」被排除）。
    ///
    /// 用手动时钟，不用墙钟。墙钟版本（producer 真 sleep 100ms、上限 1s）
    /// 余量已放到十倍，仍在满载全量下被协作线程池饥饿击穿：一次跑了 17s，
    /// 某个间隔被拖过 1s 就误报 streamStalled。时间现在只由 producer 推进，
    /// 且锁步：推进 0.6 个上限 → 等看门狗真实检查一次 → 才发 payload →
    /// 等消费方收到。调度再慢也只会让测试变慢，不会误报；若 payload 不续命，
    /// 第二个间隔的检查就会看到 1.2 个上限而当场报 stall。
    @Test("payload arriving in time keeps the stream alive", .timeLimit(.minutes(1)))
    func payloadResetsTheClock() async throws {
        let payloadCount = 20
        let idleTimeout: TimeInterval = 60
        let clock = ManualIdleClock()
        let (acks, ackContinuation) = AsyncStream<Void>.makeStream()
        let source = AsyncStream<String> { continuation in
            let producer = Task {
                var ackIterator = acks.makeAsyncIterator()
                for index in 0..<payloadCount {
                    clock.advance(by: idleTimeout * 0.6)
                    // 推进之后，消费方已在等下一行，此刻读时钟的只有看门狗。
                    await clock.waitForRead()
                    continuation.yield("data: \(index)")
                    guard await ackIterator.next() != nil else { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
        var count = 0
        defer { ackContinuation.finish() }
        for try await _ in AgentStreamIdleGuard.lines(
            source,
            idleTimeout: idleTimeout,
            pollInterval: 0.005,
            now: { clock.now() }
        ) {
            count += 1
            ackContinuation.yield(())
        }
        #expect(count == payloadCount)
        #expect(clock.elapsed >= idleTimeout * 10)
    }

    @Test("the stall error names the idle limit")
    func stallErrorShape() {
        let error = AgentClientError.streamStalled(idleSeconds: 180)
        #expect(error.errorDescription?.contains("180") == true)
    }
}

/// 只由测试推进的时钟；记录被读次数，用来确认看门狗在两次推进之间真的检查过。
private nonisolated final class ManualIdleClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = Date(timeIntervalSinceReferenceDate: 0)
    private var offset: TimeInterval = 0
    private var reads = 0

    func now() -> Date {
        lock.withLock {
            reads += 1
            return origin.addingTimeInterval(offset)
        }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { offset += seconds }
    }

    var elapsed: TimeInterval {
        lock.withLock { offset }
    }

    /// 等到下一次有人读时钟。
    func waitForRead() async {
        let seen = lock.withLock { reads }
        while lock.withLock({ reads }) == seen, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
