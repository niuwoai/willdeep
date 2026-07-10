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

    var supportsImageGeneration: Bool { kinds.contains(.image) || model.localizedCaseInsensitiveContains("image") }
    var supportsVideoGeneration: Bool { kinds.contains(.video) || model.localizedCaseInsensitiveContains("video") }
    var agentDiscovery: AgentModelDiscovery {
        AgentModelDiscovery(id: model, isHot: isHot, isNew: isNew)
    }
}

struct SomeIMCodingPlanStatus: Codable, Equatable {
    var hasActivePlan: Bool
    var planID: String?
    var planName: String?
    var periodEnd: Date?
    var checkedAt: Date

    static let unknown = SomeIMCodingPlanStatus(
        hasActivePlan: false,
        planID: nil,
        planName: nil,
        periodEnd: nil,
        checkedAt: .distantPast
    )

    var isActiveNow: Bool {
        guard hasActivePlan else { return false }
        guard let periodEnd else { return true }
        return periodEnd > Date()
    }

    var isStale: Bool {
        Date().timeIntervalSince(checkedAt) > 10 * 60
    }
}

struct SomeIMIntegrationSettings: Codable, Equatable {
    static let defaultBaseURL = SomeIMRelayRegion.internationalBaseURL
    static let defaultImageModel = "gpt-image-2"
    static let defaultVideoModel = "seedance-2.0"
    static let defaultTextModel = "someim-auto-flash"
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

enum SomeIMIntegrationStore {
    // Plain immutable constants — `nonisolated` so they can be referenced from
    // the Sendable cross-app session-observer closure below without hopping
    // actors (the enum otherwise defaults to main-actor isolation).
    nonisolated static let accountDidChangeNotification = Notification.Name("com.willdeep.someIM.accountDidChange")
    /// Posted (local, same-process) whenever the shared some.im session changes
    /// — including changes made by *another* app. AppState listens to reconcile
    /// its agent provider so a cross-app login/logout takes effect live.
    nonisolated static let sessionDidChangeNotification = Notification.Name("com.willdeep.someIM.sessionDidChange")

    /// Shared Keychain access group (Team ZH2S7D6PL6). Must match the
    /// `keychain-access-groups` entitlement and every other participating app.
    nonisolated static let sharedAccessGroup = "ZH2S7D6PL6.com.someim.shared"

    private static let settingsKey = "com.willdeep.someIM.integrationSettings.v1"
    private static let accountKey = "com.willdeep.someIM.account.v1"
    private static let codingPlanStatusKey = "com.willdeep.someIM.codingPlanStatus.v1"
    // Legacy per-app Keychain accounts. Read only for the one-time migration
    // into the shared store; never written after that.
    private static let legacyAPIKeyAccount = "some-im/api-key"
    private static let legacySessionTokenAccount = "some-im/customer-session"
    private static let migrationDoneKey = "com.willdeep.someIM.sharedSessionMigration.v1"

    private static let migrationLock = NSLock()
    private nonisolated(unsafe) static var migrationAttempted = false
    private nonisolated(unsafe) static var sessionObservation: ObservationToken?
    #if DEBUG
    private nonisolated(unsafe) static var testSharedSessionOverrideEnabled = false
    private nonisolated(unsafe) static var testSharedSessionOverride: SomeIMSharedSession?
    #endif

    /// Call once at app launch (before any credential access). Wires the shared
    /// Keychain access group, migrates any legacy per-app credentials, and starts
    /// forwarding cross-app session changes into `sessionDidChangeNotification`.
    static func configureSharedSession() {
        #if DEBUG
        // Debug installs are often ad-hoc signed on machines without a local
        // Apple development identity. In that case macOS ignores the invalid
        // access-group entitlement; use the app's ordinary Keychain namespace
        // so browser login can still persist credentials locally.
        let accessGroup = hasSharedKeychainAccessGroup ? sharedAccessGroup : ""
        #else
        let accessGroup = sharedAccessGroup
        #endif
        SomeIMSharedSessionStore.shared.configure(accessGroup: accessGroup)
        migrateLegacyIfNeeded()
        guard sessionObservation == nil else { return }
        sessionObservation = SomeIMSharedSessionStore.shared.observe { _ in
            // Delivered on the main queue on every login/logout in this or any
            // other app. Fan out so the account UI and the agent provider
            // re-read the (already-persisted) shared session.
            NotificationCenter.default.post(name: accountDidChangeNotification, object: nil)
            NotificationCenter.default.post(name: sessionDidChangeNotification, object: nil)
        }
    }

    private static var hasSharedKeychainAccessGroup: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(
                  task,
                  "keychain-access-groups" as CFString,
                  nil
              ) as? [String] else {
            return false
        }
        return groups.contains(sharedAccessGroup)
    }

    static func loadSettings() -> SomeIMIntegrationSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode(SomeIMIntegrationSettings.self, from: data) else {
            return SomeIMIntegrationSettings()
        }
        return decoded.normalized
    }

    static func saveSettings(_ settings: SomeIMIntegrationSettings) {
        let normalized = settings.normalized
        if let data = try? JSONEncoder().encode(normalized) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    static func loadAccount() -> SomeIMAccount? {
        guard let data = UserDefaults.standard.data(forKey: accountKey) else { return nil }
        return try? JSONDecoder().decode(SomeIMAccount.self, from: data)
    }

    static func saveAccount(_ account: SomeIMAccount?) {
        if let account, let data = try? JSONEncoder().encode(account) {
            UserDefaults.standard.set(data, forKey: accountKey)
            // Keep the shared session's identity fields in step with the local
            // display cache (balance/credits stay local, per-app).
            mirrorIdentityToShared(email: account.email, tenantID: account.tenantID)
        } else {
            UserDefaults.standard.removeObject(forKey: accountKey)
        }
        NotificationCenter.default.post(name: accountDidChangeNotification, object: nil)
    }

    // MARK: - Secrets (shared Keychain access group is the source of truth)

    static func loadAPIKey() -> String {
        #if DEBUG
        if testSharedSessionOverrideEnabled {
            return testSharedSessionOverride?.apiKey ?? ""
        }
        #endif
        migrateLegacyIfNeeded()
        return currentSharedSession()?.apiKey ?? ""
    }

    @discardableResult
    static func saveAPIKey(_ apiKey: String) -> Bool {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty key is a NO-OP, never a logout. Real sign-out goes through
        // `logout()`; this guard stops an accidental empty save (e.g. the
        // Settings pane saving while its key field is momentarily blank) from
        // signing every app out.
        guard !trimmed.isEmpty else { return false }
        return updateSharedSession { $0.apiKey = trimmed }
    }

    static func loadSessionToken() -> String {
        #if DEBUG
        if testSharedSessionOverrideEnabled {
            return testSharedSessionOverride?.sessionToken ?? ""
        }
        #endif
        migrateLegacyIfNeeded()
        return currentSharedSession()?.sessionToken ?? ""
    }

    @discardableResult
    static func saveSessionToken(_ token: String) -> Bool {
        updateSharedSession { $0.sessionToken = token.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    @discardableResult
    static func saveAuthenticatedSession(
        apiKey: String,
        sessionToken: String?,
        account: SomeIMAccount,
        settings: SomeIMIntegrationSettings
    ) -> Bool {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return false }
        let normalizedSettings = settings.normalized
        var session = currentSharedSession()
            ?? SomeIMSharedSession(apiKey: "", baseURL: normalizedSettings.baseURL)
        session.apiKey = trimmedKey
        if let token = sessionToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            session.sessionToken = token
        }
        session.email = account.email
        session.tenantID = account.tenantID
        session.baseURL = normalizedSettings.baseURL
        session.updatedAt = Date()
        guard session.isValid,
              persistSharedSession(session),
              currentSharedSession()?.apiKey == trimmedKey else {
            return false
        }
        return true
    }

    /// Sign out of some.im everywhere: clears the shared session (broadcasting to
    /// all apps) and drops this app's local account cache and enabled flag.
    static func logout() {
        #if DEBUG
        if testSharedSessionOverrideEnabled {
            testSharedSessionOverride = nil
        } else {
            SomeIMSharedSessionStore.shared.logout()
        }
        #else
        SomeIMSharedSessionStore.shared.logout()
        #endif
        UserDefaults.standard.removeObject(forKey: accountKey)
        UserDefaults.standard.removeObject(forKey: codingPlanStatusKey)
        var settings = loadSettings()
        if settings.enabled {
            settings.enabled = false
            saveSettings(settings)
        }
        NotificationCenter.default.post(name: accountDidChangeNotification, object: nil)
        NotificationCenter.default.post(name: sessionDidChangeNotification, object: nil)
    }

    static func loadCodingPlanStatus() -> SomeIMCodingPlanStatus {
        guard let data = UserDefaults.standard.data(forKey: codingPlanStatusKey),
              let decoded = try? JSONDecoder().decode(SomeIMCodingPlanStatus.self, from: data) else {
            return .unknown
        }
        return decoded
    }

    static func saveCodingPlanStatus(_ status: SomeIMCodingPlanStatus) {
        if let data = try? JSONEncoder().encode(status) {
            UserDefaults.standard.set(data, forKey: codingPlanStatusKey)
        }
    }

    // MARK: - Shared session plumbing

    /// Loads the shared session (or a fresh empty one), applies `mutate`,
    /// reconciles the identity fields from local settings/account, and persists —
    /// but only if the result carries a real key.
    @discardableResult
    private static func updateSharedSession(_ mutate: (inout SomeIMSharedSession) -> Void) -> Bool {
        var session = currentSharedSession()
            ?? SomeIMSharedSession(apiKey: "", baseURL: loadSettings().baseURL)
        mutate(&session)
        session.baseURL = loadSettings().baseURL
        if let account = loadAccount() {
            if session.email.isEmpty { session.email = account.email }
            if session.tenantID == nil { session.tenantID = account.tenantID }
        }
        session.updatedAt = Date()
        guard session.isValid,
              persistSharedSession(session),
              currentSharedSession()?.apiKey == session.apiKey else {
            return false
        }
        return true
    }

    /// Pushes fresh email/tenant into an existing shared session. No-op when
    /// nobody is logged in (never resurrects a session from account data alone).
    private static func mirrorIdentityToShared(email: String, tenantID: String?) {
        guard var session = currentSharedSession() else { return }
        var changed = false
        if !email.isEmpty, session.email != email { session.email = email; changed = true }
        if let tenantID, session.tenantID != tenantID { session.tenantID = tenantID; changed = true }
        guard changed else { return }
        session.updatedAt = Date()
        persistSharedSession(session)
    }

    private static func currentSharedSession() -> SomeIMSharedSession? {
        #if DEBUG
        if testSharedSessionOverrideEnabled {
            return testSharedSessionOverride
        }
        #endif
        return SomeIMSharedSessionStore.shared.current()
    }

    @discardableResult
    private static func persistSharedSession(_ session: SomeIMSharedSession) -> Bool {
        #if DEBUG
        if testSharedSessionOverrideEnabled {
            testSharedSessionOverride = session
            NotificationCenter.default.post(name: sessionDidChangeNotification, object: nil)
            return true
        }
        #endif
        return SomeIMSharedSessionStore.shared.login(session)
    }

    #if DEBUG
    static func _setTestSharedSessionOverride(enabled: Bool, session: SomeIMSharedSession? = nil) {
        testSharedSessionOverrideEnabled = enabled
        testSharedSessionOverride = session
    }
    #endif

    /// One-time move of legacy per-app Keychain credentials into the shared
    /// store. Runs at most once per process; only marks itself permanently done
    /// (and deletes the legacy items) once the shared copy is verifiably readable
    /// back — so an unsigned dev build that can't reach the access group keeps
    /// the legacy items and retries on the next signed launch.
    private static func migrateLegacyIfNeeded() {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        if migrationAttempted { return }
        migrationAttempted = true

        let defaults = UserDefaults.standard
        if defaults.bool(forKey: migrationDoneKey) { return }
        if SomeIMSharedSessionStore.shared.current() != nil {
            defaults.set(true, forKey: migrationDoneKey)
            return
        }
        let legacyKey = AgentCredentialStore.load(account: legacyAPIKeyAccount)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyKey.isEmpty else {
            defaults.set(true, forKey: migrationDoneKey)
            return
        }
        let legacyToken = AgentCredentialStore.load(account: legacySessionTokenAccount)
        let account = loadAccount()
        let migrated = SomeIMSharedSession(
            apiKey: legacyKey,
            sessionToken: legacyToken,
            email: account?.email ?? "",
            tenantID: account?.tenantID,
            baseURL: loadSettings().baseURL
        )
        let ok = SomeIMSharedSessionStore.shared.login(migrated)
        if ok, SomeIMSharedSessionStore.shared.current()?.apiKey == legacyKey {
            AgentCredentialStore.save("", account: legacyAPIKeyAccount)
            AgentCredentialStore.save("", account: legacySessionTokenAccount)
            defaults.set(true, forKey: migrationDoneKey)
        }
    }

    static func loadClientLoginSecret() -> String {
        let env = ProcessInfo.processInfo.environment["WILLDEEP_CLIENT_LOGIN_SECRET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !env.isEmpty { return env }
        let generated = SomeIMGeneratedClientLoginSecret.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !generated.isEmpty { return generated }
        let info = (Bundle.main.object(forInfoDictionaryKey: "WillDeepSomeIMClientLoginSecret") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if info.hasPrefix("$(") { return "" }
        return info
    }

    static var clientLoginSecretConfigured: Bool {
        !loadClientLoginSecret().isEmpty
    }

    static var isConfigured: Bool {
        loadSettings().enabled && !loadAPIKey().isEmpty
    }
}

struct SomeIMAccount: Codable, Equatable {
    var email: String
    var tenantID: String?
    var balanceUSD: String
    var credits: String
    var creditsPerUSD: Int
    var defaultModel: String
    var lastUpdatedAt: Date

    nonisolated var displayCredits: String {
        guard let value = Int64(credits) else { return credits }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    nonisolated var compactDisplayCredits: String {
        Self.compactCredits(credits) ?? displayCredits
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
    private static let browserControlOrigin = "https://some.im"

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
        let endpoint = try publicAPIEndpoint(from: browserControlOrigin, suffix: "public/client-location")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        let data = try await send(request, session: session)
        let decoded = try decodeEnvelope(ClientLocationData.self, from: data)
        return SomeIMRelayRegion.automaticBaseURL(for: decoded.country)
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
        let account = accountData.account(
            fallbackEmail: "",
            fallbackModel: decoded.default_model?.nonEmpty ?? SomeIMIntegrationSettings.defaultTextModel
        )
        var nextSettings = normalized
        nextSettings.enabled = true
        guard SomeIMIntegrationStore.saveAuthenticatedSession(
            apiKey: apiKey,
            sessionToken: decoded.token,
            account: account,
            settings: nextSettings
        ) else {
            return SomeIMBrowserLoginStatus(state: .connected, account: nil)
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
        settings: SomeIMIntegrationSettings,
        session: URLSession
    ) async throws {
        let endpoint = try publicAPIEndpoint(from: settings.normalized.baseURL, suffix: "public/client-login/email/send")
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
        let endpoint = try publicAPIEndpoint(from: normalized.baseURL, suffix: "public/client-login/email/verify")
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
        )
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
        let balance = decoded.balance.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = SomeIMAccount(
            email: previous?.email ?? "",
            tenantID: decoded.tenant_id.nonEmpty ?? previous?.tenantID,
            balanceUSD: balance,
            credits: credits(fromUSD: balance),
            creditsPerUSD: 100000,
            defaultModel: previous?.defaultModel ?? SomeIMIntegrationSettings.defaultTextModel,
            lastUpdatedAt: Date()
        )
        SomeIMIntegrationStore.saveAccount(account)
        return account
    }

    static func fetchHandoffLoginURL() async throws -> URL {
        try await fetchHandoffLoginURL(
            settings: SomeIMIntegrationStore.loadSettings(),
            sessionToken: SomeIMIntegrationStore.loadSessionToken(),
            session: AgentNetworkSupport.defaultSession()
        )
    }

    static func fetchHandoffLoginURL(
        settings: SomeIMIntegrationSettings,
        sessionToken: String,
        session: URLSession
    ) async throws -> URL {
        let token = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw AgentToolError.invalidArgument("some.im session token is missing. Reconnect your account.")
        }
        let endpoint = try publicAPIEndpoint(from: settings.normalized.baseURL, suffix: "public/client-login/handoff-link")
        var request = jsonRequest(url: endpoint, method: "POST")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        applyClientLoginSecret(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["next": "/customer"], options: [.sortedKeys])
        let data = try await send(request, session: session)
        let decoded = try decodeEnvelope(HandoffLinkData.self, from: data)
        guard let url = URL(string: decoded.login_url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw AgentToolError.invalidArgument("some.im returned an invalid login URL.")
        }
        return url
    }

    static func fetchCodingPlanStatus() async throws -> SomeIMCodingPlanStatus {
        try await fetchCodingPlanStatus(
            settings: SomeIMIntegrationStore.loadSettings(),
            sessionToken: SomeIMIntegrationStore.loadSessionToken(),
            session: AgentNetworkSupport.defaultSession()
        )
    }

    static func fetchCodingPlanStatus(
        settings: SomeIMIntegrationSettings,
        sessionToken: String,
        session: URLSession
    ) async throws -> SomeIMCodingPlanStatus {
        let token = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return SomeIMCodingPlanStatus(
                hasActivePlan: false,
                planID: nil,
                planName: nil,
                periodEnd: nil,
                checkedAt: Date()
            )
        }
        let endpoint = try publicAPIEndpoint(from: settings.normalized.baseURL, suffix: "customer/plan/subscription")
        var request = jsonRequest(url: endpoint, method: "GET")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await send(request, session: session)
        let decoded = try decodeEnvelope(CodingPlanSubscriptionData.self, from: data)
        guard let subscription = decoded.subscription else {
            return SomeIMCodingPlanStatus(
                hasActivePlan: false,
                planID: nil,
                planName: nil,
                periodEnd: nil,
                checkedAt: Date()
            )
        }
        return SomeIMCodingPlanStatus(
            hasActivePlan: subscription.status.lowercased() == "active",
            planID: subscription.plan_id.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            planName: (subscription.plan_display_name ?? subscription.plan_name).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            periodEnd: parseRFC3339Date(subscription.period_end),
            checkedAt: Date()
        )
    }

    static func fetchModels(
        settings: SomeIMIntegrationSettings,
        apiKey: String,
        session: URLSession
    ) async throws -> [SomeIMModel] {
        do {
            let models = try await fetchPricingModels(settings: settings.normalized, apiKey: apiKey, session: session)
            if !models.isEmpty { return models }
        } catch {
            // Fall through to OpenAI-compatible /models below. some.im
            // deployments may expose only one of these endpoints.
        }
        return try await fetchOpenAIModels(settings: settings.normalized, apiKey: apiKey, session: session)
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
        outputDirectory: URL? = nil
    ) async throws -> SomeIMGeneratedImage {
        try await generateImage(
            prompt: prompt,
            size: size,
            model: overrideModel,
            outputDirectory: outputDirectory,
            settings: SomeIMIntegrationStore.loadSettings(),
            apiKey: SomeIMIntegrationStore.loadAPIKey(),
            session: AgentNetworkSupport.defaultSession()
        )
    }

    static func generateImage(
        prompt: String,
        size: String,
        model overrideModel: String?,
        outputDirectory: URL?,
        settings: SomeIMIntegrationSettings,
        apiKey: String,
        session: URLSession
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
        let body: [String: Any] = [
            "model": model,
            "prompt": trimmedPrompt,
            "size": size,
            "response_format": "b64_json"
        ]
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
            SomeIMModel(model: item.model, kinds: item.detectedKinds, isHot: item.is_hot ?? false, isNew: item.is_new ?? false)
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
        guard var components = URLComponents(url: try publicAPIEndpoint(from: browserControlOrigin, suffix: "public/client-login/browser-status"), resolvingAgainstBaseURL: false) else {
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
        guard var components = URLComponents(string: browserControlOrigin) else {
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

    private struct CodingPlanSubscriptionData: Decodable {
        let subscription: CodingPlanSubscription?
    }

    private struct ClientLocationData: Decodable {
        let country: String?
    }

    private struct CodingPlanSubscription: Decodable {
        let plan_id: String
        let plan_name: String
        let plan_display_name: String?
        let period_end: String
        let status: String
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
            tenant_id = try container.decodeFirstString(for: [.tenantID, .tenantIDCamel, .tenantIdCamel])
            balance_usd = try container.decodeFirstString(for: [.balanceUSD, .balanceUSDCamel, .balanceUSDCamelAlt, .balance])
            credits = try container.decodeFirstString(for: [.credits, .creditBalance, .creditBalanceCamel])
            credits_per_usd = try container.decodeFirstInt(for: [.creditsPerUSD, .creditsPerUSDCamel, .creditsPerUSDCamelAlt])
            default_model = try container.decodeFirstString(for: [.defaultModel, .defaultModelCamel])
        }

        static let empty = AccountData(
            email: nil,
            tenantID: nil,
            balanceUSD: nil,
            credits: nil,
            creditsPerUSD: nil,
            defaultModel: nil
        )

        init(
            email: String?,
            tenantID: String?,
            balanceUSD: String?,
            credits: String?,
            creditsPerUSD: Int?,
            defaultModel: String?
        ) {
            self.email = email
            self.tenant_id = tenantID
            self.balance_usd = balanceUSD
            self.credits = credits
            self.credits_per_usd = creditsPerUSD
            self.default_model = defaultModel
        }

        var hasAnyAccountInfo: Bool {
            [email, tenant_id, balance_usd, credits, default_model].contains { value in
                !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            } || credits_per_usd != nil
        }

        func account(fallbackEmail: String, fallbackModel: String) -> SomeIMAccount {
            let balance = balance_usd?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "0"
            return SomeIMAccount(
                email: email?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? fallbackEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                tenantID: tenant_id?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                balanceUSD: balance,
                credits: credits?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? SomeIMClient.credits(fromUSD: balance),
                creditsPerUSD: credits_per_usd ?? 100000,
                defaultModel: default_model?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? fallbackModel,
                lastUpdatedAt: Date()
            )
        }
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
    }

    private struct HandoffLinkData: Decodable {
        let login_url: String
        let expires_in: Int?
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

struct SomeIMIntegrationSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settingsNavigation = EditorSettingsNavigation.shared
    @State private var settings = SomeIMIntegrationStore.loadSettings()
    @State private var apiKey = SomeIMIntegrationStore.loadAPIKey()
    @State private var account = SomeIMIntegrationStore.loadAccount()
    @State private var fetchedModels: [SomeIMModel] = []
    @State private var isFetching = false
    @State private var isRefreshingBalance = false
    @State private var browserLoginRequest: SomeIMBrowserLoginRequest?
    @State private var browserLoginWatcher: Task<Void, Never>?
    @State private var isWatchingBrowserLogin = false
    @State private var browserLoginLastError: String?
    @State private var handledBrowserLoginAutogenerateRequestID: UUID?
    @State private var status = ""
    @State private var showLogoutConfirm = false

    private var imageModels: [SomeIMModel] {
        fetchedModels.filter(\.supportsImageGeneration)
    }

    private var videoModels: [SomeIMModel] {
        fetchedModels.filter(\.supportsVideoGeneration)
    }

    var body: some View {
        Form {
            Section(L10n.Settings.SomeIM.browserLoginSection) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.Settings.SomeIM.browserLoginDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let account {
                        ConnectorUnavailablePlaceholder(
                            title: L10n.Settings.SomeIM.browserLoginConnectedTitle,
                            systemImage: "checkmark.circle",
                            description: L10n.Settings.SomeIM.browserLoginConnectedDescription(account.email)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: isWatchingBrowserLogin ? "person.badge.clock" : "safari")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(.tint)
                                .frame(width: 32, height: 32)

                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.Settings.SomeIM.browserLoginPlaceholderTitle)
                                    .font(.headline)
                                Text(L10n.Settings.SomeIM.browserLoginPlaceholderDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 6) {
                                    if isWatchingBrowserLogin {
                                        ProgressView()
                                            .scaleEffect(0.6)
                                            .controlSize(.small)
                                    }
                                    Text(browserLoginStatusText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    HStack {
                        Button(L10n.Settings.SomeIM.openBrowserLoginLink) {
                            openBrowserLoginLink()
                        }
                        .disabled(account != nil)
                    }
                }
            }

            Section(L10n.Settings.SomeIM.accountSection) {
                if let account {
                    LabeledContent(L10n.Settings.SomeIM.accountConnected) {
                        Text(L10n.Settings.SomeIM.accountSummary(account.email, account.compactDisplayCredits))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(L10n.Settings.SomeIM.defaultModelLabel) {
                        Text(account.defaultModel)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(isRefreshingBalance ? L10n.Settings.SomeIM.fetchingModels : L10n.Settings.SomeIM.refreshBalance) {
                            refreshBalance()
                        }
                        .disabled(isRefreshingBalance)
                        Button(L10n.Settings.SomeIM.openSomeIM) {
                            openSomeIM()
                        }
                        Spacer()
                        Button(L10n.Settings.SomeIM.logout, role: .destructive) {
                            showLogoutConfirm = true
                        }
                    }
                    .confirmationDialog(
                        L10n.Settings.SomeIM.logoutConfirmTitle,
                        isPresented: $showLogoutConfirm,
                        titleVisibility: .visible
                    ) {
                        Button(L10n.Settings.SomeIM.logout, role: .destructive) {
                            performLogout()
                        }
                        Button(L10n.Settings.SomeIM.logoutCancel, role: .cancel) {}
                    } message: {
                        Text(L10n.Settings.SomeIM.logoutConfirmMessage)
                    }
                } else {
                    Text(L10n.Settings.SomeIM.accountNotConnected)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.Settings.SomeIM.imageSection) {
                modelPicker(
                    L10n.Settings.SomeIM.imageModelLabel,
                    selection: $settings.preferredImageModel,
                    candidates: imageModels,
                    fallbackModels: settings.preferredImageModels
                )
                TextField(L10n.Settings.SomeIM.priorityPlaceholder, text: priorityImageModelsBinding)
                    .textFieldStyle(.roundedBorder)
                Text(L10n.Settings.SomeIM.imageHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Settings.SomeIM.videoSection) {
                modelPicker(
                    L10n.Settings.SomeIM.videoModelLabel,
                    selection: $settings.preferredVideoModel,
                    candidates: videoModels,
                    fallbackModels: settings.preferredVideoModels
                )
                TextField(L10n.Settings.SomeIM.priorityPlaceholder, text: priorityVideoModelsBinding)
                    .textFieldStyle(.roundedBorder)
                Text(L10n.Settings.SomeIM.videoHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            ensureBrowserLoginRequestIfNeeded()
        }
        .task {
            await appState.refreshSomeIMRelayRouting()
            reloadSharedSessionState()
            if !apiKey.isEmpty, fetchedModels.isEmpty {
                fetchModels()
            }
        }
        .onChange(of: settings) { updated in
            persistModelPreferences(updated)
        }
        .onReceive(NotificationCenter.default.publisher(for: SomeIMIntegrationStore.accountDidChangeNotification)) { _ in
            reloadSharedSessionState()
        }
        .onReceive(NotificationCenter.default.publisher(for: SomeIMIntegrationStore.sessionDidChangeNotification)) { _ in
            reloadSharedSessionState()
        }
        .onReceive(settingsNavigation.$someIMBrowserLoginAutogenerateRequestID) { _ in
            consumeBrowserLoginAutogenerateRequestIfNeeded()
        }
    }

    private var browserLoginStatusText: String {
        guard browserLoginRequest != nil else { return status }
        if let browserLoginLastError, !browserLoginLastError.isEmpty {
            return browserLoginLastError
        }
        if isWatchingBrowserLogin { return L10n.Settings.SomeIM.browserLoginWaiting }
        return status.isEmpty ? L10n.Settings.SomeIM.browserLoginReady : status
    }

    private func modelPicker(
        _ title: String,
        selection: Binding<String>,
        candidates: [SomeIMModel],
        fallbackModels: [String]
    ) -> some View {
        LabeledContent(title) {
            HStack {
                TextField("", text: selection)
                    .textFieldStyle(.roundedBorder)
                let ids = candidateIDs(candidates: candidates, fallbackModels: fallbackModels)
                if !ids.isEmpty {
                    Picker("", selection: selection) {
                        ForEach(ids, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
        }
    }

    private func candidateIDs(candidates: [SomeIMModel], fallbackModels: [String]) -> [String] {
        var seen = Set<String>()
        return (candidates.map(\.model) + fallbackModels)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private var priorityImageModelsBinding: Binding<String> {
        Binding {
            settings.preferredImageModels.joined(separator: ", ")
        } set: { value in
            settings.preferredImageModels = splitPriorityModels(value)
            if settings.preferredImageModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let first = settings.preferredImageModels.first {
                settings.preferredImageModel = first
            }
        }
    }

    private var priorityVideoModelsBinding: Binding<String> {
        Binding {
            settings.preferredVideoModels.joined(separator: ", ")
        } set: { value in
            settings.preferredVideoModels = splitPriorityModels(value)
            if settings.preferredVideoModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let first = settings.preferredVideoModels.first {
                settings.preferredVideoModel = first
            }
        }
    }

    private func splitPriorityModels(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func persistModelPreferences(_ updated: SomeIMIntegrationSettings) {
        let normalized = updated.normalized
        SomeIMIntegrationStore.saveSettings(normalized)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        appState.syncSomeIMProvider(settings: normalized, apiKey: trimmedKey, activate: false)
    }

    private func reloadSharedSessionState() {
        let latestSettings = SomeIMIntegrationStore.loadSettings()
        let latestAPIKey = SomeIMIntegrationStore.loadAPIKey()
        settings = latestSettings
        apiKey = latestAPIKey
        account = SomeIMIntegrationStore.loadAccount()
        guard !latestAPIKey.isEmpty else { return }
        appState.syncSomeIMProvider(settings: latestSettings, apiKey: latestAPIKey)
        appState.syncSomeIMImageUnderstanding(apiKey: latestAPIKey)
    }

    private func prepareBrowserLoginRequest(openInBrowser: Bool) {
        guard SomeIMIntegrationStore.clientLoginSecretConfigured else {
            status = L10n.Settings.SomeIM.browserLoginClientSecretMissing
            return
        }
        do {
            let request = try SomeIMClient.makeBrowserLoginRequest(settings: settings.normalized)
            browserLoginRequest = request
            browserLoginLastError = nil
            status = L10n.Settings.SomeIM.browserLoginReady
            startBrowserLoginWatcher(for: request)
            if openInBrowser {
                _ = NSWorkspace.shared.open(request.url)
                status = L10n.Settings.SomeIM.browserLoginOpened
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func consumeBrowserLoginAutogenerateRequestIfNeeded() {
        guard let requestID = settingsNavigation.someIMBrowserLoginAutogenerateRequestID,
              handledBrowserLoginAutogenerateRequestID != requestID else {
            return
        }
        handledBrowserLoginAutogenerateRequestID = requestID
        ensureBrowserLoginRequestIfNeeded()
    }

    private func ensureBrowserLoginRequestIfNeeded() {
        guard account == nil else { return }
        guard SomeIMIntegrationStore.clientLoginSecretConfigured else {
            status = L10n.Settings.SomeIM.browserLoginClientSecretMissing
            return
        }
        if let request = browserLoginRequest {
            if !isWatchingBrowserLogin {
                startBrowserLoginWatcher(for: request)
            }
        } else {
            prepareBrowserLoginRequest(openInBrowser: false)
        }
    }

    private func openBrowserLoginLink() {
        guard SomeIMIntegrationStore.clientLoginSecretConfigured else {
            status = L10n.Settings.SomeIM.browserLoginClientSecretMissing
            return
        }
        if let request = browserLoginRequest {
            if !isWatchingBrowserLogin {
                startBrowserLoginWatcher(for: request)
            }
            _ = NSWorkspace.shared.open(request.url)
            status = L10n.Settings.SomeIM.browserLoginOpened
        } else {
            prepareBrowserLoginRequest(openInBrowser: true)
        }
    }

    private func startBrowserLoginWatcher(for loginRequest: SomeIMBrowserLoginRequest) {
        stopBrowserLoginWatcher()
        isWatchingBrowserLogin = true
        browserLoginLastError = nil
        status = L10n.Settings.SomeIM.browserLoginWaiting
        let currentSettings = settings.normalized
        browserLoginWatcher = Task {
            let deadline = Date().addingTimeInterval(10 * 60)
            var lastError: String?
            while !Task.isCancelled, Date() < deadline {
                do {
                    let result = try await SomeIMClient.checkBrowserLoginStatus(request: loginRequest, settings: currentSettings)
                    if lastError != nil {
                        lastError = nil
                        await MainActor.run {
                            guard browserLoginRequest?.code == loginRequest.code else { return }
                            browserLoginLastError = nil
                        }
                    }
                    if result.state == .connected, let linked = result.account {
                        await MainActor.run {
                            reloadSharedSessionState()
                            account = SomeIMIntegrationStore.loadAccount() ?? linked
                            browserLoginRequest = nil
                            isWatchingBrowserLogin = false
                            status = L10n.Settings.SomeIM.browserLoginConnected
                        }
                        return
                    }
                    if result.state == .connected {
                        await MainActor.run {
                            // some.im 认为浏览器已登录，却没回 WillDeep 可识别的 API Key。
                            // 必须丢弃这个已被服务端标记为 connected 的一次性 code，否则下次点
                            // 「在浏览器打开」会复用它、被秒回同一条错误。清空后再点会自动 mint 新 code。
                            browserLoginRequest = nil
                            isWatchingBrowserLogin = false
                            status = L10n.Settings.SomeIM.browserLoginMissingCredentials
                        }
                        return
                    }
                    if result.state == .expired {
                        await MainActor.run {
                            browserLoginRequest = nil
                            isWatchingBrowserLogin = false
                            status = L10n.Settings.SomeIM.browserLoginExpired
                        }
                        return
                    }
                } catch {
                    lastError = error.localizedDescription
                    await MainActor.run {
                        guard browserLoginRequest?.code == loginRequest.code else { return }
                        browserLoginLastError = "浏览器登录状态查询失败：\(error.localizedDescription)"
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            await MainActor.run {
                browserLoginRequest = nil
                isWatchingBrowserLogin = false
                browserLoginLastError = nil
                status = lastError ?? L10n.Settings.SomeIM.browserLoginExpired
            }
        }
    }

    private func stopBrowserLoginWatcher() {
        browserLoginWatcher?.cancel()
        browserLoginWatcher = nil
        isWatchingBrowserLogin = false
    }

    private func refreshBalance() {
        isRefreshingBalance = true
        status = ""
        Task {
            let result: Result<SomeIMAccount, Error>
            do {
                result = .success(try await SomeIMClient.fetchAccountBalance())
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                isRefreshingBalance = false
                switch result {
                case .success(let refreshed):
                    account = refreshed
                    status = L10n.Settings.savedStatus
                case .failure(let error):
                    status = error.localizedDescription
                }
            }
        }
    }

    private func performLogout() {
        // Clears the shared session (broadcasting to every app on this Mac) and
        // this app's local caches. The AppState observer also drops the agent
        // provider off the sessionDidChange broadcast; do it here too for an
        // immediate, in-view response.
        SomeIMIntegrationStore.logout()
        appState.clearSomeIMProvider()
        account = nil
        apiKey = ""
        settings.enabled = false
        status = L10n.Settings.SomeIM.loggedOut
    }

    private func openSomeIM() {
        Task {
            do {
                let url = try await SomeIMClient.fetchHandoffLoginURL()
                await MainActor.run {
                    _ = NSWorkspace.shared.open(url)
                }
            } catch {
                await MainActor.run {
                    status = error.localizedDescription
                }
            }
        }
    }

    private func fetchModels() {
        isFetching = true
        status = ""
        let currentSettings = settings.normalized
        let currentKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let result: Result<[SomeIMModel], Error>
            do {
                result = .success(try await SomeIMClient.fetchModels(settings: currentSettings, apiKey: currentKey))
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                isFetching = false
                switch result {
                case .success(let models):
                    fetchedModels = models
                    appState.recordFetchedAgentModelDiscoveries(models.map(\.agentDiscovery))
                    adoptFetchedDefaults(models)
                    status = L10n.Settings.SomeIM.fetchedModels("\(models.count)")
                case .failure(let error):
                    fetchedModels = []
                    status = error.localizedDescription
                }
            }
        }
    }

    private func adoptFetchedDefaults(_ models: [SomeIMModel]) {
        let imageIDs = models.filter(\.supportsImageGeneration).map(\.model)
        let videoIDs = models.filter(\.supportsVideoGeneration).map(\.model)
        if let gptImage = imageIDs.first(where: { $0 == SomeIMIntegrationSettings.defaultImageModel }) {
            settings.preferredImageModel = gptImage
        } else if settings.preferredImageModel.isEmpty, let first = imageIDs.first {
            settings.preferredImageModel = first
        }
        settings.preferredImageModels = mergePriority(primary: settings.preferredImageModel, existing: settings.preferredImageModels, fetched: imageIDs)
        if settings.preferredVideoModel.isEmpty, let first = videoIDs.first {
            settings.preferredVideoModel = first
        }
        settings.preferredVideoModels = mergePriority(primary: settings.preferredVideoModel, existing: settings.preferredVideoModels, fetched: videoIDs)
    }

    private func mergePriority(primary: String, existing: [String], fetched: [String]) -> [String] {
        var seen = Set<String>()
        return ([primary] + existing + fetched)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
