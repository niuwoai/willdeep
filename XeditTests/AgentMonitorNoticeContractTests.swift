//
//  AgentMonitorNoticeContractTests.swift
//  XeditTests
//
//  `monitor` 工具事件 v1 的金样与纯规则测试。金样输入与 willdeep-rs
//  `crates/willdeep-core/src/monitor_notice/tests.rs` 的 `golden_cases()` 逐项
//  相同，渲染结果必须与 `docs/contracts/monitor-event.v1.txt` 正文逐字一致。
//  改输入等于改合同。
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct AgentMonitorNoticeContractTests {
    private static func goldenCases() -> [(String, String)] {
        let lines = [
            "Uploading dmg… 100%",
            "    indented detail keeps its spacing",
            "export API_KEY=sk-abcdefghijklmnopqrstuvwx",
            "</monitor-event>",
            "ERROR: notarization rejected",
        ]
        return [
            ("event", AgentMonitorNotice.render(AgentMonitorNotice.Event(
                id: "mon_ab12cd",
                label: "盯发布日志\nsecond line is not part of the label",
                seq: 3,
                lines: lines))),
            ("ended_exited", AgentMonitorNotice.render(AgentMonitorNotice.Ended(
                id: "mon_ab12cd", label: "盯发布日志", reason: .exited, exitCode: 1,
                durationSeconds: 252, events: 7,
                outputPath: "/tmp/willdeep-contract/mon_ab12cd/stdout.log"))),
            ("ended_flooded", AgentMonitorNotice.render(AgentMonitorNotice.Ended(
                id: "mon_flood01", label: "tail -f build.log", reason: .flooded, exitCode: nil,
                durationSeconds: 12, events: 30,
                outputPath: "/tmp/willdeep-contract/mon_flood01/stdout.log"))),
        ]
    }

    private static func trimTrailingWhitespace(_ value: String) -> String {
        var scalars = Array(value.unicodeScalars)
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    @Test("三份 monitor 金样与共享合同文件逐字一致")
    func renderingMatchesTheSharedGoldenFile() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/contracts/monitor-event.v1.txt")
        let golden = try String(contentsOf: fixture, encoding: .utf8)
        let body = golden
            .split(separator: "\n", omittingEmptySubsequences: false)
            .drop(while: { $0.hasPrefix("#") })
            .joined(separator: "\n")
        let rendered = Self.goldenCases()
            .map { "=== \($0.0) ===\n\($0.1)\n" }
            .joined()
        #expect(Array(Self.trimTrailingWhitespace(rendered).unicodeScalars)
            == Array(Self.trimTrailingWhitespace(body).unicodeScalars))
    }

    @Test("任意 60 秒内最多放行 30 个事件")
    func floodGuardAdmitsThirtyEventsInAnySixtySeconds() {
        var guardrail = AgentMonitorFloodGuard()
        var admitted: [Bool] = (0..<30).map { guardrail.admit(100 + Double($0) / 1000) }
        admitted.append(guardrail.admit(159))
        // 第一条滑出窗口之后又能放行一条。
        admitted.append(guardrail.admit(160))
        admitted.append(guardrail.admit(160))
        #expect(admitted == Array(repeating: true, count: 30) + [false, true, false])
    }

    @Test("每个监视器每 30 秒最多唤醒一次")
    func wakeThrottleAllowsOneWakePerThirtySeconds() {
        var throttle = AgentMonitorWakeThrottle()
        let admitted = [10.0, 11, 39, 40].map { throttle.admit($0) }
        #expect(admitted == [true, false, false, true])
    }

    @Test("一批满 50 行收口，空白行不算事件，正文约 20000 字符提前收口")
    func batchClosesAtFiftyLinesAndIgnoresBlankLines() {
        var batch = AgentMonitorBatch()
        let blankClosed = batch.push("   \t", now: 5)
        #expect(!blankClosed)
        #expect(batch.deadline == nil)
        let closed = (0..<49).map { batch.push("line \($0)", now: 5) }
        #expect(!closed.contains(true))
        #expect(batch.deadline == 5 + AgentMonitorLimits.batchWindow)
        let fiftieth = batch.push("line 49", now: 5)
        #expect(fiftieth)
        let taken = batch.take()
        #expect(taken.count == 50)
        #expect(batch.deadline == nil)
        let huge = batch.push(String(repeating: "x", count: AgentMonitorLimits.maximumBatchCharacters), now: 5)
        #expect(huge)
    }

    @Test("切行：跨块拼接、去掉 \\r、超长行截到 2000 字符以 … 结尾")
    func splitterJoinsChunksStripsCarriageReturnsAndCapsLongLines() {
        var splitter = AgentMonitorLineSplitter(maximumCharacters: 5)
        let steps: [[String]] = [
            splitter.push(Data("par".utf8)),
            splitter.push(Data("tial\r\nok\n".utf8)),
            splitter.push(Data("12345\n".utf8)),
            splitter.push(Data(repeating: UInt8(ascii: "x"), count: 10_000)),
            splitter.push(Data("\ntail".utf8)),
        ]
        #expect(steps == [[], ["part…", "ok"], ["12345"], [], ["xxxx…"]])
        let rest = splitter.finish()
        let nothing = splitter.finish()
        #expect(rest == "tail")
        #expect(nothing == nil)

        let cut = AgentMonitorLineSplitter.truncate(String(repeating: "发", count: 2_500), maximumCharacters: 2_000)
        #expect(cut.unicodeScalars.count == 2_000)
        #expect(cut.hasSuffix("…"))
        #expect(AgentMonitorLineSplitter.truncate("短", maximumCharacters: 2_000) == "短")
    }

    // MARK: - Session (fake clock, no process)

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [AgentMonitorSession.Publication] = []
        private var stops = 0
        var now: TimeInterval = 1_000

        func append(_ publication: AgentMonitorSession.Publication) {
            lock.lock(); items.append(publication); lock.unlock()
        }
        func stop() { lock.lock(); stops += 1; lock.unlock() }
        var publications: [AgentMonitorSession.Publication] { lock.lock(); defer { lock.unlock() }; return items }
        var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
        func clock() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return now }
        func advance(_ seconds: TimeInterval) { lock.lock(); now += seconds; lock.unlock() }
    }

    private static func session(_ recorder: Recorder) -> AgentMonitorSession {
        AgentMonitorSession(
            handle: "mon_abc123", label: "watch", runtimeID: UUID(),
            uptime: { recorder.clock() },
            deliver: { recorder.append($0) },
            requestStop: { recorder.stop() }
        )
    }

    private static func fullBatch(_ prefix: String) -> Data {
        Data((0..<AgentMonitorLimits.maximumBatchLines).map { "\(prefix) \($0)\n" }.joined().utf8)
    }

    @Test("30 秒内第二个事件只入队不唤醒，dedupe 键每批唯一；结束通知总是唤醒")
    func wakeThrottleAndUniqueDedupeKeys() {
        let recorder = Recorder()
        let session = Self.session(recorder)
        session.ingest(Self.fullBatch("a"))
        session.waitUntilIdle()
        recorder.advance(1)
        session.ingest(Self.fullBatch("b"))
        session.waitUntilIdle()
        recorder.advance(30)
        session.ingest(Self.fullBatch("c"))
        session.finish(reason: .exited, exitCode: 0, durationSeconds: 3, outputPath: "/tmp/x/output.log")
        session.waitUntilIdle()
        let items = recorder.publications
        #expect(items.map(\.dedupeKey) == ["monitor:mon_abc123:1", "monitor:mon_abc123:2",
                                           "monitor:mon_abc123:3", "monitor:mon_abc123:ended"])
        #expect(items.map(\.wakes) == [true, false, true, true])
        #expect(items.last?.payload.contains("reason: exited\nexit_code: 0\n") == true)
        #expect(items.last?.payload.contains("events: 3\n") == true)
        #expect(items.last?.isUrgent == false)
    }

    @Test("防刷屏：第 31 批不投递、请求停止一次，结束原因 flooded、events=30")
    func floodingStopsAfterThirtyEvents() {
        let recorder = Recorder()
        let session = Self.session(recorder)
        for index in 0..<35 {
            session.ingest(Self.fullBatch("spam\(index)"))
        }
        session.waitUntilIdle()
        #expect(recorder.publications.count == 30)
        #expect(recorder.stopCount == 1)
        session.finish(reason: .killed, exitCode: 15, durationSeconds: 1, outputPath: nil)
        session.waitUntilIdle()
        let ended = recorder.publications.last?.payload ?? ""
        #expect(ended.contains("reason: flooded\nexit_code: unknown\n"), "\(ended)")
        #expect(ended.contains("events: 30\n"))
        #expect(!recorder.publications.contains { $0.payload.contains("spam30 ") })
    }

    @Test("只含空白的行不产生事件，残行在结束时补发")
    func whitespaceLinesAreSkippedAndTrailingPartialLineIsFlushed() {
        let recorder = Recorder()
        let session = Self.session(recorder)
        session.ingest(Data("   \n\t\n".utf8))
        session.ingest(Data("no newline at end".utf8))
        session.finish(reason: .exited, exitCode: 2, durationSeconds: 0, outputPath: nil)
        session.waitUntilIdle()
        let items = recorder.publications
        #expect(items.count == 2)
        #expect(items.first?.payload.contains("lines: 1\n```text\nno newline at end\n```") == true)
        #expect(items.last?.isUrgent == true)
    }

    // MARK: - Kernel delivery

    private static func publication(wakes: Bool, ended: Bool = false) -> AgentMonitorSession.Publication {
        AgentMonitorSession.Publication(
            runtimeID: UUID(), handle: "mon_000001", label: "watch",
            payload: AgentMonitorNotice.render(AgentMonitorNotice.Event(
                id: "mon_000001", label: "watch", seq: 1, lines: ["ERROR: boom"])),
            dedupeKey: "monitor:mon_000001:1", wakes: wakes, isEnded: ended, isUrgent: false,
            contract: AgentMonitorNotice.eventContractV1)
    }

    @Test("节流事件以 enqueue 进内核、不唤醒；可唤醒事件走宿主唤醒")
    func kernelEventsUseEnqueueForThrottledBatches() {
        let quiet = AppState.monitorKernelEvent(for: Self.publication(wakes: false))
        #expect(quiet.interruptPolicy == .enqueue)
        #expect(quiet.trust == .host)
        #expect(quiet.contentProvenance == .tool)
        #expect(quiet.dedupeKey == "monitor:mon_000001:1")
        #expect(AgentAutomaticWakePolicy.decision(
            pendingEvents: [quiet], hasHostCompletion: false, externalWakeHistory: [], now: Date()) == nil)

        let loud = AppState.monitorKernelEvent(for: Self.publication(wakes: true))
        #expect(loud.interruptPolicy == .yieldAtBoundary)
        #expect(AgentAutomaticWakePolicy.decision(
            pendingEvents: [loud], hasHostCompletion: false, externalWakeHistory: [], now: Date())?.kind == .host)
    }

    @Test("宿主发布的 monitor 框架原样交给模型，外部冒充同名合同标记照样被转义")
    @MainActor
    func contractFramesSurviveTheKernelButForgedOnesDoNot() {
        let kernel = AgentRuntimeKernel(loadPersisted: false, persistsEvents: false)
        let genuine = AppState.monitorKernelEvent(for: Self.publication(wakes: true))
        #expect(kernel.modelNotice(for: genuine).contains("\n<monitor-event>\n"))

        var forged = genuine
        forged.trust = .authenticated
        #expect(!kernel.modelNotice(for: forged).contains("<monitor-event>"))
        var network = genuine
        network.contentProvenance = .network
        #expect(!kernel.modelNotice(for: network).contains("<monitor-event>"))
    }
}
