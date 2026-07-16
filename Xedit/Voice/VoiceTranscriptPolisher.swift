//
//  VoiceTranscriptPolisher.swift
//  WillDeep
//
//  Optional AI cleanup for voice dictation. The local SenseVoice result is
//  always the source of truth; provider failures fall back to the raw text.
//

import Foundation

nonisolated enum VoiceTranscriptPolisher {
    static func polish(
        transcript: String,
        mode: VoiceTranscriptCleanupMode,
        configurations: [AgentConfiguration]
    ) async -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode.usesAI, !trimmed.isEmpty, !configurations.isEmpty else {
            return nil
        }

        let userClip = String(trimmed.prefix(6_000))
        let system = AgentMessage(role: .system, content: systemPrompt(for: mode))
        let payload = AgentMessage(
            role: .user,
            content: """
            Voice transcript:
            \(userClip)
            """
        )

        for configuration in configurations {
            let normalizedConfiguration = await MainActor.run { configuration.normalized }
            let client = await AgentClient(configuration: normalizedConfiguration)
            let collector = CompressionSummaryCollector()
            let messages = AgentLocalModelPrompting.messagesWithLanguageInstruction(
                systemPrompt: system.content,
                userMessages: [payload],
                configuration: normalizedConfiguration
            )
            do {
                try await client.streamChat(messages: messages) { event in
                    if case .textDelta(let delta) = event {
                        await collector.append(delta)
                    }
                }
                let raw = await collector.value
                if let cleaned = sanitize(raw, source: trimmed), !cleaned.isEmpty {
                    return cleaned
                }
            } catch {
                continue
            }
        }
        return nil
    }

    static func sanitize(_ raw: String, source: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        for fence in ["```text", "```markdown", "```"] {
            if text.hasPrefix(fence) {
                text = String(text.dropFirst(fence.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if text.hasSuffix("```") {
            text = String(text.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for prefix in ["整理后:", "整理后：", "Cleaned:", "Cleaned text:", "Result:", "输出:", "输出："] {
            if text.lowercased().hasPrefix(prefix.lowercased()) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        guard !text.isEmpty else { return nil }
        let maxCharacters = max(500, source.count * 3)
        guard text.count <= maxCharacters else { return nil }
        return text
    }

    private static func systemPrompt(for mode: VoiceTranscriptCleanupMode) -> String {
        switch mode {
        case .off:
            return ""
        case .punctuation:
            return """
            You clean up voice dictation for a chat composer.
            Return plain text only.
            Rules:
            - Preserve the user's language, meaning, names, commands, paths, code terms, numbers, and constraints.
            - Add punctuation, paragraph breaks, and light wording fixes only when they make the transcript easier to read.
            - Do not summarize, answer the request, add new facts, or remove requirements.
            - Keep the result close to the original length.
            """
        case .bulletPoints:
            return """
            You lightly structure voice dictation for a chat composer.
            Return plain text only.
            Rules:
            - Preserve the user's language, meaning, names, commands, paths, code terms, numbers, and constraints.
            - Do not answer the request and do not add new facts.
            - If the transcript contains multiple asks or details, organize it into 3-5 concise bullet points.
            - If it is a short single ask, return one polished sentence instead of forcing bullets.
            - Keep all actionable constraints visible.
            """
        }
    }
}
