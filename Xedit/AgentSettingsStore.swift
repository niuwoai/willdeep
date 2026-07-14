//
//  AgentSettingsStore.swift
//  WillDeep
//
//  Stores non-secret agent settings in UserDefaults and the API key in Keychain.
//

import Foundation
import Security

struct AgentModelDiscovery: Codable, Equatable {
    var id: String
    var isHot: Bool
    var isNew: Bool
}

enum AgentDefaultModelModePreference: String, Equatable {
    /// No explicit choice yet. A signed-in some.im account may default new
    /// chats to managed routing.
    case automatic
    /// The user explicitly selected some.im managed routing.
    case managed
    /// The user explicitly selected a concrete model or route default.
    case explicitModel
}

enum AgentWebSearchProvider: String, CaseIterable, Codable, Identifiable {
    case auto
    case exa
    case brave

    var id: String { rawValue }
}

enum AgentSettingsStore {
    private static let defaultsKey = "com.willdeep.agentSettings.v1"
    private static let knownModelsKey = "com.willdeep.agentSettings.knownModels.v1"
    private static let discoveredModelMetadataKey = "com.willdeep.agentSettings.discoveredModelMetadata.v1"
    private static let recentlyUsedModelsKey = "com.willdeep.agentSettings.recentlyUsedModels.v1"
    private static let defaultModelModePreferenceKey = "com.willdeep.agentSettings.defaultModelModePreference.v1"
    private static let alwaysAllowedCommandsKey = "com.willdeep.agentSettings.alwaysAllowedCommands.v1"
    private static let autoApproveKey = "com.willdeep.agentSettings.autoApproveSafeCommands.v1"
    private static let perProviderConcurrencyKey = "com.willdeep.agentSettings.perProviderConcurrencyLimit.v1"
    private static let chatBaseFontSizeKey = "com.willdeep.agentSettings.chatBaseFontSize.v1"
    private static let webSearchProviderKey = "com.willdeep.agentSettings.webSearchProvider.v1"
    private static let localModelSettingsKey = "com.willdeep.agentSettings.localModelSettings.v1"
    /// Global toggle: 关掉后 plan 自动执行 banner 不再做 destructive keyword
    /// 扫描，所有 plan 都跑倒计时自动执行。默认开。
    private static let planAutoExecuteDangerScanKey = "com.willdeep.agentSettings.planAutoExecuteDangerScan.v1"
    /// Per-workspace 偏好：勾选"本工作区记住"后写入；下次 plan 就绪不再
    /// 弹 banner，直接走 confirmPlanAndExecute。key 形如
    /// `com.willdeep.agentSettings.planAutoExecuteSilently.v1.<workspaceHash>`。
    private static let planAutoExecuteSilentlyKeyPrefix = "com.willdeep.agentSettings.planAutoExecuteSilently.v1."

    /// Hard bounds for the Agent chat base font slider. The lower
    /// bound matches the prior caption size so the picker can't shrink
    /// the body text below an already-secondary element; the upper
    /// bound leaves headroom without breaking the chat bubble layout
    /// constants in AgentDesign.
    static let chatBaseFontSizeMin: CGFloat = 11
    static let chatBaseFontSizeMax: CGFloat = 20
    static let chatBaseFontSizeDefault: CGFloat = 14
    /// JSON-encoded `AgentProviderLibrary` minus the API keys, which
    /// live in Keychain under the entry's UUID.
    private static let providerLibraryKey = "com.willdeep.agentSettings.providerLibrary.v1"
    private static let defaultKeychainService = "com.willdeep.agent"
    private static let keychainAccount = "openai-compatible-api-key"
    private static let imageKeychainAccount = "openai-compatible-image-description-api-key"
    /// Keychain account prefix for per-entry library keys
    /// (full account = `libraryEntryKeychainPrefix + UUID string`).
    private static let libraryEntryKeychainPrefix = "library-entry-"
    /// Brave Search API key for the built-in `web_search` tool.
    private static let braveSearchKeychainAccount = "brave-search-api-key"
    /// Exa API key for the built-in `web_search` tool.
    private static let exaSearchKeychainAccount = "exa-search-api-key"

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

    /// Test-only override for the UserDefaults backing store. Mirrors
    /// the keychain override above and exists for the same reason: a
    /// `KeychainSandbox`-only sandbox stopped fixture API keys from
    /// landing in the real keychain, but the *entry skeletons* (encoded
    /// JSON containing providerID / baseURL / displayName / model lists)
    /// still went straight into `defaults` via
    /// `saveProviderLibrary`. Result: the dev's running app showed two
    /// fixture providers ("OpenAI / gpt-4.1-mini" and
    /// "DeepSeek / deepseek-v4-flash") with empty API keys after every
    /// test run, as if the new version had auto-seeded them. Tests now
    /// point this at a per-run `UserDefaults(suiteName:)` so non-secret
    /// fixture data is sandboxed too.
    nonisolated(unsafe) private static var testDefaultsOverride: UserDefaults?
    nonisolated(unsafe) private static var xctestKeychainStorage: [String: String] = [:]

    private static var keychainService: String {
        testKeychainServiceOverride ?? defaultKeychainService
    }

    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// All non-secret persistence flows through this accessor so a test
    /// can redirect every read / write into a sandbox suite. Production
    /// gets `defaults`; tests get whatever
    /// `_setTestDefaultsOverride` last installed.
    private static var defaults: UserDefaults {
        testDefaultsOverride ?? .standard
    }

    /// Test-only entry point: redirect all subsequent Keychain reads /
    /// writes to a sandbox service name. Returns the service name in
    /// use so tests can clean it up.
    @discardableResult
    static func _setTestKeychainServiceOverride(_ service: String?) -> String {
        testKeychainServiceOverride = service
        return keychainService
    }

    /// Test-only entry point: redirect all subsequent UserDefaults
    /// reads / writes to a sandbox suite. Pass nil to restore
    /// `defaults`. Cleanup is the caller's job — call
    /// `removePersistentDomain(forName:)` on the suite name before
    /// dropping the override.
    static func _setTestDefaultsOverride(_ defaults: UserDefaults?) {
        testDefaultsOverride = defaults
    }

    /// Test-only entry point: best-effort delete every Generic Password
    /// row this process wrote under the current (overridden) service.
    /// Safe to call even when no override is set — it then targets the
    /// production service, which we never want in tests, so the guard
    /// below makes that a no-op.
    static func _wipeTestKeychain() {
        if isRunningUnderXCTest {
            let prefix = "\(keychainService)/"
            xctestKeychainStorage = xctestKeychainStorage.filter { !$0.key.hasPrefix(prefix) }
            return
        }
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
        (defaults.stringArray(forKey: knownModelsKey) ?? [])
            .filter { !$0.isEmpty }
    }

    static func saveKnownModelIDs(_ ids: [String]) {
        let cleaned = Array(Set(ids.filter { !$0.isEmpty })).sorted()
        defaults.set(cleaned, forKey: knownModelsKey)
    }

    static func loadDiscoveredModelMetadata() -> [AgentModelDiscovery] {
        guard let data = defaults.data(forKey: discoveredModelMetadataKey),
              let decoded = try? JSONDecoder().decode([AgentModelDiscovery].self, from: data) else {
            return []
        }
        return cleanedDiscoveredModelMetadata(decoded)
    }

    static func saveDiscoveredModelMetadata(_ models: [AgentModelDiscovery]) {
        let cleaned = cleanedDiscoveredModelMetadata(models)
        if let data = try? JSONEncoder().encode(cleaned) {
            defaults.set(data, forKey: discoveredModelMetadataKey)
        }
    }

    private static func cleanedDiscoveredModelMetadata(_ models: [AgentModelDiscovery]) -> [AgentModelDiscovery] {
        var seen = Set<String>()
        var result: [AgentModelDiscovery] = []
        for model in models {
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let key = id.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(AgentModelDiscovery(id: id, isHot: model.isHot, isNew: model.isNew))
        }
        return result.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    /// Models the user explicitly picked in the composer/model picker,
    /// most-recently-used first. Kept separate from `knownModelsKey`:
    /// fetched means "seen from /models", used means "chosen for a turn".
    static func loadRecentlyUsedModelIDs() -> [String] {
        cleanedRecentlyUsedModelIDs(defaults.stringArray(forKey: recentlyUsedModelsKey) ?? [])
    }

    static func saveRecentlyUsedModelIDs(_ ids: [String]) {
        defaults.set(cleanedRecentlyUsedModelIDs(ids), forKey: recentlyUsedModelsKey)
    }

    static func loadDefaultModelModePreference() -> AgentDefaultModelModePreference {
        if let raw = defaults.string(forKey: defaultModelModePreferenceKey),
           let preference = AgentDefaultModelModePreference(rawValue: raw) {
            return preference
        }
        // Backward-compatible inference: before this preference existed,
        // recently-used models were written only by explicit picker actions.
        return loadRecentlyUsedModelIDs().isEmpty ? .automatic : .explicitModel
    }

    static func saveDefaultModelModePreference(_ preference: AgentDefaultModelModePreference) {
        defaults.set(preference.rawValue, forKey: defaultModelModePreferenceKey)
    }

    private static func cleanedRecentlyUsedModelIDs(_ ids: [String], limit: Int = 24) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in ids {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let key = id.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(id)
            if result.count >= limit { break }
        }
        return result
    }

    static func loadAlwaysAllowedCommands() -> [AgentAlwaysAllowedCommand] {
        guard let data = defaults.data(forKey: alwaysAllowedCommandsKey),
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
        if defaults.object(forKey: autoApproveKey) == nil {
            return true
        }
        return defaults.bool(forKey: autoApproveKey)
    }

    static func saveAutoApproveSafeCommands(_ enabled: Bool) {
        defaults.set(enabled, forKey: autoApproveKey)
    }

    static func loadLocalModelSettings() -> AgentLocalModelSettings {
        guard let data = defaults.data(forKey: localModelSettingsKey),
              let decoded = try? JSONDecoder().decode(AgentLocalModelSettings.self, from: data) else {
            return .default
        }
        return decoded.normalized
    }

    static func saveLocalModelSettings(_ settings: AgentLocalModelSettings) {
        if let data = try? JSONEncoder().encode(settings.normalized) {
            defaults.set(data, forKey: localModelSettingsKey)
        }
    }

    // MARK: - Plan auto-execution (1.79.0)

    /// 是否在 plan 自动执行 banner 弹出前扫 destructive 关键词；命中后
    /// 倒计时被禁用，需要用户手动点确认。默认 true（保守 + 可关）。
    static func loadPlanAutoExecuteDangerScanEnabled() -> Bool {
        if defaults.object(forKey: planAutoExecuteDangerScanKey) == nil {
            return true
        }
        return defaults.bool(forKey: planAutoExecuteDangerScanKey)
    }

    static func savePlanAutoExecuteDangerScanEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: planAutoExecuteDangerScanKey)
    }

    /// 「本工作区记住」：勾选后，下次同 workspace 下 plan 就绪不再弹
    /// banner，直接 confirm。workspace 用绝对路径的 SHA256 前缀做 key
    /// 后缀，避免把完整路径写进 defaults。nil workspace（无 workspace
    /// 的场景）走特殊 key。
    static func loadPlanAutoExecuteSilently(workspacePath: String?) -> Bool {
        defaults.bool(forKey: planAutoExecuteSilentlyKey(for: workspacePath))
    }

    static func savePlanAutoExecuteSilently(_ enabled: Bool, workspacePath: String?) {
        let key = planAutoExecuteSilentlyKey(for: workspacePath)
        if enabled {
            defaults.set(true, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func planAutoExecuteSilentlyKey(for workspacePath: String?) -> String {
        let suffix: String
        if let path = workspacePath, !path.isEmpty {
            suffix = workspaceHash(path)
        } else {
            suffix = "no-workspace"
        }
        return planAutoExecuteSilentlyKeyPrefix + suffix
    }

    /// 稳定、与平台无关的 workspace 路径短哈希。用 DJB2（djb2a 变体）
    /// 是为了避免引入 CryptoKit 在所有 target 上的传染；这里只是
    /// per-workspace 偏好 key 的命名空间，无安全/抗碰撞要求。
    private static func workspaceHash(_ path: String) -> String {
        var hash: UInt64 = 5381
        for byte in path.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    /// Cap on simultaneous in-flight Agent turns per provider. The
    /// concurrency model splits this per `providerID` so different
    /// providers don't share a single quota — see AppState. Defaults
    /// to 3 on fresh installs; user-tunable 1–8.
    static func loadPerProviderConcurrencyLimit() -> Int {
        if defaults.object(forKey: perProviderConcurrencyKey) == nil {
            return 3
        }
        let stored = defaults.integer(forKey: perProviderConcurrencyKey)
        return max(1, min(8, stored == 0 ? 3 : stored))
    }

    static func savePerProviderConcurrencyLimit(_ limit: Int) {
        let clamped = max(1, min(8, limit))
        defaults.set(clamped, forKey: perProviderConcurrencyKey)
    }

    /// Base font size (in points) for the Agent chat transcript body —
    /// user/assistant message prose and rendered Markdown blocks.
    /// Tool-call summaries, footers, headers, and composer chrome stay
    /// on `AgentDesign`'s fixed sizes by design (Q1=A from the rc2
    /// scope conversation).
    static func loadAgentChatBaseFontSize() -> CGFloat {
        if defaults.object(forKey: chatBaseFontSizeKey) == nil {
            return chatBaseFontSizeDefault
        }
        let stored = defaults.double(forKey: chatBaseFontSizeKey)
        guard stored > 0 else { return chatBaseFontSizeDefault }
        return clampChatBaseFontSize(CGFloat(stored))
    }

    static func saveAgentChatBaseFontSize(_ size: CGFloat) {
        let clamped = clampChatBaseFontSize(size)
        defaults.set(Double(clamped), forKey: chatBaseFontSizeKey)
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
            defaults.set(data, forKey: alwaysAllowedCommandsKey)
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
        if let data = defaults.data(forKey: defaultsKey),
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
            defaults.set(data, forKey: defaultsKey)
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
        deleteAPIKey(account: keychainAccount)
    }

    /// One-shot accessor used by the migration: returns the legacy
    /// provider API key without removing it, so the repair pass can
    /// hand it to whichever library entry actually deserves it.
    static func loadLegacyProviderAPIKey() -> String {
        loadAPIKey(account: keychainAccount)
    }

    // MARK: - Web tools

    /// Preferred backend for `web_search`. Auto tries Exa first when
    /// configured, then Brave, which preserves old installs while making
    /// Exa the default path for new setups.
    static func loadWebSearchProvider() -> AgentWebSearchProvider {
        guard let raw = defaults.string(forKey: webSearchProviderKey),
              let provider = AgentWebSearchProvider(rawValue: raw) else {
            return .auto
        }
        return provider
    }

    static func saveWebSearchProvider(_ provider: AgentWebSearchProvider) {
        defaults.set(provider.rawValue, forKey: webSearchProviderKey)
    }

    /// Exa API key consumed by `web_search` at call time. Empty string
    /// means "not configured" — the tool surfaces a setup hint to the
    /// model instead of failing silently.
    static func loadExaSearchAPIKey() -> String {
        loadAPIKey(account: exaSearchKeychainAccount)
    }

    static func saveExaSearchAPIKey(_ key: String) {
        saveAPIKey(
            key.trimmingCharacters(in: .whitespacesAndNewlines),
            account: exaSearchKeychainAccount
        )
    }

    /// Brave Search API key consumed by `web_search` at call time. Empty
    /// string means "not configured" — the tool surfaces a setup hint to
    /// the model instead of failing silently.
    static func loadBraveSearchAPIKey() -> String {
        loadAPIKey(account: braveSearchKeychainAccount)
    }

    static func saveBraveSearchAPIKey(_ key: String) {
        saveAPIKey(
            key.trimmingCharacters(in: .whitespacesAndNewlines),
            account: braveSearchKeychainAccount
        )
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
        if let data = defaults.data(forKey: providerLibraryKey),
           let stored = try? JSONDecoder().decode(StoredLibrary.self, from: data) {
            var library = AgentProviderLibrary(entries: stored.entries, activeID: stored.activeID)
            materializeProviderLibraryAPIKey(in: &library, id: library.active?.id)

            // One-shot repair pass. We don't re-run it on every launch
            // because once cfg.didSet no longer回灌 library, no new
            // mis-tags can show up; running it forever would risk
            // re-mapping a custom entry the user genuinely re-pointed.
            if !defaults.bool(forKey: repairAppliedKey) {
                library = repairLibraryProviderMismatch(library)
                defaults.set(true, forKey: repairAppliedKey)
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
        defaults.set(true, forKey: repairAppliedKey)
        return migrated
    }

    @discardableResult
    static func materializeProviderLibraryAPIKey(in library: inout AgentProviderLibrary, id: UUID?) -> Bool {
        guard let id,
              let index = library.entries.firstIndex(where: { $0.id == id }),
              !library.entries[index].apiKeyLoaded else {
            return false
        }
        library.entries[index].apiKey = loadAPIKey(account: libraryEntryKeychainAccount(for: id))
        library.entries[index].apiKeyLoaded = true
        return true
    }

    /// One-shot key (UserDefaults bool) that marks whether the
    /// providerID-vs-baseURL repair has run on this install.
    private static let repairAppliedKey =
        "com.willdeep.agentSettings.providerLibrary.repairAppliedV1"

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
            copy.apiKeyLoaded = false
            return copy
        }
        let stored = StoredLibrary(entries: stripped, activeID: library.activeID)
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: providerLibraryKey)
        }
        // Sync only entries whose secret has been materialized. Empty
        // `apiKey` on an unloaded entry means "still in Keychain", not
        // "user cleared this key".
        for entry in library.entries {
            guard entry.apiKeyLoaded else { continue }
            saveAPIKey(entry.apiKey, account: libraryEntryKeychainAccount(for: entry.id))
        }
    }

    /// Convenience for tests + migrations: deletes a library entry's
    /// Keychain row.
    static func deleteLibraryEntryAPIKey(for id: UUID) {
        deleteAPIKey(account: libraryEntryKeychainAccount(for: id))
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
        if isRunningUnderXCTest {
            return xctestKeychainStorage[keychainStorageKey(account: account)] ?? ""
        }
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

    private static func keychainStorageKey(account: String) -> String {
        "\(keychainService)/\(account)"
    }

    private static func deleteAPIKey(account: String) {
        if isRunningUnderXCTest {
            xctestKeychainStorage.removeValue(forKey: keychainStorageKey(account: account))
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Why this is more careful than "delete then add":
    ///
    /// 1. **No-op fast path.** `saveProviderLibrary` is called from
    ///    `AppState`'s `didSet` for the whole library, which fires on
    ///    every Settings tweak — base URL, model, entry name, anything.
    ///    Before this rewrite that meant `SecItemDelete + SecItemAdd`
    ///    ran on *every* entry on *every* edit, and macOS reads each
    ///    Add as a fresh write of secret material — which triggers the
    ///    "WillDeep wants to access 'com.willdeep.agent'"
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
            deleteAPIKey(account: account)
            return
        }

        if isRunningUnderXCTest {
            let key = keychainStorageKey(account: account)
            if xctestKeychainStorage[key] == apiKey { return }
            xctestKeychainStorage[key] = apiKey
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

enum AgentCredentialStore {
    nonisolated static let referencePrefix = "keychain://"
    nonisolated private static let defaultKeychainService = "com.willdeep.credentials"

    nonisolated(unsafe) private static var testKeychainServiceOverride: String?
    nonisolated(unsafe) private static var testKeychainStorage: [String: String]?
    nonisolated(unsafe) private static var xctestKeychainStorage: [String: String] = [:]
    nonisolated(unsafe) private static var testLoadCounts: [String: Int] = [:]
    nonisolated(unsafe) private static var testSaveCounts: [String: Int] = [:]

    nonisolated private static var keychainService: String {
        testKeychainServiceOverride ?? defaultKeychainService
    }

    nonisolated private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    @discardableResult
    static func _setTestKeychainServiceOverride(_ service: String?) -> String {
        testKeychainServiceOverride = service
        testKeychainStorage = service == nil ? nil : [:]
        return keychainService
    }

    static func _wipeTestKeychain() {
        if testKeychainStorage != nil {
            testKeychainStorage?.removeAll()
            _resetTestAccessCounts()
            return
        }

        if isRunningUnderXCTest {
            xctestKeychainStorage.removeAll()
            _resetTestAccessCounts()
            return
        }

        guard let service = testKeychainServiceOverride else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func _resetTestAccessCounts() {
        testLoadCounts.removeAll()
        testSaveCounts.removeAll()
    }

    static func _testLoadCount(account: String) -> Int {
        testLoadCounts[account] ?? 0
    }

    static func _testSaveCount(account: String) -> Int {
        testSaveCounts[account] ?? 0
    }

    nonisolated static func reference(account: String) -> String {
        "\(referencePrefix)\(account)"
    }

    nonisolated static func mcpAccount(serverID: String, kind: String, key: String) -> String {
        "mcp/\(sanitize(serverID))/\(sanitize(kind))/\(sanitize(key))"
    }

    nonisolated static func skillAccount(entryID: String, credentialID: String) -> String {
        "skill/\(sanitize(entryID))/\(sanitize(credentialID))"
    }

    nonisolated static func save(_ secret: String, account: String) {
        testSaveCounts[account, default: 0] += 1
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            delete(account: account)
            return
        }

        if testKeychainStorage != nil {
            testKeychainStorage?[account] = trimmed
            return
        }

        if isRunningUnderXCTest {
            xctestKeychainStorage[account] = trimmed
            return
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            SecItemDelete(baseQuery as CFDictionary)
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    nonisolated static func load(account: String) -> String {
        testLoadCounts[account, default: 0] += 1
        if let testKeychainStorage {
            return testKeychainStorage[account] ?? ""
        }

        if isRunningUnderXCTest {
            return xctestKeychainStorage[account] ?? ""
        }

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

    nonisolated static func delete(account: String) {
        if testKeychainStorage != nil {
            testKeychainStorage?.removeValue(forKey: account)
            return
        }

        if isRunningUnderXCTest {
            xctestKeychainStorage.removeValue(forKey: account)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    nonisolated static func isReference(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(referencePrefix)
            || value.contains("${credential:")
    }

    nonisolated static func resolve(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(referencePrefix) {
            return load(account: String(trimmed.dropFirst(referencePrefix.count)))
        }

        var resolved = value
        while let range = resolved.range(of: "${credential:") {
            guard let end = resolved[range.upperBound...].firstIndex(of: "}") else { break }
            let account = String(resolved[range.upperBound..<end])
            let secret = load(account: account)
            resolved.replaceSubrange(range.lowerBound...end, with: secret)
        }
        return resolved
    }

    nonisolated static func hasSecret(reference value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(referencePrefix) {
            return !load(account: String(trimmed.dropFirst(referencePrefix.count))).isEmpty
        }
        return false
    }

    nonisolated private static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        return String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
