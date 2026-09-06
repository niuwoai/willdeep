import Foundation

extension L10n {
    enum GoalAuthorization {
        static let allow = String(localized: "goal-authorization.allow", defaultValue: "Allow local checks for this Goal")
        static let badge = String(localized: "goal-authorization.badge", defaultValue: "GOAL GRANT")
        static let scope = String(localized: "goal-authorization.scope", defaultValue: "Repeat this exact foreground verification command in this workspace for this Goal, for up to 8 hours. Entry script, manifest, environment or Goal changes require a fresh approval. Stop revokes the grant. Network and sandbox escape remain denied; existing local read permissions still apply.")
        static let unavailable = String(localized: "goal-authorization.unavailable", defaultValue: "A Goal-scoped grant could not be established. Nothing ran. The original one-time approval is still available.")
    }
}
