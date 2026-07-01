//
//  EditorLanguageService.swift
//  WillDeep
//
//  First-stage IDE language service configuration for source editors.
//

import Foundation

nonisolated enum EditorLanguageServiceCapability: String, CaseIterable, Sendable {
    case diagnostics
    case hover
    case declaration
    case definition
    case typeDefinition
    case implementation
    case workspaceSymbols
    case documentSymbols
    case documentLinks
    case completion
    case semanticTokens
    case inlayHints
    case formatting
    case rename
    case prepareRename
    case foldingRanges
    case signatureHelp
    case codeActions
    case documentHighlights
    case selectionRanges
    case callHierarchy
}

nonisolated struct EditorLanguageServerConfiguration: Equatable, Sendable {
    let id: String
    let displayName: String
    let languages: Set<Language>
    let executableCandidates: [String]
    let arguments: [String]
    let workspaceMarkers: [String]
    let capabilities: Set<EditorLanguageServiceCapability>
    let installHint: String

    func supports(_ language: Language?) -> Bool {
        guard let language else { return false }
        return languages.contains(language)
    }

    func commandLine(preferredExecutable: String? = nil) -> [String] {
        let executable = preferredExecutable ?? executableCandidates.first ?? id
        return [executable] + arguments
    }
}

nonisolated struct EditorDefinitionRequest: Equatable, Sendable {
    let symbol: String
    let characterOffset: Int
}

nonisolated struct EditorDeclarationRequest: Equatable, Sendable {
    let symbol: String
    let characterOffset: Int
}

nonisolated struct EditorTypeDefinitionRequest: Equatable, Sendable {
    let symbol: String
    let characterOffset: Int
}

nonisolated struct EditorImplementationRequest: Equatable, Sendable {
    let symbol: String
    let characterOffset: Int
}

nonisolated struct EditorReferenceRequest: Equatable, Sendable {
    let symbol: String
    let characterOffset: Int
}

nonisolated struct EditorRenameRequest: Equatable, Sendable {
    let symbol: String
    let characterOffset: Int
}

nonisolated struct EditorPreparedRename: Equatable, Sendable {
    let range: NSRange?
    let placeholder: String?
}

nonisolated struct EditorSelectionRangeRequest: Equatable, Sendable {
    let characterOffset: Int
    let currentRange: NSRange
}

nonisolated struct EditorInlayHintSpan: Identifiable, Equatable, Sendable {
    let id: String
    let location: Int
    let label: String
    let kind: Int?
    let tooltip: String?

    init(location: Int, label: String, kind: Int?, tooltip: String? = nil) {
        self.id = "\(location)-\(kind ?? 0)-\(label)"
        self.location = location
        self.label = label
        self.kind = kind
        self.tooltip = tooltip
    }

    init?(hint: LSPInlayHint, in text: String) {
        let label = hint.label.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty,
              let offset = hint.position.utf16Offset(in: text) else {
            return nil
        }
        self.init(location: offset, label: label, kind: hint.kind, tooltip: hint.tooltipText)
    }
}

nonisolated struct EditorDocumentLinkSpan: Identifiable, Equatable, Sendable {
    let id: String
    let range: NSRange
    let target: URL?
    let tooltip: String?
    let lspLink: LSPDocumentLink

    init(range: NSRange, target: URL, tooltip: String?) {
        let placeholderText = String(repeating: " ", count: max(NSMaxRange(range), 0))
        self.init(
            range: range,
            target: target,
            tooltip: tooltip,
            lspLink: LSPDocumentLink(
                range: LSPRange(nsRange: range, in: placeholderText),
                target: target.absoluteString,
                tooltip: tooltip
            )
        )
    }

    init(range: NSRange, target: URL?, tooltip: String?, lspLink: LSPDocumentLink) {
        let identityTarget = target?.absoluteString ?? "unresolved"
        self.id = "\(range.location)-\(range.length)-\(identityTarget)"
        self.range = range
        self.target = target
        self.tooltip = tooltip
        self.lspLink = lspLink
    }

    init?(link: LSPDocumentLink, in text: String) {
        guard let range = link.range.nsRange(in: text),
              range.length > 0 else {
            return nil
        }
        self.init(range: range, target: link.targetURL, tooltip: link.tooltip, lspLink: link)
    }
}

nonisolated struct EditorCallHierarchyRequest: Equatable, Sendable {
    let symbol: String
    let characterOffset: Int
}

nonisolated struct EditorHoverRequest: Equatable, Sendable {
    let symbol: String
    let characterOffset: Int
}

nonisolated struct EditorHoverInfo: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let content: String
    let isLoading: Bool

    init(id: UUID = UUID(), title: String, content: String, isLoading: Bool = false) {
        self.id = id
        self.title = title
        self.content = content
        self.isLoading = isLoading
    }

    init?(request: EditorHoverRequest, hover: LSPHover?) {
        let content = hover?.contents.plainText
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else { return nil }
        self.init(title: request.symbol, content: content)
    }
}

nonisolated struct EditorCompletionRequest: Equatable, Sendable {
    let characterOffset: Int
    let replacementRange: NSRange
    let prefix: String
}

nonisolated struct EditorCompletionItem: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let detail: String?
    let documentation: String?
    let insertText: String
    let insertTextFormat: Int?
    let textEdit: LSPCompletionTextEdit?
    let additionalTextEdits: [LSPTextEdit]
    let kind: Int?
    let lspItem: LSPCompletionItem

    init(
        id: String,
        label: String,
        detail: String?,
        documentation: String?,
        insertText: String,
        insertTextFormat: Int? = nil,
        textEdit: LSPCompletionTextEdit? = nil,
        additionalTextEdits: [LSPTextEdit] = [],
        kind: Int?,
        lspItem: LSPCompletionItem? = nil
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.documentation = documentation
        self.insertText = insertText
        self.insertTextFormat = insertTextFormat
        self.textEdit = textEdit
        self.additionalTextEdits = additionalTextEdits
        self.kind = kind
        self.lspItem = lspItem ?? LSPCompletionItem(
            label: label,
            kind: kind,
            detail: detail,
            documentation: documentation.map { .string($0) },
            insertText: insertText,
            insertTextFormat: insertTextFormat,
            textEdit: textEdit,
            additionalTextEdits: additionalTextEdits
        )
    }

    init(item: LSPCompletionItem, index: Int) {
        let insertText = item.textEdit?.newText
            ?? (item.insertText?.isEmpty == false ? item.insertText! : item.label)
        self.init(
            id: "\(index)-\(item.label)-\(insertText)",
            label: item.label,
            detail: item.detail,
            documentation: item.documentation?.plainText,
            insertText: insertText,
            insertTextFormat: item.insertTextFormat,
            textEdit: item.textEdit,
            additionalTextEdits: item.additionalTextEdits ?? [],
            kind: item.kind,
            lspItem: item
        )
    }
}

nonisolated struct EditorCompletionPanelState: Identifiable, Equatable, Sendable {
    let id: UUID
    let request: EditorCompletionRequest
    let items: [EditorCompletionItem]
    let isLoading: Bool
    let message: String?

    init(
        id: UUID = UUID(),
        request: EditorCompletionRequest,
        items: [EditorCompletionItem],
        isLoading: Bool = false,
        message: String? = nil
    ) {
        self.id = id
        self.request = request
        self.items = items
        self.isLoading = isLoading
        self.message = message
    }
}

nonisolated struct EditorSignatureHelpRequest: Equatable, Sendable {
    let characterOffset: Int
}

nonisolated struct EditorRangeFormattingRequest: Equatable, Sendable {
    let range: NSRange
}

nonisolated struct EditorSignatureParameter: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let documentation: String?
    let isActive: Bool

    init(label: String, documentation: String?, isActive: Bool) {
        self.id = "\(label)-\(documentation ?? "")-\(isActive)"
        self.label = label
        self.documentation = documentation
        self.isActive = isActive
    }
}

nonisolated struct EditorSignatureHelpPanelState: Identifiable, Equatable, Sendable {
    let id: UUID
    let request: EditorSignatureHelpRequest
    let signatureLabel: String
    let documentation: String?
    let parameters: [EditorSignatureParameter]
    let isLoading: Bool
    let message: String?

    init(
        id: UUID = UUID(),
        request: EditorSignatureHelpRequest,
        signatureLabel: String = "",
        documentation: String? = nil,
        parameters: [EditorSignatureParameter] = [],
        isLoading: Bool = false,
        message: String? = nil
    ) {
        self.id = id
        self.request = request
        self.signatureLabel = signatureLabel
        self.documentation = documentation
        self.parameters = parameters
        self.isLoading = isLoading
        self.message = message
    }

    init?(request: EditorSignatureHelpRequest, signatureHelp: LSPSignatureHelp?) {
        guard let signatureHelp, !signatureHelp.signatures.isEmpty else { return nil }
        let activeSignatureIndex = min(
            max(0, signatureHelp.activeSignature ?? 0),
            signatureHelp.signatures.count - 1
        )
        let signature = signatureHelp.signatures[activeSignatureIndex]
        let activeParameterIndex = signature.activeParameter ?? signatureHelp.activeParameter ?? 0
        let parameters = (signature.parameters ?? []).enumerated().map { index, parameter in
            EditorSignatureParameter(
                label: parameter.label.text(in: signature.label),
                documentation: parameter.documentation?.plainText,
                isActive: index == activeParameterIndex
            )
        }
        self.init(
            request: request,
            signatureLabel: signature.label,
            documentation: signature.documentation?.plainText,
            parameters: parameters
        )
    }
}

nonisolated struct EditorCodeActionRequest: Equatable, Sendable {
    let characterOffset: Int
    let range: NSRange
}

nonisolated struct EditorCodeActionItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let kind: String?
    let isPreferred: Bool
    let edit: LSPWorkspaceEdit?
    let command: LSPCommand?
    let lspAction: LSPCodeAction

    init(
        id: String,
        title: String,
        kind: String?,
        isPreferred: Bool,
        edit: LSPWorkspaceEdit?,
        command: LSPCommand?,
        lspAction: LSPCodeAction? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isPreferred = isPreferred
        self.edit = edit
        self.command = command
        self.lspAction = lspAction ?? LSPCodeAction(
            title: title,
            kind: kind,
            isPreferred: isPreferred,
            edit: edit,
            command: command
        )
    }

    init(action: LSPCodeAction, index: Int) {
        self.init(
            id: "\(index)-\(action.title)-\(action.kind ?? "")-\(action.isPreferred == true)",
            title: action.title,
            kind: action.kind,
            isPreferred: action.isPreferred == true,
            edit: action.edit,
            command: action.command,
            lspAction: action
        )
    }
}

nonisolated struct EditorCodeActionPanelState: Identifiable, Equatable, Sendable {
    let id: UUID
    let request: EditorCodeActionRequest
    let items: [EditorCodeActionItem]
    let isLoading: Bool
    let message: String?

    init(
        id: UUID = UUID(),
        request: EditorCodeActionRequest,
        items: [EditorCodeActionItem],
        isLoading: Bool = false,
        message: String? = nil
    ) {
        self.id = id
        self.request = request
        self.items = items
        self.isLoading = isLoading
        self.message = message
    }
}

nonisolated struct EditorReferenceItem: Identifiable, Equatable, Sendable {
    let id: String
    let location: LSPLocation
    let fileURL: URL
    let fileName: String
    let line: Int
    let column: Int
    let preview: String

    init?(location: LSPLocation, previewText: String?) {
        guard let url = URL(string: location.uri), url.isFileURL else { return nil }
        let line = location.range.start.line + 1
        let column = location.range.start.character + 1
        self.id = "\(location.uri)-\(line)-\(column)-\(location.range.end.character)"
        self.location = location
        self.fileURL = url.standardizedFileURL
        self.fileName = url.lastPathComponent
        self.line = line
        self.column = column
        self.preview = previewText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

nonisolated struct EditorWorkspaceSymbolItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: EditorOutlineItem.Kind
    let fileURL: URL
    let fileName: String
    let line: Int
    let containerName: String?

    init?(symbol: LSPWorkspaceSymbol) {
        guard let url = URL(string: symbol.location.uri), url.isFileURL else { return nil }
        let fileURL = url.standardizedFileURL
        let line = symbol.location.range.start.line + 1
        self.id = "\(symbol.name)-\(symbol.kind)-\(fileURL.path)-\(line)-\(symbol.location.range.start.character)"
        self.name = symbol.name
        self.kind = EditorWorkspaceSymbolItem.outlineKind(for: symbol.kind)
        self.fileURL = fileURL
        self.fileName = fileURL.lastPathComponent
        self.line = line
        self.containerName = symbol.containerName
    }

    private static func outlineKind(for symbolKind: Int) -> EditorOutlineItem.Kind {
        switch symbolKind {
        case 2, 3, 4, 5, 10, 11, 22, 23:
            return .type
        case 6, 12:
            return .function
        case 7, 8, 13, 14, 20:
            return .property
        case 1:
            return .section
        default:
            return .key
        }
    }
}

nonisolated struct EditorCallHierarchyResponse: Equatable, Sendable {
    let target: LSPCallHierarchyItem?
    let incoming: [LSPCallHierarchyIncomingCall]
    let outgoing: [LSPCallHierarchyOutgoingCall]
}

nonisolated struct EditorCallHierarchyEntry: Identifiable, Equatable, Sendable {
    enum Direction: String, Sendable {
        case incoming
        case outgoing
    }

    let id: String
    let direction: Direction
    let name: String
    let detail: String?
    let fileURL: URL
    let fileName: String
    let line: Int
    let column: Int
    let preview: String

    init?(direction: Direction, item: LSPCallHierarchyItem, preview: String) {
        guard let url = URL(string: item.uri), url.isFileURL else { return nil }
        let line = item.selectionRange.start.line + 1
        let column = item.selectionRange.start.character + 1
        self.direction = direction
        self.name = item.name
        self.detail = item.detail
        self.fileURL = url.standardizedFileURL
        self.fileName = url.lastPathComponent
        self.line = line
        self.column = column
        self.preview = preview
        self.id = "\(direction.rawValue)-\(item.name)-\(url.path)-\(line)-\(column)"
    }
}

nonisolated struct EditorCallHierarchyPanelState: Identifiable, Equatable, Sendable {
    let id: UUID
    let request: EditorCallHierarchyRequest
    let incoming: [EditorCallHierarchyEntry]
    let outgoing: [EditorCallHierarchyEntry]
    let isLoading: Bool
    let message: String?

    init(
        id: UUID = UUID(),
        request: EditorCallHierarchyRequest,
        incoming: [EditorCallHierarchyEntry],
        outgoing: [EditorCallHierarchyEntry],
        isLoading: Bool = false,
        message: String? = nil
    ) {
        self.id = id
        self.request = request
        self.incoming = incoming
        self.outgoing = outgoing
        self.isLoading = isLoading
        self.message = message
    }
}

nonisolated struct EditorReferencesPanelState: Identifiable, Equatable, Sendable {
    let id: UUID
    let request: EditorReferenceRequest
    let items: [EditorReferenceItem]
    let isLoading: Bool
    let message: String?

    init(
        id: UUID = UUID(),
        request: EditorReferenceRequest,
        items: [EditorReferenceItem],
        isLoading: Bool = false,
        message: String? = nil
    ) {
        self.id = id
        self.request = request
        self.items = items
        self.isLoading = isLoading
        self.message = message
    }
}

nonisolated struct EditorTextSelectionRequest: Equatable, Sendable {
    let range: NSRange
    let revision: Int

    init(location: Int, revision: Int) {
        self.range = NSRange(location: location, length: 0)
        self.revision = revision
    }

    init(range: NSRange, revision: Int) {
        self.range = range
        self.revision = revision
    }

    var location: Int { range.location }
}

nonisolated enum EditorSelectionRangeResolver {
    static func expandedRange(from ranges: [NSRange], currentRange: NSRange, textLength: Int) -> NSRange? {
        let current = boundedRange(currentRange, textLength: textLength)
        let normalized = ranges
            .map { boundedRange($0, textLength: textLength) }
            .filter { $0.length > 0 }

        guard !normalized.isEmpty else { return nil }

        if current.length == 0 {
            return normalized.first { range in
                range.location <= current.location && current.location <= NSMaxRange(range)
            } ?? normalized.first
        }

        return normalized.first { range in
            range.location <= current.location
                && NSMaxRange(range) >= NSMaxRange(current)
                && range.length > current.length
        }
    }

    private static func boundedRange(_ range: NSRange, textLength: Int) -> NSRange {
        let lower = min(max(0, range.location), max(0, textLength))
        let upper = min(max(lower, NSMaxRange(range)), max(0, textLength))
        return NSRange(location: lower, length: upper - lower)
    }
}

nonisolated struct EditorDocumentHighlightSpan: Identifiable, Equatable, Sendable {
    let id: String
    let range: NSRange
    let kind: Int?

    init(range: NSRange, kind: Int?) {
        self.id = "\(range.location)-\(range.length)-\(kind ?? 0)"
        self.range = range
        self.kind = kind
    }

    init?(highlight: LSPDocumentHighlight, in text: String) {
        guard let range = highlight.range.nsRange(in: text), range.length > 0 else { return nil }
        self.init(range: range, kind: highlight.kind)
    }
}

nonisolated struct EditorSemanticTokenSpan: Identifiable, Equatable, Sendable {
    let id: String
    let range: NSRange
    let tokenType: String
    let tokenModifiers: Set<String>

    init(range: NSRange, tokenType: String, tokenModifiers: Set<String>) {
        self.id = "\(range.location)-\(range.length)-\(tokenType)-\(tokenModifiers.sorted().joined(separator: "."))"
        self.range = range
        self.tokenType = tokenType
        self.tokenModifiers = tokenModifiers
    }
}

nonisolated enum EditorSemanticTokenDecoder {
    static func spans(
        from tokens: LSPSemanticTokens,
        legend: LSPSemanticTokensLegend,
        text: String
    ) -> [EditorSemanticTokenSpan] {
        guard tokens.data.count >= 5 else { return [] }
        let nsText = text as NSString
        var result: [EditorSemanticTokenSpan] = []
        var line = 0
        var character = 0
        var index = 0

        while index + 4 < tokens.data.count {
            let deltaLine = tokens.data[index]
            let deltaStart = tokens.data[index + 1]
            let length = tokens.data[index + 2]
            let tokenTypeIndex = tokens.data[index + 3]
            let tokenModifierBits = tokens.data[index + 4]
            index += 5

            guard length > 0 else { continue }
            line += deltaLine
            character = deltaLine == 0 ? character + deltaStart : deltaStart
            guard tokenTypeIndex >= 0, tokenTypeIndex < legend.tokenTypes.count,
                  let location = LSPPosition(line: line, character: character).utf16Offset(in: text) else {
                continue
            }

            let safeLength = min(length, max(0, nsText.length - location))
            guard safeLength > 0 else { continue }
            result.append(EditorSemanticTokenSpan(
                range: NSRange(location: location, length: safeLength),
                tokenType: legend.tokenTypes[tokenTypeIndex],
                tokenModifiers: modifiers(from: tokenModifierBits, legend: legend)
            ))
        }

        return result
    }

    private static func modifiers(from bitset: Int, legend: LSPSemanticTokensLegend) -> Set<String> {
        guard bitset > 0 else { return [] }
        var result = Set<String>()
        for index in legend.tokenModifiers.indices where bitset & (1 << index) != 0 {
            result.insert(legend.tokenModifiers[index])
        }
        return result
    }
}

nonisolated enum EditorFoldingRangeMapper {
    static func scopeGuides(from ranges: [LSPFoldingRange]) -> [ScopeGuide] {
        let normalized = ranges.compactMap { range -> (startLine: Int, endLine: Int, column: Int)? in
            guard range.endLine > range.startLine else { return nil }
            return (
                startLine: range.startLine + 1,
                endLine: range.endLine + 1,
                column: max(0, range.startCharacter ?? 0)
            )
        }.sorted { lhs, rhs in
            if lhs.startLine == rhs.startLine {
                return lhs.endLine > rhs.endLine
            }
            return lhs.startLine < rhs.startLine
        }

        return normalized.map { current in
            let depth = normalized.filter { candidate in
                let startsBefore = candidate.startLine < current.startLine
                    || (candidate.startLine == current.startLine && candidate.endLine > current.endLine)
                return startsBefore && candidate.endLine >= current.endLine
            }.count
            return ScopeGuide(
                startLine: current.startLine,
                endLine: current.endLine,
                column: current.column,
                depth: depth
            )
        }
    }
}

nonisolated enum EditorTextEditApplier {
    static func apply(edits: [LSPTextEdit], to text: String) -> String? {
        guard !edits.isEmpty else { return text }
        let nsText = text as NSString
        let replacements: [(range: NSRange, text: String)] = edits.compactMap { edit in
            guard let range = edit.range.nsRange(in: text),
                  range.location >= 0,
                  NSMaxRange(range) <= nsText.length else {
                return nil
            }
            return (range, edit.newText)
        }
        guard replacements.count == edits.count else { return nil }

        let ascending = replacements.sorted { lhs, rhs in
            if lhs.range.location == rhs.range.location {
                return lhs.range.length < rhs.range.length
            }
            return lhs.range.location < rhs.range.location
        }
        for index in ascending.indices.dropFirst() {
            let previous = ascending[ascending.index(before: index)].range
            let current = ascending[index].range
            guard NSMaxRange(previous) <= current.location else { return nil }
        }

        var result = nsText
        for replacement in ascending.reversed() {
            result = result.replacingCharacters(in: replacement.range, with: replacement.text) as NSString
        }
        return result as String
    }
}

nonisolated enum EditorCompletionTextEditApplier {
    struct Result: Equatable, Sendable {
        let text: String
        let cursorLocation: Int
    }

    static func apply(item: EditorCompletionItem, request: EditorCompletionRequest, to text: String) -> Result? {
        let nsText = text as NSString
        guard request.replacementRange.location >= 0,
              NSMaxRange(request.replacementRange) <= nsText.length else {
            return nil
        }

        let primaryEdit = completionPrimaryEdit(item: item, request: request, text: text)
        guard let primaryRange = primaryEdit.range.nsRange(in: text),
              primaryRange.location >= 0,
              NSMaxRange(primaryRange) <= nsText.length else {
            return nil
        }

        let primaryNewText = normalizedCompletionText(primaryEdit.newText, insertTextFormat: item.insertTextFormat)
        let normalizedPrimary = LSPTextEdit(range: primaryEdit.range, newText: primaryNewText)
        let edits = item.additionalTextEdits + [normalizedPrimary]
        guard let updated = EditorTextEditApplier.apply(edits: edits, to: text) else { return nil }

        let rawCursorLocation = primaryRange.location + (primaryNewText as NSString).length
        let cursorLocation = adjustedCursorLocation(
            rawCursorLocation,
            primaryRange: primaryRange,
            additionalTextEdits: item.additionalTextEdits,
            in: text
        )
        return Result(text: updated, cursorLocation: min(max(0, cursorLocation), (updated as NSString).length))
    }

    static func normalizedCompletionText(_ text: String, insertTextFormat: Int?) -> String {
        guard insertTextFormat == 2 else { return text }
        return snippetPlainText(text)
    }

    private static func completionPrimaryEdit(
        item: EditorCompletionItem,
        request: EditorCompletionRequest,
        text: String
    ) -> LSPTextEdit {
        if let textEdit = item.textEdit {
            return textEdit.replacementEdit
        }
        return LSPTextEdit(
            range: LSPRange(nsRange: request.replacementRange, in: text),
            newText: item.insertText
        )
    }

    private static func adjustedCursorLocation(
        _ rawLocation: Int,
        primaryRange: NSRange,
        additionalTextEdits: [LSPTextEdit],
        in text: String
    ) -> Int {
        var location = rawLocation
        for edit in additionalTextEdits {
            guard let range = edit.range.nsRange(in: text),
                  NSMaxRange(range) <= primaryRange.location else {
                continue
            }
            location += (edit.newText as NSString).length - range.length
        }
        return location
    }

    private static func snippetPlainText(_ snippet: String) -> String {
        var result = ""
        var index = snippet.startIndex
        while index < snippet.endIndex {
            let character = snippet[index]
            guard character == "$" else {
                result.append(character)
                index = snippet.index(after: index)
                continue
            }

            let next = snippet.index(after: index)
            guard next < snippet.endIndex else {
                result.append(character)
                index = next
                continue
            }

            if snippet[next].isNumber {
                index = consumeDigits(in: snippet, from: next)
                continue
            }

            guard snippet[next] == "{" else {
                result.append(character)
                index = next
                continue
            }

            guard let close = matchingSnippetBrace(in: snippet, openingAt: next) else {
                result.append(character)
                index = next
                continue
            }

            let contentStart = snippet.index(after: next)
            let content = String(snippet[contentStart..<close])
            result += snippetPlaceholderPlainText(content)
            index = snippet.index(after: close)
        }
        return result
    }

    private static func snippetPlaceholderPlainText(_ content: String) -> String {
        guard let separator = content.firstIndex(of: ":") else { return "" }
        let defaultStart = content.index(after: separator)
        return snippetPlainText(String(content[defaultStart...]))
    }

    private static func consumeDigits(in text: String, from start: String.Index) -> String.Index {
        var index = start
        while index < text.endIndex, text[index].isNumber {
            index = text.index(after: index)
        }
        return index
    }

    private static func matchingSnippetBrace(in text: String, openingAt open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" {
                depth += 1
            } else if text[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

nonisolated struct EditorWorkspaceEditFileChange: Equatable, Sendable {
    let fileURL: URL
    let edits: [LSPTextEdit]
}

nonisolated enum EditorWorkspaceEditApplier {
    static func fileChanges(from edit: LSPWorkspaceEdit) -> [EditorWorkspaceEditFileChange] {
        edit.textEditChanges
            .compactMap { uri, edits -> EditorWorkspaceEditFileChange? in
                guard let url = URL(string: uri), url.isFileURL, !edits.isEmpty else { return nil }
                return EditorWorkspaceEditFileChange(fileURL: url.standardizedFileURL, edits: edits)
            }
            .sorted { lhs, rhs in
                lhs.fileURL.path.localizedCaseInsensitiveCompare(rhs.fileURL.path) == .orderedAscending
            }
    }

    static func apply(fileChange: EditorWorkspaceEditFileChange, to text: String) -> String? {
        EditorTextEditApplier.apply(edits: fileChange.edits, to: text)
    }

    static func isSafeFileURL(_ fileURL: URL, inside rootURL: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        return filePath == rootPath || filePath.hasPrefix(rootPath + "/")
    }
}

nonisolated struct EditorDiagnosticIssue: Identifiable, Equatable, Sendable {
    enum Severity: Int, Sendable {
        case error = 1
        case warning = 2
        case information = 3
        case hint = 4
    }

    let id: String
    let range: NSRange
    let line: Int
    let severity: Severity
    let message: String
    let source: String?

    init(range: NSRange, line: Int, severity: Severity, message: String, source: String?) {
        self.id = "\(line)-\(range.location)-\(range.length)-\(severity.rawValue)-\(message)"
        self.range = range
        self.line = line
        self.severity = severity
        self.message = message
        self.source = source
    }

    init?(diagnostic: LSPDiagnostic, in text: String) {
        guard let range = diagnostic.range.nsRange(in: text) else { return nil }
        self.init(
            range: range,
            line: diagnostic.range.start.line + 1,
            severity: Severity(rawValue: diagnostic.severity ?? Severity.information.rawValue) ?? .information,
            message: diagnostic.message,
            source: diagnostic.source
        )
    }
}

nonisolated enum EditorLanguageServiceRegistry {
    static let go = EditorLanguageServerConfiguration(
        id: "gopls",
        displayName: "Go Language Server",
        languages: [.go],
        executableCandidates: ["gopls"],
        arguments: [],
        workspaceMarkers: ["go.work", "go.mod"],
        capabilities: firstStageCapabilities,
        installHint: "Install gopls with `go install golang.org/x/tools/gopls@latest`."
    )

    static let typescriptJavaScript = EditorLanguageServerConfiguration(
        id: "typescript-language-server",
        displayName: "TypeScript/JavaScript Language Server",
        languages: [.typescript, .javascript],
        executableCandidates: ["typescript-language-server"],
        arguments: ["--stdio"],
        workspaceMarkers: ["package.json", "tsconfig.json", "jsconfig.json"],
        capabilities: firstStageCapabilities,
        installHint: "Install with `yarn global add typescript typescript-language-server` or configure a project-local binary."
    )

    static let swift = EditorLanguageServerConfiguration(
        id: "sourcekit-lsp",
        displayName: "SourceKit-LSP",
        languages: [.swift],
        executableCandidates: ["sourcekit-lsp"],
        arguments: [],
        workspaceMarkers: ["Package.swift", ".xcodeproj", ".xcworkspace", "compile_commands.json"],
        capabilities: firstStageCapabilities,
        installHint: "Install Xcode or a Swift toolchain that includes sourcekit-lsp."
    )

    static let all: [EditorLanguageServerConfiguration] = [
        go,
        typescriptJavaScript,
        swift
    ]

    static func configuration(for language: Language?) -> EditorLanguageServerConfiguration? {
        all.first { $0.supports(language) }
    }

    static func isFirstStageIDELanguage(_ language: Language?) -> Bool {
        configuration(for: language) != nil
    }

    static func workspaceRoot(for fileURL: URL, language: Language?, explicitRoot: URL?) -> URL {
        if let explicitRoot {
            return explicitRoot.standardizedFileURL
        }
        guard let configuration = configuration(for: language) else {
            return fileURL.deletingLastPathComponent().standardizedFileURL
        }
        return nearestWorkspaceRoot(from: fileURL, markers: configuration.workspaceMarkers)
            ?? fileURL.deletingLastPathComponent().standardizedFileURL
    }

    private static let firstStageCapabilities: Set<EditorLanguageServiceCapability> = [
        .diagnostics,
        .hover,
        .declaration,
        .definition,
        .typeDefinition,
        .implementation,
        .workspaceSymbols,
        .documentSymbols,
        .documentLinks,
        .completion,
        .semanticTokens,
        .inlayHints,
        .formatting,
        .rename,
        .prepareRename,
        .foldingRanges,
        .signatureHelp,
        .codeActions,
        .documentHighlights,
        .selectionRanges,
        .callHierarchy
    ]

    private static func nearestWorkspaceRoot(from fileURL: URL, markers: [String]) -> URL? {
        var current = fileURL.hasDirectoryPath
            ? fileURL.standardizedFileURL
            : fileURL.deletingLastPathComponent().standardizedFileURL
        let fileManager = FileManager.default

        while true {
            for marker in markers {
                if marker.hasSuffix(".xcodeproj") || marker.hasSuffix(".xcworkspace") {
                    if containsPackage(withExtension: String(marker.dropFirst()), in: current, fileManager: fileManager) {
                        return current
                    }
                } else if fileManager.fileExists(atPath: current.appendingPathComponent(marker).path) {
                    return current
                }
            }

            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    private static func containsPackage(withExtension ext: String, in directory: URL, fileManager: FileManager) -> Bool {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return false }
        return names.contains { $0.hasSuffix(ext) }
    }
}
