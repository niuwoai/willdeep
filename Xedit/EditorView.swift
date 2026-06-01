//
//  EditorView.swift
//  VeilWriter
//
//  Created by rocky on 2026/5/27.
//

import SwiftUI
import AppKit

/// An NSViewRepresentable that wraps NSTextView inside an NSScrollView
/// for native macOS text editing performance within a SwiftUI view hierarchy.
///
/// Supports syntax highlighting, line numbers, editor font settings, color
/// themes, and current-line focus highlighting.
struct EditorView: NSViewRepresentable {
    @Binding var text: String

    /// The language to use for syntax highlighting. `nil` disables highlighting.
    var language: Language?
    var detectedLanguage: Language?
    var syntaxHighlightingSelection: SyntaxHighlightingSelection = .automatic

    /// User-configurable editor appearance.
    var settings: EditorSettings

    /// Explicit render token used when SwiftUI keeps the same NSTextView alive
    /// across tab activation changes.
    var renderRevision = 0

    /// Explicit highlight token used after file load completes.
    var highlightRevision = 0

    /// A one-shot line navigation request from the inspector/minimap.
    var navigationRequest: EditorNavigationRequest?

    /// Lines whose current content differs from the last saved content.
    var changedLineNumbers: Set<Int> = []

    /// Ranges matching the current find query.
    var searchRanges: [NSRange] = []

    /// The active find match, shown more prominently than the rest.
    var activeSearchRange: NSRange?

    /// Called whenever the user makes a text change (not during programmatic updates).
    var onEdit: (() -> Void)?

    /// Called when the caret or selection moves so the status bar can stay current.
    var onSelectionChange: ((Int, Int, Int, Int) -> Void)?

    /// Called when the user picks a syntax highlighting mode from the editor menu.
    var onSyntaxHighlightingChange: ((SyntaxHighlightingSelection) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = VeilWriterTextView()

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView
        scrollView.autoresizingMask = [.width, .height]
        scrollView.contentView.postsBoundsChangedNotifications = true

        // Rich text mode is required for NSAttributedString highlighting.
        textView.isEditable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        textView.layoutManager?.delegate = context.coordinator
        textView.syntaxHighlightingSelection = syntaxHighlightingSelection
        textView.detectedLanguage = detectedLanguage
        textView.scopeGuideLanguage = language
        textView.onSyntaxHighlightingChange = { [weak coordinator = context.coordinator] selection in
            coordinator?.parent.onSyntaxHighlightingChange?(selection)
        }

        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.visibleRectDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        context.coordinator.applyAppearance(to: textView, in: scrollView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? VeilWriterTextView else { return }

        context.coordinator.parent = self

        let langChanged = context.coordinator.currentLanguage != language
        let settingsChanged = context.coordinator.currentSettings != settings
        let renderRevisionChanged = context.coordinator.currentRenderRevision != renderRevision
        let highlightRevisionChanged = context.coordinator.currentHighlightRevision != highlightRevision
        let navigationChanged = context.coordinator.currentNavigationRequest != navigationRequest
        let searchChanged = context.coordinator.currentSearchRanges != searchRanges
            || context.coordinator.currentActiveSearchRange != activeSearchRange
        context.coordinator.currentLanguage = language
        context.coordinator.currentSettings = settings
        context.coordinator.currentRenderRevision = renderRevision
        context.coordinator.currentHighlightRevision = highlightRevision
        context.coordinator.currentNavigationRequest = navigationRequest
        context.coordinator.currentSearchRanges = searchRanges
        context.coordinator.currentActiveSearchRange = activeSearchRange
        textView.layoutManager?.delegate = context.coordinator
        textView.syntaxHighlightingSelection = syntaxHighlightingSelection
        textView.detectedLanguage = detectedLanguage
        textView.scopeGuideLanguage = language
        textView.onSyntaxHighlightingChange = { [weak coordinator = context.coordinator] selection in
            coordinator?.parent.onSyntaxHighlightingChange?(selection)
        }
        context.coordinator.applyAppearance(to: textView, in: nsView)

        // Detect programmatic text changes (file load, not user typing).
        if textView.string != text || langChanged || settingsChanged || renderRevisionChanged || highlightRevisionChanged {
            textView.clearFoldedScopes()
            context.coordinator.suppressDirtyFlag = true
            context.coordinator.applyText(text, to: textView)
            context.coordinator.suppressDirtyFlag = false
        } else if searchChanged {
            context.coordinator.applySearchHighlights(to: textView)
        }

        if navigationChanged, let navigationRequest {
            context.coordinator.navigate(toLine: navigationRequest.line, in: textView)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSLayoutManagerDelegate, NSTextViewDelegate {
        var parent: EditorView

        /// When `true`, `textDidChange` will skip calling `onEdit` —
        /// used during programmatic text changes in `updateNSView`.
        var suppressDirtyFlag = false

        /// Tracks the current language so we can detect changes.
        var currentLanguage: Language?

        /// Tracks the current settings so we can refresh text attributes.
        var currentSettings: EditorSettings

        var currentRenderRevision: Int
        var currentHighlightRevision: Int
        var currentNavigationRequest: EditorNavigationRequest?
        var currentSearchRanges: [NSRange]
        var currentActiveSearchRange: NSRange?

        /// Debounced highlight work item.
        private var highlightWorkItem: DispatchWorkItem?
        private var highlightGeneration = 0

        init(_ parent: EditorView) {
            self.parent = parent
            self.currentLanguage = parent.language
            self.currentSettings = parent.settings
            self.currentRenderRevision = parent.renderRevision
            self.currentHighlightRevision = parent.highlightRevision
            self.currentNavigationRequest = parent.navigationRequest
            self.currentSearchRanges = parent.searchRanges
            self.currentActiveSearchRange = parent.activeSearchRange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? VeilWriterTextView else { return }
            textView.invalidateFoldableGuidesCache()
            textView.clearFoldedScopes()
            parent.text = textView.string

            if !suppressDirtyFlag {
                parent.onEdit?()
            }

            scheduleHighlight(textView: textView)
            publishCursorPosition(for: textView)
            refreshEditorChrome(for: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? VeilWriterTextView else { return }
            publishCursorPosition(for: textView)
            applyBracketHighlight(to: textView)
            refreshEditorChrome(for: textView)
        }

        @objc func visibleRectDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView,
                  let scrollView = clipView.enclosingScrollView,
                  let textView = scrollView.documentView as? VeilWriterTextView else {
                return
            }
            refreshEditorChrome(for: textView)
        }

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
            lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
            baselineOffset: UnsafeMutablePointer<CGFloat>,
            in textContainer: NSTextContainer,
            forGlyphRange glyphRange: NSRange
        ) -> Bool {
            guard let textView = textContainer.textView as? VeilWriterTextView,
                  textView.isFoldedGlyphRange(glyphRange, layoutManager: layoutManager) else {
                return true
            }

            lineFragmentRect.pointee.size.height = 0
            lineFragmentUsedRect.pointee.size.height = 0
            lineFragmentUsedRect.pointee.size.width = 0
            baselineOffset.pointee = 0
            return true
        }

        func applyAppearance(to textView: VeilWriterTextView, in scrollView: NSScrollView) {
            let theme = parent.settings.theme
            let font = parent.settings.editorFont()
            let paragraphStyle = parent.settings.editorParagraphStyle()

            scrollView.drawsBackground = true
            scrollView.backgroundColor = theme.backgroundColor
            scrollView.rulersVisible = parent.settings.showsLineNumbers
            scrollView.hasVerticalRuler = parent.settings.showsLineNumbers

            textView.font = font
            textView.backgroundColor = theme.backgroundColor
            textView.insertionPointColor = theme.insertionPointColor
            textView.currentLineColor = theme.currentLineBackgroundColor
            textView.foldedPlaceholderColor = theme.gutterTextColor
            textView.foldedPlaceholderBackgroundColor = theme.gutterTextColor.withAlphaComponent(0.12)
            textView.showsCurrentLineHighlight = parent.settings.highlightsCurrentLine
            textView.defaultParagraphStyle = paragraphStyle
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: theme.foregroundColor,
                .paragraphStyle: paragraphStyle,
            ]

            if let ruler = scrollView.verticalRulerView as? LineNumberRulerView {
                ruler.settings = parent.settings
                ruler.theme = theme
                ruler.font = font
                ruler.changedLineNumbers = parent.changedLineNumbers
                ruler.needsDisplay = true
                ruler.invalidateRuleThickness()
            }
            textView.needsDisplay = true
        }

        func applyText(_ newText: String, to textView: VeilWriterTextView) {
            highlightGeneration += 1
            let generation = highlightGeneration
            textView.invalidateFoldableGuidesCache()

            if let lang = currentLanguage, !newText.isEmpty {
                let settings = parent.settings
                let immediate = SyntaxHighlighter.highlightSync(
                    newText,
                    language: lang,
                    theme: settings.theme,
                    font: settings.editorFont()
                )
                replaceTextStorage(in: textView, with: immediate)

                SyntaxHighlighter.highlight(
                    newText,
                    language: lang,
                    theme: settings.theme,
                    font: settings.editorFont()
                ) { [weak self, weak textView] highlighted in
                    guard let self = self, let textView = textView else { return }
                    guard self.highlightGeneration == generation else { return }
                    self.replaceTextStorage(in: textView, with: highlighted)
                }
            } else {
                let attributed = NSAttributedString(
                    string: newText,
                    attributes: [
                        .font: parent.settings.editorFont(),
                        .foregroundColor: parent.settings.theme.foregroundColor,
                        .paragraphStyle: parent.settings.editorParagraphStyle(),
                    ]
                )
                replaceTextStorage(in: textView, with: attributed)
            }
        }

        private func replaceTextStorage(in textView: VeilWriterTextView, with attributed: NSAttributedString) {
            let selected = textView.selectedRanges
            // Replacing the entire text storage resets layout and makes the scroll
            // view snap to the origin. Capture the scroll position up front and
            // restore it afterwards so a re-highlight never yanks the viewport to
            // the top of the document.
            //
            // We anchor on the character at the top of the viewport rather than a
            // raw pixel origin: replacing the storage transiently collapses the
            // document height, so restoring a saved pixel origin gets clamped to
            // the not-yet-recomputed (smaller) height and lands a few lines too
            // high. We also record how far that line's top sits above the viewport
            // top, so partially-scrolled lines are restored sub-pixel-exactly
            // instead of snapping to a whole-line boundary (which drifted by ~one
            // line).
            let topAnchor = topVisibleAnchor(in: textView)

            textView.textStorage?.setAttributedString(attributed)
            if let textStorage = textView.textStorage, textStorage.length > 0 {
                textStorage.addAttribute(
                    .paragraphStyle,
                    value: parent.settings.editorParagraphStyle(),
                    range: NSRange(location: 0, length: textStorage.length)
                )
            }
            applySearchHighlights(to: textView, scrollToActiveMatch: false)
            textView.selectedRanges = selected

            restoreTopVisibleAnchor(topAnchor, in: textView)
            refreshEditorChrome(for: textView)
        }

        /// A scroll anchor: the character at the top of the viewport plus the
        /// distance its line's top sits above the viewport top. Restoring both
        /// reproduces a partially-scrolled top line exactly.
        private struct ScrollAnchor {
            let characterIndex: Int
            /// `viewportTopY - lineTopY` in text-view coordinates (>= 0 when the
            /// line's top has scrolled above the viewport edge).
            let offsetWithinLine: CGFloat
        }

        private func topVisibleAnchor(in textView: VeilWriterTextView) -> ScrollAnchor? {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  textView.enclosingScrollView != nil else {
                return nil
            }
            let visibleRect = textView.visibleRect
            guard visibleRect.height > 0 else { return nil }

            // Probe a point just inside the top of the viewport, in text-container
            // coordinates.
            let probeY = visibleRect.minY - textView.textContainerOrigin.y + 1
            let probe = NSPoint(x: textView.textContainerOrigin.x, y: probeY)
            let glyphIndex = layoutManager.glyphIndex(for: probe, in: textContainer)
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

            var lineGlyphRange = NSRange(location: 0, length: 0)
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineGlyphRange,
                withoutAdditionalLayout: true
            )
            let lineTopY = lineRect.minY + textView.textContainerOrigin.y
            return ScrollAnchor(
                characterIndex: characterIndex,
                offsetWithinLine: visibleRect.minY - lineTopY
            )
        }

        /// Scrolls so the anchored line is restored to the same sub-pixel position
        /// it held before the text storage was replaced, after forcing layout so
        /// the document height is correct.
        private func restoreTopVisibleAnchor(_ anchor: ScrollAnchor?, in textView: VeilWriterTextView) {
            guard let anchor,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let clipView = textView.enclosingScrollView?.contentView else {
                return
            }

            let length = (textView.string as NSString).length
            let safeAnchor = min(max(0, anchor.characterIndex), max(0, length))

            // Force full glyph layout so both the anchor's line rect and the
            // document height are valid; otherwise the clamp below uses a stale
            // (collapsed) height and lands the viewport too high.
            layoutManager.ensureLayout(for: textContainer)

            let glyphIndex = layoutManager.glyphIndexForCharacter(at: safeAnchor)
            var lineGlyphRange = NSRange(location: 0, length: 0)
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineGlyphRange
            )

            let documentHeight = layoutManager.usedRect(for: textContainer).height
                + textView.textContainerInset.height * 2
            let lineTopY = lineRect.minY + textView.textContainerOrigin.y
            // Re-apply the original within-line offset so a top line that was only
            // half-visible stays half-visible instead of snapping flush to the top.
            let targetY = lineTopY + anchor.offsetWithinLine
            let maxY = max(0, documentHeight - clipView.bounds.height)
            let clampedY = min(max(0, targetY), maxY)
            clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: clampedY))
            textView.enclosingScrollView?.reflectScrolledClipView(clipView)
        }

        func applySearchHighlights(to textView: VeilWriterTextView, scrollToActiveMatch: Bool = true) {
            guard let textStorage = textView.textStorage else { return }

            let fullRange = NSRange(location: 0, length: textStorage.length)
            textStorage.removeAttribute(.backgroundColor, range: fullRange)
            textStorage.removeAttribute(.underlineStyle, range: fullRange)

            let passiveColor = NSColor.systemYellow.withAlphaComponent(0.28)
            let activeColor = NSColor.systemYellow.withAlphaComponent(0.58)
            for range in currentSearchRanges where NSMaxRange(range) <= textStorage.length {
                textStorage.addAttribute(.backgroundColor, value: passiveColor, range: range)
            }

            if let activeRange = currentActiveSearchRange,
               NSMaxRange(activeRange) <= textStorage.length {
                textStorage.addAttributes(
                    [
                        .backgroundColor: activeColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ],
                    range: activeRange
                )
                if scrollToActiveMatch {
                    textView.scrollRangeToVisible(activeRange)
                }
            }

            refreshEditorChrome(for: textView)
        }

        private func refreshEditorChrome(for textView: VeilWriterTextView) {
            // Only re-apply folding when scopes are actually folded. Applying it
            // unconditionally forced a full-document glyph/layout invalidation on
            // every caret move, which produced severe arrow-key lag.
            textView.refreshFoldedScopesIfNeeded()
            textView.needsDisplay = true
            (textView.enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?.needsDisplay = true
        }

        func navigate(toLine line: Int, in textView: VeilWriterTextView) {
            let range = Self.rangeForLine(line, in: textView.string)
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            textView.scrollRangeToVisible(range)
            publishCursorPosition(for: textView)
            applyBracketHighlight(to: textView)
            refreshEditorChrome(for: textView)
        }

        static func rangeForLine(_ line: Int, in text: String) -> NSRange {
            guard line > 1, !text.isEmpty else {
                return NSRange(location: 0, length: 0)
            }

            let nsText = text as NSString
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            var currentLine = 1

            while lineStart < nsText.length {
                nsText.getLineStart(
                    &lineStart,
                    end: &lineEnd,
                    contentsEnd: &contentsEnd,
                    for: NSRange(location: lineStart, length: 0)
                )

                if currentLine == line {
                    return NSRange(location: lineStart, length: max(0, contentsEnd - lineStart))
                }

                currentLine += 1
                lineStart = lineEnd
            }

            return NSRange(location: nsText.length, length: 0)
        }

        private func publishCursorPosition(for textView: VeilWriterTextView) {
            let selectedRange = textView.selectedRange()
            let position = Self.lineAndColumn(for: selectedRange.location, in: textView.string)
            let selectedLines = Self.selectedLineCount(for: selectedRange, in: textView.string)
            parent.onSelectionChange?(position.line, position.column, selectedRange.length, selectedLines)
        }

        /// The two single-character ranges currently carrying the bracket-match
        /// highlight, so we can clear exactly those instead of sweeping the whole
        /// document's temporary attributes on every caret move.
        private var highlightedBracketRanges: [NSRange] = []

        private func applyBracketHighlight(to textView: VeilWriterTextView) {
            guard let layoutManager = textView.layoutManager else { return }
            let length = (textView.string as NSString).length

            for range in highlightedBracketRanges where NSMaxRange(range) <= length {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            }
            highlightedBracketRanges = []

            guard let match = Self.matchingBracketRanges(
                around: textView.selectedRange().location,
                in: textView.string
            ) else {
                return
            }

            let color = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.55)
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: match.opening)
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: match.closing)
            highlightedBracketRanges = [match.opening, match.closing]
        }

        static func matchingBracketRanges(around location: Int, in text: String) -> (opening: NSRange, closing: NSRange)? {
            let nsText = text as NSString
            guard nsText.length > 1 else { return nil }

            let candidates = [
                min(max(0, location - 1), nsText.length - 1),
                min(max(0, location), nsText.length - 1),
            ]

            for index in candidates {
                guard let bracket = BracketPair(character: nsText.character(at: index)) else {
                    continue
                }

                if bracket.isOpening,
                   let match = findClosingBracket(from: index, pair: bracket, in: nsText) {
                    return (NSRange(location: index, length: 1), NSRange(location: match, length: 1))
                }

                if !bracket.isOpening,
                   let match = findOpeningBracket(from: index, pair: bracket, in: nsText) {
                    return (NSRange(location: match, length: 1), NSRange(location: index, length: 1))
                }
            }

            return nil
        }

        private static func findClosingBracket(from index: Int, pair: BracketPair, in text: NSString) -> Int? {
            var depth = 0
            guard index + 1 < text.length else { return nil }
            for cursor in index..<text.length {
                let character = text.character(at: cursor)
                if character == pair.opening {
                    depth += 1
                } else if character == pair.closing {
                    depth -= 1
                    if depth == 0 {
                        return cursor
                    }
                }
            }
            return nil
        }

        private static func findOpeningBracket(from index: Int, pair: BracketPair, in text: NSString) -> Int? {
            var depth = 0
            guard index > 0 else { return nil }
            for cursor in stride(from: index, through: 0, by: -1) {
                let character = text.character(at: cursor)
                if character == pair.closing {
                    depth += 1
                } else if character == pair.opening {
                    depth -= 1
                    if depth == 0 {
                        return cursor
                    }
                }
            }
            return nil
        }

        static func lineAndColumn(for location: Int, in text: String) -> (line: Int, column: Int) {
            guard !text.isEmpty else { return (1, 1) }

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

            let prefix = nsText.substring(with: NSRange(location: 0, length: lineStart))
            let line = prefix.components(separatedBy: .newlines).count
            return (line, boundedLocation - lineStart + 1)
        }

        static func selectedLineCount(for range: NSRange, in text: String) -> Int {
            guard range.length > 0 else { return 0 }
            let nsText = text as NSString
            let boundedLocation = min(max(0, range.location), nsText.length)
            let boundedEnd = min(max(boundedLocation, NSMaxRange(range)), nsText.length)
            let selected = nsText.substring(with: NSRange(location: boundedLocation, length: boundedEnd - boundedLocation))
            return selected.components(separatedBy: .newlines).count
        }

        // MARK: - Debounced Highlighting

        /// Schedules a debounced re-highlight of the current document content.
        /// The highlight runs on a background queue and results are applied on
        /// the main thread, preserving cursor/selection position.
        private func scheduleHighlight(textView: VeilWriterTextView) {
            guard let lang = currentLanguage else { return }

            highlightWorkItem?.cancel()
            highlightGeneration += 1
            let generation = highlightGeneration

            let settings = parent.settings
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self = self, let textView = textView, self.currentLanguage != nil else { return }

                let latestText = textView.string
                guard !latestText.isEmpty else { return }

                SyntaxHighlighter.highlight(
                    latestText,
                    language: lang,
                    theme: settings.theme,
                    font: settings.editorFont()
                ) { [weak self, weak textView] highlighted in
                    guard let self = self, let textView = textView else { return }
                    guard self.highlightGeneration == generation else { return }
                    self.replaceTextStorage(in: textView, with: highlighted)
                }
            }

            highlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        }
    }
}

private struct BracketPair {
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

final class VeilWriterTextView: NSTextView {
    var currentLineColor: NSColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.16)
    var foldedPlaceholderColor: NSColor = NSColor.secondaryLabelColor
    var foldedPlaceholderBackgroundColor: NSColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
    var showsCurrentLineHighlight = true
    var scopeGuideLanguage: Language?
    var syntaxHighlightingSelection: SyntaxHighlightingSelection = .automatic
    var detectedLanguage: Language?
    var onSyntaxHighlightingChange: ((SyntaxHighlightingSelection) -> Void)?
    private var foldedGuides: Set<ScopeGuide> = []

    /// Tracks whether the layout currently reflects `foldedGuides`. While this is
    /// `true`, caret moves and chrome refreshes can skip the expensive
    /// full-document glyph/layout invalidation entirely.
    private var foldLayoutIsClean = true

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
        if menu.items.isEmpty == false {
            menu.addItem(.separator())
        }
        menu.addItem(syntaxHighlightingMenuItem())
        return menu
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
        applyFoldedScopes()
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    func clearFoldedScopes() {
        guard foldedGuides.isEmpty == false else { return }
        foldedGuides.removeAll()
        foldLayoutIsClean = false
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
    }

    func applyFoldedScopes() {
        guard let layoutManager, let textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)

        guard foldedGuides.isEmpty == false else {
            layoutManager.invalidateGlyphs(forCharacterRange: fullRange, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
            foldLayoutIsClean = true
            return
        }

        for guide in foldedGuides {
            guard let hiddenRange = foldedCharacterRange(for: guide), hiddenRange.length > 0 else {
                continue
            }
            layoutManager.addTemporaryAttributes(
                [.foregroundColor: NSColor.clear],
                forCharacterRange: hiddenRange
            )
        }
        layoutManager.invalidateGlyphs(forCharacterRange: fullRange, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        foldLayoutIsClean = true
        needsDisplay = true
    }

    func isFoldedGlyphRange(_ glyphRange: NSRange, layoutManager: NSLayoutManager) -> Bool {
        guard foldedGuides.isEmpty == false else { return false }
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        return foldedCharacterRanges().contains { NSIntersectionRange($0, characterRange).length > 0 }
    }

    private func foldedCharacterRanges() -> [NSRange] {
        foldedGuides.compactMap { foldedCharacterRange(for: $0) }
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

    private static func lineNumber(at location: Int, in text: String) -> Int {
        let nsText = text as NSString
        let boundedLocation = min(max(0, location), nsText.length)
        var line = 1
        for index in 0..<boundedLocation where nsText.character(at: index) == 10 {
            line += 1
        }
        return line
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
        scrollView?.tile()
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        theme.gutterBackgroundColor.setFill()
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
        let foldableGuides = (textView as? VeilWriterTextView)?.foldableGuides() ?? []
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
                isFolded: foldGuide.map { (textView as? VeilWriterTextView)?.isFolded($0) ?? false } ?? false
            )

            let nextGlyphIndex = NSMaxRange(lineGlyphRange)
            if nextGlyphIndex <= glyphIndex { break }
            glyphIndex = nextGlyphIndex
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x <= 18,
              let textView = textView as? VeilWriterTextView,
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

    private func lineCount() -> Int {
        guard let string = textView?.string, !string.isEmpty else { return 1 }
        let nsString = string as NSString
        var count = 1
        for index in 0..<nsString.length where nsString.character(at: index) == 10 {
            count += 1
        }
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
