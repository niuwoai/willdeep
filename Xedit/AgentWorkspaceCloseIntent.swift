import Foundation

/// Window-local close confirmation state. Cancelling never touches the editor.
nonisolated struct AgentWorkspaceCloseIntent {
    private(set) var requiresConfirmation = false
    private(set) var requestID: UUID?
    private(set) var approvedRequestID: UUID?

    mutating func request(isDirty: Bool) -> Bool {
        if approvedRequestID != nil { return true }
        guard isDirty else { continueEditing(); return true }
        requestID = UUID()
        requiresConfirmation = true
        return false
    }

    // SwiftUI can dismiss a dialog's Binding before its button action runs.
    mutating func dismissPresentation() { requiresConfirmation = false }
    mutating func continueEditing() { requiresConfirmation = false; requestID = nil; approvedRequestID = nil }

    mutating func confirmDiscard(requestID: UUID) -> Bool {
        guard self.requestID == requestID else { return false }
        requiresConfirmation = false
        self.requestID = nil; approvedRequestID = requestID
        return true
    }
    mutating func abandonApprovedClose(_ requestID: UUID) {
        guard approvedRequestID == requestID else { return }
        continueEditing()
    }
}
