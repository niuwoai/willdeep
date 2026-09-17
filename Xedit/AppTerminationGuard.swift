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
            confirmation: {
                presentConfirmation(keepRunningLabels: jobsSurvivingTermination(appStates: appStates)
                    .map { $0.label ?? $0.command })
            }
        )
    }

    /// Detached `.persistent` jobs keep running after quit and are adopted by
    /// the next launch, so they never block quitting; the dialog only lists
    /// them. Several app states may share one registry.
    static func jobsSurvivingTermination(appStates: [AppState]) -> [AgentBackgroundJob] {
        var visited: Set<ObjectIdentifier> = []
        var jobs: [AgentBackgroundJob] = []
        for appState in appStates {
            let registry = appState.agentJobRegistry
            guard visited.insert(ObjectIdentifier(registry)).inserted else { continue }
            jobs.append(contentsOf: registry.aliveDetachedJobs)
        }
        return jobs
    }

    /// Informative text: the standard warning, plus the jobs that will keep
    /// running when there are any.
    static func confirmationMessage(keepRunningLabels: [String]) -> String {
        guard !keepRunningLabels.isEmpty else { return L10n.AppTermination.message }
        let list = keepRunningLabels.map { "• \($0)" }.joined(separator: "\n")
        return L10n.AppTermination.message + "\n\n" + L10n.AppTermination.detachedJobsKeepRunning(list)
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

    private static func presentConfirmation(keepRunningLabels: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.AppTermination.title
        alert.informativeText = confirmationMessage(keepRunningLabels: keepRunningLabels)
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
                || !runtime.workflowTasks.isEmpty
                || agentJobRegistry.aliveJobs(forRuntime: runtime.id).contains { !$0.isDetached }
                || agentSubagentRegistry.activeCount(forParentRuntime: runtime.id) > 0
        }
    }
}
