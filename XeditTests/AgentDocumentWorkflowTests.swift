//
//  AgentDocumentWorkflowTests.swift
//  XeditTests
//

import Foundation
import PDFKit
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentDocumentWorkflowTests {
    @Test("Document task modes add source-aware guidance and redact sensitive values")
    func taskModeAndPrivacyPrompt() {
        let section = AgentAttachmentSection(
            id: "lines-1",
            kind: .chunk,
            ordinal: 1,
            title: "Chunk 1",
            sourceReference: "lines=1-4",
            text: "Owner: person@example.com\nAPI: sk-abcdefghijklmnopqrstuvwxyz123456",
            wasRecognizedByOCR: false
        )
        var file = AgentFileAttachment(
            url: URL(fileURLWithPath: "/tmp/brief.md"),
            relativePath: "brief.md"
        )
        file.parseStatus = .ready
        file.analysis = AgentAttachmentAnalysis(
            documentKind: .text,
            sections: [section],
            totalUnitCount: 1,
            didUseOCR: false,
            warnings: [],
            containsPotentialPromptInjection: false
        )

        let prompt = AppState().composeAttachedPrompt(
            userText: "总结这份材料",
            skills: [],
            files: [file],
            includeWorkspaceOverview: false,
            documentTaskMode: .summarize,
            redactSensitiveContent: true
        )

        #expect(prompt.contains("Document task mode: summarize"))
        #expect(prompt.contains("[Source: brief.md; lines=1-4]"))
        #expect(prompt.contains("[REDACTED:EMAIL]"))
        #expect(prompt.contains("[REDACTED:API-KEY]"))
        #expect(!prompt.contains("person@example.com"))
        #expect(!prompt.contains("sk-abcdefghijklmnopqrstuvwxyz123456"))
    }

    @Test("Citation evidence exports locally as Markdown and PDF")
    func localCitationExport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_export_test_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let section = AgentAttachmentSection(
            id: "page-2",
            kind: .page,
            ordinal: 2,
            title: "Page 2",
            sourceReference: "page=2",
            text: "Exported evidence text",
            wasRecognizedByOCR: false
        )
        let file = AgentFileAttachment(
            url: root.appendingPathComponent("source.pdf"),
            relativePath: "source.pdf"
        )
        let markdownURL = root.appendingPathComponent("citation.md")
        let pdfURL = root.appendingPathComponent("citation.pdf")

        try await AgentDocumentExportService.export(file: file, section: section, to: markdownURL)
        try await AgentDocumentExportService.export(file: file, section: section, to: pdfURL)

        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        #expect(markdown.contains("page=2"))
        #expect(markdown.contains("Exported evidence text"))
        #expect(PDFDocument(url: pdfURL)?.pageCount ?? 0 >= 1)
    }
}
