//
//  AgentOfficeAttachmentReader.swift
//  WillDeep
//
//  Converts common office documents into compact, model-readable text
//  blocks before they are spliced into an Agent turn.
//

import Foundation
import PDFKit

enum AgentOfficeAttachmentReader {
    private static let maxTextCharacters = 120_000
    private static let maxPDFPages = 30
    private static let maxWorkbookSheets = 8
    private static let maxSheetRows = 40
    private static let maxSheetColumns = 20

    static func read(url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return readPDF(url: url)
        case "docx":
            return readDOCX(url: url)
        case "xlsx":
            return readXLSX(url: url)
        default:
            return nil
        }
    }

    private static func readPDF(url: URL) -> String {
        guard let document = PDFDocument(url: url) else {
            return fenced("PDF could not be opened.")
        }

        let pageCount = document.pageCount
        var sections: [String] = ["PDF document: \(pageCount) page\(pageCount == 1 ? "" : "s")"]
        for index in 0..<min(pageCount, maxPDFPages) {
            guard let page = document.page(at: index) else { continue }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }
            sections.append("Page \(index + 1):\n\(text)")
        }
        if pageCount > maxPDFPages {
            sections.append("[truncated after \(maxPDFPages) pages]")
        }
        return fenced(limit(sections.joined(separator: "\n\n"), to: maxTextCharacters))
    }

    private static func readDOCX(url: URL) -> String {
        guard let xml = unzipEntry("word/document.xml", from: url) else {
            return fenced("DOCX text could not be extracted.")
        }
        let parser = XMLParser(data: xml)
        let delegate = DOCXTextDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            return fenced("DOCX text could not be parsed.")
        }

        let text = delegate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.isEmpty ? "DOCX contains no extractable text." : text
        return fenced(limit(body, to: maxTextCharacters))
    }

    private static func readXLSX(url: URL) -> String {
        guard let workbookXML = unzipEntry("xl/workbook.xml", from: url) else {
            return fenced("XLSX workbook metadata could not be extracted.")
        }

        let sheets = parseWorkbookSheets(workbookXML)
        let rels = unzipEntry("xl/_rels/workbook.xml.rels", from: url).map { parseWorkbookRelationships($0) } ?? [:]
        let sharedStrings = unzipEntry("xl/sharedStrings.xml", from: url).map { parseSharedStrings($0) } ?? []

        var blocks: [String] = ["Excel workbook: \(sheets.count) sheet\(sheets.count == 1 ? "" : "s")"]
        for sheet in sheets.prefix(maxWorkbookSheets) {
            let target = rels[sheet.relationshipID] ?? "worksheets/sheet\(sheet.index).xml"
            let normalizedTarget = target.hasPrefix("xl/") ? String(target.dropFirst(3)) : target
            let entry = "xl/" + normalizedTarget.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let sheetXML = unzipEntry(entry, from: url) else {
                blocks.append("## Sheet: \(sheet.name)\n(unable to read \(entry))")
                continue
            }
            let rows = parseWorksheetRows(sheetXML, sharedStrings: sharedStrings)
            blocks.append(renderSheet(name: sheet.name, rows: rows))
        }

        if sheets.count > maxWorkbookSheets {
            blocks.append("[truncated after \(maxWorkbookSheets) sheets]")
        }
        return fenced(limit(blocks.joined(separator: "\n\n"), to: maxTextCharacters))
    }

    private static func parseWorkbookSheets(_ data: Data) -> [WorkbookSheet] {
        let parser = XMLParser(data: data)
        let delegate = WorkbookSheetsDelegate()
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.sheets
    }

    private static func parseWorkbookRelationships(_ data: Data) -> [String: String] {
        let parser = XMLParser(data: data)
        let delegate = WorkbookRelationshipsDelegate()
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.targets
    }

    private static func parseSharedStrings(_ data: Data) -> [String] {
        let parser = XMLParser(data: data)
        let delegate = SharedStringsDelegate()
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.values
    }

    private static func parseWorksheetRows(_ data: Data, sharedStrings: [String]) -> [[String]] {
        let parser = XMLParser(data: data)
        let delegate = WorksheetRowsDelegate(sharedStrings: sharedStrings)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.rows
    }

    private static func renderSheet(name: String, rows: [[String]]) -> String {
        guard !rows.isEmpty else {
            return "## Sheet: \(name)\n(empty or no extractable cells)"
        }

        let shownRows = rows.prefix(maxSheetRows).map { row in
            Array(row.prefix(maxSheetColumns)).map { sanitizeCell($0) }
        }
        var lines: [String] = ["## Sheet: \(name)", "Rows shown: \(shownRows.count) of \(rows.count) extracted"]
        for (index, row) in shownRows.enumerated() {
            lines.append("\(index + 1): " + row.joined(separator: " | "))
        }
        if rows.count > maxSheetRows {
            lines.append("[truncated after \(maxSheetRows) rows]")
        }
        return lines.joined(separator: "\n")
    }

    private static func sanitizeCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unzipEntry(_ entry: String, from url: URL) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, entry]

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return data.isEmpty ? nil : data
    }

    private static func fenced(_ body: String) -> String {
        "```\n\(body)\n```"
    }

    private static func limit(_ text: String, to maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let end = text.index(text.startIndex, offsetBy: maxCharacters)
        return "\(text[..<end])\n\n[truncated at \(maxCharacters) chars]"
    }
}

private struct WorkbookSheet {
    let index: Int
    let name: String
    let relationshipID: String
}

private final class DOCXTextDelegate: NSObject, XMLParserDelegate {
    private var currentElement = ""
    private var buffer = ""
    private(set) var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        if elementName == "w:tab" || elementName == "tab" {
            buffer += "\t"
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "w:t" || currentElement == "t" {
            buffer += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "w:p" || elementName == "p" {
            let line = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                if !text.isEmpty { text += "\n" }
                text += line
            }
            buffer = ""
        }
        currentElement = ""
    }
}

private final class WorkbookSheetsDelegate: NSObject, XMLParserDelegate {
    private(set) var sheets: [WorkbookSheet] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "sheet" || elementName == "s:sheet" else { return }
        let name = attributeDict["name"] ?? "Sheet \(sheets.count + 1)"
        let relationshipID = attributeDict["r:id"] ?? attributeDict["id"] ?? ""
        sheets.append(WorkbookSheet(index: sheets.count + 1, name: name, relationshipID: relationshipID))
    }
}

private final class WorkbookRelationshipsDelegate: NSObject, XMLParserDelegate {
    private(set) var targets: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "Relationship" else { return }
        guard let id = attributeDict["Id"], let target = attributeDict["Target"] else { return }
        targets[id] = target
    }
}

private final class SharedStringsDelegate: NSObject, XMLParserDelegate {
    private var inStringItem = false
    private var inText = false
    private var buffer = ""
    private(set) var values: [String] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "si" {
            inStringItem = true
            buffer = ""
        } else if inStringItem, elementName == "t" {
            inText = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" {
            inText = false
        } else if elementName == "si" {
            values.append(buffer)
            buffer = ""
            inStringItem = false
        }
    }
}

private final class WorksheetRowsDelegate: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private var currentCellReference = ""
    private var currentCellType = ""
    private var currentCellValue = ""
    private var currentRow: [Int: String] = [:]
    private var inValue = false
    private(set) var rows: [[String]] = []

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "row":
            currentRow = [:]
        case "c":
            currentCellReference = attributeDict["r"] ?? ""
            currentCellType = attributeDict["t"] ?? ""
            currentCellValue = ""
        case "v", "t":
            inValue = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue {
            currentCellValue += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "v", "t":
            inValue = false
        case "c":
            let index = columnIndex(from: currentCellReference)
            currentRow[index] = resolvedCellValue()
        case "row":
            if !currentRow.isEmpty {
                let maxIndex = currentRow.keys.max() ?? 0
                rows.append((0...maxIndex).map { currentRow[$0] ?? "" })
            }
        default:
            break
        }
    }

    private func resolvedCellValue() -> String {
        let raw = currentCellValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentCellType == "s", let idx = Int(raw), sharedStrings.indices.contains(idx) {
            return sharedStrings[idx]
        }
        return raw
    }

    private func columnIndex(from reference: String) -> Int {
        var value = 0
        for scalar in reference.unicodeScalars {
            let upper = CharacterSet.uppercaseLetters.contains(scalar)
                ? scalar.value
                : String(scalar).uppercased().unicodeScalars.first?.value ?? 0
            guard upper >= 65, upper <= 90 else { break }
            value = value * 26 + Int(upper - 64)
        }
        return max(0, value - 1)
    }
}
