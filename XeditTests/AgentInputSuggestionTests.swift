//
//  AgentInputSuggestionTests.swift
//  XeditTests
//

import Testing
@testable import WillDeep

@Suite("Agent input suggestion")
struct AgentInputSuggestionTests {
    private typealias Suggestion = AgentInputSuggestion
    private typealias Turn = AgentInputSuggestion.Turn

    @Test("payload keeps the latest user messages and the assistant reply tail")
    func payloadUsesRecentContext() throws {
        let longReply = String(repeating: "前文", count: 2000) + "要不要我提交并合回 develop？"
        let turns = [
            Turn(isUser: true, text: "第一句"),
            Turn(isUser: false, text: "回复一"),
            Turn(isUser: true, text: "第二句"),
            Turn(isUser: true, text: "第三句"),
            Turn(isUser: false, text: longReply)
        ]

        let payload = try #require(Suggestion.payload(from: turns))

        #expect(!payload.contains("第一句"))
        #expect(payload.contains("第二句"))
        #expect(payload.contains("第三句"))
        #expect(payload.hasSuffix("要不要我提交并合回 develop？"))
        #expect(payload.count < Suggestion.assistantTailClip + 2 * Suggestion.userMessageClip + 100)
    }

    @Test("no payload without a user message or a non-empty assistant reply")
    func payloadRequiresBothSides() {
        #expect(Suggestion.payload(from: [Turn(isUser: false, text: "hi")]) == nil)
        #expect(Suggestion.payload(from: [Turn(isUser: true, text: "hi"), Turn(isUser: false, text: "  ")]) == nil)
        #expect(Suggestion.payload(from: [Turn(isUser: true, text: "hi")]) == nil)
    }

    @Test("sanitize strips labels, quotes and extra lines")
    func sanitizeCleansOutput() {
        #expect(Suggestion.sanitize("“提交并合回 develop”") == "提交并合回 develop")
        #expect(Suggestion.sanitize("User: run the tests\nbecause the assistant asked") == "run the tests")
        #expect(Suggestion.sanitize("用户：继续") == "继续")
    }

    @Test("sanitize rejects NONE, empty, overlong and assistant-voice output")
    func sanitizeRejectsNonSuggestions() {
        #expect(Suggestion.sanitize("NONE") == nil)
        #expect(Suggestion.sanitize("none") == nil)
        #expect(Suggestion.sanitize("   ") == nil)
        #expect(Suggestion.sanitize(String(repeating: "长", count: Suggestion.maxCharacters + 1)) == nil)
        #expect(Suggestion.sanitize("好的，我来帮你提交") == nil)
        #expect(Suggestion.sanitize("Sure, I will run the tests") == nil)
    }
}
