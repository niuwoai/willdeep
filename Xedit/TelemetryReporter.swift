//
//  TelemetryReporter.swift
//  WillDeep
//
//  遥测的队列与上报。
//
//  行为约定：
//    * 攒够 20 条或过了 30 秒才发一次，不给每个事件单开一个请求；
//    * 队列上限 500 条，满了丢最旧的——遥测永远不该把内存或磁盘吃满；
//    * 队列落盘，App 退出后未发出的事件下次启动继续发；
//    * 上传失败保留队列并退避重试，`event_id` 在服务端是唯一键，重发幂等；
//    * 关掉开关立即停止采集、清空队列、删掉落盘文件。
//

import Foundation

/// 队列与上报。actor 隔离：埋点可能来自任意线程。
actor TelemetryReporter {
    static let shared = TelemetryReporter()

    /// 攒够这么多条就立刻发一批。
    static let batchThreshold = 20
    /// 没攒够也最多等这么久。
    static let flushInterval: TimeInterval = 30
    /// 队列上限；超了从头部丢弃。
    static let maxQueuedEvents = 500
    /// 单次请求最多带多少条（与服务端上限一致）。
    static let maxEventsPerRequest = 100
    /// 连续失败后的退避上限。
    static let maxBackoff: TimeInterval = 15 * 60

    private var queue: [TelemetryEvent] = []
    private var consecutiveFailures = 0
    private var nextAttemptAfter: Date?
    private var flushTask: Task<Void, Never>?
    private var isFlushing = false
    private var didLoadPersistedQueue = false

    private let session: URLSession
    private let preferences: TelemetryPreferences
    private let queueFileURL: URL?
    /// some.im 会话 token 的来源。登录时带上它，服务端才能算出 account_key；
    /// 拿不到就匿名上报。这里做成闭包，测试不必碰 Keychain。
    private let sessionTokenProvider: @Sendable () async -> String?

    init(
        session: URLSession = AgentNetworkSupport.defaultSession(),
        preferences: TelemetryPreferences = TelemetryPreferences(),
        queueFileURL: URL? = TelemetryReporter.defaultQueueFileURL(),
        sessionTokenProvider: @escaping @Sendable () async -> String? = TelemetryReporter.defaultSessionTokenProvider
    ) {
        self.session = session
        self.preferences = preferences
        self.queueFileURL = queueFileURL
        self.sessionTokenProvider = sessionTokenProvider
    }

    static func defaultQueueFileURL() -> URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let base else { return nil }
        return base.appendingPathComponent("WillDeep", isDirectory: true)
            .appendingPathComponent("telemetry-queue.json", isDirectory: false)
    }

    /// 默认 token 来源：some.im 的 customer session token。
    /// 只把它放进 `Authorization` 头，绝不进事件体。
    static let defaultSessionTokenProvider: @Sendable () async -> String? = {
        await MainActor.run {
            let token = SomeIMIntegrationStore.loadSessionToken()
            return token.isEmpty ? nil : token
        }
    }

    // MARK: - 入队

    /// 记录一个事件。开关关闭时直接丢弃——不入队、不落盘。
    func record(_ event: TelemetryEvent) {
        guard preferences.isEnabled else { return }
        loadPersistedQueueIfNeeded()
        queue.append(event.sanitized())
        if queue.count > Self.maxQueuedEvents {
            queue.removeFirst(queue.count - Self.maxQueuedEvents)
        }
        persistQueue()
        scheduleFlush()
    }

    /// 队列里现有的事件数（测试与诊断用）。
    func pendingCount() -> Int {
        loadPersistedQueueIfNeeded()
        return queue.count
    }

    // MARK: - 开关

    /// 关闭采集：停止定时器、清空队列、删掉落盘文件。
    /// 已经发出去的数据由 `forgetCollectedData()` 负责，两者是不同的动作。
    func disableAndPurge() {
        flushTask?.cancel()
        flushTask = nil
        queue.removeAll()
        consecutiveFailures = 0
        nextAttemptAfter = nil
        if let queueFileURL {
            try? FileManager.default.removeItem(at: queueFileURL)
        }
    }

    /// 请求服务端删除这个安装已上报的全部数据。
    /// 用户点「删除我的遥测数据」或重置匿名 ID 时调用。
    @discardableResult
    func forgetCollectedData(installID: String) async -> Bool {
        guard let url = TelemetryEndpoint.forgetURL else { return false }
        guard let body = try? JSONSerialization.data(
            withJSONObject: ["install_id": installID], options: [.sortedKeys]
        ) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AgentNetworkSupport.userAgentHeaderValue, forHTTPHeaderField: "User-Agent")
        if let token = await sessionTokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    // MARK: - 发送

    /// 立刻发送队列里的事件（App 退出前、设置页手动触发时用）。
    func flushNow() async {
        await flush()
    }

    private func scheduleFlush() {
        if queue.count >= Self.batchThreshold, flushTask == nil {
            flushTask = Task { [weak self] in
                await self?.flush()
                await self?.clearFlushTask()
            }
            return
        }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.flushInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.flush()
            await self?.clearFlushTask()
        }
    }

    private func clearFlushTask() {
        flushTask = nil
        // 退避期结束后队列还有货就再排一次，否则事件会一直躺到下一次埋点。
        if !queue.isEmpty {
            scheduleFlush()
        }
    }

    private func flush() async {
        guard preferences.isEnabled else {
            queue.removeAll()
            return
        }
        guard !isFlushing else { return }
        loadPersistedQueueIfNeeded()
        guard !queue.isEmpty else { return }
        if let nextAttemptAfter, nextAttemptAfter > Date() { return }

        isFlushing = true
        defer { isFlushing = false }

        let batch = Array(queue.prefix(Self.maxEventsPerRequest))
        let succeeded = await send(batch)
        if succeeded {
            queue.removeFirst(min(batch.count, queue.count))
            consecutiveFailures = 0
            nextAttemptAfter = nil
            persistQueue()
            return
        }
        // 失败不丢事件：event_id 是服务端唯一键，重发不会产生重复行。
        consecutiveFailures += 1
        let backoff = min(Self.maxBackoff, pow(2, Double(min(consecutiveFailures, 10))) * 5)
        nextAttemptAfter = Date().addingTimeInterval(backoff)
        persistQueue()
    }

    private func send(_ events: [TelemetryEvent]) async -> Bool {
        guard !events.isEmpty, let url = TelemetryEndpoint.eventsURL else { return false }
        let payload = TelemetryUploadPayload(events: events)
        guard let body = try? JSONEncoder().encode(payload) else {
            // 编不出来的事件重发多少次都编不出来，直接当发送成功丢掉，
            // 免得一条坏事件把整个队列卡死。
            return true
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AgentNetworkSupport.userAgentHeaderValue, forHTTPHeaderField: "User-Agent")
        if let token = await sessionTokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if (200..<300).contains(http.statusCode) { return true }
            // 4xx（除 429）是协议问题，重发也不会变好；丢掉这批免得永久卡队列。
            if (400..<500).contains(http.statusCode), http.statusCode != 429 { return true }
            return false
        } catch {
            return false
        }
    }

    // MARK: - 落盘

    private func loadPersistedQueueIfNeeded() {
        guard !didLoadPersistedQueue else { return }
        didLoadPersistedQueue = true
        guard let queueFileURL, let data = try? Data(contentsOf: queueFileURL) else { return }
        guard let stored = try? JSONDecoder().decode([TelemetryEvent].self, from: data) else {
            try? FileManager.default.removeItem(at: queueFileURL)
            return
        }
        queue = Array(stored.suffix(Self.maxQueuedEvents)) + queue
    }

    private func persistQueue() {
        guard let queueFileURL else { return }
        if queue.isEmpty {
            try? FileManager.default.removeItem(at: queueFileURL)
            return
        }
        let directory = queueFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: queueFileURL, options: .atomic)
    }
}

/// 上报请求体。
struct TelemetryUploadPayload: Codable, Sendable {
    var events: [TelemetryEvent]
}
