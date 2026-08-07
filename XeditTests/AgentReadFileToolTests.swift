//
//  AgentReadFileToolTests.swift
//  WillDeepTests
//
//  Covers the read_file tool's line-windowed reads (offset/limit), the
//  UTF-8-boundary-safe truncation that keeps CJK content from collapsing
//  into mojibake, and the tab-buffer-first content source that keeps
//  read_file consistent with what edit_file matches against.
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
struct AgentReadFileToolTests {
    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_read_file_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    // MARK: - utf8SafePrefix

    @Test("byte cuts inside a multi-byte character drop the partial bytes")
    func utf8SafePrefixDropsPartialCharacter() {
        let bytes = Data("中文".utf8) // 6 bytes, 3 per character
        for cut in 1...(bytes.count - 1) {
            let safe = AgentFileTools.utf8SafePrefix(Data(bytes.prefix(cut)))
            // The trimmed prefix must always decode as UTF-8.
            #expect(String(data: safe, encoding: .utf8) != nil, "cut at \(cut)")
        }
        // A cut on a character boundary is returned untouched.
        #expect(AgentFileTools.utf8SafePrefix(Data(bytes.prefix(3))) == Data("中".utf8))
        #expect(AgentFileTools.utf8SafePrefix(bytes) == bytes)
    }

    @Test("pure ASCII data is never modified")
    func utf8SafePrefixKeepsASCII() {
        let data = Data("hello".utf8)
        #expect(AgentFileTools.utf8SafePrefix(data) == data)
    }

    // MARK: - Line windows

    @Test("offset/limit return the requested window with true line numbers")
    func offsetAndLimitWindow() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let lines = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try lines.write(to: workspace.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let result = try await AgentFileTools.readFile(
            arguments: [
                "path": .string("a.txt"),
                "offset": .number(4),
                "limit": .number(3)
            ],
            context: AgentToolContext(rootDirectory: workspace)
        )

        #expect(result.summary == "a.txt (lines 4-6 of 10)")
        #expect(result.payload.contains("    4  line 4"))
        #expect(result.payload.contains("    6  line 6"))
        #expect(!result.payload.contains("line 3"))
        #expect(!result.payload.contains("line 7\n"))
        #expect(result.payload.contains("offset=7"))
    }

    @Test("a full read has no truncation note and counts lines correctly")
    func fullReadHasNoTruncationNote() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "alpha\nbeta\n".write(to: workspace.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let result = try await AgentFileTools.readFile(
            arguments: ["path": .string("b.txt")],
            context: AgentToolContext(rootDirectory: workspace)
        )

        #expect(result.summary == "b.txt (2 lines)")
        #expect(!result.payload.contains("truncated"))
    }

    @Test("absolute paths inside another Project folder are readable")
    func readsAdditionalProjectRoot() async throws {
        let primary = try makeWorkspace()
        let secondary = try makeWorkspace()
        defer {
            try? FileManager.default.removeItem(at: primary)
            try? FileManager.default.removeItem(at: secondary)
        }
        let target = secondary.appendingPathComponent("backend.txt")
        try "secondary root\n".write(to: target, atomically: true, encoding: .utf8)

        let result = try await AgentFileTools.readFile(
            arguments: ["path": .string(target.path)],
            context: AgentToolContext(
                rootDirectory: primary,
                additionalWorkspaceRoots: [secondary]
            )
        )

        #expect(result.payload.contains("secondary root"))
    }

    @Test("byte-budget truncation lands on a line boundary and keeps CJK intact")
    func byteBudgetTruncationKeepsCJKIntact() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        // Each line is 中文注释行 + number; ~20 bytes per line.
        let lines = (1...100).map { "中文注释第\($0)行" }.joined(separator: "\n") + "\n"
        try lines.write(to: workspace.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)

        let result = try await AgentFileTools.readFile(
            arguments: [
                "path": .string("c.txt"),
                "max_bytes": .number(300)
            ],
            context: AgentToolContext(rootDirectory: workspace)
        )

        // Whatever was included is intact UTF-8 text, cut between lines.
        #expect(result.payload.contains("中文注释第1行"))
        #expect(result.payload.contains("truncated"))
        #expect(result.payload.contains("offset="))
        #expect(!result.payload.contains("\u{FFFD}"))
    }

    @Test("out-of-range offset is a clear error, not an empty payload")
    func offsetBeyondEndThrows() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "only\n".write(to: workspace.appendingPathComponent("d.txt"), atomically: true, encoding: .utf8)

        await #expect(throws: (any Error).self) {
            _ = try await AgentFileTools.readFile(
                arguments: [
                    "path": .string("d.txt"),
                    "offset": .number(99)
                ],
                context: AgentToolContext(rootDirectory: workspace)
            )
        }
    }

    // MARK: - Tab-buffer consistency

    @Test("read_file returns the editable-content provider's buffer, not stale disk")
    @MainActor
    func readPrefersEditableContentProvider() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fileURL = workspace.appendingPathComponent("e.swift")
        try "stale disk content\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let context = AgentToolContext(
            rootDirectory: workspace,
            editableContentProvider: { _ in "let fresh = true\n" }
        )
        let result = try await AgentFileTools.readFile(
            arguments: ["path": .string("e.swift")],
            context: context
        )

        #expect(result.payload.contains("let fresh = true"))
        #expect(!result.payload.contains("stale disk content"))
    }
}
