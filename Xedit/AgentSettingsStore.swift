//
//  AgentSettingsStore.swift
//  VeilWriter
//
//  Stores non-secret agent settings in UserDefaults and the API key in Keychain.
//

import Foundation
import Security

enum AgentSettingsStore {
    private static let defaultsKey = "im.some.veilwriter.agentSettings.v1"
    private static let knownModelsKey = "im.some.veilwriter.agentSettings.knownModels.v1"
    private static let alwaysAllowedCommandsKey = "im.some.veilwriter.agentSettings.alwaysAllowedCommands.v1"
    private static let autoApproveKey = "im.some.veilwriter.agentSettings.autoApproveSafeCommands.v1"
    private static let perProviderConcurrencyKey = "im.some.veilwriter.agentSettings.perProviderConcurrencyLimit.v1"
    private static let chatBaseFontSizeKey = "im.some.veilwriter.agentSettings.chatBaseFontSize.v1"

    /// Hard bounds for the Agent chat base font slider. The lower
    /// bound matches the prior caption size so the picker can't shrink
    /// the body text below an already-secondary element; the upper
    /// bound leaves headroom without breaking the chat bubble layout
    /// constants in AgentDesign.
    static let chatBaseFontSizeMin: CGFloat = 11
    static let chatBaseFontSizeMax: CGFloat = 20
    static let chatBaseFontSizeDefault: CGFloat = 13
    /// JSON-encoded `AgentProviderLibrary` minus the API keys, which
    /// live in Keychain under the entry's UUID.
    private static let providerLibraryKey = "im.some.veilwriter.agentSettings.providerLibrary.v1"
    private static let defaultKeychainService = "im.some.veilwriter.agent"
    private static let keychainAccount = "openai-compatible-api-key"
    private static let imageKeychainAccount = "openai-compatible-image-description-api-key"
    /// Keychain account prefix for per-entry library keys
    /// (full account = `libraryEntryKeychainPrefix + UUID string`).
    private static let libraryEntryKeychainPrefix = "library-entry-"

    /// Test-only override for the Keychain service name. Production code
    /// never touches this — it stays nil and `keychainService` returns
    /// `defaultKeychainService`. The unit tests that exercise AppState
    /// fire its @Published didSets, which transitively call
    /// `saveAPIKey` and `saveProviderLibrary`; without this override
    /// those tests would write fixture API keys (e.g. fixtures named
    /// `test-fixture-deepseek-key`) into the *real* developer-machine
    /// Keychain under the production service name, and they would
    /// resurface inside the running Settings UI. Tests should set this
    /// to a per-run unique string in setUp and call
    /// `resetTestKeychainOverride()` in tearDown to wipe the rows.
    nonisolated(unsafe) private static var testKeychainServiceOverride: String?

    private static var keychainService: String {
        testKeychainServiceOverride ?? defaultKeychainService
    }

    /// Test-only entry point: redirect all subsequent Keychain reads /
    /// writes to a sandbox service name. Returns the service name in
    /// use so tests can clean it up.
    @discardableResult
    static func _setTestKeychainServiceOverride(_ service: String?) -> String {
        testKeychainServiceOverride = service
        return keychainService
    }

    /// Test-only entry point: best-effort delete every Generic Password
    /// row this process wrote under the current (overridden) service.
    /// Safe to call even when no override is set — it then targets the
    /// production service, which we never want in tests, so the guard
    /// below makes that a no-op.
    static func _wipeTestKeychain() {
        guard let service = testKeychainServiceOverride else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Recently-fetched model IDs from any provider's `/models` endpoint.
    /// Surfaced in the Agent-mode model picker as a quick switcher.
    static func loadKnownModelIDs() -> [String] {
        (UserDefaults.standard.stringArray(forKey: knownModelsKey) ?? [])
            .filter { !$0.isEmpty }
    }

    static func saveKnownModelIDs(_ ids: [String]) {
        let cleaned = Array(Set(ids.filter { !$0.isEmpty })).sorted()
        UserDefaults.standard.set(cleaned, forKey: knownModelsKey)
    }

    static func loadAlwaysAllowedCommands() -> [AgentAlwaysAllowedCommand] {
        guard let data = UserDefaults.standard.data(forKey: alwaysAllowedCommandsKey),
              let decoded = try? JSONDecoder().decode([AgentAlwaysAllowedCommand].self, from: data) else {
            return []
        }
        return decoded
            .filter { !$0.commandSignature.isEmpty }
            .sorted { $0.commandSignature < $1.commandSignature }
    }

    /// Whether `run_command` should auto-approve commands the static
    /// allowlist (or the LLM judge) certifies as safe. Defaults to true
    /// on a fresh install; the toggle lives in Settings > Agent.
    static func loadAutoApproveSafeCommands() -> Bool {
        if UserDefaults.standard.object(forKey: autoApproveKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: autoApproveKey)
    }

    static func saveAutoApproveSafeCommands(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: autoApproveKey)
    }

    /// Cap on simultaneous in-flight Agent turns per provider. The
    /// concurrency model splits this per `providerID` so different
    /// providers don't share a single quota — see AppState. Defaults
    /// to 3 on fresh installs; user-tunable 1–8.
    static func loadPerProviderConcurrencyLimit() -> Int {
        if UserDefaults.standard.object(forKey: perProviderConcurrencyKey) == nil {
            return 3
        }
        let stored = UserDefaults.standard.integer(forKey: perProviderConcurrencyKey)
        return max(1, min(8, stored == 0 ? 3 : stored))
    }

    static func savePerProviderConcurrencyLimit(_ limit: Int) {
        let clamped = max(1, min(8, limit))
        UserDefaults.standard.set(clamped, forKey: perProviderConcurrencyKey)
    }

    /// Base font size (in points) for the Agent chat transcript body —
    /// user/assistant message prose and rendered Markdown blocks.
    /// Tool-call summaries, footers, headers, and composer chrome stay
    /// on `AgentDesign`'s fixed sizes by design (Q1=A from the rc2
    /// scope conversation).
    static func loadAgentChatBaseFontSize() -> CGFloat {
        if UserDefaults.standard.object(forKey: chatBaseFontSizeKey) == nil {
            return chatBaseFontSizeDefault
        }
        let stored = UserDefaults.standard.double(forKey: chatBaseFontSizeKey)
        guard stored > 0 else { return chatBaseFontSizeDefault }
        return clampChatBaseFontSize(CGFloat(stored))
    }

    static func saveAgentChatBaseFontSize(_ size: CGFloat) {
        let clamped = clampChatBaseFontSize(size)
        UserDefaults.standard.set(Double(clamped), forKey: chatBaseFontSizeKey)
    }

    static func clampChatBaseFontSize(_ size: CGFloat) -> CGFloat {
        max(chatBaseFontSizeMin, min(chatBaseFontSizeMax, size))
    }

    static func saveAlwaysAllowedCommands(_ commands: [AgentAlwaysAllowedCommand]) {
        var seen = Set<String>()
        let cleaned = commands
            .filter { !$0.commandSignature.isEmpty }
            .filter { seen.insert($0.commandSignature).inserted }
            .sorted { $0.commandSignature < $1.commandSignature }
        if let data = try? JSONEncoder().encode(cleaned) {
            UserDefaults.standard.set(data, forKey: alwaysAllowedCommandsKey)
        }
    }

    private struct StoredSettings: Codable {
        var providerID: String?
        var baseURL: String
        var model: String
        var flashModel: String?
        var proModel: String?
        var routingMode: AgentModelRoutingMode?
        var imageProviderID: String?
        var imageBaseURL: String?
        var imageModel: String?
    }

    static func load() -> AgentConfiguration {
        let stored: StoredSettings
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(StoredSettings.self, from: data) {
            stored = decoded
        } else {
            stored = StoredSettings(
                providerID: AgentConfiguration.default.providerID,
                baseURL: AgentConfiguration.default.baseURL,
                model: AgentConfiguration.default.model,
                flashModel: AgentConfiguration.default.flashModel,
                proModel: AgentConfiguration.default.proModel,
                routingMode: AgentConfiguration.default.routingMode,
                imageProviderID: AgentConfiguration.default.imageDescription.providerID,
                imageBaseURL: AgentConfiguration.default.imageDescription.baseURL,
                imageModel: AgentConfiguration.default.imageDescription.model
            )
        }

        let providerID = stored.providerID
            ?? AgentProviderPreset.matchingBaseURL(stored.baseURL)?.id
            ?? AgentProviderPreset.customID
        let preset = AgentProviderPreset.preset(id: providerID)
        let flashModel = stored.flashModel ?? preset?.defaultFlashModel ?? stored.model
        let proModel = stored.proModel ?? preset?.defaultProModel ?? stored.model
        let imageDescription = AgentImageDescriptionConfiguration(
            providerID: stored.imageProviderID ?? AgentImageDescriptionConfiguration.default.providerID,
            baseURL: stored.imageBaseURL ?? AgentImageDescriptionConfiguration.default.baseURL,
            model: stored.imageModel ?? AgentImageDescriptionConfiguration.default.model,
            apiKey: loadAPIKey(account: imageKeychainAccount)
        ).normalized

        return AgentConfiguration(
            providerID: providerID,
            baseURL: stored.baseURL,
            model: stored.model,
            flashModel: flashModel,
            proModel: proModel,
            routingMode: stored.routingMode ?? .auto,
            imageDescription: imageDescription,
            apiKey: loadAPIKey(account: keychainAccount)
        ).normalized
    }

    /// Legacy entry point — kept for any pre-A-plan callers. Forwards
    /// to `saveAuxiliaryConfiguration` so the provider-main fields are
    /// no longer round-tripped through here.
    static func save(_ configuration: AgentConfiguration) {
        saveAuxiliaryConfiguration(configuration)
    }

    /// A 方案保留点：只持久化那些不由 `agentProviderLibrary` 接管的辅助
    /// 字段 —— image-description provider 三件套、image API key、
    /// titleModel、routingMode（routingMode 同时也存在于 active entry，
    /// 这里只是一份兼容快照）。
    ///
    /// 关键不同：**不再**写入 legacy `keychainAccount`（也就是
    /// `openai-compatible-api-key`）。该 row 在 A 方案下没有读者，只会
    /// 在被回灌时反过来把错误的 key 写进 active entry —— 见 bug
    /// "OpenAI 顶着 DeepSeek 的 key"。
    static func saveAuxiliaryConfiguration(_ configuration: AgentConfiguration) {
        let normalized = configuration.normalized
        // We continue to persist a snapshot of the provider-main fields
        // into UserDefaults so old installs that still call `load()`
        // before the library migration kicks in (e.g. tests) get a
        // sensible answer. None of these survive past first launch on
        // an existing install — the library has already owned them
        // since Phase B.
        let stored = StoredSettings(
            providerID: normalized.providerID,
            baseURL: normalized.baseURL,
            model: normalized.model,
            flashModel: normalized.flashModel,
            proModel: normalized.proModel,
            routingMode: normalized.routingMode,
            imageProviderID: normalized.imageDescription.providerID,
            imageBaseURL: normalized.imageDescription.baseURL,
            imageModel: normalized.imageDescription.model
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        // image-description key is its own slot, never overlapped with
        // a provider library entry — safe to keep writing.
        saveAPIKey(normalized.imageDescription.apiKey, account: imageKeychainAccount)
    }

    /// Test-only / migration helper: remove the legacy provider-main
    /// keychain row that A 方案 no longer uses. We call this in the
    /// `loadProviderLibrary` one-shot repair so a stale key can't get
    /// re-adopted later.
    static func deleteLegacyProviderAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// One-shot accessor used by the migration: returns the legacy
    /// provider API key without removing it, so the repair pass can
    /// hand it to whichever library entry actually deserves it.
    static func loadLegacyProviderAPIKey() -> String {
        loadAPIKey(account: keychainAccount)
    }

    // MARK: - Provider library

    /// Load the multi-provider library. JSON-encoded entries live in
    /// UserDefaults; API keys live in Keychain keyed by entry UUID and
    /// are reattached here before returning. If the library is missing
    /// or empty, migrate from the legacy single-provider
    /// `AgentConfiguration` so existing users land smoothly on a
    /// library containing exactly their previous setup.
    ///
    /// **A 方案一次性修复**：之前 cfg.didSet 会把 legacy 默认值
    /// `providerID = "openai"` 回灌到 active entry 上，导致 DeepSeek
    /// 条目变成 OpenAI 但仍保留 DeepSeek 的 baseURL，且 API key 也被
    /// 错配。这里加载完 library 后做一次推断式修复：当某条 entry 的
    /// `baseURL` 明显属于一个 preset，而其 `providerID` 是另一个，就
    /// 按 baseURL 改回正确的 preset + 显示名。修复完会把结果回写一次
    /// 持久化，且只做一次（依据是 `repairAppliedKey`）。
    static func loadProviderLibrary() -> AgentProviderLibrary {
        if let data = UserDefaults.standard.data(forKey: providerLibraryKey),
           let stored = try? JSONDecoder().decode(StoredLibrary.self, from: data) {
            let entries = stored.entries.map { stripped -> AgentProviderEntry in
                var entry = stripped
                entry.apiKey = loadAPIKey(account: libraryEntryKeychainAccount(for: entry.id))
                return entry
            }
            var library = AgentProviderLibrary(entries: entries, activeID: stored.activeID)

            // One-shot repair pass. We don't re-run it on every launch
            // because once cfg.didSet no longer回灌 library, no new
            // mis-tags can show up; running it forever would risk
            // re-mapping a custom entry the user genuinely re-pointed.
            if !UserDefaults.standard.bool(forKey: repairAppliedKey) {
                library = repairLibraryProviderMismatch(library)
                UserDefaults.standard.set(true, forKey: repairAppliedKey)
                saveProviderLibrary(library)
                deleteLegacyProviderAPIKey()
            }
            return library
        }
        // Migration path — wrap the legacy AgentConfiguration in a
        // single-entry library on first launch after this change.
        let legacy = load()
        let migrated = AgentProviderLibrary.migrate(from: legacy)
        saveProviderLibrary(migrated)
        // Even on first launch we mark the repair as applied — the
        // migrated entry was freshly minted from cfg, no mismatch to
        // chase.
        UserDefaults.standard.set(true, forKey: repairAppliedKey)
        return migrated
    }

    /// One-shot key (UserDefaults bool) that marks whether the
    /// providerID-vs-baseURL repair has run on this install.
    private static let repairAppliedKey =
        "im.some.veilwriter.agentSettings.providerLibrary.repairAppliedV1"

    /// Repair logic split out for testing. For each entry whose
    /// `baseURL` matches a known preset but whose `providerID` doesn't,
    /// fix the providerID and displayName. If the displayName is the
    /// generic placeholder for the *wrong* preset (e.g. shows "OpenAI"
    /// while baseURL is DeepSeek), rename to the correct preset too.
    /// We never touch `apiKey` here — the key has always lived
    /// alongside the entry's UUID, not its providerID, so the user's
    /// real DeepSeek key is already on the right Keychain row even
    /// after the providerID was corrupted.
    static func repairLibraryProviderMismatch(_ library: AgentProviderLibrary) -> AgentProviderLibrary {
        var repaired = library
        let presetDisplayNames = Set(AgentProviderPreset.all.map(\.displayName))
        for index in repaired.entries.indices {
            let entry = repaired.entries[index]
            guard let bestPreset = AgentProviderPreset.matchingBaseURL(entry.baseURL),
                  bestPreset.id != AgentProviderPreset.customID,
                  bestPreset.id != entry.providerID else { continue }
            repaired.entries[index].providerID = bestPreset.id
            // Only relabel if the current displayName looks like the
            // generic preset name of the *wrong* preset — don't clobber
            // a user-chosen label like "Work DeepSeek".
            if presetDisplayNames.contains(entry.displayName) {
                repaired.entries[index].displayName = bestPreset.displayName
            }
        }
        return repaired
    }

    static func saveProviderLibrary(_ library: AgentProviderLibrary) {
        let stripped = library.entries.map { entry -> AgentProviderEntry in
            var copy = entry
            copy.apiKey = ""
            return copy
        }
        let stored = StoredLibrary(entries: stripped, activeID: library.activeID)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: providerLibraryKey)
        }
        // Sync keychain — write each entry's key under its UUID, and
        // delete keychain rows for entries that no longer exist.
        for entry in library.entries {
            saveAPIKey(entry.apiKey, account: libraryEntryKeychainAccount(for: entry.id))
        }
    }

    /// Convenience for tests + migrations: deletes a library entry's
    /// Keychain row.
    static func deleteLibraryEntryAPIKey(for id: UUID) {
        let account = libraryEntryKeychainAccount(for: id)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func libraryEntryKeychainAccount(for id: UUID) -> String {
        "\(libraryEntryKeychainPrefix)\(id.uuidString)"
    }

    /// On-disk shape — same as `AgentProviderLibrary` minus the API
    /// keys (those live in Keychain).
    private struct StoredLibrary: Codable {
        var entries: [AgentProviderEntry]
        var activeID: UUID?
    }

    private static func loadAPIKey(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    /// Why this is more careful than "delete then add":
    ///
    /// 1. **No-op fast path.** `saveProviderLibrary` is called from
    ///    `AppState`'s `didSet` for the whole library, which fires on
    ///    every Settings tweak — base URL, model, entry name, anything.
    ///    Before this rewrite that meant `SecItemDelete + SecItemAdd`
    ///    ran on *every* entry on *every* edit, and macOS reads each
    ///    Add as a fresh write of secret material — which triggers the
    ///    "VeilWriter wants to access 'im.some.veilwriter.agent'"
    ///    prompt repeatedly. We now read the current stored value
    ///    first and skip the entire write if it's identical.
    /// 2. **Prefer `SecItemUpdate` over delete+add.** When the value
    ///    actually changed we update the existing row in place. Delete
    ///    + add severs the Keychain ACL (the list of binaries that
    ///    were granted access via "Always Allow"), forcing the user to
    ///    re-grant on next read. `SecItemUpdate` keeps the ACL intact.
    /// 3. **`kSecAttrAccessible: AfterFirstUnlock`.** Without this the
    ///    row gets a default policy that some macOS releases interpret
    ///    as "ask the user on every access". After-first-unlock means
    ///    once the user has logged into the Mac after boot, the row is
    ///    readable for the rest of the session without prompting.
    private static func saveAPIKey(_ apiKey: String, account: String) {
        // Empty value → delete the row (don't store empty data).
        guard !apiKey.isEmpty, let data = apiKey.data(using: .utf8) else {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            return
        }

        // No-op when the stored value is already what we'd write — the
        // single biggest source of the repeated Keychain prompts.
        let existing = loadAPIKey(account: account)
        if existing == apiKey { return }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        // Try update first; if the row doesn't exist (`errSecItemNotFound`)
        // fall through to add. This keeps the ACL list intact so users
        // who have clicked "Always Allow" stay granted.
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            // Something weirder than "row doesn't exist" — wipe and
            // re-add so we don't leave a half-written row behind.
            SecItemDelete(baseQuery as CFDictionary)
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
