//
//  AgentQueuedPreviewPreludeTests.swift
//  WillDeepTests
//

import Testing

@testable import WillDeep

/// A queued message stores the *composed* prompt — splicing happens at send
/// time — so every human-facing preview of one has to strip the model-facing
/// prelude. The reported bug: the queue card showed
/// "The user attached the following context for this turn…" instead of what
/// the operator typed.
@Suite("Queued preview strips the model prelude")
struct AgentQueuedPreviewPreludeTests {
    /// Mirrors the shape `AppState.composeAttachedPrompt` emits.
    private func splicedPrompt(userText: String, skill: String = "release-macos-app") -> String {
        [
            AgentAttachedPromptProtocol.preludeHeader,
            "",
            "### Skill: \(skill)",
            "some skill body the operator never typed",
            "",
            AgentAttachedPromptProtocol.userTextBoundary,
            userText,
        ].joined(separator: "\n")
    }

    @Test("拼接过的 prompt 只预览用户自己打的字")
    func splicedPromptPreviewsOnlyUserText() {
        let preview = AgentAttachedPromptDisplay.singleLinePreview(
            of: splicedPrompt(userText: "帮我把版本升到 rc5")
        )

        #expect(preview?.contains("帮我把版本升到 rc5") == true)
        #expect(preview?.contains("The user attached") == false)
        #expect(preview?.contains("### Skill:") == false)
        #expect(preview?.contains(AgentAttachedPromptProtocol.userTextBoundary) == false)
    }

    /// Callers keep their own fallbacks (attachment counts, empty label), so
    /// a plain message must opt out rather than get rewritten.
    @Test("没拼接的普通消息返回 nil，交回调用方原有兜底")
    func plainPromptOptsOut() {
        #expect(AgentAttachedPromptDisplay.singleLinePreview(of: "普通一句话") == nil)
        #expect(AgentAttachedPromptDisplay.singleLinePreview(of: "") == nil)
    }

    /// Attachments with no typed text must not preview as the prelude
    /// either — the visible form is the compact attachment tag.
    @Test("只挂附件没打字时不泄漏英文头")
    func attachmentOnlyPromptNeverLeaksHeader() {
        let preview = AgentAttachedPromptDisplay.singleLinePreview(
            of: splicedPrompt(userText: "")
        )

        if let preview {
            #expect(!preview.contains("The user attached"))
            #expect(!preview.contains(AgentAttachedPromptProtocol.userTextBoundary))
        }
    }

    @Test("多行输入压成单行，不破坏卡片布局")
    func multilineUserTextCollapsesToOneLine() {
        let preview = AgentAttachedPromptDisplay.singleLinePreview(
            of: splicedPrompt(userText: "第一行\n第二行")
        )

        #expect(preview?.contains("\n") == false)
        #expect(preview?.contains("第一行") == true)
        #expect(preview?.contains("第二行") == true)
    }

    /// The prelude is a security protocol, not UI copy: it must stay English
    /// and stay exactly in sync between the composer and the display parser,
    /// or stripping silently stops matching.
    @Test("显示侧与协议侧共用同一个 header 常量")
    func displayAndProtocolShareTheHeader() {
        #expect(AgentAttachedPromptDisplay.preludeHeader == AgentAttachedPromptProtocol.preludeHeader)
    }
}
