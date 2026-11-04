//
//  AppStateContextRunwayRelay.swift
//  WillDeep
//
//  Carries a context-runway handover into a brand-new session: automatically
//  when compression fails after a runway stop, or when the operator presses
//  "continue in a new session".
//

import WillDeepCore
import Foundation

extension AppState {
    /// 压缩失败后把活儿接到新会话。
    ///
    /// 跑道交接的正常路径是：90% 停下写交接 → 压缩 → 原会话自动续跑。压缩
    /// 失败时窗口还停在 90%，原地续跑只会再撞一次同样的有序停止，所以过去
    /// 这里直接停住，等人来点。可交接已经写好了，没人值守的任务就这么卡死。
    /// 现在带着整份交接开一个新会话接着跑。
    ///
    /// 只接原本就要自动续跑的那一类：`pendingContextRunwayResume` 已经替我们
    /// 判过次数上限（`canResumeAfterContextCompaction`）。三处刻意不接：
    /// - Goal：目标、验收清单、预算都挂在原会话上，新会话接不住，照旧停住；
    /// - 远程工作区：新会话只能按本地路径创建，接过去会跑到错的机器上；
    /// - 找不到交接消息：没有 NEXT PROMPT 可接，接过去只能从头猜。
    ///
    /// - Returns: 接力出去的新会话；没接时为 nil。
    @discardableResult
    func relayContextRunwayAfterCompressionFailure(for source: AgentRuntime) -> AgentRuntime? {
        guard let (relay, prompt) = prepareContextRunwayRelayAfterCompressionFailure(for: source) else {
            return nil
        }
        dispatchAgentMessageUsingSelectedExecutor(
            relay.executionAgent,
            for: relay,
            text: prompt,
            images: [],
            source: .hostInstruction
        )
        return relay
    }

    /// 接力的全部准备（开会话、继承设置、计数、原会话留痕），不含派发。
    /// 单独拆出来是为了能测：派发会走真实的供应商与网络。
    func prepareContextRunwayRelayAfterCompressionFailure(
        for source: AgentRuntime
    ) -> (relay: AgentRuntime, prompt: String)? {
        guard source.interactionMode != .goal,
              source.queuedMessages.isEmpty,
              !source.isResponding,
              let handover = Self.latestContextRunwayHandover(in: source.messages) else {
            return nil
        }
        // 用户正看着原会话才切过去；在看别的会话就别抢焦点。
        let wasActive = activeAgentSessionID == source.id
        guard let relay = makeContextRunwayRelaySession(from: source, makeActive: wasActive) else {
            return nil
        }
        // 次数接着原会话往下数：否则「压缩失败 → 新会话 → 又满 → 又失败 →
        // 再开新会话」会一直转到额度用光。
        relay.contextRunwayResumeCount = source.contextRunwayResumeCount + 1
        appendContextRunwayRelayNotice(to: source, relay: relay)
        let prompt = AgentContextRunwayPolicy.relaySessionPrompt(
            handover: handover,
            sourceSessionTitle: source.session.title,
            reason: .compressionFailed
        )
        return (relay, prompt)
    }

    /// 最近一条跑道交接的全文（进度块已剥掉，NEXT PROMPT 保留）。只认最后
    /// 一条 assistant 回复：更早的交接已经被后来的工作取代了。
    nonisolated static func latestContextRunwayHandover(in messages: [AgentMessage]) -> String? {
        guard let message = messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }) else {
            return nil
        }
        let visible = AgentTurnProgressPresentation.extract(from: message.content, plan: nil).visibleContent
        guard AgentContextRunwayHandoffDisplay.extract(from: visible).isHandoff else { return nil }
        return visible
    }

    /// 新会话照原会话的设置开：工作区、模型与供应商、审批档位、执行器、
    /// 专家、沙箱开关、知识库。交接里全是这个工作区、这套配置下的事实，
    /// 换了任何一样，ANCHORS 就对不上了。
    func makeContextRunwayRelaySession(from source: AgentRuntime, makeActive: Bool) -> AgentRuntime? {
        // A new top-level relay would lose the child's parent and its read-only
        // capability ceiling. Leave the failed task in its original conversation.
        guard source.session.parentSessionID == nil else { return nil }
        let location = source.workspaceLocation ?? source.workspaceRootPath.map { .local(path: $0) }
        if let location, location.localPath == nil { return nil }
        let session = startNewAgentSession(inWorkspaceAt: location?.localPath, makeActive: makeActive)
        guard let relay = agentRuntimes[session.id] else { return nil }

        relay.session.projectID = source.session.projectID ?? relay.session.projectID
        relay.session.sidebarWorkspaceRootPath = source.session.sidebarWorkspaceRootPath
        relay.session.modelID = source.session.modelID
        relay.session.providerEntryID = source.session.providerEntryID
        relay.session.providerID = source.session.providerID
        relay.session.providerDisplayName = source.session.providerDisplayName
        relay.session.sandboxEnabled = source.session.sandboxEnabled
        relay.session.prefersSubagents = source.session.prefersSubagents
        relay.session.title = L10n.ContextRunwayHandoff.relaySessionTitle(source.session.title)
        relay.session.titleIsUserSet = true
        relay.sessionModelOverride = source.sessionModelOverride
        relay.sessionProviderEntryID = source.sessionProviderEntryID
        relay.sessionProviderIDOverride = source.sessionProviderIDOverride
        relay.managedRouting = source.managedRouting
        relay.interactionMode = source.interactionMode == .goal ? .normal : source.interactionMode
        relay.approvalMode = source.approvalMode
        relay.executionAgent = source.executionAgent
        relay.activeExperts = source.activeExperts
        relay.localSandboxDisabled = source.localSandboxDisabled
        relay.knowledgeFolders = source.knowledgeFolders
        relay.documentTaskMode = source.documentTaskMode
        relay.redactSensitiveAttachmentContent = source.redactSensitiveAttachmentContent
        return relay
    }

    /// 原会话里留一行「已转到新会话」。
    ///
    /// 借用 `.responseStopped` 事件而不是新增一种：旧版本对会话消息是严格
    /// 解码，遇到不认识的事件值整个会话都读不出来，回滚后这个会话会从侧边栏
    /// 消失。这一行本来也就是「这里停了」的意思，渲染成居中的说明文字。
    func appendContextRunwayRelayNotice(to source: AgentRuntime, relay: AgentRuntime) {
        source.messages.append(AgentMessage(
            role: .system,
            content: L10n.ContextRunwayHandoff.relayedNotice(relay.session.title),
            transcriptEvent: .responseStopped
        ))
        persistAgentSession(runtime: source, touchUpdatedAt: false, moveToFront: false)
    }
}
