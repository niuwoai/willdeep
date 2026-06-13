//
//  AgentGlobalRulesStore.swift
//  WillDeep
//
//  Stores the user-level Agent rules file preference and reads its content.
//

import Foundation

struct AgentGlobalRulesSettings: Codable, Equatable {
    var isEnabled: Bool
    var filePath: String

    static let defaultFilePath = "~/.willdeep/CLAUDE.md"
    static let `default` = AgentGlobalRulesSettings(
        isEnabled: true,
        filePath: defaultFilePath
    )

    var normalized: AgentGlobalRulesSettings {
        var copy = self
        copy.filePath = copy.filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.filePath.isEmpty {
            copy.filePath = Self.defaultFilePath
        }
        return copy
    }
}

enum AgentGlobalRulesStore {
    private static let settingsKey = "com.willdeep.agentGlobalRules.settings.v1"
    static let maxRulesCharacters = 8_000

    static func loadSettings() -> AgentGlobalRulesSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AgentGlobalRulesSettings.self, from: data) else {
            return .default
        }
        return settings.normalized
    }

    static func saveSettings(_ settings: AgentGlobalRulesSettings) {
        guard let data = try? JSONEncoder().encode(settings.normalized) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }

    static func resolvedURL(for filePath: String) -> URL {
        let normalized = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = normalized.isEmpty ? AgentGlobalRulesSettings.defaultFilePath : normalized
        let expanded: String
        if path == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if path.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)))
                .path
        } else {
            expanded = (path as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    static func displayPath(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~/" + String(path.dropFirst(home.count + 1))
        }
        return path
    }

    static func loadRules(settings: AgentGlobalRulesSettings = loadSettings()) -> String? {
        let settings = settings.normalized
        guard settings.isEnabled else { return nil }
        return readRules(at: resolvedURL(for: settings.filePath))
    }

    static func readRules(at url: URL) -> String? {
        guard let trimmed = readRulesFileText(at: url)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return limit(trimmed, to: maxRulesCharacters)
    }

    static func readRulesFileText(at url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    static func saveRules(_ text: String, settings: AgentGlobalRulesSettings = loadSettings()) throws {
        let url = resolvedURL(for: settings.normalized.filePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func limit(_ text: String, to maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let index = text.index(text.startIndex, offsetBy: maxCharacters)
        return "\(text[..<index])\n\n[truncated]"
    }
}
