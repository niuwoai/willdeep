//
//  AgentOfficeAttachmentReaderTests.swift
//  XeditTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentOfficeAttachmentReaderTests {
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
                <sheet name="销售数据" sheetId="1" r:id="rId1"/>
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
                <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>42</v></c></row>
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
        #expect(body.contains("Pro | 42"))
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
