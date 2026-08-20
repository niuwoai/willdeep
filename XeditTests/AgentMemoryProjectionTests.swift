import Foundation
import Testing
@testable import WillDeep

/// Agent memory lived only in UserDefaults: authoritative but invisible — you
/// could not grep it, diff it, or put it in a review. And recall was entirely
/// host-driven, so a memory keyword scoring failed to surface was one the
/// model never learned existed.
///
/// These pin the two halves of the fix: the Markdown mirror on disk, and the
/// per-turn index that makes `read_memory` reachable.
@Suite
struct AgentMemoryProjectionTests {
    private func record(
        content: String,
        scope: AgentMemoryScope = .project,
        projectPath: String? = "/Users/rocky/Sites/Xedit",
        topics: [String] = [],
        updatedAt: Date = Date(timeIntervalSince1970: 1_787_000_000),
        archivedAt: Date? = nil
    ) -> AgentMemoryRecord {
        AgentMemoryRecord(
            content: content,
            source: .manual,
            scope: scope,
            projectFingerprint: projectPath.map {
                AgentMemoryEngine.projectFingerprint(for: URL(fileURLWithPath: $0, isDirectory: true)) ?? ""
            },
            projectPath: projectPath,
            topics: topics,
            updatedAt: updatedAt,
            archivedAt: archivedAt
        )
    }

    /// A tree of this test's own. Swift Testing runs cases in parallel, so
    /// reaching for `AgentMemoryProjection.directoryOverride` would have these
    /// cases overwrite each other's root mid-run.
    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-projection-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Shaping

    @Test("an index line carries the memory, not just a heading")
    func hookIsUsableOnItsOwn() {
        let entry = AgentMemoryProjection.entry(for: record(
            content: "发布流程：不直接 push — commit 后跑 scripts/frontend-upload-and-railway-prebuilt.sh（脚本自带 push），不手动 git push"
        ))

        // The whole point of a hook: a small model that never spends a tool
        // call still walks away knowing the rule.
        #expect(entry.hook.contains("不直接 push"))
        #expect(entry.hook.count <= AgentMemoryProjection.maximumHookCharacters + 1)
        #expect(entry.title.count <= AgentMemoryProjection.maximumTitleCharacters + 1)
        #expect(!entry.title.isEmpty)
    }

    @Test("a long memory is clipped, a short one is left whole")
    func hookClipping() {
        let short = AgentMemoryProjection.entry(for: record(content: "线上部署在 h1.niuwoai.com"))
        #expect(short.hook == "线上部署在 h1.niuwoai.com", "a memory that already fits must not gain an ellipsis")

        let long = AgentMemoryProjection.entry(for: record(content: String(repeating: "长", count: 400)))
        #expect(long.hook.hasSuffix("…"))
        #expect(long.hook.count <= AgentMemoryProjection.maximumHookCharacters + 1)
    }

    @Test("multi-line memories flatten into one index line")
    func hookIsSingleLine() {
        let entry = AgentMemoryProjection.entry(for: record(content: "第一行\n第二行\n第三行"))

        #expect(!entry.hook.contains("\n"), "a hook with newlines would break the index list")
        #expect(entry.hook.contains("第一行"))
        #expect(entry.hook.contains("第三行"))
    }

    @Test("similar memories never collide onto one file")
    func slugsAreUnique() {
        // Keyword stems collide readily — three memories about releases all
        // reduce to the same stem, and a collision means one silently
        // overwrites another's file.
        let records = (0..<3).map { _ in record(content: "发布流程注意事项", topics: ["release"]) }
        let slugs = Set(records.map { AgentMemoryProjection.entry(for: $0).slug })

        #expect(slugs.count == 3)
    }

    @Test("a memory with no usable keywords still gets a file name")
    func slugFallback() {
        let entry = AgentMemoryProjection.entry(for: record(content: "!!! ???"))

        #expect(!entry.slug.isEmpty)
        #expect(entry.slug.hasSuffix(AgentMemoryProjection.shortID(entry.id)))
    }

    @Test("the index is capped instead of growing without limit")
    func indexIsCapped() {
        let entries = (0..<400).map {
            AgentMemoryProjection.entry(for: record(content: "记忆条目编号 \($0)，内容足够长以便占用索引预算"))
        }
        let markdown = AgentMemoryProjection.indexMarkdown(heading: "项目记忆索引", entries: entries)

        #expect(markdown.count <= AgentMemoryProjection.maximumIndexCharacters + 500)
        #expect(markdown.contains("more not listed"), "a silently truncated index reads as a complete one")
    }

    @Test("an empty index says so rather than rendering a bare heading")
    func emptyIndex() {
        let markdown = AgentMemoryProjection.indexMarkdown(heading: "项目记忆索引", entries: [])

        #expect(markdown.contains("_(empty)_"))
    }

    @Test("topic files carry the identity needed to find them again")
    func topicMarkdownShape() {
        let source = record(content: "迁移失败置 dirty 会让旧二进制也起不来", topics: ["migration"])
        let entry = AgentMemoryProjection.entry(for: source)
        let markdown = AgentMemoryProjection.topicMarkdown(for: entry)

        #expect(markdown.hasPrefix("---\n"))
        #expect(markdown.contains("id: \(source.id.uuidString)"))
        #expect(markdown.contains("short_id: \(AgentMemoryProjection.shortID(source.id))"))
        #expect(markdown.contains("scope: project"))
        #expect(markdown.contains("迁移失败置 dirty 会让旧二进制也起不来"))
    }

    @Test("files announce that they are generated")
    func indexWarnsItIsGenerated() {
        // Without this the user edits a file, the next save overwrites it, and
        // the work is gone with no warning.
        let markdown = AgentMemoryProjection.indexMarkdown(
            heading: "项目记忆索引",
            entries: [AgentMemoryProjection.entry(for: record(content: "任意记忆"))]
        )

        #expect(markdown.contains("Generated by WillDeep"))
        #expect(markdown.contains("overwritten"))
    }

    // MARK: - Disk layout

    @Test("global and per-project memories land in separate trees")
    func directoryLayout() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let projectMemory = record(content: "Xedit 的单测入口是 scripts/run_tests_fast.rb")
        let globalMemory = record(
            content: "回复一律使用简体中文",
            scope: .global,
            projectPath: nil
        )
        AgentMemoryProjection.writeSynchronously(records: [projectMemory, globalMemory], root: root)

        let globalIndex = root.appendingPathComponent("global/MEMORY.md")
        #expect(FileManager.default.fileExists(atPath: globalIndex.path))
        let globalText = try String(contentsOf: globalIndex, encoding: .utf8)
        #expect(globalText.contains("回复一律使用简体中文"))
        #expect(!globalText.contains("run_tests_fast"), "a project memory must not leak into the global index")

        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let projectDirs = try FileManager.default.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil)
        #expect(projectDirs.count == 1)
        let projectText = try String(
            contentsOf: projectDirs[0].appendingPathComponent("MEMORY.md"),
            encoding: .utf8
        )
        #expect(projectText.contains("run_tests_fast"))
    }

    @Test("deleting a memory removes its file")
    func deletedMemoryLosesItsFile() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let keep = record(content: "保留这条记忆")
        let drop = record(content: "这条稍后会被删除")
        AgentMemoryProjection.writeSynchronously(records: [keep, drop], root: root)

        let topics = AgentMemoryProjection
            .directory(for: .project, projectFingerprint: keep.normalized.projectFingerprint, root: root)
            .appendingPathComponent("topics", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(at: topics, includingPropertiesForKeys: nil).count == 2)

        AgentMemoryProjection.writeSynchronously(records: [keep], root: root)

        let remaining = try FileManager.default.contentsOfDirectory(at: topics, includingPropertiesForKeys: nil)
        #expect(remaining.count == 1, "a file left behind keeps asserting something the Agent no longer believes")
        #expect(remaining[0].lastPathComponent == "\(AgentMemoryProjection.entry(for: keep).slug).md")
    }

    @Test("archived memories are not projected")
    func archivedMemoriesAreExcluded() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let live = record(content: "还在生效的记忆")
        let archived = record(content: "已归档的记忆", archivedAt: Date(timeIntervalSince1970: 1_787_000_100))
        AgentMemoryProjection.writeSynchronously(records: [live, archived], root: root)

        let index = AgentMemoryProjection
            .directory(for: .project, projectFingerprint: live.normalized.projectFingerprint, root: root)
            .appendingPathComponent("MEMORY.md")
        let text = try String(contentsOf: index, encoding: .utf8)

        #expect(text.contains("还在生效的记忆"))
        #expect(!text.contains("已归档的记忆"))
    }

    @Test("re-projecting unchanged records does not touch the files")
    func unchangedFilesKeepTheirTimestamps() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let memory = record(content: "内容没有变化")
        AgentMemoryProjection.writeSynchronously(records: [memory], root: root)
        let index = AgentMemoryProjection
            .directory(for: .project, projectFingerprint: memory.normalized.projectFingerprint, root: root)
            .appendingPathComponent("MEMORY.md")
        let firstWrite = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date

        AgentMemoryProjection.writeSynchronously(records: [memory], root: root)
        let secondWrite = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date

        // Memory saves fire on every `@Published` didSet. Rewriting unchanged
        // files would churn mtimes constantly and make the directory useless
        // as a record of when the Agent actually learned something.
        #expect(firstWrite == secondWrite)
    }
}

/// The per-turn index — the half that makes on-demand recall possible at all.
@Suite
struct AgentMemoryIndexBlockTests {
    private let workspace = URL(fileURLWithPath: "/Users/rocky/Sites/Xedit", isDirectory: true)

    private func record(content: String, scope: AgentMemoryScope = .global) -> AgentMemoryRecord {
        AgentMemoryRecord(content: content, source: .manual, scope: scope)
    }

    @Test("memories scoring failed to surface are still listed")
    func unretrievedMemoriesAreStillVisible() throws {
        let surfaced = record(content: "已经被打分召回的记忆")
        let missed = record(content: "打分没捞到但可能有用的记忆")

        let block = try #require(AgentMemoryEngine.indexBlock(
            records: [surfaced, missed],
            excluding: [surfaced.id],
            settings: .default,
            rootDirectory: workspace
        ))

        #expect(block.contains("打分没捞到"))
        #expect(!block.contains("已经被打分召回"), "the floor already sent this in full; repeating it wastes the budget")
        #expect(block.contains(AgentMemoryProjection.shortID(missed.id)))
        #expect(block.contains("read_memory"), "the index has to say how to pull the detail")
    }

    @Test("nothing left to list means no block at all")
    func emptyIndexProducesNoBlock() {
        let only = record(content: "唯一一条记忆")

        #expect(AgentMemoryEngine.indexBlock(
            records: [only],
            excluding: [only.id],
            settings: .default,
            rootDirectory: workspace
        ) == nil)
        #expect(AgentMemoryEngine.indexBlock(
            records: [],
            excluding: [],
            settings: .default,
            rootDirectory: workspace
        ) == nil)
    }

    @Test("disabling memory or auto-recall silences the index")
    func settingsGateTheIndex() {
        let memory = record(content: "一条记忆")

        var disabled = AgentMemorySettings.default
        disabled.isMemoryEnabled = false
        #expect(AgentMemoryEngine.indexBlock(
            records: [memory],
            excluding: [],
            settings: disabled,
            rootDirectory: workspace
        ) == nil)

        var noAutoRecall = AgentMemorySettings.default
        noAutoRecall.autoRetrievalEnabled = false
        #expect(AgentMemoryEngine.indexBlock(
            records: [memory],
            excluding: [],
            settings: noAutoRecall,
            rootDirectory: workspace
        ) == nil)
    }

    @Test("another workspace's project memories stay out of this one")
    func projectScopingIsRespected() {
        let elsewhere = AgentMemoryRecord(
            content: "只属于另一个仓库的约定",
            source: .manual,
            scope: .project,
            projectPath: "/Users/rocky/Sites/muchtoken"
        )

        let block = AgentMemoryEngine.indexBlock(
            records: [elsewhere],
            excluding: [],
            settings: .default,
            rootDirectory: workspace
        )

        #expect(block == nil)
    }

    @Test("the index stays within its budget and says what it dropped")
    func indexBudgetIsEnforced() throws {
        let records = (0..<200).map {
            record(content: "第 \($0) 条记忆，内容写得足够长以便快速吃掉字符预算，用来验证截断行为")
        }

        let block = try #require(AgentMemoryEngine.indexBlock(
            records: records,
            excluding: [],
            settings: .default,
            rootDirectory: workspace
        ))

        #expect(block.count <= 2_400, "an unbounded index defeats the point of not sending everything")
        #expect(block.contains("not listed"), "silently dropping entries reads as a complete index")
    }
}
