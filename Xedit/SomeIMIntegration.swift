//
//  SomeIMIntegration.swift
//  WillDeep
//
//  Settings, model discovery, and generation helpers for Rocky's
//  some.im relay. The API key stays in Keychain; non-secret routing
//  preferences live in UserDefaults.
//

import Foundation
import AppKit
import os
import Security
import SwiftUI
import SomeIMSharedSession

enum SomeIMGenerationKind: String, Codable, CaseIterable, Identifiable {
    case image
    case video
    case text
    case unknown

    var id: String { rawValue }
}

enum SomeIMRelayRegion: String, CaseIterable, Identifiable {
    case china
    case international
    case custom

    static let chinaBaseURL = "https://api.niuwoai.com/v1"
    static let internationalBaseURL = "https://some.im/v1"

    var id: String { rawValue }

    var baseURL: String? {
        switch self {
        case .china:
            return Self.chinaBaseURL
        case .international:
            return Self.internationalBaseURL
        case .custom:
            return nil
        }
    }

    static func resolved(for baseURL: String) -> SomeIMRelayRegion {
        switch baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case chinaBaseURL.lowercased():
            return .china
        case internationalBaseURL.lowercased(), "":
            return .international
        default:
            return .custom
        }
    }

    static func automaticBaseURL(for countryCode: String?) -> String {
        countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "CN"
            ? chinaBaseURL
            : internationalBaseURL
    }
}

struct SomeIMModel: Identifiable, Codable, Equatable {
    var id: String { model }
    var model: String
    var kinds: [SomeIMGenerationKind]
    var isHot: Bool = false
    var isNew: Bool = false
    /// Context window from some.im's pricing catalog, when it reports one.
    var contextWindowTokens: Int?

    var supportsImageGeneration: Bool { kinds.contains(.image) || model.localizedCaseInsensitiveContains("image") }
    var supportsVideoGeneration: Bool { kinds.contains(.video) || model.localizedCaseInsensitiveContains("video") }
    var agentDiscovery: AgentModelDiscovery {
        AgentModelDiscovery(
            id: model,
            isHot: isHot,
            isNew: isNew,
            contextWindowTokens: contextWindowTokens
        )
    }
}



struct SomeIMIntegrationSettings: Codable, Equatable {
    static let defaultBaseURL = SomeIMRelayRegion.internationalBaseURL
    static let defaultImageModel = "gpt-image-2"
    static let defaultVideoModel = "seedance-2.0"
    /// Authenticated some.im sessions begin on the relay's automatic Flash
    /// route. It remains the low tier and can escalate through the managed
    /// model family, while historical sessions keep their persisted model.
    static let defaultTextModel = SomeIMManagedModel.autoFlash
    static let defaultVisionModel = "qwen3-vl-plus"

    var enabled: Bool
    var baseURL: String
    var preferredImageModel: String
    var preferredImageModels: [String]
    var preferredVideoModel: String
    var preferredVideoModels: [String]

    init(
        enabled: Bool = false,
        baseURL: String = defaultBaseURL,
        preferredImageModel: String = defaultImageModel,
        preferredImageModels: [String] = [defaultImageModel],
        preferredVideoModel: String = defaultVideoModel,
        preferredVideoModels: [String] = [defaultVideoModel]
    ) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.preferredImageModel = preferredImageModel
        self.preferredImageModels = Self.cleanList(preferredImageModels, ensuringFirst: preferredImageModel)
        self.preferredVideoModel = preferredVideoModel
        self.preferredVideoModels = Self.cleanList(preferredVideoModels, ensuringFirst: preferredVideoModel)
    }

    var normalized: SomeIMIntegrationSettings {
        SomeIMIntegrationSettings(
            enabled: enabled,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? Self.defaultBaseURL,
            preferredImageModel: preferredImageModel.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? Self.defaultImageModel,
            preferredImageModels: preferredImageModels,
            preferredVideoModel: preferredVideoModel.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? Self.defaultVideoModel,
            preferredVideoModels: preferredVideoModels
        )
    }

    private static func cleanList(_ list: [String], ensuringFirst primary: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let head = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !head.isEmpty, seen.insert(head).inserted {
            result.append(head)
        }
        for item in list {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}

struct SomeIMAccount: Codable, Equatable {
    var email: String
    var nickname: String?
    var avatarURL: String?
    var tenantID: String?
    var balanceUSD: String
    var credits: String
    var creditsPerUSD: Int
    var defaultModel: String
    var lastUpdatedAt: Date
    /// 最近一次成功获取 some.im 客户资料（昵称、头像）的时间。
    /// 与余额更新时间分离，避免模型响应里的余额快照阻止资料补全。
    var profileUpdatedAt: Date? = nil
    /// 服务端余额快照的账本/预占变更时间（Unix 微秒）。只用于余额合并排序，
    /// 与本机抓取时间 `lastUpdatedAt` 分离，避免客户端时钟偏差造成新旧误判。
    var creditsUpdatedAtMicros: Int64? = nil

    nonisolated var displayCredits: String {
        guard let value = Int64(credits) else { return credits }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    nonisolated var displayName: String {
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? email : trimmed
    }

    nonisolated var compactDisplayCredits: String {
        Self.compactCredits(credits) ?? displayCredits
    }

    nonisolated var isLowOnCredits: Bool {
        guard let value = Int64(credits) else { return false }
        return value < SomeIMCreditsSnapshot.lowCreditsThreshold
    }

    nonisolated static func compactCredits(_ credits: String) -> String? {
        guard let value = Double(credits.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let magnitude = abs(value)
        let unit: (divisor: Double, suffix: String)?
        if magnitude >= 1_000_000_000 {
            unit = (1_000_000_000, "B")
        } else if magnitude >= 1_000_000 {
            unit = (1_000_000, "M")
        } else {
            return nil
        }
        guard let unit else { return nil }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let scaled = value / unit.divisor
        let rendered = formatter.string(from: NSNumber(value: scaled)) ?? String(format: "%.2f", scaled)
        return rendered + unit.suffix
    }

    /// Carry the display profile (nickname, avatar, email) forward from the
    /// account this one replaces.
    ///
    /// Login responses carry balance but never nickname or avatar — the
    /// server only returns those from `/customer/me`. Saving a login result
    /// verbatim therefore blanked whatever profile the app had already
    /// fetched, which is why an account could end up showing credits with no
    /// name or picture.
    ///
    /// Switching accounts must NOT inherit: a different email means a
    /// different person, and showing the previous user's avatar would be
    /// worse than showing none.
    nonisolated func preservingProfile(from previous: SomeIMAccount?) -> SomeIMAccount {
        guard let previous else { return self }
        let incomingEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousEmail = previous.email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !incomingEmail.isEmpty,
           !previousEmail.isEmpty,
           incomingEmail.caseInsensitiveCompare(previousEmail) != .orderedSame {
            return self
        }

        var merged = self
        if merged.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged.email = previous.email
        }
        if merged.nickname?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == nil {
            merged.nickname = previous.nickname
        }
        if merged.avatarURL?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == nil {
            merged.avatarURL = previous.avatarURL
        }
        if merged.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty == nil {
            merged.tenantID = previous.tenantID
        }
        if merged.profileUpdatedAt == nil {
            merged.profileUpdatedAt = previous.profileUpdatedAt
        }
        return merged
    }
}

struct SomeIMAuthenticationSnapshot: Equatable {
    let apiKey: String
    let account: SomeIMAccount?

    nonisolated init(cachedAccount: SomeIMAccount?, apiKey: String) {
        let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = normalizedAPIKey
        account = normalizedAPIKey.isEmpty ? nil : cachedAccount
    }

    nonisolated var isAuthenticated: Bool {
        !apiKey.isEmpty
    }
}

struct SomeIMCreditsSnapshot: Equatable, Sendable {
    nonisolated static let remainingHeader = "X-SomeIM-Credits-Remaining"
    nonisolated static let updatedAtHeader = "X-SomeIM-Credits-Updated-At"
    nonisolated static let creditsPerUSDHeader = "X-SomeIM-Credits-Per-USD"
    nonisolated static let sourceHeader = "X-SomeIM-Credits-Source"
    nonisolated static let lowCreditsThreshold: Int64 = 10_000_000

    let credits: String
    let updatedAtMicros: Int64
    let creditsPerUSD: Int
    let source: String?

    nonisolated static func responseSnapshot(from response: HTTPURLResponse) -> SomeIMCreditsSnapshot? {
        guard let rawCredits = response.value(forHTTPHeaderField: remainingHeader)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let creditsValue = Int64(rawCredits), creditsValue >= 0,
              let rawUpdatedAt = response.value(forHTTPHeaderField: updatedAtHeader)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let updatedAtMicros = Int64(rawUpdatedAt), updatedAtMicros > 0 else {
            return nil
        }
        let rawRate = response.value(forHTTPHeaderField: creditsPerUSDHeader)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rate = rawRate.flatMap(Int.init) ?? 100_000
        guard rate > 0 else { return nil }
        let rawSource = response.value(forHTTPHeaderField: sourceHeader)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = rawSource?.isEmpty == false ? rawSource : nil
        return SomeIMCreditsSnapshot(
            credits: String(creditsValue),
            updatedAtMicros: updatedAtMicros,
            creditsPerUSD: rate,
            source: source
        )
    }

    nonisolated func applying(to account: SomeIMAccount) -> SomeIMAccount? {
        if let currentVersion = account.creditsUpdatedAtMicros,
           updatedAtMicros <= currentVersion {
            return nil
        }
        var updated = account
        updated.credits = credits
        updated.creditsPerUSD = creditsPerUSD
        if let creditsValue = Decimal(string: credits, locale: Locale(identifier: "en_US_POSIX")) {
            updated.balanceUSD = NSDecimalNumber(decimal: creditsValue / Decimal(creditsPerUSD)).stringValue
        }
        updated.creditsUpdatedAtMicros = updatedAtMicros
        updated.lastUpdatedAt = Date()
        return updated
    }
}

enum SomeIMCreditsResponseObserver {
    nonisolated private static let someIMProviderID = "some-im"

    nonisolated static func capture(_ response: HTTPURLResponse, providerID: String) {
        guard providerID == someIMProviderID,
              let snapshot = SomeIMCreditsSnapshot.responseSnapshot(from: response) else {
            return
        }
        Task { @MainActor in
            SomeIMIntegrationStore.applyCreditsSnapshot(snapshot)
        }
    }
}

struct SomeIMBrowserLoginRequest: Equatable {
    var code: String
    var pairToken: String
    var url: URL
    var createdAt: Date
}

struct SomeIMBrowserLoginStatus: Equatable {
    enum State: String {
        case pending
        case connected
        case credentialSaveFailed
        case expired
        case unknown
    }

    var state: State
    var account: SomeIMAccount?
}

private extension SomeIMBrowserLoginStatus.State {
    static func fromServerValue(_ value: String) -> Self {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "connected", "success", "succeeded", "complete", "completed", "authorized", "authenticated", "logged_in", "logged-in":
            return .connected
        case "expired", "cancelled", "canceled", "timeout", "timed_out", "timed-out":
            return .expired
        case "pending", "waiting", "processing", "authorizing", "in_progress", "in-progress":
            return .pending
        default:
            return .unknown
        }
    }
}

struct SomeIMGeneratedImage: Equatable, Sendable {
    let fileURL: URL
    let model: String
}

enum SomeIMClient {
    static let willDeepClientID = "willdeep"
    /// 网关对参照图的张数上限，见 muchtoken `internal/asyncmedia/capabilities.go`。
    static let maximumReferenceImages = 9
    static let customerPortalURL = URL(string: "https://some.im/customer")!
    /// Customer identity, login, subscription, and app-update APIs live on
    /// some.im. Model relay selection (for example api.niuwoai.com in China)
    /// must not redirect these control-plane calls to an inference-only
    /// gateway — the relay only proxies model inference and 404s everything
    /// else (which used to break Sparkle update checks for China-region users).
    static let controlPlaneOrigin = "https://some.im"
    private static let someIMClientLocationEndpoint = URL(string: "https://some.im/api/v1/public/client-location")!
    private static let ipipClientLocationEndpoint = URL(string: "https://myip.ipip.net")!
    private static let myIPLAClientLocationEndpoint = URL(string: "https://api.myip.la/en?json")!
    private static let countryProbeTimeout: TimeInterval = 8

    private enum CountryProbeVerdict: Sendable {
        case china
        case outsideChina
    }

    static func makeBrowserLoginRequest(settings: SomeIMIntegrationSettings) throws -> SomeIMBrowserLoginRequest {
        let code = try randomDeviceCode()
        let pairToken = try randomPairToken()
        let url = try browserLoginURL(code: code, pairToken: pairToken)
        return SomeIMBrowserLoginRequest(code: code, pairToken: pairToken, url: url, createdAt: Date())
    }

    static func resolveAutomaticRelayBaseURL() async throws -> String {
        try await resolveAutomaticRelayBaseURL(session: AgentNetworkSupport.defaultSession())
    }

    static func resolveAutomaticRelayBaseURL(session: URLSession) async throws -> String {
        async let someIMVerdict = probeSomeIMCountry(session: session)
        async let ipipVerdict = probeIPIPCountry(session: session)
        async let myIPLAVerdict = probeMyIPLACountry(session: session)

        let results = await [someIMVerdict, ipipVerdict, myIPLAVerdict].compactMap { $0 }
        if results.contains(where: { $0 == .china }) {
            return SomeIMRelayRegion.chinaBaseURL
        }
        guard results.contains(where: { $0 == .outsideChina }) else {
            throw AgentClientError.invalidResponse
        }
        return SomeIMRelayRegion.internationalBaseURL
    }

    private static func probeSomeIMCountry(session: URLSession) async -> CountryProbeVerdict? {
        do {
            let data = try await send(countryProbeRequest(url: someIMClientLocationEndpoint), session: session)
            let decoded = try decodeEnvelope(ClientLocationData.self, from: data)
            return countryVerdict(codeOrName: decoded.country)
        } catch {
            return nil
        }
    }

    private static func probeIPIPCountry(session: URLSession) async -> CountryProbeVerdict? {
        do {
            let data = try await send(
                countryProbeRequest(url: ipipClientLocationEndpoint, accept: "text/plain"),
                session: session
            )
            guard let text = String(data: data, encoding: .utf8), text.contains("来自于") else {
                return nil
            }
            return text.contains("中国") ? .china : .outsideChina
        } catch {
            return nil
        }
    }

    private static func probeMyIPLACountry(session: URLSession) async -> CountryProbeVerdict? {
        do {
            let data = try await send(countryProbeRequest(url: myIPLAClientLocationEndpoint), session: session)
            let decoded = try JSONDecoder().decode(MyIPLALocationData.self, from: data)
            return countryVerdict(codeOrName: decoded.location?.countryCode)
                ?? countryVerdict(codeOrName: decoded.location?.countryName)
        } catch {
            return nil
        }
    }

    private static func countryProbeRequest(url: URL, accept: String = "application/json") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = countryProbeTimeout
        request.setValue(accept, forHTTPHeaderField: "Accept")
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        return request
    }

    private static func countryVerdict(codeOrName: String?) -> CountryProbeVerdict? {
        let normalized = codeOrName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else { return nil }
        let uppercased = normalized.uppercased()
        if uppercased == "CN" || uppercased == "CHN" || uppercased.contains("CHINA") || normalized.contains("中国") {
            return .china
        }
        return .outsideChina
    }

    static func checkBrowserLoginStatus(
        request loginRequest: SomeIMBrowserLoginRequest,
        settings: SomeIMIntegrationSettings
    ) async throws -> SomeIMBrowserLoginStatus {
        try await checkBrowserLoginStatus(
            request: loginRequest,
            settings: settings,
            session: AgentNetworkSupport.defaultSession()
        )
    }

    static func checkBrowserLoginStatus(
        request loginRequest: SomeIMBrowserLoginRequest,
        settings: SomeIMIntegrationSettings,
        session: URLSession
    ) async throws -> SomeIMBrowserLoginStatus {
        let normalized = settings.normalized
        let endpoint = try browserStatusEndpoint(code: loginRequest.code)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(loginRequest.pairToken)", forHTTPHeaderField: "Authorization")
        applyClientLoginSecret(to: &request)
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        let data = try await send(request, session: session)
        let decoded = try decodeEnvelope(BrowserLoginStatusData.self, from: data)
        let state = SomeIMBrowserLoginStatus.State.fromServerValue(decoded.status)
        guard state == .connected else {
            return SomeIMBrowserLoginStatus(state: state, account: nil)
        }
        guard let apiKey = decoded.api_key?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            // 诊断：some.im 回了 connected 却没给出可识别的 API Key。只打字段名、不打任何值
            // （避免泄露 token / 邮箱），用来判断是服务端字段名不在识别清单里，还是压根没下发凭据。
            logBrowserStatusMissingKey(from: data)
            return SomeIMBrowserLoginStatus(state: .connected, account: nil)
        }
        let accountData = decoded.account ?? .empty
        // Browser login can come back without any account block at all; even
        // when present it carries no nickname/avatar. Keep the profile the
        // app already has instead of overwriting it with blanks.
        //
        // 资料补拉刻意**不**放在这里：这是个轮询状态检查，塞进第二个网络
        // 请求会让它每轮都可能打 /customer/me，也逼所有状态解析测试去桩
        // 一个无关端点。补拉在登录完成点做，见 `hydrateLoginProfile`。
        let account = accountData.account(
            fallbackEmail: "",
            fallbackModel: decoded.default_model?.nonEmpty ?? SomeIMIntegrationSettings.defaultTextModel
        ).preservingProfile(from: SomeIMIntegrationStore.loadAccount())
        var nextSettings = normalized
        nextSettings.enabled = true
        guard SomeIMIntegrationStore.saveAuthenticatedSession(
            apiKey: apiKey,
            sessionToken: decoded.token,
            account: account,
            settings: nextSettings
        ) else {
            return SomeIMBrowserLoginStatus(state: .credentialSaveFailed, account: nil)
        }
        SomeIMIntegrationStore.saveSettings(nextSettings)
        SomeIMIntegrationStore.saveAccount(account)
        return SomeIMBrowserLoginStatus(state: .connected, account: account)
    }

    static func sendClientLoginCode(
        email: String,
        settings: SomeIMIntegrationSettings
    ) async throws {
        try await sendClientLoginCode(
            email: email,
            settings: settings,
            session: AgentNetworkSupport.defaultSession()
        )
    }

    static func sendClientLoginCode(
        email: String,
        settings _: SomeIMIntegrationSettings,
        session: URLSession
    ) async throws {
        let endpoint = try publicAPIEndpoint(from: controlPlaneOrigin, suffix: "public/client-login/email/send")
        var request = jsonRequest(url: endpoint, method: "POST")
        applyClientLoginSecret(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "client_id": willDeepClientID
        ], options: [.sortedKeys])
        let data = try await send(request, session: session)
        _ = try decodeEnvelope(ClientLoginSendData.self, from: data)
    }

    static func verifyClientLoginCode(
        email: String,
        code: String,
        settings: SomeIMIntegrationSettings
    ) async throws -> SomeIMAccount {
        try await verifyClientLoginCode(
            email: email,
            code: code,
            settings: settings,
            session: AgentNetworkSupport.defaultSession()
        )
    }

    static func verifyClientLoginCode(
        email: String,
        code: String,
        settings: SomeIMIntegrationSettings,
        session: URLSession
    ) async throws -> SomeIMAccount {
        let normalized = settings.normalized
        let endpoint = try publicAPIEndpoint(from: controlPlaneOrigin, suffix: "public/client-login/email/verify")
        var request = jsonRequest(url: endpoint, method: "POST")
        applyClientLoginSecret(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "code": code.trimmingCharacters(in: .whitespacesAndNewlines),
            "client_id": willDeepClientID
        ], options: [.sortedKeys])
        let data = try await send(request, session: session)
        let decoded = try decodeEnvelope(ClientLoginVerifyData.self, from: data)
        let account = decoded.account.account(
            fallbackEmail: email,
            fallbackModel: decoded.default_model.nonEmpty ?? SomeIMIntegrationSettings.defaultTextModel
        ).preservingProfile(from: SomeIMIntegrationStore.loadAccount())
        var nextSettings = normalized
        nextSettings.enabled = true
        guard SomeIMIntegrationStore.saveAuthenticatedSession(
            apiKey: decoded.api_key,
            sessionToken: decoded.token,
            account: account,
            settings: nextSettings
        ) else {
            throw URLError(.userAuthenticationRequired)
        }
        SomeIMIntegrationStore.saveSettings(nextSettings)
        SomeIMIntegrationStore.saveAccount(account)
        return account
    }

    static func fetchAccountBalance() async throws -> SomeIMAccount {
        try await fetchAccountBalance(
            settings: SomeIMIntegrationStore.loadSettings(),
            apiKey: SomeIMIntegrationStore.loadAPIKey(),
            session: AgentNetworkSupport.defaultSession()
        )
    }

    static func fetchAccountBalance(
        settings: SomeIMIntegrationSettings,
        apiKey: String,
        session: URLSession
    ) async throws -> SomeIMAccount {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw AgentClientError.missingAPIKey }
        let endpoint = try AgentNetworkSupport.endpoint(from: settings.normalized.baseURL, suffix: "account/balance")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        let data = try await send(request, session: session)
        let decoded = try JSONDecoder().decode(AccountBalanceData.self, from: data)
        let previous = SomeIMIntegrationStore.loadAccount()
        // Credits come from the long-lived api_key and keep working even when
        // the 7-day customer session is dead, so a failure here degrades the
        // footer to the raw email with no other symptom. `try?` alone made
        // that state undiagnosable — log it (redacted) so a stuck nickname or
        // avatar can be traced instead of guessed at.
        var profile: (account: AccountData, tenantID: String?)?
        do {
            profile = try await fetchCustomerProfile(
                settings: settings,
                sessionToken: SomeIMIntegrationStore.loadSessionToken(),
                session: session
            )
        } catch {
            profile = nil
            print("SomeIMClient: customer profile refresh failed (nickname/avatar keep the last known value): \(error.localizedDescription)")
        }
        let balance = decoded.balance.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = SomeIMAccount(
            email: profile?.account.email?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? previous?.email ?? "",
            nickname: profile?.account.nickname?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? previous?.nickname,
            avatarURL: profile?.account.avatar_url?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? previous?.avatarURL,
            tenantID: decoded.tenant_id.nonEmpty ?? profile?.tenantID ?? previous?.tenantID,
            balanceUSD: balance,
            credits: credits(fromUSD: balance),
            creditsPerUSD: 100000,
            defaultModel: previous?.defaultModel ?? SomeIMIntegrationSettings.defaultTextModel,
            lastUpdatedAt: Date(),
            profileUpdatedAt: profile == nil ? previous?.profileUpdatedAt : Date(),
            creditsUpdatedAtMicros: decoded.balance_updated_at_unix_micros.flatMap(Int64.init)
        )
        return SomeIMIntegrationStore.saveRefreshedAccount(account)
    }

    /// 登录时补拉资料的时间预算。登录已经等过验证码校验和会话建立，这里
    /// 再多花的时间是用户直接感知的，所以给得紧；超时不算失败，只是退回
    /// 「稍后刷新时再出现」。
    static let loginProfileHydrationBudget: Double = 2.5

    /// 给一个 async 操作套时间预算：先出结果的赢，超时返回 nil 并取消对方。
    /// 只用于「拿到更好、拿不到也能继续」的锦上添花请求。
    static func withBudget<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// 登录完成后补齐昵称/头像并落盘，返回可直接展示的账号。
    ///
    /// 登录响应本身可能不含 nickname/avatar：服务端在这条路径上只 SELECT
    /// email（新版 some.im 随登录下发资料，线上旧版不会），于是账号先以邮箱
    /// 兜底渲染，几秒后 `fetchAccountBalance` 里的 `/customer/me` 才把头像
    /// 补上 —— 用户看到的就是「登录完先秃一截，头像慢慢冒出来」。
    ///
    /// 在登录**完成点**调用，而不是塞进 `checkBrowserLoginStatus`：后者是
    /// 轮询状态检查，多一个网络请求会让每轮轮询都可能打 `/customer/me`。
    @discardableResult
    static func hydrateLoginProfile(
        for account: SomeIMAccount,
        settings: SomeIMIntegrationSettings = SomeIMIntegrationStore.loadSettings(),
        sessionToken: String? = SomeIMIntegrationStore.loadSessionToken(),
        session: URLSession = AgentNetworkSupport.defaultSession()
    ) async -> SomeIMAccount {
        let hydrated = await hydratingLoginProfile(
            account,
            settings: settings.normalized,
            sessionToken: sessionToken,
            session: session
        )
        guard hydrated != account else { return account }
        SomeIMIntegrationStore.saveAccount(hydrated)
        return hydrated
    }

    /// 纯函数版本（不落盘），便于单测直接验证合并与预算行为。
    ///
    /// 服务端已经把资料带回来时直接返回，不多打一次请求；补拉失败也只是
    /// 退回原来的「稍后刷新时再出现」，绝不让登录本身失败。
    static func hydratingLoginProfile(
        _ account: SomeIMAccount,
        settings: SomeIMIntegrationSettings,
        sessionToken: String?,
        session: URLSession
    ) async -> SomeIMAccount {
        guard account.nickname?.nonEmpty == nil, account.avatarURL?.nonEmpty == nil else {
            return account
        }
        guard let token = sessionToken?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return account
        }
        // 硬预算：拿不到就按老路子等下一次余额刷新补，绝不让登录界面卡在
        // 资料请求上。`/customer/me` 本身 12s 超时，失败时还会再试一次
        // token 续期 —— 不封顶的话「登录慢半秒」会退化成「登录卡 20 秒」，
        // 比原来的问题更糟。
        guard let profile = await withBudget(seconds: loginProfileHydrationBudget, operation: {
            try? await fetchCustomerProfile(
                settings: settings,
                sessionToken: token,
                session: session
            )
        }) else {
            return account
        }
        let nickname = profile.account.nickname?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let avatarURL = profile.account.avatar_url?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        guard nickname != nil || avatarURL != nil else { return account }
        var merged = account
        merged.nickname = nickname
        merged.avatarURL = avatarURL
        // 邮箱以登录响应为准；`/customer/me` 只在登录没给出邮箱时补位，
        // 避免资料接口的空值把刚登录的身份洗掉。
        if merged.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let profileEmail = profile.account.email?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            merged.email = profileEmail
        }
        if merged.tenantID?.nonEmpty == nil {
            merged.tenantID = profile.tenantID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        merged.profileUpdatedAt = Date()
        return merged
    }

    /// Fetch nickname/avatar, renewing the session token once if it has
    /// expired.
    ///
    /// Customer sessions last 7 days and `/customer/me` accepts nothing else,
    /// while balance runs on the long-lived api_key. Without this renewal the
    /// account settles into "credits still update, name and picture never do"
    /// and cannot recover on its own.
    private static func fetchCustomerProfile(
        settings: SomeIMIntegrationSettings,
        sessionToken: String,
        session: URLSession
    ) async throws -> (account: AccountData, tenantID: String?) {
        do {
            return try await requestCustomerProfile(sessionToken: sessionToken, session: session)
        } catch {
            // Exactly one renewal attempt. Looping on a key the server keeps
            // rejecting would hammer the exchange endpoint for nothing.
            guard isAuthenticationFailure(error),
                  let renewed = try? await exchangeSessionToken(settings: settings, session: session) else {
                throw error
            }
            return try await requestCustomerProfile(sessionToken: renewed, session: session)
        }
    }

    private static func requestCustomerProfile(
        sessionToken: String,
        session: URLSession
    ) async throws -> (account: AccountData, tenantID: String?) {
        let token = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw URLError(.userAuthenticationRequired) }
        let endpoint = try publicAPIEndpoint(from: controlPlaneOrigin, suffix: "customer/me")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        let data = try await send(request, session: session)
        let decoded = try decodeEnvelope(CustomerMeData.self, from: data)
        guard let account = decoded.user else { throw AgentClientError.invalidResponse }
        return (account, decoded.tenant?.id)
    }

    /// Trade the long-lived api_key for a fresh customer session token and
    /// store it. Returns the new token.
    ///
    /// Only the expired-session case should reach here; a failure is left to
    /// the caller so the profile it already has is kept rather than cleared.
    @discardableResult
    static func exchangeSessionToken(
        settings: SomeIMIntegrationSettings,
        session: URLSession
    ) async throws -> String {
        let apiKey = SomeIMIntegrationStore.loadAPIKey().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw AgentClientError.missingAPIKey }
        let endpoint = try publicAPIEndpoint(
            from: controlPlaneOrigin,
            suffix: "public/client-login/session/exchange"
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        applyClientLoginSecret(to: &request)
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        let data = try await send(request, session: session)
        let decoded = try decodeEnvelope(SessionExchangeData.self, from: data)
        let token = decoded.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw AgentClientError.invalidResponse }
        _ = SomeIMIntegrationStore.saveSessionToken(token)
        return token
    }

    /// Whether an error means "this session token is no longer valid", as
    /// opposed to a network blip or a server fault — renewing on anything
    /// else would turn transient failures into pointless exchange traffic.
    nonisolated static func isAuthenticationFailure(_ error: Error) -> Bool {
        if case AgentToolError.httpFailed(let status, _) = error {
            return status == 401 || status == 403
        }
        if let urlError = error as? URLError {
            return urlError.code == .userAuthenticationRequired
        }
        return false
    }

    fileprivate struct SessionExchangeData: Decodable {
        let token: String
        let expires_at: String?
        let tenant_id: String?
    }



    static func fetchModels(
        settings: SomeIMIntegrationSettings,
        apiKey: String,
        session: URLSession
    ) async throws -> [SomeIMModel] {
        do {
            let models = try await fetchPricingModels(settings: settings.normalized, apiKey: apiKey, session: session)
                .filter { !SomeIMManagedModel.isRetired($0.model) }
            if !models.isEmpty { return models }
        } catch {
            // Fall through to OpenAI-compatible /models below. some.im
            // deployments may expose only one of these endpoints.
        }
        return try await fetchOpenAIModels(settings: settings.normalized, apiKey: apiKey, session: session)
            .filter { !SomeIMManagedModel.isRetired($0.model) }
    }

    static func fetchModels(
        settings: SomeIMIntegrationSettings,
        apiKey: String
    ) async throws -> [SomeIMModel] {
        try await fetchModels(settings: settings, apiKey: apiKey, session: AgentNetworkSupport.defaultSession())
    }

    static func generateImage(
        prompt: String,
        size: String = "1024x1024",
        model overrideModel: String? = nil,
        outputDirectory: URL? = nil,
        referenceImageURLs: [String] = []
    ) async throws -> SomeIMGeneratedImage {
        try await generateImage(
            prompt: prompt,
            size: size,
            model: overrideModel,
            outputDirectory: outputDirectory,
            settings: SomeIMIntegrationStore.loadSettings(),
            apiKey: SomeIMIntegrationStore.loadAPIKey(),
            session: AgentNetworkSupport.defaultSession(),
            referenceImageURLs: referenceImageURLs
        )
    }

    /// 把一组本地图片上传成公网 URL，供上面那两个函数当参照图用。内容哈希
    /// 命中缓存就不重复上传——同一张脸会在很多镜头、很多集里反复用到。
    static func uploadReferenceImages(_ fileURLs: [URL]) async throws -> [String] {
        guard !fileURLs.isEmpty else { return [] }
        let settings = SomeIMIntegrationStore.loadSettings().normalized
        let apiKey = SomeIMIntegrationStore.loadAPIKey()
        let session = AgentNetworkSupport.defaultSession()
        let baseURL = settings.baseURL
        var uploaded: [String] = []
        for fileURL in fileURLs {
            let key = try SomeIMReferenceImageUpload.contentKey(forContentsOf: fileURL)
            // 走合并器而不是直接传：一次生成会并发发起多张候选，每一路都要
            // 同一批脸，各传一遍纯属白花流量。
            let image = try await SomeIMReferenceImageUploadCoalescer.shared.image(contentKey: key) {
                try await SomeIMReferenceImageUpload.upload(
                    fileURL: fileURL,
                    inferenceBaseURL: baseURL,
                    apiKey: apiKey,
                    session: session
                )
            }
            uploaded.append(image.publicURL)
        }
        return uploaded
    }

    static func generateImage(
        prompt: String,
        size: String,
        model overrideModel: String?,
        outputDirectory: URL?,
        settings: SomeIMIntegrationSettings,
        apiKey: String,
        session: URLSession,
        /// 参照图，已经是可取的公网 URL。本地文件要先经
        /// `SomeIMReferenceImageUpload` 换成 URL——网关只接 URL，见那个文件
        /// 顶部的说明。空数组即纯文生图，与改动前完全一致。
        referenceImageURLs: [String] = []
    ) async throws -> SomeIMGeneratedImage {
        let normalized = settings.normalized
        guard normalized.enabled else {
            throw AgentToolError.invalidArgument("some.im integration is disabled.")
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentClientError.missingAPIKey
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw AgentToolError.missingArgument("prompt")
        }
        let model = overrideModel?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? normalized.preferredImageModel
        let endpoint = try AgentNetworkSupport.endpoint(from: normalized.baseURL, suffix: "images/generations")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = AgentNetworkSupport.resourceTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        // 上限 9 张是网关的（internal/asyncmedia/capabilities.go）。超了就如实
        // 报错而不是悄悄截断——少送一张脸，出来的图错得不显眼，最难查。
        let references = referenceImageURLs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard references.count <= maximumReferenceImages else {
            throw AgentToolError.invalidArgument(
                "some.im accepts at most \(maximumReferenceImages) reference images, got \(references.count)."
            )
        }
        // body 的形状（含 nano-banana 系要的 `aspect_ratio`）见
        // `SomeIMImageGenerationRequest`。
        let body = SomeIMImageGenerationRequest.body(
            model: model,
            prompt: trimmedPrompt,
            size: size,
            referenceImageURLs: references
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentToolError.httpFailed(http.statusCode, String(data: data, encoding: .utf8) ?? "<non-UTF8 response body>")
        }
        let decoded = try JSONDecoder().decode(ImageGenerationResponse.self, from: data)
        guard let first = decoded.data.first else {
            throw AgentToolError.invalidArgument("some.im returned no image data.")
        }
        if let base64 = first.b64_json, let data = Data(base64Encoded: base64) {
            let fileURL = outputURL(fileExtension: "png", outputDirectory: outputDirectory)
            try data.write(to: fileURL, options: [.atomic])
            return SomeIMGeneratedImage(fileURL: fileURL, model: model)
        } else if let urlString = first.url, let url = URL(string: urlString) {
            var downloadRequest = URLRequest(url: url)
            AgentNetworkSupport.applyStandardHeaders(to: &downloadRequest)
            let (temporaryURL, response) = try await session.download(for: downloadRequest)
            guard let http = response as? HTTPURLResponse else {
                throw AgentClientError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                let data = (try? Data(contentsOf: temporaryURL)) ?? Data()
                let text = String(data: data.prefix(64 * 1024), encoding: .utf8) ?? "<non-UTF8 response body>"
                try? FileManager.default.removeItem(at: temporaryURL)
                throw AgentToolError.httpFailed(http.statusCode, AgentNetworkSupport.limitDebugText(text))
            }
            let fileURL = outputURL(fileExtension: url.pathExtension.nonEmpty ?? "png", outputDirectory: outputDirectory)
            try AgentNetworkSupport.moveDownloadedFile(from: temporaryURL, to: fileURL)
            return SomeIMGeneratedImage(fileURL: fileURL, model: model)
        } else {
            throw AgentToolError.invalidArgument("some.im image response did not include b64_json or url.")
        }
    }

    private static func fetchPricingModels(
        settings: SomeIMIntegrationSettings,
        apiKey: String,
        session: URLSession
    ) async throws -> [SomeIMModel] {
        guard let endpoint = publicPricingEndpoint(from: settings.baseURL) else {
            return []
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AgentClientError.invalidResponse
        }
        let decoded = try JSONDecoder().decode(PricingResponse.self, from: data)
        return decoded.items.map { item in
            SomeIMModel(
                model: item.model,
                kinds: item.detectedKinds,
                isHot: item.is_hot ?? false,
                isNew: item.is_new ?? false,
                contextWindowTokens: item.context_tokens_max.flatMap { $0 > 0 ? $0 : nil }
            )
        }
    }

    private static func fetchOpenAIModels(
        settings: SomeIMIntegrationSettings,
        apiKey: String,
        session: URLSession
    ) async throws -> [SomeIMModel] {
        let configuration = AgentConfiguration(
            providerID: "some-im",
            baseURL: settings.baseURL,
            model: settings.preferredImageModel,
            apiKey: apiKey
        )
        return try await AgentClient(configuration: configuration, session: session)
            .fetchModelDiscoveries()
            .map { discovery in
                SomeIMModel(
                    model: discovery.id,
                    kinds: detectKinds(model: discovery.id, words: []),
                    isHot: discovery.isHot,
                    isNew: discovery.isNew
                )
            }
    }

    private static func publicPricingEndpoint(from baseURL: String) -> URL? {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        components.path = "/api/v1/public/model-pricing"
        components.query = nil
        return components.url
    }

    private static func publicAPIEndpoint(from baseURL: String, suffix: String) throws -> URL {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AgentClientError.invalidResponse
        }
        let cleaned = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/api/v1/\(cleaned)"
        components.query = nil
        guard let url = components.url else { throw AgentClientError.invalidResponse }
        return url
    }

    private static func browserStatusEndpoint(code: String) throws -> URL {
        guard var components = URLComponents(url: try publicAPIEndpoint(from: controlPlaneOrigin, suffix: "public/client-login/browser-status"), resolvingAgainstBaseURL: false) else {
            throw AgentClientError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: willDeepClientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "device_code", value: code),
            URLQueryItem(name: "willdeep_device_code", value: code)
        ]
        guard let url = components.url else { throw AgentClientError.invalidResponse }
        return url
    }

    private static func browserLoginURL(code: String, pairToken: String) throws -> URL {
        guard var components = URLComponents(string: controlPlaneOrigin) else {
            throw AgentClientError.invalidResponse
        }
        components.path = "/customer/login"
        let next = "/customer?willdeep_return=1&code=\(code)&device_code=\(code)&willdeep_device_code=\(code)&pair_token=\(pairToken)&willdeep_pair_token=\(pairToken)"
        components.queryItems = [
            URLQueryItem(name: "client_id", value: willDeepClientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "device_code", value: code),
            URLQueryItem(name: "willdeep_device_code", value: code),
            URLQueryItem(name: "pair_token", value: pairToken),
            URLQueryItem(name: "willdeep_pair_token", value: pairToken),
            URLQueryItem(name: "return_to", value: "willdeep"),
            URLQueryItem(name: "next", value: next)
        ]
        guard let url = components.url else { throw AgentClientError.invalidResponse }
        return url
    }

    private static func randomDeviceCode() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw AgentToolError.invalidArgument("Unable to create a random some.im login code.")
        }
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let raw = bytes.map { alphabet[Int($0) % alphabet.count] }
        return "WD-\(String(raw.prefix(4)))-\(String(raw.suffix(4)))"
    }

    private static func randomPairToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw AgentToolError.invalidArgument("Unable to create a secure some.im browser login token.")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func jsonRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = AgentNetworkSupport.resourceTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        return request
    }

    /// 仅记录 browser-status 响应里出现的字段名（含嵌套 data/result/payload 一层），不记录任何值，
    /// 便于诊断「connected 却无凭据」时服务端到底把 key 放哪、或有没有下发。
    private static func logBrowserStatusMissingKey(from data: Data) {
        var names = Set<String>()
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            names.formUnion(root.keys)
            for wrapper in ["data", "result", "payload", "credentials", "credential", "account"] {
                if let nested = root[wrapper] as? [String: Any] {
                    names.formUnion(nested.keys.map { "\(wrapper).\($0)" })
                }
            }
        }
        let fields = names.sorted().joined(separator: ", ")
        print("[some.im] browser-status connected but no recognizable api_key; response fields: [\(fields)]")
    }

    private static func applyClientLoginSecret(to request: inout URLRequest) {
        let secret = SomeIMIntegrationStore.loadClientLoginSecret()
        guard !secret.isEmpty else { return }
        request.setValue(secret, forHTTPHeaderField: "X-WillDeep-Client-Secret")
    }

    private static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentToolError.httpFailed(http.statusCode, AgentNetworkSupport.limitDebugText(String(data: data, encoding: .utf8) ?? "<non-UTF8 response body>"))
        }
        return data
    }

    private static func decodeEnvelope<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if let envelope = try? JSONDecoder().decode(APIEnvelope<T>.self, from: data) {
            return envelope.data
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func credits(fromUSD usd: String) -> String {
        let decimal = Decimal(string: usd.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let credits = decimal * Decimal(100000)
        return max(Int64(0), NSDecimalNumber(decimal: credits).int64Value).description
    }

    private static func parseRFC3339Date(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    private static func outputURL(fileExtension: String, outputDirectory: URL?) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "willdeep-generated-image-\(formatter.string(from: Date())).\(fileExtension)"
        let directory = outputDirectory?.standardizedFileURL
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let candidate = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return candidate
        }
        let stem = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var counter = 2
        while true {
            let next = directory.appendingPathComponent("\(stem)-\(counter).\(ext)")
            if !FileManager.default.fileExists(atPath: next.path) {
                return next
            }
            counter += 1
        }
    }

    private static func detectKinds(model: String, words: [String]) -> [SomeIMGenerationKind] {
        let haystack = ([model] + words).joined(separator: " ").lowercased()
        var kinds: [SomeIMGenerationKind] = []
        if haystack.contains("image") || haystack.contains("vision") || haystack.contains("图") {
            kinds.append(.image)
        }
        if haystack.contains("video") || haystack.contains("视频") {
            kinds.append(.video)
        }
        if haystack.contains("llm") || haystack.contains("chat") || haystack.contains("text") {
            kinds.append(.text)
        }
        return kinds.isEmpty ? [.unknown] : kinds
    }

    private struct PricingResponse: Decodable {
        let items: [PricingItem]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let direct = try? container.decode([PricingItem].self, forKey: .items) {
                items = direct
                return
            }
            let wrapped = try? container.decode(DataWrapper.self, forKey: .data)
            items = wrapped?.items ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case items
            case data
        }

        private struct DataWrapper: Decodable {
            let items: [PricingItem]
        }
    }

    private struct PricingItem: Decodable {
        let model: String
        let capability_kinds: [String]?
        let generation_task_types: [String]?
        let input_modalities: [String]?
        let output_modalities: [String]?
        let catalog_tags: [String]?
        let is_hot: Bool?
        let is_new: Bool?
        /// some.im publishes the context window here. Only a minority of rows
        /// fill it in today (9 of 47 at the time of writing, and notably not
        /// the DeepSeek defaults), so this supplements the id-matching table
        /// rather than replacing it.
        let context_tokens_max: Int?

        var detectedKinds: [SomeIMGenerationKind] {
            detectKinds(model: model, words: [
                capability_kinds,
                generation_task_types,
                input_modalities,
                output_modalities,
                catalog_tags
            ].compactMap { $0 }.flatMap { $0 })
        }
    }

    private struct ImageGenerationResponse: Decodable {
        let data: [ImageDatum]

        struct ImageDatum: Decodable {
            let b64_json: String?
            let url: String?
        }
    }


    private struct ClientLocationData: Decodable {
        let country: String?
    }

    private struct MyIPLALocationData: Decodable {
        let location: Location?

        struct Location: Decodable {
            let countryCode: String?
            let countryName: String?

            private enum CodingKeys: String, CodingKey {
                case countryCode = "country_code"
                case countryName = "country_name"
            }
        }
    }


    private struct APIEnvelope<T: Decodable>: Decodable {
        let data: T
    }

    private struct ClientLoginSendData: Decodable {
        let ok: Bool?
    }

    private struct ClientLoginVerifyData: Decodable {
        let api_key: String
        let default_model: String
        let token: String?
        let account: AccountData
    }

    private struct BrowserLoginStatusData: Decodable {
        let status: String
        let api_key: String?
        let default_model: String?
        let token: String?
        let account: AccountData?

        private enum CodingKeys: String, CodingKey {
            case status
            case state
            case loginStatus = "login_status"
            case apiKey = "api_key"
            case apiKeyCamel = "apiKey"
            case appAPIKey = "app_api_key"
            case appAPIKeyCamel = "appApiKey"
            case willDeepAPIKey = "willdeep_api_key"
            case willDeepAPIKeyCamel = "willdeepApiKey"
            case apiToken = "api_token"
            case apiTokenCamel = "apiToken"
            case defaultModel = "default_model"
            case defaultModelCamel = "defaultModel"
            case token
            case sessionToken = "session_token"
            case sessionTokenCamel = "sessionToken"
            case customerSession = "customer_session"
            case customerSessionCamel = "customerSession"
            case customerSessionToken = "customer_session_token"
            case customerSessionTokenCamel = "customerSessionToken"
            case account
            case customer
            case profile
            case user
            case credentials
            case credential
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decodeFirstString(for: [.status, .state, .loginStatus]) ?? "unknown"
            let directAPIKey = try container.decodeFirstString(for: [
                .apiKey,
                .apiKeyCamel,
                .appAPIKey,
                .appAPIKeyCamel,
                .willDeepAPIKey,
                .willDeepAPIKeyCamel,
                .apiToken,
                .apiTokenCamel
            ])
            let directDefaultModel = try container.decodeFirstString(for: [.defaultModel, .defaultModelCamel])
            let directToken = try container.decodeFirstString(for: [
                .token,
                .sessionToken,
                .sessionTokenCamel,
                .customerSession,
                .customerSessionCamel,
                .customerSessionToken,
                .customerSessionTokenCamel
            ])
            let credentials = try container.decodeFirstCredentials(for: [.credentials, .credential])
            let flatAccount = try AccountData(from: decoder)
            api_key = directAPIKey ?? credentials.apiKey
            default_model = directDefaultModel ?? credentials.defaultModel
            token = directToken ?? credentials.token
            account = try container.decodeFirstAccount(for: [.account, .customer, .profile, .user])
                ?? credentials.account
                ?? (flatAccount.hasAnyAccountInfo ? flatAccount : nil)
        }
    }

    fileprivate struct AccountData: Decodable {
        let email: String?
        let nickname: String?
        let avatar_url: String?
        let tenant_id: String?
        let balance_usd: String?
        let credits: String?
        let credits_per_usd: Int?
        let default_model: String?

        private enum CodingKeys: String, CodingKey {
            case email
            case customerEmail = "customer_email"
            case customerEmailCamel = "customerEmail"
            case userEmail = "user_email"
            case userEmailCamel = "userEmail"
            case nickname
            case nickName = "nick_name"
            case displayName = "display_name"
            case avatarURL = "avatar_url"
            case avatarURLCamel = "avatarURL"
            case avatarUrlCamel = "avatarUrl"
            case tenantID = "tenant_id"
            case tenantIDCamel = "tenantID"
            case tenantIdCamel = "tenantId"
            case balanceUSD = "balance_usd"
            case balanceUSDCamel = "balanceUSD"
            case balanceUSDCamelAlt = "balanceUsd"
            case balance
            case credits
            case creditBalance = "credit_balance"
            case creditBalanceCamel = "creditBalance"
            case creditsPerUSD = "credits_per_usd"
            case creditsPerUSDCamel = "creditsPerUSD"
            case creditsPerUSDCamelAlt = "creditsPerUsd"
            case defaultModel = "default_model"
            case defaultModelCamel = "defaultModel"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            email = try container.decodeFirstString(for: [.email, .customerEmail, .customerEmailCamel, .userEmail, .userEmailCamel])
            nickname = try container.decodeFirstString(for: [.nickname, .nickName, .displayName])
            avatar_url = try container.decodeFirstString(for: [.avatarURL, .avatarURLCamel, .avatarUrlCamel])
            tenant_id = try container.decodeFirstString(for: [.tenantID, .tenantIDCamel, .tenantIdCamel])
            balance_usd = try container.decodeFirstString(for: [.balanceUSD, .balanceUSDCamel, .balanceUSDCamelAlt, .balance])
            credits = try container.decodeFirstString(for: [.credits, .creditBalance, .creditBalanceCamel])
            credits_per_usd = try container.decodeFirstInt(for: [.creditsPerUSD, .creditsPerUSDCamel, .creditsPerUSDCamelAlt])
            default_model = try container.decodeFirstString(for: [.defaultModel, .defaultModelCamel])
        }

        static let empty = AccountData(
            email: nil,
            nickname: nil,
            avatarURL: nil,
            tenantID: nil,
            balanceUSD: nil,
            credits: nil,
            creditsPerUSD: nil,
            defaultModel: nil
        )

        init(
            email: String?,
            nickname: String?,
            avatarURL: String?,
            tenantID: String?,
            balanceUSD: String?,
            credits: String?,
            creditsPerUSD: Int?,
            defaultModel: String?
        ) {
            self.email = email
            self.nickname = nickname
            self.avatar_url = avatarURL
            self.tenant_id = tenantID
            self.balance_usd = balanceUSD
            self.credits = credits
            self.credits_per_usd = creditsPerUSD
            self.default_model = defaultModel
        }

        var hasAnyAccountInfo: Bool {
            [email, nickname, avatar_url, tenant_id, balance_usd, credits, default_model].contains { value in
                !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            } || credits_per_usd != nil
        }

        func account(fallbackEmail: String, fallbackModel: String) -> SomeIMAccount {
            let balance = balance_usd?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "0"
            let normalizedNickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            let normalizedAvatarURL = avatar_url?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            return SomeIMAccount(
                email: email?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? fallbackEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                nickname: normalizedNickname,
                avatarURL: normalizedAvatarURL,
                tenantID: tenant_id?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                balanceUSD: balance,
                credits: credits?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? SomeIMClient.credits(fromUSD: balance),
                creditsPerUSD: credits_per_usd ?? 100000,
                defaultModel: default_model?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? fallbackModel,
                lastUpdatedAt: Date(),
                profileUpdatedAt: normalizedNickname == nil && normalizedAvatarURL == nil ? nil : Date()
            )
        }
    }

    fileprivate struct CustomerMeData: Decodable {
        let user: AccountData?
        let tenant: CustomerMeTenantData?
    }

    fileprivate struct CustomerMeTenantData: Decodable {
        let id: String?
    }

    fileprivate struct BrowserLoginCredentials: Decodable {
        let apiKey: String?
        let defaultModel: String?
        let token: String?
        let account: AccountData?

        private enum CodingKeys: String, CodingKey {
            case apiKey = "api_key"
            case apiKeyCamel = "apiKey"
            case appAPIKey = "app_api_key"
            case appAPIKeyCamel = "appApiKey"
            case willDeepAPIKey = "willdeep_api_key"
            case willDeepAPIKeyCamel = "willdeepApiKey"
            case apiToken = "api_token"
            case apiTokenCamel = "apiToken"
            case defaultModel = "default_model"
            case defaultModelCamel = "defaultModel"
            case token
            case sessionToken = "session_token"
            case sessionTokenCamel = "sessionToken"
            case customerSession = "customer_session"
            case customerSessionCamel = "customerSession"
            case customerSessionToken = "customer_session_token"
            case customerSessionTokenCamel = "customerSessionToken"
            case account
            case customer
            case profile
            case user
        }

        init(apiKey: String?, defaultModel: String?, token: String?, account: AccountData?) {
            self.apiKey = apiKey
            self.defaultModel = defaultModel
            self.token = token
            self.account = account
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            apiKey = try container.decodeFirstString(for: [
                .apiKey,
                .apiKeyCamel,
                .appAPIKey,
                .appAPIKeyCamel,
                .willDeepAPIKey,
                .willDeepAPIKeyCamel,
                .apiToken,
                .apiTokenCamel
            ])
            defaultModel = try container.decodeFirstString(for: [.defaultModel, .defaultModelCamel])
            token = try container.decodeFirstString(for: [
                .token,
                .sessionToken,
                .sessionTokenCamel,
                .customerSession,
                .customerSessionCamel,
                .customerSessionToken,
                .customerSessionTokenCamel
            ])
            account = try container.decodeFirstAccount(for: [.account, .customer, .profile, .user])
        }
    }

    private struct AccountBalanceData: Decodable {
        let tenant_id: String
        let currency: String
        let balance: String
        let balance_updated_at_unix_micros: String?
    }

}

private extension KeyedDecodingContainer {
    func decodeFirstString(for keys: [Key]) throws -> String? {
        for key in keys {
            if let value = try? decodeIfPresent(String.self, forKey: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return String(value)
            }
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return String(value)
            }
        }
        return nil
    }

    func decodeFirstInt(for keys: [Key]) throws -> Int? {
        for key in keys {
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let string = try? decodeIfPresent(String.self, forKey: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let value = Int(string) {
                return value
            }
        }
        return nil
    }

    func decodeFirstAccount(for keys: [Key]) throws -> SomeIMClient.AccountData? {
        for key in keys {
            if let value = try decodeIfPresent(SomeIMClient.AccountData.self, forKey: key) {
                return value
            }
        }
        return nil
    }

    func decodeFirstCredentials(for keys: [Key]) throws -> SomeIMClient.BrowserLoginCredentials {
        for key in keys {
            if let value = try decodeIfPresent(SomeIMClient.BrowserLoginCredentials.self, forKey: key) {
                return value
            }
        }
        return SomeIMClient.BrowserLoginCredentials(apiKey: nil, defaultModel: nil, token: nil, account: nil)
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
