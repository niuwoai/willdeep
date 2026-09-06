import Foundation
import Combine

/// One editor owns one immutable ledger identity. Switching the selected task
/// cannot redirect an in-flight save to a different Goal or parent project.
@MainActor
final class AgentGoalBudgetSettings: ObservableObject {
    let ledger: AgentModelRequestLedger
    @Published private(set) var snapshot: AgentModelRequestLedger.BudgetSnapshot?
    @Published private(set) var loadedAt: Date?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published var isLimited = false
    @Published var limitText = ""

    init(ledger: AgentModelRequestLedger) { self.ledger = ledger }

    var canSave: Bool {
        !isBusy && snapshot != nil && (!isLimited || Self.parseLimit(limitText) != nil)
    }

    /// Do not accept negatives, fractional/scientific notation or overflow.
    /// Plain decimal input avoids interpreting a locale separator ambiguously.
    nonisolated static func parseLimit(_ text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let limit = Int(value), limit > 0 else { return nil }
        return limit
    }

    func load() async {
        guard !isBusy, !Task.isCancelled else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        let ledger = ledger
        do {
            let value = try await Task.detached { try ledger.budgetSnapshot() }.value
            guard !Task.isCancelled else { return }
            apply(value)
        } catch {
            snapshot = nil
            loadedAt = nil
            errorMessage = L10n.GoalBudget.storageError
        }
    }

    /// Only an explicit UI action calls this. No inference, resume, permission
    /// expansion or spend reset accompanies a policy edit, including unlimited.
    @discardableResult
    func save() async -> Bool {
        guard !isBusy, let snapshot else { return false }
        let limit = isLimited ? Self.parseLimit(limitText) : nil
        guard !isLimited || limit != nil else {
            errorMessage = L10n.GoalBudget.invalidLimit
            return false
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        let ledger = ledger
        do {
            let value = try await Task.detached {
                try ledger.setAdmissionLimit(limit, expectedRevision: snapshot.policy.revision)
                return try ledger.budgetSnapshot()
            }.value
            apply(value)
            return true
        } catch AgentModelRequestLedger.Failure.stalePolicy {
            // Require a deliberate reload; a retry must not silently acquire
            // the new revision and overwrite another editor's decision.
            self.snapshot = nil
            loadedAt = nil
            errorMessage = L10n.GoalBudget.stalePolicy
        } catch {
            self.snapshot = nil
            loadedAt = nil
            errorMessage = L10n.GoalBudget.storageError
        }
        return false
    }

    private func apply(_ value: AgentModelRequestLedger.BudgetSnapshot) {
        snapshot = value
        loadedAt = Date()
        isLimited = value.policy.tokenLimit != nil
        limitText = value.policy.tokenLimit.map(String.init) ?? ""
    }
}
