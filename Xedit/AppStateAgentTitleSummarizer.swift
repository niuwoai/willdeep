//
//  AppStateAgentTitleSummarizer.swift
//  Xedit
//
//  Owns the "give this conversation a short title" path. Triggered
//  from `persistAgentSession` after the first user→assistant exchange
//  lands; runs one short, non-streaming-flavored chat completion on
//  `agentConfiguration.titleSummaryModel()` (falls back to flashModel)
//  and writes the result back into `session.title`.
//
//  Hard rules (also documented inline below):
//    1. Skip if `session.titleIsUserSet` — the user has named it; we
//       never overwrite a human-set title.
//    2. Skip if a summary is already in flight for this session id —
//       persistAgentSession can fire many times in one turn (every
//       tool result writes), we only need one summarization per
//       trigger.
//    3. Skip if the chat doesn't have at least one user + one finished
//       assistant message. The "finished" check matters: an assistant
//       message still in-flight has `isStreaming == true` and using
//       its (partial) content makes for garbage titles.
//    4. Skip if api key / model are missing — silent no-op, leave the
//       derived first-message-prefix title in place.
//

import Foundation

extension AppState {
    /// One-shot "summarize the chat into a short title". Caller is
    /// expected to have already gated on the conditions in the file
    /// header — this method only enforces (1) and (2). It's safe to
    /// call repeatedly: in-flight requests are tracked per session id.
    ///
    /// `force: true` bypasses both the "title already locked" gate
    /// (caller should have cleared the flag itself) and the "only on
    /// first assistant turn" gate. Used by the sidebar context-menu
    /// "Summarize with AI" item — the user wants this NOW, regardless
    /// of where the conversation is.
    @MainActor
    func summarizeAgentSessionTitleIfNeeded(runtime: AgentRuntime, force: Bool = false) {
        // Rule (1): user-named sessions are off-limits (except force).
        if !force && runtime.session.titleIsUserSet { return }

        // Rule (2): one in-flight summarization per session — applies
        // even to force, to prevent the user double-clicking the menu
        // and getting two parallel requests.
        if titleSummarizationsInFlight.contains(runtime.id) { return }

        // Rule (3) part A: need at least one user message and one
        // assistant message with non-empty content. We use the
        // runtime's messages (not session.messages — runtime is the
        // live source of truth during a turn).
        let messages = runtime.messages
        guard messages.contains(where: { !$0.userAuthoredText.isEmpty }) else { return }
        guard let lastAssistant = messages.last(where: { $0.role == .assistant }) else { return }
        let assistantText = lastAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assistantText.isEmpty else { return }

        // Rule (3) part B: only fire on the FIRST assistant turn for
        // the automatic path. After that, the prefix-of-first-user-
        // message title (which we keep updating on every persist via
        // deriveTitle) plus the LLM summary we wrote here suffices —
        // further automatic rewrites would surprise users mid-chat.
        // The user can still ask for a refresh via the sidebar menu
        // (force=true).
        let assistantCount = messages.filter { $0.role == .assistant && !$0.content.isEmpty }.count
        if !force && assistantCount != 1 { return }

        // Rule (4): need a usable provider config.
        let configuration = agentConfiguration.normalized
        let modelID = configuration.titleSummaryModel()
        guard !modelID.isEmpty else { return }
        let configurations = titleSummaryConfigurationCandidates(remoteModelID: modelID)
        guard !configurations.isEmpty else { return }

        titleSummarizationsInFlight.insert(runtime.id)

        // Distill the chat to ~one user turn + one assistant turn so
        // the title call stays cheap even if the conversation runs
        // long later (defensive — we only fire on turn 1, but if the
        // gate logic ever loosens, this keeps the prompt tight).
        let firstUser = messages.first(where: \.isOperatorInput)?.userAuthoredText ?? ""
        let firstAssistant = assistantText

        let runtimeID = runtime.id
        let prevTitle = runtime.session.title

        Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.titleSummarizationsInFlight.remove(runtimeID)
                }
            }
            let title = await Self.requestTitleSummary(
                configurations: configurations,
                firstUser: firstUser,
                firstAssistant: firstAssistant
            )
            guard let title, !title.isEmpty else { return }
            await MainActor.run {
                guard let self else { return }
                self.applyAutoSummarizedTitle(
                    runtimeID: runtimeID,
                    expectedPriorTitle: prevTitle,
                    title: title
                )
            }
        }
    }

    /// Apply an LLM-summarized title back onto the runtime + session.
    /// Re-checks `titleIsUserSet` because the user may have renamed
    /// the chat in the seconds the request was in flight — we lose
    /// that race rather than overwriting them.
    @MainActor
    private func applyAutoSummarizedTitle(
        runtimeID: UUID,
        expectedPriorTitle _: String,
        title: String
    ) {
        guard let runtime = agentRuntimes[runtimeID] else { return }
        if runtime.session.titleIsUserSet { return }

        runtime.session.title = title
        // Lock the title from now on so `AgentRuntime.persist()`
        // won't fall back to `deriveTitle(from: messages)` and stomp
        // on the polished LLM result on the next tool round. The user
        // can still override via the sidebar rename UI (which also
        // sets titleIsUserSet=true — same flag, same effect).
        runtime.session.titleIsUserSet = true
        if let index = agentSessions.firstIndex(where: { $0.id == runtimeID }) {
            agentSessions[index].title = title
            agentSessions[index].titleIsUserSet = true
        }
        AgentSessionStore.saveAsync(runtime.session)
    }

    @MainActor
    func sessionTitleSuggestionSnapshot(for runtime: AgentRuntime) async -> AgentSessionTitleSuggestionSnapshot {
        let currentTitle = runtime.session.title
        let configuration = agentConfiguration.normalized
        let modelID = configuration.titleSummaryModel()
        guard !modelID.isEmpty else {
            return AgentSessionTitleSuggestionSnapshot(currentTitle: currentTitle, suggestedTitle: nil, modelID: nil)
        }
        let configurations = titleSummaryConfigurationCandidates(remoteModelID: modelID)
        guard !configurations.isEmpty else {
            return AgentSessionTitleSuggestionSnapshot(currentTitle: currentTitle, suggestedTitle: nil, modelID: modelID)
        }

        let messages = runtime.messages.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let latestUserIndex = messages.lastIndex(where: \.isOperatorInput) else {
            return AgentSessionTitleSuggestionSnapshot(currentTitle: currentTitle, suggestedTitle: nil, modelID: modelID)
        }
        let latestUser = messages[latestUserIndex].userAuthoredText
        let nearbyAssistant = messages[..<latestUserIndex]
            .last(where: { $0.role == .assistant })?
            .content ?? messages.last(where: { $0.role == .assistant })?.content ?? ""
        let title = await Self.requestTitleSummary(
            configurations: configurations,
            firstUser: latestUser,
            firstAssistant: nearbyAssistant
        )
        return AgentSessionTitleSuggestionSnapshot(
            currentTitle: currentTitle,
            suggestedTitle: title,
            modelID: modelID
        )
    }

    /// Fire one non-streaming-flavored chat completion against the
    /// configured title model and return a cleaned-up short title, or
    /// nil if the request failed / model declined / produced garbage.
    nonisolated static func requestTitleSummary(
        configurations: [AgentConfiguration],
        firstUser: String,
        firstAssistant: String
    ) async -> String? {
        // Trim both sides to keep prompt size predictable. We intentionally
        // include just enough assistant context to disambiguate, not enough
        // for the model to start writing essays about it.
        let userClip = String(firstUser.prefix(800))
        let assistantClip = String(firstAssistant.prefix(800))

        let system = AgentMessage(
            role: .system,
            content: """
            你是一个把对话浓缩成短标题的工具。
            读取 USER 和 ASSISTANT 两段，输出**单行**标题。
            硬性要求：
            - 不超过 12 个字符（中文按字数算，英文按词数算且不超过 6 个英文词）；
            - 用户用中文则输出中文，用户用英文则输出英文；
            - 不要任何引号、前后缀、标点结尾、解释、emoji、"标题：" 之类的导言；
            - 直接输出标题本身，纯文本；
            - 抓住核心动作或主题，例如 "排查 CPU 负载"、"配置 SSH 登录"、"修复登录 bug"，避免笼统词如 "技术问题" / "帮助"。
            """
        )
        let payload = AgentMessage(
            role: .user,
            content: "USER:\n\(userClip)\n\nASSISTANT:\n\(assistantClip)"
        )

        for configuration in configurations {
            let client = await AgentClient(configuration: configuration)
            let collector = CompressionSummaryCollector()
            let messages = AgentLocalModelPrompting.messagesWithLanguageInstruction(
                systemPrompt: system.content,
                userMessages: [payload],
                configuration: configuration
            )
            do {
                try await client.streamChat(messages: messages) { event in
                    if case .textDelta(let delta) = event {
                        await collector.append(delta)
                    }
                }
                let raw = await collector.value
                if let title = Self.sanitizeAutoTitle(raw), !title.isEmpty {
                    return title
                }
            } catch {
                continue
            }
        }
        return nil
    }

    /// Defensive cleanup on whatever the model returned. Strip
    /// surrounding quotes / asterisks / "Title:" prefixes / trailing
    /// punctuation / newlines, then enforce a hard char cap. Returns
    /// nil for empty / suspiciously-long-and-uncleanable results.
    nonisolated static func sanitizeAutoTitle(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // First newline-separated line only (model occasionally adds a
        // second "(based on …)" line despite the prompt).
        if let newlineIndex = s.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            s = String(s[..<newlineIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Drop leading "Title:" / "标题：" prefix variants.
        let lowered = s.lowercased()
        for prefix in ["title:", "title：", "标题:", "标题:", "标题：", "title ", "标题 "] {
            if lowered.hasPrefix(prefix.lowercased()) {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        // Strip matching outer quotes/backticks/asterisks (one pass).
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("`", "`"), ("“", "”"), ("‘", "’"), ("「", "」"), ("『", "』"), ("【", "】"), ("*", "*"), ("_", "_")]
        if let first = s.first, let last = s.last, first != last || s.count >= 2 {
            for (open, close) in quotePairs where s.first == open && s.last == close && s.count >= 2 {
                s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        // Trailing punctuation: 。.!?！？,，;；:：
        while let last = s.last, "。.!?！？,，;；:：".contains(last) {
            s.removeLast()
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Hard char cap (defensive — prompt says ≤12 but models lie).
        // Use Character count so CJK 一字符算一格。
        let maxChars = 24
        if s.count > maxChars {
            s = String(s.prefix(maxChars)) + "…"
        }
        return s
    }
}
