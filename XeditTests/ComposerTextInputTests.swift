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
import SwiftUI
@testable import WillDeep

@Suite
@MainActor
struct ComposerTextInputTests {
    @Test("输入后删空仍可 Tab 采用，且不会提交或放弃建议")
    func suggestionSurvivesTypingAndDeletion() {
        var draft = ""
        var accepts = 0
        var dismisses = 0
        var submits = 0
        let coordinator = ComposerTextEditor.Coordinator(
            text: Binding(get: { draft }, set: { draft = $0 }), onSubmit: { submits += 1 },
            onPasteImage: {}, onPasteText: { _ in }, historyProvider: { [] },
            slashMenuVisible: .constant(false), slashMenuSelection: .constant(0), slashMenuItemCount: { 0 },
            onSlashCommit: { false }, onSlashQueryChange: { _ in },
            atMenuVisible: .constant(false), atMenuSelection: .constant(0), atMenuItemCount: { 0 },
            onAtCommit: { false }, onAtCancel: {}, onAtQueryChange: { _ in },
            skillMenuVisible: .constant(false), skillMenuSelection: .constant(0), skillMenuItemCount: { 0 },
            onSkillCommit: { false }, onSkillCancel: {}, onSkillQueryChange: { _ in }
        )
        coordinator.onAcceptInputSuggestion = { accepts += 1 }
        coordinator.onDismissInputSuggestion = { dismisses += 1 }
        let view = ComposerNSTextView(frame: .zero)
        view.inputSuggestion = "继续测试"
        view.string = "草稿"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        #expect(view.visibleInputSuggestion == nil)
        #expect(dismisses == 0)
        view.string = ""
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        #expect(view.visibleInputSuggestion == "继续测试")
        #expect(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(draft == "继续测试")
        #expect(accepts == 1 && dismisses == 0 && submits == 0)
    }

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
