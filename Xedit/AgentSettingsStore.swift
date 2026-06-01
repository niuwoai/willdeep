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
    private static let keychainService = "im.some.veilwriter.agent"
    private static let keychainAccount = "openai-compatible-api-key"

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

    private struct StoredSettings: Codable {
        var providerID: String?
        var baseURL: String
        var model: String
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
                model: AgentConfiguration.default.model
            )
        }

        return AgentConfiguration(
            providerID: stored.providerID ?? AgentProviderPreset.matchingBaseURL(stored.baseURL)?.id ?? AgentProviderPreset.customID,
            baseURL: stored.baseURL,
            model: stored.model,
            apiKey: loadAPIKey()
        ).normalized
    }

    static func save(_ configuration: AgentConfiguration) {
        let normalized = configuration.normalized
        let stored = StoredSettings(
            providerID: normalized.providerID,
            baseURL: normalized.baseURL,
            model: normalized.model
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        saveAPIKey(normalized.apiKey)
    }

    private static func loadAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
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

    private static func saveAPIKey(_ apiKey: String) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard !apiKey.isEmpty, let data = apiKey.data(using: .utf8) else { return }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
