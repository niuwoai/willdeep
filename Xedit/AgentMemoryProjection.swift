//
//  AgentMemoryProjection.swift
//  WillDeep
//
//  Human-readable Markdown mirror of Agent memory, plus the compact index the
//  model sees every turn.
//
//  Records themselves live in UserDefaults (`AgentMemorySettingsStore`), which
//  is authoritative but invisible: you cannot grep it, diff it, or put it in a
//  review. This projects the same records onto disk as one file per memory
//  under a `MEMORY.md` index, following the layout already settled in
//  docs/AGENT_PROJECT_MEMORY_DESIGN.md.
//
//  The projection is deliberately one-way. Two writable copies of the same
//  fact would need conflict resolution nobody asked for, so the files carry a
//  generated-header and the store stays the single source of truth. The model
//  reads memory through `read_memory`, which also goes to the store — a file
//  that has drifted can never feed it a stale answer.
//

import Foundation

nonisolated enum AgentMemoryProjection {
    // MARK: - Location

    /// Test seam: when set, projected Markdown lands here instead of
    /// Application Support.
    nonisolated(unsafe) static var directoryOverride: URL?

    /// The shipping location, never redirected.
    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WillDeep", isDirectory: true)
            .appendingPathComponent("AgentMemory", isDirectory: true)
    }

    /// Every test process gets a throwaway tree, for the same reason
    /// `AgentSessionStore` and `AgentRoutineStore` do: tests exercise the
    /// memory store, and a projection pointed at the real directory would
    /// rewrite the user's actual memory files.
    private static let testSandboxDirectory: URL? = {
        let environment = ProcessInfo.processInfo.environment
        let underTest = NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest") != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        guard underTest else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WillDeepTests-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
            .appendingPathComponent("AgentMemory", isDirectory: true)
    }()

    static var directory: URL {
        directoryOverride ?? testSandboxDirectory ?? applicationSupportDirectory
    }

    /// `global/` for user-wide memories, `projects/<fingerprint>/` for each
    /// workspace. Project memories are only recalled inside their own
    /// workspace, so keeping them in separate trees means a directory listing
    /// answers "what does the Agent know about this repo?" on its own.
    /// `root` is explicit rather than read from `directory` inside, so callers
    /// — tests especially — can target a tree of their own without mutating
    /// process-global state that a concurrently running test would clobber.
    static func directory(
        for scope: AgentMemoryScope,
        projectFingerprint: String?,
        root: URL = AgentMemoryProjection.directory
    ) -> URL {
        switch scope {
        case .global:
            return root.appendingPathComponent("global", isDirectory: true)
        case .project:
            let key = projectFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines)
            return root
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(
                    key?.isEmpty == false ? key! : "unbound",
                    isDirectory: true
                )
        }
    }

    // MARK: - Limits

    /// Matches what Claude Code loads from its own `MEMORY.md`. Past this an
    /// index stops being a table of contents and becomes another thing to
    /// scroll past.
    static let maximumIndexEntries = 200
    static let maximumIndexCharacters = 25_000
    /// A hook has to convey the memory on its own — the index is the only part
    /// guaranteed to reach the model, so a title-only entry ("database
    /// migrations") leaves a weak model with nothing usable and no reason to
    /// pull the detail.
    static let maximumHookCharacters = 150
    static let maximumTitleCharacters = 40

    // MARK: - Shaping (pure — no disk access)

    struct Entry: Equatable, Identifiable {
        let id: UUID
        /// Stable file name stem. Content-derived so a memory keeps its file
        /// across edits, with an id suffix so two similar memories cannot
        /// collide onto one path.
        let slug: String
        let title: String
        let hook: String
        let record: AgentMemoryRecord
    }

    static func entry(for record: AgentMemoryRecord) -> Entry {
        let normalized = record.normalized
        return Entry(
            id: normalized.id,
            slug: slug(for: normalized),
            title: title(for: normalized),
            hook: hook(for: normalized),
            record: normalized
        )
    }

    /// Short id prefix the model passes to `read_memory`. Full UUIDs are
    /// unreadable in an index and needlessly expensive to echo back.
    static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    static func title(for record: AgentMemoryRecord) -> String {
        let firstLine = record.content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !firstLine.isEmpty else { return "memory" }
        // Cut at the first sentence break when there is one close enough to
        // read as a title; otherwise just clip.
        let breakSet = CharacterSet(charactersIn: "。．.:：—-·")
        if let breakIndex = firstLine.unicodeScalars.firstIndex(where: { breakSet.contains($0) }) {
            let head = String(String.UnicodeScalarView(firstLine.unicodeScalars[..<breakIndex]))
                .trimmingCharacters(in: .whitespaces)
            if head.count >= 4, head.count <= maximumTitleCharacters {
                return head
            }
        }
        return clip(firstLine, to: maximumTitleCharacters)
    }

    static func hook(for record: AgentMemoryRecord) -> String {
        let flattened = record.content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        return clip(flattened, to: maximumHookCharacters)
    }

    static func slug(for record: AgentMemoryRecord) -> String {
        let keywords = record.topics.isEmpty
            ? AgentMemoryKeywordExtractor.keywords(from: record.content, limit: 4)
            : Array(record.topics.prefix(4))
        let stem = keywords
            .map { $0.lowercased() }
            .joined(separator: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let trimmed = String(stem.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // The id suffix is not decoration: keyword stems collide readily
        // (three memories about "release" all reduce to `release`), and a
        // collision would make one memory overwrite another's file.
        return trimmed.isEmpty ? "memory-\(shortID(record.id))" : "\(trimmed)-\(shortID(record.id))"
    }

    /// The `MEMORY.md` body. Entries are expected pre-sorted by the caller.
    static func indexMarkdown(heading: String, entries: [Entry]) -> String {
        var lines = [
            "# \(heading)",
            "",
            "<!-- Generated by WillDeep from Agent memory. Edits here are overwritten;",
            "     change memories in Settings → AI Agents → 记忆. -->",
            "",
        ]
        guard !entries.isEmpty else {
            lines.append("_(empty)_")
            return lines.joined(separator: "\n") + "\n"
        }

        var used = lines.joined(separator: "\n").count
        var written = 0
        for entry in entries {
            guard written < maximumIndexEntries else { break }
            let line = "- [`\(shortID(entry.id))`](topics/\(entry.slug).md) **\(entry.title)** — \(entry.hook)"
            guard used + line.count + 1 <= maximumIndexCharacters else { break }
            lines.append(line)
            used += line.count + 1
            written += 1
        }
        if written < entries.count {
            lines.append("")
            lines.append("_\(entries.count - written) more not listed (index capped). Open the topics/ directory or Settings → AI Agents → 记忆._")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func topicMarkdown(for entry: Entry) -> String {
        let record = entry.record
        let formatter = ISO8601DateFormatter()
        var lines = [
            "---",
            "id: \(record.id.uuidString)",
            "short_id: \(shortID(record.id))",
            "title: \(entry.title)",
            "scope: \(record.scope.rawValue)",
            "lifetime: \(record.lifetime.rawValue)",
        ]
        if !record.topics.isEmpty {
            lines.append("topics: [\(record.topics.sorted().joined(separator: ", "))]")
        }
        if let path = record.projectPath, !path.isEmpty {
            lines.append("project_path: \(path)")
        }
        lines.append("confidence: \(String(format: "%.2f", record.confidence))")
        if record.containsSensitiveContent {
            lines.append("contains_sensitive_content: true")
        }
        lines.append("created: \(formatter.string(from: record.createdAt))")
        lines.append("updated: \(formatter.string(from: record.updatedAt))")
        if let archivedAt = record.archivedAt {
            lines.append("archived: \(formatter.string(from: archivedAt))")
        }
        lines.append("---")
        lines.append("")
        lines.append(record.content)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Writing

    /// Serial, off the caller's thread: `saveRecords` runs from a `@Published`
    /// didSet on the main actor and can fire several times per turn. Writing a
    /// few dozen small files there would be main-thread I/O for no reason.
    private static let writeQueue = DispatchQueue(
        label: "com.willdeep.agentMemoryProjection",
        qos: .utility
    )

    static func project(records: [AgentMemoryRecord]) {
        let snapshot = records.map(\.normalized)
        let root = directory
        writeQueue.async {
            writeSynchronously(records: snapshot, root: root)
        }
    }

    /// Test entry point. Production goes through `project(records:)`.
    static func writeSynchronously(
        records: [AgentMemoryRecord],
        root: URL = AgentMemoryProjection.directory
    ) {
        // Archived memories are excluded on purpose: the projection answers
        // "what does the Agent currently know", and retrieval already skips
        // archived records. They remain in the store and in the Settings UI.
        let live = records.map(\.normalized).filter { !$0.isArchived }
        var byDirectory: [URL: [Entry]] = [:]
        for record in live {
            let target = directory(
                for: record.scope,
                projectFingerprint: record.projectFingerprint,
                root: root
            )
            byDirectory[target, default: []].append(entry(for: record))
        }

        for (target, entries) in byDirectory {
            let sorted = entries.sorted { lhs, rhs in
                if lhs.record.updatedAt != rhs.record.updatedAt {
                    return lhs.record.updatedAt > rhs.record.updatedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            write(entries: sorted, to: target)
        }

        pruneEmptyProjectDirectories(keeping: Set(byDirectory.keys), root: root)
    }

    private static func write(entries: [Entry], to target: URL) {
        let topics = target.appendingPathComponent("topics", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: topics, withIntermediateDirectories: true)
        } catch {
            return
        }

        let heading = target.lastPathComponent == "global"
            ? "Agent 记忆索引（全局）"
            : "项目记忆索引"
        writeIfChanged(
            indexMarkdown(heading: heading, entries: entries),
            to: target.appendingPathComponent("MEMORY.md")
        )

        var expected = Set<String>()
        for entry in entries {
            let name = "\(entry.slug).md"
            expected.insert(name)
            writeIfChanged(topicMarkdown(for: entry), to: topics.appendingPathComponent(name))
        }

        // A deleted or archived memory has to lose its file, otherwise the
        // directory keeps asserting something the Agent no longer believes.
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: topics,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in existing where url.pathExtension == "md" && !expected.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Rewriting an unchanged file would churn its mtime on every keystroke-
    /// triggered save and make the directory useless as a change log.
    private static func writeIfChanged(_ contents: String, to url: URL) {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == contents {
            return
        }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Removing the last memory for a project should leave no directory
    /// claiming the Agent still knows something about it.
    private static func pruneEmptyProjectDirectories(keeping live: Set<URL>, root: URL) {
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        let livePaths = Set(live.map(\.standardizedFileURL.path))
        for entry in entries {
            guard !livePaths.contains(entry.standardizedFileURL.path) else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - Helpers

    private static func clip(_ value: String, to limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<end]).trimmingCharacters(in: .whitespaces) + "…"
    }
}
