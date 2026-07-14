//
//  AgentSkillDirectory.swift
//  WillDeep
//
//  Codex skill discovery + the `list_skills`/`read_skill` tool wrappers,
//  split out of AgentTools.swift in rc42. Three pieces:
//   - `AgentSkillCatalog`: tool-call front-end (private; called from the
//     registry runner). Lists discovered skills and reads a single
//     SKILL.md body, with a character cap to keep one skill from blowing
//     the context budget.
//   - `AgentSkillEntry`: the public record exposed to UI consumers (the
//     `$skill` composer popover) so views can list and inline skills
//     without going through the LLM tool round-trip.
//   - `AgentSkillDirectory`: file-system enumeration over bundled,
//     user (~/.codex/skills), and plugin-cache roots; YAML front-matter
//     parsing for name/description; identifier normalization and dedupe.
//

import Foundation

enum AgentSkillCatalog {
    static func listSkills(arguments: [String: AgentJSONValue]) throws -> AgentToolResult {
        let query = arguments["query"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let skills = AgentSkillDirectory.list(includeDisabled: false).filter { record in
            guard let query, !query.isEmpty else { return true }
            return AgentSkillLocalization.searchableText(for: record).contains(query)
        }

        let lines = skills.map { record in
            "- \(record.identifier) | name=\(AgentSkillLocalization.displayName(for: record)) | \(AgentSkillLocalization.displayDescription(for: record))"
        }
        let payload = lines.isEmpty
            ? "No installed Codex skills found."
            : lines.joined(separator: "\n")
        return AgentToolResult(summary: "\(skills.count) skills", payload: payload)
    }

    static func readSkill(arguments: [String: AgentJSONValue]) throws -> AgentToolResult {
        guard let rawName = arguments["name"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty else {
            throw AgentToolError.missingArgument("name")
        }

        guard let record = AgentSkillDirectory.list(includeDisabled: false).first(where: {
            $0.identifier == rawName || $0.name == rawName
        }) else {
            throw AgentToolError.notFound(rawName)
        }

        guard let data = try? Data(contentsOf: record.url),
              let text = String(data: data, encoding: .utf8) else {
            throw AgentToolError.notFound(record.url.path)
        }

        let limited = limit(text.trimmingCharacters(in: .whitespacesAndNewlines), to: 48_000)
        return AgentToolResult(
            summary: record.name,
            payload: "Skill: \(record.identifier)\nPath: \(record.url.path)\n\n\(limited)"
        )
    }

    private static func limit(_ text: String, to maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let index = text.index(text.startIndex, offsetBy: maxCharacters)
        return "\(text[..<index])\n\n[truncated]"
    }
}

/// Public skill record + discovery surface for UI consumers (the `$skill`
/// composer popover). Mirrors `AgentSkillCatalog.SkillRecord` but exposed
/// outside the private enum so views and AppState helpers can list and
/// inline skills without going through the LLM tool-call round-trip.
nonisolated struct AgentSkillEntry: Identifiable, Equatable, Sendable {
    let identifier: String
    let name: String
    let description: String
    let url: URL
    let source: AgentSkillSource
    let isEnabled: Bool

    var id: String { identifier }
}

nonisolated enum AgentSkillDirectory {
    private struct SkillRoot {
        let url: URL
        let source: AgentSkillSource
    }

    /// Discovers built-in skills, user skills under ~/.codex/skills,
    /// and plugin-cache skills. Returns up to ~300 records sorted by
    /// source and identifier.
    static func list(includeDisabled: Bool = false) -> [AgentSkillEntry] {
        let settings = AgentSkillSettingsStore.load()
        var records: [AgentSkillEntry] = []

        for root in skillRoots() {
            records.append(contentsOf: discover(in: root, settings: settings))
            if records.count >= 300 { break }
        }

        let deduped = dedupe(records)
        let filtered = includeDisabled ? deduped : deduped.filter(\.isEnabled)
        return filtered.sorted { lhs, rhs in
            if lhs.source != rhs.source {
                return sourceOrder(lhs.source) < sourceOrder(rhs.source)
            }
            return lhs.identifier < rhs.identifier
        }
    }

    /// Settings panes are created on the main actor. Keep directory walking
    /// and SKILL.md parsing off that actor so switching panes stays responsive.
    static func listAsync(includeDisabled: Bool = false) async -> [AgentSkillEntry] {
        await Task.detached(priority: .userInitiated) {
            list(includeDisabled: includeDisabled)
        }.value
    }

    static var userSkillsRoot: URL {
        AgentSkillFileManager.userSkillsRoot
    }

    private static func skillRoots() -> [SkillRoot] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots: [SkillRoot] = bundledSkillRoots().map {
            SkillRoot(url: $0, source: .bundled)
        }
        // 1.85.0-rc5：主用户目录改 `~/.willdeep/skills/`,旧 `~/.codex/skills/`
        // 仍扫描以兼容老用户。两边都用 `.user` source —— UI 上区分起来意义
        // 不大,且两边创建的 skill 行为完全等价。
        roots.append(SkillRoot(url: AgentSkillFileManager.userSkillsRoot, source: .user))
        roots.append(SkillRoot(url: AgentSkillFileManager.legacyCodexSkillsRoot, source: .user))
        roots.append(SkillRoot(url: home.appendingPathComponent(".codex/plugins/cache"), source: .plugin))
        return roots
    }

    /// 暴露所有 skill 根目录的纯 URL 列表,给 `UserWorkflowRegistry`
    /// 复用——同一套发现路径,不重复造轮子。
    static func allSkillRootURLs() -> [URL] {
        skillRoots().map(\.url)
    }

    private static func bundledSkillRoots() -> [URL] {
        var roots: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("BundledSkills")
            if FileManager.default.fileExists(atPath: bundled.path) {
                roots.append(bundled)
            }
        }
        let sourceTree = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("BundledSkills")
        if FileManager.default.fileExists(atPath: sourceTree.path),
           !roots.contains(where: { $0.standardizedFileURL.path == sourceTree.standardizedFileURL.path }) {
            roots.append(sourceTree)
        }
        return roots
    }

    private static func discover(in root: SkillRoot, settings: AgentSkillSettings) -> [AgentSkillEntry] {
        guard FileManager.default.fileExists(atPath: root.url.path),
              let enumerator = FileManager.default.enumerator(
                at: root.url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
              ) else {
            return []
        }

        var records: [AgentSkillEntry] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "SKILL.md",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }

            let metadata = parseMetadata(from: text)
            let fallbackName = url.deletingLastPathComponent().lastPathComponent
            let name = metadata.name.isEmpty ? fallbackName : metadata.name
            let identifier = identifier(for: url, root: root.url, fallback: name, source: root.source)
            records.append(AgentSkillEntry(
                identifier: identifier,
                name: name,
                description: metadata.description.isEmpty ? "(no description)" : metadata.description,
                url: url,
                source: root.source,
                isEnabled: settings.isEnabled(identifier: identifier)
            ))

            if records.count >= 300 { break }
        }
        return records
    }

    /// Reads the full SKILL.md body, capped at `maxCharacters` to keep
    /// any single skill from blowing the context budget. Returns nil if
    /// the file is unreadable.
    static func loadBody(for entry: AgentSkillEntry, maxCharacters: Int = 24_000) -> String? {
        guard let data = try? Data(contentsOf: entry.url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxCharacters { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: maxCharacters)
        return "\(trimmed[..<idx])\n\n[truncated]"
    }

    private static func parseMetadata(from text: String) -> (name: String, description: String) {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "---" else { return ("", "") }

        var name = ""
        var description = ""
        for line in lines.dropFirst() {
            if line == "---" { break }
            if let value = yamlValue(line, key: "name") {
                name = value
            } else if let value = yamlValue(line, key: "description") {
                description = value
            }
        }
        return (name, description)
    }

    private static func yamlValue(_ line: String, key: String) -> String? {
        let prefix = "\(key):"
        guard line.hasPrefix(prefix) else { return nil }
        var value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    private static func identifier(for url: URL, root: URL, fallback: String, source: AgentSkillSource) -> String {
        let rootPath = root.standardizedFileURL.path
        let skillPath = url.deletingLastPathComponent().standardizedFileURL.path
        guard skillPath.hasPrefix(rootPath) else { return fallback }
        let relative = String(skillPath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = relative.split(separator: "/").map(String.init)
        if let skillsIndex = parts.lastIndex(of: "skills"), skillsIndex + 1 < parts.count {
            return parts[(skillsIndex + 1)...].joined(separator: ":")
        }
        return parts.joined(separator: ":")
    }

    private static func dedupe(_ records: [AgentSkillEntry]) -> [AgentSkillEntry] {
        var seen = Set<String>()
        var result: [AgentSkillEntry] = []
        for record in records.sorted(by: { sourceOrder($0.source) < sourceOrder($1.source) }) {
            guard seen.insert(record.identifier).inserted else { continue }
            result.append(record)
        }
        return result
    }

    private static func sourceOrder(_ source: AgentSkillSource) -> Int {
        switch source {
        case .bundled:
            return 0
        case .user:
            return 1
        case .plugin:
            return 2
        }
    }
}
