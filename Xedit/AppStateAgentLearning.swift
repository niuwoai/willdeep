//
//  AppStateAgentLearning.swift
//  WillDeep
//
//  Agent turn-end memory and skill learning helpers.
//

import Foundation

extension AppState {
    static func memoryRetrievalQuery(
        messages: [AgentMessage],
        openedFileURL: URL?,
        selectedText: String
    ) -> String {
        let recentUserText = messages
            .reversed()
            .filter { $0.role == .user }
            .prefix(3)
            .map(\.modelContent)
            .reversed()
            .joined(separator: "\n\n")
        return [
            recentUserText,
            openedFileURL?.path ?? "",
            selectedText
        ]
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func buildTurnRecallSnapshot(
        query: String,
        retrievedMemories: [AgentMemoryRetrievalResult],
        attachedSkills: [AgentSkillEntry],
        createdAt: Date = Date()
    ) -> AgentTurnRecallSnapshot? {
        var items: [AgentTurnRecallItem] = retrievedMemories.map { result in
            AgentTurnRecallItem(
                kind: .memory,
                title: oneLine(result.record.content, limit: 140),
                detail: result.record.scope == .project ? "Project memory" : "Global memory",
                score: result.score,
                reasons: result.reasons
            )
        }
        items.append(contentsOf: attachedSkills.map { skill in
            AgentTurnRecallItem(
                kind: .skill,
                title: skill.identifier,
                detail: oneLine(skill.description, limit: 160),
                reasons: ["Attached via $skill for this turn."]
            )
        })
        guard !items.isEmpty else { return nil }
        return AgentTurnRecallSnapshot(
            createdAt: createdAt,
            query: query,
            items: items
        )
    }

    func captureTurnEndLearning(
        for runtime: AgentRuntime,
        memoryState: AgentMemoryState,
        workspaceURL: URL?
    ) {
        var events = captureAutomaticMemories(
            for: runtime,
            memoryState: memoryState,
            workspaceURL: workspaceURL
        )
        events.append(contentsOf: AgentSelfLearning.captureAutomaticMCPCapabilityGap(
            for: runtime,
            memoryState: memoryState,
            workspaceURL: workspaceURL
        ))
        events.append(contentsOf: AgentSelfLearning.captureAutomaticSkillCandidate(
            for: runtime,
            workspaceURL: workspaceURL
        ))
        // Cross-link each learning event back to the recall hits that
        // influenced this turn, so the audit trail can say "this
        // suggestion relates to these recalled memories / attached skills"
        // — not just "it came from a tool sequence". Recall was captured
        // early in the turn (see runAgentLoop), so `latestTurnRecall` is
        // populated by the time this turn-end pass runs.
        let recall = runtime.latestTurnRecall
        events = events.map { event in
            var enriched = event
            let links = AgentSelfLearning.relatedRecallLinks(for: event, in: recall)
            enriched.relatedRecall = links.isEmpty ? nil : links
            return enriched
        }
        appendAgentLearningEvents(events, to: runtime)
    }

    private func captureAutomaticMemories(
        for runtime: AgentRuntime,
        memoryState: AgentMemoryState,
        workspaceURL: URL?
    ) -> [AgentLearningEvent] {
        guard memoryState.settings.normalized.isMemoryEnabled,
              memoryState.settings.normalized.autoSummaryEnabled,
              let latestUser = runtime.messages.last(where: { $0.isOperatorInput }),
              runtime.messages.contains(where: {
                  $0.role == .assistant
                      && $0.createdAt >= latestUser.createdAt
                      && !$0.modelContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            return []
        }
        // 1.85.0-rc16:不再调 `memoryState.addAutomaticMemories(...)` 直接
        // 落盘;改用 `AgentMemoryEngine.candidates(...)` 拿候选(同一份
        // 抽取逻辑),拍成 [AgentMemoryDraft] 挂到 LearningEvent 上,等用户
        // 在 popover 里按 Approve 才真正写入。详见 [AgentMemoryDraft](Xedit/AgentSelfLearning.swift)
        // + [AppState.applyAgentMemoryDrafts](Xedit/AppStateAgentLearning.swift)。
        // 1.195.0-rc12:候选只从用户原话里挖。assistant 文本里
        // "use X / should / 自动"这类词天天出现，之前连回复里的表格行
        // （"数据库自动运维"命中"自动"）都会被拍成记忆建议。
        let candidates = AgentMemoryEngine.candidates(
            fromUser: latestUser.modelContent,
            rootDirectory: workspaceURL,
            now: Date()
        )
        guard !candidates.isEmpty else { return [] }
        let drafts = candidates.map { record in
            AgentMemoryDraft(
                content: record.content,
                scopeRaw: record.scope.rawValue,
                lifetimeRaw: record.lifetime.rawValue,
                rootDirectoryPath: record.scope == .project ? workspaceURL?.path : nil
            )
        }
        return [
            AgentLearningEvent(
                kind: .memory,
                status: .suggested,
                title: L10n.Transcript.learningEventTitleSuggestedMemories(String(drafts.count)),
                detail: AgentLearningActionPresentation.memorySuggestionDetail(for: drafts),
                action: AgentLearningAction(
                    kind: .saveMemory,
                    commandName: "add_memory",
                    target: workspaceURL == nil
                        ? L10n.Transcript.learningTargetGlobalMemory
                        : L10n.Transcript.learningTargetProjectMemory,
                    reason: L10n.Transcript.learningReasonConversationContext,
                    nextStep: L10n.Transcript.learningNextStepApprovePopover,
                    requiresUserConfirmation: true
                ),
                memoryDrafts: drafts
            )
        ]
    }

    /// 1.85.0-rc16:popover 里的 Approve 按钮 → 把一个 LearningEvent 上
    /// 攒着的所有 `AgentMemoryDraft` 真正写入 memory store,然后把对应
    /// review item 标 `.reviewed`。返回实际写入的条数。
    ///
    /// `AgentMemoryState` 构造时从 UserDefaults 加载;`memories` 数组有
    /// `didSet` 自动落盘,所以这里只需 addMemory 然后让 state 走出作用
    /// 域即可,不需要显式 persist。
    @discardableResult
    func applyAgentMemoryDrafts(for event: AgentLearningEvent) -> Int {
        let drafts = event.pendingMemoryDrafts
        guard !drafts.isEmpty else { return 0 }
        let memoryState = AgentMemoryState()
        for draft in drafts {
            memoryState.addMemory(
                content: draft.content,
                source: .automatic,
                lifetime: draft.lifetime,
                scope: draft.scope,
                rootDirectory: draft.rootDirectoryURL
            )
        }
        memoryState.mergeDuplicateMemories()
        // 把该事件在所有 runtime 里的 status / drafts 都更新一次,popover
        // 重渲染时 Approve 按钮就消失,避免被重复 Approve。
        for runtime in agentRuntimes.values {
            if let idx = runtime.learningEvents.firstIndex(where: { $0.id == event.id }) {
                runtime.learningEvents[idx].status = .saved
                runtime.learningEvents[idx].memoryDrafts = nil
            }
        }
        AgentLearningReviewStore.mark(id: event.id, decision: .reviewed)
        return drafts.count
    }

    private func appendAgentLearningEvents(_ events: [AgentLearningEvent], to runtime: AgentRuntime) {
        let meaningfulEvents = events.filter {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // 同一会话里重复的建议（同 kind/标题/内容）不再二次入列——回合末
        // 自动扫描每轮都跑，没有这道闸同一条 MCP 建议会反复弹 popover。
        let freshEvents = AgentSelfLearning.dedupedNewEvents(
            meaningfulEvents,
            existing: runtime.learningEvents
        )
        guard !freshEvents.isEmpty else { return }
        runtime.learningEvents = Array((freshEvents + runtime.learningEvents).prefix(24))
        AgentLearningReviewStore.enqueue(events: freshEvents, sessionID: runtime.id)
    }

    static func oneLine(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "..."
    }
}
