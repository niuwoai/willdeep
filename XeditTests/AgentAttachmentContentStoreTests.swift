//
//  AgentAttachmentContentStoreTests.swift
//  XeditTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct AgentAttachmentContentStoreTests {
    @Test("Attachment text externalizes to a verified content-addressed sidecar")
    func externalizedRoundTrip() throws {
        let root = try temporaryStoreDirectory()
        defer { resetStore(removing: root) }

        let section = makeSection(text: String(repeating: "evidence ", count: 256))
        let analysis = makeAnalysis(sections: [section])
        let externalized = try analysis.externalized()
        let path = try #require(externalized.contentFilePath)
        let digest = try #require(externalized.contentSHA256)

        #expect(!externalized.needsContentExternalization)
        #expect(URL(fileURLWithPath: path).lastPathComponent == "\(digest).json")
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(externalized.loadedSections() == [section])

        let encoded = try JSONEncoder().encode(externalized)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["sections"] == nil)
        #expect(object["sectionSummaries"] != nil)

        let decoded = try JSONDecoder().decode(AgentAttachmentAnalysis.self, from: encoded)
        #expect(decoded.loadedSections() == [section])
    }

    @Test("Identical attachment content reuses one sidecar file")
    func contentAddressedDeduplication() throws {
        let root = try temporaryStoreDirectory()
        defer { resetStore(removing: root) }

        let analysis = makeAnalysis(sections: [makeSection(text: "same content")])
        let first = try analysis.externalized()
        let second = try analysis.externalized()

        #expect(first.contentSHA256 == second.contentSHA256)
        #expect(first.contentFilePath == second.contentFilePath)
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(entries.count == 1)
    }

    @Test("Legacy inline attachment JSON remains readable")
    func legacyInlineCompatibility() throws {
        let root = try temporaryStoreDirectory()
        defer { resetStore(removing: root) }

        let section = makeSection(text: "legacy inline text")
        let encoded = try JSONEncoder().encode(makeAnalysis(sections: [section]))
        let decoded = try JSONDecoder().decode(AgentAttachmentAnalysis.self, from: encoded)

        #expect(decoded.needsContentExternalization)
        #expect(decoded.loadedSections() == [section])
        #expect(decoded.sectionSummaries.first?.preview == "legacy inline text")
    }

    @Test("Session persistence snapshots externalize documents and knowledge folders")
    func sessionSnapshotExternalization() throws {
        let root = try temporaryStoreDirectory()
        defer { resetStore(removing: root) }

        var attachment = AgentFileAttachment(
            url: URL(fileURLWithPath: "/tmp/reference.md"),
            relativePath: "reference.md"
        )
        attachment.parseStatus = .ready
        let privateTail = "PRIVATE_FULL_TEXT_TAIL_MUST_STAY_IN_SIDECAR"
        attachment.analysis = makeAnalysis(
            sections: [makeSection(
                text: String(repeating: "preview-safe ", count: 20) + privateTail
            )]
        )
        let folder = AgentKnowledgeFolder(
            url: URL(fileURLWithPath: "/tmp/knowledge"),
            status: .ready,
            documents: [attachment]
        )
        let snapshot = AgentSession(
            documentAttachments: [attachment],
            knowledgeFolders: [folder]
        ).externalizingAttachmentContent()

        let encoded = try JSONEncoder().encode(snapshot)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains("preview-safe"))
        #expect(!json.contains(privateTail))
        #expect(snapshot.documentAttachments.first?.analysis?.loadedSections().count == 1)
        #expect(snapshot.knowledgeFolders.first?.documents.first?.analysis?.loadedSections().count == 1)
    }

    @Test("Tampered sidecar content is rejected")
    func integrityValidation() throws {
        let root = try temporaryStoreDirectory()
        defer { resetStore(removing: root) }

        let externalized = try makeAnalysis(
            sections: [makeSection(text: "trusted")]
        ).externalized()
        let path = try #require(externalized.contentFilePath)
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)

        #expect(externalized.loadedSections().isEmpty)
    }

    private func temporaryStoreDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_attachment_store_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        AgentAttachmentContentStore.directoryOverride = url
        return url
    }

    private func resetStore(removing url: URL) {
        AgentAttachmentContentStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: url)
    }

    private func makeSection(text: String) -> AgentAttachmentSection {
        AgentAttachmentSection(
            id: "lines-1",
            kind: .chunk,
            ordinal: 1,
            title: "Chunk 1",
            sourceReference: "lines=1-2",
            text: text,
            wasRecognizedByOCR: false
        )
    }

    private func makeAnalysis(
        sections: [AgentAttachmentSection]
    ) -> AgentAttachmentAnalysis {
        AgentAttachmentAnalysis(
            documentKind: .text,
            sections: sections,
            totalUnitCount: sections.count,
            didUseOCR: false,
            warnings: [],
            containsPotentialPromptInjection: false
        )
    }
}
