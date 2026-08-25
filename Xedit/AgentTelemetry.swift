//
//  AgentTelemetry.swift
//  WillDeep
//
//  埋点门面：把公共字段（安装 ID、版本、系统、语言）补齐后交给
//  `TelemetryReporter`。业务代码只描述「发生了什么」，不关心传输。
//
//  功能名和错误码都是枚举，不是散落各处的字符串字面量——服务端按这些值
//  聚合，拼错一个字母就是一条查不出来的曲线。
//

import Foundation

/// 被统计的功能。加新功能就在这里加一个 case，别在调用点写裸字符串。
enum TelemetryFeature: String, Sendable {
    case agentChat = "agent_chat"
    case terminal
    case embeddedBrowser = "embedded_browser"
    case voiceInput = "voice_input"
    case desktopPet = "desktop_pet"
    case computerUse = "computer_use"
    case mobileGateway = "mobile_gateway"
    case skillInvoked = "skill_invoked"
    case mcpToolCall = "mcp_tool_call"
    case subagentDispatch = "subagent_dispatch"
    case scheduledTask = "scheduled_task"
    case contextCompression = "context_compression"
    case planUpdate = "plan_update"
    case imageGeneration = "image_generation"
    case dockMenu = "dock_menu"
    case settingsOpened = "settings_opened"
}

/// 触发面。同一个功能从哪儿被用起来的。
enum TelemetrySurface: String, Sendable {
    case sidebar
    case composer
    /// 模型/供应商选择器。它在 composer 与侧边栏都有入口，选择动作本身
    /// 汇到同一个函数，再细分只会得到一条分不清来源的曲线。
    case picker
    case dock
    case menu
    case shortcut
    case settings
    case notification
    case mobile
    case automatic
}

/// 结构化错误码。永远不要把原始错误信息当错误码传——里面经常夹着
/// 路径、prompt 片段甚至凭据。
enum TelemetryErrorCode: String, Sendable {
    case networkTimeout = "network_timeout"
    case networkOffline = "network_offline"
    case tlsFailure = "tls_failure"
    case cancelled
    case missingCredential = "missing_credential"
    case invalidResponse = "invalid_response"
    case emptyStream = "empty_stream"
    case contextOverflow = "context_overflow"
    case unsupportedProvider = "unsupported_provider"
    case unknown

    /// HTTP 状态码走 `http_<code>`，比枚举穷举更耐用。
    static func http(_ statusCode: Int) -> String { "http_\(statusCode)" }
}

/// 一个 Agent 回合的遥测累计值。
///
/// 回合内可能有多轮 provider 请求（工具调用循环），token 累加、降级次数累加；
/// `resolvedModel` 记最后实际执行的那个模型（省心托管路由或质量升档之后的）。
///
/// 做成 `@MainActor` 引用类型而不是 struct：流式回调在 `MainActor.run` 里回来，
/// 逃逸闭包改不了外层的局部 var，而回合结束时的 defer 又要读到累计后的值。
@MainActor
final class AgentTurnTelemetry {
    var providerID: String?
    var requestedModel: String?
    var resolvedModel: String?
    var credentialSource: TelemetryCredentialSource?
    var status: TelemetryStatus = .succeeded
    var errorCode: String?
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var fallbackCount: Int = 0
    let startedAt: Date

    /// 回合内没有任何一轮请求真正发出去（比如派发前就被门禁拦下），
    /// 这种回合不该混进「AI 请求成功率」。
    var didSendRequest = false

    init(
        providerID: String? = nil,
        requestedModel: String? = nil,
        resolvedModel: String? = nil,
        credentialSource: TelemetryCredentialSource? = nil,
        startedAt: Date = Date()
    ) {
        self.providerID = providerID
        self.requestedModel = requestedModel
        self.resolvedModel = resolvedModel
        self.credentialSource = credentialSource
        self.startedAt = startedAt
    }

    func addUsage(promptTokens: Int, completionTokens: Int) {
        didSendRequest = true
        inputTokens += max(0, promptTokens)
        outputTokens += max(0, completionTokens)
    }

    func noteRequestStarted() {
        didSendRequest = true
    }

    /// 实际执行模型与最初选的不同就算一次降级/改派。
    func noteResolvedModel(_ model: String?) {
        guard let model, !model.isEmpty, model != resolvedModel else { return }
        if resolvedModel != nil { fallbackCount += 1 }
        resolvedModel = model
    }

    func noteFailure(_ error: Error) {
        if error is CancellationError {
            status = .cancelled
        } else {
            status = .failed
        }
        errorCode = AgentTelemetry.errorCode(for: error)
    }

    func noteCancelled() {
        status = .cancelled
        errorCode = TelemetryErrorCode.cancelled.rawValue
    }

    var durationMs: Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
    }
}

/// 埋点入口。
@MainActor
enum AgentTelemetry {
    /// 允许测试替换掉真实 reporter。
    static var reporter: TelemetryReporter = .shared
    static var preferences = TelemetryPreferences()

    // MARK: - 事件

    static func recordAppSessionStarted() {
        record(makeEvent(.appSessionStarted))
    }

    static func recordLoginFinished(
        status: TelemetryStatus,
        surface: TelemetrySurface,
        errorCode: String? = nil
    ) {
        var event = makeEvent(.someLoginFinished)
        event.status = status
        event.surface = surface.rawValue
        event.errorCode = errorCode
        record(event)
    }

    static func recordModelSelected(
        providerID: String?,
        model: String?,
        surface: TelemetrySurface
    ) {
        var event = makeEvent(.modelSelected)
        event.provider = providerID
        event.requestedModel = model
        event.surface = surface.rawValue
        record(event)
    }

    /// 一个 Agent 回合结束。没真正发出请求的回合直接跳过，
    /// 免得把「被门禁拦下」也算进请求成功率。
    static func recordTurnFinished(_ summary: AgentTurnTelemetry) {
        guard summary.didSendRequest else { return }
        var event = makeEvent(.aiRequestFinished)
        event.provider = summary.providerID
        event.requestedModel = summary.requestedModel
        event.resolvedModel = summary.resolvedModel ?? summary.requestedModel
        event.credentialSource = summary.credentialSource
        event.status = summary.status
        event.errorCode = summary.errorCode
        event.durationMs = summary.durationMs
        event.inputTokens = summary.inputTokens > 0 ? summary.inputTokens : nil
        event.outputTokens = summary.outputTokens > 0 ? summary.outputTokens : nil
        event.fallbackCount = summary.fallbackCount
        record(event)
    }

    static func recordFeatureUsed(
        _ feature: TelemetryFeature,
        surface: TelemetrySurface? = nil,
        outcome: TelemetryOutcome? = nil,
        count: Int? = nil
    ) {
        var event = makeEvent(.featureUsed)
        event.feature = feature.rawValue
        event.surface = surface?.rawValue
        event.outcome = outcome
        event.valueCount = count
        record(event)
    }

    static func recordError(
        code: String,
        feature: TelemetryFeature? = nil,
        surface: TelemetrySurface? = nil
    ) {
        var event = makeEvent(.appError)
        event.errorCode = code
        event.feature = feature?.rawValue
        event.surface = surface?.rawValue
        record(event)
    }

    // MARK: - 生命周期

    /// App 退出前尽力把队列发出去。没发出去的下次启动继续发。
    static func flushBeforeTermination() {
        let reporter = self.reporter
        Task.detached(priority: .utility) {
            await reporter.flushNow()
        }
    }

    /// 用户在设置里切换开关。
    static func setEnabled(_ enabled: Bool) {
        preferences.isEnabled = enabled
        let reporter = self.reporter
        if enabled {
            recordAppSessionStarted()
            return
        }
        // 关闭时先请求服务端删掉已上报的数据，再清本地队列。
        let installID = preferences.existingInstallID()
        Task.detached(priority: .utility) {
            if let installID {
                _ = await reporter.forgetCollectedData(installID: installID)
            }
            await reporter.disableAndPurge()
        }
    }

    /// 重置匿名 ID：请求服务端删掉旧 ID 的数据，本地换新 ID。
    static func resetInstallIdentity() {
        let previous = preferences.resetInstallID()
        guard let previous else { return }
        let reporter = self.reporter
        Task.detached(priority: .utility) {
            _ = await reporter.forgetCollectedData(installID: previous)
        }
    }

    /// 删除已上报数据但保留开关状态。
    static func requestDataDeletion() {
        guard let installID = preferences.existingInstallID() else { return }
        let reporter = self.reporter
        Task.detached(priority: .utility) {
            _ = await reporter.forgetCollectedData(installID: installID)
        }
    }

    // MARK: - 判定

    /// 判断这次请求用的是哪类凭据。只区分类型，永远不碰 key 本身。
    static func credentialSource(providerID: String, baseURL: String, hasAPIKey: Bool) -> TelemetryCredentialSource {
        if providerID == AgentProviderPreset.someIMID { return .someGateway }
        let host = URL(string: baseURL)?.host?.lowercased() ?? ""
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") {
            return .local
        }
        return hasAPIKey ? .userKey : .unknown
    }

    /// 把一个 Error 收敛成结构化错误码。刻意不带原始错误文案——
    /// 那里面经常夹着路径、prompt 片段甚至凭据。
    static func errorCode(for error: Error) -> String {
        if error is CancellationError { return TelemetryErrorCode.cancelled.rawValue }
        if let clientError = error as? AgentClientError {
            switch clientError {
            case .missingAPIKey:
                return TelemetryErrorCode.missingCredential.rawValue
            case .invalidBaseURL, .invalidResponse:
                return TelemetryErrorCode.invalidResponse.rawValue
            case .serverStatus(let httpError), .imageDescriptionServerStatus(let httpError):
                return TelemetryErrorCode.http(httpError.statusCode)
            case .emptyStream:
                return TelemetryErrorCode.emptyStream.rawValue
            case .unsupportedProviderKind:
                return TelemetryErrorCode.unsupportedProvider.rawValue
            }
        }
        let urlError = error as? URLError
        switch urlError?.code {
        case .some(.timedOut):
            return TelemetryErrorCode.networkTimeout.rawValue
        case .some(.notConnectedToInternet), .some(.networkConnectionLost), .some(.cannotConnectToHost):
            return TelemetryErrorCode.networkOffline.rawValue
        case .some(.secureConnectionFailed), .some(.serverCertificateUntrusted):
            return TelemetryErrorCode.tlsFailure.rawValue
        case .some(.cancelled):
            return TelemetryErrorCode.cancelled.rawValue
        default:
            return TelemetryErrorCode.unknown.rawValue
        }
    }

    // MARK: - 组装

    static func makeEvent(_ name: TelemetryEventName) -> TelemetryEvent {
        TelemetryEvent(
            eventName: name,
            installID: preferences.installID(),
            appVersion: AgentNetworkSupport.appVersionHeaderValue,
            osVersion: TelemetryProtocol.majorOSVersion(),
            arch: TelemetryProtocol.architecture,
            locale: TelemetryProtocol.currentLocaleIdentifier()
        )
    }

    private static func record(_ event: TelemetryEvent) {
        guard preferences.isEnabled else { return }
        let reporter = self.reporter
        Task.detached(priority: .utility) {
            await reporter.record(event)
        }
    }
}
