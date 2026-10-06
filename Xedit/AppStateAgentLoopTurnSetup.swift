//
//  AppStateAgentLoopTurnSetup.swift
//  WillDeep
//
//  `runAgentLoop` 进入工具循环之前和退出之后的两段，原样从
//  AppStateAgentLoop.swift 搬出来——那个文件越过了 complexity_guard 的
//  3000 行硬上限，而这两段是函数体里仅有的、不读写循环局部变量的整块：
//
//    - resolveManagedTurnRoute：「省心托管」每个用户回合只判一次路由，
//      在工具循环之前定下这一回合用哪个模型；
//    - finishAgentLoopTurnCleanup：回合退出时 `defer` 里的收尾（遥测、
//      计时、交付租约、Computer Use 租约、设计闸门、释放 provider 槽位）。
//
//  行为不变：调用顺序、判断条件与原先逐行一致。
//

import WillDeepCore
import Foundation

/// 托管路由对一个回合的结论。
enum AgentManagedTurnRoute {
    /// 不走托管路由（没开，或 provider 不是 some.im），沿用原配置。
    case unmanaged
    /// 路由判官运行期间用户停止了回合，调用方应直接返回。
    case stopped
    /// 已选定模型。`explicitTier` 是判官给出的显式档位；回落时为 nil，
    /// 之后写只升不降的下限时必须用它，不能用对冲抬高过的有效档位。
    case routed(model: String, decision: AgentManagedRouteDecision, explicitTier: AgentManagedCapabilityTier?)
}

extension AppState {
    /// "省心托管" dynamic routing. Resolved ONCE per user turn, BEFORE the
    /// tool-call loop, so the whole loop reuses a single model — no
    /// mid-turn re-judging that could desync tool_call pairing. The judge
    /// shares this turn's already-held provider slot; `routeJudge` never
    /// acquires/releases a slot and never throws, so the caller's `defer`
    /// still owns every release path.
    @MainActor
    func resolveManagedTurnRoute(
        for runtime: AgentRuntime,
        configuration: AgentConfiguration,
        someIMContext: SomeIMRequestContext?
    ) async -> AgentManagedTurnRoute {
        guard runtime.managedRouting != nil,
              configuration.providerID == AgentProviderPreset.someIMID else {
            return .unmanaged
        }
        let floor = runtime.managedRouting?.minimumTier ?? .low
        // isOperatorInput: hidden host carriers (empty content, per-turn
        // context reminders) are `.user` role but must never stand in for
        // what the human actually asked — a wake-up turn would otherwise
        // send the judge an empty message.
        let latestOperatorMessage = runtime.messages.last(where: { $0.isOperatorInput })
        let judgeInput = SomeIMRouteJudgeInput(
            latestUserMessage: latestOperatorMessage?.content ?? "",
            hasImages: latestOperatorMessage?.images.isEmpty == false,
            hasTextAttachments: latestOperatorMessage?.textAttachments.isEmpty == false,
            workspaceAvailable: runtime.workspaceLocation != nil || (runtime.workspaceRootPath?.isEmpty == false),
            selectedFileLanguage: openedFileURL.flatMap { $0.pathExtension.isEmpty ? nil : $0.pathExtension },
            interactionMode: "\(runtime.interactionMode)",
            approvalMode: "\(runtime.approvalMode)",
            toolsEnabled: true,
            conversationSummary: runtime.contextSummary
        )
        beginGoalExecutionBudgetIfNeeded(for: runtime)
        let judgeClient = AgentClient(configuration: configuration, session: agentLoopInferenceEnvironment?.session,
            someIMContext: someIMContext, requestLedger: modelRequestLedger(for: runtime))
        let routeJudge = AgentGoalRouteJudge(client: judgeClient, executionBudget: auxiliaryModelExecutionBudget(for: runtime))
        // Routing must never wait on the account control plane. The
        // launch timer owns refreshes; a stale value is still a better
        // latency trade than blocking the first provider request.
        let hasCodingPlan = someIMCodingPlanStatus.isActiveNow
        if someIMCodingPlanStatus.isStale {
            refreshSomeIMCodingPlanStatus(force: false)
        }
        let routeMeasurement = AgentAuxiliaryRequestMeasurement()
        let resolution = await AgentNonStreamingModelRequest.$usageObserver.withValue(routeMeasurement) {
            await SomeIMManagedRouting.route(
                input: judgeInput,
                floor: floor,
                hasCodingPlan: hasCodingPlan
            ) { system, user, maxTokens in
                await routeJudge.text(model: SomeIMManagedModel.judge, system: system, user: user, maxTokens: maxTokens)
            }
        }
        await recordJudgeRequest(routeMeasurement, purpose: .routeJudge, configuration: configuration,
            model: SomeIMManagedModel.judge, succeeded: !resolution.usedFallback, runtimeID: runtime.id)
        AgentModelRouteLog.record(AgentModelRouteLog.Entry(
            surface: .managedRouting,
            sessionID: runtime.id,
            subject: resolution.verdict.domain.rawValue,
            requested: resolution.verdict.targetModel,
            providerID: configuration.providerID,
            model: resolution.model,
            fallback: resolution.usedFallback,
            reason: resolution.usedFallback ? .judgeUnavailable : .routed,
            detail: resolution.verdict.reason
        ))
        if stopAfterRouteJudge(routeJudge, runtime: runtime) { return .stopped }
        // Captured BEFORE noteManagedSelectedModel overwrites it — the
        // escalation check below compares against the tier the session
        // actually ran on last turn.
        let previousManagedModel = runtime.managedRouting?.lastSelectedModel
        runtime.noteManagedSelectedModel(resolution.model)
        let decision = AgentManagedRouteDecision(
            selectedModel: resolution.model,
            tier: resolution.effectiveTier,
            domain: resolution.verdict.domain,
            complexity: resolution.verdict.complexity,
            didFallback: resolution.usedFallback
        )
        // Only a real judge verdict raises the persisted floor — a network
        // fallback must not lock the session into a high tier. Use the
        // judge's explicit tier, not `effectiveTier`: the low-confidence
        // conservative escalation applies to this turn's model choice only
        // and must never be written into the only-goes-up floor.
        var explicitTier: AgentManagedCapabilityTier?
        if !resolution.usedFallback {
            explicitTier = resolution.persistedFloorTier
            runtime.raiseManagedFloor(to: resolution.persistedFloorTier, reason: resolution.verdict.reason)
        }
        // 升档前压缩（见 muchtoken docs/someim-32b-compressor.md）：
        // 切到高档模型本来就必然使前缀缓存失效，此刻压缩零缓存损失，
        // 却直接削减高档模型要摄入的 input。只在 turn 开始的路由升档
        // 处做；输出质检的 mid-turn 升档重跑不压——一轮之内不改写
        // 历史，避免 tool_call 配对漂移。低于阈值或压缩失败都原文
        // 照发，不阻塞本轮。
        if Self.managedEscalationCrossesTier(
            previousModel: previousManagedModel,
            newTier: resolution.effectiveTier
        ) {
            await compressBeforeManagedEscalationIfNeeded(
                for: runtime,
                escalatedModel: resolution.model,
                providerID: configuration.providerID
            )
        }
        return .routed(model: resolution.model, decision: decision, explicitTier: explicitTier)
    }

    /// `runAgentLoop` 每条退出路径上的收尾，由它的 `defer` 调用。
    @MainActor
    func finishAgentLoopTurnCleanup(
        for runtime: AgentRuntime,
        turnID: UUID,
        providerSlotClaimID: UUID,
        providerID: String,
        turnTelemetry: AgentTurnTelemetry,
        shouldResumePendingEvents: Bool
    ) {
        AgentTelemetry.recordTurnFinished(turnTelemetry)
        // The parallel scout belongs to this turn: cancel it if it is
        // still running, drop an undelivered report, then write the
        // turn's timing line. Runs before the wake-up probes below so a
        // scout can never be mistaken for pending background work.
        if runtime.activeTurnID == turnID {
            finalizeTurnTiming(
                for: runtime,
                turnID: turnID,
                outcome: String(describing: turnTelemetry.status)
            )
        }
        // Any event still leased here was not acknowledged by a completed
        // provider request. Put it back before the final wakeup probe so a
        // cancellation, transport failure, or host preemption can retry in
        // this process rather than waiting for an app restart.
        agentRuntimeKernel.releaseModelDeliveryLeases(
            for: runtime.id,
            leaseID: turnID
        )
        let computerUseLeaseID: AgentComputerUseLease.ID? = {
            guard let lease = AgentComputerUseCoordinator.shared.state.lease,
                  lease.owner.runtimeID == runtime.id,
                  lease.owner.turnID == turnID else {
                return nil
            }
            return lease.id
        }()
        AgentComputerUseCoordinator.shared.finishTurn(
            runtimeID: runtime.id,
            turnID: turnID
        )
        // Computer Use approvals are intentionally turn-scoped. The
        // exclusive lease binds calls to one target during this turn;
        // retaining `computer_use:*` into a later turn would silently
        // authorize a different target or newly consequential action.
        if runtime.activeTurnID == turnID {
            runtime.conversationAllowedToolSignatures.remove("computer_use:*")
        }
        if let computerUseLeaseID {
            Task {
                try? await AgentComputerUseBridge.shared.endControlSession(
                    controlLeaseID: computerUseLeaseID.uuidString.lowercased()
                )
            }
        }
        // Design gate: hand over the card, or stand down. Runs before the
        // turn is finished off so the card is in the transcript by the
        // time the composer becomes available again — a gate that locks
        // write tools without showing what it is waiting for is just a
        // broken session.
        finalizeSpecGateTurn(for: runtime)
        finishAgentLoopTurn(
            for: runtime, turnID: turnID, providerSlotClaimID: providerSlotClaimID,
            providerID: providerID,
            shouldResumePendingEvents: shouldResumePendingEvents
        )
    }
}
