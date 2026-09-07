import Foundation
import Testing
@testable import WillDeep

/// A phase receipt is three lines the user can read at every phase boundary
/// and the model can resume from. The host writes one from evidence it
/// holds; the model may refine the wording; timing is never the model's.
@Suite
struct AgentPhaseReceiptTests {
    private func roadmap() -> AgentGoalRoadmap {
        AgentGoalRoadmap(
            phases: [
                .init(id: "p1", title: "查清证据", acceptanceCriteria: ["日志已读"]),
                .init(id: "p2", title: "改代码", acceptanceCriteria: ["编译通过"]),
                .init(id: "p3", title: "跑测试", acceptanceCriteria: ["全绿"]),
            ],
            activePhaseIndex: 0
        )
    }

    @Test("the host receipt names the phase, tallies steps, names the next phase, and projects time")
    func hostSynthesis() {
        let started = Date(timeIntervalSince1970: 1_000)
        let now = started.addingTimeInterval(600)
        let plan = AgentPlan(status: .done, steps: [
            .init(text: "a", status: .done), .init(text: "b", status: .done), .init(text: "c", status: .skipped),
        ])

        let receipt = AgentPhaseReceipt.synthesized(
            roadmap: roadmap(), completedIndex: 0, plan: plan, phaseStartedAt: started, now: now
        )

        #expect(receipt.author == .host)
        #expect(receipt.done == "查清证据 — 2/3 steps done")
        #expect(receipt.next == "改代码")
        // Ten minutes for this phase, two phases still open.
        #expect(receipt.remainingSeconds == 1_200)
        #expect(receipt.lines == ["DONE: 查清证据 — 2/3 steps done", "NEXT: 改代码", "ETA: ~20 min remaining"])
    }

    @Test("the last phase points at final acceptance and no start time means no ETA")
    func lastPhaseAndNoTiming() {
        let receipt = AgentPhaseReceipt.synthesized(
            roadmap: roadmap(), completedIndex: 2, plan: nil, phaseStartedAt: nil
        )
        #expect(receipt.done == "跑测试")
        #expect(receipt.next.contains("final acceptance"))
        #expect(receipt.remainingSeconds == nil)
        #expect(receipt.lines.count == 2)
    }

    @Test("a model receipt block is parsed leniently and refines wording only")
    func parseAndRefine() throws {
        let content = """
        Here is the receipt.
        ```receipt
        - **DONE:** 读完了 niuwo 和 sslcat 24 小时日志，26 条 error 全部归类
        NEXT — 修 sslcat 的证书续期
        ```
        ```plan
        1. x
        ```
        """
        let model = try #require(AgentPhaseReceipt.parse(from: content))
        #expect(model.done.hasPrefix("读完了"))
        #expect(model.next == "修 sslcat 的证书续期")
        #expect(model.author == .model)

        let host = AgentPhaseReceipt.synthesized(
            roadmap: roadmap(), completedIndex: 0, plan: nil,
            phaseStartedAt: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 300)
        )
        let merged = host.refined(with: model)
        #expect(merged.done == model.done)
        #expect(merged.next == model.next)
        // Timing stays the host's.
        #expect(merged.remainingSeconds == host.remainingSeconds)
        #expect(merged.author == .model)
    }

    @Test("no receipt block, or a block with neither line, parses as nil")
    func parseRejectsEmpty() {
        #expect(AgentPhaseReceipt.parse(from: "no fence here") == nil)
        #expect(AgentPhaseReceipt.parse(from: "```receipt\nhello\n```") == nil)
    }

    @Test("lines are clipped so a runaway model cannot bloat the card")
    func clipping() throws {
        let long = String(repeating: "很长", count: 300)
        let receipt = try #require(AgentPhaseReceipt.parse(from: "```receipt\nDONE: \(long)\n```"))
        #expect(receipt.done.count <= AgentPhaseReceipt.maximumLineCharacters)
        #expect(receipt.done.hasSuffix("…"))
    }

    @Test("durations read as minutes and hours")
    func durationFormat() {
        #expect(AgentPhaseReceipt.formatDuration(20) == "<1 min")
        #expect(AgentPhaseReceipt.formatDuration(1_200) == "20 min")
        #expect(AgentPhaseReceipt.formatDuration(3_600) == "1 h")
        #expect(AgentPhaseReceipt.formatDuration(5_400) == "1 h 30 min")
    }

    @Test("the resume block carries all lines inside one tagged element")
    func resumeBlock() {
        let receipt = AgentPhaseReceipt(
            done: "a", next: "b", remainingSeconds: 60,
            recordedAt: Date(timeIntervalSince1970: 0), author: .host
        )
        let block = receipt.resumeContextBlock
        #expect(block.hasPrefix("<last_phase_receipt recorded=\"1970-01-01T00:00:00Z\">"))
        #expect(block.contains("DONE: a"))
        #expect(block.contains("NEXT: b"))
        #expect(block.contains("ETA: ~1 min remaining"))
        #expect(block.hasSuffix("</last_phase_receipt>"))
    }

    /// Roadmaps persisted before the field existed must still decode.
    @Test("a persisted phase without a receipt decodes with nil")
    func phaseReceiptIsOptionalOnDecode() throws {
        let json = #"{"id":"p1","title":"t","acceptanceCriteria":[],"status":"completed"}"#
        let phase = try JSONDecoder().decode(AgentGoalRoadmap.Phase.self, from: Data(json.utf8))
        #expect(phase.receipt == nil)
    }
}
