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

    /// User-configurable editor appearance.
    var settings: EditorSettings

    /// Called whenever the user makes a text change (not during programmatic updates).
    var onEdit: (() -> Void)?

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
        context.coordinator.currentLanguage = language
        context.coordinator.currentSettings = settings
        context.coordinator.applyAppearance(to: textView, in: nsView)

        // Detect programmatic text changes (file load, not user typing).
        if textView.string != text || langChanged || settingsChanged {
            context.coordinator.suppressDirtyFlag = true
            context.coordinator.applyText(text, to: textView)
            context.coordinator.suppressDirtyFlag = false
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorView

        /// When `true`, `textDidChange` will skip calling `onEdit` —
        /// used during programmatic text changes in `updateNSView`.
        var suppressDirtyFlag = false

        /// Tracks the current language so we can detect changes.
        var currentLanguage: Language?

        /// Tracks the current settings so we can refresh text attributes.
        var currentSettings: EditorSettings

        /// Debounced highlight work item.
        private var highlightWorkItem: DispatchWorkItem?

        init(_ parent: EditorView) {
            self.parent = parent
            self.currentLanguage = parent.language
            self.currentSettings = parent.settings
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? VeilWriterTextView else { return }
            parent.text = textView.string

            if !suppressDirtyFlag {
                parent.onEdit?()
            }

            scheduleHighlight(textView: textView)
            refreshEditorChrome(for: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? VeilWriterTextView else { return }
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

        func applyAppearance(to textView: VeilWriterTextView, in scrollView: NSScrollView) {
            let theme = parent.settings.theme
            let font = parent.settings.editorFont()

            scrollView.drawsBackground = true
            scrollView.backgroundColor = theme.backgroundColor
            scrollView.rulersVisible = parent.settings.showsLineNumbers
            scrollView.hasVerticalRuler = parent.settings.showsLineNumbers

            textView.font = font
            textView.textColor = theme.foregroundColor
            textView.backgroundColor = theme.backgroundColor
            textView.insertionPointColor = theme.insertionPointColor
            textView.currentLineColor = theme.currentLineBackgroundColor
            textView.showsCurrentLineHighlight = parent.settings.highlightsCurrentLine
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: theme.foregroundColor,
            ]

            if let ruler = scrollView.verticalRulerView as? LineNumberRulerView {
                ruler.settings = parent.settings
                ruler.theme = theme
                ruler.font = font
                ruler.needsDisplay = true
                ruler.invalidateRuleThickness()
            }
            textView.needsDisplay = true
        }

        func applyText(_ newText: String, to textView: VeilWriterTextView) {
            if let lang = currentLanguage, !newText.isEmpty {
                let settings = parent.settings
                SyntaxHighlighter.highlight(
                    newText,
                    language: lang,
                    theme: settings.theme,
                    font: settings.editorFont()
                ) { [weak self, weak textView] highlighted in
                    guard let self = self, let textView = textView else { return }
                    self.replaceTextStorage(in: textView, with: highlighted)
                }
            } else {
                let attributed = NSAttributedString(
                    string: newText,
                    attributes: [
                        .font: parent.settings.editorFont(),
                        .foregroundColor: parent.settings.theme.foregroundColor,
                    ]
                )
                replaceTextStorage(in: textView, with: attributed)
            }
        }

        private func replaceTextStorage(in textView: VeilWriterTextView, with attributed: NSAttributedString) {
            let selected = textView.selectedRanges
            textView.textStorage?.setAttributedString(attributed)
            textView.selectedRanges = selected
            refreshEditorChrome(for: textView)
        }

        private func refreshEditorChrome(for textView: VeilWriterTextView) {
            textView.needsDisplay = true
            (textView.enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?.needsDisplay = true
        }

        // MARK: - Debounced Highlighting

        /// Schedules a debounced re-highlight of the current document content.
        /// The highlight runs on a background queue and results are applied on
        /// the main thread, preserving cursor/selection position.
        private func scheduleHighlight(textView: VeilWriterTextView) {
            guard let lang = currentLanguage else { return }

            highlightWorkItem?.cancel()

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
                    self.replaceTextStorage(in: textView, with: highlighted)
                }
            }

            highlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        }
    }
}

final class VeilWriterTextView: NSTextView {
    var currentLineColor: NSColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.16)
    var showsCurrentLineHighlight = true

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard showsCurrentLineHighlight else { return }

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
}

final class LineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?
    var settings: EditorSettings = .default
    var theme: EditorTheme = .paper
    var font: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

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
        return CGFloat(digits) * digitWidth + 18
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
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        var glyphIndex = glyphRange.location

        while glyphIndex < NSMaxRange(glyphRange) {
            var lineGlyphRange = NSRange(location: 0, length: 0)
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineGlyphRange,
                withoutAdditionalLayout: true
            )
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineNumber = lineNumber(at: characterIndex)
            let y = relativePoint.y + textView.textContainerOrigin.y + lineRect.minY

            drawLineNumber(
                lineNumber,
                y: y,
                lineHeight: lineRect.height,
                attributes: attributes,
                isCurrentLine: settings.highlightsCurrentLine && lineNumber == selectedLine
            )

            let nextGlyphIndex = NSMaxRange(lineGlyphRange)
            if nextGlyphIndex <= glyphIndex { break }
            glyphIndex = nextGlyphIndex
        }
    }

    private func drawLineNumber(
        _ lineNumber: Int,
        y: CGFloat,
        lineHeight: CGFloat,
        attributes: [NSAttributedString.Key: Any],
        isCurrentLine: Bool
    ) {
        if isCurrentLine {
            theme.currentLineBackgroundColor.setFill()
            NSRect(x: 0, y: y, width: bounds.width, height: lineHeight).fill()
        }

        let text = "\(lineNumber)" as NSString
        let drawRect = NSRect(
            x: 0,
            y: y + max(0, (lineHeight - (attributes[.font] as? NSFont ?? font).boundingRectForFont.height) / 2),
            width: bounds.width - 8,
            height: lineHeight
        )
        text.draw(in: drawRect, withAttributes: attributes)
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
}
