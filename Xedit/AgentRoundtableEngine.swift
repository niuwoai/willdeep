//
//  AgentRoundtableEngine.swift
//  WillDeep
//
//  专家圆桌的编排引擎。仿 `AgentConsultationEngine.runGroupChat` 的三段式
//  (导播开场 → 多轮串行专家 → 综合),但:
//   - 专家是主模型扮演的领域角色(`AgentSubagentRunner.run`),不是外部 CLI;
//   - 不绑工作区(workspaceURL: nil);
//   - 多了「AI 推荐专家」前置步骤和「导播收敛判定」;
//   - 专家发言强制结构化输出(OSR),喂态势看板;
//   - 收敛后产出一份 Markdown 文档。
//
//  所有状态变更走 `mutate` → `updateWorkflowReport` + `persistWorkflowRuntime`,
//  复用会诊的落盘链路(WorkflowReport.roundtable 载体)。
//

import Foundation

enum AgentRoundtableError: LocalizedError {
    case reportUnavailable
    case emptyChairOutput
    case recommendationFailed
    case allExpertsFailed

    var errorDescription: String? {
        switch self {
        case .reportUnavailable: return "圆桌报告不可用。"
        case .emptyChairOutput: return "主持人未产出内容。"
        case .recommendationFailed: return "未能推荐出合适的专家，请调整议题后重试。"
        case .allExpertsFailed: return "本轮所有专家都未能发言。"
        }
    }
}

@MainActor
final class AgentRoundtableEngine {
    let reportID: UUID
    let runtimeID: UUID
    let configuration: AgentConfiguration
    let someIMContext: SomeIMRequestContext?
    weak var appState: AppState?

    init(
        reportID: UUID,
        runtimeID: UUID,
        configuration: AgentConfiguration,
        someIMContext: SomeIMRequestContext?,
        appState: AppState
    ) {
        self.reportID = reportID
        self.runtimeID = runtimeID
        self.configuration = configuration
        self.someIMContext = someIMContext
        self.appState = appState
    }

    // MARK: - 主流程

    /// 单次驱动的结果:要么在专家反问处暂停等主持人答复,要么收敛出终稿。
    enum RunResult: Equatable {
        case awaitingUser
        case completed(String)
    }

    /// 从当前状态往下推进到下一个暂停点或终稿。每个阶段都按落盘状态幂等,
    /// 支持「专家反问 → 暂停 → 主持人答复 → 续跑」反复驱动同一场圆桌。
    func run() async throws -> RunResult {
        try await ensureRecommendedAndOpened()
        if try await discuss() == .awaitingUser {
            return .awaitingUser
        }
        return .completed(try await synthesize())
    }

    /// 推荐专家 + 导播开场,均幂等:已推荐/已开场则跳过(续跑不重复)。
    private func ensureRecommendedAndOpened() async throws {
        var report = try requireReport()

        if report.experts.isEmpty {
            setPhase(.recommending)
            let payload = try await recommend(topic: report.topic)
            mutate {
                $0.experts = payload.resolvedExperts
                if !payload.title.isEmpty { $0.title = payload.title }
            }
            report = try requireReport()
        }

        guard !report.experts.isEmpty else {
            throw AgentRoundtableError.recommendationFailed
        }

        // 开场只做一次:round 0 的导播消息已存在则跳过。
        if !hasChairMessage(round: 0) {
            setPhase(.opening)
            let opening = try await runChair(
                AgentRoundtablePromptBuilder.opening(topic: report.topic, experts: report.experts)
            )
            appendMessage(.init(speaker: .chair, round: 0, content: opening))
        }
    }

    private enum DiscussOutcome { case awaitingUser, finished }

    /// 多轮讨论,可从任意暂停点续跑。收敛或达轮数上限即结束;专家反问则
    /// 暂停到 .awaitingUser 等主持人答复。
    private func discuss() async throws -> DiscussOutcome {
        if try requireReport().converged { return .finished }

        for round in 1...AgentRoundtableReport.maxRounds {
            try Task.checkCancellation()
            // 已出过轮末小结的轮次 = 已完整处理,续跑时跳过。
            if hasChairMessage(round: round) { continue }

            let report = try requireReport()
            mutate {
                $0.phase = .discussing
                $0.currentRound = round
            }

            // 本轮已发言(含失败)的专家不再重复;续跑时只补剩下的。
            let spoken = spokenRoles(inRound: round)
            for role in report.experts where !spoken.contains(role) {
                try Task.checkCancellation()
                let transcript = AgentRoundtablePromptBuilder.transcript(currentMessages())
                mutate { $0.activeExpert = role }
                do {
                    let payload = try await runExpert(topic: report.topic, role: role, round: round, transcript: transcript)
                    appendMessage(.init(
                        speaker: .expert,
                        role: role,
                        round: round,
                        content: payload.speaking,
                        osr: payload.toOSR(),
                        pendingUserOptions: payload.asksUser ? payload.resolvedUserOptions : nil
                    ))
                    mutate { $0.activeExpert = nil }
                    // 专家发起反问:暂停讨论,交回给主持人答复后再续跑。
                    if payload.asksUser {
                        setPhase(.awaitingUser)
                        return .awaitingUser
                    }
                } catch is CancellationError {
                    mutate { $0.activeExpert = nil }
                    throw CancellationError()
                } catch {
                    mutate { $0.activeExpert = nil }
                    appendMessage(.init(
                        speaker: .expert,
                        role: role,
                        round: round,
                        content: error.localizedDescription,
                        isError: true
                    ))
                }
            }

            // 本轮全败保护(照会诊):不让终稿基于失败噪声下结论。
            if successfulExpertCount(inRound: round) == 0 {
                throw AgentRoundtableError.allExpertsFailed
            }

            // 轮末导播小结 + 收敛判定。
            let moderation = try await moderate(
                topic: report.topic,
                round: round,
                transcript: AgentRoundtablePromptBuilder.transcript(currentMessages())
            )
            appendMessage(.init(speaker: .chair, round: round, content: moderation.summary))
            if moderation.converged {
                mutate { $0.converged = true }
                break
            }
        }
        return .finished
    }

    /// 生成终稿文档。已有终稿则直接返回(幂等,续跑不重复生成)。
    private func synthesize() async throws -> String {
        let report = try requireReport()
        if let existing = report.finalDocument, !existing.isEmpty {
            if report.phase != .completed { mutate { $0.phase = .completed } }
            return existing
        }
        setPhase(.synthesizing)
        mutate { $0.activeExpert = nil }
        let rawDocument = try await runChair(
            AgentRoundtablePromptBuilder.finalDocument(
                topic: report.topic,
                transcript: AgentRoundtablePromptBuilder.transcript(currentMessages(), excludeErrors: true)
            )
        )
        let document = AgentRoundtableDocumentNormalizer.normalize(rawDocument)
        guard !document.isEmpty else {
            throw AgentRoundtableError.emptyChairOutput
        }
        mutate {
            $0.finalDocument = document
            $0.finalDocumentFilePath = nil
            $0.finalDocumentWriteError = nil
            $0.phase = .completed
        }
        return document
    }

    // MARK: - 单步 LLM 调用（都走主模型）

    /// 主持人/导播的一次性文本调用。仿会诊 runChair:空输出重试一次。
    private func runChair(_ prompt: String) async throws -> String {
        for _ in 1...2 {
            try Task.checkCancellation()
            let outcome = try await AgentSubagentRunner.run(
                prompt: prompt,
                configuration: configuration,
                workspaceURL: nil,
                someIMContext: someIMContext
            )
            let output = outcome.report.trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty {
                return String(output.prefix(AgentRoundtablePromptBuilder.maxSectionCharacters))
            }
        }
        throw AgentRoundtableError.emptyChairOutput
    }

    /// 推荐专家:结构化调用 + 解析兜底。
    private func recommend(topic: String) async throws -> RoundtableRecommendationPayload {
        let outcome = try await AgentSubagentRunner.run(
            prompt: AgentRoundtablePromptBuilder.recommendExperts(topic: topic),
            configuration: configuration,
            workspaceURL: nil,
            someIMContext: someIMContext,
            outputSchema: AgentRoundtablePromptBuilder.recommendSchema
        )
        guard let payload = Self.decodeRecommendation(outcome.report), payload.isValid else {
            throw AgentRoundtableError.recommendationFailed
        }
        return payload
    }

    /// 专家发言:结构化调用(拿 OSR + speaking)+ 解析兜底。
    private func runExpert(
        topic: String,
        role: AgentRoundtableExpertRole,
        round: Int,
        transcript: String
    ) async throws -> RoundtableExpertPayload {
        try Task.checkCancellation()
        let outcome = try await AgentSubagentRunner.run(
            prompt: AgentRoundtablePromptBuilder.expertTurn(topic: topic, role: role, round: round, transcript: transcript),
            configuration: configuration,
            workspaceURL: nil,
            someIMContext: someIMContext,
            outputSchema: RoundtableOSR.outputSchema
        )
        guard let payload = Self.decodeExpert(outcome.report), payload.isValid else {
            throw AgentRoundtableError.emptyChairOutput
        }
        return payload
    }

    /// 导播小结 + 收敛判定。解析失败时兜底为「未收敛」，让讨论继续。
    private func moderate(
        topic: String,
        round: Int,
        transcript: String
    ) async throws -> RoundtableModerationPayload {
        let outcome = try await AgentSubagentRunner.run(
            prompt: AgentRoundtablePromptBuilder.moderatorTurn(topic: topic, round: round, transcript: transcript),
            configuration: configuration,
            workspaceURL: nil,
            someIMContext: someIMContext,
            outputSchema: AgentRoundtablePromptBuilder.moderationSchema
        )
        if let payload = Self.decodeModeration(outcome.report), payload.isValid {
            return payload
        }
        // 解析失败:用原始文本当小结,判为未收敛(靠轮数上限兜底)。
        let fallback = outcome.report.trimmingCharacters(in: .whitespacesAndNewlines)
        return RoundtableModerationPayload(
            summary: fallback.isEmpty ? "本轮讨论继续。" : String(fallback.prefix(2_000)),
            converged: false
        )
    }

    // MARK: - 解析层（分层兜底，吸取 think 标签泄漏教训）

    /// 从可能夹带 markdown 代码围栏 / 前后噪声的文本里抠出 JSON 再解码。
    nonisolated static func decodeExpert(_ raw: String) -> RoundtableExpertPayload? {
        decodeJSON(raw, as: RoundtableExpertPayload.self)
    }

    nonisolated static func decodeRecommendation(_ raw: String) -> RoundtableRecommendationPayload? {
        decodeJSON(raw, as: RoundtableRecommendationPayload.self)
    }

    nonisolated static func decodeModeration(_ raw: String) -> RoundtableModerationPayload? {
        decodeJSON(raw, as: RoundtableModerationPayload.self)
    }

    /// 分层解码:先直接解,失败则剥掉 ```json 围栏和首尾噪声,截取第一个
    /// 平衡的 `{...}` 再解。主模型走 outputSchema 时通常是干净 JSON,这层
    /// 兜底应对偶发夹带。
    nonisolated static func decodeJSON<T: Decodable>(_ raw: String, as type: T.Type) -> T? {
        let decoder = JSONDecoder()
        if let data = raw.data(using: .utf8), let value = try? decoder.decode(T.self, from: data) {
            return value
        }
        guard let extracted = extractJSONObject(raw),
              let data = extracted.data(using: .utf8),
              let value = try? decoder.decode(T.self, from: data) else {
            return nil
        }
        return value
    }

    /// 从文本里截出第一个括号平衡的 JSON object 子串。
    nonisolated static func extractJSONObject(_ raw: String) -> String? {
        var stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 剥 ```json ... ``` 围栏。
        if stripped.hasPrefix("```") {
            if let firstNewline = stripped.firstIndex(of: "\n") {
                stripped = String(stripped[stripped.index(after: firstNewline)...])
            }
            if let fence = stripped.range(of: "```", options: .backwards) {
                stripped = String(stripped[..<fence.lowerBound])
            }
        }
        guard let start = stripped.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < stripped.endIndex {
            let ch = stripped[index]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(stripped[start...index])
                    }
                }
            }
            index = stripped.index(after: index)
        }
        return nil
    }

    // MARK: - 状态与落盘

    private var currentReport: AgentRoundtableReport? {
        appState?.workflowReport(id: reportID, runtimeID: runtimeID)?.roundtable
    }

    private func requireReport() throws -> AgentRoundtableReport {
        guard let currentReport else { throw AgentRoundtableError.reportUnavailable }
        return currentReport
    }

    private func currentMessages() -> [RoundtableMessage] {
        currentReport?.messages ?? []
    }

    /// 某一轮是否已有导播消息(round 0 = 开场,round ≥ 1 = 轮末小结)。
    /// 幂等续跑靠它判断阶段是否已完成。
    private func hasChairMessage(round: Int) -> Bool {
        currentMessages().contains { $0.speaker == .chair && $0.round == round }
    }

    /// 某一轮已经发过言(含失败)的专家角色集合,续跑时用来跳过。
    private func spokenRoles(inRound round: Int) -> Set<AgentRoundtableExpertRole> {
        Set(currentMessages()
            .filter { $0.speaker == .expert && $0.round == round }
            .compactMap(\.role))
    }

    /// 某一轮成功发言(非失败)的专家条数,用于本轮全败保护。
    private func successfulExpertCount(inRound round: Int) -> Int {
        currentMessages().filter {
            $0.speaker == .expert && $0.round == round && $0.isError != true
        }.count
    }

    private func setPhase(_ phase: AgentRoundtableReport.Phase) {
        mutate { $0.phase = phase }
    }

    private func appendMessage(_ message: RoundtableMessage) {
        mutate { $0.messages.append(message) }
    }

    private func mutate(_ mutation: (inout AgentRoundtableReport) -> Void) {
        appState?.updateWorkflowReport(id: reportID, runtimeID: runtimeID) { report in
            guard var roundtable = report.roundtable else { return }
            mutation(&roundtable)
            roundtable.updatedAt = Date()
            report.roundtable = roundtable
        }
        appState?.persistWorkflowRuntime(runtimeID: runtimeID)
    }
}
