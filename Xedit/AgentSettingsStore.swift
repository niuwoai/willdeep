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
    /// JSON-encoded `AgentProviderLibrary` minus the API keys, which
    /// live in Keychain under the entry's UUID.
    private static let providerLibraryKey = "im.some.veilwriter.agentSettings.providerLibrary.v1"
    private static let keychainService = "im.some.veilwriter.agent"
    private static let keychainAccount = "openai-compatible-api-key"
    private static let imageKeychainAccount = "openai-compatible-image-description-api-key"
    /// Keychain account prefix for per-entry library keys
    /// (full account = `libraryEntryKeychainPrefix + UUID string`).
    private static let libraryEntryKeychainPrefix = "library-entry-"

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

    static func save(_ configuration: AgentConfiguration) {
        let normalized = configuration.normalized
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
        saveAPIKey(normalized.apiKey, account: keychainAccount)
        saveAPIKey(normalized.imageDescription.apiKey, account: imageKeychainAccount)
    }

    // MARK: - Provider library

    /// Load the multi-provider library. JSON-encoded entries live in
    /// UserDefaults; API keys live in Keychain keyed by entry UUID and
    /// are reattached here before returning. If the library is missing
    /// or empty, migrate from the legacy single-provider
    /// `AgentConfiguration` so existing users land smoothly on a
    /// library containing exactly their previous setup.
    static func loadProviderLibrary() -> AgentProviderLibrary {
        if let data = UserDefaults.standard.data(forKey: providerLibraryKey),
           let stored = try? JSONDecoder().decode(StoredLibrary.self, from: data) {
            let entries = stored.entries.map { stripped -> AgentProviderEntry in
                var entry = stripped
                entry.apiKey = loadAPIKey(account: libraryEntryKeychainAccount(for: entry.id))
                return entry
            }
            return AgentProviderLibrary(entries: entries, activeID: stored.activeID)
        }
        // Migration path — wrap the legacy AgentConfiguration in a
        // single-entry library on first launch after this change.
        let legacy = load()
        let migrated = AgentProviderLibrary.migrate(from: legacy)
        saveProviderLibrary(migrated)
        return migrated
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

    private static func saveAPIKey(_ apiKey: String, account: String) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard !apiKey.isEmpty, let data = apiKey.data(using: .utf8) else { return }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
