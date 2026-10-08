import Foundation
import AppKit
import Testing
@testable import WillDeep

@Suite("RSI 本机反馈", .serialized)
@MainActor
struct AgentFeedbackLedgerTests {
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
