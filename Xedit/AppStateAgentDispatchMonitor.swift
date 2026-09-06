import Foundation

extension AppState {
    /// Runtime identity alone is insufficient: an operator can stop and
    /// resume verification on the same session before the old await returns.
    func beginDispatchMonitor(runtimeID: UUID, taskID: UUID) -> UUID {
        invalidateDispatchMonitor(taskID: taskID)
        let leaseID = UUID()
        dispatchMonitorLeaseIDsByTaskID[taskID] = leaseID
        dispatchMonitoredRuntimeIDsByTaskID[taskID] = runtimeID
        return leaseID
    }

    func isCurrentDispatchMonitor(runtimeID: UUID, taskID: UUID, leaseID: UUID) -> Bool {
        dispatchMonitoredRuntimeIDsByTaskID[taskID] == runtimeID
            && dispatchMonitorLeaseIDsByTaskID[taskID] == leaseID
    }

    func invalidateDispatchMonitor(taskID: UUID) {
        dispatchMonitorLeaseIDsByTaskID[taskID] = nil
        dispatchMonitoredRuntimeIDsByTaskID[taskID] = nil
        dispatchMonitorTasksByTaskID.removeValue(forKey: taskID)?.cancel()
    }

    /// Called only by explicit task launch/override, never by board restoration
    /// or automatic executor fallback. A fresh prepared record has no old proof.
    func resumeStoppedDispatchDelivery(goalID: UUID, taskID: UUID, runtimeID: UUID, explicitlyRequested: Bool) throws {
        let journal = try dispatchDeliveryJournal(goalID: goalID, taskID: taskID)
        guard let record = try journal.load(goalID: goalID, taskID: taskID),
              record.phase == .stopped else { return }
        guard explicitlyRequested else { throw AgentDispatchDeliveryError.staleRuntime }
        invalidateDispatchMonitor(taskID: taskID)
        try journal.restartStopped(record, runtimeID: runtimeID)
    }
}
