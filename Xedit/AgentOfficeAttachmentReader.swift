//
//  AgentOfficeAttachmentReader.swift
//  WillDeep
//
//  Converts common office documents into compact, model-readable text
//  blocks before they are spliced into an Agent turn.
//

import Foundation
import PDFKit
import Darwin

nonisolated enum AgentOfficeAttachmentReader {
    private static let maxTextCharacters = 120_000
    private static let maxPDFPages = 30
    private static let maxWorkbookSheets = 8
    private static let maxSheetRows = 40
    private static let maxSheetColumns = 20
    private static let maxArchiveEntryBytes = 16 * 1_024 * 1_024
    private static let maxSharedStringCount = 100_000
    private static let maxSharedStringCharacters = 2_000_000

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

    static func extractDOCXText(url: URL) -> String? {
        guard let xml = unzipEntry("word/document.xml", from: url) else { return nil }
        let parser = XMLParser(data: xml)
        let delegate = DOCXTextDelegate(maxCharacters: maxTextCharacters)
        parser.delegate = delegate
        _ = parser.parse()
        let text = delegate.extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func extractXLSXSheets(url: URL) -> [(name: String, text: String, isHidden: Bool)]? {
        guard let workbookXML = unzipEntry("xl/workbook.xml", from: url) else { return nil }
        let sheets = parseWorkbookSheets(workbookXML)
        let rels = unzipEntry("xl/_rels/workbook.xml.rels", from: url).map { parseWorkbookRelationships($0) } ?? [:]
        let sharedStrings = unzipEntry("xl/sharedStrings.xml", from: url).map { parseSharedStrings($0) } ?? []

        return sheets.prefix(maxWorkbookSheets).map { sheet in
            let target = rels[sheet.relationshipID] ?? "worksheets/sheet\(sheet.index).xml"
            let normalizedTarget = target.hasPrefix("xl/") ? String(target.dropFirst(3)) : target
            let entry = "xl/" + normalizedTarget.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let sheetXML = unzipEntry(entry, from: url) else {
                return (sheet.name, "(unable to read \(entry))", sheet.isHidden)
            }
            let rows = parseWorksheetRows(sheetXML, sharedStrings: sharedStrings)
            return (sheet.name, renderSheet(name: sheet.name, rows: rows), sheet.isHidden)
        }
    }

    private static func readPDF(url: URL) -> String {
        guard let document = PDFDocument(url: url) else {
            return fenced("PDF could not be opened.")
        }

        let pageCount = document.pageCount
        var sections: [String] = ["PDF document: \(pageCount) page\(pageCount == 1 ? "" : "s")"]
        var extractedPageCount = 0
        for index in 0..<min(pageCount, maxPDFPages) {
            guard let page = document.page(at: index) else { continue }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }
            extractedPageCount += 1
            sections.append("Page \(index + 1):\n\(text)")
        }
        if pageCount > 0, extractedPageCount == 0 {
            sections.append("[no extractable text; this may be a scanned PDF that requires OCR]")
        }
        if pageCount > maxPDFPages {
            sections.append("[truncated after \(maxPDFPages) pages]")
        }
        return fenced(limit(sections.joined(separator: "\n\n"), to: maxTextCharacters))
    }

    private static func readDOCX(url: URL) -> String {
        let body = extractDOCXText(url: url) ?? "DOCX text could not be extracted."
        return fenced(limit(body, to: maxTextCharacters))
    }

    private static func readXLSX(url: URL) -> String {
        guard let workbookXML = unzipEntry("xl/workbook.xml", from: url) else {
            return fenced("XLSX workbook metadata could not be extracted.")
        }

        let sheets = parseWorkbookSheets(workbookXML)
        var blocks: [String] = ["Excel workbook: \(sheets.count) sheet\(sheets.count == 1 ? "" : "s")"]
        for sheet in extractXLSXSheets(url: url) ?? [] {
            let hiddenLabel = sheet.isHidden ? " [hidden]" : ""
            blocks.append(sheet.text.replacingOccurrences(of: "## Sheet: \(sheet.name)", with: "## Sheet: \(sheet.name)\(hiddenLabel)"))
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
        let delegate = SharedStringsDelegate(
            maxValues: maxSharedStringCount,
            maxCharacters: maxSharedStringCharacters
        )
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.values
    }

    private static func parseWorksheetRows(_ data: Data, sharedStrings: [String]) -> [[String]] {
        let parser = XMLParser(data: data)
        let delegate = WorksheetRowsDelegate(
            sharedStrings: sharedStrings,
            maxRows: maxSheetRows,
            maxColumns: maxSheetColumns
        )
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
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let timeout = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: timeout)

        var data = Data()
        data.reserveCapacity(min(maxArchiveEntryBytes, 512 * 1_024))
        var exceededBudget = false
        while true {
            let chunk: Data
            do {
                guard let next = try output.fileHandleForReading.read(upToCount: 64 * 1_024), !next.isEmpty else { break }
                chunk = next
            } catch {
                break
            }
            let remaining = maxArchiveEntryBytes - data.count
            if remaining > 0 { data.append(chunk.prefix(remaining)) }
            if chunk.count > remaining {
                exceededBudget = true
                process.terminate()
                break
            }
        }
        process.waitUntilExit()
        timeout.cancel()
        guard !exceededBudget, process.terminationStatus == 0 else { return nil }
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

private nonisolated struct WorkbookSheet {
    let index: Int
    let name: String
    let relationshipID: String
    let isHidden: Bool
}

private nonisolated final class DOCXTextDelegate: NSObject, XMLParserDelegate {
    private let maxCharacters: Int
    private var currentElement = ""
    private var buffer = ""
    private var paragraphStyle = ""
    private(set) var text = ""

    var extractedText: String {
        let trailingText = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trailingText.isEmpty else { return text }
        return text.isEmpty ? trailingText : "\(text)\n\(trailingText)"
    }

    init(maxCharacters: Int) {
        self.maxCharacters = maxCharacters
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        if elementName == "w:p" || elementName == "p" {
            paragraphStyle = ""
        }
        if elementName == "w:pStyle" || elementName == "pStyle" {
            paragraphStyle = attributeDict["w:val"] ?? attributeDict["val"] ?? ""
        }
        if elementName == "w:tab" || elementName == "tab" {
            buffer += "\t"
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "w:t" || currentElement == "t" {
            let remaining = max(0, maxCharacters - text.count - buffer.count)
            if remaining > 0 { buffer += String(string.prefix(remaining)) }
            if remaining == 0 || string.count > remaining { parser.abortParsing() }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "w:p" || elementName == "p" {
            let line = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                if !text.isEmpty { text += "\n" }
                let headingLevel = paragraphStyle.lowercased().hasPrefix("heading")
                    ? Int(paragraphStyle.dropFirst("heading".count))
                    : nil
                if let headingLevel {
                    text += String(repeating: "#", count: min(max(headingLevel, 1), 6)) + " " + line
                } else {
                    text += line
                }
            }
            buffer = ""
            paragraphStyle = ""
        }
        currentElement = ""
    }
}

private nonisolated final class WorkbookSheetsDelegate: NSObject, XMLParserDelegate {
    private(set) var sheets: [WorkbookSheet] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "sheet" || elementName == "s:sheet" else { return }
        let name = attributeDict["name"] ?? "Sheet \(sheets.count + 1)"
        let relationshipID = attributeDict["r:id"] ?? attributeDict["id"] ?? ""
        let state = attributeDict["state"]?.lowercased() ?? "visible"
        sheets.append(
            WorkbookSheet(
                index: sheets.count + 1,
                name: name,
                relationshipID: relationshipID,
                isHidden: state == "hidden" || state == "veryhidden"
            )
        )
    }
}

private nonisolated final class WorkbookRelationshipsDelegate: NSObject, XMLParserDelegate {
    private(set) var targets: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "Relationship" else { return }
        guard let id = attributeDict["Id"], let target = attributeDict["Target"] else { return }
        targets[id] = target
    }
}

private nonisolated final class SharedStringsDelegate: NSObject, XMLParserDelegate {
    private let maxValues: Int
    private let maxCharacters: Int
    private var inStringItem = false
    private var inText = false
    private var buffer = ""
    private(set) var values: [String] = []
    private var characterCount = 0

    init(maxValues: Int, maxCharacters: Int) {
        self.maxValues = maxValues
        self.maxCharacters = maxCharacters
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "si" {
            inStringItem = true
            buffer = ""
        } else if inStringItem, elementName == "t" {
            inText = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inText else { return }
        let remaining = max(0, maxCharacters - characterCount - buffer.count)
        if remaining > 0 { buffer += String(string.prefix(remaining)) }
        if remaining == 0 || string.count > remaining { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" {
            inText = false
        } else if elementName == "si" {
            values.append(buffer)
            characterCount += buffer.count
            buffer = ""
            inStringItem = false
            if values.count >= maxValues || characterCount >= maxCharacters {
                parser.abortParsing()
            }
        }
    }
}

private nonisolated final class WorksheetRowsDelegate: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private let maxRows: Int
    private let maxColumns: Int
    private var currentCellReference = ""
    private var currentCellType = ""
    private var currentCellValue = ""
    private var currentFormula = ""
    private var currentRow: [Int: String] = [:]
    private var inValue = false
    private var inFormula = false
    private(set) var rows: [[String]] = []

    init(sharedStrings: [String], maxRows: Int, maxColumns: Int) {
        self.sharedStrings = sharedStrings
        self.maxRows = maxRows
        self.maxColumns = maxColumns
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "row":
            currentRow = [:]
        case "c":
            currentCellReference = attributeDict["r"] ?? ""
            currentCellType = attributeDict["t"] ?? ""
            currentCellValue = ""
            currentFormula = ""
        case "v", "t":
            inValue = true
        case "f":
            inFormula = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue {
            currentCellValue += string
        } else if inFormula {
            currentFormula += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "v", "t":
            inValue = false
        case "f":
            inFormula = false
        case "c":
            let index = columnIndex(from: currentCellReference)
            if index < maxColumns {
                currentRow[index] = String(resolvedCellValue().prefix(4_096))
            }
        case "row":
            if !currentRow.isEmpty {
                let maxIndex = min(currentRow.keys.max() ?? 0, maxColumns - 1)
                rows.append((0...maxIndex).map { currentRow[$0] ?? "" })
            }
            if rows.count >= maxRows { parser.abortParsing() }
        default:
            break
        }
    }

    private func resolvedCellValue() -> String {
        let raw = currentCellValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentCellType == "s", let idx = Int(raw), sharedStrings.indices.contains(idx) {
            return sharedStrings[idx]
        }
        let formula = currentFormula.trimmingCharacters(in: .whitespacesAndNewlines)
        if !formula.isEmpty {
            return raw.isEmpty ? "=\(formula)" : "=\(formula) → \(raw)"
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
