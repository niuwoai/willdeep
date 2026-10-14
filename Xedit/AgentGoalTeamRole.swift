//
//  AgentGoalTeamRole.swift
//  WillDeep
//
//  Execution-period roles for goal teams (docs/GOAL_TEAMS_ROLES_DESIGN.md §2).
//
//  A role answers "who is responsible for what in this goal, and who signs it
//  off". A profile (agent-profile.v2) answers "what tools and budget does it
//  run with". Roles bind to profiles; they never redefine them.
//
//  The point of the separation is mechanism, not persona: the value of a "QA
//  member" is an independent context, a narrowed tool set, evidence as the
//  deliverable, and cross-validation. Three names on one context is
//  role-play, not separation of duties — so every rule here is enforced on
//  the execution path, not asked for in a prompt.
//

import Foundation

/// How far a role may narrow the tools of the profile it binds to. A policy
/// can only take capability away; it can never grant what the profile lacks.
nonisolated enum AgentGoalTeamToolPolicy: String, Codable, Equatable, Sendable, CaseIterable {
    /// Reading only. Even read-tier shell is removed: a reviewer that can run
    /// commands re-runs what the developer already ran instead of reading.
    case readOnly
    /// Reading plus the read-tier shell, so gates and tests can be executed
    /// and their output quoted. Still no write tool.
    case readPlusTest
    /// Whatever the bound profile allows, including its write door if it has
    /// one (only the built-in editor trade does, gated by approval + lock).
    case writeScoped

    var deniesShell: Bool { self == .readOnly }
    var deniesWrite: Bool { self != .writeScoped }
}

nonisolated struct AgentGoalTeamRole: Codable, Equatable, Identifiable, Sendable {
    let id: String
    /// Profiles this role runs as, most specific first. Several because a
    /// developer both edits (editor trade) and investigates (deep trade).
    var boundProfileIDs: [String]
    var toolPolicy: AgentGoalTeamToolPolicy
    /// What this role may touch in the current milestone. Anything outside is
    /// refused and reported rather than quietly done.
    var lockedScope: String
    /// What "done" means, phrased so the validator can check it independently.
    var doneCriteria: String
    /// Who signs this role's work off. Hard rule: never itself.
    var validatorRoleID: String
    /// Cross-milestone memory file, relative to the goal-teams directory.
    var memoryFileName: String?

    var primaryProfileID: String? { boundProfileIDs.first }

    @MainActor var localizedName: String {
        switch id {
        case AgentGoalTeamRoster.developerID: return L10n.GoalTeams.roleDeveloper
        case AgentGoalTeamRoster.testerID: return L10n.GoalTeams.roleTester
        case AgentGoalTeamRoster.reviewerID: return L10n.GoalTeams.roleReviewer
        default: return id
        }
    }

    /// The trade this role actually runs, after its policy narrows the bound
    /// profile. Returns nil when the bound profile is missing or cannot run
    /// in-process.
    func resolvedTrade(
        profiles: [AgentProfile],
        profileID: String? = nil
    ) -> AgentSubagentProfile? {
        let wanted = profileID ?? primaryProfileID
        guard let wanted,
              let profile = profiles.first(where: { $0.id == wanted }),
              var trade = profile.asSubagentProfile() else {
            return nil
        }
        if toolPolicy.deniesShell {
            trade.toolNames.remove("run_command")
            trade.toolNames.remove("terminal_send_command")
        }
        if toolPolicy.deniesWrite {
            trade.requiresWriteAccess = false
            trade.toolNames.subtract(AgentSubagentProfileCatalog.writeToolNames)
        }
        return trade
    }
}

/// The roster for one goal: three built-in execution roles, editable per
/// workspace.
nonisolated struct AgentGoalTeamRoster: Codable, Equatable, Sendable {
    static let developerID = "developer"
    static let testerID = "tester"
    static let reviewerID = "reviewer"

    var roles: [AgentGoalTeamRole]

    static let builtIn = AgentGoalTeamRoster(roles: [
        AgentGoalTeamRole(
            id: developerID,
            boundProfileIDs: [
                AgentSubagentProfileCatalog.editorID,
                AgentSubagentProfileCatalog.deepID,
            ],
            toolPolicy: .writeScoped,
            lockedScope: "",
            doneCriteria: "The change is implemented inside the locked scope and builds.",
            validatorRoleID: reviewerID,
            memoryFileName: nil
        ),
        AgentGoalTeamRole(
            id: testerID,
            boundProfileIDs: [AgentSubagentProfileCatalog.testerID],
            toolPolicy: .readPlusTest,
            lockedScope: "",
            doneCriteria: "The declared gates ran, and their output is quoted as evidence.",
            validatorRoleID: reviewerID,
            memoryFileName: nil
        ),
        AgentGoalTeamRole(
            id: reviewerID,
            boundProfileIDs: [AgentSubagentProfileCatalog.reviewerID],
            toolPolicy: .readOnly,
            lockedScope: "",
            doneCriteria: "Scope, version consistency and git hygiene are checked, with an explicit verdict.",
            // The reviewer answers to the goal lead — the human — which is
            // why this is the one role whose validator is not another role.
            validatorRoleID: "",
            memoryFileName: nil
        ),
    ])

    func role(id: String) -> AgentGoalTeamRole? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return roles.first { $0.id.lowercased() == trimmed }
    }

    /// Hard rule from the design: a role's work can only be signed off by its
    /// validator, and a role can never be its own validator. Enforced here so
    /// every caller shares one answer instead of re-deriving it.
    func canSignOff(roleID: String, validatorRoleID: String) -> Bool {
        guard let role = role(id: roleID) else { return false }
        let claimed = validatorRoleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !claimed.isEmpty, claimed != role.id.lowercased() else { return false }
        return role.validatorRoleID.lowercased() == claimed
    }

    /// Problems that make a roster unusable. Returned rather than thrown so
    /// the UI can show all of them at once.
    func validationErrors(profiles: [AgentProfile]) -> [String] {
        var errors: [String] = []
        let ids = Set(roles.map { $0.id.lowercased() })
        let profileIDs = Set(profiles.map { $0.id.lowercased() })
        for role in roles {
            if role.validatorRoleID.lowercased() == role.id.lowercased() {
                errors.append("role `\(role.id)` cannot validate itself")
            }
            if !role.validatorRoleID.isEmpty,
               !ids.contains(role.validatorRoleID.lowercased()) {
                errors.append("role `\(role.id)` names an unknown validator `\(role.validatorRoleID)`")
            }
            if role.boundProfileIDs.isEmpty {
                errors.append("role `\(role.id)` binds no profile")
            }
            for profileID in role.boundProfileIDs where !profileIDs.contains(profileID.lowercased()) {
                errors.append("role `\(role.id)` binds unknown profile `\(profileID)`")
            }
        }
        if Set(roles.map(\.id)).count != roles.count {
            errors.append("duplicate role ids")
        }
        return errors
    }
}

/// Per-workspace roster file. Lives beside the goal-teams archive
/// (`<workspace>/.codex/goal-teams/`), which is the convention this repo
/// already uses for goal artifacts.
nonisolated enum AgentGoalTeamRoleStore {
    static let directoryName = ".codex/goal-teams"
    static let rosterFileName = "roles.json"

    static func directoryURL(workspacePath: String) -> URL {
        URL(fileURLWithPath: workspacePath, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func rosterURL(workspacePath: String) -> URL {
        directoryURL(workspacePath: workspacePath)
            .appendingPathComponent(rosterFileName, isDirectory: false)
    }

    /// Reads the workspace roster, falling back to the built-in one. A
    /// corrupt file falls back too: a goal must stay runnable when its roster
    /// file is hand-edited into invalid JSON.
    static func load(workspacePath: String?) -> AgentGoalTeamRoster {
        guard let workspacePath, !workspacePath.isEmpty else { return .builtIn }
        let url = rosterURL(workspacePath: workspacePath)
        guard let data = try? Data(contentsOf: url),
              let roster = try? JSONDecoder().decode(AgentGoalTeamRoster.self, from: data),
              !roster.roles.isEmpty else {
            return .builtIn
        }
        return roster
    }

    @discardableResult
    static func save(_ roster: AgentGoalTeamRoster, workspacePath: String) -> Bool {
        let directory = directoryURL(workspacePath: workspacePath)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(roster)
            try data.write(to: rosterURL(workspacePath: workspacePath), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
