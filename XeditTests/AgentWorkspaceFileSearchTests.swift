import Foundation
import Testing
@testable import WillDeep

@Suite("Composer @ 文件搜索")
nonisolated struct AgentWorkspaceFileSearchTests {
    @Test("按文件名与相对路径检查当前工作区")
    func searchesFilenameAndRelativePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-at-search-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceFile = sourceDirectory.appendingPathComponent("Composer.swift")
        let readmeFile = root.appendingPathComponent("README.md")
        try Data("struct Composer {}".utf8).write(to: sourceFile)
        try Data("WillDeep".utf8).write(to: readmeFile)
        defer { try? FileManager.default.removeItem(at: root) }

        let filenameMatches = AgentWorkspaceFileSearch.search(root: root, query: "composer.swift")
        #expect(filenameMatches.first == sourceFile.standardizedFileURL)

        let pathMatches = AgentWorkspaceFileSearch.search(root: root, query: "sources/feature")
        #expect(pathMatches.first == sourceFile.standardizedFileURL)
    }

    @Test("精确文件名优先于模糊命中")
    func exactFilenameRanksFirst() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-at-rank-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let exact = root.appendingPathComponent("App.swift")
        let fuzzy = root.appendingPathComponent("App.swift.backup")
        try Data().write(to: exact)
        try Data().write(to: fuzzy)
        defer { try? FileManager.default.removeItem(at: root) }

        let matches = AgentWorkspaceFileSearch.search(root: root, query: "App.swift")
        #expect(matches.first == exact.standardizedFileURL)
    }

    @Test("忽略依赖目录与隐藏文件")
    func skipsExcludedAndHiddenFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-at-exclusions-\(UUID().uuidString)", isDirectory: true)
        let dependencies = root.appendingPathComponent("node_modules/pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: dependencies, withIntermediateDirectories: true)
        try Data().write(to: dependencies.appendingPathComponent("ignored.swift"))
        try Data().write(to: root.appendingPathComponent(".hidden.swift"))
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(AgentWorkspaceFileSearch.search(root: root, query: "ignored.swift").isEmpty)
        #expect(AgentWorkspaceFileSearch.search(root: root, query: "hidden.swift").isEmpty)
    }

    @Test("Worker 候选不会遮住原有工作区与文件候选")
    @MainActor
    func contextEntriesStayAheadOfWorkers() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-at-order")
        let context: [AtPickerEntry] = [
            .workspace,
            .file(url: root.appendingPathComponent("README.md"), relativePath: "README.md"),
        ]
        let workers: [AtPickerEntry] = [
            .worker(id: "generalist", name: "通用工具", purpose: "General utility"),
        ]

        let ordered = AtPickerEntry.contextFirst(context, workers: workers)

        #expect(ordered.map(\.id) == ["@workspace", "file:/tmp/willdeep-at-order/README.md", "worker:generalist"])
    }
}
