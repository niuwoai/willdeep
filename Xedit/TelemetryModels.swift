//
//  TelemetryModels.swift
//  WillDeep
//
//  产品遥测的事件模型。协议契约见 muchtoken 仓库 docs/client-telemetry.md。
//
//  这里只有枚举、短标识符和数值——没有任何字段能装下 prompt、回复正文、
//  文件路径、终端命令或原始错误。服务端也不接受：它的表里根本没有承载
//  自由文本的列，字段校验是「不合规就丢弃」。想加维度得三端一起改。
//

import Foundation

/// 上报事件名。服务端有同名白名单，名单外的事件会被整条拒收。
enum TelemetryEventName: String, Codable, Sendable, CaseIterable {
    /// App 启动一次。
    case appSessionStarted = "app_session_started"
    /// some.im 登录流程结束（成功或失败）。
    case someLoginFinished = "some_login_finished"
    /// 用户切换了默认模型或供应商。
    case modelSelected = "model_selected"
    /// 一次 AI 回合走完。
    case aiRequestFinished = "ai_request_finished"
    /// 某个功能被用了一次。
    case featureUsed = "feature_used"
    /// 出现一次结构化错误。
    case appError = "app_error"
}

/// 请求结局。
enum TelemetryStatus: String, Codable, Sendable {
    case succeeded
    case failed
    case cancelled
}

enum TelemetryCancellationReason: String, Codable, Sendable {
    case userStop = "user_stop"
    case queuedMessageTakeover = "queued_message_takeover"
    case runtimeReplaced = "runtime_replaced"
    case taskCancelled = "task_cancelled"
}

/// 凭据来源——只记类型，永远不记密钥本身。
enum TelemetryCredentialSource: String, Codable, Sendable {
    /// 走 some.im 网关（省心托管或 some.im 供应商）。
    case someGateway = "some_gateway"
    /// 用户自带的 API Key。
    case userKey = "user_key"
    /// 本地模型，不出网。
    case local
    case unknown
}

/// 通用结果枚举，给 `featureUsed` 之类不属于 AI 请求的事件用。
enum TelemetryOutcome: String, Codable, Sendable {
    case success
    case failure
    case cancelled
    case skipped
}

/// 一条待上报的事件。字段名与服务端 JSON 一一对应。
struct TelemetryEvent: Codable, Sendable, Equatable, Identifiable {
    var id: String { eventID }

    var eventID: String
    var eventName: TelemetryEventName
    var schemaVersion: Int
    var occurredAtMs: Int64

    var installID: String
    var appID: String
    var appVersion: String
    var osName: String
    var osVersion: String?
    var arch: String?
    var locale: String?

    var provider: String?
    var requestedModel: String?
    var resolvedModel: String?
    var credentialSource: TelemetryCredentialSource?
    var status: TelemetryStatus?
    var durationMs: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var fallbackCount: Int?
    var errorCode: String?
    var requestID: String?
    var cancellationReason: TelemetryCancellationReason?

    var feature: String?
    var surface: String?
    var outcome: TelemetryOutcome?
    var valueCount: Int?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case eventName = "event_name"
        case schemaVersion = "schema_version"
        case occurredAtMs = "occurred_at_ms"
        case installID = "install_id"
        case appID = "app_id"
        case appVersion = "app_version"
        case osName = "os_name"
        case osVersion = "os_version"
        case arch
        case locale
        case provider
        case requestedModel = "requested_model"
        case resolvedModel = "resolved_model"
        case credentialSource = "credential_source"
        case status
        case durationMs = "duration_ms"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case fallbackCount = "fallback_count"
        case errorCode = "error_code"
        case requestID = "request_id"
        case cancellationReason = "cancellation_reason"
        case feature
        case surface
        case outcome
        case valueCount = "value_count"
    }

    init(
        eventID: String = UUID().uuidString.lowercased(),
        eventName: TelemetryEventName,
        schemaVersion: Int = TelemetryProtocol.schemaVersion,
        occurredAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        installID: String,
        appID: String = TelemetryProtocol.appID,
        appVersion: String,
        osName: String = TelemetryProtocol.osName,
        osVersion: String? = nil,
        arch: String? = nil,
        locale: String? = nil,
        provider: String? = nil,
        requestedModel: String? = nil,
        resolvedModel: String? = nil,
        credentialSource: TelemetryCredentialSource? = nil,
        status: TelemetryStatus? = nil,
        durationMs: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        fallbackCount: Int? = nil,
        errorCode: String? = nil,
        requestID: String? = nil,
        cancellationReason: TelemetryCancellationReason? = nil,
        feature: String? = nil,
        surface: String? = nil,
        outcome: TelemetryOutcome? = nil,
        valueCount: Int? = nil
    ) {
        self.eventID = eventID
        self.eventName = eventName
        self.schemaVersion = schemaVersion
        self.occurredAtMs = occurredAtMs
        self.installID = installID
        self.appID = appID
        self.appVersion = appVersion
        self.osName = osName
        self.osVersion = osVersion
        self.arch = arch
        self.locale = locale
        self.provider = provider
        self.requestedModel = requestedModel
        self.resolvedModel = resolvedModel
        self.credentialSource = credentialSource
        self.status = status
        self.durationMs = durationMs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.fallbackCount = fallbackCount
        self.errorCode = errorCode
        self.requestID = requestID
        self.cancellationReason = cancellationReason
        self.feature = feature
        self.surface = surface
        self.outcome = outcome
        self.valueCount = valueCount
    }
}

/// 协议常量与本地清洗规则。
///
/// 客户端这一层的清洗不是为了替服务端把关（服务端有独立的白名单），
/// 而是为了让「不该出网的东西根本不进队列」——本地拦下来的，连传输过程
/// 都不存在。两边规则刻意保持一致。
enum TelemetryProtocol {
    static let schemaVersion = 2
    static let appID = "willdeep-mac"
    static let osName = "macos"

    /// 上报路径（拼在 `TelemetryEndpoint.origin` 之后）。
    static let eventsPath = "/api/v1/public/telemetry/events"
    static let forgetPath = "/api/v1/public/telemetry/forget"

    /// 标识符字符集：和服务端 `^[A-Za-z0-9._:+_-]{1,96}$` 对齐。
    /// 下划线在集合内（`network_timeout`、`agent_chat` 这类维度名都用它）；
    /// 空格、中文、引号、换行都不在，一句自然语言过不了这一关。
    private static let identifierAllowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:+_-")
    /// 模型名额外允许 `/`（OpenRouter 风格的 vendor/model）。
    private static let modelAllowed = identifierAllowed.union(["/"])

    /// 校验短标识符；不合规返回 nil（丢弃），不做「截断后凑合上报」。
    static func identifier(_ raw: String?, maxLength: Int = 96) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard value.count <= maxLength else { return nil }
        guard value.allSatisfy({ identifierAllowed.contains($0) }) else { return nil }
        return value
    }

    /// 模型名：允许 `/`，但拒绝路径形状，免得文件路径伪装成模型名。
    static func modelIdentifier(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard value.count <= 96 else { return nil }
        guard value.allSatisfy({ modelAllowed.contains($0) }) else { return nil }
        guard !value.hasPrefix("/"), !value.contains("//"), !value.contains("..") else { return nil }
        return value
    }

    /// 非负计数；越界或负数返回 nil。
    static func counter(_ raw: Int?, max: Int) -> Int? {
        guard let value = raw, value >= 0, value <= max else { return nil }
        return value
    }

    static let maxDurationMs = 24 * 60 * 60 * 1000
    static let maxTokens = 100_000_000

    /// 只取主版本号：`26.1.2` → `26`。精确到小版本对产品决策没有额外价值，
    /// 却让设备更容易被区分出来。
    static func majorOSVersion() -> String {
        String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    /// CPU 架构。编译期常量，不做运行时探测。
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// 界面语言，如 `zh-Hans`。取当前生效的本地化，不是系统区域。
    static func currentLocaleIdentifier() -> String? {
        identifier(Bundle.main.preferredLocalizations.first, maxLength: 16)
    }
}

/// 上报目的地。og.niuwoai.com 是 some.im 的上游源站。
enum TelemetryEndpoint {
    static let origin = "https://og.niuwoai.com"

    static var eventsURL: URL? { URL(string: origin + TelemetryProtocol.eventsPath) }
    static var forgetURL: URL? { URL(string: origin + TelemetryProtocol.forgetPath) }
}

extension TelemetryEvent {
    /// 把事件里的可疑字段就地清掉。构造事件时统一走一遍，
    /// 保证进队列的每条事件都已经符合协议。
    func sanitized() -> TelemetryEvent {
        var copy = self
        copy.provider = TelemetryProtocol.identifier(provider, maxLength: 48)
        copy.requestedModel = TelemetryProtocol.modelIdentifier(requestedModel)
        copy.resolvedModel = TelemetryProtocol.modelIdentifier(resolvedModel)
        copy.errorCode = TelemetryProtocol.identifier(errorCode, maxLength: 64)
        copy.requestID = TelemetryProtocol.identifier(requestID, maxLength: 64)
        copy.feature = TelemetryProtocol.identifier(feature, maxLength: 64)
        copy.surface = TelemetryProtocol.identifier(surface, maxLength: 32)
        copy.osVersion = TelemetryProtocol.identifier(osVersion, maxLength: 16)
        copy.arch = TelemetryProtocol.identifier(arch, maxLength: 16)
        copy.locale = TelemetryProtocol.identifier(locale, maxLength: 16)
        copy.appVersion = TelemetryProtocol.identifier(appVersion, maxLength: 32) ?? "unknown"
        copy.durationMs = TelemetryProtocol.counter(durationMs, max: TelemetryProtocol.maxDurationMs)
        copy.inputTokens = TelemetryProtocol.counter(inputTokens, max: TelemetryProtocol.maxTokens)
        copy.outputTokens = TelemetryProtocol.counter(outputTokens, max: TelemetryProtocol.maxTokens)
        copy.fallbackCount = TelemetryProtocol.counter(fallbackCount, max: 255)
        copy.valueCount = TelemetryProtocol.counter(valueCount, max: 1_000_000)
        return copy
    }
}
