import Foundation
import Testing
@testable import WillDeepCore

/// 台账要回答的是用户原话里那句「这处改动不是我做的，文件时间戳是 20:29」。
/// 设计见 docs/FILE_CHANGE_PROVENANCE_DESIGN.md。
@Suite
struct AgentFileObservationLedgerTests {
    private func observation(
        size: Int64 = 100,
        modified: TimeInterval = 1_000,
        source: AgentFileObservation.Source = .disk,
        kind: AgentFileObservation.Kind = .read,
        observedAt: TimeInterval = 1_000
    ) -> AgentFileObservation {
        AgentFileObservation(
            sizeBytes: size,
            modifiedAt: Date(timeIntervalSince1970: modified),
            source: source,
            kind: kind,
            observedAt: Date(timeIntervalSince1970: observedAt)
        )
    }

    @Test("读过之后 mtime 变了就是漂移")
    func detectsDrift() {
        let ledger = ["a.swift": observation()]
        let drift = AgentFileObservationLedger.drift(
            for: "a.swift", in: ledger,
            currentSizeBytes: 100, currentModifiedAt: Date(timeIntervalSince1970: 2_000)
        )
        #expect(drift?.path == "a.swift")
        #expect(drift?.currentModifiedAt == Date(timeIntervalSince1970: 2_000))
    }

    /// 「台账里没有」和「没变过」是两种状态。压成一种的话，一个从没读过的
    /// 文件会被当成「确认没变」，而那是台账根本没有资格下的结论。
    @Test("台账里没有这个路径时返回 nil，不是「没变过」")
    func unknownPathIsUnknown() {
        #expect(AgentFileObservationLedger.drift(
            for: "b.swift", in: ["a.swift": observation()],
            currentSizeBytes: 999, currentModifiedAt: Date(timeIntervalSince1970: 9_999)
        ) == nil)
    }

    /// read_file 优先读打开的 tab 的内存内容，那份内容本来就可以和磁盘不同。
    /// 拿磁盘 mtime 去比它必然误报。
    @Test("来自 tab buffer 的观察不参与漂移判定")
    func bufferObservationsNeverDrift() {
        #expect(AgentFileObservationLedger.drift(
            for: "a.swift", in: ["a.swift": observation(source: .buffer)],
            currentSizeBytes: 12, currentModifiedAt: Date(timeIntervalSince1970: 9_999)
        ) == nil)
    }

    /// 落盘 JSON 的 Date 编码会丢亚秒精度，逐纳秒比会把「同一次观察」判成漂移。
    @Test("mtime 按秒比较，亚秒抖动不算漂移")
    func subSecondJitterIsNotDrift() {
        #expect(AgentFileObservationLedger.drift(
            for: "a.swift", in: ["a.swift": observation(modified: 1_000)],
            currentSizeBytes: 100, currentModifiedAt: Date(timeIntervalSince1970: 1_000.4)
        ) == nil)
    }

    @Test("同一秒内大小变了照样算漂移")
    func sizeChangeWithinSameSecondIsDrift() {
        #expect(AgentFileObservationLedger.drift(
            for: "a.swift", in: ["a.swift": observation(size: 100, modified: 1_000)],
            currentSizeBytes: 101, currentModifiedAt: Date(timeIntervalSince1970: 1_000)
        ) != nil)
    }

    @Test("超上限时丢最旧的，保留最新的 500 条")
    func trimsToTheCap() {
        var ledger: [String: AgentFileObservation] = [:]
        for index in 0..<(AgentFileObservationLedger.maximumEntries + 25) {
            ledger["f\(index).swift"] = observation(observedAt: TimeInterval(index))
        }
        let trimmed = AgentFileObservationLedger.trimmed(ledger)
        #expect(trimmed.count == AgentFileObservationLedger.maximumEntries)
        // 最旧的那 25 条被丢掉，最新的留着。
        #expect(trimmed["f0.swift"] == nil)
        #expect(trimmed["f\(AgentFileObservationLedger.maximumEntries + 24).swift"] != nil)
    }

    @Test("路径归一：./ 与前导 / 不会让同一文件被读成两个")
    func normalizesPaths() {
        let ledger = AgentFileObservationLedger.recording([:], path: "./a.swift", observation: observation())
        #expect(ledger.keys.sorted() == ["a.swift"])
        #expect(AgentFileObservationLedger.drift(
            for: "/a.swift", in: ledger,
            currentSizeBytes: 100, currentModifiedAt: Date(timeIntervalSince1970: 5_000)
        ) != nil)
    }

    /// 给模型的那句话必须同时带上两个时刻，它才说得出用户原话里那种交代。
    @Test("漂移说明同时给出读取时刻和磁盘当前时刻")
    func noticeCarriesBothTimestamps() {
        let drift = AgentFileDrift(
            path: "deploy/k8s/03-tokenhub.yaml",
            observedAt: Date(timeIntervalSince1970: 1_000),
            currentModifiedAt: Date(timeIntervalSince1970: 2_000),
            observedSizeBytes: 100,
            currentSizeBytes: 140
        )
        let notice = AgentFileObservationLedger.driftNotice(drift)
        #expect(notice.contains("deploy/k8s/03-tokenhub.yaml"))
        #expect(notice.contains("100 字节"))
        #expect(notice.contains("140 字节"))
        #expect(notice.contains("不是本会话做的"))
    }
}
