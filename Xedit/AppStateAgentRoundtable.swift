//
//  AppStateAgentRoundtable.swift
//  WillDeep
//
//  专家圆桌的启动/取消/历史读取,挂在 AppState 上。每场圆桌 = 一个独立的
//  AgentSession(不激活、不干扰主 Agent 会话流),里面挂一条
//  WorkflowReport.roundtable,天然复用 AgentSessionStore 落盘与 loadAll 读取。
//

import Foundation
import Combine

extension AppState {
    /// 圆桌用的会话工作区 key(与普通会话隔离,便于 workspace identity 归属)。
    fileprivate static let roundtableWorkspaceKey = "willdeep.roundtable"

    /// 发起一场新的圆桌讨论。返回承载它的 session id 供 UI 跟踪。
    /// 不切 activeAgentSessionID —— 圆桌活在独立窗口里,不该动主 Agent 会话。
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

        let runtimeID = session.id
        let turnConfiguration = configurationForCurrentTurn(for: runtime)
        let someIMContext: SomeIMRequestContext? = {
            guard turnConfiguration.providerID == AgentProviderPreset.someIMID else { return nil }
            let workspaceID = AgentWorkspaceIdentityStore.workspaceID(
                forWorkspaceKey: Self.roundtableWorkspaceKey
            )
            return SomeIMRequestContext(sessionID: runtimeID.uuidString, workspaceID: workspaceID)
        }()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let engine = AgentRoundtableEngine(
                reportID: report.id,
                runtimeID: runtimeID,
                configuration: turnConfiguration,
                someIMContext: someIMContext,
                appState: self
            )
            do {
                let document = try await engine.run()
                guard !Task.isCancelled else { throw CancellationError() }
                self.updateWorkflowReport(id: report.id, runtimeID: runtimeID) { item in
                    item.status = .done
                    item.summary = document
                    item.finishedAt = Date()
                }
                self.persistWorkflowRuntime(runtimeID: runtimeID)
            } catch is CancellationError {
                self.updateWorkflowReport(id: report.id, runtimeID: runtimeID) { item in
                    item.status = .cancelled
                    item.finishedAt = Date()
                    if var detail = item.roundtable {
                        detail.phase = .cancelled
                        item.roundtable = detail
                    }
                }
                self.persistWorkflowRuntime(runtimeID: runtimeID)
            } catch {
                self.updateWorkflowReport(id: report.id, runtimeID: runtimeID) { item in
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
            self.agentRoundtableTasks[report.id] = nil
        }
        agentRoundtableTasks[report.id] = task
        return runtimeID
    }

    func stopAgentRoundtable(reportID: UUID) {
        agentRoundtableTasks[reportID]?.cancel()
    }

    /// 用户答复专家的反问,或作为主持人插话:把用户消息追加进 transcript。
    /// (首版:追加为 .user 消息;后续可触发续跑 —— 见 UI 层。)
    func appendRoundtableUserMessage(runtimeID: UUID, reportID: UUID, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateWorkflowReport(id: reportID, runtimeID: runtimeID) { item in
            guard var roundtable = item.roundtable else { return }
            roundtable.messages.append(
                RoundtableMessage(speaker: .user, round: roundtable.currentRound, content: trimmed)
            )
            roundtable.updatedAt = Date()
            item.roundtable = roundtable
        }
        persistWorkflowRuntime(runtimeID: runtimeID)
    }

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
