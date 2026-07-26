//
//  ComposerTextInputTests.swift
//  WillDeepTests
//
//  Regression coverage for protected-secret placeholder rendering in the
//  Agent composer.
//

import AppKit
import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct ComposerTextInputTests {
    @Test("wrapped secret placeholder highlight stays on its visual fragments")
    func wrappedSecretHighlightUsesPerLineRects() throws {
        let placeholder = AgentSecretStore.placeholder(
            identifier: "tokenhub-beta-mysql-password"
        )
        let source = "密码是 \(placeholder)"
        let match = try #require(AgentSecretStore.placeholderMatches(in: source).first)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let storage = NSTextStorage(
            string: source,
            attributes: [.font: font]
        )
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(width: 90, height: 1_000)
        )
        textContainer.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let rects = ComposerSecretTagLayout.highlightRects(
            forCharacterRange: match.range,
            layoutManager: layoutManager,
            textContainer: textContainer
        )

        #expect(rects.count > 1)
        #expect(Set(rects.map { $0.minY.rounded() }).count == rects.count)
        #expect(rects.allSatisfy { $0.width <= textContainer.size.width })
    }

    @Test("single-line secret placeholder keeps one compact highlight rect")
    func singleLineSecretHighlightUsesOneRect() throws {
        let placeholder = AgentSecretStore.placeholder(identifier: "database-password")
        let source = "use \(placeholder) now"
        let match = try #require(AgentSecretStore.placeholderMatches(in: source).first)
        let storage = NSTextStorage(
            string: source,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            ]
        )
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(width: 600, height: 1_000)
        )
        textContainer.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let rects = ComposerSecretTagLayout.highlightRects(
            forCharacterRange: match.range,
            layoutManager: layoutManager,
            textContainer: textContainer
        )

        #expect(rects.count == 1)
        #expect(rects[0].width < textContainer.size.width)
    }
}
