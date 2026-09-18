//
//  PerformanceWatchdogTests.swift
//  XeditTests
//
//  CPU 看门狗：触发判定（3 秒 / 30% / 冷却 / 启动宽限 / 日上限）、CPU 读数、
//  调用栈脱敏与截断、gzip 封装、上报请求体字段、落盘与上传结果处理、开关默认值。
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct CPUSustainedLoadDetectorTests {
    private let launch = Date(timeIntervalSince1970: 5_000_000)
    /// 越过启动宽限期后的某一刻。
    private var t0: Date { launch.addingTimeInterval(60) }

    private func feed(
        _ detector: inout CPUSustainedLoadDetector,
        percents: [Double],
        from start: Date
    ) -> [CPUSustainedLoadDetector.Trigger?] {
        percents.enumerated().map { index, percent in
            detector.ingest(percent: percent, at: start.addingTimeInterval(TimeInterval(index)))
        }
    }

    /// 用户的原话：「能持续 3 秒就不错了」。1 秒一采，连续超阈值满 3 秒就要触发。
    @Test("连续 3 秒超过 30% 即触发，并带出峰值与均值")
    func triggersAfterThreeSustainedSeconds() {
        var detector = CPUSustainedLoadDetector(launchedAt: launch)
        let results = feed(&detector, percents: [40, 80, 60, 120], from: t0)
        #expect(results[0] == nil)
        #expect(results[1] == nil)
        #expect(results[2] == nil)
        let trigger = results[3]
        #expect(trigger?.sustainedSeconds == 3)
        #expect(trigger?.peakPercent == 120)
        #expect(trigger?.averagePercent == 75)
    }

    @Test("中途掉到阈值以下会重新计时")
    func dipResetsTheStreak() {
        var detector = CPUSustainedLoadDetector(launchedAt: launch)
        let results = feed(&detector, percents: [50, 50, 20, 50, 50, 50], from: t0)
        #expect(results.prefix(5).allSatisfy { $0 == nil })
        #expect(results[5] == nil)
        let next = detector.ingest(percent: 50, at: t0.addingTimeInterval(6))
        #expect(next != nil)
    }

    @Test("恰好 30% 不算超阈值")
    func thresholdIsExclusive() {
        var detector = CPUSustainedLoadDetector(launchedAt: launch)
        let results = feed(&detector, percents: [30, 30, 30, 30, 30], from: t0)
        #expect(results.allSatisfy { $0 == nil })
    }

    @Test("启动宽限期内不触发")
    func launchGraceSuppressesStartupSpike() {
        var detector = CPUSustainedLoadDetector(launchedAt: launch)
        let results = feed(&detector, percents: [90, 90, 90, 90, 90], from: launch.addingTimeInterval(1))
        #expect(results.allSatisfy { $0 == nil })
    }

    @Test("触发后 10 分钟冷却，冷却结束再次可触发")
    func cooldownBetweenReports() {
        var detector = CPUSustainedLoadDetector(launchedAt: launch)
        let first = feed(&detector, percents: [90, 90, 90, 90], from: t0)
        #expect(first[3] != nil)
        let during = feed(&detector, percents: [90, 90, 90, 90, 90], from: t0.addingTimeInterval(60))
        #expect(during.allSatisfy { $0 == nil })
        // 冷却结束后负载回落又再起：重新攒满 3 秒即可再报。
        let after = feed(&detector, percents: [10, 90, 90, 90, 90], from: t0.addingTimeInterval(2 + 10 * 60))
        #expect(after[4] != nil)
    }

    /// 负载在冷却期间一直没退：冷却一过立刻报，不用再等 3 秒。
    @Test("冷却期间持续高负载，冷却一结束立即触发")
    func sustainedLoadThroughCooldownFiresWhenCooldownEnds() {
        var detector = CPUSustainedLoadDetector(launchedAt: launch)
        let first = feed(&detector, percents: [90, 90, 90, 90], from: t0)
        #expect(first[3] != nil)
        let through = feed(&detector, percents: Array(repeating: 90, count: 600), from: t0.addingTimeInterval(4))
        let fired = through.enumerated().compactMap { $0.element == nil ? nil : $0.offset }
        // 首次触发在 t0+3，冷却 600 秒 → t0+603 即 through 的下标 599。
        #expect(fired == [599])
    }

    @Test("24 小时内触发次数有上限")
    func dailyCap() {
        var policy = CPUSustainedLoadDetector.Policy()
        policy.cooldown = 0
        policy.maxTriggersPerDay = 2
        var detector = CPUSustainedLoadDetector(policy: policy, launchedAt: launch)
        var triggers = 0
        for burst in 0..<4 {
            let start = t0.addingTimeInterval(TimeInterval(burst * 10))
            triggers += feed(&detector, percents: [90, 90, 90, 90, 10], from: start).compactMap { $0 }.count
        }
        #expect(triggers == 2)
        let nextDay = feed(&detector, percents: [90, 90, 90, 90], from: t0.addingTimeInterval(24 * 60 * 60 + 60))
        #expect(nextDay[3] != nil)
    }

    @Test("默认策略就是 30% / 3 秒")
    func defaultPolicyMatchesProductDecision() {
        let policy = CPUSustainedLoadDetector.Policy()
        #expect(policy.thresholdPercent == 30)
        #expect(policy.sustainedSeconds == 3)
    }
}

@Suite
struct ProcessCPUClockTests {
    @Test("首次读数只建基线；之后按墙钟折算成单核百分比")
    func percentFromDeltas() {
        var clock = ProcessCPUClock()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let first = clock.percentSinceLastRead(cpuSeconds: 10, at: t0)
        let second = clock.percentSinceLastRead(cpuSeconds: 11.5, at: t0.addingTimeInterval(1))
        let third = clock.percentSinceLastRead(cpuSeconds: 11.8, at: t0.addingTimeInterval(3))
        #expect(first == nil)
        #expect(second == 150)
        #expect(abs((third ?? 0) - 15) < 0.0001)
    }

    @Test("真实进程读数单调不减")
    func realProcessCPUIsMonotonic() {
        let a = ProcessCPUClock.currentProcessCPUSeconds()
        var sink = 0
        for i in 0..<200_000 { sink &+= i }
        let b = ProcessCPUClock.currentProcessCPUSeconds()
        #expect(sink != 0)
        #expect(b >= a)
    }
}

@Suite
struct PerformanceReportPayloadTests {
    private func sampleReport(stacks: String = "Call graph:\n  1 main") -> PerformanceReport {
        PerformanceReport(
            reportID: "3f0c1a8e-8d5b-4c55-9d8e-6b8a1f0e2c11",
            installID: "8d6f5a2c-1b3e-4f70-a9b1-2c3d4e5f6a7b",
            appVersion: "1.388.0-rc1",
            build: "793",
            osVersion: "26",
            arch: "arm64",
            locale: "zh-Hans",
            capturedAt: "2026-09-18T10:00:00Z",
            activeSurface: "agent.new_session",
            thresholdPercent: 30,
            sustainedSeconds: 3,
            peakCPUPercent: 142.3,
            averageCPUPercent: 98.1,
            sampleDurationSeconds: 2,
            callStacksFormat: PerformanceReport.callStacksFormat,
            callStacks: stacks
        )
    }

    @Test("请求体字段名与服务端契约一致")
    func payloadKeysMatchServerContract() throws {
        let data = try JSONEncoder().encode(sampleReport())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [
            "report_id", "install_id", "app_version", "build", "os_version", "arch", "locale",
            "captured_at", "active_surface", "threshold_percent", "sustained_seconds",
            "peak_cpu_percent", "average_cpu_percent", "sample_duration_seconds",
            "call_stacks_format", "call_stacks"
        ])
        #expect(object["call_stacks_format"] as? String == "macos-sample-v1")
    }

    @Test("主目录与其他账户名被抹掉，调用栈与 UUID 保留")
    func redactsHomeDirectoryAndAccountNames() {
        let raw = """
        Path:            /Users/rocky/Library/Caches/WillDeep/WillDeep.app/Contents/MacOS/WillDeep
        +   2830 AppState.loadRoundtableHistory() (in WillDeep) + 120 [0x100a]
        0x100000000 - 0x100ffffff +WillDeep (1.388.0) <0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9> /Users/rocky/Applications/WillDeep.app/Contents/MacOS/WillDeep
        /Users/otheruser/lib/libfoo.dylib
        """
        let redacted = PerformanceReportRedaction.redact(raw, homeDirectory: "/Users/rocky")
        #expect(!redacted.contains("rocky"))
        #expect(!redacted.contains("otheruser"))
        #expect(redacted.contains("~/Library/Caches/WillDeep"))
        #expect(redacted.contains("/Users/_/lib/libfoo.dylib"))
        #expect(redacted.contains("AppState.loadRoundtableHistory()"))
        #expect(redacted.contains("<0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9>"))
    }

    @Test("超长调用栈按字节截断并留标记")
    func truncatesOversizedStacks() {
        let text = String(repeating: "栈", count: 1_000)
        let truncated = PerformanceReportRedaction.truncated(text, maxBytes: 600)
        #expect(truncated.utf8.count <= 600)
        #expect(truncated.contains("[truncated by WillDeep: 3000 bytes total]"))
        #expect(PerformanceReportRedaction.truncated("short", maxBytes: 600) == "short")
    }

    @Test("gzip 头尾正确，DEFLATE 段能解回原文")
    func gzipRoundTrip() throws {
        let original = Data(String(repeating: "Thread_1 main-thread\n", count: 500).utf8)
        let gz = try #require(PerformanceReportGzip.gzip(original))
        #expect(gz.prefix(3) == Data([0x1f, 0x8b, 0x08]))
        #expect(gz.count < original.count)

        let deflated = gz.dropFirst(10).dropLast(8)
        let inflated = try (Data(deflated) as NSData).decompressed(using: .zlib) as Data
        #expect(inflated == original)

        let trailer = Array(gz.suffix(8))
        let crc = UInt32(trailer[0]) | UInt32(trailer[1]) << 8 | UInt32(trailer[2]) << 16 | UInt32(trailer[3]) << 24
        let size = UInt32(trailer[4]) | UInt32(trailer[5]) << 8 | UInt32(trailer[6]) << 16 | UInt32(trailer[7]) << 24
        #expect(crc == PerformanceReportGzip.crc32(original))
        #expect(size == UInt32(original.count))
    }

    @Test("CRC32 与标准值一致")
    func crc32KnownVector() {
        #expect(PerformanceReportGzip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test("状态码映射：2xx 送达、4xx（除 429）丢弃、其余重试")
    func statusCodeOutcomes() {
        #expect(PerformanceReportUploader.outcome(forStatusCode: 202) == .delivered)
        #expect(PerformanceReportUploader.outcome(forStatusCode: 200) == .delivered)
        #expect(PerformanceReportUploader.outcome(forStatusCode: 400) == .rejected)
        #expect(PerformanceReportUploader.outcome(forStatusCode: 413) == .rejected)
        #expect(PerformanceReportUploader.outcome(forStatusCode: 429) == .retryLater)
        #expect(PerformanceReportUploader.outcome(forStatusCode: 503) == .retryLater)
        #expect(PerformanceReportUploader.outcome(forStatusCode: 0) == .retryLater)
    }

    // MARK: - 上传与落盘

    private func makeSpool() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-perf-spool-\(UUID().uuidString)", isDirectory: true)
    }

    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func append(_ request: URLRequest) { lock.lock(); requests.append(request); lock.unlock() }
        var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    }

    @Test("送达后删掉落盘，请求带 gzip 与登录态")
    func deliveredReportIsRemovedFromSpool() async throws {
        let spool = makeSpool()
        defer { try? FileManager.default.removeItem(at: spool) }
        let log = RequestLog()
        let uploader = PerformanceReportUploader(
            transport: { request in log.append(request); return 202 },
            spoolDirectory: spool,
            sessionTokenProvider: { "session-token" }
        )

        await uploader.submit(sampleReport())

        #expect(await uploader.spooledCount() == 0)
        let request = try #require(log.all.first)
        #expect(request.url?.path == "/api/v1/public/telemetry/perf-reports")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Encoding") == "gzip")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        let body = try #require(request.httpBody)
        #expect(body.prefix(2) == Data([0x1f, 0x8b]))
    }

    @Test("网络失败留在落盘，下次 drain 补发")
    func failedReportStaysSpooledUntilDrain() async {
        let spool = makeSpool()
        defer { try? FileManager.default.removeItem(at: spool) }
        let failing = PerformanceReportUploader(
            transport: { _ in throw URLError(.notConnectedToInternet) },
            spoolDirectory: spool,
            sessionTokenProvider: { nil }
        )
        await failing.submit(sampleReport())
        #expect(await failing.spooledCount() == 1)

        let log = RequestLog()
        let recovered = PerformanceReportUploader(
            transport: { request in log.append(request); return 202 },
            spoolDirectory: spool,
            sessionTokenProvider: { nil }
        )
        await recovered.drain()
        #expect(await recovered.spooledCount() == 0)
        #expect(log.all.count == 1)
        #expect(log.all.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("服务端拒收（4xx）不再重发")
    func rejectedReportIsDropped() async {
        let spool = makeSpool()
        defer { try? FileManager.default.removeItem(at: spool) }
        let uploader = PerformanceReportUploader(
            transport: { _ in 400 },
            spoolDirectory: spool,
            sessionTokenProvider: { nil }
        )
        await uploader.submit(sampleReport())
        #expect(await uploader.spooledCount() == 0)
    }

    @Test("积压有上限，旧的先丢；关掉开关清空积压")
    func spoolIsCappedAndPurgeable() async {
        let spool = makeSpool()
        defer { try? FileManager.default.removeItem(at: spool) }
        let uploader = PerformanceReportUploader(
            transport: { _ in 503 },
            spoolDirectory: spool,
            sessionTokenProvider: { nil }
        )
        for _ in 0..<(PerformanceReportUploader.maxSpooledReports + 3) {
            var report = sampleReport()
            report.reportID = UUID().uuidString.lowercased()
            await uploader.submit(report)
        }
        #expect(await uploader.spooledCount() == PerformanceReportUploader.maxSpooledReports)
        await uploader.purge()
        #expect(await uploader.spooledCount() == 0)
    }
}

@Suite
struct PerformanceReportingPreferenceTests {
    /// 一次性 suite 前缀沿用已在 TestDefaultsHygiene 登记的 `willdeep-telemetry-`。
    private func makeDefaults() -> (UserDefaults, String) {
        _ = TestDefaultsHygiene.sweepStaleSuiteFiles
        let name = "willdeep-telemetry-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("性能报告默认开启，可单独关闭且不影响产品遥测开关")
    func defaultOnAndIndependent() {
        let (defaults, name) = makeDefaults()
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: name) }
        let preferences = TelemetryPreferences(defaults: defaults)
        #expect(preferences.isPerformanceReportingEnabled)

        preferences.isPerformanceReportingEnabled = false
        #expect(!preferences.isPerformanceReportingEnabled)
        #expect(preferences.isEnabled)

        preferences.isEnabled = false
        preferences.isPerformanceReportingEnabled = true
        #expect(preferences.isPerformanceReportingEnabled)
    }
}
