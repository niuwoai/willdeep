//
//  AppStateAgentPluginRoundtable.swift
//  WillDeep
//
//  插件经 `willdeep/roundtable/run` 开一场专家圆桌(1.412.0-rc1)。
//
//  与用户自己开的圆桌(`startAgentRoundtable`)走同一条引擎与落盘链路,区别在:
//   - 专家席由插件给定(`customExperts`),跳过准备室与推荐,直接开场;
//   - 无人值守(`external`):专家反问不暂停,收敛即出终稿;
//   - 终稿之后按插件给的契约再出一份结构化结论,连同发言记录交回;
//   - 这里一直等到圆桌结束(或失败、取消)才返回,反向请求那头的上限是半小时。
//
//  会话照常出现在圆桌主页的历史里,用户随时能点开看;圆桌页开着时直接跳到这一场。
//

import Foundation

extension AppState {
    /// 等圆桌结束的续体,按报告 id 存。圆桌驱动任务结束时(终稿 / 失败 / 取消)唤醒。
    /// 放在 MainActor 的静态表里:扩展不能加存储属性,而等待方与唤醒方都在主线程。
    @MainActor
    private enum PluginRoundtableWaiters {
        static var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    @MainActor
    func runPluginRoundtable(
        pluginID: AgentPluginID,
        request: AgentPluginRoundtableRequest
    ) async throws -> AgentPluginRoundtableResult {
        guard AgentPluginRegistry.shared.hasPermission(.aiChat, pluginID: pluginID) else {
            throw AgentPluginRoundtableError.permissionDenied
        }

        // 反向请求也可能来自外部 CLI / 页面，没有会话 id。只在当前窗口唯一
        // 正在执行的主会话就是活动会话时展示；多个主会话并发时不猜归属。
        let originSessionID = AgentPluginRoundtableChatOrigin.resolve(
            activeSessionID: activeAgentSessionID,
            respondingSessionIDs: agentRuntimes.values.filter {
                $0.session.presentationScope == .workspace && $0.isResponding
            }.map(\.id)
        )

        reconcileSomeIMProviderFromSharedSession()
        ensureActiveProviderIsUsableForChatSelection()
        let managedRouting = defaultSomeIMManagedRoutingState()
        let modelID = defaultAgentModelIDForNewSession(managedRouting: managedRouting)

        // 插件指定了 provider 时按 provider 库里的条目钉死本场模型;没指定跟随当前活跃 provider。
        var providerEntryID: UUID?
        if let providerID = request.providerID {
            guard let entry = agentProviderLibrary.entries.first(where: { $0.providerID == providerID }) else {
                throw AgentPluginRoundtableError.unknownProvider(providerID)
            }
            providerEntryID = entry.id
        }

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
            topic: request.topic,
            title: request.title,
            phase: .opening,
            selectedProviderEntryID: providerEntryID,
            selectedModelID: providerEntryID == nil ? nil : request.model,
            customExperts: request.experts.map {
                RoundtableCustomExpert(id: $0.id, name: $0.name, expertise: $0.expertise, persona: $0.persona)
            },
            external: RoundtableExternalRun(
                pluginID: pluginID,
                chairPersona: request.chairPersona,
                verdictInstruction: request.verdictInstruction,
                roundLimit: request.rounds
            ),
            originSessionID: originSessionID
        )
        let report = WorkflowReport(
            workflowName: "expert-roundtable",
            displayTitle: request.title,
            args: request.title,
            status: .running,
            roundtable: roundtable
        )
        runtime.messages.append(AgentMessage(role: .user, content: request.title))
        runtime.messages.append(
            AgentMessage(role: .workflowReport, content: "", workflowReport: report)
        )
        AgentSessionStore.saveAsync(session)
        persistWorkflowRuntime(runtimeID: session.id)

        // 圆桌页开着就跳到这一场;没开时留着请求,下次打开再跳。
        requestedRoundtableRoute = .discussion(runtimeID: session.id, reportID: report.id)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            PluginRoundtableWaiters.continuations[report.id] = continuation
            driveRoundtable(reportID: report.id, runtimeID: session.id)
        }

        guard let finished = workflowReport(id: report.id, runtimeID: session.id),
              let detail = finished.roundtable else {
            throw AgentPluginRoundtableError.unavailable
        }
        switch detail.phase {
        case .cancelled:
            throw AgentPluginRoundtableError.cancelled
        case .failed:
            throw AgentPluginRoundtableError.failed(finished.summary.isEmpty ? "The roundtable failed." : finished.summary)
        default:
            break
        }
        guard let document = detail.finalDocument, !document.isEmpty else {
            throw AgentPluginRoundtableError.failed(AgentRoundtableError.emptyChairOutput.localizedDescription)
        }
        let (configuration, _) = roundtableTurnContext(runtimeID: session.id, reportID: report.id)
            ?? (configurationForCurrentTurn(for: runtime), nil)
        return AgentPluginRoundtableResult(
            reportID: report.id.uuidString,
            sessionID: session.id.uuidString,
            document: document,
            verdict: detail.external?.verdict,
            transcript: detail.messages.compactMap { message in
                guard message.speaker == .expert, let seatID = message.seatID else { return nil }
                return AgentPluginRoundtableTranscriptEntry(
                    seatID: seatID,
                    name: detail.seat(for: message)?.displayName ?? message.speakerName,
                    round: message.round,
                    content: message.content,
                    stance: message.osr?.stance.rawValue,
                    isError: message.isError == true
                )
            },
            model: configuration.model,
            providerID: configuration.providerID,
            rounds: detail.currentRound
        )
    }

    /// 圆桌驱动任务收尾时调用:唤醒在等这一场的插件请求(没人等就什么也不做)。
    @MainActor
    func resolvePluginRoundtableWaiter(reportID: UUID) {
        guard let continuation = PluginRoundtableWaiters.continuations.removeValue(forKey: reportID) else { return }
        continuation.resume()
    }
}
