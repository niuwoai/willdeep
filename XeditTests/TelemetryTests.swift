//
//  TelemetryTests.swift
//  WillDeepTests
//
//  产品遥测的本地清洗、开关语义与队列行为。
//
//  重点不是「字段能不能传过去」，而是「不该出网的东西进不进得了队列」——
//  本地拦下来的，连传输过程都不存在。
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct TelemetryProtocolTests {
    @Test("自由文本进不了事件字段")
    func freeTextIsDropped() {
        var event = TelemetryEvent(
            eventName: .aiRequestFinished,
            installID: UUID().uuidString.lowercased(),
            appVersion: "1.290.0-rc1"
        )
        event.provider = "帮我把这个函数重构一下"
        event.requestedModel = "/Users/rocky/Sites/Xedit/AppState.swift"
        event.resolvedModel = "rm -rf /tmp/build && make"
        event.errorCode = "dial tcp 1.2.3.4:443: i/o timeout"
        event.feature = "用户在写一封邮件"
        event.surface = "sidebar panel"

        let clean = event.sanitized()
        #expect(clean.provider == nil)
        #expect(clean.requestedModel == nil)
        #expect(clean.resolvedModel == nil)
        #expect(clean.errorCode == nil)
        #expect(clean.feature == nil)
        #expect(clean.surface == nil)
    }

    @Test("正常的标识符原样保留")
    func wellFormedValuesSurvive() {
        var event = TelemetryEvent(
            eventName: .aiRequestFinished,
            installID: UUID().uuidString.lowercased(),
            appVersion: "1.290.0-rc1"
        )
        event.provider = "anthropic"
        event.requestedModel = "claude-opus-5"
        event.resolvedModel = "deepseek/deepseek-v3"
        event.errorCode = "http_429"
        event.feature = "agent_chat"
        event.surface = "sidebar"
        event.durationMs = 4210
        event.inputTokens = 18422
        event.outputTokens = 903

        let clean = event.sanitized()
        #expect(clean.provider == "anthropic")
        #expect(clean.requestedModel == "claude-opus-5")
        #expect(clean.resolvedModel == "deepseek/deepseek-v3")
        #expect(clean.errorCode == "http_429")
        #expect(clean.feature == "agent_chat")
        #expect(clean.surface == "sidebar")
        #expect(clean.durationMs == 4210)
        #expect(clean.inputTokens == 18422)
        #expect(clean.outputTokens == 903)
    }

    /// 事件维度名大量用下划线；字符集漏掉 `_` 会让这些值被静默丢弃，
    /// 服务端看到的曲线全是空。三端的字符集必须一致。
    @Test("下划线是合法标识符字符")
    func underscoreIsAllowed() {
        #expect(TelemetryProtocol.identifier("network_timeout") == "network_timeout")
        #expect(TelemetryProtocol.identifier("agent_chat") == "agent_chat")
        #expect(TelemetryProtocol.identifier("some_gateway") == "some_gateway")
        #expect(TelemetryProtocol.identifier("agent chat") == nil)
    }

    @Test("模型名允许斜杠但拒绝路径形状")
    func modelIdentifierRejectsPaths() {
        #expect(TelemetryProtocol.modelIdentifier("deepseek/deepseek-v3") == "deepseek/deepseek-v3")
        #expect(TelemetryProtocol.modelIdentifier("gpt-4.1") == "gpt-4.1")
        #expect(TelemetryProtocol.modelIdentifier("/Users/rocky/a.txt") == nil)
        #expect(TelemetryProtocol.modelIdentifier("a//b") == nil)
        #expect(TelemetryProtocol.modelIdentifier("../etc/passwd") == nil)
    }

    @Test("负数与越界计数被丢弃")
    func countersAreBounded() {
        var event = TelemetryEvent(
            eventName: .featureUsed,
            installID: UUID().uuidString.lowercased(),
            appVersion: "1.290.0-rc1"
        )
        event.durationMs = -5
        event.inputTokens = 1 << 30
        event.fallbackCount = 999

        let clean = event.sanitized()
        #expect(clean.durationMs == nil)
        #expect(clean.inputTokens == nil)
        #expect(clean.fallbackCount == nil)
    }

    @Test("上报请求体的字段名与服务端协议一致")
    func encodedKeysMatchServerContract() throws {
        let event = TelemetryEvent(
            eventID: "11111111-2222-4333-8444-555555555555",
            eventName: .aiRequestFinished,
            occurredAtMs: 1_756_089_600_000,
            installID: "3f1b2c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
            appVersion: "1.290.0-rc1",
            osVersion: "26",
            arch: "arm64",
            provider: "anthropic",
            requestedModel: "claude-opus-5",
            credentialSource: .someGateway,
            status: .succeeded,
            durationMs: 4210
        )
        let data = try JSONEncoder().encode(TelemetryUploadPayload(events: [event]))
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let events = try #require(json["events"] as? [[String: Any]])
        let first = try #require(events.first)

        #expect(first["event_id"] as? String == "11111111-2222-4333-8444-555555555555")
        #expect(first["event_name"] as? String == "ai_request_finished")
        #expect(first["install_id"] as? String == "3f1b2c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d")
        #expect(first["app_id"] as? String == "willdeep-mac")
        #expect(first["os_name"] as? String == "macos")
        #expect(first["app_version"] as? String == "1.290.0-rc1")
        #expect(first["credential_source"] as? String == "some_gateway")
        #expect(first["status"] as? String == "succeeded")
        #expect(first["duration_ms"] as? Int == 4210)
        #expect(first["schema_version"] as? Int == 1)
        // 没有任何字段能装下 prompt/路径/命令——协议里根本没有这些 key。
        #expect(first["prompt"] == nil)
        #expect(first["content"] == nil)
        #expect(first["path"] == nil)
    }

    @Test("凭据来源只按类型判定")
    @MainActor
    func credentialSourceClassification() {
        #expect(
            AgentTelemetry.credentialSource(
                providerID: AgentProviderPreset.someIMID,
                baseURL: "https://some.im/v1",
                hasAPIKey: true
            ) == .someGateway
        )
        #expect(
            AgentTelemetry.credentialSource(
                providerID: "ollama",
                baseURL: "http://127.0.0.1:11434/v1",
                hasAPIKey: false
            ) == .local
        )
        #expect(
            AgentTelemetry.credentialSource(
                providerID: "anthropic",
                baseURL: "https://api.anthropic.com",
                hasAPIKey: true
            ) == .userKey
        )
        #expect(
            AgentTelemetry.credentialSource(
                providerID: "anthropic",
                baseURL: "https://api.anthropic.com",
                hasAPIKey: false
            ) == .unknown
        )
    }

    /// 错误码必须是短枚举，绝不能把原始错误文案（里面常夹着路径、
    /// prompt 片段甚至凭据）当错误码传出去。
    @Test("错误被收敛成结构化错误码")
    @MainActor
    func errorCodesAreStructured() {
        #expect(AgentTelemetry.errorCode(for: URLError(.timedOut)) == "network_timeout")
        #expect(AgentTelemetry.errorCode(for: URLError(.notConnectedToInternet)) == "network_offline")
        #expect(AgentTelemetry.errorCode(for: URLError(.secureConnectionFailed)) == "tls_failure")
        #expect(AgentTelemetry.errorCode(for: CancellationError()) == "cancelled")
        #expect(AgentTelemetry.errorCode(for: AgentClientError.missingAPIKey) == "missing_credential")

        let code = AgentTelemetry.errorCode(for: NSError(
            domain: "com.example",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "/Users/rocky/secret.txt 打不开"]
        ))
        #expect(code == "unknown")
        #expect(!code.contains("/Users"))
    }
}

@Suite
struct TelemetryPreferencesTests {
    /// 一次性 suite 前缀已在 TestDefaultsHygiene 登记。
    private func makeDefaults() -> (UserDefaults, String) {
        _ = TestDefaultsHygiene.sweepStaleSuiteFiles
        let name = "willdeep-telemetry-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("默认开启")
    func enabledByDefault() {
        let (defaults, name) = makeDefaults()
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: name) }
        #expect(TelemetryPreferences(defaults: defaults).isEnabled)
    }

    @Test("安装 ID 稳定且是小写 UUID")
    func installIDIsStableLowercaseUUID() {
        let (defaults, name) = makeDefaults()
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: name) }
        let preferences = TelemetryPreferences(defaults: defaults)

        let first = preferences.installID()
        #expect(TelemetryPreferences.isValidInstallID(first))
        #expect(first == first.lowercased())
        #expect(preferences.installID() == first)
    }

    /// 关掉开关不换 ID：否则每关一次开关就凭空多出一个「新用户」，装机数虚高。
    @Test("关闭开关不会改变安装 ID")
    func togglingDoesNotRotateInstallID() {
        let (defaults, name) = makeDefaults()
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: name) }
        let preferences = TelemetryPreferences(defaults: defaults)

        let original = preferences.installID()
        preferences.isEnabled = false
        preferences.isEnabled = true
        #expect(preferences.installID() == original)
    }

    @Test("重置会换新 ID 并交回旧 ID")
    func resetReturnsPreviousID() {
        let (defaults, name) = makeDefaults()
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: name) }
        let preferences = TelemetryPreferences(defaults: defaults)

        let original = preferences.installID()
        let previous = preferences.resetInstallID()
        #expect(previous == original)
        #expect(preferences.installID() != original)
    }

    @Test("脏值被当作无效并重新生成")
    func corruptInstallIDIsReplaced() {
        let (defaults, name) = makeDefaults()
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: name) }
        defaults.set("not-a-uuid", forKey: TelemetryPreferences.installIDKey)
        let preferences = TelemetryPreferences(defaults: defaults)

        #expect(preferences.existingInstallID() == nil)
        #expect(TelemetryPreferences.isValidInstallID(preferences.installID()))
    }
}

@Suite
struct TelemetryReporterTests {
    private func makeReporter(
        enabled: Bool,
        queueFile: URL?
    ) -> (TelemetryReporter, UserDefaults, String) {
        _ = TestDefaultsHygiene.sweepStaleSuiteFiles
        let name = "willdeep-telemetry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(enabled, forKey: TelemetryPreferences.enabledKey)
        let reporter = TelemetryReporter(
            session: .shared,
            preferences: TelemetryPreferences(defaults: defaults),
            queueFileURL: queueFile,
            sessionTokenProvider: { nil }
        )
        return (reporter, defaults, name)
    }

    private func makeEvent() -> TelemetryEvent {
        TelemetryEvent(
            eventName: .featureUsed,
            installID: UUID().uuidString.lowercased(),
            appVersion: "1.290.0-rc1",
            feature: "agent_chat"
        )
    }

    @Test("关闭时事件直接丢弃，不入队")
    func disabledDropsEvents() async {
        let (reporter, defaults, name) = makeReporter(enabled: false, queueFile: nil)
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: name) }

        await reporter.record(makeEvent())
        #expect(await reporter.pendingCount() == 0)
    }

    @Test("开启时事件入队")
    func enabledQueuesEvents() async {
        let (reporter, defaults, name) = makeReporter(enabled: true, queueFile: nil)
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: name) }

        await reporter.record(makeEvent())
        await reporter.record(makeEvent())
        #expect(await reporter.pendingCount() == 2)
    }

    /// 遥测永远不该把内存或磁盘吃满：超过上限从最旧的开始丢。
    @Test("队列有上限")
    func queueIsBounded() async {
        let (reporter, defaults, name) = makeReporter(enabled: true, queueFile: nil)
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: name) }

        for _ in 0..<(TelemetryReporter.maxQueuedEvents + 25) {
            await reporter.record(makeEvent())
        }
        #expect(await reporter.pendingCount() == TelemetryReporter.maxQueuedEvents)
    }

    @Test("关闭采集会清空队列并删掉落盘文件")
    func disableAndPurgeClearsEverything() async throws {
        let queueFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-\(UUID().uuidString).json")
        let (reporter, defaults, name) = makeReporter(enabled: true, queueFile: queueFile)
        defer {
            TestDefaultsHygiene.cleanup(suite: defaults, named: name)
            try? FileManager.default.removeItem(at: queueFile)
        }

        await reporter.record(makeEvent())
        #expect(FileManager.default.fileExists(atPath: queueFile.path))

        await reporter.disableAndPurge()
        #expect(await reporter.pendingCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: queueFile.path))
    }

    @Test("未发出的事件落盘，下次启动继续发")
    func queueSurvivesRestart() async throws {
        let queueFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-\(UUID().uuidString).json")
        let (reporter, defaults, name) = makeReporter(enabled: true, queueFile: queueFile)
        defer {
            TestDefaultsHygiene.cleanup(suite: defaults, named: name)
            try? FileManager.default.removeItem(at: queueFile)
        }

        await reporter.record(makeEvent())
        await reporter.record(makeEvent())

        // 新实例复用同一个落盘文件，等价于重启后再拉起来。
        let revived = TelemetryReporter(
            session: .shared,
            preferences: TelemetryPreferences(defaults: defaults),
            queueFileURL: queueFile,
            sessionTokenProvider: { nil }
        )
        #expect(await revived.pendingCount() == 2)
    }

    @Test("入队前会先过一遍本地清洗")
    func recordSanitizesBeforeQueueing() async throws {
        let queueFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-\(UUID().uuidString).json")
        let (reporter, defaults, name) = makeReporter(enabled: true, queueFile: queueFile)
        defer {
            TestDefaultsHygiene.cleanup(suite: defaults, named: name)
            try? FileManager.default.removeItem(at: queueFile)
        }

        var dirty = makeEvent()
        dirty.feature = "用户写了一封邮件"
        await reporter.record(dirty)

        let data = try Data(contentsOf: queueFile)
        let stored = try JSONDecoder().decode([TelemetryEvent].self, from: data)
        #expect(stored.count == 1)
        #expect(stored.first?.feature == nil)
        // 落盘文件本身也不该出现那句中文。
        let raw = try #require(String(data: data, encoding: .utf8))
        #expect(!raw.contains("用户写了一封邮件"))
    }
}
