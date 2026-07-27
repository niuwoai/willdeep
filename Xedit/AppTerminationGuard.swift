//
//  AppTerminationGuard.swift
//  WillDeep
//
//  Prevents an accidental normal app quit from silently interrupting active
//  Agent work. Force Quit, crashes, power loss, and SIGKILL cannot be
//  intercepted by AppKit and remain the responsibility of recovery support.
//

import AppKit
import Foundation

@MainActor
enum AppTerminationGuard {
    static func shouldAllowTermination(appStates: [AppState]) -> Bool {
        shouldAllowTermination(
            appStates: appStates,
            confirmation: presentConfirmation
        )
    }

    static func shouldAllowTermination(
        appStates: [AppState],
        confirmation: () -> Bool
    ) -> Bool {
        guard appStates.contains(where: \.hasTerminationSensitiveActivity) else {
            return true
        }
        return confirmation()
    }

    private static func presentConfirmation() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.AppTermination.title
        alert.informativeText = L10n.AppTermination.message
        alert.addButton(withTitle: L10n.AppTermination.keepWorking)
        alert.addButton(withTitle: L10n.AppTermination.quitAnyway)
        return alert.runModal() == .alertSecondButtonReturn
    }
}

@MainActor
extension AppState {
    var hasTerminationSensitiveActivity: Bool {
        if !agentConsultationTasks.isEmpty || !agentRoundtableTasks.isEmpty {
            return true
        }
        if agentDispatchCoordinator.goals.contains(where: { $0.activeTaskCount > 0 }) {
            return true
        }
        if agentMediaTaskRegistry.tasks(forRuntime: nil).contains(where: \.isActive) {
            return true
        }

        return agentRuntimes.values.contains { runtime in
            runtime.isResponding
                || runtime.isAwaitingProviderSlot
                || runtime.isCompressingContext
                || runtime.isAskingPlanModeFlash
                || !runtime.workflowTasks.isEmpty
                || !agentJobRegistry.aliveJobs(forRuntime: runtime.id).isEmpty
                || agentSubagentRegistry.activeCount(forParentRuntime: runtime.id) > 0
        }
    }
}
