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
    /// 调用方应停止本轮。
    case stopped
    /// 已选定当前任务的请求模型。
    case routed(model: String, decision: AgentManagedRouteDecision)
}

extension AppState {
    /// Resolve the current task locally, before the tool loop. No classifier
    /// or account subscription request participates in task initialization.
    @MainActor
    func resolveManagedTurnRoute(
        for runtime: AgentRuntime,
        configuration: AgentConfiguration,
        someIMContext: SomeIMRequestContext?
    ) async -> AgentManagedTurnRoute {
        if Task.isCancelled { return .stopped }
        guard runtime.managedRouting != nil,
              configuration.providerID == AgentProviderPreset.someIMID else {
            return .unmanaged
        }
        let taskID = runtime.messages.last(where: { $0.isOperatorInput })?.id
        let model = runtime.beginManagedTask(id: taskID)
        let reason = runtime.managedRouting?.lastEscalationReason
        let decision = AgentManagedRouteDecision(
            selectedModel: model,
            tier: SomeIMManagedModel.tier(of: model) ?? .low,
            domain: .general, complexity: .low, didFallback: false,
            didEscalate: reason != nil, failureType: reason
        )
        return .routed(model: model, decision: decision)
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
