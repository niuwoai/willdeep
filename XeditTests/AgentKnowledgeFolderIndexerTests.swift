//
//  AgentKnowledgeFolderIndexerTests.swift
//  XeditTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentKnowledgeFolderIndexerTests {
    @Test("New knowledge folders stay pending outside Goal mode")
    func knowledgeFolderIndexPolicy() {
        let folder = AgentKnowledgeFolder(url: URL(fileURLWithPath: "/tmp/reference"))
        #expect(folder.status == .pending)
        #expect(!AgentKnowledgeFolderIndexPolicy.startsAutomatically(in: .normal))
        #expect(AgentKnowledgeFolderIndexPolicy.startsAutomatically(in: .goal))
    }

    @Test("Skill picker reserves three complete rows when available")
    func skillPickerMinimumHeight() {
        #expect(SkillPickerLayout.minimumListHeight(entryCount: 0) == 0)
        #expect(SkillPickerLayout.minimumListHeight(entryCount: 1) == SkillPickerLayout.rowHeight)
        #expect(SkillPickerLayout.minimumListHeight(entryCount: 3) == SkillPickerLayout.rowHeight * 3)
        #expect(SkillPickerLayout.minimumListHeight(entryCount: 20) == SkillPickerLayout.rowHeight * 3)
        #expect(ComposerPaletteLayout.maximumListHeight == 440)
    }

    @Test("Knowledge folders honor gitignore, custom exclusions, and sensitive-file defaults")
    func safeFolderIndexing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_knowledge_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        try write("# Keep\nUseful project facts", to: root.appendingPathComponent("keep.md"))
        try write("draft", to: root.appendingPathComponent("drafts/skip.md"))
        try write("private", to: root.appendingPathComponent("private/skip.md"))
        try write("dependency", to: root.appendingPathComponent("node_modules/pkg/readme.md"))
        try write("TOKEN=do-not-index", to: root.appendingPathComponent(".env"))
        try write("{\"token\":\"do-not-index\"}", to: root.appendingPathComponent("credentials.json"))
        try write("drafts/**\n", to: root.appendingPathComponent(".gitignore"))

        let result = await AgentKnowledgeFolderIndexer.index(
            folderURL: root,
            existingDocuments: [],
            excludedPatterns: ["private/**"]
        )

        #expect(result.documents.count == 1)
        #expect(result.documents.first?.relativePath.hasSuffix("/keep.md") == true)
        #expect(result.documents.first?.analysis?.sections.first?.text.contains("Useful project facts") == true)
        #expect(result.skippedFileCount >= 1)

        let reused = await AgentKnowledgeFolderIndexer.index(
            folderURL: root,
            existingDocuments: result.documents,
            excludedPatterns: ["private/**"]
        )
        #expect(reused.documents == result.documents)

        var folder = AgentKnowledgeFolder(url: root)
        folder.status = .ready
        folder.documents = result.documents
        folder.excludedPatterns = ["private/**"]
        let encoded = try JSONEncoder().encode(AgentSession(knowledgeFolders: [folder]))
        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)
        #expect(decoded.knowledgeFolders.first == folder)
    }

    @Test("Gitignore negation can re-include a more specific path")
    func gitIgnoreNegation() {
        let rules = "drafts/**\n!drafts/publish.md\n"
        #expect(AgentKnowledgeFolderIndexer.shouldExclude(
            relativePath: "drafts/internal.md",
            customPatterns: [],
            gitIgnoreText: rules
        ))
        #expect(!AgentKnowledgeFolderIndexer.shouldExclude(
            relativePath: "drafts/publish.md",
            customPatterns: [],
            gitIgnoreText: rules
        ))
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #require(text.data(using: .utf8)).write(to: url)
    }
}
