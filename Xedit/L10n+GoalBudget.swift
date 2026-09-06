import Foundation

extension L10n {
    enum GoalBudget {
        static let title = String(localized: "goal-budget.title", defaultValue: "Model request budget")
        static let scope = String(localized: "goal-budget.scope", defaultValue: "Cumulative for this Goal session. Dispatch children share their parent project's ledger; editing a Goal does not reset usage.")
        static let coverage = String(localized: "goal-budget.coverage", defaultValue: "Coverage is not yet complete: native main requests, budget-bound Workers and compression are recorded. Other auxiliary requests and external CLIs may be outside this ledger. This is not a total task cost or provider billing guarantee.")
        static let reported = String(localized: "goal-budget.reported", defaultValue: "Reported tokens")
        static let reserved = String(localized: "goal-budget.reserved", defaultValue: "Reserved for unconfirmed usage")
        static let unknown = String(localized: "goal-budget.unknown", defaultValue: "Unquantifiable requests")
        static let currentLimit = String(localized: "goal-budget.currentLimit", defaultValue: "Current total limit")
        static let remaining = String(localized: "goal-budget.remaining", defaultValue: "Remaining admission balance")
        static let unlimited = String(localized: "goal-budget.unlimited", defaultValue: "Unlimited")
        static let unquantified = String(localized: "goal-budget.unquantified", defaultValue: "Unknown — not treated as zero")
        static let limitEnabled = String(localized: "goal-budget.limitEnabled", defaultValue: "Limit recorded requests")
        static let limitPlaceholder = String(localized: "goal-budget.limitPlaceholder", defaultValue: "Total tokens, for example 100000")
        static let limitHint = String(localized: "goal-budget.limitHint", defaultValue: "Enter a positive whole number, without separators. This sets a cumulative ceiling, not extra credit. It constrains future requests; requests already sent are not cancelled.")
        static let saveBehavior = String(localized: "goal-budget.saveBehavior", defaultValue: "Saving preserves receipts and spent usage, grants no tool permissions, and does not resume paused work. Use the task's Resume action when ready.")
        static let unknownWarning = String(localized: "goal-budget.unknownWarning", defaultValue: "Some earlier requests cannot be quantified. A finite limit pauses new admissions until their usage can be reconciled; increasing the number alone cannot resolve this.")
        static let snapshotTime = String(localized: "goal-budget.snapshotTime", defaultValue: "Snapshot taken at")
        static let reload = String(localized: "goal-budget.reload", defaultValue: "Reload current settings")
        static let storageError = String(localized: "goal-budget.storageError", defaultValue: "Budget settings could not be read or confirmed. Reload to check the current policy before trying again; existing receipts were preserved.")
        static let stalePolicy = String(localized: "goal-budget.stalePolicy", defaultValue: "Another editor changed this budget. Nothing was overwritten. Reload the current settings before saving again.")
        static let invalidLimit = String(localized: "goal-budget.invalidLimit", defaultValue: "Enter a positive whole token limit within the supported numeric range.")
    }
}
