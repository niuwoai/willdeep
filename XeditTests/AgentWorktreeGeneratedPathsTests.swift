//
//  AgentWorktreeGeneratedPathsTests.swift
//  WillDeepTests
//
//  写集归因跳过未 gitignore 的构建缓存。
//

import Foundation
import Testing
@testable import WillDeep

@Suite("写集归因跳过构建缓存", .serialized)
@MainActor
struct AgentWorktreeGeneratedPathsTests {
    private static let goReadme = """
    This directory holds cached build artifacts from the Go build system.
    Run "go clean -cache" if the directory is getting too large.
    """

    private struct Repo {
        let root: URL
        func write(_ path: String, _ content: String = "x") throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
        }
        func remove() {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Repo cleanup failed: \(error)") }
        }
    }

    private func makeRepo() throws -> Repo {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("generated-paths-\(UUID())")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = Repo(root: root)
        try repo.git("init", "-q")
        try repo.git("config", "user.email", "test@example.com")
        try repo.git("config", "user.name", "test")
        try repo.write("main.go", "package main\n")
        try repo.git("add", "main.go")
        try repo.git("commit", "-q", "-m", "init")
        return repo
    }

    /// 本机真实现场的目录名：`.tmp/gocache`、`.buildtmp/cache`、`.tmp/go-cache-vet`、
    /// `.buildtmp/go-build3696466779`——名字都是项目自己起的，只能靠标记文件认。
    private func writeCaches(in repo: Repo) throws {
        try repo.write(".tmp/gocache/README", Self.goReadme)
        try repo.write(".tmp/gocache/00/0a1b-d")
        try repo.write(".tmp/gocache/ff/ffee-a")
        try repo.write(".buildtmp/cache/README", Self.goReadme)
        try repo.write(".buildtmp/cache/3c/3c4d-d")
        try repo.write(".buildtmp/go-build3696466779/b001/_pkg_.a")
        try repo.write("rust/target/CACHEDIR.TAG", "Signature: 8a477f597d28d172789f06886806bc55\n")
        try repo.write("rust/target/debug/app")
        try repo.write("web/node_modules/left-pad/index.js")
    }

    @Test("按标记文件与目录名认出构建缓存，不误伤源码、build 产物和已跟踪文件")
    func recognizesCachesByMarkerAndName() throws {
        let repo = try makeRepo(); defer { repo.remove() }
        try writeCaches(in: repo)
        try repo.write("internal/gateway/handler.go", "package gateway\n")
        try repo.write("build/report.json", "{}")
        try repo.write("notes/README", "This directory holds my notes.")
        try repo.write("notes/todo.md")
        try repo.write("main.go", "package main\n// edited\n")

        let status = AppState.loadGitStatus(for: repo.root)
        let generated = AgentWorktreeGeneratedPaths.untrackedGeneratedPaths(in: status)

        #expect(generated == [
            ".tmp/gocache/README", ".tmp/gocache/00/0a1b-d", ".tmp/gocache/ff/ffee-a",
            ".buildtmp/cache/README", ".buildtmp/cache/3c/3c4d-d",
            ".buildtmp/go-build3696466779/b001/_pkg_.a",
            "rust/target/CACHEDIR.TAG", "rust/target/debug/app",
            "web/node_modules/left-pad/index.js",
        ])
        #expect(status.entries["main.go"] == .modified)
    }

    @Test("go-build 临时目录只认 go-build 加纯数字")
    func goBuildWorkDirectoryName() {
        #expect(AgentWorktreeGeneratedPaths.isGoBuildWorkDirectory("go-build3696466779"))
        #expect(!AgentWorktreeGeneratedPaths.isGoBuildWorkDirectory("go-build"))
        #expect(!AgentWorktreeGeneratedPaths.isGoBuildWorkDirectory("go-build-scripts"))
        #expect(!AgentWorktreeGeneratedPaths.isGoBuildWorkDirectory("go-builder"))
    }

    @Test("工具跑出构建缓存后写集只记源码改动，旧版本记进去的缓存路径一并清掉")
    func attributionSkipsCachesAndPrunesOldEntries() async throws {
        let repo = try makeRepo(); defer { repo.remove() }
        let suite = "generated-paths-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppState(dispatchStore: AgentDispatchStore(defaults: defaults), sessionManagementDefaults: defaults, loadSessionCatalog: false)
        let session = app.startNewAgentSession(inWorkspaceAt: repo.root.path)
        let runtime = try #require(app.runtime(for: session.id))
        defer { AgentSessionStore.delete(id: session.id) }
        // 旧版本已经把缓存记进了写集。
        try repo.write(".tmp/gocache/README", Self.goReadme)
        try repo.write(".tmp/gocache/aa/stale-d")
        runtime.agentEditedPaths = [".tmp/gocache/aa/stale-d", "main.go"]

        let baseline = await AppState.loadAgentWorktreeSnapshot(for: repo.root)
        // 一次 `go build`：改了源码，也吐了一堆缓存。
        try writeCaches(in: repo)
        try repo.write("internal/gateway/handler.go", "package gateway\n")
        await app.refreshGitStatusAfterAgentTool(
            for: runtime,
            workspaceURL: repo.root,
            baselineSnapshot: baseline
        )

        #expect(runtime.agentEditedPaths == ["main.go", "internal/gateway/handler.go"])
        #expect(runtime.didEditFiles)
        #expect(!runtime.worktreeChanges.files.contains { $0.path.contains("gocache") || $0.path.contains("node_modules") })
    }
}
