//
//  AppStateAgentComputerUse.swift
//  WillDeep
//
//  Host reactions to the globally visible Computer Use control card.
//

import Foundation

extension AppState {
    @MainActor
    func handleComputerUseControlIntent(
        _ event: AgentComputerUseControlIntentEvent
    ) {
        switch event.intent {
        case .pause, .takeover:
            // Helper v6 is deliberately single-threaded. Terminating its
            // generation is the only bounded-latency way to interrupt an AX
            // call or wait_for that is already executing. The Agent tool task
            // observes the coordinator's paused/takeover state and stays
            // suspended until the user explicitly resumes.
            let barrierEpoch =
                AgentComputerUseCoordinator.shared
                    .requiredTransportBarrierEpoch
            Task {
                await AgentComputerUseBridge.shared.restart()
                await MainActor.run {
                    AgentComputerUseCoordinator.shared
                        .acknowledgeTransportBarrier(epoch: barrierEpoch)
                }
            }

        case .resume:
            // The old helper generation was discarded on pause. The next
            // Computer Use call re-acquires this lease and must begin with a
            // fresh state snapshot; eagerly replaying the interrupted action
            // here would violate user takeover.
            break

        case .stop:
            let barrierEpoch =
                AgentComputerUseCoordinator.shared
                    .requiredTransportBarrierEpoch
            if let runtime = agentRuntimes[event.lease.owner.runtimeID],
               runtime.activeTurnID == event.lease.owner.turnID {
                stopAgentResponse(for: runtime)
            }
            Task {
                await AgentComputerUseBridge.shared.restart()
                await MainActor.run {
                    AgentComputerUseCoordinator.shared
                        .acknowledgeTransportBarrier(epoch: barrierEpoch)
                    AgentComputerUseCoordinator.shared.complete(
                        leaseID: event.lease.id
                    )
                }
            }
        }
    }
}
