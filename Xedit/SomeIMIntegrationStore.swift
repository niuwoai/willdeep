//
//  SomeIMIntegrationStore.swift
//  WillDeep
//
//  some.im 集成的存储层：UserDefaults 里的设置、Keychain 里的凭据、
//  跨 App 共享会话的读取、写入与观察。
//
//  从 SomeIMIntegration.swift 抽出来：那个文件逼近 complexity_guard 的
//  3000 行硬上限，而存储层本来就自成一组（同一路数的先例见
//  SomeIMSharedSessionMemo.swift）。
//

import Foundation
import Security
import os
import SomeIMSharedSession

enum SomeIMIntegrationStore {
    // Plain immutable constants — `nonisolated` so they can be referenced from
    // the Sendable cross-app session-observer closure below without hopping
    // actors (the enum otherwise defaults to main-actor isolation).
    nonisolated static let accountDidChangeNotification = Notification.Name("com.willdeep.someIM.accountDidChange")
    /// Posted (local, same-process) whenever the shared some.im session changes
    /// — including changes made by *another* app. AppState listens to reconcile
    /// its agent provider so a cross-app login/logout takes effect live.
    nonisolated static let sessionDidChangeNotification = Notification.Name("com.willdeep.someIM.sessionDidChange")

    /// `userInfo` flag set to `true` only on the notification `logout()` posts.
    ///
    /// Observers must not infer a sign-out from an empty read alone: a read can
    /// come back empty because the Keychain lost a race with a write, and the
    /// reconcile that follows destroys the provider entry. This flag marks the
    /// one case where empty is the *expected* answer and destroying it is right.
    nonisolated static let signOutUserInfoKey = "com.willdeep.someIM.sessionDidChange.signOut"

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
    private nonisolated(unsafe) static var testSessionReadOutcome: SomeIMSessionReadOutcome?
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

    /// The API key for unattended paths that must not stall on a transient
    /// Keychain read failure — today the tool-approval safety judge.
    ///
    /// `loadAPIKey()` returns "" for both `.signedOut` and `.unavailable`, and
    /// the judge cannot tell them apart. That cost real user friction: one
    /// unreadable moment made the judge conclude "not signed in", fall through
    /// to the session provider (which had no key of its own), find no usable
    /// candidate at all, and hand the command to the user for manual approval.
    /// Audit data for August 2026 shows 211 such calls logged as
    /// `missing api key` — every one of them a confirmation dialog the user
    /// should never have seen, interleaved with successful guard verdicts
    /// minutes apart on the same day.
    ///
    /// So this reads through the same memo, and only when the read itself did
    /// not land does it fall back to the last session an actual read produced.
    /// A confirmed sign-out still returns "" — being signed out is an answer,
    /// and this must never keep a logged-out user authenticated.
    static func apiKeyForUnattendedUse() -> String {
        #if DEBUG
        // Same gate as `hasAuthenticatedSessionForAutomaticDefaults()`: a
        // developer's real some.im login must never leak into a test run.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
           !testSharedSessionOverrideEnabled {
            return ""
        }
        if testSharedSessionOverrideEnabled {
            return loadAPIKey()
        }
        #endif
        migrateLegacyIfNeeded()
        let outcome = currentSessionOutcome()
        if case .unavailable = outcome {
            return sharedSessionMemo.usableLastKnownGoodSession?.apiKey
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return outcome.apiKey
    }

    /// Login gate for those same unattended paths. See `apiKeyForUnattendedUse()`.
    static func hasSessionForUnattendedUse() -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
           !testSharedSessionOverrideEnabled {
            return false
        }
        #endif
        return !apiKeyForUnattendedUse().isEmpty
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
        // session would keep this app looking signed in. The remembered
        // last-good session goes too — it exists to survive failed reads, not
        // to outlive an actual sign-out.
        invalidateSharedSessionCache()
        sharedSessionMemo.forgetLastKnownGoodSession()
        UserDefaults.standard.removeObject(forKey: accountKey)
        UserDefaults.standard.removeObject(forKey: codingPlanStatusKey)
        var settings = loadSettings()
        if settings.enabled {
            settings.enabled = false
            saveSettings(settings)
        }
        NotificationCenter.default.post(name: accountDidChangeNotification, object: nil)
        // Tagged: this empty session is a real sign-out, so observers may drop
        // the provider entry immediately instead of double-checking the read.
        NotificationCenter.default.post(
            name: sessionDidChangeNotification,
            object: nil,
            userInfo: [signOutUserInfoKey: true]
        )
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
        currentSessionOutcome().session
    }

    /// The shared session *and why it is missing* when it is.
    ///
    /// Callers that destroy state on an empty result must use this rather than
    /// `currentSharedSession()`: only `.signedOut` is a statement about the
    /// user. `.unavailable` means the read itself did not land, and acting on
    /// it as a sign-out is what deleted configured providers.
    static func currentSessionOutcome() -> SomeIMSessionReadOutcome {
        #if DEBUG
        if let testSessionReadOutcome { return testSessionReadOutcome }
        // The test override is deliberately never cached: unit tests set it
        // directly and expect the very next read to see the new value.
        if testSharedSessionOverrideEnabled {
            if let session = testSharedSessionOverride ?? privateKeychainFallbackSession() {
                return .session(session)
            }
            return .signedOut
        }
        #endif
        return sharedSessionMemo.value {
            let result = SomeIMSharedSessionStore.shared.read()
            if let session = result.session { return .session(session) }
            // The shared group has nothing usable. This app's own Keychain
            // namespace is the fallback (ad-hoc signed builds never reach the
            // shared group at all), and a hit there is a real session.
            if let fallback = privateKeychainFallbackSession() { return .session(fallback) }
            // Nothing anywhere. Only call it a sign-out if the shared store
            // actually confirmed the item is absent.
            return result.isConfirmedSignedOut ? .signedOut : .unavailable
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

    /// Forces `currentSessionOutcome()` to a fixed answer, so tests can exercise
    /// the `.unavailable` path — a Keychain that will not read is not something
    /// a test can arrange for real. Pass nil to restore normal resolution.
    static func _setTestSessionReadOutcome(_ outcome: SomeIMSessionReadOutcome?) {
        testSessionReadOutcome = outcome
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
