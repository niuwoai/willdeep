//
//  EditorCJKLiveRedrawTests.swift
//  WillDeepTests
//
//  Regression coverage for the 1.192.0-rc5 live CJK fallback-font pass:
//  rewriting `.font` inside `textDidChange` without begin/endEditing or an
//  explicit invalidation left freshly-typed CJK text undrawn (invisible)
//  until an unrelated full redraw. The live pass must schedule layout and
//  display invalidation for the ranges it touches, and must never run while
//  an input-method composition (marked text) is in flight.
//

import Testing
import Foundation
import AppKit
import SwiftUI
@testable import WillDeep

private final class InvalidationSpyLayoutManager: NSLayoutManager {
    var displayInvalidations: [NSRange] = []
    var layoutInvalidations: [NSRange] = []

    func resetRecordedInvalidations() {
        displayInvalidations.removeAll()
        layoutInvalidations.removeAll()
    }

    override func invalidateDisplay(forCharacterRange charRange: NSRange) {
        displayInvalidations.append(charRange)
        super.invalidateDisplay(forCharacterRange: charRange)
    }

    override func invalidateLayout(
        forCharacterRange charRange: NSRange,
        actualCharacterRange actualCharRange: NSRangePointer?
    ) {
        layoutInvalidations.append(charRange)
        super.invalidateLayout(forCharacterRange: charRange, actualCharacterRange: actualCharRange)
    }
}

private final class EditorIMEBindingSpy {
    var text: String
    var editCount = 0

    init(text: String) {
        self.text = text
    }
}

extension WillDeepTests {
    @MainActor
    private static func makeLiveEditorTextSystem(
        text: String,
        font: NSFont
    ) -> (textView: WillDeepTextView, layoutManager: InvalidationSpyLayoutManager) {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layoutManager = InvalidationSpyLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 400, height: 1_000_000))
        layoutManager.addTextContainer(container)
        let textView = WillDeepTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300),
            textContainer: container
        )
        return (textView, layoutManager)
    }

    @Test("live CJK fallback pass invalidates layout and display for touched ranges")
    @MainActor
    func testLiveCJKFallbackPassInvalidatesTouchedRanges() throws {
        let baseFont = try #require(NSFont(name: "Menlo-Regular", size: 13))
        // A CJK-capable font that differs from the PingFang fallback: text
        // storage auto font fixing keeps it (unlike Menlo, which gets fixed to
        // PingFang on attribute access), so the live pass has real work to do —
        // the scenario where the rc5 regression left glyphs undrawn.
        let cjkCapableFont = try #require(NSFont(name: "HiraginoSansGB-W3", size: 13))
        let (textView, layoutManager) = Self.makeLiveEditorTextSystem(text: "let x = 1", font: baseFont)
        let storage = try #require(textView.textStorage)

        // Simulate a typed CJK insertion as it looks when textDidChange fires.
        storage.replaceCharacters(
            in: NSRange(location: storage.length, length: 0),
            with: NSAttributedString(string: "\u{4F60}\u{597D}", attributes: [.font: cjkCapableFont])
        )
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: storage.length))
        layoutManager.resetRecordedInvalidations()

        let applied = SyntaxHighlighter.applyLiveEditorCJKFallbackFonts(
            in: textView,
            defaultFont: baseFont,
            range: NSRange(location: 0, length: storage.length)
        )

        let cjkRange = NSRange(location: 9, length: 2)
        #expect(applied == [cjkRange])
        let appliedFont = storage.attribute(.font, at: cjkRange.location, effectiveRange: nil) as? NSFont
        #expect(appliedFont == cjkCapableFont.editorCJKFallbackFont())
        #expect(layoutManager.layoutInvalidations.contains { NSIntersectionRange($0, cjkRange) == cjkRange })
        #expect(layoutManager.displayInvalidations.contains { NSIntersectionRange($0, cjkRange) == cjkRange })

        // The invalidated range must be re-layoutable without any further
        // event: glyphs for the new characters exist immediately.
        layoutManager.ensureLayout(forCharacterRange: cjkRange)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: cjkRange, actualCharacterRange: nil)
        #expect(glyphRange.length > 0)
    }

    @Test("live CJK fallback pass is a no-op for ASCII and for already-fixed text")
    @MainActor
    func testLiveCJKFallbackPassSkipsAsciiAndAlreadyFixedText() throws {
        let baseFont = try #require(NSFont(name: "Menlo-Regular", size: 13))
        let (textView, layoutManager) = Self.makeLiveEditorTextSystem(text: "plain ascii", font: baseFont)
        let storage = try #require(textView.textStorage)
        let fullRange = NSRange(location: 0, length: storage.length)
        layoutManager.resetRecordedInvalidations()

        #expect(SyntaxHighlighter.applyLiveEditorCJKFallbackFonts(
            in: textView, defaultFont: baseFont, range: fullRange
        ).isEmpty)
        #expect(layoutManager.layoutInvalidations.isEmpty)
        #expect(layoutManager.displayInvalidations.isEmpty)

        // CJK text that already carries the fallback font is not rewritten
        // again, so repeated keystrokes don't re-invalidate the whole document.
        storage.replaceCharacters(
            in: NSRange(location: 0, length: 0),
            with: NSAttributedString(
                string: "\u{4E2D}\u{6587}",
                attributes: [.font: baseFont.editorCJKFallbackFont()]
            )
        )
        layoutManager.resetRecordedInvalidations()
        #expect(SyntaxHighlighter.applyLiveEditorCJKFallbackFonts(
            in: textView, defaultFont: baseFont, range: NSRange(location: 0, length: storage.length)
        ).isEmpty)
        #expect(layoutManager.layoutInvalidations.isEmpty)
        #expect(layoutManager.displayInvalidations.isEmpty)
    }

    @Test("live CJK fallback pass never runs during an IME composition")
    @MainActor
    func testLiveCJKFallbackPassSkipsDuringMarkedText() throws {
        let baseFont = try #require(NSFont(name: "Menlo-Regular", size: 13))
        let cjkCapableFont = try #require(NSFont(name: "HiraginoSansGB-W3", size: 13))
        let (textView, layoutManager) = Self.makeLiveEditorTextSystem(text: "abc", font: baseFont)
        let storage = try #require(textView.textStorage)

        textView.typingAttributes = [.font: cjkCapableFont]
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.setMarkedText(
            "\u{4F60}",
            selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        try #require(textView.hasMarkedText())
        layoutManager.resetRecordedInvalidations()

        let applied = SyntaxHighlighter.applyLiveEditorCJKFallbackFonts(
            in: textView,
            defaultFont: baseFont,
            range: NSRange(location: 0, length: storage.length)
        )

        // While the composition is active the pass must bail out before
        // touching the storage: nothing rewritten, nothing invalidated.
        #expect(applied.isEmpty)
        #expect(layoutManager.layoutInvalidations.isEmpty)
        #expect(layoutManager.displayInvalidations.isEmpty)

        // Committing the composition ends marked text; the next pass (as fired
        // by the commit's textDidChange) applies the fallback normally. Force
        // the committed character to a rewriteable font first — the IME
        // plumbing may already have normalized it to the fallback.
        textView.unmarkText()
        storage.addAttribute(.font, value: cjkCapableFont, range: NSRange(location: 3, length: 1))
        let appliedAfterCommit = SyntaxHighlighter.applyLiveEditorCJKFallbackFonts(
            in: textView,
            defaultFont: baseFont,
            range: NSRange(location: 0, length: storage.length)
        )
        #expect(appliedAfterCommit == [NSRange(location: 3, length: 1)])
    }

    @Test("editor defers binding and syntax highlighting during IME composition")
    @MainActor
    func testEditorDefersDocumentUpdatesDuringMarkedText() async throws {
        let spy = EditorIMEBindingSpy(text: "abc")
        let editor = EditorView(
            text: Binding(
                get: { spy.text },
                set: { spy.text = $0 }
            ),
            language: .swift,
            detectedLanguage: .swift,
            settings: .default,
            activeTabID: nil,
            onEdit: { spy.editCount += 1 }
        )
        let coordinator = editor.makeCoordinator()
        let (textView, _) = Self.makeLiveEditorTextSystem(
            text: spy.text,
            font: EditorSettings.default.editorFont()
        )

        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.setMarkedText(
            "ni",
            selectedRange: NSRange(location: 0, length: 2),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        try #require(textView.hasMarkedText())

        coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView)
        )
        try await Task.sleep(nanoseconds: 600_000_000)

        #expect(textView.hasMarkedText())
        #expect(textView.string == "abcni")
        #expect(spy.text == "abc")
        #expect(spy.editCount == 0)

        textView.unmarkText()
        coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView)
        )

        #expect(!textView.hasMarkedText())
        #expect(spy.text == "abcni")
        #expect(spy.editCount == 1)
    }
}
