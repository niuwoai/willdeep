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
        minimumToolCallCount: 3,
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
    private static let defaultThresholdMigrationKey = "com.willdeep.agentSkillSettings.defaultThreshold.rc85"

    static func load() -> AgentSkillSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AgentSkillSettings.self, from: data) else {
            return .default
        }
        var normalized = settings.normalized
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: defaultThresholdMigrationKey),
           normalized.minimumToolCallCount == 5 {
            normalized.minimumToolCallCount = AgentSkillSettings.default.minimumToolCallCount
            save(normalized)
        }
        defaults.set(true, forKey: defaultThresholdMigrationKey)
        return normalized
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
    /// 用户自定义 skill 的主目录。1.85.0-rc5 起从 `~/.codex/skills/` 迁
    /// 到 `~/.willdeep/skills/` —— `.codex` 是借来的旧名，正式品牌叫
    /// WillDeep。新增 skill 默认写到 willdeep 目录;旧 codex 目录仍然
    /// 被 `AgentSkillDirectory` 扫描以兼容已经手写过 skill 的用户,但
    /// 不再作为创建目的地。
    static var userSkillsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".willdeep/skills")
    }

    /// Legacy 兼容根目录(只读)。仍会被扫描,但创建新 skill 一律写到
    /// `userSkillsRoot`。
    static var legacyCodexSkillsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/skills")
    }

    static func createUserSkill(
        name: String,
        description: String,
        body: String,
        root: URL = userSkillsRoot
    ) throws -> URL {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw AgentSkillFileError.invalidName
        }
        let slug = skillSlug(from: trimmedName)
        guard !slug.isEmpty else {
            throw AgentSkillFileError.invalidName
        }

        let skillDirectory = root.appendingPathComponent(slug)
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

    static func deleteUserSkill(
        _ skill: AgentSkillEntry,
        allowedRoots: [URL] = [userSkillsRoot, legacyCodexSkillsRoot]
    ) throws {
        guard skill.source == .user else {
            throw AgentSkillFileError.notUserSkill
        }

        let skillURL = skill.url.standardizedFileURL
        guard skillURL.lastPathComponent == "SKILL.md" else {
            throw AgentSkillFileError.unsafeDeletePath
        }

        let skillDirectory = skillURL.deletingLastPathComponent().standardizedFileURL
        guard isSkillDirectory(skillDirectory, inside: allowedRoots) else {
            throw AgentSkillFileError.unsafeDeletePath
        }

        try FileManager.default.removeItem(at: skillDirectory)
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

    private static func isSkillDirectory(_ directory: URL, inside allowedRoots: [URL]) -> Bool {
        let directoryPath = directory.standardizedFileURL.path
        return allowedRoots.contains { root in
            let rootPath = root.standardizedFileURL.path
            return directoryPath.hasPrefix(rootPath + "/")
        }
    }
}

enum AgentSkillFileError: LocalizedError {
    case invalidName
    case alreadyExists(String)
    case notUserSkill
    case unsafeDeletePath

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Skill name is required."
        case .alreadyExists(let slug):
            return "A user skill named \(slug) already exists."
        case .notUserSkill:
            return "Only user skills can be deleted."
        case .unsafeDeletePath:
            return "The skill path is outside the user skills folder."
        }
    }
}
