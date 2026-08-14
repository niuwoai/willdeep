import Foundation

// Strings for goal-team execution roles (docs/GOAL_TEAMS_ROLES_DESIGN.md §2).
extension L10n {
    nonisolated enum GoalTeams {
        static let roleDeveloper = String(localized: "goal-teams.role-developer", defaultValue: "Developer")
        static let roleTester = String(localized: "goal-teams.role-tester", defaultValue: "Tester")
        static let roleReviewer = String(localized: "goal-teams.role-reviewer", defaultValue: "Reviewer")
    }
}
