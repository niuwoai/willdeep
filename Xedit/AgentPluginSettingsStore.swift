//
//  AgentPluginSettingsStore.swift
//  WillDeep
//

import Foundation

nonisolated enum AgentPluginSettingsStore {
    private static let defaultsPrefix = "com.willdeep.plugin.setting"

    static func value(
        pluginID: AgentPluginID,
        setting: AgentPluginSettingContribution,
        defaults: UserDefaults = .standard
    ) -> String {
        if setting.type == .secret {
            return AgentCredentialStore.load(account: credentialAccount(pluginID: pluginID, settingID: setting.id))
        }
        return defaults.string(forKey: defaultsKey(pluginID: pluginID, settingID: setting.id))
            ?? setting.defaultValue
            ?? ""
    }

    static func setValue(
        _ value: String,
        pluginID: AgentPluginID,
        setting: AgentPluginSettingContribution,
        defaults: UserDefaults = .standard
    ) {
        if setting.type == .secret {
            AgentCredentialStore.save(value, account: credentialAccount(pluginID: pluginID, settingID: setting.id))
            return
        }
        defaults.set(value, forKey: defaultsKey(pluginID: pluginID, settingID: setting.id))
    }

    static func removeAll(
        pluginID: AgentPluginID,
        settings: [AgentPluginSettingContribution],
        defaults: UserDefaults = .standard
    ) {
        for setting in settings {
            if setting.type == .secret {
                AgentCredentialStore.delete(account: credentialAccount(pluginID: pluginID, settingID: setting.id))
            } else {
                defaults.removeObject(forKey: defaultsKey(pluginID: pluginID, settingID: setting.id))
            }
        }
    }

    static func credentialAccount(pluginID: String, settingID: String) -> String {
        "plugin/\(sanitize(pluginID))/\(sanitize(settingID))"
    }

    private static func defaultsKey(pluginID: String, settingID: String) -> String {
        "\(defaultsPrefix).\(sanitize(pluginID)).\(sanitize(settingID))"
    }

    private static func sanitize(_ value: String) -> String {
        value.map { character in
            character.isLetter || character.isNumber || "-_.".contains(character) ? character : "_"
        }.reduce(into: "", { $0.append($1) })
    }
}
