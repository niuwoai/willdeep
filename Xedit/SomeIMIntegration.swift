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

enum SomeIMCodingPlanRefreshFailure: Equatable {
    case authenticationRequired
    case unavailable

    static func classify(_ error: Error) -> SomeIMCodingPlanRefreshFailure? {
        if error is CancellationError {
            return nil
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return nil
            case .userAuthenticationRequired:
                return .authenticationRequired
            default:
                return .unavailable
            }
        }
        if let toolError = error as? AgentToolError,
           case .httpFailed(let status, _) = toolError,
           status == 401 || status == 403 {
            return .authenticationRequired
        }
        return .unavailable
    }
}

struct SomeIMIntegrationSettings: Codable, Equatable {
    static let defaultBaseURL = SomeIMRelayRegion.internationalBaseURL
    static let defaultImageModel = "gpt-image-2"
    static let defaultVideoModel = "seedance-2.0"
    /// New sessions open on the M tier (256K), not the L tier.
    ///
    /// This used to be `deepseek-v4-flash` — a 1M-context model — which made
    /// the scarcest tier the default one. Every "escalate to deep only when
    /// the work cannot be bounded" rule downstream was then arguing about a
    /// door that was already open: there was nothing to escalate *to*.
    /// See docs/SMALL_MODEL_FIRST_RUNTIME_PLAN.md §4 step 1.
    ///
    /// Only new sessions are affected. A session that carries an explicit
    /// model override keeps it, so nobody's running work changes underfoot.
    static let defaultTextModel = "glm-5"
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

/// Holds one lazily-loaded shared session until something explicitly drops it.
///
/// Split out of `SomeIMIntegrationStore` so the caching rules are testable
/// without a Keychain: the real loader is a synchronous `securityd` round trip
/// that unit tests must never touch (it would read the developer's actual
/// some.im login), so tests exercise this type with a counting stub instead.
///
/// "Nobody is logged in" is a cacheable answer, hence `loaded` is tracked
/// separately from the value rather than leaning on `value == nil`.
final class SomeIMSharedSessionMemo {
    private var loaded = false
    private var cached: SomeIMSharedSession?
    /// Number of times the loader actually ran. Exists for tests to assert the
    /// Keychain is not being re-read on every access.
    private(set) var loadCount = 0

    func value(loading load: () -> SomeIMSharedSession?) -> SomeIMSharedSession? {
        if loaded { return cached }
        cached = load()
        loaded = true
        loadCount += 1
        return cached
    }

    func invalidate() {
        loaded = false
        cached = nil
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

    /// Unified-logging channel for credential persistence. Visible in Console.app
    /// or `log stream --predicate 'subsystem == "com.willdeep.agent"'`. Exists to
    /// tell apart the two ways browser-login credential save can fail: the write
    /// itself (shared access group rejected *and* per-app fallback errored) versus
    /// the post-write readback not matching what we just stored.
    private static let keychainLog = Logger(subsystem: "com.willdeep.agent", category: "someim-keychain")

    private static let settingsKey = "com.willdeep.someIM.integrationSettings.v1"
    private static let accountKey = "com.willdeep.someIM.account.v1"
    private static let codingPlanStatusKey = "com.willdeep.someIM.codingPlanStatus.v1"
    // Per-app Keychain accounts. They were originally legacy migration inputs;
    // now they also act as the local fallback when the shared access group is
    // unavailable or the user's Keychain ACL rejects the shared write.
    private static let legacyAPIKeyAccount = "some-im/api-key"
    private static let legacySessionTokenAccount = "some-im/customer-session"
    private static let migrationDoneKey = "com.willdeep.someIM.sharedSessionMigration.v1"

    private static let migrationLock = NSLock()
    private nonisolated(unsafe) static var migrationAttempted = false
    private nonisolated(unsafe) static var sessionObservation: ObservationToken?

    // Memoized `currentSharedSession()`. Reading the real thing is a
    // `SecItemCopyMatching` — a synchronous XPC round trip to `securityd` — and
    // every caller is on the main thread: the mobile-gateway peer re-reads it
    // every 400ms in `publishSnapshot()`, and the model picker re-reads it on
    // each menu refresh. A 5s main-thread sample of 1.228.0-rc10 found 89
    // samples parked in `SharedKeychain.read` for no new information.
    private nonisolated(unsafe) static let sharedSessionMemo = SomeIMSharedSessionMemo()
    #if DEBUG
    private nonisolated(unsafe) static var testSharedSessionOverrideEnabled = false
    private nonisolated(unsafe) static var testSharedSessionOverride: SomeIMSharedSession?
    private nonisolated(unsafe) static var testSharedSessionPersistFailureEnabled = false
    private nonisolated(unsafe) static var testPrivateFallbackPersistFailureEnabled = false
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
            // other app. Drop the memoized session first — the observers this
            // fans out to immediately re-read it, and for a change made by
            // *another* app this is the only signal we get.
            invalidateSharedSessionCache()
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
        // `privateKeychainFallbackSession()` folds `baseURL` into the session it
        // synthesizes, so a settings change can invalidate a memoized session
        // even though no credential moved.
        invalidateSharedSessionCache()
    }

    static func loadAccount() -> SomeIMAccount? {
        guard let data = UserDefaults.standard.data(forKey: accountKey) else { return nil }
        return try? JSONDecoder().decode(SomeIMAccount.self, from: data)
    }

    /// The account object is a display cache, not proof of authentication.
    /// Only expose it as a signed-in account while the shared session still
    /// carries a usable API key. This prevents a stale UserDefaults snapshot
    /// from making the sidebar claim the user is logged in after Keychain
    /// access was lost or the shared session was cleared elsewhere.
    static func loadAuthenticatedAccount() -> SomeIMAccount? {
        loadAuthenticationSnapshot().account
    }

    static func loadAuthenticationSnapshot() -> SomeIMAuthenticationSnapshot {
        authenticationSnapshot(cachedAccount: loadAccount(), apiKey: loadAPIKey())
    }

    nonisolated static func authenticationSnapshot(
        cachedAccount: SomeIMAccount?,
        apiKey: String
    ) -> SomeIMAuthenticationSnapshot {
        SomeIMAuthenticationSnapshot(cachedAccount: cachedAccount, apiKey: apiKey)
    }

    nonisolated static func authenticatedAccount(
        cachedAccount: SomeIMAccount?,
        apiKey: String
    ) -> SomeIMAccount? {
        authenticationSnapshot(cachedAccount: cachedAccount, apiKey: apiKey).account
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
        // Same reason as `saveSettings`: the fallback session borrows email and
        // tenant from the account cache.
        invalidateSharedSessionCache()
        NotificationCenter.default.post(name: accountDidChangeNotification, object: nil)
    }

    /// 合并 AI 响应头携带的余额快照。严格要求服务端时间点递增；同一时间或旧时间
    /// 都不落盘，从根上阻止并发响应、边缘旧快照把新 credits 覆盖掉。
    @discardableResult
    static func applyCreditsSnapshot(_ snapshot: SomeIMCreditsSnapshot) -> Bool {
        guard let current = loadAccount(),
              let updated = snapshot.applying(to: current) else {
            return false
        }
        saveAccount(updated)
        return true
    }

    /// 手动/兜底刷新也走同一时间顺序。新服务端会返回版本；旧服务端没有版本时，
    /// 若本地已经持有版本化快照，只更新身份字段并保留较新的 credits。
    @discardableResult
    static func saveRefreshedAccount(_ incoming: SomeIMAccount) -> SomeIMAccount {
        guard let current = loadAccount() else {
            saveAccount(incoming)
            return incoming
        }
        let merged = mergedRefreshedAccount(incoming, current: current)
        saveAccount(merged)
        return merged
    }

    nonisolated static func mergedRefreshedAccount(_ incoming: SomeIMAccount, current: SomeIMAccount) -> SomeIMAccount {
        guard let currentVersion = current.creditsUpdatedAtMicros else {
            return incoming
        }
        if let incomingVersion = incoming.creditsUpdatedAtMicros, incomingVersion > currentVersion {
            return incoming
        }
        var merged = incoming
        merged.balanceUSD = current.balanceUSD
        merged.credits = current.credits
        merged.creditsPerUSD = current.creditsPerUSD
        merged.creditsUpdatedAtMicros = currentVersion
        return merged
    }

    // MARK: - Secrets (shared Keychain access group is the source of truth)

    static func loadAPIKey() -> String {
        #if DEBUG
        if testSharedSessionOverrideEnabled {
            return currentSharedSession()?.apiKey ?? ""
        }
        #endif
        migrateLegacyIfNeeded()
        return currentSharedSession()?.apiKey ?? ""
    }

    /// Deterministic login gate for automatic UI defaults. Unit tests must
    /// explicitly opt into the shared-session override so a developer's real
    /// some.im login can never influence session-default tests.
    static func hasAuthenticatedSessionForAutomaticDefaults() -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
           !testSharedSessionOverrideEnabled {
            return false
        }
        #endif
        return !loadAPIKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            return currentSharedSession()?.sessionToken ?? ""
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
        guard session.isValid else {
            keychainLog.error("saveAuthenticatedSession failed: assembled session invalid before persist (apiKey empty=\(trimmedKey.isEmpty, privacy: .public), baseURL empty=\(session.baseURL.isEmpty, privacy: .public))")
            return false
        }
        guard persistSharedSession(session) else {
            // persistSharedSession already logged which store(s) rejected the
            // write and the OSStatus; this is the "写失败" bucket.
            keychainLog.error("saveAuthenticatedSession failed: write did not land in any Keychain store")
            return false
        }
        let readBackKey = currentSharedSession()?.apiKey ?? ""
        guard readBackKey == trimmedKey else {
            // Write reported success but what we read back differs — the "回读不
            // 一致" bucket (e.g. shared group wrote but reads nil, or a stale
            // per-app row shadowed the fresh value).
            keychainLog.error("saveAuthenticatedSession failed: readback mismatch — wrote \(maskedKey(trimmedKey), privacy: .public), read \(maskedKey(readBackKey), privacy: .public)")
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
        AgentCredentialStore.save("", account: legacyAPIKeyAccount)
        AgentCredentialStore.save("", account: legacySessionTokenAccount)
        // Both credential stores are now empty; a cache still holding the old
        // session would keep this app looking signed in.
        invalidateSharedSessionCache()
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

    /// Redacts a secret for logging — keeps only length and the last 4 chars, so
    /// logs can confirm "wrote the same value we read back" without leaking the key.
    private static func maskedKey(_ value: String) -> String {
        guard !value.isEmpty else { return "<empty>" }
        let suffix = value.count > 4 ? String(value.suffix(4)) : "****"
        return "len=\(value.count) …\(suffix)"
    }

    /// Human-readable name for the Keychain OSStatus codes we expect on a
    /// mis-signed / entitlement-less build, plus the system's own message.
    private static func keychainStatusDescription(_ status: OSStatus) -> String {
        let name: String
        switch status {
        case errSecSuccess: name = "success"
        case errSecMissingEntitlement: name = "errSecMissingEntitlement (build lacks keychain-access-groups / wrong Team)"
        case errSecItemNotFound: name = "errSecItemNotFound"
        case errSecDuplicateItem: name = "errSecDuplicateItem"
        case errSecAuthFailed: name = "errSecAuthFailed (Keychain locked or user denied)"
        case errSecInteractionNotAllowed: name = "errSecInteractionNotAllowed"
        case errSecNoAccessForItem: name = "errSecNoAccessForItem"
        default: name = "OSStatus \(status)"
        }
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "\(name) — \(message)"
        }
        return name
    }

    private static func currentSharedSession() -> SomeIMSharedSession? {
        #if DEBUG
        // The test override is deliberately never cached: unit tests set it
        // directly and expect the very next read to see the new value.
        if testSharedSessionOverrideEnabled {
            return testSharedSessionOverride ?? privateKeychainFallbackSession()
        }
        #endif
        return sharedSessionMemo.value {
            SomeIMSharedSessionStore.shared.current() ?? privateKeychainFallbackSession()
        }
    }

    /// Drops the memoized shared session so the next read hits the Keychain again.
    ///
    /// Every write path must call this *before* anything reads back, because
    /// `updateSharedSession` verifies its own write by re-reading the session
    /// and comparing keys — served from a stale cache that check would degrade
    /// into a tautology that always passes. Cross-app logins/logouts land here
    /// too, via the `SomeIMSharedSessionStore.observe` hook in
    /// `configureSharedSession()`.
    nonisolated static func invalidateSharedSessionCache() {
        sharedSessionMemo.invalidate()
    }

    @discardableResult
    private static func persistSharedSession(_ session: SomeIMSharedSession) -> Bool {
        // Invalidate up front, not after: callers verify the write by reading
        // the session back, and that read has to reach the Keychain. This one
        // call covers the shared-group write and the per-app fallback below.
        invalidateSharedSessionCache()
        #if DEBUG
        if testSharedSessionPersistFailureEnabled {
            return persistPrivateKeychainFallbackSession(session)
        }
        if testSharedSessionOverrideEnabled {
            testSharedSessionOverride = session
            NotificationCenter.default.post(name: sessionDidChangeNotification, object: nil)
            return true
        }
        #endif
        if SomeIMSharedSessionStore.shared.login(session) {
            return true
        }
        keychainLog.notice("shared-group Keychain write rejected (access group \(sharedAccessGroup, privacy: .public)) — likely errSecMissingEntitlement on an unsigned/mis-Teamed build; falling back to per-app Keychain")
        return persistPrivateKeychainFallbackSession(session)
    }

    private static func privateKeychainFallbackSession() -> SomeIMSharedSession? {
        let apiKey = AgentCredentialStore.load(account: legacyAPIKeyAccount)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return nil }
        let token = AgentCredentialStore.load(account: legacySessionTokenAccount)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let account = loadAccount()
        return SomeIMSharedSession(
            apiKey: apiKey,
            sessionToken: token,
            email: account?.email ?? "",
            tenantID: account?.tenantID,
            baseURL: loadSettings().baseURL
        )
    }

    @discardableResult
    private static func persistPrivateKeychainFallbackSession(_ session: SomeIMSharedSession) -> Bool {
        #if DEBUG
        if testPrivateFallbackPersistFailureEnabled {
            return false
        }
        #endif
        let apiKey = session.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return false }
        let status = AgentCredentialStore.saveReportingStatus(apiKey, account: legacyAPIKeyAccount)
        AgentCredentialStore.save(session.sessionToken, account: legacySessionTokenAccount)
        let readBack = AgentCredentialStore.load(account: legacyAPIKeyAccount)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let landed = readBack == apiKey
        if !landed {
            keychainLog.error("per-app Keychain fallback failed: SecItem write status \(keychainStatusDescription(status), privacy: .public); readback \(readBack.isEmpty ? "empty" : "mismatch", privacy: .public)")
        }
        return landed
    }

    #if DEBUG
    static func _setTestSharedSessionOverride(enabled: Bool, session: SomeIMSharedSession? = nil) {
        testSharedSessionOverrideEnabled = enabled
        testSharedSessionOverride = session
    }

    static func _setTestSharedAPIKeyWithoutNotification(_ apiKey: String) {
        testSharedSessionOverrideEnabled = true
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        testSharedSessionOverride = trimmed.isEmpty
            ? nil
            : SomeIMSharedSession(apiKey: trimmed, baseURL: loadSettings().baseURL)
    }

    static func _setTestSharedSessionPersistFailure(_ enabled: Bool) {
        testSharedSessionPersistFailureEnabled = enabled
    }

    static func _setTestPrivateFallbackPersistFailure(_ enabled: Bool) {
        testPrivateFallbackPersistFailureEnabled = enabled
    }
    #endif

    /// One-time move of legacy per-app Keychain credentials into the shared
    /// store. Runs at most once per process; only marks itself permanently done
    /// (and deletes the legacy items) once the shared copy is verifiably readable
    /// back — so an unsigned dev build that can't reach the access group keeps
    /// the legacy items and retries on the next signed launch.
    private static func migrateLegacyIfNeeded() {
        #if DEBUG
        if testSharedSessionOverrideEnabled { return }
        #endif
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
        // Migration moves credentials between the two stores that
        // `currentSharedSession()` reads, so whatever it memoized before this
        // point is stale either way.
        invalidateSharedSessionCache()
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

    static func fetchCodingPlanStatus() async throws -> SomeIMCodingPlanStatus {
        try await fetchCodingPlanStatus(
            settings: SomeIMIntegrationStore.loadSettings(),
            sessionToken: SomeIMIntegrationStore.loadSessionToken(),
            session: AgentNetworkSupport.defaultSession()
        )
    }

    static func fetchCodingPlanStatus(
        settings _: SomeIMIntegrationSettings,
        sessionToken: String,
        session: URLSession
    ) async throws -> SomeIMCodingPlanStatus {
        let token = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw URLError(.userAuthenticationRequired) }
        let endpoint = try publicAPIEndpoint(from: controlPlaneOrigin, suffix: "customer/plan/subscription")
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
            "size": size
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

    private struct CodingPlanSubscriptionData: Decodable {
        let subscription: CodingPlanSubscription?
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

struct SomeIMIntegrationSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settingsNavigation = EditorSettingsNavigation.shared
    @State private var settings = SomeIMIntegrationStore.loadSettings()
    @State private var apiKey = SomeIMIntegrationStore.loadAPIKey()
    @State private var account = SomeIMIntegrationStore.loadAuthenticatedAccount()
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
    @State private var defaultModelModePreference = AgentSettingsStore.loadDefaultModelModePreference()

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
                            description: L10n.Settings.SomeIM.browserLoginConnectedDescription(account.displayName)
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
                        Text(L10n.Settings.SomeIM.accountSummary(account.displayName, account.compactDisplayCredits))
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

            Section(L10n.Settings.SomeIM.newTabDefaultSection) {
                Picker(
                    L10n.Settings.SomeIM.newTabDefaultLabel,
                    selection: newTabDefaultUsesManagedRoutingBinding
                ) {
                    Text(L10n.Settings.SomeIM.newTabDefaultManaged).tag(true)
                    Text(L10n.Settings.SomeIM.newTabDefaultModel).tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(!isSomeIMAuthenticated)

                Text(newTabDefaultHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var isSomeIMAuthenticated: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var newTabDefaultUsesManagedRoutingBinding: Binding<Bool> {
        Binding {
            defaultModelModePreference.usesManagedRoutingForNewSessions
        } set: { enabled in
            let preference: AgentDefaultModelModePreference = enabled ? .managed : .explicitModel
            defaultModelModePreference = preference
            AgentSettingsStore.saveDefaultModelModePreference(preference)
        }
    }

    private var newTabDefaultHelp: String {
        guard isSomeIMAuthenticated else {
            return L10n.Settings.SomeIM.newTabDefaultLoginRequired
        }
        return defaultModelModePreference.usesManagedRoutingForNewSessions
            ? L10n.Settings.SomeIM.newTabDefaultManagedHelp
            : L10n.Settings.SomeIM.newTabDefaultModelHelp
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
        let authentication = SomeIMIntegrationStore.loadAuthenticationSnapshot()
        settings = latestSettings
        apiKey = authentication.apiKey
        account = authentication.account
        guard authentication.isAuthenticated else { return }
        appState.syncSomeIMProvider(settings: latestSettings, apiKey: authentication.apiKey)
        appState.syncSomeIMImageUnderstanding(apiKey: authentication.apiKey)
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
                            account = SomeIMIntegrationStore.loadAuthenticatedAccount() ?? linked
                            browserLoginRequest = nil
                            isWatchingBrowserLogin = false
                            status = L10n.Settings.SomeIM.browserLoginConnected
                        }
                        return
                    }
                    if result.state == .credentialSaveFailed {
                        await MainActor.run {
                            browserLoginRequest = nil
                            isWatchingBrowserLogin = false
                            status = L10n.Settings.SomeIM.browserLoginCredentialSaveFailed
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
        _ = NSWorkspace.shared.open(SomeIMClient.customerPortalURL)
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
