//
//  AgentDocumentAttachmentParser.swift
//  WillDeep
//
//  Local, provider-independent parsing for composer document attachments.
//  Native text is preferred; PDF pages without a text layer fall back to
//  Apple Vision OCR. The OCR protocol intentionally leaves room for an
//  optional PaddleOCR implementation without making it a runtime dependency.
//

import AppKit
import Foundation
import PDFKit
import Vision

nonisolated protocol AgentAttachmentOCRProviding: Sendable {
    var providerID: String { get }
    func recognizeText(in image: CGImage) throws -> String
}

nonisolated struct AgentVisionOCRProvider: AgentAttachmentOCRProviding {
    let providerID = "apple-vision"

    func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = (request.results ?? []).sorted { lhs, rhs in
            let verticalDelta = lhs.boundingBox.midY - rhs.boundingBox.midY
            if abs(verticalDelta) > 0.015 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        return observations.compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated enum AgentDocumentAttachmentParser {
    private static let maxTextCharacters = 500_000
    private static let maxTextInputBytes = 4 * 1_024 * 1_024
    private static let targetChunkCharacters = 3_500
    private static let maxPDFPages = 200
    private static let maxOCRPages = 60
    private static let pdfOCRImageMaxDimension: CGFloat = 2_200

    enum ParserError: LocalizedError {
        case unsupported
        case unreadable
        case malformedOfficeDocument

        var errorDescription: String? {
            switch self {
            case .unsupported: return "Unsupported attachment type."
            case .unreadable: return "The attachment could not be read."
            case .malformedOfficeDocument: return "The Office document could not be parsed."
            }
        }
    }

    static func analyze(
        url: URL,
        forceText: Bool = false,
        ocrProvider: any AgentAttachmentOCRProviding = AgentVisionOCRProvider()
    ) async throws -> AgentAttachmentAnalysis {
        try await Task.detached(priority: .userInitiated) {
            try analyzeSynchronously(
                url: url,
                forceText: forceText,
                ocrProvider: ocrProvider
            )
        }.value
    }

    private static func analyzeSynchronously(
        url: URL,
        forceText: Bool,
        ocrProvider: any AgentAttachmentOCRProviding
    ) throws -> AgentAttachmentAnalysis {
        if forceText {
            return try analyzeText(url: url)
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return try analyzePDF(url: url, ocrProvider: ocrProvider)
        case "docx":
            return try analyzeDOCX(url: url)
        case "xlsx":
            return try analyzeXLSX(url: url)
        default:
            guard AgentComposerAttachmentSupport.isKnownTextDocument(url) else {
                throw ParserError.unsupported
            }
            return try analyzeText(url: url)
        }
    }

    private static func analyzeText(url: URL) throws -> AgentAttachmentAnalysis {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ParserError.unreadable
        }
        defer { try? handle.close() }
        guard var data = try? handle.read(upToCount: maxTextInputBytes + 1),
              !data.isEmpty else {
            throw ParserError.unreadable
        }
        let wasByteTruncated = data.count > maxTextInputBytes
        if wasByteTruncated { data.removeLast(data.count - maxTextInputBytes) }
        guard var rawText = decodeText(data) else {
            throw ParserError.unreadable
        }
        if wasByteTruncated { rawText += "\n\n[truncated at 4 MiB input]" }
        let text = limit(rawText, to: maxTextCharacters)
        let sections = chunkText(text, sourcePrefix: "lines")
        return analysis(kind: .text, sections: sections, totalUnitCount: sections.count)
    }

    private static func analyzeDOCX(url: URL) throws -> AgentAttachmentAnalysis {
        guard let text = AgentOfficeAttachmentReader.extractDOCXText(url: url) else {
            throw ParserError.malformedOfficeDocument
        }
        let sections = headingSections(from: limit(text, to: maxTextCharacters))
        return analysis(kind: .word, sections: sections, totalUnitCount: sections.count)
    }

    private static func analyzeXLSX(url: URL) throws -> AgentAttachmentAnalysis {
        guard let sheets = AgentOfficeAttachmentReader.extractXLSXSheets(url: url) else {
            throw ParserError.malformedOfficeDocument
        }
        var warnings: [String] = []
        let sections = sheets.enumerated().map { index, sheet in
            if sheet.isHidden {
                warnings.append("hidden-sheet:\(sheet.name)")
            }
            return AgentAttachmentSection(
                id: "sheet-\(index + 1)",
                kind: .sheet,
                ordinal: index + 1,
                title: sheet.name,
                sourceReference: "sheet=\(sheet.name)",
                text: limit(sheet.text, to: maxTextCharacters),
                wasRecognizedByOCR: false
            )
        }
        return analysis(
            kind: .spreadsheet,
            sections: sections,
            totalUnitCount: sheets.count,
            warnings: warnings
        )
    }

    private static func analyzePDF(
        url: URL,
        ocrProvider: any AgentAttachmentOCRProviding
    ) throws -> AgentAttachmentAnalysis {
        guard let document = PDFDocument(url: url) else {
            throw ParserError.unreadable
        }

        let pageCount = document.pageCount
        let parsedPageCount = min(pageCount, maxPDFPages)
        var sections: [AgentAttachmentSection] = []
        var warnings: [String] = []
        var didUseOCR = false
        var ocrPageCount = 0

        for index in 0..<parsedPageCount {
            guard let page = document.page(at: index) else { continue }
            var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var usedOCR = false

            if text.isEmpty, ocrPageCount < maxOCRPages,
               let image = renderedImage(for: page) {
                ocrPageCount += 1
                if let recognized = try? ocrProvider.recognizeText(in: image), !recognized.isEmpty {
                    text = recognized
                    usedOCR = true
                    didUseOCR = true
                }
            }

            guard !text.isEmpty else {
                warnings.append("empty-pdf-page:\(index + 1)")
                continue
            }
            sections.append(
                AgentAttachmentSection(
                    id: "page-\(index + 1)",
                    kind: .page,
                    ordinal: index + 1,
                    title: "Page \(index + 1)",
                    sourceReference: "page=\(index + 1)",
                    text: limit(text, to: maxTextCharacters),
                    wasRecognizedByOCR: usedOCR
                )
            )
        }

        if pageCount > maxPDFPages {
            warnings.append("pdf-page-limit:\(maxPDFPages):\(pageCount)")
        }
        if ocrPageCount >= maxOCRPages,
           sections.count < parsedPageCount {
            warnings.append("ocr-page-limit:\(maxOCRPages)")
        }

        return analysis(
            kind: .pdf,
            sections: sections,
            totalUnitCount: pageCount,
            didUseOCR: didUseOCR,
            warnings: warnings
        )
    }

    private static func analysis(
        kind: AgentAttachmentDocumentKind,
        sections: [AgentAttachmentSection],
        totalUnitCount: Int,
        didUseOCR: Bool = false,
        warnings: [String] = []
    ) -> AgentAttachmentAnalysis {
        AgentAttachmentAnalysis(
            documentKind: kind,
            sections: sections,
            totalUnitCount: totalUnitCount,
            didUseOCR: didUseOCR,
            warnings: warnings,
            containsPotentialPromptInjection: AgentAttachmentInjectionScanner.containsSuspiciousInstructions(
                sections.map(\.text).joined(separator: "\n")
            )
        )
    }

    private static func renderedImage(for page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(1, pdfOCRImageMaxDimension / max(bounds.width, bounds.height))
        let size = NSSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        let thumbnail = page.thumbnail(of: size, for: .mediaBox)
        var proposedRect = NSRect(origin: .zero, size: thumbnail.size)
        return thumbnail.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    private static func headingSections(from text: String) -> [AgentAttachmentSection] {
        let lines = text.components(separatedBy: .newlines)
        var sections: [AgentAttachmentSection] = []
        var currentTitle = "Document body"
        var currentLines: [String] = []

        func flush() {
            let body = currentLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            let ordinal = sections.count + 1
            sections.append(
                AgentAttachmentSection(
                    id: "section-\(ordinal)",
                    kind: .heading,
                    ordinal: ordinal,
                    title: currentTitle,
                    sourceReference: "section=\(currentTitle)",
                    text: body,
                    wasRecognizedByOCR: false
                )
            )
            currentLines = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") {
                flush()
                currentTitle = trimmed.drop { $0 == "#" || $0 == " " }.description
                if currentTitle.isEmpty { currentTitle = "Untitled section" }
            } else {
                currentLines.append(line)
            }
        }
        flush()
        return sections.isEmpty ? chunkText(text, sourcePrefix: "paragraphs") : sections
    }

    private static func chunkText(_ text: String, sourcePrefix: String) -> [AgentAttachmentSection] {
        let lines = text.components(separatedBy: .newlines)
        var sections: [AgentAttachmentSection] = []
        var buffer: [String] = []
        var characterCount = 0
        var startLine = 1

        func flush(endLine: Int) {
            let body = buffer.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            let ordinal = sections.count + 1
            sections.append(
                AgentAttachmentSection(
                    id: "chunk-\(ordinal)",
                    kind: .chunk,
                    ordinal: ordinal,
                    title: "\(sourcePrefix.capitalized) \(startLine)-\(endLine)",
                    sourceReference: "\(sourcePrefix)=\(startLine)-\(endLine)",
                    text: body,
                    wasRecognizedByOCR: false
                )
            )
            buffer = []
            characterCount = 0
        }

        for (index, line) in lines.enumerated() {
            if !buffer.isEmpty, characterCount + line.count + 1 > targetChunkCharacters {
                flush(endLine: index)
                startLine = index + 1
            }
            buffer.append(line)
            characterCount += line.count + 1
        }
        flush(endLine: lines.count)
        return sections
    }

    private static func decodeText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        if let latin1 = String(data: data, encoding: .isoLatin1) { return latin1 }
        return nil
    }

    private static func limit(_ text: String, to maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let end = text.index(text.startIndex, offsetBy: maxCharacters)
        return "\(text[..<end])\n\n[truncated at \(maxCharacters) chars]"
    }
}

nonisolated enum AgentAttachmentInjectionScanner {
    private static let suspiciousPhrases = [
        "ignore previous instructions",
        "ignore all previous",
        "reveal the system prompt",
        "developer message",
        "upload the secret",
        "send the password",
        "忽略之前的指令",
        "忽略所有指令",
        "泄露系统提示词",
        "上传密钥",
        "发送密码"
    ]

    static func containsSuspiciousInstructions(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return suspiciousPhrases.contains { normalized.contains($0) }
    }
}
