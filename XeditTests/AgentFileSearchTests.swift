//
//  AgentFileSearchTests.swift
//  WillDeepTests
//
//  Correctness coverage for the rg-backed local Agent search tools and their
//  deterministic executable discovery.
//

import Foundation
import Testing
@testable import WillDeep

@Suite("Agent file search")
struct AgentFileSearchTests {
    @Test("search_files is case-insensitive, bounded, and skips generated directories")
    @MainActor
    func searchFilesUsesCompatibleFastPathSemantics() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-search-\(UUID().uuidString)", isDirectory: true)
        let generatedDirectory = workspace.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: generatedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "first Needle\nsecond needle\n".write(
            to: workspace.appendingPathComponent("Source.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "needle from generated dependency\n".write(
            to: generatedDirectory.appendingPathComponent("dependency.js"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await AgentToolRunner.run(
            name: "search_files",
            arguments: [
                "query": .string("NEEDLE"),
                "max_results": .number(1)
            ],
            context: AgentToolContext(rootDirectory: workspace)
        )

        #expect(result.summary == "1 match for \"NEEDLE\"")
        #expect(result.payload.contains("Source.swift:1: first Needle"))
        #expect(!result.payload.contains("node_modules"))
    }

    @Test("grep_files keeps workspace-relative paths when searching a subdirectory")
    @MainActor
    func grepFilesFastPathKeepsWorkspaceRelativePaths() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-grep-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = workspace.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "func fastSearch() {}\n".write(
            to: sourceDirectory.appendingPathComponent("Search.swift"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await AgentToolRunner.run(
            name: "grep_files",
            arguments: [
                "pattern": .string("^func\\s+fastSearch"),
                "path": .string("Sources"),
                "include": .string("*.swift")
            ],
            context: AgentToolContext(rootDirectory: workspace)
        )

        #expect(result.payload.contains("Sources/Search.swift:1: func fastSearch() {}"))
    }

    @Test("ripgrep discovery has a deterministic unavailable fallback")
    func ripgrepDiscoveryCanReportUnavailable() {
        let missing = AgentRipgrepSearch.locateExecutable(
            pathEnvironment: "",
            knownPaths: ["/definitely/missing/willdeep-rg"]
        )
        #expect(missing == nil)

        let knownExecutable = AgentRipgrepSearch.locateExecutable(
            pathEnvironment: "",
            knownPaths: ["/usr/bin/true"]
        )
        #expect(knownExecutable?.path == "/usr/bin/true")
    }
}
