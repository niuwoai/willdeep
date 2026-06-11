//
//  AgentSkillSettingsStore.swift
//  WillDeep
//
//  Local settings and helpers for built-in and user-created Agent skills.
//

import Foundation

struct AgentSkillSettings: Codable, Equatable {
    var autoExtractionEnabled: Bool
    var minimumToolCallCount: Int
    var disabledSkillIdentifiers: [String]

    static let `default` = AgentSkillSettings(
        autoExtractionEnabled: true,
        minimumToolCallCount: 5,
        disabledSkillIdentifiers: []
    )

    var normalized: AgentSkillSettings {
        var copy = self
        copy.minimumToolCallCount = max(1, min(50, copy.minimumToolCallCount))
        copy.disabledSkillIdentifiers = Array(Set(copy.disabledSkillIdentifiers.filter { !$0.isEmpty })).sorted()
        return copy
    }

    func isEnabled(identifier: String) -> Bool {
        !disabledSkillIdentifiers.contains(identifier)
    }
}

enum AgentSkillSettingsStore {
    private static let settingsKey = "com.willdeep.agentSkillSettings.v1"

    static func load() -> AgentSkillSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AgentSkillSettings.self, from: data) else {
            return .default
        }
        return settings.normalized
    }

    static func save(_ settings: AgentSkillSettings) {
        guard let data = try? JSONEncoder().encode(settings.normalized) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }

    static func isSkillEnabled(identifier: String) -> Bool {
        load().isEnabled(identifier: identifier)
    }

    static func setSkillEnabled(identifier: String, enabled: Bool) {
        var settings = load()
        var disabled = Set(settings.disabledSkillIdentifiers)
        if enabled {
            disabled.remove(identifier)
        } else {
            disabled.insert(identifier)
        }
        settings.disabledSkillIdentifiers = Array(disabled)
        save(settings)
    }
}

enum AgentSkillSource: String, Codable, CaseIterable, Identifiable {
    case bundled
    case user
    case plugin

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bundled:
            return "Built-in"
        case .user:
            return "User"
        case .plugin:
            return "Plugin"
        }
    }
}

enum AgentSkillFileManager {
    static var userSkillsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/skills")
    }

    static func createUserSkill(name: String, description: String, body: String) throws -> URL {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw AgentSkillFileError.invalidName
        }
        let slug = skillSlug(from: trimmedName)
        guard !slug.isEmpty else {
            throw AgentSkillFileError.invalidName
        }

        let skillDirectory = userSkillsRoot.appendingPathComponent(slug)
        let skillURL = skillDirectory.appendingPathComponent("SKILL.md")
        if FileManager.default.fileExists(atPath: skillURL.path) {
            throw AgentSkillFileError.alreadyExists(slug)
        }

        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        let markdown = """
        ---
        name: \(trimmedName)
        description: \(description.trimmingCharacters(in: .whitespacesAndNewlines))
        ---

        # \(trimmedName)

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))
        """
        try markdown.write(to: skillURL, atomically: true, encoding: .utf8)
        return skillURL
    }

    private static func skillSlug(from name: String) -> String {
        let lowercased = name.lowercased()
        var slug = ""
        var previousWasDash = false
        for scalar in lowercased.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash {
                slug.append("-")
                previousWasDash = true
            }
        }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

enum AgentSkillFileError: LocalizedError {
    case invalidName
    case alreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Skill name is required."
        case .alreadyExists(let slug):
            return "A user skill named \(slug) already exists."
        }
    }
}
