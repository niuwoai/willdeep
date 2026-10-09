import Foundation
import AppKit
import Testing
@testable import WillDeep

@Suite("RSI 本机反馈", .serialized)
@MainActor
struct AgentFeedbackLedgerTests {
    @Test("新输入收起旧卡片，取消模型审阅但不伪造人工评分")
    func followupDismissesReviewWithoutJudgment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = AgentRuntime(session: AgentSession())
        runtime.feedbackLedger = AgentFeedbackLedger(directory: directory)
        runtime.beginFeedbackRun(turnID: UUID(), provider: "fixture", model: "model")
        runtime.endFeedbackRun(reason: "finished")
        #expect(runtime.feedbackReview != nil)
        let assessment = Task<Void, Never> {}
        runtime.feedbackAssessmentTask = assessment
        runtime.dismissFeedbackReviewForNewInput()
        #expect(runtime.feedbackReview == nil)
        #expect(runtime.feedbackAssessmentTask == nil)
        #expect(assessment.isCancelled)
        runtime.feedbackLedger.flush()
        #expect(try rows(directory).allSatisfy { $0["judgment_source"] == nil })
    }

    @Test("排队的新输入不能让旧回合结束时复活卡片，新回合仍可反馈")
    func queuedFollowupRetiresOnlyPreviousTurn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = AgentRuntime(session: AgentSession())
        runtime.feedbackLedger = AgentFeedbackLedger(directory: directory)
        let previousTurn = UUID()
        runtime.beginFeedbackRun(turnID: previousTurn, provider: "fixture", model: "model")
        runtime.dismissFeedbackReviewForNewInput()
        runtime.endFeedbackRun(reason: "finished")
        #expect(runtime.feedbackReview == nil)
        #expect(runtime.feedbackPreviousTurnID == previousTurn)
        let nextTurn = UUID()
        runtime.beginFeedbackRun(turnID: nextTurn, provider: "fixture", model: "model")
        runtime.endFeedbackRun(reason: "finished")
        #expect(runtime.feedbackReview?.turnID == nextTurn)
        runtime.feedbackLedger.flush()
        #expect(try rows(directory).filter { $0["signal"] as? String == "run_finished" }.count == 2)
    }

    @Test("模型辅助不能冒充人工通过，结论关联原运行和参数")
    func separateJudgments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = AgentRuntime(session: AgentSession())
        runtime.feedbackLedger = AgentFeedbackLedger(directory: directory)
        runtime.runtimeParameters = AgentRuntimeParameters()
        let turn = UUID()
        runtime.beginFeedbackRun(turnID: turn, provider: "run-provider", model: "run-model")
        runtime.endFeedbackRun(reason: "finished")
        var review = try #require(runtime.feedbackReview)
        review.assessment = AgentFeedbackAssessment(schema: AgentFeedbackAssessment.schemaID,
            judgment: "unknown", confidence: 70, reasonCode: "unverified")
        review.assessmentProvider = "judge-provider"
        review.assessmentModel = "judge-model"
        runtime.feedbackReview = review
        runtime.recordReviewFeedback(review, signal: "model_assessment", source: "model", judgment: "unknown")
        #expect(runtime.feedbackReview?.disposition == nil)
        runtime.recordHumanDisposition(.needsChanges)
        runtime.recordHumanDisposition(.accepted)
        runtime.feedbackLedger.flush()
        let events = try rows(directory)
        let judgments = events.filter { $0["judgment_source"] != nil }
        #expect(judgments.count == 2)
        #expect(judgments[0]["assessment_model"] as? String == "judge-model")
        #expect(judgments[0]["provider"] as? String == "run-provider")
        #expect(judgments[1]["judgment"] as? String == "needs_changes")
        #expect(judgments[1]["assessment_model"] == nil)
        #expect(judgments.allSatisfy { $0["run_id"] as? String == review.id.uuidString && $0["turn_id"] as? String == turn.uuidString })
        #expect(judgments.allSatisfy { $0["runtime_parameters_sha256"] as? String == AgentRuntimeParameters().fingerprint })
        #expect(AgentFeedbackAssessment.parse("{\"schema\":\"willdeep.feedback-assessment.v1\",\"judgment\":\"accepted\",\"confidence\":100,\"reason_code\":\"unverified\"}") == nil)
        runtime.beginFeedbackRun(turnID: UUID(), provider: "new", model: "new")
        #expect(runtime.feedbackReview == nil)
    }
    private func rows(_ directory: URL) throws -> [[String: Any]] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .flatMap { url in
                try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
                    try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
                }
            }
    }

    @Test("建议输入删空后可恢复，不重复展示或误记忽略")
    func suggestionRecoveryAndSettlement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = AgentRuntime(session: AgentSession())
        runtime.feedbackLedger = AgentFeedbackLedger(directory: directory)
        runtime.installInputSuggestion("运行测试", provider: "fixture", model: "model")
        runtime.input = "自己输入"
        runtime.input = ""
        #expect(runtime.inputSuggestion == "运行测试")
        runtime.acceptInputSuggestion()
        #expect(runtime.inputSuggestion == nil)
        runtime.settleInputSuggestion(sent: "运行测试")
        runtime.clearInputSuggestion()
        runtime.feedbackLedger.flush()
        let events = try rows(directory)
        #expect(events.compactMap { $0["signal"] as? String } == ["suggestion_shown", "suggestion_accepted", "suggestion_sent_verbatim"])
        #expect(Set(events.compactMap { $0["suggestion_id"] as? String }).count == 1)
        #expect(events.allSatisfy { $0["text_hash"] != nil && $0["provider"] as? String == "fixture" })
        let raw = try JSONSerialization.data(withJSONObject: events)
        #expect(!String(decoding: raw, as: UTF8.self).contains("运行测试"))
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("发送其他文字才忽略，Esc 后不复活，运行不能冒充验证通过")
    func terminalSignalsAndRunScope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = AgentRuntime(session: AgentSession())
        runtime.feedbackLedger = AgentFeedbackLedger(directory: directory)
        let turn = UUID()
        runtime.beginFeedbackRun(turnID: turn, provider: "fixture", model: "model")
        runtime.beginFeedbackRun(turnID: turn, provider: "fixture", model: "model")
        runtime.installInputSuggestion("继续", provider: nil, model: nil)
        runtime.settleInputSuggestion(sent: "换个需求")
        runtime.installInputSuggestion("再试", provider: nil, model: nil)
        runtime.dismissInputSuggestion()
        runtime.input = "x"
        runtime.input = ""
        #expect(runtime.inputSuggestion == nil)
        runtime.endFeedbackRun(reason: "cancelled")
        runtime.endFeedbackRun(reason: "finished")
        runtime.feedbackLedger.flush()
        let events = try rows(directory)
        let signals = events.compactMap { $0["signal"] as? String }
        #expect(signals == ["run_started", "suggestion_shown", "suggestion_ignored_typed", "suggestion_shown", "suggestion_dismissed", "run_finished"])
        #expect(Set(events.compactMap { $0["run_id"] as? String }).count == 1)
        #expect(events.last?["verification"] as? String == "unverified")
        #expect(runtime.feedbackPreviousTurnID == turn)
    }

    @Test("写失败只增加计数，不进入对话或抛给热路径")
    func writeFailureIsObservable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("fixture".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = AgentFeedbackLedger(directory: directory)
        ledger.record(AgentFeedbackEvent(sessionID: UUID(), signal: "run_started"))
        ledger.flush()
        #expect(ledger.health().writeFailures == 1)
    }

    @Test("普通追问保持 other，不推断满意或失败")
    func conservativeClassification() {
        #expect(AgentFeedbackEvent.distance("kitten", "sitting") == 3)
        #expect(AgentFeedbackEvent.distance("继续", "继续吧") == 1)
        #expect(AgentFeedbackEvent.distance("x", String(repeating: "y", count: 601)) == nil)
        #expect(AgentFeedbackEvent.hash("继续") == AgentFeedbackEvent.hash(" 继续 \n"))
        #expect(AgentFeedbackEvent.hash("继续").count == 16)
        #expect(AgentFeedbackClassification.hint("请解释这里怎么工作的") == "other")
        #expect(AgentFeedbackClassification.hint("不是这个意思") == "correction")
        #expect(AgentFeedbackClassification.hint("补充一点信息") == "supplement")
        #expect(AgentFeedbackClassification.hint("重做这个步骤") == "redo")
    }
}
