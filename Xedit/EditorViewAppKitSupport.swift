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
    var currentLineColor: NSColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.16)
    var foldedPlaceholderColor: NSColor = NSColor.secondaryLabelColor
    var foldedPlaceholderBackgroundColor: NSColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
    var showsCurrentLineHighlight = true
    var scopeGuideLanguage: Language?
    var syntaxHighlightingSelection: SyntaxHighlightingSelection = .automatic
    var detectedLanguage: Language?
    var onSyntaxHighlightingChange: ((SyntaxHighlightingSelection) -> Void)?
    var onAddSelectionToAgentConversation: ((AgentEditorSelectionContext) -> Void)?
    var onAskSelectionInAgentPanel: ((AgentEditorSelectionContext) -> Void)?
    var onGoToDefinition: ((String) -> Void)?
    private var foldedGuides: Set<ScopeGuide> = []

    /// Tracks whether the layout currently reflects `foldedGuides`. While this is
    /// `true`, caret moves and chrome refreshes can skip the expensive
    /// full-document glyph/layout invalidation entirely.
    private var foldLayoutIsClean = true

    /// Earliest character offset invalidated by the last fold update. When the
    /// fold set changes we re-invalidate from min(this, new earliest fold) so
    /// content that reappears after an unfold gets re-laid-out, while content
    /// above the fold is never touched.
    private var lastFoldInvalidationStart = 0

    /// Cached result of `foldableGuides()`. Computing it re-parses the entire
    /// document via `ScopeGuideCalculator`, and the line-number ruler asks for it
    /// on every redraw (i.e. every scroll/edit), so we memoize until the text or
    /// language changes.
    private var cachedFoldableGuides: [ScopeGuide]?
    private var cachedFoldableGuidesLanguage: Language?

    private enum SyntaxMenuToken {
        static let automatic = "__automatic"
        static let plainText = "__plain_text"
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let symbol = definitionSymbol(at: event) {
            if menu.items.isEmpty == false {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: "Go to Definition", action: #selector(goToDefinition(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = symbol
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
        if event.modifierFlags.contains(.command),
           let symbol = definitionSymbol(at: event) {
            onGoToDefinition?(symbol)
            return
        }
        super.mouseDown(with: event)
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
        guard let symbol = sender.representedObject as? String else { return }
        onGoToDefinition?(symbol)
    }

    private func definitionSymbol(at event: NSEvent) -> String? {
        if let selected = selectedSymbol(), !selected.isEmpty {
            return selected
        }
        let pointInView = convert(event.locationInWindow, from: nil)
        guard let index = characterIndex(at: pointInView) else { return nil }
        return symbol(at: index)
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

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        if showsCurrentLineHighlight {
            currentLineColor.setFill()

            if string.isEmpty {
                let lineHeight = font?.boundingRectForFont.height ?? 16
                NSRect(
                    x: 0,
                    y: textContainerInset.height,
                    width: bounds.width,
                    height: lineHeight + 2
                ).fill()
                return
            }

            guard let layoutManager = layoutManager else { return }

            let selectedLocation = min(selectedRange().location, max(0, string.utf16.count - 1))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: selectedLocation)
            var lineGlyphRange = NSRange(location: 0, length: 0)
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineGlyphRange,
                withoutAdditionalLayout: true
            )

            let y = lineRect.minY + textContainerOrigin.y
            NSRect(x: 0, y: y, width: bounds.width, height: lineRect.height).fill()
        }

        drawFoldedPlaceholders(in: rect)
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
        if let cachedFoldableGuides, cachedFoldableGuidesLanguage == scopeGuideLanguage {
            return cachedFoldableGuides
        }
        let guides = ScopeGuideCalculator.guides(in: string, language: scopeGuideLanguage)
            .filter { $0.endLine - $0.startLine >= 2 }
        cachedFoldableGuides = guides
        cachedFoldableGuidesLanguage = scopeGuideLanguage
        return guides
    }

    /// Drops the memoized fold guides so the next request re-parses the document.
    /// Called whenever the text content changes.
    func invalidateFoldableGuidesCache() {
        cachedFoldableGuides = nil
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

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
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

        let selectedLine = lineNumber(at: textView.selectedRange().location)
        let foldableGuides = (textView as? WillDeepTextView)?.foldableGuides() ?? []
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        var glyphIndex = glyphRange.location

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
            if let previousCharacterIndex {
                lineNumber += Self.newlineCount(in: nsString, from: previousCharacterIndex, to: characterIndex)
            } else {
                lineNumber = self.lineNumber(at: characterIndex)
            }
            previousCharacterIndex = characterIndex
            let y = relativePoint.y + textView.textContainerOrigin.y + lineRect.minY
            let foldGuide = foldableGuides.first(where: { $0.startLine == lineNumber })

            drawLineNumber(
                lineNumber,
                y: y,
                lineHeight: lineRect.height,
                attributes: attributes,
                isCurrentLine: settings.highlightsCurrentLine && lineNumber == selectedLine,
                isChanged: changedLineNumbers.contains(lineNumber),
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
        isCurrentLine: Bool,
        isChanged: Bool = false,
        foldGuide: ScopeGuide? = nil,
        isFolded: Bool = false
    ) {
        if isCurrentLine {
            theme.currentLineBackgroundColor.setFill()
            NSRect(x: 0, y: y, width: bounds.width, height: lineHeight).fill()
        }

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
        var count = 1
        for byte in string.utf8 where byte == 0x0A {
            count += 1
        }
        cachedLineCount = count
        cachedLineCountForLength = length
        return count
    }

    private func lineNumber(at location: Int) -> Int {
        guard let string = textView?.string, !string.isEmpty else { return 1 }
        let nsString = string as NSString
        let boundedLocation = min(max(0, location), nsString.length)
        var line = 1
        for index in 0..<boundedLocation where nsString.character(at: index) == 10 {
            line += 1
        }
        return line
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
        return lineNumber(at: characterIndex)
    }
}
