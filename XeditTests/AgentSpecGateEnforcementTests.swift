//
//  AgentSpecGateEnforcementTests.swift
//  WillDeepTests
//

import Foundation
import Testing

@testable import WillDeep

@Suite("Spec gate 阻断与恢复")
nonisolated struct AgentSpecGateEnforcementTests {
    // MARK: - 状态机

    @Test("只有等文档和等回答两个状态拦人")
    func onlyPendingStatesBlock() {
        #expect(AgentSpecGateState.awaitingDocument.blocksExecution)
        #expect(AgentSpecGateState.awaitingUserReview.blocksExecution)
        #expect(AgentSpecGateState.inactive.blocksExecution == false)
        #expect(AgentSpecGateState.released.blocksExecution == false)
    }

    /// 门只拦写入类工具。文件工具是 read 档，所以模型仍然写得了那份
    /// 设计文档——门要的就是这个。
    @Test("拦的是写入和危险档，不拦只读")
    func blocksOnlyWriteTier() {
        #expect(AgentExecutionIntentPolicy.blocksExecution(risk: .write))
        #expect(AgentExecutionIntentPolicy.blocksExecution(risk: .danger))
        #expect(AgentExecutionIntentPolicy.blocksExecution(risk: .read) == false)
        #expect(AgentExecutionIntentPolicy.blocksExecution(risk: .userInput) == false)
    }

    @Test("两个拦人的状态各有各的提示词，不共用一段")
    func promptBlockDiffersByState() {
        let waiting = AgentSpecGateState.awaitingDocument.systemPromptBlock
        let review = AgentSpecGateState.awaitingUserReview.systemPromptBlock
        #expect(waiting != nil)
        #expect(review != nil)
        #expect(waiting != review)
        #expect(AgentSpecGateState.inactive.systemPromptBlock == nil)
        #expect(AgentSpecGateState.released.systemPromptBlock == nil)
    }

    /// 提示词必须明确说「别问审批」。这个门的回答在卡片上，模型跑去
    /// 问用户「要我继续吗」就把两条决策路径搅在一起了。
    @Test("提示词要求写文档、停下、且不要索要审批")
    func promptTellsModelWhatToDo() throws {
        let block = try #require(AgentSpecGateState.awaitingDocument.systemPromptBlock)
        #expect(block.contains("docs/"))
        #expect(block.contains("SCREAMING_SNAKE_CASE"))
        #expect(block.lowercased().contains("do not ask for approval"))
        #expect(block.lowercased().contains("do not begin implementing"))
    }

    // MARK: - 容错解码

    /// 旧版本读到没见过的状态值时必须降级，而不是抛错。合成的 Codable
    /// 会抛，而一个解码失败的会话不是退化，是从侧边栏消失。
    @Test("未知状态值降级为未激活，不抛错")
    func unknownStateDecodesToInactive() throws {
        let data = Data("\"someFutureState\"".utf8)
        let decoded = try JSONDecoder().decode(AgentSpecGateState.self, from: data)
        #expect(decoded == .inactive)
    }

    @Test("未知用户选择降级为待定")
    func unknownChoiceDecodesToDeferred() throws {
        let data = Data("\"maybe\"".utf8)
        let decoded = try JSONDecoder().decode(AgentSpecProposalChoice.self, from: data)
        #expect(decoded == .deferred)
    }

    @Test("提案编解码往返相等")
    func proposalRoundTrips() throws {
        let proposal = AgentSpecProposal(
            documentPath: "docs/FOO_DESIGN.md",
            signals: [AgentSpecGateSignal(kind: .newSubsystem, evidence: "新增一个子系统")],
            choice: .accepted
        )
        let data = try JSONEncoder().encode(proposal)
        let decoded = try JSONDecoder().decode(AgentSpecProposal.self, from: data)
        #expect(decoded == proposal)
    }

    // MARK: - 文档合格判定

    @Test("docs 下的大写下划线 md 才算数")
    func qualifyingDocumentPaths() {
        #expect(AgentSpecGateDocument.qualifies(path: "docs/FOO_DESIGN.md"))
        #expect(AgentSpecGateDocument.qualifies(path: "docs/SPEC_FIRST_GATE_DESIGN.md"))
        #expect(AgentSpecGateDocument.qualifies(path: "docs/A1_B2.md"))
    }

    /// 写到别处、写成小写、写进子目录、或者根本不是 md，都不是这个门
    /// 在等的东西。判据是规则不是文件名白名单——名字由模型起。
    @Test("其余写法一律不算")
    func nonQualifyingDocumentPaths() {
        #expect(AgentSpecGateDocument.qualifies(path: "docs/notes.md") == false)
        #expect(AgentSpecGateDocument.qualifies(path: "docs/design/FOO.md") == false)
        #expect(AgentSpecGateDocument.qualifies(path: "FOO_DESIGN.md") == false)
        #expect(AgentSpecGateDocument.qualifies(path: "src/FOO_DESIGN.md") == false)
        #expect(AgentSpecGateDocument.qualifies(path: "docs/FOO_DESIGN.txt") == false)
        #expect(AgentSpecGateDocument.qualifies(path: "docs/.md") == false)
        #expect(AgentSpecGateDocument.qualifies(path: "") == false)
    }

    // MARK: - 判官

    @Test("判官只能降级，且含糊不算数")
    func judgeNeedsConfidenceToRelease() {
        let sure = AgentSpecGateJudgeVerdict(isLocalChange: true, confidence: 0.9, reason: "")
        let unsure = AgentSpecGateJudgeVerdict(isLocalChange: true, confidence: 0.3, reason: "")
        let disagrees = AgentSpecGateJudgeVerdict(isLocalChange: false, confidence: 0.95, reason: "")
        #expect(sure.releasesGate)
        #expect(unsure.releasesGate == false)
        #expect(disagrees.releasesGate == false)
    }

    @Test("判官预算按推理加结论给，且超时同步抬")
    func judgeBudgetsForReasoning() {
        // 384 是现役路由判官的额度，它能用是因为强制关了思考。这个判官
        // 可能跑在用户自带的推理模型上，照抄那个数字就会复现审批裁判
        // 那次「越复杂越容易掉线」的事故。
        #expect(AgentSpecGateJudge.maxTokens >= 4096)
        #expect(AgentSpecGateJudge.timeout >= 15)
    }

    @Test("缺字段的裁决不算通过")
    func malformedVerdictIsRejected() {
        #expect(AgentSpecGateJudge.decodeVerdict(fromRaw: "{}") == nil)
        #expect(AgentSpecGateJudge.decodeVerdict(fromRaw: "not json") == nil)
        #expect(AgentSpecGateJudge.decodeVerdict(fromRaw: "{\"confidence\":0.9}") == nil)
    }

    /// 置信度缺失要当成没把握，不能当成满把握——它唯一能推动的方向是
    /// 不拦人，所以含糊不能帮它。
    @Test("裁决缺置信度按零算，不足以放行")
    func missingConfidenceCountsAsZero() throws {
        let verdict = try #require(
            AgentSpecGateJudge.decodeVerdict(fromRaw: "{\"local_change\":true}")
        )
        #expect(verdict.confidence == 0)
        #expect(verdict.releasesGate == false)
    }

    @Test("裹在解释里的 JSON 也能取出来")
    func extractsJSONFromChatter() throws {
        let raw = "我看了一下。\n{\"local_change\":true,\"confidence\":0.8,\"reason\":\"改一行\"}\n就这样。"
        let verdict = try #require(AgentSpecGateJudge.decodeVerdict(fromRaw: raw))
        #expect(verdict.isLocalChange)
        #expect(verdict.releasesGate)
    }

    @Test("判官载荷带上宿主信号但不带路径")
    func payloadCarriesSignalsOnly() {
        let payload = AgentSpecGateJudge.encodePayload(
            requestText: "重构 /Users/someone/secret/path 那块",
            signals: [AgentSpecGateSignal(kind: .crossModuleKeywords, evidence: "重构")]
        )
        #expect(payload.contains("host_signals"))
        #expect(payload.contains("crossModuleKeywords"))
    }

    @Test("判官不答就 fail-open，答了没通过才拦")
    func judgeFailureFailsOpen() async {
        let verdict = await AgentSpecGateJudge.review(
            requestText: "新增一个子系统",
            signals: [AgentSpecGateSignal(kind: .newSubsystem, evidence: "新增一个子系统")],
            timeout: 0.2
        ) { _, _, _ in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return "{\"local_change\":true,\"confidence\":1}"
        }
        #expect(verdict == nil)
    }

    // MARK: - 裁决原因码

    /// 「没判官可问」不是失败，是很多用户的常态。把它当失败会让整个门
    /// 对这批人静默失效。
    @Test("没有判官与判官失败是两个原因码")
    func unconfiguredIsNotUnavailable() {
        #expect(AgentSpecGateVerdict.Reason.judgeUnconfigured != AgentSpecGateVerdict.Reason.judgeUnavailable)
        let unconfigured = AgentSpecGateVerdict(outcome: .gate, reason: .judgeUnconfigured, signals: [])
        #expect(unconfigured.wouldGate)
    }

    @Test("用户跳过是误报口径")
    func dismissalIsTheFalsePositiveSignal() {
        let verdict = AgentSpecGateVerdict.proceed(.userOptedOut)
        #expect(verdict.outcome == .proceed)
        #expect(verdict.wouldGate == false)
    }
}
