//
//  GitWorktreeCoreTests.swift
//  WillDeepTests
//
//  Git status parsing and worktree lifecycle tests split from
//  XeditTests.swift so the main regression suite stays easier to scan.
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
struct GitWorktreeCoreTests {
    private enum TestError: Error {
        case gitFailed(String)
    }

    private func requireGit(_ arguments: [String], in directory: URL) throws {
        let result = AppState.runGitCommand(arguments: arguments, in: directory)
        guard result.succeeded else {
            throw TestError.gitFailed(result.userMessage)
        }
    }

    @Test("git porcelain status maps common file states")
    func testGitPorcelainStatusMapping() {
        let entries = AppState.parseGitStatusPorcelain(
            """
             M Sources/App.swift
            ?? Notes/todo.md
            A  Sources/NewFile.swift
             D Sources/Removed.swift
            R  Old.swift -> Sources/Renamed.swift
            ?? Assets/
            """
        )

        #expect(entries["Sources/App.swift"] == .modified)
        #expect(entries["Notes/todo.md"] == .untracked)
        #expect(entries["Sources/NewFile.swift"] == .added)
        #expect(entries["Sources/Removed.swift"] == .deleted)
        #expect(entries["Sources/Renamed.swift"] == .renamed)
        #expect(entries["Assets"] == .untracked)
    }

    @Test("git repository status returns folder marker when child changed")
    func testGitRepositoryStatusFolderMarker() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-git-root")
        let status = GitRepositoryStatus(
            repositoryRoot: root,
            branchName: "main",
            entries: ["Sources/App.swift": .modified]
        )

        #expect(status.kind(for: root.appendingPathComponent("Sources")) == .modified)
        #expect(status.kind(for: root.appendingPathComponent("Sources/App.swift")) == .modified)
        #expect(status.kind(for: root.appendingPathComponent("README.md")) == nil)
    }

    @Test("initial workspace status summarizes untracked directories")
    func testLightweightInitialGitStatus() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_git_status_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let generated = root.appendingPathComponent("generated/deep")
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: generated.appendingPathComponent("one.txt"))
        try Data("two".utf8).write(to: generated.appendingPathComponent("two.txt"))
        try requireGit(["init"], in: root)

        let summary = AppState.loadGitStatus(for: root, enumerateUntrackedFiles: false)
        let detailed = AppState.loadGitStatus(for: root, enumerateUntrackedFiles: true)

        #expect(summary.entries == ["generated": .untracked])
        #expect(detailed.entries.keys.contains("generated/deep/one.txt"))
        #expect(detailed.entries.keys.contains("generated/deep/two.txt"))
    }

    @Test("git repository status aggregates folder markers deterministically")
    func testGitRepositoryStatusFolderMarkerPriority() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-git-root")
        let status = GitRepositoryStatus(
            repositoryRoot: root,
            branchName: "main",
            entries: [
                "icons/new.svg": .untracked,
                "icons/removed.svg": .deleted,
                "icons/changed.svg": .modified,
            ]
        )

        #expect(status.kind(for: root.appendingPathComponent("icons")) == .deleted)
    }

    @Test("git numstat parser returns per-file line deltas")
    func testGitNumstatParser() {
        let stats = AppState.parseGitNumstat(
            """
            25\t13\tXedit/AgentClient.swift
            -\t-\tAssets/icon.png
            2\t0\tDocs/Name With Spaces.md
            """
        )

        #expect(stats["Xedit/AgentClient.swift"]?.added == 25)
        #expect(stats["Xedit/AgentClient.swift"]?.deleted == 13)
        #expect(stats["Assets/icon.png"]?.added == nil)
        #expect(stats["Assets/icon.png"]?.deleted == nil)
        #expect(stats["Docs/Name With Spaces.md"]?.added == 2)
        #expect(stats["Docs/Name With Spaces.md"]?.deleted == 0)
    }

    @Test("git C-quoted path with octal-escaped CJK bytes decodes to UTF-8")
    func testUnquoteGitPathDecodesCJK() {
        // git 默认 core.quotePath=true 把「重启.md」输出成
        // "docs/\351\207\215\345\220\257.md"(重=E9 87 8D,启=E5 90 AF)。
        #expect(AppState.unquoteGitPath(#""docs/\351\207\215\345\220\257.md""#) == "docs/重启.md")
        // 含转义字符的常规情况
        #expect(AppState.unquoteGitPath(#""a\tb\\c\"d.md""#) == "a\tb\\c\"d.md")
        // 未加引号的路径原样返回(加了 core.quotePath=false 后的常态)
        #expect(AppState.unquoteGitPath("docs/重启.md") == "docs/重启.md")
        #expect(AppState.unquoteGitPath("Xedit/AppState.swift") == "Xedit/AppState.swift")
    }

    @Test("porcelain + numstat parsers decode octal-escaped CJK paths")
    func testParsersDecodeQuotedCJKPaths() {
        let entries = AppState.parseGitStatusPorcelain(
            #" M "docs/\351\207\215\345\220\257.md""# + "\n" +
            #"R  "old.md" -> "docs/\345\220\257\345\212\250.md""#
        )
        #expect(entries["docs/重启.md"] == .modified)
        #expect(entries["docs/启动.md"] == .renamed)

        // numstat 字段用真实 tab 分隔;路径里的反斜杠用 \\ 写成字面量。
        let stats = AppState.parseGitNumstat(
            "3\t1\t\"docs/\\351\\207\\215\\345\\220\\257.md\""
        )
        #expect(stats["docs/重启.md"]?.added == 3)
        #expect(stats["docs/重启.md"]?.deleted == 1)
    }

    @Test("worktree change summary combines porcelain entries and numstat")
    func testWorktreeChangeSummaryTotals() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-git-root")
        let summary = AgentWorktreeChangeSummary(
            repositoryRoot: root,
            files: [
                AgentFileChangeSummary(
                    path: "B.swift",
                    kind: .modified,
                    lineStats: AgentLineChangeStats(added: 10, deleted: 2)
                ),
                AgentFileChangeSummary(
                    path: "A.swift",
                    kind: .untracked,
                    lineStats: AgentLineChangeStats(added: nil, deleted: nil)
                )
            ]
        )

        #expect(summary.fileCount == 2)
        #expect(summary.totalAddedLines == 10)
        #expect(summary.totalDeletedLines == 2)
        #expect(summary.files.map(\.path) == ["A.swift", "B.swift"])
        #expect(summary.change(for: "B.swift")?.fileName == "B.swift")
    }

    @Test("agent worktree summary filters to attributed paths")
    func testWorktreeChangeSummaryFiltersToAttributedPaths() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-git-root")
        let summary = AgentWorktreeChangeSummary(
            repositoryRoot: root,
            files: [
                AgentFileChangeSummary(
                    path: "Agent.swift",
                    kind: .modified,
                    lineStats: AgentLineChangeStats(added: 3, deleted: 1)
                ),
                AgentFileChangeSummary(
                    path: "UserDraft.md",
                    kind: .untracked,
                    lineStats: AgentLineChangeStats(added: nil, deleted: nil)
                )
            ]
        )

        let filtered = summary.filtering(paths: ["Agent.swift"])
        #expect(filtered.repositoryRoot == root)
        #expect(filtered.files.map(\.path) == ["Agent.swift"])
        #expect(summary.filtering(paths: []).isEmpty)
    }

    @Test("agent worktree baseline attribution ignores unchanged dirty files")
    func testWorktreeBaselineAttributionIgnoresUnchangedDirtyFiles() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-git-root")
        let baseline = AppState.AgentWorktreeSnapshot(
            status: GitRepositoryStatus(repositoryRoot: root, branchName: "main", entries: [
                "preexisting.txt": .modified,
            ]),
            changes: AgentWorktreeChangeSummary(repositoryRoot: root),
            fingerprint: "before",
            fileSignatures: [
                "preexisting.txt": "modified|added=1|deleted=0|size=10|mtime=1",
            ]
        )
        let current = AppState.AgentWorktreeSnapshot(
            status: GitRepositoryStatus(repositoryRoot: root, branchName: "main", entries: [
                "preexisting.txt": .modified,
                "agent-output.txt": .untracked,
            ]),
            changes: AgentWorktreeChangeSummary(
                repositoryRoot: root,
                files: [
                    AgentFileChangeSummary(
                        path: "agent-output.txt",
                        kind: .untracked,
                        lineStats: AgentLineChangeStats(added: nil, deleted: nil)
                    ),
                    AgentFileChangeSummary(
                        path: "preexisting.txt",
                        kind: .modified,
                        lineStats: AgentLineChangeStats(added: 1, deleted: 0)
                    ),
                ]
            ),
            fingerprint: "after",
            fileSignatures: [
                "preexisting.txt": "modified|added=1|deleted=0|size=10|mtime=1",
                "agent-output.txt": "untracked|added=?|deleted=?|size=22|mtime=2",
            ]
        )

        #expect(AppState.agentWorktreePathsChangedSinceBaseline(
            baseline: baseline,
            current: current
        ) == Set(["agent-output.txt"]))
    }

    @Test("session artifacts include new deliverables but exclude build output and source edits")
    func testSessionArtifactAttributionHasExplicitSemantics() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-git-root")
        let baseline = AppState.AgentWorktreeSnapshot(
            status: GitRepositoryStatus(repositoryRoot: root),
            changes: AgentWorktreeChangeSummary(repositoryRoot: root),
            fingerprint: "before",
            fileSignatures: ["Sources/App.swift": "modified|size=10"],
            artifactFileSignatures: [:]
        )
        let current = AppState.AgentWorktreeSnapshot(
            status: GitRepositoryStatus(repositoryRoot: root),
            changes: AgentWorktreeChangeSummary(
                repositoryRoot: root,
                files: [
                    AgentFileChangeSummary(path: "reports/result.pdf", kind: .untracked, lineStats: AgentLineChangeStats(added: nil, deleted: nil)),
                    AgentFileChangeSummary(path: "media/preview.mp4", kind: .added, lineStats: AgentLineChangeStats(added: nil, deleted: nil)),
                    AgentFileChangeSummary(path: "build/report.json", kind: .untracked, lineStats: AgentLineChangeStats(added: nil, deleted: nil)),
                    AgentFileChangeSummary(path: "Sources/App.swift", kind: .modified, lineStats: AgentLineChangeStats(added: 1, deleted: 0)),
                ]
            ),
            fingerprint: "after",
            fileSignatures: [
                "reports/result.pdf": "untracked|size=20",
                "media/preview.mp4": "added|size=30",
                "build/report.json": "untracked|size=40",
                "Sources/App.swift": "modified|size=12",
            ],
            artifactFileSignatures: [
                "reports/result.pdf": "size=20|mtime=1",
                "media/preview.mp4": "size=30|mtime=1",
            ]
        )

        #expect(AppState.agentArtifactPathsCreatedSinceBaseline(
            baseline: baseline,
            current: current
        ) == Set(["reports/result.pdf", "media/preview.mp4"]))
        #expect(!AppState.isAgentSessionArtifactPath(".local-cache/output.json"))
        #expect(!AppState.isAgentSessionArtifactPath("Sources/NewView.swift"))
    }

    @Test("only explicit deliverable-producing tools whitelist directory-diff artifacts")
    func testToolArtifactWhitelistIsNarrow() {
        // Explicit workspace deliverables: short-drama exports write
        // JSON/MD/CSV/HTML packages into the working directory.
        #expect(AppState.toolProducesSessionArtifacts("short_drama_export_plan_template"))
        #expect(AppState.toolProducesSessionArtifacts("short_drama_export_production_package"))

        // Process / work-file tools must NOT scoop their output into the
        // artifact rail, no matter what extension they happen to write.
        #expect(!AppState.toolProducesSessionArtifacts("create_file"))
        #expect(!AppState.toolProducesSessionArtifacts("edit_file"))
        #expect(!AppState.toolProducesSessionArtifacts("apply_patch"))
        #expect(!AppState.toolProducesSessionArtifacts("run_command"))
        #expect(!AppState.toolProducesSessionArtifacts("claude_code"))
        #expect(!AppState.toolProducesSessionArtifacts("change_workspace"))

        // Media generation registers deliverables explicitly and downloads
        // outside the workspace, so it never relies on the diff whitelist.
        #expect(!AppState.toolProducesSessionArtifacts("generate_image"))
        #expect(!AppState.toolProducesSessionArtifacts("generate_video_from_image"))
        #expect(!AppState.toolProducesSessionArtifacts("create_media_task"))
    }

    @Test("artifact inventory finds git-ignored deliverables and prunes transient trees")
    func testArtifactInventoryIsIndependentFromGitStatus() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_artifact_inventory_\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("exports"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("build"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("pdf".utf8).write(to: root.appendingPathComponent("exports/result.pdf"))
        try Data("json".utf8).write(to: root.appendingPathComponent("build/report.json"))
        try Data("swift".utf8).write(to: root.appendingPathComponent("App.swift"))

        let signatures = AppState.agentArtifactFileSignatures(in: root)
        #expect(Set(signatures.keys) == Set(["exports/result.pdf"]))
    }

    @Test("agent rail artifacts collapse sibling deliverables into directory rows")
    func testAgentRailArtifactDirectoryCollapse() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-artifact-rail")
        let mediaRoot = URL(fileURLWithPath: "/tmp/willdeep-media")
        let artifacts = [
            AgentRailArtifact(
                url: root.appendingPathComponent("exports/result.pdf"),
                displayPath: "exports/result.pdf",
                isDirectory: false
            ),
            AgentRailArtifact(
                url: root.appendingPathComponent("exports/summary.md"),
                displayPath: "exports/summary.md",
                isDirectory: false
            ),
            AgentRailArtifact(
                url: root.appendingPathComponent("README.md"),
                displayPath: "README.md",
                isDirectory: false
            ),
            AgentRailArtifact(
                url: mediaRoot.appendingPathComponent("shot-1.png"),
                displayPath: mediaRoot.appendingPathComponent("shot-1.png").path,
                isDirectory: false
            ),
            AgentRailArtifact(
                url: mediaRoot.appendingPathComponent("shot-2.png"),
                displayPath: mediaRoot.appendingPathComponent("shot-2.png").path,
                isDirectory: false
            ),
            AgentRailArtifact(
                url: root.appendingPathComponent("bundle"),
                displayPath: "bundle",
                isDirectory: true
            ),
            AgentRailArtifact(
                url: root.appendingPathComponent("bundle/index.html"),
                displayPath: "bundle/index.html",
                isDirectory: false
            ),
        ]

        let collapsed = AgentRailArtifact.collapsedForDisplay(artifacts)
        let byDisplayPath = Dictionary(uniqueKeysWithValues: collapsed.map { ($0.displayPath, $0) })

        #expect(collapsed.count == 4)
        #expect(byDisplayPath["exports"]?.isDirectory == true)
        #expect(byDisplayPath["exports"]?.itemCount == 2)
        #expect(byDisplayPath[mediaRoot.path]?.isDirectory == true)
        #expect(byDisplayPath[mediaRoot.path]?.itemCount == 2)
        #expect(byDisplayPath["README.md"]?.isDirectory == false)
        #expect(byDisplayPath["bundle"]?.isDirectory == true)
        #expect(byDisplayPath["bundle/index.html"] == nil)
    }

    @Test("agent rail work file Finder target selects one file and opens grouped directory")
    func testAgentRailWorkFileFinderTarget() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-work-file-rail", isDirectory: true)

        let singleFile = AgentRailWorkFileFinderTarget.resolve(
            repositoryRoot: root,
            relativePaths: ["scripts/debug_install_mac_apps.rb"],
            fileExists: { $0.hasSuffix("debug_install_mac_apps.rb") }
        )
        #expect(singleFile == root.appendingPathComponent("scripts/debug_install_mac_apps.rb").standardizedFileURL)

        let groupedDirectory = AgentRailWorkFileFinderTarget.resolve(
            repositoryRoot: root,
            relativePaths: ["scripts/a.rb", "scripts/b.rb"],
            fileExists: { _ in true }
        )
        #expect(groupedDirectory == root.appendingPathComponent("scripts", isDirectory: true).standardizedFileURL)

        let deletedFileDirectory = AgentRailWorkFileFinderTarget.resolve(
            repositoryRoot: root,
            relativePaths: ["docs/deleted.md"],
            fileExists: { _ in false }
        )
        #expect(deletedFileDirectory == root.appendingPathComponent("docs", isDirectory: true).standardizedFileURL)
    }

    @Test("agent worktree diff preview is limited to attributed files")
    func testWorktreeDiffPreviewLimitsTrackedDiffToAttributedFiles() throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_agent_diff_preview_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }

        try requireGit(["init"], in: repository)
        try requireGit(["config", "user.email", "tests@example.com"], in: repository)
        try requireGit(["config", "user.name", "WillDeep Tests"], in: repository)
        try "one\n".write(to: repository.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two\n".write(to: repository.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try requireGit(["add", "a.txt", "b.txt"], in: repository)
        try requireGit(["commit", "-m", "initial"], in: repository)

        try "one\nagent\n".write(to: repository.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two\nuser\n".write(to: repository.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let summary = AgentWorktreeChangeSummary(
            repositoryRoot: repository,
            files: [
                AgentFileChangeSummary(
                    path: "a.txt",
                    kind: .modified,
                    lineStats: AgentLineChangeStats(added: 1, deleted: 0)
                ),
            ]
        )
        let preview = AppState.loadAgentWorktreeDiffPreview(
            changes: summary,
            repositoryRoot: repository
        )

        #expect(preview.diff.contains("diff --git a/a.txt b/a.txt"))
        #expect(!preview.diff.contains("diff --git a/b.txt b/b.txt"))
        #expect(!preview.diff.contains("+user"))
    }

    @Test("agent worktree diff preview renders small untracked files without git child processes")
    func testWorktreeDiffPreviewRendersSmallUntrackedFilesDirectly() throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_untracked_diff_preview_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }

        let files = try (0..<7).map { index -> AgentFileChangeSummary in
            let path = "new-file-\(index).txt"
            try "line \(index)\n".write(
                to: repository.appendingPathComponent(path),
                atomically: true,
                encoding: .utf8
            )
            return AgentFileChangeSummary(
                path: path,
                kind: .untracked,
                lineStats: AgentLineChangeStats(added: nil, deleted: nil)
            )
        }
        let summary = AgentWorktreeChangeSummary(repositoryRoot: repository, files: files)

        let preview = AppState.loadAgentWorktreeDiffPreview(
            changes: summary,
            repositoryRoot: repository
        )

        #expect(!preview.diff.contains("Diff 预览已降级"))
        #expect(preview.diff.contains("diff --git a/new-file-0.txt b/new-file-0.txt"))
        #expect(preview.diff.contains("diff --git a/new-file-6.txt b/new-file-6.txt"))
        #expect(preview.diff.contains("+line 6"))
    }

    @Test("agent worktree diff preview summarizes oversized untracked files")
    func testWorktreeDiffPreviewSummarizesOversizedUntrackedFiles() throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_large_untracked_diff_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }

        let path = "large-output.txt"
        let oversizedData = Data(
            repeating: 0x61,
            count: AppState.worktreeDiffPreviewMaxUntrackedFileBytes + 1
        )
        try oversizedData.write(to: repository.appendingPathComponent(path))
        let summary = AgentWorktreeChangeSummary(
            repositoryRoot: repository,
            files: [
                AgentFileChangeSummary(
                    path: path,
                    kind: .untracked,
                    lineStats: AgentLineChangeStats(added: nil, deleted: nil)
                )
            ]
        )

        let preview = AppState.loadAgentWorktreeDiffPreview(
            changes: summary,
            repositoryRoot: repository
        )

        #expect(preview.diff.contains("Diff 预览已降级"))
        #expect(preview.diff.contains("单文件 64KB"))
        #expect(!preview.diff.contains(String(repeating: "a", count: 1_024)))
    }

    @Test("agent worktree diff preview summarizes binary untracked files")
    func testWorktreeDiffPreviewSummarizesBinaryUntrackedFiles() throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_binary_untracked_diff_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }

        let path = "asset.bin"
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: repository.appendingPathComponent(path))
        let summary = AgentWorktreeChangeSummary(
            repositoryRoot: repository,
            files: [
                AgentFileChangeSummary(
                    path: path,
                    kind: .untracked,
                    lineStats: AgentLineChangeStats(added: nil, deleted: nil)
                )
            ]
        )

        let preview = AppState.loadAgentWorktreeDiffPreview(
            changes: summary,
            repositoryRoot: repository
        )

        #expect(preview.diff.contains("Diff 预览已降级"))
        #expect(preview.diff.contains("二进制或非 UTF-8"))
    }

    @Test("agent worktree diff preview summarizes large generated web dist changes")
    func testWorktreeDiffPreviewSummarizesGeneratedWebDist() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-git-root")
        let files = (0..<160).map { index in
            AgentFileChangeSummary(
                path: "railway-prebuilt-web-dist/assets/Chunk-\(String(format: "%03d", index)).js",
                kind: .deleted,
                lineStats: AgentLineChangeStats(added: 0, deleted: 5)
            )
        }
        let summary = AgentWorktreeChangeSummary(repositoryRoot: root, files: files)
        let preview = AppState.loadAgentWorktreeDiffPreview(
            changes: summary,
            repositoryRoot: root
        )

        #expect(preview.title == "160 个文件已更改 +0 -800")
        #expect(preview.diff.contains("Diff 预览已降级"))
        #expect(preview.diff.contains("疑似前端构建产物目录"))
        #expect(preview.diff.contains("railway-prebuilt-web-dist/assets/Chunk-000.js"))
        #expect(preview.diff.contains("... 另外 80 个文件未列出 ..."))
        #expect(!preview.diff.contains("diff --git"))
    }

    @Test("agent worktree summary skips modified files without real diff")
    func testAgentWorktreeSummarySkipsModifiedFilesWithoutDiff() {
        #expect(AppState.shouldIncludeAgentWorktreeChange(
            kind: .modified,
            lineStats: AgentLineChangeStats(added: nil, deleted: nil),
            hasNumstatEntry: false
        ) == false)
        #expect(AppState.shouldIncludeAgentWorktreeChange(
            kind: .modified,
            lineStats: AgentLineChangeStats(added: 0, deleted: 0),
            hasNumstatEntry: true
        ) == false)
        #expect(AppState.shouldIncludeAgentWorktreeChange(
            kind: .modified,
            lineStats: AgentLineChangeStats(added: 2, deleted: 0),
            hasNumstatEntry: true
        ) == true)
        #expect(AppState.shouldIncludeAgentWorktreeChange(
            kind: .modified,
            lineStats: AgentLineChangeStats(added: nil, deleted: nil),
            hasNumstatEntry: true
        ) == true)
        #expect(AppState.shouldIncludeAgentWorktreeChange(
            kind: .untracked,
            lineStats: AgentLineChangeStats(added: nil, deleted: nil),
            hasNumstatEntry: false
        ) == true)
    }

    @Test("hidden cache directories are excluded from worktree diff, real hidden dirs kept")
    func testHiddenCacheWorktreePathFiltering() {
        // 命中:隐藏缓存 / 构建目录里的文件应被排除。
        #expect(AppState.isHiddenCacheWorktreePath(".gocache/00/00a2cd1c40c562c4705deaab1a66b0a46e28bf5") == true)
        #expect(AppState.isHiddenCacheWorktreePath(".venv/lib/python3.12/site-packages/foo.py") == true)
        #expect(AppState.isHiddenCacheWorktreePath("sub/.mypy_cache/3.12/module.data.json") == true)
        #expect(AppState.isHiddenCacheWorktreePath(".gradle/caches/modules-2/x.jar") == true)
        #expect(AppState.isHiddenCacheWorktreePath("frontend/.next/static/chunks/main.js") == true)
        // 大小写不敏感。
        #expect(AppState.isHiddenCacheWorktreePath(".GoCache/aa/bb") == true)
        #expect(AppState.isHiddenCacheWorktreePath(".gocache/") == true)

        // 放行:用户可能真在改的隐藏配置目录,以及仓库根下的隐藏文件。
        #expect(AppState.isHiddenCacheWorktreePath(".github/workflows/ci.yml") == false)
        #expect(AppState.isHiddenCacheWorktreePath(".claude/agents/foo.md") == false)
        #expect(AppState.isHiddenCacheWorktreePath(".vscode/settings.json") == false)
        #expect(AppState.isHiddenCacheWorktreePath(".gitignore") == false)
        #expect(AppState.isHiddenCacheWorktreePath(".env") == false)
        #expect(AppState.isHiddenCacheWorktreePath("Xedit/AppStateGitStatus.swift") == false)
        // 只按目录段匹配:名为 .gocache 的顶层文件(无目录段)不误伤。
        #expect(AppState.isHiddenCacheWorktreePath(".gocache") == false)
    }

    @Test("git worktree porcelain parser captures branches and prunable rows")
    func testGitWorktreePorcelainParser() {
        let worktrees = AppState.parseGitWorktreeListPorcelain(
            """
            worktree /tmp/repo
            HEAD 1111111111111111111111111111111111111111
            branch refs/heads/main

            worktree /tmp/repo-feature
            HEAD 2222222222222222222222222222222222222222
            branch refs/heads/feature/demo

            worktree /tmp/repo-old
            HEAD 3333333333333333333333333333333333333333
            detached
            prunable gitdir file points to non-existent location
            """
        )

        #expect(worktrees.count == 3)
        #expect(worktrees[0].isPrimary == true)
        #expect(worktrees[0].branch == "main")
        #expect(worktrees[1].branch == "feature/demo")
        #expect(worktrees[2].isDetached == true)
        #expect(worktrees[2].isPrunable == true)
        #expect(worktrees[2].pruneReason == "gitdir file points to non-existent location")
    }

    @Test("git worktree names are sanitized and default paths avoid collisions")
    func testGitWorktreeDefaultNaming() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_worktree_name_\(UUID().uuidString)")
        let repository = base.appendingPathComponent("sources/Repo")
        let worktreeRoot = base.appendingPathComponent("home/.willdeep/worktrees")
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(AppState.sanitizedGitWorktreeName(" feature/name ! ") == "feature-name")
        #expect(AppState.defaultGitWorktreeBranchName(
            sessionTitle: "Fix Login Flow",
            fallbackStem: "quiet-orbit",
            uniqueness: "A3F9"
        ) == "xedit-fix-login-flow-a3f9")
        #expect(AppState.defaultGitWorktreeBranchName(
            sessionTitle: "新对话",
            fallbackStem: "quiet-orbit",
            uniqueness: "B7C2"
        ) == "xedit-quiet-orbit-b7c2")
        let first = AppState.defaultGitWorktreeURL(
            repositoryRoot: repository,
            branchName: "feature/name !",
            worktreeRoot: worktreeRoot
        )
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let next = AppState.defaultGitWorktreeURL(
            repositoryRoot: repository,
            branchName: "feature/name !",
            worktreeRoot: worktreeRoot
        )

        #expect(
            first.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
                == worktreeRoot.standardizedFileURL.path
        )
        #expect(first.deletingLastPathComponent().lastPathComponent.hasPrefix("Repo-"))
        #expect(first.lastPathComponent == "feature-name")
        #expect(next.lastPathComponent == "feature-name-2")
        #expect(!first.path.hasPrefix(repository.deletingLastPathComponent().path))
    }

    @Test("git worktree checkout progress reads the latest percentage")
    func testGitWorktreeProgressParsing() {
        let output = "Preparing worktree\rUpdating files: 12% (12/100)\rUpdating files: 67% (67/100)"
        #expect(AppState.gitWorktreeCheckoutProgress(from: output) == 0.67)
        #expect(AppState.gitWorktreeCheckoutProgress(from: "Preparing worktree") == nil)
    }

    @Test("session worktree marker follows the current execution binding")
    func testSessionWorktreeMarkerFollowsBinding() {
        var session = AgentSession(
            workspaceRootPath: "/tmp/project-worktree",
            workspaceLocation: .local(path: "/tmp/project-worktree"),
            sidebarWorkspaceRootPath: "/tmp/project"
        )
        #expect(session.isRunningInGitWorktree)

        session.workspaceRootPath = "/tmp/project"
        session.workspaceLocation = .local(path: "/tmp/project")
        session.sidebarWorkspaceRootPath = nil
        session.worktreeRecoveryInfo = nil
        #expect(!session.isRunningInGitWorktree)

        session.workspaceRootPath = "/tmp/project-worktree"
        session.workspaceLocation = .local(path: "/tmp/project-worktree")
        session.sidebarWorkspaceRootPath = "/tmp/project"
        #expect(session.isRunningInGitWorktree)
    }

    @Test("missing worktrees without a complete restore recipe stay unavailable")
    func testLegacyMissingWorktreeDoesNotOfferRestore() {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_missing_worktree_\(UUID().uuidString)")
            .path
        let session = AgentSession(
            workspaceRootPath: missingPath,
            workspaceLocation: .local(path: missingPath),
            sidebarWorkspaceRootPath: "/tmp/project"
        )
        #expect(AppState.worktreeRecoveryState(for: session) == .unavailable(path: missingPath))
    }

    @Test("complete recovery metadata restores the original branch and path")
    func testManagedWorktreeRecovery() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_worktree_recovery_\(UUID().uuidString)")
        let repository = base.appendingPathComponent("main")
        let managedHome = base.appendingPathComponent("home")
        let worktree = managedHome.appendingPathComponent(".willdeep/worktrees/project/feature")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try requireGit(["init"], in: repository)
        try requireGit(["config", "user.email", "tests@example.com"], in: repository)
        try requireGit(["config", "user.name", "WillDeep Tests"], in: repository)
        try "hello\n".write(to: repository.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try requireGit(["add", "README.md"], in: repository)
        try requireGit(["commit", "-m", "initial"], in: repository)
        try requireGit(["branch", "feature/recover-me"], in: repository)

        let info = AgentWorktreeRecoveryInfo(
            repositoryRootPath: repository.path,
            worktreePath: worktree.path,
            branchName: "feature/recover-me",
            managedByWillDeep: true
        )
        let session = AgentSession(
            workspaceRootPath: worktree.path,
            workspaceLocation: .local(path: worktree.path),
            sidebarWorkspaceRootPath: repository.path,
            worktreeRecoveryInfo: info
        )
        let outsideManagedRoot = AgentWorktreeRecoveryInfo(
            repositoryRootPath: repository.path,
            worktreePath: base.appendingPathComponent("outside/feature").path,
            branchName: "feature/recover-me",
            managedByWillDeep: true
        )
        let outsideSession = AgentSession(
            workspaceRootPath: outsideManagedRoot.worktreePath,
            workspaceLocation: .local(path: outsideManagedRoot.worktreePath),
            sidebarWorkspaceRootPath: repository.path,
            worktreeRecoveryInfo: outsideManagedRoot
        )
        #expect(AppState.worktreeRecoveryState(
            for: outsideSession,
            managedHomeDirectory: managedHome
        ) == .unavailable(path: outsideManagedRoot.worktreePath))
        guard case .failure = AppState.restoreGitWorktree(
            from: outsideManagedRoot,
            managedHomeDirectory: managedHome
        ) else {
            Issue.record("Expected paths outside the managed worktree root to be rejected")
            return
        }
        #expect(AppState.worktreeRecoveryState(
            for: session,
            managedHomeDirectory: managedHome
        ) == .restorable(info))

        let result = AppState.restoreGitWorktree(from: info, managedHomeDirectory: managedHome)
        guard case .success(let restored) = result else {
            Issue.record("Expected the worktree restore to succeed")
            return
        }
        #expect(restored.worktree.url.path == worktree.standardizedFileURL.path)
        #expect(restored.worktree.branch == "feature/recover-me")
    }

    @Test("dispatch worktree uses its pinned input instead of a moving source HEAD")
    func testWorktreeUsesPinnedInputRevision() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("willdeep_pinned_input_\(UUID().uuidString)")
        let repository = base.appendingPathComponent("repository")
        let worktreeRoot = base.appendingPathComponent("worktrees")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: base) }
            catch { Issue.record("Fixture cleanup failed: \(error)") }
        }
        try requireGit(["init"], in: repository)
        try requireGit(["config", "user.email", "tests@example.com"], in: repository)
        try requireGit(["config", "user.name", "WillDeep Tests"], in: repository)
        let file = repository.appendingPathComponent("input.txt")
        try Data("pinned\n".utf8).write(to: file)
        try requireGit(["add", "input.txt"], in: repository)
        try requireGit(["-c", "commit.gpgsign=false", "commit", "-m", "input"], in: repository)
        let pinned = AppState.runGitCommand(arguments: ["rev-parse", "HEAD"], in: repository).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("new source HEAD\n".utf8).write(to: file)
        try requireGit(["-c", "commit.gpgsign=false", "commit", "-am", "advance source"], in: repository)
        let result = try AppState.createGitWorktree(
            from: repository, branchName: "task/pinned", worktreeRoot: worktreeRoot, startingRevision: pinned
        ).get()
        #expect(try String(contentsOf: result.worktree.url.appendingPathComponent("input.txt"), encoding: .utf8) == "pinned\n")
        #expect(try String(contentsOf: file, encoding: .utf8) == "new source HEAD\n")
        let head = AppState.runGitCommand(arguments: ["rev-parse", "HEAD"], in: repository).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .success = AppState.createGitWorktree(
            from: repository, branchName: "task/pinned", worktreeRoot: worktreeRoot, startingRevision: head
        ) {
            Issue.record("A mismatched existing task worktree must not be silently reused")
        }
        #expect(try String(contentsOf: result.worktree.url.appendingPathComponent("input.txt"), encoding: .utf8) == "pinned\n")
    }

    @Test("git worktree creation lists and detects worktree git-file roots")
    func testGitWorktreeCreateListAndFindRoot() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_worktree_create_\(UUID().uuidString)")
        let repository = base.appendingPathComponent("main")
        let worktreeRoot = base.appendingPathComponent("home/.willdeep/worktrees")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try requireGit(["init"], in: repository)
        try requireGit(["config", "user.email", "tests@example.com"], in: repository)
        try requireGit(["config", "user.name", "WillDeep Tests"], in: repository)
        try "hello\n".write(to: repository.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try requireGit(["add", "README.md"], in: repository)
        try requireGit(["commit", "-m", "initial"], in: repository)

        let created = AppState.createGitWorktree(
            from: repository,
            branchName: "feature test",
            worktreeRoot: worktreeRoot
        )
        guard case .success(let result) = created else {
            Issue.record("Expected worktree creation to succeed")
            return
        }

        #expect(result.worktree.branch == "feature-test")
        #expect(result.worktree.url.path.hasPrefix(worktreeRoot.path + "/"))
        #expect(!result.worktree.url.path.hasPrefix(repository.deletingLastPathComponent().path + "/main-"))
        #expect(FileManager.default.fileExists(atPath: result.worktree.url.appendingPathComponent(".git").path))

        let detectedRoot = AppState.findGitRepositoryRoot(startingAt: result.worktree.url)
        #expect(detectedRoot?.standardizedFileURL.path == result.worktree.url.path)

        let worktrees = AppState.listGitWorktrees(for: result.worktree.url)
        #expect(worktrees.contains { $0.url == repository.standardizedFileURL && $0.isPrimary })
        #expect(worktrees.contains { $0.url == result.worktree.url && $0.branch == "feature-test" })

        let relaunched = AppState.createGitWorktree(
            from: repository,
            branchName: "feature test",
            worktreeRoot: worktreeRoot
        )
        guard case .success(let reused) = relaunched else {
            Issue.record("Expected an occupied task branch to reuse its existing worktree")
            return
        }
        #expect(reused.worktree.url == result.worktree.url)
        #expect(reused.output.contains("Reusing existing WillDeep worktree"))
    }
}
