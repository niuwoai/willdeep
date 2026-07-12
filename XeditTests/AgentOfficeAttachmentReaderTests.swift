//
//  AgentOfficeAttachmentReaderTests.swift
//  XeditTests
//

import AppKit
import Foundation
import PDFKit
import Testing
@testable import WillDeep

@Suite
struct AgentOfficeAttachmentReaderTests {
    @Test("Composer attachment allow-list covers text, source, PDF, Word, and Excel files")
    func composerAttachmentAllowList() {
        for filename in [
            "notes.txt", "readme.md", "main.go", "tool.rb", "script.py",
            "index.php", "data.csv", "data.tsv", "payload.json",
            "report.pdf", "brief.docx", "budget.xlsx"
        ] {
            #expect(
                AgentComposerAttachmentSupport.isSupportedDocument(
                    URL(fileURLWithPath: "/tmp/\(filename)")
                )
            )
        }
        #expect(
            !AgentComposerAttachmentSupport.isSupportedDocument(
                URL(fileURLWithPath: "/tmp/archive.zip")
            )
        )
    }

    @Test("DOCX attachments are converted to readable paragraph text")
    func docxAttachmentExtractsText() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("docx-src")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("word"),
            withIntermediateDirectories: true
        )
        try write(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:body>
                <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>项目摘要</w:t></w:r></w:p>
                <w:p><w:r><w:t>第一段说明</w:t></w:r></w:p>
                <w:p><w:r><w:t>第二段结论</w:t></w:r></w:p>
              </w:body>
            </w:document>
            """,
            to: source.appendingPathComponent("word/document.xml")
        )

        let docx = root.appendingPathComponent("sample.docx")
        try zipDirectory(source, to: docx)

        let body = try #require(AgentOfficeAttachmentReader.read(url: docx))
        #expect(body.contains("# 项目摘要"))
        #expect(body.contains("第一段说明"))
        #expect(body.contains("第二段结论"))
        #expect(!body.contains("file unreadable or binary"))
    }

    @Test("XLSX attachments expose sheet names and sample rows")
    func xlsxAttachmentExtractsWorkbookSummary() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("xlsx-src")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("xl/worksheets"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("xl/_rels"),
            withIntermediateDirectories: true
        )
        try write(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <sheets>
                <sheet name="销售数据" sheetId="1" state="hidden" r:id="rId1"/>
              </sheets>
            </workbook>
            """,
            to: source.appendingPathComponent("xl/workbook.xml")
        )
        try write(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/>
            </Relationships>
            """,
            to: source.appendingPathComponent("xl/_rels/workbook.xml.rels")
        )
        try write(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <sst>
              <si><t>产品</t></si>
              <si><t>收入</t></si>
              <si><t>Pro</t></si>
            </sst>
            """,
            to: source.appendingPathComponent("xl/sharedStrings.xml")
        )
        try write(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet>
              <sheetData>
                <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
                <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><f>SUM(B2:B2)</f><v>42</v></c></row>
              </sheetData>
            </worksheet>
            """,
            to: source.appendingPathComponent("xl/worksheets/sheet1.xml")
        )

        let xlsx = root.appendingPathComponent("sample.xlsx")
        try zipDirectory(source, to: xlsx)

        let body = try #require(AgentOfficeAttachmentReader.read(url: xlsx))
        #expect(body.contains("Excel workbook: 1 sheet"))
        #expect(body.contains("## Sheet: 销售数据"))
        #expect(body.contains("产品 | 收入"))
        #expect(body.contains("Pro | =SUM(B2:B2) → 42"))
        #expect(body.contains("[hidden]"))
    }

    @Test("Image-only PDF pages fall back to Apple Vision OCR")
    func scannedPDFAttachmentUsesVisionOCR() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let image = NSImage(size: NSSize(width: 1_200, height: 300))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 82, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        NSString(string: "WILLDEEP OCR 2048").draw(
            at: NSPoint(x: 70, y: 105),
            withAttributes: attributes
        )
        image.unlockFocus()

        let document = PDFDocument()
        let page = try #require(PDFPage(image: image))
        document.insert(page, at: 0)
        let pdf = root.appendingPathComponent("scanned.pdf")
        #expect(document.write(to: pdf))

        let analysis = try await AgentDocumentAttachmentParser.analyze(url: pdf)
        #expect(analysis.documentKind == .pdf)
        #expect(analysis.didUseOCR)
        #expect(analysis.sections.first?.sourceReference == "page=1")
        #expect(analysis.sections.first?.text.uppercased().contains("WILLDEEP") == true)
    }

    @Test("Parsed conversation documents survive session persistence")
    func sessionDocumentPersistence() throws {
        let section = AgentAttachmentSection(
            id: "page-1",
            kind: .page,
            ordinal: 1,
            title: "Page 1",
            sourceReference: "page=1",
            text: "Persistent local document text",
            wasRecognizedByOCR: true
        )
        let analysis = AgentAttachmentAnalysis(
            documentKind: .pdf,
            sections: [section],
            totalUnitCount: 1,
            didUseOCR: true,
            warnings: [],
            containsPotentialPromptInjection: false
        )
        var attachment = AgentFileAttachment(
            url: URL(fileURLWithPath: "/tmp/reference.pdf"),
            relativePath: "reference.pdf"
        )
        attachment.parseStatus = .ready
        attachment.analysis = analysis
        attachment.excludedSectionIDs = ["page-2"]
        attachment.isEnabled = false
        attachment.sourceFileSize = 4_096
        attachment.sourceModifiedAt = Date(timeIntervalSince1970: 123_456)

        let encoded = try JSONEncoder().encode(
            AgentSession(documentAttachments: [attachment])
        )
        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)
        let persisted = try #require(decoded.documentAttachments.first)

        #expect(persisted == attachment)
        #expect(persisted.analysis?.sections.first?.sourceReference == "page=1")
        #expect(!persisted.isEnabled)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_office_attachment_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.data(using: .utf8)?.write(to: url)
    }

    private func zipDirectory(_ directory: URL, to output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-qr", output.path, "."]
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
