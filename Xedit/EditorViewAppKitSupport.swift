//
//  EditorViewAppKitSupport.swift
//  WillDeep
//
//  Created by Codex on 2026/6/16.
//

import AppKit

struct BracketPair {
    let opening: unichar
    let closing: unichar
    let isOpening: Bool

    init?(character: unichar) {
        switch character {
        case 40:
            self.opening = 40
            self.closing = 41
            self.isOpening = true
        case 41:
            self.opening = 40
            self.closing = 41
            self.isOpening = false
        case 91:
            self.opening = 91
            self.closing = 93
            self.isOpening = true
        case 93:
            self.opening = 91
            self.closing = 93
            self.isOpening = false
        case 123:
            self.opening = 123
            self.closing = 125
            self.isOpening = true
        case 125:
            self.opening = 123
            self.closing = 125
            self.isOpening = false
        default:
            return nil
        }
    }
}

final class WillDeepTextView: NSTextView {
    private enum ShortcutKeyCode {
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
    }

    var currentLineColor: NSColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.16)
    var foldedPlaceholderColor: NSColor = NSColor.secondaryLabelColor
    var foldedPlaceholderBackgroundColor: NSColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
    var showsCurrentLineHighlight = true
    var scopeGuideLanguage: Language?
    var inlayHintSpans: [EditorInlayHintSpan] = [] {
        didSet {
            guard oldValue != inlayHintSpans else { return }
            needsDisplay = true
        }
    }
    var documentLinkSpans: [EditorDocumentLinkSpan] = []
    var languageServiceFoldingGuides: [ScopeGuide] = [] {
        didSet {
            guard oldValue != languageServiceFoldingGuides else { return }
            invalidateFoldableGuidesCache()
        }
    }
    var languageServiceFoldingIsAuthoritative = false {
        didSet {
            guard oldValue != languageServiceFoldingIsAuthoritative else { return }
            invalidateFoldableGuidesCache()
        }
    }
    var syntaxHighlightingSelection: SyntaxHighlightingSelection = .automatic
    var detectedLanguage: Language?
    var onSyntaxHighlightingChange: ((SyntaxHighlightingSelection) -> Void)?
    var onAddSelectionToAgentConversation: ((AgentEditorSelectionContext) -> Void)?
    var onAskSelectionInAgentPanel: ((AgentEditorSelectionContext) -> Void)?
    var onGoToDefinition: ((EditorDefinitionRequest) -> Void)?
    var onGoToDeclaration: ((EditorDeclarationRequest) -> Void)?
    var onGoToTypeDefinition: ((EditorTypeDefinitionRequest) -> Void)?
    var onGoToImplementation: ((EditorImplementationRequest) -> Void)?
    var onFindReferences: ((EditorReferenceRequest) -> Void)?
    var onShowCallHierarchy: ((EditorCallHierarchyRequest) -> Void)?
    var onRenameSymbol: ((EditorRenameRequest) -> Void)?
    var onFormatDocument: (() -> Void)?
    var onFormatSelection: ((EditorRangeFormattingRequest) -> Void)?
    var onShowHoverInfo: ((EditorHoverRequest) -> Void)?
    var onShowCompletions: ((EditorCompletionRequest) -> Void)?
    var onShowSignatureHelp: ((EditorSignatureHelpRequest) -> Void)?
    var onShowCodeActions: ((EditorCodeActionRequest) -> Void)?
    var onExpandSelection: ((EditorSelectionRangeRequest) -> Void)?
    var onOpenDocumentLink: ((EditorDocumentLinkSpan) -> Void)?
    private var foldedGuides: Set<ScopeGuide> = []
    private var lastCurrentLineHighlightRect: NSRect?

    /// Tracks whether the layout currently reflects `foldedGuides`. While this is
    /// `true`, caret moves and chrome refreshes can skip the expensive
    /// full-document glyph/layout invalidation entirely.
    private var foldLayoutIsClean = true

    /// Earliest character offset invalidated by the last fold update. When the
    /// fold set changes we re-invalidate from min(this, new earliest fold) so
    /// content that reappears after an unfold gets re-laid-out, while content
    /// above the fold is never touched.
    private var lastFoldInvalidationStart = 0

    /// Cached result of `foldableGuides()`. Fallback guide computation re-parses
    /// the entire document via `ScopeGuideCalculator`, and the line-number ruler
    /// asks for it on every redraw, so we memoize until the text, language, or
    /// language-server folding ranges change.
    private var cachedFoldableGuides: [ScopeGuide]?
    private var cachedFoldableGuidesLanguage: Language?
    private var cachedFoldableGuidesUsedAuthoritativeLSP = false

    private enum SyntaxMenuToken {
        static let automatic = "__automatic"
        static let plainText = "__plain_text"
    }

    /// NSTextView inherits macOS writing assistance defaults, including smart
    /// quotes and text replacement. Those defaults are useful for prose but
    /// corrupt source text (for example, ASCII quotes can become curly quotes).
    /// Keep the editor byte-faithful even though syntax highlighting requires
    /// rich-text mode.
    func configureCodeEditingBehavior() {
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        smartInsertDeleteEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let request = codeActionRequest(at: event) {
            if menu.items.isEmpty == false {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: L10n.EditorContextMenu.showCodeActions, action: #selector(showCodeActions(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = request
            menu.addItem(item)
        }
        if let request = hoverRequest(at: event) {
            if menu.items.isEmpty == false {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: L10n.EditorContextMenu.showHoverInfo, action: #selector(showHoverInfo(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = request
            menu.addItem(item)
        }
        if let request = completionRequest(at: event) {
            if menu.items.isEmpty == false {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: L10n.EditorContextMenu.showCompletions, action: #selector(showCompletions(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = request
            menu.addItem(item)
        }
        if let request = signatureHelpRequest(at: event) {
            if menu.items.isEmpty == false {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: L10n.EditorContextMenu.showSignatureHelp, action: #selector(showSignatureHelp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = request
            menu.addItem(item)
        }
        if let request = definitionRequest(at: event) {
            if menu.items.isEmpty == false {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: L10n.EditorContextMenu.goToDefinition, action: #selector(goToDefinition(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = request
            menu.addItem(item)
        }
        if let request = declarationRequest(at: event) {
            let item = NSMenuItem(title: L10n.EditorContextMenu.goToDeclaration, action: #selector(goToDeclaration(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = request
            menu.addItem(item)
        }
        if let request = typeDefinitionRequest(at: event) {
            let item = NSMenuItem(title: L10n.EditorContextMenu.goToTypeDefinition, action: #selector(goToTypeDefinition(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = request
            menu.addItem(item)
        }
        if let request = implementationRequest(at: event) {
            let item = NSMenuItem(title: L10n.EditorContextMenu.goToImplementation, action: #selector(goToImplementation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = request
            menu.addItem(item)
        }
        if let request = referenceRequest(at: event) {
            if menu.items.isEmpty == false {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: L10n.EditorContextMenu.findReferences, action: #selector(findReferences(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = request
            menu.addItem(item)
        }
        if let request = callHierarchyRequest(at: event) {
            let item = NSMenuItem(title: L10n.EditorContextMenu.showCallHierarchy, action: #selector(showCallHierarchy(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = request
            menu.addItem(item)
        }
        if let request = renameRequest(at: event) {
            if menu.items.isEmpty == false {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: L10n.EditorContextMenu.renameSymbol, action: #selector(renameSymbol(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = request
            menu.addItem(item)
        }
        if supportsLanguageServerFormatting {
            if menu.items.isEmpty == false {
                menu.addItem(.separator())
            }
            if let request = rangeFormattingRequest() {
                let formatSelectionItem = NSMenuItem(title: L10n.EditorContextMenu.formatSelection, action: #selector(formatSelection(_:)), keyEquivalent: "")
                formatSelectionItem.target = self
                formatSelectionItem.representedObject = request
                menu.addItem(formatSelectionItem)
            }
            if let request = selectionRangeRequest(at: event) {
                let selectionItem = NSMenuItem(title: L10n.EditorContextMenu.expandSelection, action: #selector(expandSelection(_:)), keyEquivalent: "")
                selectionItem.target = self
                selectionItem.representedObject = request
                menu.addItem(selectionItem)
            }
            let item = NSMenuItem(title: L10n.EditorContextMenu.formatDocument, action: #selector(formatDocument(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if currentAgentSelectionContext() != nil {
            if menu.items.isEmpty == false {
                menu.addItem(.separator())
            }
            menu.addItem(agentSelectionMenuItem(
                title: L10n.AgentSelection.addToConversation,
                action: #selector(addSelectionToAgentConversation(_:))
            ))
            menu.addItem(agentSelectionMenuItem(
                title: L10n.AgentSelection.askInSidebar,
                action: #selector(askSelectionInAgentPanel(_:))
            ))
        }
        if menu.items.isEmpty == false {
            menu.addItem(.separator())
        }
        menu.addItem(syntaxHighlightingMenuItem())
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            if let link = documentLink(at: event) {
                onOpenDocumentLink?(link)
                return
            }
            if let request = definitionRequest(at: event) {
                onGoToDefinition?(request)
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// Mirrors the standard macOS plain-text editing convention: Command-left
    /// and Command-right move to the beginning and end of the current line.
    /// Route through TextKit's command dispatch rather than computing offsets
    /// ourselves so selections, writing direction, undo, and accessibility
    /// keep the native NSTextView behavior. Command-Shift extends selection.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let extendsSelection = modifiers == [.command, .shift]
        let isCommandArrow = modifiers == .command || extendsSelection

        guard isCommandArrow else {
            super.keyDown(with: event)
            return
        }

        let command: Selector?
        switch event.keyCode {
        case ShortcutKeyCode.leftArrow:
            command = extendsSelection
                ? #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:))
                : #selector(NSResponder.moveToBeginningOfLine(_:))
        case ShortcutKeyCode.rightArrow:
            command = extendsSelection
                ? #selector(NSResponder.moveToEndOfLineAndModifySelection(_:))
                : #selector(NSResponder.moveToEndOfLine(_:))
        default:
            command = nil
        }

        guard let command else {
            super.keyDown(with: event)
            return
        }
        doCommand(by: command)
    }

    /// Always paste as plain text so external rich text (HTML / RTF /
    /// styled NSAttributedString from Notes, browsers, terminals etc.)
    /// can't drag its own font, paragraph style, or background color
    /// into the editor — see the screenshot where a pasted command came
    /// in with a wildly different font size. We pull `.string` off the
    /// pasteboard ourselves and feed it through `insertText:`, which
    /// triggers the same undo / textDidChange / syntax-highlight pass
    /// as typing those characters, so everything downstream behaves
    /// identically. Fall back to `pasteAsPlainText:` if for some reason
    /// no string representation is offered.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let plain = pasteboard.string(forType: .string), !plain.isEmpty {
            insertText(plain, replacementRange: selectedRange())
            return
        }
        pasteAsPlainText(sender)
    }

    @objc private func chooseSyntaxHighlighting(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }

        switch value {
        case SyntaxMenuToken.automatic:
            onSyntaxHighlightingChange?(.automatic)
        case SyntaxMenuToken.plainText:
            onSyntaxHighlightingChange?(.plainText)
        default:
            guard let language = Language(rawValue: value) else { return }
            onSyntaxHighlightingChange?(.language(language))
        }
    }

    @objc private func addSelectionToAgentConversation(_ sender: NSMenuItem) {
        guard let context = currentAgentSelectionContext() else { return }
        onAddSelectionToAgentConversation?(context)
    }

    @objc private func askSelectionInAgentPanel(_ sender: NSMenuItem) {
        guard let context = currentAgentSelectionContext() else { return }
        onAskSelectionInAgentPanel?(context)
    }

    @objc private func goToDefinition(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? EditorDefinitionRequest else { return }
        onGoToDefinition?(request)
    }

    @objc private func goToDeclaration(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? EditorDeclarationRequest else { return }
        onGoToDeclaration?(request)
    }

    @objc private func goToTypeDefinition(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? EditorTypeDefinitionRequest else { return }
        onGoToTypeDefinition?(request)
    }

    @objc private func goToImplementation(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? EditorImplementationRequest else { return }
        onGoToImplementation?(request)
    }

    @objc private func findReferences(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? EditorReferenceRequest else { return }
        onFindReferences?(request)
    }

    @objc private func showCallHierarchy(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? EditorCallHierarchyRequest else { return }
        onShowCallHierarchy?(request)
    }

    @objc private func renameSymbol(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? EditorRenameRequest else { return }
        onRenameSymbol?(request)
    }

    @objc private func formatDocument(_ sender: NSMenuItem) {
        onFormatDocument?()
    }

    @objc private func formatSelection(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? EditorRangeFormattingRequest else { return }
        onFormatSelection?(request)
    }

    @objc private func showHoverInfo(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? EditorHoverRequest else { return }
        onShowHoverInfo?(request)
    }

    @objc private func showCompletions(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? EditorCompletionRequest else { return }
        onShowCompletions?(request)
    }

    @objc private func showSignatureHelp(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? EditorSignatureHelpRequest else { return }
        onShowSignatureHelp?(request)
    }

    @objc private func showCodeActions(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? EditorCodeActionRequest else { return }
        onShowCodeActions?(request)
    }

    @objc private func expandSelection(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? EditorSelectionRangeRequest else { return }
        onExpandSelection?(request)
    }

    private func definitionRequest(at event: NSEvent) -> EditorDefinitionRequest? {
        guard let request = symbolRequest(at: event) else { return nil }
        return EditorDefinitionRequest(symbol: request.symbol, characterOffset: request.characterOffset)
    }

    private func declarationRequest(at event: NSEvent) -> EditorDeclarationRequest? {
        guard supportsLanguageServerFormatting,
              let request = symbolRequest(at: event) else { return nil }
        return EditorDeclarationRequest(symbol: request.symbol, characterOffset: request.characterOffset)
    }

    private func typeDefinitionRequest(at event: NSEvent) -> EditorTypeDefinitionRequest? {
        guard supportsLanguageServerFormatting,
              let request = symbolRequest(at: event) else { return nil }
        return EditorTypeDefinitionRequest(symbol: request.symbol, characterOffset: request.characterOffset)
    }

    private func implementationRequest(at event: NSEvent) -> EditorImplementationRequest? {
        guard supportsLanguageServerFormatting,
              let request = symbolRequest(at: event) else { return nil }
        return EditorImplementationRequest(symbol: request.symbol, characterOffset: request.characterOffset)
    }

    private func referenceRequest(at event: NSEvent) -> EditorReferenceRequest? {
        guard let request = symbolRequest(at: event) else { return nil }
        return EditorReferenceRequest(symbol: request.symbol, characterOffset: request.characterOffset)
    }

    private func callHierarchyRequest(at event: NSEvent) -> EditorCallHierarchyRequest? {
        guard supportsLanguageServerFormatting,
              let request = symbolRequest(at: event) else { return nil }
        return EditorCallHierarchyRequest(symbol: request.symbol, characterOffset: request.characterOffset)
    }

    private func renameRequest(at event: NSEvent) -> EditorRenameRequest? {
        guard supportsLanguageServerFormatting,
              let request = symbolRequest(at: event) else { return nil }
        return EditorRenameRequest(symbol: request.symbol, characterOffset: request.characterOffset)
    }

    private func hoverRequest(at event: NSEvent) -> EditorHoverRequest? {
        guard let request = symbolRequest(at: event) else { return nil }
        return EditorHoverRequest(symbol: request.symbol, characterOffset: request.characterOffset)
    }

    private func completionRequest(at event: NSEvent) -> EditorCompletionRequest? {
        if selectedRange().length > 0 {
            let selected = selectedRange()
            let nsText = string as NSString
            guard NSMaxRange(selected) <= nsText.length else { return nil }
            let prefix = nsText.substring(with: selected)
            return EditorCompletionRequest(
                characterOffset: selected.location,
                replacementRange: selected,
                prefix: prefix
            )
        }

        let pointInView = convert(event.locationInWindow, from: nil)
        let index = characterIndex(at: pointInView) ?? selectedRange().location
        let prefixRange = completionPrefixRange(endingAt: index)
        let prefix = (string as NSString).substring(with: prefixRange)
        return EditorCompletionRequest(
            characterOffset: index,
            replacementRange: prefixRange,
            prefix: prefix
        )
    }

    private func signatureHelpRequest(at event: NSEvent) -> EditorSignatureHelpRequest? {
        let pointInView = convert(event.locationInWindow, from: nil)
        let index = characterIndex(at: pointInView) ?? selectedRange().location
        return EditorSignatureHelpRequest(characterOffset: index)
    }

    private func selectionRangeRequest(at event: NSEvent) -> EditorSelectionRangeRequest? {
        let nsText = string as NSString
        guard nsText.length > 0 else { return nil }
        let selected = selectedRange()
        if selected.length > 0, selected.location >= 0, NSMaxRange(selected) <= nsText.length {
            return EditorSelectionRangeRequest(characterOffset: selected.location, currentRange: selected)
        }

        let pointInView = convert(event.locationInWindow, from: nil)
        let index = characterIndex(at: pointInView) ?? selectedRange().location
        let bounded = min(max(0, index), nsText.length)
        return EditorSelectionRangeRequest(
            characterOffset: bounded,
            currentRange: NSRange(location: bounded, length: 0)
        )
    }

    private func rangeFormattingRequest() -> EditorRangeFormattingRequest? {
        let nsText = string as NSString
        let selected = selectedRange()
        guard selected.length > 0,
              selected.location >= 0,
              NSMaxRange(selected) <= nsText.length else {
            return nil
        }
        return EditorRangeFormattingRequest(range: selected)
    }

    private func codeActionRequest(at event: NSEvent) -> EditorCodeActionRequest? {
        guard supportsLanguageServerFormatting else { return nil }
        let nsText = string as NSString
        if selectedRange().length > 0 {
            let selected = selectedRange()
            guard selected.location >= 0, NSMaxRange(selected) <= nsText.length else { return nil }
            return EditorCodeActionRequest(characterOffset: selected.location, range: selected)
        }

        let pointInView = convert(event.locationInWindow, from: nil)
        let index = characterIndex(at: pointInView) ?? selectedRange().location
        let bounded = min(max(0, index), nsText.length)
        return EditorCodeActionRequest(characterOffset: bounded, range: NSRange(location: bounded, length: 0))
    }

    private func documentLink(at event: NSEvent) -> EditorDocumentLinkSpan? {
        guard !documentLinkSpans.isEmpty else { return nil }
        let pointInView = convert(event.locationInWindow, from: nil)
        guard let index = characterIndex(at: pointInView) else { return nil }
        return documentLinkSpans.first { NSLocationInRange(index, $0.range) }
    }

    private var supportsLanguageServerFormatting: Bool {
        EditorLanguageServiceRegistry.isFirstStageIDELanguage(detectedLanguage ?? scopeGuideLanguage)
    }

    private func symbolRequest(at event: NSEvent) -> (symbol: String, characterOffset: Int)? {
        if let selected = selectedSymbol(), !selected.isEmpty {
            return (selected, selectedRange().location)
        }
        let pointInView = convert(event.locationInWindow, from: nil)
        guard let index = characterIndex(at: pointInView) else { return nil }
        guard let symbol = symbol(at: index) else { return nil }
        return (symbol, index)
    }

    private func selectedSymbol() -> String? {
        let selected = selectedRange()
        guard selected.length > 0 else { return nil }
        let nsText = string as NSString
        guard NSMaxRange(selected) <= nsText.length else { return nil }
        let value = nsText.substring(with: selected)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\r`'\"()[]{}<>:,;"))
        return value.isEmpty ? nil : value
    }

    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        var containerPoint = point
        containerPoint.x -= textContainerOrigin.x
        containerPoint.y -= textContainerOrigin.y
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex >= 0, characterIndex < (string as NSString).length else { return nil }
        return characterIndex
    }

    private func symbol(at index: Int) -> String? {
        let nsText = string as NSString
        guard nsText.length > 0 else { return nil }
        let bounded = min(max(0, index), nsText.length - 1)
        let scalars = string.utf16.map { unichar($0) }
        guard scalars.indices.contains(bounded), Self.isSymbolCharacter(scalars[bounded]) else { return nil }

        var start = bounded
        var end = bounded
        while start > 0, Self.isSymbolCharacter(scalars[start - 1]) {
            start -= 1
        }
        while end + 1 < scalars.count, Self.isSymbolCharacter(scalars[end + 1]) {
            end += 1
        }

        let raw = nsText.substring(with: NSRange(location: start, length: end - start + 1))
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".-$"))
        return trimmed.isEmpty ? nil : trimmed
    }

    private func completionPrefixRange(endingAt index: Int) -> NSRange {
        let nsText = string as NSString
        guard nsText.length > 0 else { return NSRange(location: 0, length: 0) }
        let scalars = string.utf16.map { unichar($0) }
        let safeEnd = min(max(0, index), scalars.count)
        var start = safeEnd
        while start > 0, Self.isSymbolCharacter(scalars[start - 1]) {
            start -= 1
        }
        return NSRange(location: start, length: safeEnd - start)
    }

    private static func isSymbolCharacter(_ character: unichar) -> Bool {
        switch character {
        case 45, 46, 48...57, 65...90, 95, 97...122:
            return true
        default:
            return false
        }
    }

    private func agentSelectionMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func currentAgentSelectionContext() -> AgentEditorSelectionContext? {
        let selected = selectedRange()
        guard selected.length > 0 else { return nil }
        let nsText = string as NSString
        let boundedLocation = min(max(0, selected.location), nsText.length)
        let boundedEnd = min(max(boundedLocation, NSMaxRange(selected)), nsText.length)
        guard boundedEnd > boundedLocation else { return nil }

        let selectedText = nsText.substring(with: NSRange(
            location: boundedLocation,
            length: boundedEnd - boundedLocation
        ))
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let startLine = Self.lineNumber(for: boundedLocation, in: nsText)
        let endLine = Self.lineNumber(for: max(boundedLocation, boundedEnd - 1), in: nsText)
        return AgentEditorSelectionContext(
            text: selectedText,
            startLine: startLine,
            endLine: max(startLine, endLine)
        )
    }

    private static func lineNumber(for location: Int, in text: NSString) -> Int {
        let boundedLocation = min(max(0, location), text.length)
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        text.getLineStart(
            &lineStart,
            end: &lineEnd,
            contentsEnd: &contentsEnd,
            for: NSRange(location: boundedLocation, length: 0)
        )
        let prefix = text.substring(with: NSRange(location: 0, length: lineStart))
        return prefix.components(separatedBy: .newlines).count
    }

    private func syntaxHighlightingMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Syntax Highlighting", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Syntax Highlighting")

        let detectedName = detectedLanguage?.displayName ?? "Plain Text"
        submenu.addItem(syntaxMenuItem(
            title: "Automatic (\(detectedName))",
            representedObject: SyntaxMenuToken.automatic,
            isSelected: syntaxHighlightingSelection == .automatic
        ))
        submenu.addItem(syntaxMenuItem(
            title: "Plain Text",
            representedObject: SyntaxMenuToken.plainText,
            isSelected: syntaxHighlightingSelection == .plainText
        ))
        submenu.addItem(.separator())

        for language in Language.allCases.sorted(by: { $0.displayName < $1.displayName }) {
            submenu.addItem(syntaxMenuItem(
                title: language.displayName,
                representedObject: language.rawValue,
                isSelected: syntaxHighlightingSelection == .language(language)
            ))
        }

        item.submenu = submenu
        return item
    }

    private func syntaxMenuItem(title: String, representedObject: String, isSelected: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(chooseSyntaxHighlighting(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        item.state = isSelected ? .on : .off
        return item
    }

    override func insertNewline(_ sender: Any?) {
        let indent = Self.leadingWhitespaceBefore(location: selectedRange().location, in: string)
        insertText("\n\(indent)", replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        let selected = selectedRange()
        guard selected.length > 0 else {
            insertText("    ", replacementRange: selected)
            return
        }
        replaceSelectedLines(using: Self.indentingLines(_:))
    }

    override func insertBacktab(_ sender: Any?) {
        replaceSelectedLines(using: Self.outdentingLines(_:))
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: insertionPointRectMatchingFont(in: rect), color: color, turnedOn: flag)
    }

    private func insertionPointRectMatchingFont(in rect: NSRect) -> NSRect {
        guard let font else { return rect }

        let glyphHeight = ceil(font.ascender - font.descender)
        let targetHeight = min(rect.height, max(2, glyphHeight))
        var adjusted = rect
        adjusted.origin.y += floor((rect.height - targetHeight) / 2)
        adjusted.size.height = targetHeight
        return adjusted
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        if showsCurrentLineHighlight {
            currentLineColor.setFill()

            if let highlightRect = currentLineHighlightRect() {
                highlightRect.fill()
                lastCurrentLineHighlightRect = highlightRect
            }
        }

        drawFoldedPlaceholders(in: rect)
        drawInlayHints(in: rect)
    }

    func invalidateCurrentLineHighlight() {
        guard showsCurrentLineHighlight else {
            lastCurrentLineHighlightRect = nil
            return
        }

        let nextRect = currentLineHighlightRect()
        let dirtyRects = [lastCurrentLineHighlightRect, nextRect].compactMap { $0 }
        if dirtyRects.isEmpty {
            needsDisplay = true
        } else {
            for rect in dirtyRects {
                setNeedsDisplay(rect.insetBy(dx: 0, dy: -1))
            }
        }
        lastCurrentLineHighlightRect = nextRect
    }

    private func currentLineHighlightRect() -> NSRect? {
        if string.isEmpty {
            let lineHeight = font?.boundingRectForFont.height ?? 16
            return NSRect(
                x: 0,
                y: textContainerInset.height,
                width: bounds.width,
                height: lineHeight + 2
            )
        }

        guard let layoutManager else { return nil }

        let selectedLocation = min(selectedRange().location, max(0, string.utf16.count - 1))
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: selectedLocation)
        var lineGlyphRange = NSRange(location: 0, length: 0)
        let lineRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: &lineGlyphRange,
            withoutAdditionalLayout: true
        )

        let y = lineRect.minY + textContainerOrigin.y
        return NSRect(x: 0, y: y, width: bounds.width, height: lineRect.height)
    }

    func toggleFold(at line: Int) {
        guard let guide = foldableGuides().first(where: { $0.startLine == line }) else { return }
        if foldedGuides.contains(guide) {
            foldedGuides.remove(guide)
        } else {
            foldedGuides.insert(guide)
        }
        foldLayoutIsClean = false
        invalidateFoldedRangesCache()
        applyFoldedScopes()
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    func clearFoldedScopes() {
        guard foldedGuides.isEmpty == false else { return }
        foldedGuides.removeAll()
        foldLayoutIsClean = false
        invalidateFoldedRangesCache()
        applyFoldedScopes()
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    /// Re-applies folding layout only when it is stale. Caret moves call this on
    /// every selection change, so the common (no-op) path must avoid touching the
    /// layout manager.
    func refreshFoldedScopesIfNeeded() {
        guard foldLayoutIsClean == false else { return }
        applyFoldedScopes()
    }

    func isFolded(_ guide: ScopeGuide) -> Bool {
        foldedGuides.contains(guide)
    }

    func foldableGuides() -> [ScopeGuide] {
        if let cachedFoldableGuides,
           cachedFoldableGuidesLanguage == scopeGuideLanguage,
           cachedFoldableGuidesUsedAuthoritativeLSP == languageServiceFoldingIsAuthoritative {
            return cachedFoldableGuides
        }
        let sourceGuides = languageServiceFoldingIsAuthoritative
            ? languageServiceFoldingGuides
            : ScopeGuideCalculator.guides(in: string, language: scopeGuideLanguage)
        let guides = sourceGuides
            .filter { $0.endLine - $0.startLine >= 2 }
        cachedFoldableGuides = guides
        cachedFoldableGuidesLanguage = scopeGuideLanguage
        cachedFoldableGuidesUsedAuthoritativeLSP = languageServiceFoldingIsAuthoritative
        return guides
    }

    /// Drops the memoized fold guides so the next request re-parses the document.
    /// Called whenever the text content changes.
    func invalidateFoldableGuidesCache() {
        cachedFoldableGuides = nil
        cachedFoldableGuidesUsedAuthoritativeLSP = false
        // Folded ranges are keyed by line offsets, which shift when text changes.
        invalidateFoldedRangesCache()
    }

    func applyFoldedScopes() {
        guard let layoutManager, let textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)

        guard foldedGuides.isEmpty == false else {
            // Nothing folded: invalidate from the previously-folded region down.
            // Content above never changed, so re-laying it out is wasted work —
            // the dominant cost behind the ~1 s fold/unfold stall on large files
            // once non-contiguous layout was enabled.
            invalidateFoldLayout(from: lastFoldInvalidationStart, in: layoutManager, fullRange: fullRange)
            lastFoldInvalidationStart = 0
            foldLayoutIsClean = true
            return
        }

        var earliestHiddenStart = textStorage.length
        for guide in foldedGuides {
            guard let hiddenRange = foldedCharacterRange(for: guide), hiddenRange.length > 0 else {
                continue
            }
            layoutManager.addTemporaryAttributes(
                [.foregroundColor: NSColor.clear],
                forCharacterRange: hiddenRange
            )
            earliestHiddenStart = min(earliestHiddenStart, hiddenRange.location)
        }

        // Only invalidate from the earliest fold downward. Lines above the first
        // folded scope keep their layout, so on a large file we re-lay-out only
        // the tail (and with non-contiguous layout, only its visible part).
        let invalidateStart = min(earliestHiddenStart, lastFoldInvalidationStart)
        invalidateFoldLayout(from: invalidateStart, in: layoutManager, fullRange: fullRange)
        lastFoldInvalidationStart = earliestHiddenStart
        foldLayoutIsClean = true
        needsDisplay = true
    }

    /// Invalidate glyphs/layout from `start` to the end of the document.
    private func invalidateFoldLayout(from start: Int, in layoutManager: NSLayoutManager, fullRange: NSRange) {
        let clampedStart = max(0, min(start, fullRange.length))
        let range = NSRange(location: clampedStart, length: fullRange.length - clampedStart)
        guard range.length >= 0 else { return }
        layoutManager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
    }

    func isFoldedGlyphRange(_ glyphRange: NSRange, layoutManager: NSLayoutManager) -> Bool {
        guard foldedGuides.isEmpty == false else { return false }
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        return foldedCharacterRanges().contains { NSIntersectionRange($0, characterRange).length > 0 }
    }

    /// Folded character ranges, cached. `isFoldedGlyphRange` is called by the
    /// layout-manager delegate for *every* line fragment laid out, and each
    /// `foldedCharacterRange(for:)` does an O(file) line scan — recomputing them
    /// per fragment was O(folds × file) per layout pass and the real cause of the
    /// fold stall on larger files. The cache is rebuilt only when the fold set or
    /// text changes.
    private var cachedFoldedCharacterRanges: [NSRange]?

    private func foldedCharacterRanges() -> [NSRange] {
        if let cachedFoldedCharacterRanges {
            return cachedFoldedCharacterRanges
        }
        let ranges = foldedGuides.compactMap { foldedCharacterRange(for: $0) }
        cachedFoldedCharacterRanges = ranges
        return ranges
    }

    private func invalidateFoldedRangesCache() {
        cachedFoldedCharacterRanges = nil
    }

    private func drawFoldedPlaceholders(in rect: NSRect) {
        guard let layoutManager,
              let textContainer,
              let font,
              foldedGuides.isEmpty == false,
              string.isEmpty == false else {
            return
        }

        let columnWidth = max(1, font.advancement(forGlyph: font.glyph(withName: "space")).width)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: max(10, font.pointSize - 2), weight: .medium),
            .foregroundColor: foldedPlaceholderColor,
        ]

        for guide in foldedGuides {
            guard let lineRect = lineFragmentRect(forLine: guide.startLine, layoutManager: layoutManager, textContainer: textContainer) else { continue }
            let y = textContainerOrigin.y + lineRect.minY + max(0, (lineRect.height - font.boundingRectForFont.height) / 2)
            guard rect.maxY >= y, rect.minY <= y + lineRect.height else { continue }

            let visibleText = Self.lineText(forLine: guide.startLine, in: string)
            let x = textContainerOrigin.x + CGFloat(visibleText.count + 2) * columnWidth
            let foldedLineCount = max(1, guide.endLine - guide.startLine)
            let placeholder = "... \(foldedLineCount) lines folded" as NSString
            let size = placeholder.size(withAttributes: attributes)
            let backgroundRect = NSRect(x: x - 4, y: y + 1, width: size.width + 8, height: size.height + 2)
            foldedPlaceholderBackgroundColor.setFill()
            backgroundRect.fill()
            placeholder.draw(at: NSPoint(x: x, y: y + 2), withAttributes: attributes)
        }
    }

    private func drawInlayHints(in rect: NSRect) {
        guard let layoutManager,
              let textContainer,
              let font,
              !inlayHintSpans.isEmpty,
              !string.isEmpty else {
            return
        }

        let nsText = string as NSString
        let hintFont = NSFont.monospacedSystemFont(ofSize: max(9, font.pointSize - 3), weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: hintFont,
            .foregroundColor: foldedPlaceholderColor.withAlphaComponent(0.78),
        ]
        let backgroundColor = foldedPlaceholderBackgroundColor.withAlphaComponent(0.78)

        for hint in inlayHintSpans {
            guard hint.location >= 0, hint.location <= nsText.length else { continue }
            let point = inlayHintPoint(for: hint.location, layoutManager: layoutManager, textContainer: textContainer)
            guard point.y <= rect.maxY, point.y + hintFont.boundingRectForFont.height >= rect.minY else {
                continue
            }

            let label = " \(hint.label) " as NSString
            let size = label.size(withAttributes: attributes)
            let backgroundRect = NSRect(
                x: point.x - 1,
                y: point.y,
                width: size.width + 2,
                height: size.height + 1
            )
            backgroundColor.setFill()
            backgroundRect.fill()
            label.draw(at: NSPoint(x: point.x, y: point.y), withAttributes: attributes)
        }
    }

    private func inlayHintPoint(
        for location: Int,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSPoint {
        let nsText = string as NSString
        let bounded = min(max(0, location), nsText.length)
        let characterIndex = min(max(0, bounded), max(0, nsText.length - 1))
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        let lineRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: nil,
            withoutAdditionalLayout: true
        )
        var glyphLocation = layoutManager.location(forGlyphAt: glyphIndex)
        if bounded == nsText.length {
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                in: textContainer
            )
            glyphLocation.x = glyphRect.maxX
        }

        let y = textContainerOrigin.y + lineRect.minY + max(0, (lineRect.height - (font?.boundingRectForFont.height ?? lineRect.height)) / 2)
        return NSPoint(x: textContainerOrigin.x + glyphLocation.x, y: y + 1)
    }

    private func lineFragmentRect(
        forLine line: Int,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect? {
        let nsText = string as NSString
        guard nsText.length > 0 else { return nil }

        let characterIndex = Self.characterIndex(forLine: line, in: nsText)
        guard characterIndex < nsText.length else { return nil }

        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        var effectiveRange = NSRange(location: 0, length: 0)
        return layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: &effectiveRange,
            withoutAdditionalLayout: true
        )
    }

    private static func characterIndex(forLine targetLine: Int, in text: NSString) -> Int {
        guard targetLine > 1 else { return 0 }
        var line = 1
        var index = 0
        while index < text.length {
            if line == targetLine {
                return index
            }
            if text.character(at: index) == 10 {
                line += 1
                if line == targetLine {
                    return min(index + 1, text.length - 1)
                }
            }
            index += 1
        }
        return max(0, text.length - 1)
    }

    private func foldedCharacterRange(for guide: ScopeGuide) -> NSRange? {
        let nsText = string as NSString
        guard nsText.length > 0, guide.endLine > guide.startLine else { return nil }

        let start = Self.characterIndex(forLine: guide.startLine + 1, in: nsText)
        let endLineStart = Self.characterIndex(forLine: guide.endLine, in: nsText)
        let endLineRange = nsText.lineRange(for: NSRange(location: endLineStart, length: 0))
        let end = min(NSMaxRange(endLineRange), nsText.length)
        guard start < end else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private static func lineText(forLine targetLine: Int, in text: String) -> String {
        let nsText = text as NSString
        guard nsText.length > 0 else { return "" }
        let location = characterIndex(forLine: targetLine, in: nsText)
        let range = nsText.lineRange(for: NSRange(location: location, length: 0))
        return nsText.substring(with: range)
            .trimmingCharacters(in: .newlines)
    }

    private func replaceSelectedLines(using transform: (String) -> String) {
        let nsText = string as NSString
        let lineRange = nsText.lineRange(for: selectedRange())
        let original = nsText.substring(with: lineRange)
        let replacement = transform(original)

        guard replacement != original else { return }
        shouldChangeText(in: lineRange, replacementString: replacement)
        textStorage?.replaceCharacters(in: lineRange, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: lineRange.location, length: (replacement as NSString).length))
    }

    nonisolated static func leadingWhitespaceBefore(location: Int, in text: String) -> String {
        guard !text.isEmpty else { return "" }

        let nsText = text as NSString
        let boundedLocation = min(max(0, location), nsText.length)
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        nsText.getLineStart(
            &lineStart,
            end: &lineEnd,
            contentsEnd: &contentsEnd,
            for: NSRange(location: boundedLocation, length: 0)
        )

        let linePrefix = nsText.substring(with: NSRange(location: lineStart, length: boundedLocation - lineStart))
        return String(linePrefix.prefix { $0 == " " || $0 == "\t" })
    }

    nonisolated static func indentingLines(_ text: String) -> String {
        transformLines(text) { "    \($0)" }
    }

    nonisolated static func outdentingLines(_ text: String) -> String {
        transformLines(text) { line in
            if line.hasPrefix("\t") {
                return String(line.dropFirst())
            }
            let removableSpaces = min(line.prefix { $0 == " " }.count, 4)
            return String(line.dropFirst(removableSpaces))
        }
    }

    private nonisolated static func transformLines(_ text: String, transform: (String) -> String) -> String {
        let endsWithNewline = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if endsWithNewline {
            lines.removeLast()
        }

        let transformed = lines.map(transform).joined(separator: "\n")
        return endsWithNewline ? "\(transformed)\n" : transformed
    }
}

final class LineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?
    var settings: EditorSettings = .default
    var theme: EditorTheme = .paper
    var font: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    var changedLineNumbers: Set<Int> = []
    private var textDidChangeObserver: NSObjectProtocol?

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        textDidChangeObserver = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification,
            object: textView,
            queue: nil
        ) { [weak self] _ in
            self?.clearLineCaches()
        }
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        if let textDidChangeObserver {
            NotificationCenter.default.removeObserver(textDidChangeObserver)
        }
    }

    override var requiredThickness: CGFloat {
        let digits = max(2, String(max(1, lineCount())).count)
        let digitWidth = max(7, font.advancement(forGlyph: font.glyph(withName: "zero")).width)
        return CGFloat(digits) * digitWidth + 34
    }

    func invalidateRuleThickness() {
        ruleThickness = requiredThickness
        lastThicknessDigits = String(max(1, lineCount())).count
        scrollView?.tile()
    }

    private var lastThicknessDigits: Int = 0

    /// `true` when the gutter's digit width has actually changed since the last
    /// `invalidateRuleThickness()` (i.e. the file crossed a power-of-10 boundary
    /// in line count). Lets callers skip the expensive `tile()` re-layout when
    /// the rendered gutter wouldn't change.
    func thicknessNeedsRefresh() -> Bool {
        let digits = max(2, String(max(1, lineCount())).count)
        return digits != lastThicknessDigits
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // Clip drawing to our own bounds. NSRulerView's drawing isn't clipped
        // automatically — line-number labels whose Y falls just above the
        // ruler's top end up rendering into the tab bar above (the "line 12
        // appearing in the tab bar row" glitch).
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()

        let backgroundOpacity = settings.editorGlassEnabled ? CGFloat(settings.editorSurfaceOpacity) : 1
        theme.backgroundColor.withAlphaComponent(backgroundOpacity).setFill()
        bounds.fill()

        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        let visibleRect = textView.visibleRect
        let relativePoint = convert(NSPoint.zero, from: textView)
        let numberFont = NSFont.monospacedDigitSystemFont(
            ofSize: max(10, CGFloat(settings.fontSize) - 2),
            weight: .regular
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: theme.gutterTextColor,
            .paragraphStyle: paragraphStyle,
        ]

        if textView.string.isEmpty {
            drawLineNumber(
                1,
                y: textView.textContainerOrigin.y + relativePoint.y,
                lineHeight: numberFont.boundingRectForFont.height + 2,
                attributes: attributes,
                isCurrentLine: true
            )
            return
        }

        let foldableGuides = (textView as? WillDeepTextView)?.foldableGuides() ?? []
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        var glyphIndex = glyphRange.location
        let selectedLineGlyphRange = currentLineGlyphRange(
            layoutManager: layoutManager,
            selectedLocation: textView.selectedRange().location,
            textLength: textView.string.utf16.count
        )

        // The line number for the first visible character is computed once via a
        // full scan; every line after that is derived incrementally by counting
        // only the newlines in the gap from the previous line. This keeps the
        // ruler redraw at O(visible characters) instead of O(lines × file length),
        // which is what made scrolling large files sluggish.
        let nsString = textView.string as NSString
        var previousCharacterIndex: Int? = nil
        var lineNumber = 1

        while glyphIndex < NSMaxRange(glyphRange) {
            var lineGlyphRange = NSRange(location: 0, length: 0)
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineGlyphRange,
                withoutAdditionalLayout: true
            )
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let startsLogicalLine = Self.startsLogicalLine(characterIndex: characterIndex, in: nsString)
            if let previousCharacterIndex {
                lineNumber += Self.newlineCount(in: nsString, from: previousCharacterIndex, to: characterIndex)
            } else {
                lineNumber = self.lineNumber(at: characterIndex)
            }
            previousCharacterIndex = characterIndex
            let y = relativePoint.y + textView.textContainerOrigin.y + lineRect.minY
            let foldGuide = startsLogicalLine ? foldableGuides.first(where: { $0.startLine == lineNumber }) : nil
            let isCurrentFragment = selectedLineGlyphRange.map { NSEqualRanges($0, lineGlyphRange) } ?? false

            drawLineNumber(
                lineNumber,
                y: y,
                lineHeight: lineRect.height,
                attributes: attributes,
                drawsNumber: startsLogicalLine,
                isCurrentLine: settings.highlightsCurrentLine && isCurrentFragment,
                isChanged: startsLogicalLine && changedLineNumbers.contains(lineNumber),
                foldGuide: foldGuide,
                isFolded: foldGuide.map { (textView as? WillDeepTextView)?.isFolded($0) ?? false } ?? false
            )

            let nextGlyphIndex = NSMaxRange(lineGlyphRange)
            if nextGlyphIndex <= glyphIndex { break }
            glyphIndex = nextGlyphIndex
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x <= 18,
              let textView = textView as? WillDeepTextView,
              let line = lineNumber(atRulerY: point.y),
              textView.foldableGuides().contains(where: { $0.startLine == line }) else {
            super.mouseDown(with: event)
            return
        }

        textView.toggleFold(at: line)
    }

    private func drawLineNumber(
        _ lineNumber: Int,
        y: CGFloat,
        lineHeight: CGFloat,
        attributes: [NSAttributedString.Key: Any],
        drawsNumber: Bool = true,
        isCurrentLine: Bool,
        isChanged: Bool = false,
        foldGuide: ScopeGuide? = nil,
        isFolded: Bool = false
    ) {
        if isCurrentLine {
            theme.currentLineBackgroundColor.setFill()
            NSRect(x: 0, y: y, width: bounds.width, height: lineHeight).fill()
        }

        guard drawsNumber else { return }

        if isChanged {
            NSColor.systemBlue.withAlphaComponent(0.82).setFill()
            NSRect(x: 2, y: y + 3, width: 3, height: max(4, lineHeight - 6)).fill()
        }

        if foldGuide != nil {
            drawFoldToggle(y: y, lineHeight: lineHeight, isFolded: isFolded)
        }

        let text = "\(lineNumber)" as NSString
        let drawRect = NSRect(
            x: 18,
            y: y + max(0, (lineHeight - (attributes[.font] as? NSFont ?? font).boundingRectForFont.height) / 2),
            width: bounds.width - 26,
            height: lineHeight
        )
        text.draw(in: drawRect, withAttributes: attributes)
    }

    private func currentLineGlyphRange(
        layoutManager: NSLayoutManager,
        selectedLocation: Int,
        textLength: Int
    ) -> NSRange? {
        guard textLength > 0 else { return nil }
        let selectedCharacterIndex = min(max(0, selectedLocation), max(0, textLength - 1))
        let selectedGlyphIndex = layoutManager.glyphIndexForCharacter(at: selectedCharacterIndex)
        var selectedLineGlyphRange = NSRange(location: 0, length: 0)
        _ = layoutManager.lineFragmentRect(
            forGlyphAt: selectedGlyphIndex,
            effectiveRange: &selectedLineGlyphRange,
            withoutAdditionalLayout: true
        )
        return selectedLineGlyphRange.length > 0 ? selectedLineGlyphRange : nil
    }

    private func drawFoldToggle(y: CGFloat, lineHeight: CGFloat, isFolded: Bool) {
        let center = NSPoint(x: 10, y: y + lineHeight / 2)
        let path = NSBezierPath()

        if isFolded {
            path.move(to: NSPoint(x: center.x - 2, y: center.y - 4))
            path.line(to: NSPoint(x: center.x - 2, y: center.y + 4))
            path.line(to: NSPoint(x: center.x + 4, y: center.y))
        } else {
            path.move(to: NSPoint(x: center.x - 4, y: center.y + 2))
            path.line(to: NSPoint(x: center.x + 4, y: center.y + 2))
            path.line(to: NSPoint(x: center.x, y: center.y - 4))
        }

        path.close()
        theme.gutterTextColor.withAlphaComponent(0.82).setFill()
        path.fill()
    }

    private var cachedLineCount: Int = 1
    private var cachedLineCountForLength: Int = -1
    private var cachedLineStartOffsets: [Int] = [0]
    private var cachedLineStartOffsetsForLength: Int = -1

    private func clearLineCaches() {
        cachedLineCount = 1
        cachedLineCountForLength = -1
        cachedLineStartOffsets = [0]
        cachedLineStartOffsetsForLength = -1
    }

    private func lineCount() -> Int {
        guard let string = textView?.string, !string.isEmpty else { return 1 }
        // Cache the result keyed by string length. `lineCount()` is read on
        // every `requiredThickness` getter call and that getter ran twice per
        // EditorView.updateNSView (re-fired on every window re-activation),
        // contributing ~80/350 main-thread samples in profiling on a 348 KB
        // file. Length is a cheap O(1) proxy that changes on any edit, so the
        // cache stays correct without needing a separate invalidation token.
        let length = (string as NSString).length
        if length == cachedLineCountForLength {
            return cachedLineCount
        }
        let count = lineStartOffsets(in: string).count
        cachedLineCount = count
        cachedLineCountForLength = length
        return count
    }

    private func lineNumber(at location: Int) -> Int {
        guard let string = textView?.string, !string.isEmpty else { return 1 }
        let nsString = string as NSString
        let boundedLocation = min(max(0, location), nsString.length)
        let starts = lineStartOffsets(in: string)
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= boundedLocation {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return max(1, low)
    }

    private func lineStartOffsets(in string: String) -> [Int] {
        let nsString = string as NSString
        let length = nsString.length
        if length == cachedLineStartOffsetsForLength {
            return cachedLineStartOffsets
        }
        var starts = [0]
        starts.reserveCapacity(max(1, cachedLineCount))
        guard length > 0 else {
            cachedLineStartOffsets = starts
            cachedLineStartOffsetsForLength = length
            return starts
        }
        for index in 0..<length where nsString.character(at: index) == 10 {
            let next = index + 1
            if next < length {
                starts.append(next)
            }
        }
        cachedLineStartOffsets = starts
        cachedLineStartOffsetsForLength = length
        return starts
    }

    /// Counts newlines in the half-open character range `[from, to)`. Used to
    /// advance the visible line number incrementally instead of rescanning the
    /// document from the start for every gutter row.
    private static func newlineCount(in text: NSString, from: Int, to: Int) -> Int {
        let lower = min(max(0, from), text.length)
        let upper = min(max(lower, to), text.length)
        guard lower < upper else { return 0 }
        var count = 0
        for index in lower..<upper where text.character(at: index) == 10 {
            count += 1
        }
        return count
    }

    static func startsLogicalLine(characterIndex: Int, in text: NSString) -> Bool {
        let boundedIndex = min(max(0, characterIndex), text.length)
        return boundedIndex == 0 || text.character(at: boundedIndex - 1) == 10
    }

    private func lineNumber(atRulerY y: CGFloat) -> Int? {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return nil
        }

        let relativePoint = convert(NSPoint.zero, from: textView)
        let textPoint = NSPoint(
            x: textView.textContainerOrigin.x,
            y: y - relativePoint.y - textView.textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(for: textPoint, in: textContainer)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard Self.startsLogicalLine(characterIndex: characterIndex, in: textView.string as NSString) else {
            return nil
        }
        return lineNumber(at: characterIndex)
    }
}
