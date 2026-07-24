//
//  AgentPlanModeFlashJudgeTests.swift
//  WillDeepTests
//

import Testing
@testable import WillDeep

@Suite
struct AgentPlanModeFlashJudgeTests {
    private func run(
        judgeReply: String?,
        timeoutSeconds: Double = 3
    ) async -> Bool {
        await AgentPlanModeFlashJudge.shouldSuggest(
            userText: "帮我重构这个函数",
            attachmentCount: 0,
            includesWorkspaceOverview: false,
            workspaceAvailable: true,
            localScore: 2,
            timeoutSeconds: timeoutSeconds
        ) { _, _, _ in judgeReply }
    }

    @Test("a clean positive verdict suggests Plan mode")
    func positiveVerdict() async {
        let reply = #"{"should_suggest_plan":true,"confidence":0.8,"reason":"cross-file refactor"}"#
        #expect(await run(judgeReply: reply))
    }

    @Test("a clean negative verdict sends normally")
    func negativeVerdict() async {
        let reply = #"{"should_suggest_plan":false,"confidence":0.7,"reason":"local edit"}"#
        #expect(await run(judgeReply: reply) == false)
    }

    @Test("a nil transport reply falls back to not suggesting")
    func nilReplyFallsBack() async {
        #expect(await run(judgeReply: nil) == false)
    }

    @Test("an undecodable reply falls back to not suggesting")
    func garbageReplyFallsBack() async {
        #expect(await run(judgeReply: "sorry I can't do that") == false)
    }

    @Test("JSON wrapped in markdown fences and prose is still parsed")
    func lenientJSONExtraction() async {
        let reply = """
        Here is my verdict:
        ```json
        {"should_suggest_plan": true, "confidence": 0.9}
        ```
        Hope that helps.
        """
        #expect(await run(judgeReply: reply))
    }

    @Test("a verdict missing the decisive field defaults to false")
    func missingFieldDefaultsFalse() async {
        #expect(await run(judgeReply: #"{"confidence":0.5}"#) == false)
    }

    @Test("a slow judge times out and sends normally")
    func slowJudgeTimesOut() async {
        let suggest = await AgentPlanModeFlashJudge.shouldSuggest(
            userText: "帮我重构这个函数",
            attachmentCount: 0,
            includesWorkspaceOverview: false,
            workspaceAvailable: true,
            localScore: 2,
            timeoutSeconds: 0.2
        ) { _, _, _ in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return #"{"should_suggest_plan":true,"confidence":1.0}"#
        }
        #expect(suggest == false)
    }

    @Test("the payload never leaks beyond the truncation cap")
    func payloadTruncation() {
        let huge = String(repeating: "重构", count: 5000)
        let payload = AgentPlanModeFlashJudge.encodeJudgePayload(
            userText: huge,
            attachmentCount: 0,
            includesWorkspaceOverview: false,
            workspaceAvailable: true,
            localScore: 2
        )
        // The encoded message body must not exceed the character cap
        // (payload also carries JSON scaffolding, so just assert the cap held).
        #expect(payload.contains("willdeep_planmode_judge_v1"))
        #expect(payload.count < AgentPlanModeFlashJudge.maxUserMessageChars + 500)
    }
}
