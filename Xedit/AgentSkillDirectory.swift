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
    static func listSkills(
        arguments: [String: AgentJSONValue],
        includeDispatchHint: Bool = false
    ) throws -> AgentToolResult {
        let query = arguments["query"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let skills = AgentSkillDirectory.list(includeDisabled: false).filter { record in
            guard let query, !query.isEmpty else { return true }
            return AgentSkillLocalization.searchableText(for: record).contains(query)
        }

        let lines = skills.map { record in
            // The tier rides in the listing so the dispatch decision can be
            // made before the body is read: `tier=worker` → package a task
            // packet and spawn the matching trade instead of running inline.
            let tier = record.tier.map { " | tier=\($0.rawValue)" } ?? ""
            return "- \(record.identifier) | name=\(AgentSkillLocalization.displayName(for: record))\(tier) | \(AgentSkillLocalization.displayDescription(for: record))"
        }
        var payload = lines.isEmpty
            ? "No installed Codex skills found."
            : lines.joined(separator: "\n")
        // Deterministic dispatch trigger, same philosophy as the failed-test
        // hint: visibility must not depend on the model remembering the
        // routing rule — the dispatch-rate audit measured what "remembering"
        // is worth (1.4%). Main loop only: a child cannot spawn, and a hint
        // it cannot act on is just noise in a small window.
        if includeDispatchHint {
            let workers = skills.filter { $0.tier == .worker }.map(\.identifier)
            if !workers.isEmpty {
                payload += """


                <delegation-hint tier="worker">
                These skills fit a small-context worker: \(workers.joined(separator: ", ")). Instead of running one inline, spawn_agent with a task packet — set task.skill to the skill name (the runtime inlines its body for the worker), task.goal to the outcome, and task.relevant_files to the inputs. Your window stays free and the worker starts warm.
                </delegation-hint>
                """
            }
        }
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

        let resource = arguments["resource"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resourceURL = try resolvedResourceURL(for: record, resource: resource)
        guard let data = try? Data(contentsOf: resourceURL),
              let text = String(data: data, encoding: .utf8) else {
            throw AgentToolError.notFound(resourceURL.path)
        }

        let limited = limit(text.trimmingCharacters(in: .whitespacesAndNewlines), to: 48_000)
        let relativePath = resourceURL.path.replacingOccurrences(
            of: record.url.deletingLastPathComponent().path + "/",
            with: ""
        )
        return AgentToolResult(
            summary: resource == nil || resource?.isEmpty == true ? record.name : "\(record.name): \(relativePath)",
            payload: "Skill: \(record.identifier)\nResource: \(relativePath)\nPath: \(resourceURL.path)\n\n\(limited)"
        )
    }

    private static func resolvedResourceURL(
        for record: AgentSkillEntry,
        resource: String?
    ) throws -> URL {
        guard let resource, !resource.isEmpty else { return record.url }
        let skillRoot = record.url.deletingLastPathComponent().resolvingSymlinksInPath()
        let candidate = skillRoot
            .appendingPathComponent(resource, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let allowedPrefix = skillRoot.path.hasSuffix("/") ? skillRoot.path : skillRoot.path + "/"
        guard candidate.path.hasPrefix(allowedPrefix),
              (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw AgentToolError.notFound(resource)
        }
        return candidate
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
/// Context tier a skill declares for itself (`tier:` in SKILL.md
/// frontmatter). Shared semantics with willdeep-rs (model-tiers.v1): this is
/// a dispatch hint read *before* the skill body — a worker-tier skill is a
/// spawn_agent candidate, not a reason to burn the parent's window. The point
/// is sovereignty as much as cost: in an air-gapped deployment the deployable
/// models are usually exactly the ones the worker and standard tiers run on.
nonisolated enum AgentSkillTier: String, Sendable {
    /// 32–64K window, verifiable or strongly templated work.
    case worker
    /// ~256K window: the session's default tier.
    case standard
    /// Long-context work that needs the largest window available.
    case deep

    /// Unknown spellings are user data, not errors: a skill written for some
    /// other tool must not break discovery here.
    static func parse(_ value: String) -> AgentSkillTier? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "worker", "small": return .worker
        case "standard", "medium": return .standard
        case "deep", "large": return .deep
        default: return nil
        }
    }
}

nonisolated struct AgentSkillEntry: Identifiable, Equatable, Sendable {
    let identifier: String
    let name: String
    let description: String
    /// Declared context tier, if the skill's frontmatter names one. Defaults
    /// to nil so the dozens of existing construction sites (tests included)
    /// stay valid — an untagged skill is the common case, not an error.
    let tier: AgentSkillTier?
    let url: URL
    let source: AgentSkillSource
    let isEnabled: Bool

    init(
        identifier: String,
        name: String,
        description: String,
        tier: AgentSkillTier? = nil,
        url: URL,
        source: AgentSkillSource,
        isEnabled: Bool
    ) {
        self.identifier = identifier
        self.name = name
        self.description = description
        self.tier = tier
        self.url = url
        self.source = source
        self.isEnabled = isEnabled
    }

    var id: String { identifier }
}

/// Process-wide cache for filesystem skill discovery.
///
/// Discovery walks bundled, user, legacy, and plugin roots and may read
/// hundreds of SKILL.md files. Keep one snapshot until a real filesystem
/// mutation invalidates it, and collapse concurrent cold loads into one scan.
nonisolated final class AgentSkillCatalogCache: @unchecked Sendable {
    private let condition = NSCondition()
    private var records: [AgentSkillEntry]?
    private var revisionValue = 0
    private var loadingRevision: Int?

    var revision: Int {
        condition.lock()
        let value = revisionValue
        condition.unlock()
        return value
    }

    func value(loader: () -> [AgentSkillEntry]) -> [AgentSkillEntry] {
        while true {
            condition.lock()
            if let records {
                condition.unlock()
                return records
            }

            if loadingRevision == nil {
                let targetRevision = revisionValue
                loadingRevision = targetRevision
                condition.unlock()

                let loadedRecords = loader()

                condition.lock()
                if revisionValue == targetRevision {
                    records = loadedRecords
                }
                loadingRevision = nil
                let currentRecords = records
                condition.broadcast()
                condition.unlock()

                if let currentRecords {
                    return currentRecords
                }
                continue
            }

            condition.wait()
            condition.unlock()
        }
    }

    func invalidate() {
        condition.lock()
        revisionValue &+= 1
        records = nil
        condition.broadcast()
        condition.unlock()
    }
}

nonisolated enum AgentSkillDirectory {
    private struct SkillRoot {
        let url: URL
        let source: AgentSkillSource
    }

    private static let catalogCache = AgentSkillCatalogCache()

    /// Discovers built-in skills, user skills under ~/.codex/skills,
    /// and plugin-cache skills. Returns up to ~300 records sorted by
    /// source and identifier.
    static func list(includeDisabled: Bool = false) -> [AgentSkillEntry] {
        let settings = AgentSkillSettingsStore.load()
        let records = catalogCache.value {
            scanSkillRoots()
        }

        return records.compactMap { record in
            let isEnabled = settings.isEnabled(identifier: record.identifier)
            guard includeDisabled || isEnabled else { return nil }
            return AgentSkillEntry(
                identifier: record.identifier,
                name: record.name,
                description: record.description,
                tier: record.tier,
                url: record.url,
                source: record.source,
                isEnabled: isEnabled
            )
        }
    }

    /// Current filesystem cache revision. UI consumers can cheaply decide
    /// whether an already displayed catalog needs an asynchronous refresh.
    static var cacheRevision: Int {
        catalogCache.revision
    }

    /// Call after a skill file or directory is created, updated, or removed.
    /// Enabled/disabled settings do not need invalidation because `list`
    /// overlays those flags on the cached filesystem records.
    static func invalidateCache() {
        catalogCache.invalidate()
    }

    private static func scanSkillRoots() -> [AgentSkillEntry] {
        var records: [AgentSkillEntry] = []

        for root in skillRoots() {
            records.append(contentsOf: discover(in: root))
            if records.count >= 300 { break }
        }

        let deduped = dedupe(records)
        return deduped.sorted { lhs, rhs in
            if lhs.source != rhs.source {
                return sourceOrder(lhs.source) < sourceOrder(rhs.source)
            }
            return lhs.identifier < rhs.identifier
        }
    }

    /// Settings panes are created on the main actor. Keep directory walking
    /// and SKILL.md parsing off that actor so switching panes stays responsive.
    static func listAsync(
        includeDisabled: Bool = false,
        forceRefresh: Bool = false
    ) async -> [AgentSkillEntry] {
        await Task.detached(priority: .userInitiated) {
            if forceRefresh {
                invalidateCache()
            }
            return list(includeDisabled: includeDisabled)
        }.value
    }

    static var userSkillsRoot: URL {
        AgentSkillFileManager.userSkillsRoot
    }

    /// Resolves one top-level bundled skill without enumerating user/plugin
    /// roots. Auto-activation runs on the send path, so it must stay bounded.
    static func bundledSkill(identifier: String, includeDisabled: Bool = false) -> AgentSkillEntry? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil else {
            return nil
        }

        let settings = AgentSkillSettingsStore.load()
        let isEnabled = settings.isEnabled(identifier: trimmed)
        guard includeDisabled || isEnabled else { return nil }

        for root in bundledSkillRoots() {
            let url = root
                .appendingPathComponent(trimmed, isDirectory: true)
                .appendingPathComponent("SKILL.md", isDirectory: false)
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }
            let metadata = parseMetadata(from: text)
            return AgentSkillEntry(
                identifier: trimmed,
                name: metadata.name.isEmpty ? trimmed : metadata.name,
                description: metadata.description.isEmpty ? "(no description)" : metadata.description,
                tier: metadata.tier,
                url: url,
                source: .bundled,
                isEnabled: isEnabled
            )
        }
        return nil
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

    private static func discover(in root: SkillRoot) -> [AgentSkillEntry] {
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
                tier: metadata.tier,
                url: url,
                source: root.source,
                isEnabled: true
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

    static func parseMetadata(
        from text: String
    ) -> (name: String, description: String, tier: AgentSkillTier?) {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "---" else { return ("", "", nil) }

        var name = ""
        var description = ""
        var tier: AgentSkillTier?
        for line in lines.dropFirst() {
            if line == "---" { break }
            if let value = yamlValue(line, key: "name") {
                name = value
            } else if let value = yamlValue(line, key: "description") {
                description = value
            } else if let value = yamlValue(line, key: "tier") {
                tier = AgentSkillTier.parse(value)
            }
        }
        return (name, description, tier)
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
