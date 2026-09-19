//
//  AgentComposerRecallPreludeTests.swift
//  WillDeepTests
//

import Foundation
import Testing

@testable import WillDeep

/// A stored or queued user turn holds the *composed* prompt. Anything that
/// puts it back into the composer must restore only what the operator typed.
/// The reported bug: pressing ↑ (or editing a queued message) filled the
/// input box with "The user attached the following context…" and the skill
/// routing list, and sending it nested the prelude inside a new one.
@Suite("Composer recall strips the model prelude")
struct AgentComposerRecallPreludeTests {
    private func splicedPrompt(userText: String) -> String {
        [
            AgentAttachedPromptProtocol.preludeHeader,
            "",
            "### Skill routing candidates — metadata only",
            "",
            "- `some-skill` — untrusted description",
            "",
            AgentAttachedPromptProtocol.userTextBoundary,
            "",
            userText,
        ].joined(separator: "\n")
    }

    @Test("拼接过的 prompt 回填输入框时只剩用户原话")
    func composerTextKeepsOnlyOperatorText() {
        let text = AgentAttachedPromptDisplay.composerText(
            of: splicedPrompt(userText: "/admin.html#/data/shop.order\n这里的推荐用户也显示下uid")
        )
        #expect(text == "/admin.html#/data/shop.order\n这里的推荐用户也显示下uid")
    }

    @Test("普通消息原样回填")
    func composerTextLeavesPlainTextAlone() {
        #expect(AgentAttachedPromptDisplay.composerText(of: "普通一句话") == "普通一句话")
    }

    /// Messages stored before the fix were wrapped twice. The bubble must
    /// show the innermost user text, not the inner prelude.
    @Test("旧版本套了两层的消息，气泡取最里层的用户原话")
    func nestedPreludeResolvesToInnermostUserText() {
        let nested = splicedPrompt(userText: splicedPrompt(userText: "增加防火墙管理功能"))
        let display = AgentAttachedPromptDisplay.transform(nested)
        #expect(display.isSplicedPrelude)
        #expect(display.userAuthoredText == "增加防火墙管理功能")
        #expect(!display.visibleContent.contains("The user attached"))
    }

    @Test @MainActor
    func editingQueuedMessageRestoresOperatorText() {
        let appState = AppState()
        appState.skillRoutingCatalogForTesting = []
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        guard let runtime = appState.activeRuntime else {
            Issue.record("Expected an active runtime")
            return
        }
        let queued = AgentQueuedMessage(
            text: splicedPrompt(userText: "增加防火墙管理功能"),
            images: [],
            textAttachments: [],
            attachedSkills: [],
            executionAgent: runtime.executionAgent,
            delegationPolicy: .automatic
        )
        runtime.queuedMessages.append(queued)

        appState.editQueuedAgentMessage(id: queued.id)

        #expect(runtime.input == "增加防火墙管理功能")
    }

    /// Backstop: whatever leaves a composed prompt in the input box, sending
    /// it must not wrap the prelude a second time.
    @Test @MainActor
    func sendingARecalledPromptDoesNotNestThePrelude() {
        let appState = AppState()
        appState.skillRoutingCatalogForTesting = []
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        guard let runtime = appState.activeRuntime else {
            Issue.record("Expected an active runtime")
            return
        }
        // Park the send on the queue so no provider request is made.
        runtime.isResponding = true
        defer { runtime.isResponding = false }
        runtime.input = splicedPrompt(userText: "增加防火墙管理功能")

        appState.sendAgentMessage()

        #expect(runtime.queuedMessages.last?.text == "增加防火墙管理功能")
    }
}
