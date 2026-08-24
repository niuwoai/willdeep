//
//  AgentAttachmentModels.swift
//  WillDeep
//
//  Agent attachment and knowledge-folder models split out of AgentModels.swift.
//

import Foundation

nonisolated enum AgentAttachmentParseStatus: String, Codable, Equatable, Sendable {
    case parsing
    case ready
    case failed
}

nonisolated enum AgentAttachmentDocumentKind: String, Codable, Equatable, Sendable {
    case text
    case pdf
    case word
    case spreadsheet
}

nonisolated enum AgentAttachmentSectionKind: String, Codable, Equatable, Sendable {
    case page
    case sheet
    case heading
    case chunk
}

nonisolated struct AgentAttachmentSection: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let kind: AgentAttachmentSectionKind
    let ordinal: Int
    let title: String
    let sourceReference: String
    let text: String
    let wasRecognizedByOCR: Bool
}

/// Lightweight per-section metadata kept in session JSON after the full
/// extracted text moved into an `AgentAttachmentContentStore` sidecar file.
nonisolated struct AgentAttachmentSectionSummary: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let kind: AgentAttachmentSectionKind
    let ordinal: Int
    let title: String
    let sourceReference: String
    let characterCount: Int
    let preview: String
    let wasRecognizedByOCR: Bool

    init(section: AgentAttachmentSection) {
        id = section.id
        kind = section.kind
        ordinal = section.ordinal
        title = section.title
        sourceReference = section.sourceReference
        characterCount = section.text.count
        preview = Self.preview(of: section.text)
        wasRecognizedByOCR = section.wasRecognizedByOCR
    }

    private static let maxPreviewCharacters = 160

    private static func preview(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxPreviewCharacters else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxPreviewCharacters)
        return String(trimmed[..<end]) + "…"
    }
}

nonisolated struct AgentAttachmentAnalysis: Codable, Equatable, Sendable {
    let documentKind: AgentAttachmentDocumentKind
    /// Per-section metadata (titles, locators, sizes) that stays in session
    /// JSON so lists and toggles render without touching the sidecar file.
    private(set) var sectionSummaries: [AgentAttachmentSectionSummary]
    /// Content-addressed sidecar file holding the full section texts.
    private(set) var contentFilePath: String?
    private(set) var contentSHA256: String?
    /// Full sections still held inline: a fresh parse before `externalized()`
    /// ran, or a legacy session whose JSON inlines the text. Encoded back
    /// under the legacy `sections` key so nothing is lost if externalization
    /// fails or never runs.
    private(set) var inlineSections: [AgentAttachmentSection]?
    let totalUnitCount: Int
    let didUseOCR: Bool
    let warnings: [String]
    let containsPotentialPromptInjection: Bool

    init(
        documentKind: AgentAttachmentDocumentKind,
        sections: [AgentAttachmentSection],
        totalUnitCount: Int,
        didUseOCR: Bool,
        warnings: [String],
        containsPotentialPromptInjection: Bool
    ) {
        self.documentKind = documentKind
        self.sectionSummaries = sections.map(AgentAttachmentSectionSummary.init)
        self.inlineSections = sections
        self.totalUnitCount = totalUnitCount
        self.didUseOCR = didUseOCR
        self.warnings = warnings
        self.containsPotentialPromptInjection = containsPotentialPromptInjection
    }

    var extractedCharacterCount: Int {
        sectionSummaries.reduce(0) { $0 + $1.characterCount }
    }

    /// Compatibility accessor for code paths that need the full extracted
    /// text. New list and toggle UI should prefer `sectionSummaries` so it
    /// does not read a sidecar file while rendering.
    var sections: [AgentAttachmentSection] { loadedSections() }

    var needsContentExternalization: Bool { inlineSections != nil }

    /// Full section texts. Reads the sidecar file when the content was
    /// externalized, so call at send/render/export time — not per frame.
    func loadedSections() -> [AgentAttachmentSection] {
        if let inlineSections { return inlineSections }
        guard let contentFilePath, let contentSHA256 else { return [] }
        return AgentAttachmentContentStore.loadSections(
            atPath: contentFilePath,
            expectedSHA256: contentSHA256
        ) ?? []
    }

    /// Moves the inline section texts into the content store, leaving only
    /// summaries plus a path/hash reference behind.
    func externalized() throws -> AgentAttachmentAnalysis {
        guard let inlineSections else { return self }
        let stored = try AgentAttachmentContentStore.store(sections: inlineSections)
        var copy = self
        copy.contentFilePath = stored.filePath
        copy.contentSHA256 = stored.sha256
        copy.inlineSections = nil
        return copy
    }

    /// Externalizes, keeping the inline copy on failure so the attachment
    /// stays usable (just heavier) when the disk write fails.
    func externalizedOrInline() -> AgentAttachmentAnalysis {
        do {
            return try externalized()
        } catch {
            print("AgentAttachmentContentStore: failed to externalize attachment content")
            return self
        }
    }

    enum CodingKeys: String, CodingKey {
        case documentKind
        // Legacy key: full sections inlined in session JSON.
        case sections
        case sectionSummaries, contentFilePath, contentSHA256
        case totalUnitCount, didUseOCR, warnings, containsPotentialPromptInjection
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        documentKind = try c.decode(AgentAttachmentDocumentKind.self, forKey: .documentKind)
        let inline = try c.decodeIfPresent([AgentAttachmentSection].self, forKey: .sections)
        inlineSections = inline
        sectionSummaries = try c.decodeIfPresent([AgentAttachmentSectionSummary].self, forKey: .sectionSummaries)
            ?? inline?.map(AgentAttachmentSectionSummary.init)
            ?? []
        contentFilePath = try c.decodeIfPresent(String.self, forKey: .contentFilePath)
        contentSHA256 = try c.decodeIfPresent(String.self, forKey: .contentSHA256)
        totalUnitCount = try c.decode(Int.self, forKey: .totalUnitCount)
        didUseOCR = try c.decode(Bool.self, forKey: .didUseOCR)
        warnings = try c.decode([String].self, forKey: .warnings)
        containsPotentialPromptInjection = try c.decode(Bool.self, forKey: .containsPotentialPromptInjection)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(documentKind, forKey: .documentKind)
        try c.encodeIfPresent(inlineSections, forKey: .sections)
        try c.encode(sectionSummaries, forKey: .sectionSummaries)
        try c.encodeIfPresent(contentFilePath, forKey: .contentFilePath)
        try c.encodeIfPresent(contentSHA256, forKey: .contentSHA256)
        try c.encode(totalUnitCount, forKey: .totalUnitCount)
        try c.encode(didUseOCR, forKey: .didUseOCR)
        try c.encode(warnings, forKey: .warnings)
        try c.encode(containsPotentialPromptInjection, forKey: .containsPotentialPromptInjection)
    }
}

/// A local file staged in the composer. Parsing starts immediately so the UI
/// can preview exactly what will be sent; the original URL remains the source
/// of truth and can be re-attached when the user wants a fresh parse.
nonisolated struct AgentFileAttachment: Identifiable, Codable, Equatable, Sendable {
    let url: URL
    let relativePath: String
    var parseStatus: AgentAttachmentParseStatus = .parsing
    var analysis: AgentAttachmentAnalysis?
    var parseError: String?
    var excludedSectionIDs: Set<String> = []
    var isEnabled: Bool = true
    var sourceFileSize: Int64?
    var sourceModifiedAt: Date?
    /// Set only after the user explicitly confirms that an otherwise unknown
    /// file of at most 8 KB should be decoded and sent as plain text.
    var treatsUnknownTypeAsText: Bool?

    var id: String { url.standardizedFileURL.path }

    var includedSections: [AgentAttachmentSection] {
        guard let analysis else { return [] }
        return analysis.loadedSections().filter { !excludedSectionIDs.contains($0.id) }
    }

    func externalizingAttachmentContent() -> AgentFileAttachment {
        guard let analysis else { return self }
        var copy = self
        copy.analysis = analysis.externalizedOrInline()
        return copy
    }
}

nonisolated enum AgentKnowledgeFolderIndexStatus: String, Codable, Equatable, Sendable {
    case pending
    case indexing
    case ready
    case failed
}

nonisolated enum AgentDocumentTaskMode: String, Codable, CaseIterable, Equatable, Sendable {
    case automatic
    case summarize
    case compare
    case spreadsheetAnalysis
    case codeReview
    case evidenceExtraction
}

nonisolated struct AgentKnowledgeFolder: Identifiable, Codable, Equatable, Sendable {
    let url: URL
    var isEnabled: Bool = true
    var status: AgentKnowledgeFolderIndexStatus = .pending
    var documents: [AgentFileAttachment] = []
    var excludedPatterns: [String] = []
    var skippedFileCount: Int = 0
    var lastIndexedAt: Date?
    var errorMessage: String?

    var id: String { url.standardizedFileURL.path }

    func externalizingAttachmentContent() -> AgentKnowledgeFolder {
        var copy = self
        copy.documents = documents.map { $0.externalizingAttachmentContent() }
        return copy
    }
}

