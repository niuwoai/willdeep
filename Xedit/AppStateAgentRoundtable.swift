//
//  AppStateAgentRoundtable.swift
//  WillDeep
//
//  专家圆桌的启动/续跑/取消/历史读取,挂在 AppState 上。每场圆桌 = 一个独立的
//  AgentSession(不激活、不干扰主 Agent 会话流),里面挂一条
//  WorkflowReport.roundtable,天然复用 AgentSessionStore 落盘与 loadAll 读取。
//
//  引擎(AgentRoundtableEngine.run)每次驱动会推进到「专家反问暂停」或「收敛出
//  终稿」两个终点之一。反问暂停时不落终态,等主持人答复后 submitRoundtableUserReply
//  会重启一次驱动续跑 —— 引擎按落盘状态幂等,不会重复已完成的阶段。
//

import Foundation
import Combine

extension AppState {
    /// 圆桌用的会话工作区 key(与普通会话隔离,便于 workspace identity 归属)。
    fileprivate static let roundtableWorkspaceKey = "willdeep.roundtable"

    /// 发起一场新的圆桌讨论。返回承载它的 session id 供 UI 跟踪。
    /// 不切 activeAgentSessionID —— 圆桌活在独立窗口/嵌入页里,不该动主 Agent 会话。
    @discardableResult
    func startAgentRoundtable(
        topic: String,
        title: String = "",
        experts: [AgentRoundtableExpertRole] = [],
        originSessionID: UUID? = nil,
        startImmediately: Bool = false
    ) -> UUID? {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        reconcileSomeIMProviderFromSharedSession()
        ensureActiveProviderIsUsableForChatSelection()
        let managedRouting = defaultSomeIMManagedRoutingState()
        let modelID = defaultAgentModelIDForNewSession(managedRouting: managedRouting)

        // 独立、无工作区的圆桌会话。
        let session = AgentSession(
            workspaceRootPath: nil,
            workspaceLocation: nil,
            presentationScope: .roundtable,
            modelID: modelID,
            managedRouting: managedRouting
        )
        let runtime = AgentRuntime(session: session)
        agentRuntimes[session.id] = runtime
        agentSessions.insert(session, at: 0)

        let roundtable = AgentRoundtableReport(
            topic: trimmed,
            title: title,
            phase: startImmediately ? .recommending : .clarifying,
            preparation: startImmediately ? nil : RoundtablePreparation(originalTopic: trimmed),
            experts: experts,
            originSessionID: originSessionID
        )
        let report = WorkflowReport(
            workflowName: "expert-roundtable",
            displayTitle: trimmed,
            args: trimmed,
            status: .running,
            roundtable: roundtable
        )
        runtime.messages.append(AgentMessage(role: .user, content: trimmed))
        runtime.messages.append(
            AgentMessage(role: .workflowReport, content: "", workflowReport: report)
        )
        AgentSessionStore.saveAsync(session)
        persistWorkflowRuntime(runtimeID: session.id)

        if startImmediately {
            driveRoundtable(reportID: report.id, runtimeID: session.id)
        } else {
            driveRoundtablePreparation(reportID: report.id, runtimeID: session.id)
        }
        return session.id
    }

    func stopAgentRoundtable(reportID: UUID) {
        agentRoundtableTasks[reportID]?.cancel()
    }

    /// 主持人答复专家反问,或作为主持人插话。追加为 .user 消息;若讨论正停在
    /// 「等答复」(.awaitingUser)且没有在跑的驱动,则重启一次续跑。
    func submitRoundtableUserReply(
        runtimeID: UUID,
        reportID: UUID,
        content: String,
        quote: RoundtableQuoteReference? = nil
    ) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var wasAwaiting = false
        updateWorkflowReport(id: reportID, runtimeID: runtimeID) { item in
            guard var roundtable = item.roundtable else { return }
            wasAwaiting = roundtable.phase == .awaitingUser
            roundtable.messages.append(
                RoundtableMessage(
                    speaker: .user,
                    round: roundtable.currentRound,
                    content: trimmed,
                    quote: quote
                )
            )
            roundtable.updatedAt = Date()
            item.roundtable = roundtable
        }
        persistWorkflowRuntime(runtimeID: runtimeID)

        // 只有在「等答复」且当前没有活跃驱动时才续跑,避免重复启动。
        if wasAwaiting, agentRoundtableTasks[reportID] == nil {
            driveRoundtable(reportID: reportID, runtimeID: runtimeID)
        }
    }

    /// 兼容旧调用名:等价于 submitRoundtableUserReply。
    func appendRoundtableUserMessage(runtimeID: UUID, reportID: UUID, content: String) {
        submitRoundtableUserReply(runtimeID: runtimeID, reportID: reportID, content: content)
    }

    // MARK: - 主持人控轮(收敛后由用户决定继续还是收尾)

    /// 收敛暂停后,主持人点「继续下一轮」:复位 converged、回到 .discussing,再驱动
    /// 一次。引擎循环从下一轮续跑(前面轮次已有导播小结会被跳过),上一轮小结里的
    /// 「下一轮建议聚焦」已随 transcript 自动带入。仅在收敛暂停态且无活跃驱动时生效。
    func continueRoundtableNextRound(runtimeID: UUID, reportID: UUID) {
        guard agentRoundtableTasks[reportID] == nil else { return }
        var canContinue = false
        updateWorkflowReport(id: reportID, runtimeID: runtimeID) { item in
            guard var roundtable = item.roundtable else { return }
            // 只在「收敛后停下等主持人」这个态放行,且没到轮数硬顶。
            guard roundtable.phase == .awaitingUser,
                  roundtable.converged,
                  roundtable.currentRound < AgentRoundtableReport.maxRounds
            else { return }
            roundtable.converged = false
            roundtable.phase = .discussing
            roundtable.updatedAt = Date()
            item.roundtable = roundtable
            canContinue = true
        }
        guard canContinue else { return }
        persistWorkflowRuntime(runtimeID: runtimeID)
        driveRoundtable(reportID: reportID, runtimeID: runtimeID)
    }

    /// 收敛暂停后,主持人点「结束并生成文档」:保持 converged=true 再驱动一次,引擎
    /// discuss() 顶部的 `if converged { return .finished }` 便直接进入 synthesize 出终稿。
    /// 仅在收敛暂停态且无活跃驱动时生效。
    func finalizeRoundtable(runtimeID: UUID, reportID: UUID) {
        guard agentRoundtableTasks[reportID] == nil else { return }
        var canFinalize = false
        updateWorkflowReport(id: reportID, runtimeID: runtimeID) { item in
            guard var roundtable = item.roundtable else { return }
            guard roundtable.phase == .awaitingUser, roundtable.converged else { return }
            roundtable.phase = .synthesizing
            roundtable.updatedAt = Date()
            item.roundtable = roundtable
            canFinalize = true
        }
        guard canFinalize else { return }
        persistWorkflowRuntime(runtimeID: runtimeID)
        driveRoundtable(reportID: reportID, runtimeID: runtimeID)
    }

    // MARK: - 会前准备

    /// 用户补充背景或修正框架后，重新生成一份完整准备方案。准备任务与正式
    /// 讨论共用 report task 槽，保证同一场圆桌不会同时跑两条模型链路。
    func refineRoundtablePreparation(
        runtimeID: UUID,
        reportID: UUID,
        content: String
    ) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, agentRoundtableTasks[reportID] == nil else { return }

        updateWorkflowReport(id: reportID, runtimeID: runtimeID) { item in
            guard var roundtable = item.roundtable else { return }
            var preparation = roundtable.preparation
                ?? RoundtablePreparation(originalTopic: roundtable.topic)
            preparation.conversation.append(
                RoundtablePreparationMessage(speaker: .user, content: trimmed)
            )
            roundtable.preparation = preparation
            roundtable.phase = .clarifying
            roundtable.updatedAt = Date()
            item.summary = ""
            item.roundtable = roundtable
        }
        persistWorkflowRuntime(runtimeID: runtimeID)
        driveRoundtablePreparation(reportID: reportID, runtimeID: runtimeID)
    }

    /// 从框架确认进入专家选择。只改变准备阶段，不会偷偷启动正式讨论。
    func showRoundtableExpertSelection(runtimeID: UUID, reportID: UUID) {
        guard agentRoundtableTasks[reportID] == nil else { return }
        updateWorkflowReport(id: reportID, runtimeID: runtimeID) { item in
            guard var roundtable = item.roundtable,
                  let preparation = roundtable.preparation,
                  preparation.hasValidExpertSelection
            else { return }
            roundtable.phase = .selectingExperts
            roundtable.updatedAt = Date()
            item.summary = ""
            item.roundtable = roundtable
        }
        persistWorkflowRuntime(runtimeID: runtimeID)
    }

    func returnToRoundtablePreparation(runtimeID: UUID, reportID: UUID) {
        guard agentRoundtableTasks[reportID] == nil else { return }
        updateWorkflowReport(id: reportID, runtimeID: runtimeID) { item in
            guard var roundtable = item.roundtable else { return }
            roundtable.phase = .clarifying
            roundtable.updatedAt = Date()
            item.summary = ""
            item.roundtable = roundtable
        }
        persistWorkflowRuntime(runtimeID: runtimeID)
    }

    /// 用户明确确认阵容后才把精炼议题和专家名单交给正式圆桌引擎。
    @discardableResult
    func confirmRoundtableExpertSelection(
        runtimeID: UUID,
        reportID: UUID,
        experts: [AgentRoundtableExpertRole],
        providerEntryID: UUID? = nil,
        modelID: String? = nil
    ) -> Bool {
        guard agentRoundtableTasks[reportID] == nil else { return false }
        var seen = Set<AgentRoundtableExpertRole>()
        let uniqueExperts = experts.filter { seen.insert($0).inserted }
        guard uniqueExperts.count >= RoundtablePreparation.minimumExpertCount,
              uniqueExperts.count <= RoundtablePreparation.maximumExpertCount
        else { return false }

        var confirmed = false
        updateWorkflowReport(id: reportID, runtimeID: runtimeID) { item in
            guard var roundtable = item.roundtable,
                  var preparation = roundtable.preparation,
                  roundtable.phase == .selectingExperts
            else { return }
            preparation.selectedExperts = uniqueExperts
            roundtable.preparation = preparation
            roundtable.experts = uniqueExperts
            roundtable.topic = preparation.resolvedTopic
            // 仅本场生效的 provider/模型选择;nil 表示跟随全局活跃 provider。
            roundtable.selectedProviderEntryID = providerEntryID
            roundtable.selectedModelID = modelID
            roundtable.phase = .opening
            roundtable.updatedAt = Date()
            item.displayTitle = roundtable.displayTitle
            item.args = roundtable.topic
            item.summary = ""
            item.roundtable = roundtable
            confirmed = true
        }
        guard confirmed else { return false }
        persistWorkflowRuntime(runtimeID: runtimeID)
        driveRoundtable(reportID: reportID, runtimeID: runtimeID)
        return true
    }

    func isAgentRoundtableTaskRunning(reportID: UUID) -> Bool {
        agentRoundtableTasks[reportID] != nil
    }

    private func driveRoundtablePreparation(reportID: UUID, runtimeID: UUID) {
        guard agentRoundtableTasks[reportID] == nil,
              let (configuration, someIMContext) = roundtableTurnContext(runtimeID: runtimeID, reportID: reportID)
        else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let engine = AgentRoundtableEngine(
                reportID: reportID,
                runtimeID: runtimeID,
                configuration: configuration,
                someIMContext: someIMContext,
                appState: self
            )
            var failure: String?
            do {
                try await engine.prepareDiscussion()
                try Task.checkCancellation()
            } catch is CancellationError {
                failure = CancellationError().localizedDescription
            } catch {
                failure = error.localizedDescription
            }

            self.agentRoundtableTasks[reportID] = nil
            self.updateWorkflowReport(id: reportID, runtimeID: runtimeID) { item in
                guard var roundtable = item.roundtable else { return }
                roundtable.phase = .clarifying
                roundtable.updatedAt = Date()
                item.summary = failure ?? ""
                item.roundtable = roundtable
            }
            self.persistWorkflowRuntime(runtimeID: runtimeID)
        }
        agentRoundtableTasks[reportID] = task
    }

    // MARK: - 驱动引擎(首跑 / 续跑共用)

    /// 启动一次圆桌驱动:跑引擎到暂停点或终稿,并按结果落状态。首跑与续跑
    /// 共用同一条路径,靠引擎的幂等性保证续跑不重复已完成阶段。
    func driveRoundtable(reportID: UUID, runtimeID: UUID) {
        guard let (configuration, someIMContext) = roundtableTurnContext(runtimeID: runtimeID, reportID: reportID) else {
            resolvePluginRoundtableWaiter(reportID: reportID)
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let engine = AgentRoundtableEngine(
                reportID: reportID,
                runtimeID: runtimeID,
                configuration: configuration,
                someIMContext: someIMContext,
                appState: self
            )
            do {
                let result = try await engine.run()
                guard !Task.isCancelled else { throw CancellationError() }
                switch result {
                case .completed(let document):
                    let title = self.workflowReport(
                        id: reportID,
                        runtimeID: runtimeID
                    )?.roundtable?.displayTitle ?? "roundtable"
                    self.updateWorkflowReport(id: reportID, runtimeID: runtimeID) { item in
                        item.status = .done
                        item.summary = document
                        item.finishedAt = Date()
                    }
                    do {
                        let fileURL = try RoundtableDocumentExporter.persist(
                            reportID: reportID,
                            title: title,
                            markdown: document
                        )
                        self.updateWorkflowReport(id: reportID, runtimeID: runtimeID) { item in
                            guard var detail = item.roundtable else { return }
                            detail.finalDocumentFilePath = fileURL.path
                            detail.finalDocumentWriteError = nil
                            detail.updatedAt = Date()
                            item.roundtable = detail
                        }
                    } catch {
                        let description = error.localizedDescription
                        NSLog(
                            "Roundtable document persist failed report=%@ error=%@",
                            reportID.uuidString,
                            description
                        )
                        self.updateWorkflowReport(id: reportID, runtimeID: runtimeID) { item in
                            guard var detail = item.roundtable else { return }
                            detail.finalDocumentFilePath = nil
                            detail.finalDocumentWriteError = description
                            detail.updatedAt = Date()
                            item.roundtable = detail
                        }
                    }
                case .awaitingUser:
                    // 停在等主持人答复:保持 running,不落终态,phase 已由引擎置为
                    // .awaitingUser。答复后 submitRoundtableUserReply 会再驱动一次。
                    break
                }
                self.persistWorkflowRuntime(runtimeID: runtimeID)
            } catch is CancellationError {
                self.updateWorkflowReport(id: reportID, runtimeID: runtimeID) { item in
                    item.status = .cancelled
                    item.finishedAt = Date()
                    if var detail = item.roundtable {
                        detail.phase = .cancelled
                        detail.activeExpert = nil
                        detail.activeCustomExpertID = nil
                        detail.activeExpertDraft = nil
                        detail.activeExpertDraftIsComplete = nil
                        item.roundtable = detail
                    }
                }
                self.persistWorkflowRuntime(runtimeID: runtimeID)
            } catch {
                self.updateWorkflowReport(id: reportID, runtimeID: runtimeID) { item in
                    item.status = .failed
                    item.finishedAt = Date()
                    item.summary = error.localizedDescription
                    if var detail = item.roundtable {
                        detail.phase = .failed
                        detail.activeExpert = nil
                        detail.activeCustomExpertID = nil
                        detail.activeExpertDraft = nil
                        detail.activeExpertDraftIsComplete = nil
                        item.roundtable = detail
                    }
                }
                self.persistWorkflowRuntime(runtimeID: runtimeID)
            }
            self.agentRoundtableTasks[reportID] = nil
            // 插件开的圆桌(1.412.0-rc1):驱动结束就唤醒等结果的反向请求。
            self.resolvePluginRoundtableWaiter(reportID: reportID)
        }
        agentRoundtableTasks[reportID] = task
    }

    /// 为一次圆桌驱动组装本轮 configuration 与(若走 some.im)请求上下文。
    /// 若本场圆桌在开会时选定了 provider/模型(report.selectedProviderEntryID),
    /// 用该 entry 现造配置、仅本场生效,不动全局活跃 provider;否则回退到当前
    /// 全局活跃 provider 的路由结果。
    /// 插件开的圆桌（AppStateAgentPluginRoundtable.swift）也要拿本场的配置回报模型名，故不设 private。
    func roundtableTurnContext(
        runtimeID: UUID,
        reportID: UUID
    ) -> (AgentConfiguration, SomeIMRequestContext?)? {
        guard let runtime = agentRuntimes[runtimeID] else { return nil }
        let roundtable = workflowReport(id: reportID, runtimeID: runtimeID)?.roundtable
        let configuration: AgentConfiguration = {
            if let entryID = roundtable?.selectedProviderEntryID,
               let entry = agentProviderLibrary.entries.first(where: { $0.id == entryID }) {
                // 选定模型同时喂给 flash/pro,把本场钉死在这个模型上(不受路由影响)。
                let model = roundtable?.selectedModelID
                return entry.makeConfiguration(flashOverride: model, proOverride: model).normalized
            }
            return configurationForCurrentTurn(for: runtime)
        }()
        let someIMContext: SomeIMRequestContext? = {
            guard configuration.providerID == AgentProviderPreset.someIMID else { return nil }
            let workspaceID = AgentWorkspaceIdentityStore.workspaceID(
                forWorkspaceKey: Self.roundtableWorkspaceKey
            )
            return SomeIMRequestContext(sessionID: runtimeID.uuidString, workspaceID: workspaceID)
        }()
        return (configuration, someIMContext)
    }

    // MARK: - 历史

    /// 读取所有历史圆桌报告(内存 runtime + 已落盘圆桌会话),给主页历史列表和专家档案用。
    ///
    /// 主线程只做两件便宜事:扫内存 runtime、从已加载的侧边栏目录里挑出
    /// `.roundtable` 作用域的会话 id。整份会话 JSON 的解码放到后台 ——
    /// 以前这里同步调 `AgentSessionStore.loadAll()`,主窗口一打开圆桌就在主线程
    /// 把全部会话的 catalog 解一遍(采样实测 ~0.4s),而 catalog 里的会话是
    /// 去掉 messages 的骨架,扫下来一条落盘报告都拿不到,纯属白干。
    func loadRoundtableHistory() async -> [AgentRoundtableHistoryItem] {
        var resident: [AgentRoundtableHistoryItem] = []
        for (sessionID, runtime) in agentRuntimes {
            resident += AgentRoundtableHistoryLoader.items(sessionID: sessionID, messages: runtime.messages)
        }
        let residentIDs = Set(agentRuntimes.keys)
        // 目录还没加载完(刚启动)时交给后台自己扫一遍骨架目录。
        let catalogCandidates: [UUID]? = hasLoadedAgentSessionCatalog
            ? AgentRoundtableHistoryLoader.storedCandidateIDs(catalog: agentSessions, excluding: residentIDs)
            : nil
        let stored = await Task.detached(priority: .userInitiated) {
            let candidates = catalogCandidates ?? AgentRoundtableHistoryLoader.storedCandidateIDs(
                catalog: AgentSessionStore.loadAll(),
                excluding: residentIDs
            )
            return AgentRoundtableHistoryLoader.loadStored(
                candidateIDs: candidates,
                load: AgentSessionStore.peekStoredSession(id:)
            )
        }.value
        return AgentRoundtableHistoryLoader.merge(resident: resident, stored: stored)
    }
}

/// 圆桌历史列表的一行:报告本身 + 承载它的会话 id。落盘会话点开时靠 sessionID
/// 物化 runtime —— 只拿报告的话,不在内存里的历史条目点了没反应。
nonisolated struct AgentRoundtableHistoryItem: Identifiable, Equatable, Sendable {
    let sessionID: UUID
    let report: AgentRoundtableReport

    var id: UUID { report.id }
}

/// 圆桌历史读取的纯逻辑部分,无 AppState 依赖,可在后台跑、可单测。
nonisolated enum AgentRoundtableHistoryLoader {
    static func items(sessionID: UUID, messages: [AgentMessage]) -> [AgentRoundtableHistoryItem] {
        messages.compactMap { message in
            message.workflowReport?.roundtable.map {
                AgentRoundtableHistoryItem(sessionID: sessionID, report: $0)
            }
        }
    }

    /// 只有圆桌作用域的会话才可能挂圆桌报告(见 startAgentRoundtable);已在内存
    /// runtime 里的会话以内存为准,不再读盘。
    static func storedCandidateIDs(catalog: [AgentSession], excluding residentIDs: Set<UUID>) -> [UUID] {
        catalog
            .filter { $0.presentationScope == .roundtable && !residentIDs.contains($0.id) }
            .map(\.id)
    }

    static func loadStored(
        candidateIDs: [UUID],
        load: (UUID) -> AgentSession?
    ) -> [AgentRoundtableHistoryItem] {
        candidateIDs.flatMap { id -> [AgentRoundtableHistoryItem] in
            guard let session = load(id) else { return [] }
            return items(sessionID: session.id, messages: session.messages)
        }
    }

    /// 按报告 id 去重(内存优先,状态最新),再按更新时间倒序。
    static func merge(
        resident: [AgentRoundtableHistoryItem],
        stored: [AgentRoundtableHistoryItem]
    ) -> [AgentRoundtableHistoryItem] {
        var seen = Set<UUID>()
        var results: [AgentRoundtableHistoryItem] = []
        for item in resident + stored where seen.insert(item.report.id).inserted {
            results.append(item)
        }
        return results.sorted { $0.report.updatedAt > $1.report.updatedAt }
    }
}
