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
    func startAgentRoundtable(topic: String) -> UUID? {
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
            modelID: modelID,
            managedRouting: managedRouting
        )
        let runtime = AgentRuntime(session: session)
        agentRuntimes[session.id] = runtime
        agentSessions.insert(session, at: 0)

        let roundtable = AgentRoundtableReport(topic: trimmed)
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

        driveRoundtable(reportID: report.id, runtimeID: session.id)
        return session.id
    }

    func stopAgentRoundtable(reportID: UUID) {
        agentRoundtableTasks[reportID]?.cancel()
    }

    /// 主持人答复专家反问,或作为主持人插话。追加为 .user 消息;若讨论正停在
    /// 「等答复」(.awaitingUser)且没有在跑的驱动,则重启一次续跑。
    func submitRoundtableUserReply(runtimeID: UUID, reportID: UUID, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var wasAwaiting = false
        updateWorkflowReport(id: reportID, runtimeID: runtimeID) { item in
            guard var roundtable = item.roundtable else { return }
            wasAwaiting = roundtable.phase == .awaitingUser
            roundtable.messages.append(
                RoundtableMessage(speaker: .user, round: roundtable.currentRound, content: trimmed)
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

    // MARK: - 驱动引擎(首跑 / 续跑共用)

    /// 启动一次圆桌驱动:跑引擎到暂停点或终稿,并按结果落状态。首跑与续跑
    /// 共用同一条路径,靠引擎的幂等性保证续跑不重复已完成阶段。
    private func driveRoundtable(reportID: UUID, runtimeID: UUID) {
        guard let (configuration, someIMContext) = roundtableTurnContext(runtimeID: runtimeID) else { return }

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
                    self.updateWorkflowReport(id: reportID, runtimeID: runtimeID) { item in
                        item.status = .done
                        item.summary = document
                        item.finishedAt = Date()
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
                        item.roundtable = detail
                    }
                }
                self.persistWorkflowRuntime(runtimeID: runtimeID)
            }
            self.agentRoundtableTasks[reportID] = nil
        }
        agentRoundtableTasks[reportID] = task
    }

    /// 为一次圆桌驱动组装本轮 configuration 与(若走 some.im)请求上下文。
    private func roundtableTurnContext(
        runtimeID: UUID
    ) -> (AgentConfiguration, SomeIMRequestContext?)? {
        guard let runtime = agentRuntimes[runtimeID] else { return nil }
        let configuration = configurationForCurrentTurn(for: runtime)
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

    /// 读取所有历史圆桌报告(从内存 runtime + 已落盘会话)。给主页历史列表用。
    func loadRoundtableHistory() -> [AgentRoundtableReport] {
        var seen = Set<UUID>()
        var results: [AgentRoundtableReport] = []
        // 内存中的活跃 runtime 优先(最新状态)。
        for runtime in agentRuntimes.values {
            for message in runtime.messages {
                if let rt = message.workflowReport?.roundtable, seen.insert(rt.id).inserted {
                    results.append(rt)
                }
            }
        }
        // 已落盘、未在内存的会话。
        for session in AgentSessionStore.loadAll() {
            for message in session.messages {
                if let rt = message.workflowReport?.roundtable, seen.insert(rt.id).inserted {
                    results.append(rt)
                }
            }
        }
        return results.sorted { $0.updatedAt > $1.updatedAt }
    }
}
