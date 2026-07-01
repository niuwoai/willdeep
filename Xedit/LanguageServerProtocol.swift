//
//  LanguageServerProtocol.swift
//  WillDeep
//
//  Minimal Language Server Protocol types and JSON-RPC framing used by
//  WillDeep's first-stage IDE language service.
//

import Foundation

nonisolated struct LSPPosition: Codable, Equatable, Sendable {
    let line: Int
    let character: Int

    init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    init(utf16Offset: Int, in text: String) {
        let nsText = text as NSString
        let boundedOffset = min(max(0, utf16Offset), nsText.length)
        var line = 0
        var lineStart = 0

        if boundedOffset > 0 {
            var searchRange = NSRange(location: 0, length: boundedOffset)
            while searchRange.length > 0 {
                let newline = nsText.rangeOfCharacter(from: .newlines, options: [], range: searchRange)
                if newline.location == NSNotFound || NSMaxRange(newline) > boundedOffset {
                    break
                }
                line += 1
                lineStart = NSMaxRange(newline)
                let nextLocation = NSMaxRange(newline)
                guard nextLocation < boundedOffset else { break }
                searchRange = NSRange(location: nextLocation, length: boundedOffset - nextLocation)
            }
        }

        self.line = line
        self.character = max(0, boundedOffset - lineStart)
    }

    func utf16Offset(in text: String) -> Int? {
        let nsText = text as NSString
        var currentLine = 0
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0

        while lineStart <= nsText.length {
            nsText.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: lineStart, length: 0)
            )

            if currentLine == line {
                let lineLimit = max(lineStart, contentsEnd)
                let offset = lineStart + max(0, character)
                return min(max(lineStart, offset), lineLimit)
            }

            guard lineEnd > lineStart else { break }
            currentLine += 1
            lineStart = lineEnd
        }

        return nil
    }
}

nonisolated struct LSPRange: Codable, Equatable, Sendable {
    let start: LSPPosition
    let end: LSPPosition

    init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }

    init(nsRange: NSRange, in text: String) {
        self.start = LSPPosition(utf16Offset: nsRange.location, in: text)
        self.end = LSPPosition(utf16Offset: NSMaxRange(nsRange), in: text)
    }

    func nsRange(in text: String) -> NSRange? {
        guard let startOffset = start.utf16Offset(in: text),
              let endOffset = end.utf16Offset(in: text),
              endOffset >= startOffset else {
            return nil
        }
        return NSRange(location: startOffset, length: endOffset - startOffset)
    }
}

nonisolated indirect enum LSPAnyValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([LSPAnyValue])
    case object([String: LSPAnyValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([LSPAnyValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: LSPAnyValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let object):
            try container.encode(object)
        }
    }
}

nonisolated struct LSPTextDocumentIdentifier: Codable, Equatable, Sendable {
    let uri: String
}

nonisolated struct LSPVersionedTextDocumentIdentifier: Codable, Equatable, Sendable {
    let uri: String
    let version: Int?
}

nonisolated struct LSPTextDocumentItem: Codable, Equatable, Sendable {
    let uri: String
    let languageId: String
    let version: Int
    let text: String
}

nonisolated struct LSPTextDocumentPositionParams: Codable, Equatable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
    let position: LSPPosition
}

nonisolated struct LSPReferenceParams: Codable, Equatable, Sendable {
    struct Context: Codable, Equatable, Sendable {
        let includeDeclaration: Bool
    }

    let textDocument: LSPTextDocumentIdentifier
    let position: LSPPosition
    let context: Context
}

nonisolated struct LSPWorkspaceSymbolParams: Codable, Equatable, Sendable {
    let query: String
}

nonisolated struct LSPWorkspaceConfigurationParams: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        let scopeUri: String?
        let section: String?
    }

    let items: [Item]
}

nonisolated struct LSPWorkspaceFolder: Codable, Equatable, Sendable {
    let uri: String
    let name: String
}

nonisolated enum LSPFileChangeType: Int, Codable, Equatable, Sendable {
    case created = 1
    case changed = 2
    case deleted = 3
}

nonisolated struct LSPFileEvent: Codable, Equatable, Sendable {
    let uri: String
    let type: LSPFileChangeType
}

nonisolated struct LSPDidChangeWatchedFilesParams: Codable, Equatable, Sendable {
    let changes: [LSPFileEvent]
}

nonisolated struct LSPSignatureHelpParams: Codable, Equatable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
    let position: LSPPosition
}

nonisolated struct LSPSelectionRangeParams: Codable, Equatable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
    let positions: [LSPPosition]
}

nonisolated struct LSPCallHierarchyPrepareParams: Codable, Equatable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
    let position: LSPPosition
}

nonisolated struct LSPCallHierarchyItemParams: Codable, Equatable, Sendable {
    let item: LSPCallHierarchyItem
}

nonisolated struct LSPCallHierarchyItem: Codable, Equatable, Sendable {
    let name: String
    let kind: Int
    let tags: [Int]?
    let detail: String?
    let uri: String
    let range: LSPRange
    let selectionRange: LSPRange
    let data: LSPAnyValue?
}

nonisolated struct LSPCallHierarchyIncomingCall: Codable, Equatable, Sendable {
    let from: LSPCallHierarchyItem
    let fromRanges: [LSPRange]
}

nonisolated struct LSPCallHierarchyOutgoingCall: Codable, Equatable, Sendable {
    let to: LSPCallHierarchyItem
    let fromRanges: [LSPRange]
}

nonisolated enum LSPCallHierarchyItemResult: Decodable, Equatable, Sendable {
    case items([LSPCallHierarchyItem])
    case none

    var items: [LSPCallHierarchyItem] {
        switch self {
        case .items(let items):
            return items
        case .none:
            return []
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else {
            self = .items(try container.decode([LSPCallHierarchyItem].self))
        }
    }
}

nonisolated enum LSPCallHierarchyIncomingCallResult: Decodable, Equatable, Sendable {
    case calls([LSPCallHierarchyIncomingCall])
    case none

    var calls: [LSPCallHierarchyIncomingCall] {
        switch self {
        case .calls(let calls):
            return calls
        case .none:
            return []
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else {
            self = .calls(try container.decode([LSPCallHierarchyIncomingCall].self))
        }
    }
}

nonisolated enum LSPCallHierarchyOutgoingCallResult: Decodable, Equatable, Sendable {
    case calls([LSPCallHierarchyOutgoingCall])
    case none

    var calls: [LSPCallHierarchyOutgoingCall] {
        switch self {
        case .calls(let calls):
            return calls
        case .none:
            return []
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else {
            self = .calls(try container.decode([LSPCallHierarchyOutgoingCall].self))
        }
    }
}

nonisolated final class LSPSelectionRange: Codable, Equatable, @unchecked Sendable {
    let range: LSPRange
    let parent: LSPSelectionRange?

    init(range: LSPRange, parent: LSPSelectionRange?) {
        self.range = range
        self.parent = parent
    }

    static func == (lhs: LSPSelectionRange, rhs: LSPSelectionRange) -> Bool {
        lhs.range == rhs.range && lhs.parent == rhs.parent
    }

    func flattenedRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var current: LSPSelectionRange? = self
        while let node = current {
            if let range = node.range.nsRange(in: text), range.length > 0 {
                ranges.append(range)
            }
            current = node.parent
        }
        return ranges
    }
}

nonisolated enum LSPSelectionRangeResult: Decodable, Equatable, Sendable {
    case ranges([LSPSelectionRange])
    case none

    var ranges: [LSPSelectionRange] {
        switch self {
        case .ranges(let ranges):
            return ranges
        case .none:
            return []
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else {
            self = .ranges(try container.decode([LSPSelectionRange].self))
        }
    }
}

nonisolated struct LSPDocumentHighlight: Codable, Equatable, Sendable {
    let range: LSPRange
    let kind: Int?
}

nonisolated enum LSPDocumentHighlightResult: Decodable, Equatable, Sendable {
    case highlights([LSPDocumentHighlight])
    case none

    var highlights: [LSPDocumentHighlight] {
        switch self {
        case .highlights(let highlights):
            return highlights
        case .none:
            return []
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else {
            self = .highlights(try container.decode([LSPDocumentHighlight].self))
        }
    }
}

nonisolated struct LSPCodeActionParams: Encodable, Equatable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
    let range: LSPRange
    let context: LSPCodeActionContext
}

nonisolated struct LSPCodeActionContext: Encodable, Equatable, Sendable {
    let diagnostics: [LSPDiagnostic]
    let only: [String]?

    init(diagnostics: [LSPDiagnostic], only: [String]? = nil) {
        self.diagnostics = diagnostics
        self.only = only
    }
}

nonisolated struct LSPFormattingOptions: Codable, Equatable, Sendable {
    let tabSize: Int
    let insertSpaces: Bool
    let trimTrailingWhitespace: Bool?
    let insertFinalNewline: Bool?
    let trimFinalNewlines: Bool?

    init(
        tabSize: Int = 4,
        insertSpaces: Bool = true,
        trimTrailingWhitespace: Bool? = nil,
        insertFinalNewline: Bool? = nil,
        trimFinalNewlines: Bool? = nil
    ) {
        self.tabSize = tabSize
        self.insertSpaces = insertSpaces
        self.trimTrailingWhitespace = trimTrailingWhitespace
        self.insertFinalNewline = insertFinalNewline
        self.trimFinalNewlines = trimFinalNewlines
    }
}

nonisolated struct LSPDocumentFormattingParams: Codable, Equatable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
    let options: LSPFormattingOptions
}

nonisolated struct LSPDocumentRangeFormattingParams: Codable, Equatable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
    let range: LSPRange
    let options: LSPFormattingOptions
}

nonisolated struct LSPFoldingRangeParams: Codable, Equatable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
}

nonisolated struct LSPFoldingRange: Codable, Equatable, Sendable {
    let startLine: Int
    let startCharacter: Int?
    let endLine: Int
    let endCharacter: Int?
    let kind: String?

    init(startLine: Int, startCharacter: Int? = nil, endLine: Int, endCharacter: Int? = nil, kind: String? = nil) {
        self.startLine = startLine
        self.startCharacter = startCharacter
        self.endLine = endLine
        self.endCharacter = endCharacter
        self.kind = kind
    }
}

nonisolated enum LSPFoldingRangeResult: Decodable, Equatable, Sendable {
    case ranges([LSPFoldingRange])
    case none

    var ranges: [LSPFoldingRange] {
        switch self {
        case .ranges(let ranges):
            return ranges
        case .none:
            return []
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else {
            self = .ranges(try container.decode([LSPFoldingRange].self))
        }
    }
}

nonisolated struct LSPRenameParams: Codable, Equatable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
    let position: LSPPosition
    let newName: String
}

nonisolated enum LSPPrepareRenameResult: Decodable, Equatable, Sendable {
    case none
    case range(LSPRange)
    case placeholder(range: LSPRange, placeholder: String?)

    var range: LSPRange? {
        switch self {
        case .none:
            return nil
        case .range(let range):
            return range
        case .placeholder(let range, _):
            return range
        }
    }

    var placeholder: String? {
        switch self {
        case .none, .range:
            return nil
        case .placeholder(_, let placeholder):
            return placeholder
        }
    }

    private struct PlaceholderPayload: Decodable {
        let range: LSPRange
        let placeholder: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else if let payload = try? container.decode(PlaceholderPayload.self) {
            self = .placeholder(range: payload.range, placeholder: payload.placeholder)
        } else {
            self = .range(try container.decode(LSPRange.self))
        }
    }
}

nonisolated struct LSPDidOpenTextDocumentParams: Codable, Equatable, Sendable {
    let textDocument: LSPTextDocumentItem
}

nonisolated struct LSPTextDocumentContentChangeEvent: Codable, Equatable, Sendable {
    let text: String
}

nonisolated struct LSPDidChangeTextDocumentParams: Codable, Equatable, Sendable {
    let textDocument: LSPVersionedTextDocumentIdentifier
    let contentChanges: [LSPTextDocumentContentChangeEvent]
}

nonisolated struct LSPDidCloseTextDocumentParams: Codable, Equatable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
}

nonisolated struct LSPWillSaveTextDocumentParams: Codable, Equatable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
    let reason: Int
}

nonisolated struct LSPDidSaveTextDocumentParams: Codable, Equatable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
    let text: String?
}

nonisolated struct LSPHover: Codable, Equatable, Sendable {
    let contents: LSPHoverContent
    let range: LSPRange?
}

nonisolated struct LSPSignatureHelp: Codable, Equatable, Sendable {
    let signatures: [LSPSignatureInformation]
    let activeSignature: Int?
    let activeParameter: Int?
}

nonisolated struct LSPSignatureInformation: Codable, Equatable, Sendable {
    let label: String
    let documentation: LSPHoverContent?
    let parameters: [LSPParameterInformation]?
    let activeParameter: Int?
}

nonisolated struct LSPParameterInformation: Codable, Equatable, Sendable {
    let label: LSPParameterLabel
    let documentation: LSPHoverContent?
}

nonisolated enum LSPParameterLabel: Codable, Equatable, Sendable {
    case string(String)
    case range(Int, Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        let values = try container.decode([Int].self)
        guard values.count == 2 else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Parameter label range must contain two offsets.")
        }
        self = .range(values[0], values[1])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .range(let start, let end):
            try container.encode([start, end])
        }
    }

    func text(in signatureLabel: String) -> String {
        switch self {
        case .string(let value):
            return value
        case .range(let start, let end):
            let nsLabel = signatureLabel as NSString
            let safeStart = min(max(0, start), nsLabel.length)
            let safeEnd = min(max(safeStart, end), nsLabel.length)
            return nsLabel.substring(with: NSRange(location: safeStart, length: safeEnd - safeStart))
        }
    }
}

nonisolated enum LSPHoverContent: Codable, Equatable, Sendable {
    case markedString(LSPMarkedString)
    case markedStrings([LSPMarkedString])

    var plainText: String {
        switch self {
        case .markedString(let value):
            return value.plainText
        case .markedStrings(let values):
            return values.map(\.plainText)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
        }
    }

    init(from decoder: Decoder) throws {
        if let values = try? decoder.singleValueContainer().decode([LSPMarkedString].self) {
            self = .markedStrings(values)
            return
        }
        self = .markedString(try LSPMarkedString(from: decoder))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .markedString(let value):
            try value.encode(to: encoder)
        case .markedStrings(let values):
            var container = encoder.singleValueContainer()
            try container.encode(values)
        }
    }
}

nonisolated enum LSPMarkedString: Codable, Equatable, Sendable {
    case string(String)
    case markdown(String)
    case languageString(language: String, value: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case language
        case value
    }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            self = .string(value)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind)
        if kind == "markdown" {
            self = .markdown(try container.decode(String.self, forKey: .value))
            return
        }

        self = .languageString(
            language: try container.decodeIfPresent(String.self, forKey: .language) ?? "",
            value: try container.decode(String.self, forKey: .value)
        )
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .markdown(let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("markdown", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .languageString(let language, let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(language, forKey: .language)
            try container.encode(value, forKey: .value)
        }
    }

    var plainText: String {
        switch self {
        case .string(let value), .markdown(let value):
            return value
        case .languageString(let language, let value):
            guard !language.isEmpty else { return value }
            return "```\(language)\n\(value)\n```"
        }
    }
}

nonisolated struct LSPLocation: Codable, Equatable, Sendable {
    let uri: String
    let range: LSPRange
}

nonisolated struct LSPTextEdit: Codable, Equatable, Sendable {
    let range: LSPRange
    let newText: String
}

nonisolated struct LSPTextDocumentEdit: Codable, Equatable, Sendable {
    let textDocument: LSPVersionedTextDocumentIdentifier
    let edits: [LSPTextEdit]
}

nonisolated enum LSPWorkspaceResourceOperationKind: String, Codable, Equatable, Sendable {
    case create
    case rename
    case delete
}

nonisolated struct LSPWorkspaceResourceOperationOptions: Codable, Equatable, Sendable {
    let overwrite: Bool?
    let ignoreIfExists: Bool?
    let recursive: Bool?
    let ignoreIfNotExists: Bool?

    init(
        overwrite: Bool? = nil,
        ignoreIfExists: Bool? = nil,
        recursive: Bool? = nil,
        ignoreIfNotExists: Bool? = nil
    ) {
        self.overwrite = overwrite
        self.ignoreIfExists = ignoreIfExists
        self.recursive = recursive
        self.ignoreIfNotExists = ignoreIfNotExists
    }
}

nonisolated struct LSPWorkspaceResourceOperation: Codable, Equatable, Sendable {
    let kind: LSPWorkspaceResourceOperationKind
    let uri: String?
    let oldUri: String?
    let newUri: String?
    let options: LSPWorkspaceResourceOperationOptions?

    init(
        kind: LSPWorkspaceResourceOperationKind,
        uri: String? = nil,
        oldUri: String? = nil,
        newUri: String? = nil,
        options: LSPWorkspaceResourceOperationOptions? = nil
    ) {
        self.kind = kind
        self.uri = uri
        self.oldUri = oldUri
        self.newUri = newUri
        self.options = options
    }
}

nonisolated struct LSPWorkspaceEdit: Codable, Equatable, Sendable {
    let changes: [String: [LSPTextEdit]]
    let documentChanges: [LSPTextDocumentEdit]
    let resourceOperations: [LSPWorkspaceResourceOperation]

    var textEditChanges: [String: [LSPTextEdit]] {
        var result = changes
        for documentChange in documentChanges {
            result[documentChange.textDocument.uri, default: []].append(contentsOf: documentChange.edits)
        }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case changes
        case documentChanges
    }

    init(
        changes: [String: [LSPTextEdit]] = [:],
        documentChanges: [LSPTextDocumentEdit] = [],
        resourceOperations: [LSPWorkspaceResourceOperation] = []
    ) {
        self.changes = changes
        self.documentChanges = documentChanges
        self.resourceOperations = resourceOperations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        changes = try container.decodeIfPresent([String: [LSPTextEdit]].self, forKey: .changes) ?? [:]
        let decodedDocumentChanges = try container.decodeDocumentChangesIfPresent(forKey: .documentChanges)
        documentChanges = decodedDocumentChanges.textEdits
        resourceOperations = decodedDocumentChanges.resourceOperations
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !changes.isEmpty {
            try container.encode(changes, forKey: .changes)
        }
        if !documentChanges.isEmpty || !resourceOperations.isEmpty {
            var nested = container.nestedUnkeyedContainer(forKey: .documentChanges)
            for documentChange in documentChanges {
                try nested.encode(documentChange)
            }
            for operation in resourceOperations {
                try nested.encode(operation)
            }
        }
    }
}

nonisolated struct LSPCommand: Codable, Equatable, Sendable {
    let title: String
    let command: String
    let arguments: [LSPAnyValue]?

    init(title: String, command: String, arguments: [LSPAnyValue]? = nil) {
        self.title = title
        self.command = command
        self.arguments = arguments
    }
}

nonisolated struct LSPExecuteCommandProvider: Codable, Equatable, Sendable {
    let commands: [String]
}

nonisolated struct LSPExecuteCommandParams: Encodable, Equatable, Sendable {
    let command: String
    let arguments: [LSPAnyValue]?
}

nonisolated struct LSPApplyWorkspaceEditParams: Decodable, Equatable, Sendable {
    let label: String?
    let edit: LSPWorkspaceEdit
}

nonisolated struct LSPApplyWorkspaceEditResponse: Codable, Equatable, Sendable {
    let applied: Bool
    let failureReason: String?

    init(applied: Bool, failureReason: String? = nil) {
        self.applied = applied
        self.failureReason = failureReason
    }
}

nonisolated struct LSPCodeAction: Codable, Equatable, Sendable {
    let title: String
    let kind: String?
    let diagnostics: [LSPDiagnostic]?
    let isPreferred: Bool?
    let edit: LSPWorkspaceEdit?
    let command: LSPCommand?
    let data: LSPAnyValue?

    private enum CodingKeys: String, CodingKey {
        case title
        case kind
        case diagnostics
        case isPreferred
        case edit
        case command
        case arguments
        case data
    }

    init(
        title: String,
        kind: String? = nil,
        diagnostics: [LSPDiagnostic]? = nil,
        isPreferred: Bool? = nil,
        edit: LSPWorkspaceEdit? = nil,
        command: LSPCommand? = nil,
        data: LSPAnyValue? = nil
    ) {
        self.title = title
        self.kind = kind
        self.diagnostics = diagnostics
        self.isPreferred = isPreferred
        self.edit = edit
        self.command = command
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        diagnostics = try container.decodeIfPresent([LSPDiagnostic].self, forKey: .diagnostics)
        isPreferred = try container.decodeIfPresent(Bool.self, forKey: .isPreferred)
        edit = try container.decodeIfPresent(LSPWorkspaceEdit.self, forKey: .edit)
        if let nestedCommand = try? container.decodeIfPresent(LSPCommand.self, forKey: .command) {
            command = nestedCommand
        } else if let commandID = try container.decodeIfPresent(String.self, forKey: .command) {
            command = LSPCommand(
                title: title,
                command: commandID,
                arguments: try container.decodeIfPresent([LSPAnyValue].self, forKey: .arguments)
            )
        } else {
            command = nil
        }
        data = try container.decodeIfPresent(LSPAnyValue.self, forKey: .data)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(diagnostics, forKey: .diagnostics)
        try container.encodeIfPresent(isPreferred, forKey: .isPreferred)
        try container.encodeIfPresent(edit, forKey: .edit)
        try container.encodeIfPresent(command, forKey: .command)
        try container.encodeIfPresent(data, forKey: .data)
    }
}

nonisolated enum LSPCodeActionResult: Decodable, Equatable, Sendable {
    case actions([LSPCodeAction])
    case none

    var actions: [LSPCodeAction] {
        switch self {
        case .actions(let actions):
            return actions
        case .none:
            return []
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else {
            self = .actions(try container.decode([LSPCodeAction].self))
        }
    }
}

private extension KeyedDecodingContainer {
    nonisolated func decodeDocumentChangesIfPresent(
        forKey key: Key
    ) throws -> (textEdits: [LSPTextDocumentEdit], resourceOperations: [LSPWorkspaceResourceOperation]) {
        guard contains(key) else { return ([], []) }
        var nested = try nestedUnkeyedContainer(forKey: key)
        var textEdits: [LSPTextDocumentEdit] = []
        var resourceOperations: [LSPWorkspaceResourceOperation] = []
        while !nested.isAtEnd {
            if let edit = try? nested.decode(LSPTextDocumentEdit.self) {
                textEdits.append(edit)
            } else if let operation = try? nested.decode(LSPWorkspaceResourceOperation.self) {
                resourceOperations.append(operation)
            } else {
                _ = try nested.decode(LSPIgnoredDocumentChange.self)
            }
        }
        return (textEdits, resourceOperations)
    }
}

nonisolated private struct LSPIgnoredDocumentChange: Decodable {
    init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            while !container.isAtEnd {
                _ = try container.decode(LSPIgnoredDocumentChange.self)
            }
            return
        }
        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            for key in container.allKeys {
                _ = try container.decode(LSPIgnoredDocumentChange.self, forKey: key)
            }
            return
        }
        _ = try? decoder.singleValueContainer().decode(String.self)
        _ = try? decoder.singleValueContainer().decode(Double.self)
        _ = try? decoder.singleValueContainer().decode(Bool.self)
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

nonisolated enum LSPTextEditResult: Decodable, Equatable, Sendable {
    case edits([LSPTextEdit])
    case none

    var edits: [LSPTextEdit] {
        switch self {
        case .edits(let edits):
            return edits
        case .none:
            return []
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else {
            self = .edits(try container.decode([LSPTextEdit].self))
        }
    }
}

nonisolated struct LSPDiagnostic: Codable, Equatable, Sendable {
    let range: LSPRange
    let severity: Int?
    let code: LSPDiagnosticCode?
    let source: String?
    let message: String
}

nonisolated enum LSPDiagnosticCode: Codable, Equatable, Sendable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }
}

nonisolated struct LSPPublishDiagnosticsParams: Codable, Equatable, Sendable {
    let uri: String
    let diagnostics: [LSPDiagnostic]
}

nonisolated struct LSPInlayHintParams: Codable, Equatable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
    let range: LSPRange
}

nonisolated struct LSPInlayHint: Codable, Equatable, Sendable {
    let position: LSPPosition
    let label: LSPInlayHintLabel
    let kind: Int?
    let tooltip: LSPMarkedString?
    let textEdits: [LSPTextEdit]?
    let paddingLeft: Bool?
    let paddingRight: Bool?
    let data: LSPAnyValue?

    private enum CodingKeys: String, CodingKey {
        case position
        case label
        case kind
        case tooltip
        case textEdits
        case paddingLeft
        case paddingRight
        case data
    }

    init(
        position: LSPPosition,
        label: LSPInlayHintLabel,
        kind: Int? = nil,
        tooltip: LSPMarkedString? = nil,
        textEdits: [LSPTextEdit]? = nil,
        paddingLeft: Bool? = nil,
        paddingRight: Bool? = nil,
        data: LSPAnyValue? = nil
    ) {
        self.position = position
        self.label = label
        self.kind = kind
        self.tooltip = tooltip
        self.textEdits = textEdits
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
        self.data = data
    }

    var tooltipText: String? {
        if let tooltip = tooltip?.plainText.trimmingCharacters(in: .whitespacesAndNewlines),
           !tooltip.isEmpty {
            return tooltip
        }
        let partTooltips = label.partTooltips
        guard !partTooltips.isEmpty else { return nil }
        return partTooltips.joined(separator: "\n\n")
    }
}

nonisolated enum LSPInlayHintLabel: Codable, Equatable, Sendable {
    case string(String)
    case parts([LSPInlayHintLabelPart])

    var plainText: String {
        switch self {
        case .string(let value):
            return value
        case .parts(let parts):
            return parts.map(\.value).joined()
        }
    }

    var partTooltips: [String] {
        switch self {
        case .string:
            return []
        case .parts(let parts):
            return parts.compactMap { part in
                let text = part.tooltip?.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                return text?.isEmpty == false ? text : nil
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .parts(try container.decode([LSPInlayHintLabelPart].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

nonisolated struct LSPInlayHintLabelPart: Codable, Equatable, Sendable {
    let value: String
    let tooltip: LSPMarkedString?
    let location: LSPLocation?
    let command: LSPCommand?

    init(value: String, tooltip: LSPMarkedString? = nil, location: LSPLocation? = nil, command: LSPCommand? = nil) {
        self.value = value
        self.tooltip = tooltip
        self.location = location
        self.command = command
    }
}

nonisolated enum LSPInlayHintResult: Decodable, Equatable, Sendable {
    case hints([LSPInlayHint])
    case none

    var hints: [LSPInlayHint] {
        switch self {
        case .hints(let hints):
            return hints
        case .none:
            return []
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else {
            self = .hints(try container.decode([LSPInlayHint].self))
        }
    }
}

nonisolated struct LSPCompletionItem: Codable, Equatable, Sendable {
    let label: String
    let kind: Int?
    let detail: String?
    let documentation: LSPMarkedString?
    let insertText: String?
    let insertTextFormat: Int?
    let textEdit: LSPCompletionTextEdit?
    let additionalTextEdits: [LSPTextEdit]?
    let sortText: String?
    let filterText: String?
    let data: LSPAnyValue?

    init(
        label: String,
        kind: Int? = nil,
        detail: String? = nil,
        documentation: LSPMarkedString? = nil,
        insertText: String? = nil,
        insertTextFormat: Int? = nil,
        textEdit: LSPCompletionTextEdit? = nil,
        additionalTextEdits: [LSPTextEdit]? = nil,
        sortText: String? = nil,
        filterText: String? = nil,
        data: LSPAnyValue? = nil
    ) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.documentation = documentation
        self.insertText = insertText
        self.insertTextFormat = insertTextFormat
        self.textEdit = textEdit
        self.additionalTextEdits = additionalTextEdits
        self.sortText = sortText
        self.filterText = filterText
        self.data = data
    }
}

nonisolated enum LSPCompletionTextEdit: Codable, Equatable, Sendable {
    case textEdit(LSPTextEdit)
    case insertReplace(LSPInsertReplaceEdit)

    var newText: String {
        switch self {
        case .textEdit(let edit):
            return edit.newText
        case .insertReplace(let edit):
            return edit.newText
        }
    }

    var replacementEdit: LSPTextEdit {
        switch self {
        case .textEdit(let edit):
            return edit
        case .insertReplace(let edit):
            return LSPTextEdit(range: edit.replace, newText: edit.newText)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let edit = try? container.decode(LSPTextEdit.self) {
            self = .textEdit(edit)
        } else {
            self = .insertReplace(try container.decode(LSPInsertReplaceEdit.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .textEdit(let edit):
            try container.encode(edit)
        case .insertReplace(let edit):
            try container.encode(edit)
        }
    }
}

nonisolated struct LSPInsertReplaceEdit: Codable, Equatable, Sendable {
    let newText: String
    let insert: LSPRange
    let replace: LSPRange
}

nonisolated struct LSPCompletionList: Codable, Equatable, Sendable {
    let isIncomplete: Bool
    let items: [LSPCompletionItem]
}

nonisolated enum LSPCompletionResult: Decodable, Equatable, Sendable {
    case items([LSPCompletionItem])
    case list(LSPCompletionList)
    case none

    var items: [LSPCompletionItem] {
        switch self {
        case .items(let items):
            return items
        case .list(let list):
            return list.items
        case .none:
            return []
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else if let items = try? container.decode([LSPCompletionItem].self) {
            self = .items(items)
        } else {
            self = .list(try container.decode(LSPCompletionList.self))
        }
    }
}

nonisolated struct LSPSemanticTokensParams: Codable, Equatable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
}

nonisolated struct LSPSemanticTokens: Codable, Equatable, Sendable {
    let resultId: String?
    let data: [Int]
}

nonisolated struct LSPSemanticTokensLegend: Codable, Equatable, Sendable {
    let tokenTypes: [String]
    let tokenModifiers: [String]
}

nonisolated struct LSPDocumentSymbol: Codable, Equatable, Sendable {
    let name: String
    let detail: String?
    let kind: Int
    let range: LSPRange
    let selectionRange: LSPRange
    let children: [LSPDocumentSymbol]?
}

nonisolated struct LSPDocumentLinkParams: Codable, Equatable, Sendable {
    let textDocument: LSPTextDocumentIdentifier
}

nonisolated struct LSPDocumentLink: Codable, Equatable, Sendable {
    let range: LSPRange
    let target: String?
    let tooltip: String?
    let data: LSPAnyValue?

    init(range: LSPRange, target: String? = nil, tooltip: String? = nil, data: LSPAnyValue? = nil) {
        self.range = range
        self.target = target
        self.tooltip = tooltip
        self.data = data
    }

    var targetURL: URL? {
        guard let target,
              let url = URL(string: target),
              let scheme = url.scheme?.lowercased(),
              ["file", "http", "https"].contains(scheme) else {
            return nil
        }
        return url
    }
}

nonisolated enum LSPDocumentLinkResult: Decodable, Equatable, Sendable {
    case links([LSPDocumentLink])
    case none

    var links: [LSPDocumentLink] {
        switch self {
        case .links(let links):
            return links
        case .none:
            return []
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else {
            self = .links(try container.decode([LSPDocumentLink].self))
        }
    }
}

nonisolated struct LSPSymbolInformation: Codable, Equatable, Sendable {
    let name: String
    let kind: Int
    let location: LSPLocation
    let containerName: String?
}

nonisolated enum LSPDocumentSymbolResult: Decodable, Equatable, Sendable {
    case documentSymbols([LSPDocumentSymbol])
    case symbolInformation([LSPSymbolInformation])
    case none

    var documentSymbols: [LSPDocumentSymbol] {
        switch self {
        case .documentSymbols(let symbols):
            return symbols
        case .symbolInformation(let symbols):
            return symbols.map { symbol in
                LSPDocumentSymbol(
                    name: symbol.name,
                    detail: symbol.containerName,
                    kind: symbol.kind,
                    range: symbol.location.range,
                    selectionRange: symbol.location.range,
                    children: nil
                )
            }
        case .none:
            return []
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else if let symbols = try? container.decode([LSPDocumentSymbol].self) {
            self = .documentSymbols(symbols)
        } else {
            self = .symbolInformation(try container.decode([LSPSymbolInformation].self))
        }
    }
}

nonisolated struct LSPWorkspaceSymbol: Codable, Equatable, Sendable {
    let name: String
    let kind: Int
    let location: LSPLocation
    let containerName: String?
}

nonisolated enum LSPWorkspaceSymbolResult: Decodable, Equatable, Sendable {
    case symbols([LSPWorkspaceSymbol])
    case none

    var symbols: [LSPWorkspaceSymbol] {
        switch self {
        case .symbols(let symbols):
            return symbols
        case .none:
            return []
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else {
            self = .symbols(try container.decode([LSPWorkspaceSymbol].self))
        }
    }
}

nonisolated struct LSPRequestEnvelope<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Params
}

nonisolated struct LSPNotificationEnvelope<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: Params
}

nonisolated struct LSPResponseEnvelope<Result: Decodable>: Decodable {
    let jsonrpc: String
    let id: Int?
    let result: Result?
    let error: LSPResponseError?
}

nonisolated struct LSPResultResponseEnvelope<Result: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let result: Result
}

nonisolated struct LSPResponseError: Decodable, Equatable, Sendable, Error {
    let code: Int
    let message: String
}

nonisolated enum LSPMessageFramer {
    private static let separator = "\r\n\r\n".data(using: .utf8)!

    static func frame(payload: Data) -> Data {
        var data = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
        data.append(payload)
        return data
    }

    static func encodeMessage<T: Encodable>(_ message: T, encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        frame(payload: try encoder.encode(message))
    }

    static func extractMessages(from buffer: inout Data) -> [Data] {
        var messages: [Data] = []

        while let headerRange = buffer.range(of: separator) {
            let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
            guard let header = String(data: headerData, encoding: .utf8),
                  let length = contentLength(from: header) else {
                buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
                continue
            }

            let payloadStart = headerRange.upperBound
            let payloadEnd = payloadStart + length
            guard buffer.count >= payloadEnd else { break }

            messages.append(buffer.subdata(in: payloadStart..<payloadEnd))
            buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        }

        return messages
    }

    private static func contentLength(from header: String) -> Int? {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].caseInsensitiveCompare("Content-Length") == .orderedSame {
                return Int(parts[1])
            }
        }
        return nil
    }
}

extension Language {
    nonisolated var lspLanguageID: String? {
        switch self {
        case .go:
            return "go"
        case .swift:
            return "swift"
        case .typescript:
            return "typescript"
        case .javascript:
            return "javascript"
        default:
            return nil
        }
    }
}
