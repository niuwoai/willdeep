//
//  AgentInputSuggestion.swift
//  WillDeep
//
//  回合结束后预测用户下一句要说什么，以灰字显示在空输入框里，按 Tab 采用。
//
//  这里只放纯逻辑：挑上下文、拼提示词、清洗模型输出。触发、落到 runtime、
//  取消都在 AppStateAgentInputSuggestion.swift；输入框的绘制与 Tab 在
//  ComposerTextInput.swift。
//
//  判定刻意保守：拿不准就不给。一条猜错的建议只是多一行灰字，但一条像
//  Agent 口吻的建议（"好的，我来帮你…"）被用户 Tab 进去发出去，就是在
//  替用户说话。
//

import Foundation

nonisolated enum AgentInputSuggestion {
    /// 超过这个长度的建议不再是「下一句」，而是替用户写需求，直接丢。
    static let maxCharacters = 120
    /// 最近几条用户原话用来学语气和语言；再多只会让小模型抓错重点。
    static let recentUserMessageLimit = 2
    static let userMessageClip = 400
    /// 助手回复取**结尾**：结论、「要不要我继续…」这类问句都在最后。
    static let assistantTailClip = 1500
    /// 模型认为没有明显下一步时输出的哨兵。
    static let noSuggestionSentinel = "NONE"

    struct Turn: Equatable, Sendable {
        let isUser: Bool
        let text: String
    }

    static let systemPrompt = """
    You predict what the USER will type next in a chat with a coding / ops assistant.
    Read the recent USER messages and the ASSISTANT's latest reply, then output the single most likely next USER message.
    Rules:
    - Write as the user, addressed to the assistant: a short instruction or question (e.g. "继续", "提交并合回 develop", "run the tests").
    - Use the same language the user writes in.
    - One line, at most 60 characters. No quotes, no prefixes like "User:", no explanation.
    - If the assistant asked a yes/no question, answer it the way the user most likely would.
    - Never write in the assistant's voice (no "好的，我来…", "Sure, I will…").
    - If there is no obvious next step, output exactly NONE.
    """

    /// 拼给预测模型的上下文。没有用户原话或助手回复为空时返回 nil，不发请求。
    static func payload(from turns: [Turn]) -> String? {
        guard let lastAssistantIndex = turns.lastIndex(where: {
            !$0.isUser && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        let users = turns[..<lastAssistantIndex]
            .filter { $0.isUser }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(recentUserMessageLimit)
        guard !users.isEmpty else { return nil }
        let assistant = turns[lastAssistantIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let userBlock = users
            .map { "USER:\n\(String($0.prefix(userMessageClip)))" }
            .joined(separator: "\n\n")
        return "\(userBlock)\n\nASSISTANT (latest reply, tail):\n\(String(assistant.suffix(assistantTailClip)))"
    }

    private static let labelPrefixes = [
        "user:", "user：", "用户:", "用户：", "next:", "next：", "下一句:", "下一句：", "建议:", "建议：", "suggestion:"
    ]
    private static let assistantVoicePrefixes = [
        "好的，我", "好的,我", "我来", "我会", "我将", "sure, i", "sure i", "okay, i", "ok, i", "i will", "i'll", "let me"
    ]
    private static let wrappingCharacters = CharacterSet(charactersIn: "\"'`“”‘’「」『』*")

    /// 清洗模型输出。不像用户下一句的一律返回 nil。
    static func sanitize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let newline = text.range(of: "\n", options: .literal) {
            text = String(text[..<newline.lowerBound])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        if let prefix = labelPrefixes.first(where: { lowered.hasPrefix($0) }) {
            text = String(text.dropFirst(prefix.count))
        }
        text = text.trimmingCharacters(in: wrappingCharacters.union(.whitespacesAndNewlines))
        guard !text.isEmpty, text.count <= maxCharacters else { return nil }
        guard text.uppercased() != noSuggestionSentinel else { return nil }
        let normalized = text.lowercased()
        guard !assistantVoicePrefixes.contains(where: { normalized.hasPrefix($0) }) else { return nil }
        return text
    }

    /// 依次试候选配置（本地模型优先），第一条清洗后可用的建议即返回。
    static func request(
        configurations: [AgentConfiguration],
        payload: String
    ) async -> (suggestion: String?, records: [AgentAuxiliaryModelRequestRecord]) {
        var records: [AgentAuxiliaryModelRequestRecord] = []
        for configuration in configurations {
            if Task.isCancelled { break }
            let client = await AgentClient(configuration: configuration)
            let collector = CompressionSummaryCollector()
            let measurement = AgentAuxiliaryRequestMeasurement()
            let messages = AgentLocalModelPrompting.messagesWithLanguageInstruction(
                systemPrompt: systemPrompt,
                userMessages: [AgentMessage(role: .user, content: payload)],
                configuration: configuration
            )
            var succeeded = true
            do {
                try await client.streamChat(messages: messages) { event in
                    await measurement.consume(event)
                    if case .textDelta(let delta) = event {
                        await collector.append(delta)
                    }
                }
            } catch {
                succeeded = false
            }
            records.append(await measurement.record(
                purpose: .inputSuggestion,
                providerID: configuration.providerID,
                modelID: configuration.model,
                isLocal: AgentLocalModelPrompting.isLocalProvider(configuration),
                succeeded: succeeded
            ))
            guard succeeded else { continue }
            // 模型明确说「没有下一步」也是有效答案，不再换下一个候选重问。
            return (sanitize(await collector.value), records)
        }
        return (nil, records)
    }
}
