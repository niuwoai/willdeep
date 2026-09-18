//
//  PerformanceWatchdog.swift
//  WillDeep
//
//  CPU 看门狗：本进程 CPU 连续 3 秒超过 30% 时，用 `/usr/bin/sample` 抓一份
//  全线程调用栈，脱敏后 gzip 上报到 some.im 源站，只在后台可见。
//
//  设计约束：
//    * 每秒读一次 `getrusage(RUSAGE_SELF)`，只做一次减法，不碰主线程；
//    * 触发后冷却 10 分钟、单日最多 30 份（与服务端限流一致），启动后前
//      20 秒不判（冷启动解码目录本来就忙，每次启动都报一份没有信息量）；
//    * 抓栈在后台起子进程，`sample` 自身的 CPU 不算在本进程头上；
//    * 报告先落盘再上传，失败的下次触发/启动时补发，最多积压 5 份；
//    * 开关在「设置 → 隐私 → 性能报告」，默认开启，与产品遥测开关相互独立。
//

import Foundation

// MARK: - 触发判定

/// 持续高负载判定。纯值类型，时钟由调用方传入，便于单测。
nonisolated struct CPUSustainedLoadDetector {
    struct Policy: Equatable {
        /// 单核百分比口径（`top` 同款，多核可超过 100）。
        var thresholdPercent: Double = 30
        /// 连续超阈值多久才算。
        var sustainedSeconds: TimeInterval = 3
        /// 两次触发的最短间隔。
        var cooldown: TimeInterval = 10 * 60
        /// 进程启动后多久内不判。
        var launchGrace: TimeInterval = 20
        /// 任意 24 小时窗口内最多触发几次（与服务端 429 阈值一致）。
        var maxTriggersPerDay: Int = 30
    }

    struct Trigger: Equatable {
        var sustainedSeconds: TimeInterval
        var peakPercent: Double
        var averagePercent: Double
    }

    static let maxRetainedSamples = 60

    let policy: Policy
    let launchedAt: Date
    private var streakStart: Date?
    private var streakSamples: [Double] = []
    private var lastTriggerAt: Date?
    private var recentTriggers: [Date] = []

    init(policy: Policy = Policy(), launchedAt: Date) {
        self.policy = policy
        self.launchedAt = launchedAt
    }

    /// 喂一个采样点：`percent` 是上一个采样间隔内的平均 CPU。
    /// 满足条件时返回触发信息，并立即进入冷却。
    mutating func ingest(percent: Double, at now: Date) -> Trigger? {
        guard percent > policy.thresholdPercent else {
            streakStart = nil
            streakSamples.removeAll()
            return nil
        }
        if streakStart == nil {
            // 这个采样点代表的是「过去一个间隔」，连续段从本次读数开始算起即可；
            // 判定用 >= sustainedSeconds，1 秒一采时第 4 个超阈值点触发（整 3 秒）。
            streakStart = now
        }
        streakSamples.append(percent)
        // 冷却 / 宽限 / 日上限挡住时连续段不清零（负载一直没退，冷却一过就该报），
        // 但读数只留最近一分钟，峰值与均值描述的是触发前的这一段。
        if streakSamples.count > Self.maxRetainedSamples {
            streakSamples.removeFirst(streakSamples.count - Self.maxRetainedSamples)
        }
        guard let streakStart, now.timeIntervalSince(streakStart) >= policy.sustainedSeconds else { return nil }
        guard now.timeIntervalSince(launchedAt) >= policy.launchGrace else { return nil }
        if let lastTriggerAt, now.timeIntervalSince(lastTriggerAt) < policy.cooldown { return nil }
        recentTriggers.removeAll { now.timeIntervalSince($0) >= 24 * 60 * 60 }
        guard recentTriggers.count < policy.maxTriggersPerDay else { return nil }

        let trigger = Trigger(
            sustainedSeconds: now.timeIntervalSince(streakStart),
            peakPercent: streakSamples.max() ?? percent,
            averagePercent: streakSamples.reduce(0, +) / Double(streakSamples.count)
        )
        lastTriggerAt = now
        recentTriggers.append(now)
        self.streakStart = nil
        streakSamples.removeAll()
        return trigger
    }
}

/// 两次 `getrusage` 读数之间的 CPU 百分比（单核口径）。
nonisolated struct ProcessCPUClock {
    private var lastCPUSeconds: Double?
    private var lastWall: Date?

    static func currentProcessCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ tv: timeval) -> Double { Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// 返回自上次调用以来的平均 CPU；首次调用只建立基线，返回 nil。
    mutating func percentSinceLastRead(cpuSeconds: Double, at now: Date) -> Double? {
        defer {
            lastCPUSeconds = cpuSeconds
            lastWall = now
        }
        guard let lastCPUSeconds, let lastWall else { return nil }
        let wall = now.timeIntervalSince(lastWall)
        guard wall > 0 else { return nil }
        return max(0, cpuSeconds - lastCPUSeconds) / wall * 100
    }
}

// MARK: - 报告

/// 与服务端 `POST /api/v1/public/telemetry/perf-reports` 的请求体一一对应。
nonisolated struct PerformanceReport: Codable, Equatable, Sendable {
    var reportID: String
    var installID: String
    var appVersion: String
    var build: String
    var osVersion: String
    var arch: String
    var locale: String?
    var capturedAt: String
    var activeSurface: String
    var thresholdPercent: Double
    var sustainedSeconds: Double
    var peakCPUPercent: Double
    var averageCPUPercent: Double
    var sampleDurationSeconds: Int
    var callStacksFormat: String
    var callStacks: String

    enum CodingKeys: String, CodingKey {
        case reportID = "report_id"
        case installID = "install_id"
        case appVersion = "app_version"
        case build
        case osVersion = "os_version"
        case arch
        case locale
        case capturedAt = "captured_at"
        case activeSurface = "active_surface"
        case thresholdPercent = "threshold_percent"
        case sustainedSeconds = "sustained_seconds"
        case peakCPUPercent = "peak_cpu_percent"
        case averageCPUPercent = "average_cpu_percent"
        case sampleDurationSeconds = "sample_duration_seconds"
        case callStacksFormat = "call_stacks_format"
        case callStacks = "call_stacks"
    }

    static let callStacksFormat = "macos-sample-v1"
    /// 服务端解压后上限 8 MiB；留出 JSON 其余字段的余量。
    static let maxCallStacksBytes = 6 * 1024 * 1024
}

nonisolated enum PerformanceReportRedaction {
    /// `sample` 的输出里有二进制与 dylib 的绝对路径，`/Users/<name>/...` 会带出
    /// 账户名。统一换成 `~`，调用栈与 Binary Images 的 UUID 原样保留（后台靠它
    /// 配 dSYM 符号化）。
    static func redact(_ text: String, homeDirectory: String = NSHomeDirectory()) -> String {
        var result = text
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        if !home.isEmpty, home != "/" {
            result = result.replacingOccurrences(of: home, with: "~")
        }
        // 兜底：别的账户目录（沙箱容器、其他用户的共享路径）也不带名字。
        result = result.replacingOccurrences(
            of: #"/Users/[^/\s]+"#,
            with: "/Users/_",
            options: .regularExpression
        )
        return result
    }

    /// 超长输出按 UTF-8 字节截断，并标注截断位置，不让一份报告被服务端 413 拒掉。
    static func truncated(_ text: String, maxBytes: Int = PerformanceReport.maxCallStacksBytes) -> String {
        let data = Data(text.utf8)
        guard data.count > maxBytes else { return text }
        let marker = "\n\n[truncated by WillDeep: \(data.count) bytes total]\n"
        var keep = max(0, maxBytes - marker.utf8.count)
        // 退到 UTF-8 字符边界：切在多字节字符中间会被解码成替换字符，反而变长。
        while keep > 0, keep < data.count, data[data.startIndex + keep] & 0xC0 == 0x80 {
            keep -= 1
        }
        let prefix = String(decoding: data.prefix(keep), as: UTF8.self)
        return prefix + marker
    }
}

// MARK: - gzip

nonisolated enum PerformanceReportGzip {
    /// RFC 1952 gzip：Foundation 的 `.zlib` 产出的是裸 DEFLATE，这里补上头尾。
    static func gzip(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        output.append(deflated)
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
        return output
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - 抓栈

nonisolated enum PerformanceStackCapture {
    static let sampleToolPath = "/usr/bin/sample"
    static let sampleDurationSeconds = 2
    static let symbolicationAllowance: TimeInterval = 120

    /// 对本进程跑一次 `sample`，返回原始文本。阻塞调用方所在线程，只能在后台用。
    static func captureCurrentProcess(durationSeconds: Int = sampleDurationSeconds) -> String? {
        guard FileManager.default.isExecutableFile(atPath: sampleToolPath) else { return nil }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-perf-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sampleToolPath)
        process.arguments = [
            String(ProcessInfo.processInfo.processIdentifier),
            String(durationSeconds),
            "-mayDie",
            "-file", outputURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // `sample` 采完还要做符号化：实测 Debug 构建 2 秒采样总耗时 72 秒（符号化
        // 吃掉 10 秒 CPU，在 `sample` 进程里，不算本进程）。给足余量但不无限等。
        let deadline = Date().addingTimeInterval(TimeInterval(durationSeconds) + Self.symbolicationAllowance)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0,
              let text = try? String(contentsOf: outputURL, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - 上传与落盘

/// 落盘 + 上传。actor 隔离：触发来自看门狗的后台队列。
actor PerformanceReportUploader {
    static let shared = PerformanceReportUploader()
    static let path = "/api/v1/public/telemetry/perf-reports"
    /// 积压上限：上不去的报告最多留这么多份，旧的先丢。
    static let maxSpooledReports = 5

    /// 发出请求、返回 HTTP 状态码；抛错视为网络失败。测试注入假的。
    typealias Transport = @Sendable (URLRequest) async throws -> Int

    private let transport: Transport
    private let spoolDirectory: URL?
    private let sessionTokenProvider: @Sendable () async -> String?

    init(
        transport: @escaping Transport = PerformanceReportUploader.urlSessionTransport(AgentNetworkSupport.defaultSession()),
        spoolDirectory: URL? = PerformanceReportUploader.defaultSpoolDirectory(),
        sessionTokenProvider: @escaping @Sendable () async -> String? = TelemetryReporter.defaultSessionTokenProvider
    ) {
        self.transport = transport
        self.spoolDirectory = spoolDirectory
        self.sessionTokenProvider = sessionTokenProvider
    }

    static func urlSessionTransport(_ session: URLSession) -> Transport {
        { request in
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
    }

    static func defaultSpoolDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("WillDeep", isDirectory: true)
            .appendingPathComponent("perf-reports", isDirectory: true)
    }

    static var endpointURL: URL? { URL(string: TelemetryEndpoint.origin + path) }

    /// 编码、压缩、落盘，然后把积压的全部尝试发一遍。
    func submit(_ report: PerformanceReport) async {
        guard let body = Self.encodedBody(report) else { return }
        spool(body, reportID: report.reportID)
        await drain()
    }

    /// 发送积压（启动时也调用一次）。
    func drain() async {
        for url in spooledFiles() {
            guard let body = try? Data(contentsOf: url) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            switch await send(body) {
            case .delivered, .rejected:
                try? FileManager.default.removeItem(at: url)
            case .retryLater:
                return
            }
        }
    }

    /// 关掉开关：清空积压。
    func purge() {
        for url in spooledFiles() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func spooledCount() -> Int { spooledFiles().count }

    static func encodedBody(_ report: PerformanceReport) -> Data? {
        guard let json = try? JSONEncoder().encode(report) else { return nil }
        return PerformanceReportGzip.gzip(json)
    }

    enum SendOutcome: Equatable {
        case delivered
        /// 4xx（除 429）：协议问题，重发也不会好，丢掉。
        case rejected
        case retryLater
    }

    static func outcome(forStatusCode status: Int) -> SendOutcome {
        if (200..<300).contains(status) { return .delivered }
        if (400..<500).contains(status), status != 429 { return .rejected }
        return .retryLater
    }

    private func send(_ gzippedBody: Data) async -> SendOutcome {
        guard let url = Self.endpointURL else { return .rejected }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.setValue(AgentNetworkSupport.userAgentHeaderValue, forHTTPHeaderField: "User-Agent")
        if let token = await sessionTokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = gzippedBody
        do {
            return Self.outcome(forStatusCode: try await transport(request))
        } catch {
            return .retryLater
        }
    }

    private func spool(_ body: Data, reportID: String) {
        guard let spoolDirectory else { return }
        try? FileManager.default.createDirectory(at: spoolDirectory, withIntermediateDirectories: true)
        let url = spoolDirectory.appendingPathComponent("\(reportID).json.gz")
        try? body.write(to: url, options: .atomic)
        let files = spooledFiles()
        if files.count > Self.maxSpooledReports {
            for stale in files.prefix(files.count - Self.maxSpooledReports) {
                try? FileManager.default.removeItem(at: stale)
            }
        }
    }

    /// 最旧的在前。
    private func spooledFiles() -> [URL] {
        guard let spoolDirectory,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: spoolDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return entries
            .filter { $0.lastPathComponent.hasSuffix(".json.gz") }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs < rhs
            }
    }
}

// MARK: - 看门狗

/// 全局单例。只在正式运行时启动（XCTest 下不启）。
nonisolated final class PerformanceWatchdog: @unchecked Sendable {
    static let shared = PerformanceWatchdog()
    static let sampleInterval: TimeInterval = 1

    /// 当前所在界面的短标识（如 `agent.new_session`），由主窗口的 AppState 注册。
    /// 只在触发时于主线程读一次。
    @MainActor static var surfaceProvider: (@MainActor () -> String)?

    private let queue = DispatchQueue(label: "com.willdeep.performance-watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var clock = ProcessCPUClock()
    private var detector = CPUSustainedLoadDetector(launchedAt: Date())
    private var isCapturing = false
    private let preferences = TelemetryPreferences()

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            detector = CPUSustainedLoadDetector(launchedAt: Date())
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(
                deadline: .now() + Self.sampleInterval,
                repeating: Self.sampleInterval,
                leeway: .milliseconds(100)
            )
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume()
            timer = source
        }
        Task.detached(priority: .background) {
            guard TelemetryPreferences().isPerformanceReportingEnabled else { return }
            await PerformanceReportUploader.shared.drain()
        }
    }

    /// 设置页切换开关时调用。关闭即清空积压。
    static func setEnabled(_ enabled: Bool) {
        TelemetryPreferences().isPerformanceReportingEnabled = enabled
        guard !enabled else { return }
        Task.detached(priority: .utility) {
            await PerformanceReportUploader.shared.purge()
        }
    }

    private func tick() {
        let now = Date()
        guard let percent = clock.percentSinceLastRead(
            cpuSeconds: ProcessCPUClock.currentProcessCPUSeconds(),
            at: now
        ) else { return }
        // 抓栈期间 `sample` 会暂停/恢复本进程线程，这段读数不参与判定。
        guard !isCapturing, preferences.isPerformanceReportingEnabled else { return }
        guard let trigger = detector.ingest(percent: percent, at: now) else { return }
        isCapturing = true
        Task.detached(priority: .utility) { [weak self] in
            await self?.captureAndSubmit(trigger)
        }
    }

    private func finishCapture() {
        queue.async { [self] in
            isCapturing = false
            // 丢掉抓栈期间的基线，避免把 `sample` 挂起时段算成一次读数。
            clock = ProcessCPUClock()
        }
    }

    private func captureAndSubmit(_ trigger: CPUSustainedLoadDetector.Trigger) async {
        defer { finishCapture() }
        // 界面标识与协议字段都在主线程读一次；主线程再忙，这里也只是排个队。
        let metadata = await MainActor.run {
            (
                surface: TelemetryProtocol.identifier(Self.surfaceProvider?() ?? "unknown", maxLength: 64) ?? "unknown",
                appVersion: AgentNetworkSupport.appVersionHeaderValue,
                osVersion: TelemetryProtocol.majorOSVersion(),
                arch: TelemetryProtocol.architecture,
                locale: TelemetryProtocol.currentLocaleIdentifier()
            )
        }
        guard let raw = PerformanceStackCapture.captureCurrentProcess() else { return }
        let stacks = PerformanceReportRedaction.truncated(PerformanceReportRedaction.redact(raw))
        let report = PerformanceReport(
            reportID: UUID().uuidString.lowercased(),
            installID: preferences.installID(),
            appVersion: metadata.appVersion,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            osVersion: metadata.osVersion,
            arch: metadata.arch,
            locale: metadata.locale,
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            activeSurface: metadata.surface,
            thresholdPercent: CPUSustainedLoadDetector.Policy().thresholdPercent,
            sustainedSeconds: (trigger.sustainedSeconds * 10).rounded() / 10,
            peakCPUPercent: (trigger.peakPercent * 10).rounded() / 10,
            averageCPUPercent: (trigger.averagePercent * 10).rounded() / 10,
            sampleDurationSeconds: PerformanceStackCapture.sampleDurationSeconds,
            callStacksFormat: PerformanceReport.callStacksFormat,
            callStacks: stacks
        )
        guard preferences.isPerformanceReportingEnabled else { return }
        await PerformanceReportUploader.shared.submit(report)
    }
}
