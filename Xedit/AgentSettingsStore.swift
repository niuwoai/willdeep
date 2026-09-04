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
    /// Context window as reported by the provider's own model catalog, when
    /// it publishes one. nil means "not reported" — the caller falls back to
    /// the built-in id-matching table in `agentContextWindow(model:)`.
    ///
    /// Worth having even though few providers fill it in: the matching table
    /// guesses from the model id, and an id it does not recognise lands on
    /// the conservative 128K default. some.im lists `kimi-k3` at 1M, so the
    /// guess was reading 87% low — the gauge showed 78% used when the real
    /// figure was 10%, which fires compression and the 90% ordered stop for
    /// no reason.
    var contextWindowTokens: Int?
}

enum AgentDefaultModelModePreference: String, Equatable {
    /// No explicit choice yet. Authenticated some.im sessions default to the
    /// relay's automatic Flash route; managed routing remains an opt-in mode.
    case automatic
    /// The user explicitly selected some.im managed routing.
    case managed
    /// The user explicitly selected a concrete model or route default.
    case explicitModel

    var usesManagedRoutingForNewSessions: Bool {
        self == .managed
    }
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
    private static let perProviderConcurrencyKey = "com.willdeep.agentSettings.perProviderConcurrencyLimit.v1"
    private static let deepAdmissionBudgetKey = "com.willdeep.agentSettings.deepAdmissionBudget.v1"
    private static let chatBaseFontSizeKey = "com.willdeep.agentSettings.chatBaseFontSize.v2"
    private static let legacyChatBaseFontSizeKey = "com.willdeep.agentSettings.chatBaseFontSize.v1"
    private static let chatFontIDKey = "com.willdeep.agentSettings.chatFontID.v1"
    private static let fontSmoothingEnabledKey = "com.willdeep.agentSettings.fontSmoothing.v1"
    private static let pluginPageInspectableKey = "com.willdeep.agentSettings.pluginPageInspectable.v1"
    private static let chatLineHeightMultipleKey = "com.willdeep.agentSettings.chatLineHeightMultiple.v1"
    private static let anthropicMaxOutputTokensKey = "com.willdeep.agentSettings.anthropicMaxOutputTokens.v1"
    private static let webSearchProviderKey = "com.willdeep.agentSettings.webSearchProvider.v1"
    private static let localModelSettingsKey = "com.willdeep.agentSettings.localModelSettings.v1"

    /// Hard bounds for the Agent chat base font slider. The lower
    /// bound matches the prior caption size so the picker can't shrink
    /// the body text below an already-secondary element; the upper
    /// bound leaves headroom without breaking the chat bubble layout
    /// constants in AgentDesign.
    static let chatBaseFontSizeMin: CGFloat = 11
    static let chatBaseFontSizeMax: CGFloat = 20
    static let chatBaseFontSizeDefault: CGFloat = 15
    static let chatFontIDDefault = "pingfang-sc"
    static let chatLineHeightMultipleMin: CGFloat = 1.2
    static let chatLineHeightMultipleMax: CGFloat = 2.0
    static let chatLineHeightMultipleDefault: CGFloat = 1.4
    /// JSON-encoded `AgentProviderLibrary` minus the API keys, which
    /// live in Keychain under the entry's UUID.
    private static let providerLibraryKey = "com.willdeep.agentSettings.providerLibrary.v1"
    private static let releaseKeychainService = "com.willdeep.agent"
    private static let debugKeychainService = "com.willdeep.agent.debug"
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
    /// the service selected for the current build configuration. The unit
    /// tests that exercise AppState fire its @Published didSets, which transitively call
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
        if let testKeychainServiceOverride {
            return testKeychainServiceOverride
        }
        #if DEBUG
        return serviceName(debugBuild: true)
        #else
        return serviceName(debugBuild: false)
        #endif
    }

    static func serviceName(debugBuild: Bool) -> String {
        debugBuild ? debugKeychainService : releaseKeychainService
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
            result.append(
                AgentModelDiscovery(
                    id: id,
                    isHot: model.isHot,
                    isNew: model.isNew,
                    contextWindowTokens: model.contextWindowTokens.flatMap { $0 > 0 ? $0 : nil }
                )
            )
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
        // Fresh installs and upgrades default to some.im's automatic Flash
        // model. Composer picks remain conversation-scoped; only the some.im
        // Settings control persists an explicit managed-routing preference.
        return .automatic
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

    /// How many `deep` (1M tier) spawns one session may be granted.
    ///
    /// `~/.willdeep/config.toml` wins when it names a value: that file is
    /// shared with willdeep-rs, and someone who set `max_deep_calls_per_harness`
    /// there meant it for the machine, not for whichever client they had open.
    ///
    /// Unlike the concurrency limit, **0 is a meaningful stored value** here —
    /// it turns the scarce tier off entirely — so absence is detected via
    /// `object(forKey:)` rather than by treating 0 as unset.
    static func loadDeepAdmissionBudget(
        sharedConfig: AgentSharedRuntimeConfig = .load()
    ) -> Int {
        if let shared = sharedConfig.maxDeepCallsPerHarness {
            return AgentDeepAdmission.clampBudget(shared)
        }
        guard defaults.object(forKey: deepAdmissionBudgetKey) != nil else {
            return AgentDeepAdmission.defaultBudgetPerSession
        }
        return AgentDeepAdmission.clampBudget(defaults.integer(forKey: deepAdmissionBudgetKey))
    }

    static func saveDeepAdmissionBudget(_ budget: Int) {
        defaults.set(AgentDeepAdmission.clampBudget(budget), forKey: deepAdmissionBudgetKey)
    }

    /// Base font size (in points) for the Agent chat transcript body —
    /// user/assistant message prose and rendered Markdown blocks.
    /// Tool-call summaries, footers, headers, and composer chrome stay
    /// on `AgentDesign`'s fixed sizes by design (Q1=A from the rc2
    /// scope conversation).
    static func loadAgentChatBaseFontSize() -> CGFloat {
        if defaults.object(forKey: chatBaseFontSizeKey) != nil {
            let stored = defaults.double(forKey: chatBaseFontSizeKey)
            guard stored > 0 else { return chatBaseFontSizeDefault }
            return clampChatBaseFontSize(CGFloat(stored))
        }

        let legacyStored = defaults.object(forKey: legacyChatBaseFontSizeKey) == nil
            ? nil
            : CGFloat(defaults.double(forKey: legacyChatBaseFontSizeKey))
        let migrated = migratedChatBaseFontSize(fromLegacy: legacyStored)
        defaults.set(Double(migrated), forKey: chatBaseFontSizeKey)
        return migrated
    }

    static func saveAgentChatBaseFontSize(_ size: CGFloat) {
        let clamped = clampChatBaseFontSize(size)
        defaults.set(Double(clamped), forKey: chatBaseFontSizeKey)
    }

    /// Whether macOS font smoothing is on for this app.
    ///
    /// Defaults to true — smoothing is what text looked like before macOS
    /// turned it off for layer-backed views, and it is what the rest of the
    /// system still looks like on a non-Retina display.
    static func loadFontSmoothingEnabled() -> Bool {
        guard defaults.object(forKey: fontSmoothingEnabledKey) != nil else { return true }
        return defaults.bool(forKey: fontSmoothingEnabledKey)
    }

    static func saveFontSmoothingEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: fontSmoothingEnabledKey)
    }

    /// 插件页面允不允许挂 Safari 的网页检查器。
    ///
    /// 默认关。开着不会给页面多一分权限（能力还是那些桥），但检查器能读
    /// 到页面内存里的一切，包括它刚从 `ai.complete` 拿回来的东西；这是给
    /// 插件作者调试用的开关，不该是所有用户的默认状态。
    /// 开启后还需要 Safari 打开「开发」菜单才看得到。
    static func loadPluginPageInspectable() -> Bool {
        defaults.bool(forKey: pluginPageInspectableKey)
    }

    static func savePluginPageInspectable(_ enabled: Bool) {
        defaults.set(enabled, forKey: pluginPageInspectableKey)
    }

    static func loadAgentChatFontID() -> String {
        let stored = defaults.string(forKey: chatFontIDKey) ?? chatFontIDDefault
        return AgentChatFontChoice.byID(stored) == nil ? chatFontIDDefault : stored
    }

    static func saveAgentChatFontID(_ id: String) {
        defaults.set(AgentChatFontChoice.byID(id) == nil ? chatFontIDDefault : id, forKey: chatFontIDKey)
    }

    static func loadAgentChatLineHeightMultiple() -> CGFloat {
        guard defaults.object(forKey: chatLineHeightMultipleKey) != nil else {
            return chatLineHeightMultipleDefault
        }
        return clampChatLineHeightMultiple(CGFloat(defaults.double(forKey: chatLineHeightMultipleKey)))
    }

    static func saveAgentChatLineHeightMultiple(_ multiple: CGFloat) {
        defaults.set(Double(clampChatLineHeightMultiple(multiple)), forKey: chatLineHeightMultipleKey)
    }

    /// Upper bound for a single Anthropic reply (`max_tokens` is mandatory
    /// on that API). Default 32K so long-form replies stop truncating with
    /// finish_reason=length; legacy Claude 3.x models are clamped lower at
    /// request time (`AnthropicAdapter.maxOutputTokens(forModel:)`).
    static let anthropicMaxOutputTokensMin = 1_024
    static let anthropicMaxOutputTokensMax = 128_000
    static let anthropicMaxOutputTokensDefault = 32_768

    static func loadAnthropicMaxOutputTokens() -> Int {
        if defaults.object(forKey: anthropicMaxOutputTokensKey) == nil {
            return anthropicMaxOutputTokensDefault
        }
        let stored = defaults.integer(forKey: anthropicMaxOutputTokensKey)
        guard stored > 0 else { return anthropicMaxOutputTokensDefault }
        return clampAnthropicMaxOutputTokens(stored)
    }

    static func saveAnthropicMaxOutputTokens(_ value: Int) {
        defaults.set(clampAnthropicMaxOutputTokens(value), forKey: anthropicMaxOutputTokensKey)
    }

    static func clampAnthropicMaxOutputTokens(_ value: Int) -> Int {
        max(anthropicMaxOutputTokensMin, min(anthropicMaxOutputTokensMax, value))
    }

    static func clampChatBaseFontSize(_ size: CGFloat) -> CGFloat {
        max(chatBaseFontSizeMin, min(chatBaseFontSizeMax, size))
    }

    static func clampChatLineHeightMultiple(_ multiple: CGFloat) -> CGFloat {
        max(chatLineHeightMultipleMin, min(chatLineHeightMultipleMax, multiple))
    }

    /// Preserve deliberate custom sizes while moving installs that still use
    /// the old 14 pt default onto the Codex-aligned 15 pt baseline.
    static func migratedChatBaseFontSize(fromLegacy size: CGFloat?) -> CGFloat {
        guard let size, size > 0 else { return chatBaseFontSizeDefault }
        if size == 14 {
            return chatBaseFontSizeDefault
        }
        return clampChatBaseFontSize(size)
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
        /// Auxiliary model slots. `titleModel` was documented as persisted
        /// here from the start but never actually had a field, so a Title
        /// Model typed into Settings survived only until the next launch.
        var titleModel: String?
        var compressionModel: String?
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
            apiKey: loadAPIKey(account: keychainAccount),
            titleModel: stored.titleModel ?? "",
            compressionModel: stored.compressionModel ?? ""
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
            imageModel: normalized.imageDescription.model,
            titleModel: normalized.titleModel,
            compressionModel: normalized.compressionModel
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
        return WillDeepKeychainStore.load(
            service: keychainService,
            account: account
        ) ?? ""
    }

    private static func keychainStorageKey(account: String) -> String {
        "\(keychainService)/\(account)"
    }

    private static func deleteAPIKey(account: String) {
        if isRunningUnderXCTest {
            xctestKeychainStorage.removeValue(forKey: keychainStorageKey(account: account))
            return
        }
        WillDeepKeychainStore.delete(service: keychainService, account: account)
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
    /// 2. **Data Protection Keychain.** The shared transport scopes rows to
    ///    WillDeep's signed access group instead of the legacy per-binary ACL,
    ///    so app updates no longer reopen the password-only authorization
    ///    dialog. Existing rows migrate after their first successful read.
    /// 3. **`kSecAttrAccessible: AfterFirstUnlock`.** Once macOS has been
    ///    unlocked by login / Touch ID after boot, the row stays available
    ///    without repeated prompts.
    private static func saveAPIKey(_ apiKey: String, account: String) {
        // Empty value → delete the row (don't store empty data).
        guard !apiKey.isEmpty else {
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

        WillDeepKeychainStore.save(
            apiKey,
            service: keychainService,
            account: account
        )
    }
}

enum AgentCredentialStore {
    nonisolated static let referencePrefix = "keychain://"
    nonisolated private static let releaseKeychainService = "com.willdeep.credentials"
    nonisolated private static let debugKeychainService = "com.willdeep.credentials.debug"
    /// Unsandboxed macOS apps otherwise fall back to the legacy file-based
    /// Keychain, whose per-binary ACL can repeatedly show the password-only
    /// "wants to use your confidential information" dialog after an update.
    /// The Data Protection Keychain uses the signed app access group instead
    /// and follows the Mac's normal login / Touch ID unlock state.
    nonisolated static let usesDataProtectionKeychain = WillDeepKeychainStore.usesDataProtectionKeychain
    nonisolated static let appCredentialAccessGroup = WillDeepKeychainStore.accessGroup

    nonisolated(unsafe) private static var testKeychainServiceOverride: String?
    nonisolated(unsafe) private static var testKeychainStorage: [String: String]?
    nonisolated(unsafe) private static var xctestKeychainStorage: [String: String] = [:]
    nonisolated(unsafe) private static var testLoadCounts: [String: Int] = [:]
    nonisolated(unsafe) private static var testSaveCounts: [String: Int] = [:]

    nonisolated private static var keychainService: String {
        if let testKeychainServiceOverride {
            return testKeychainServiceOverride
        }
        #if DEBUG
        return serviceName(debugBuild: true)
        #else
        return serviceName(debugBuild: false)
        #endif
    }

    nonisolated static func serviceName(debugBuild: Bool) -> String {
        debugBuild ? debugKeychainService : releaseKeychainService
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
        _ = saveReportingStatus(secret, account: account)
    }

    /// Same as `save`, but surfaces the raw Keychain `OSStatus` so callers can
    /// log *why* a write failed instead of only inferring it from a later
    /// readback miss. Returns `errSecSuccess` for the in-memory test/XCTest
    /// stores (they cannot fail).
    @discardableResult
    nonisolated static func saveReportingStatus(_ secret: String, account: String) -> OSStatus {
        testSaveCounts[account, default: 0] += 1
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete(account: account)
            return errSecSuccess
        }

        if testKeychainStorage != nil {
            testKeychainStorage?[account] = trimmed
            return errSecSuccess
        }

        if isRunningUnderXCTest {
            xctestKeychainStorage[account] = trimmed
            return errSecSuccess
        }

        return WillDeepKeychainStore.save(
            trimmed,
            service: keychainService,
            account: account
        )
    }

    nonisolated static func load(account: String) -> String {
        testLoadCounts[account, default: 0] += 1
        if let testKeychainStorage {
            return testKeychainStorage[account] ?? ""
        }

        if isRunningUnderXCTest {
            return xctestKeychainStorage[account] ?? ""
        }

        return WillDeepKeychainStore.load(
            service: keychainService,
            account: account
        ) ?? ""
    }

    /// Returns account names only; secret bytes never leave Keychain. This is
    /// used to discover protected Composer secrets created before the alias
    /// index existed, so upgrades do not make those entries invisible.
    nonisolated static func accounts(matchingPrefix prefix: String) -> [String] {
        if let testKeychainStorage {
            return testKeychainStorage.keys.filter { $0.hasPrefix(prefix) }.sorted()
        }

        if isRunningUnderXCTest {
            return xctestKeychainStorage.keys.filter { $0.hasPrefix(prefix) }.sorted()
        }

        return WillDeepKeychainStore.accounts(
            service: keychainService,
            matchingPrefix: prefix
        )
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

        WillDeepKeychainStore.delete(service: keychainService, account: account)
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
