//
//  AgentGoalMilestone.swift
//  WillDeep
//
//  Version-anchored milestones and the Doc Capsule handoff
//  (docs/GOAL_TEAMS_ROLES_DESIGN.md §3–§5).
//
//  One milestone is one rc version. That is not bookkeeping decoration: it is
//  what makes "what shipped in this step" answerable months later, and it
//  lines up with the repo's own rule that one PR does not mix feat + fix.
//

import Foundation

nonisolated enum AgentGoalMilestoneGate: String, Codable, Equatable, Sendable {
    case none
    /// The periodic full gate: build, full tests, guard scripts, smoke,
    /// signing. Carries no feature scope of its own.
    case periodic
}

nonisolated struct AgentGoalMilestone: Codable, Equatable, Identifiable, Sendable {
    /// Target version, e.g. `1.248.0-rc3`. Also the identity: one milestone,
    /// one version.
    var version: String
    /// What this version does — and explicitly what it must not mix in.
    var scope: String
    /// How it is verified, naming the Test Owner.
    var verification: String
    /// Git contract: separate commit, `v{version}` tag, push or not.
    var gitContract: String
    var gate: AgentGoalMilestoneGate
    /// Set only by the validator role named in the roster.
    var signedOffBy: String?

    var id: String { version }

    var isSignedOff: Bool {
        !(signedOffBy ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static let periodicScope = "Periodic gate only: full build, full unit tests, guard scripts, smoke, signing. No feature or fix changes."
}

nonisolated struct AgentGoalMilestoneLedger: Codable, Equatable, Sendable {
    /// Versions between two periodic gates (goal-teams §3.2, confirmed
    /// default). Configurable per goal, never zero.
    static let defaultGateInterval = 40

    var milestones: [AgentGoalMilestone]
    var gateInterval: Int

    init(milestones: [AgentGoalMilestone] = [], gateInterval: Int = defaultGateInterval) {
        self.milestones = milestones
        self.gateInterval = max(1, gateInterval)
    }

    /// Whether the next milestone must be a periodic gate: every
    /// `gateInterval` non-gate milestones, counted since the last gate.
    var nextMilestoneNeedsPeriodicGate: Bool {
        var sinceGate = 0
        for milestone in milestones.reversed() {
            if milestone.gate == .periodic { break }
            sinceGate += 1
        }
        return sinceGate >= gateInterval
    }

    /// Appends a milestone, refusing the two mistakes the design calls out:
    /// reusing a version, and mixing feature scope into a periodic gate.
    @discardableResult
    mutating func append(_ milestone: AgentGoalMilestone) -> [String] {
        var errors: [String] = []
        if milestones.contains(where: {
            $0.version.caseInsensitiveCompare(milestone.version) == .orderedSame
        }) {
            errors.append("milestone version `\(milestone.version)` is already used")
        }
        if milestone.gate == .periodic,
           milestone.scope.trimmingCharacters(in: .whitespacesAndNewlines)
               != AgentGoalMilestone.periodicScope {
            errors.append("a periodic gate milestone cannot carry its own scope")
        }
        guard errors.isEmpty else { return errors }
        milestones.append(milestone)
        return []
    }

    /// Sign-off goes through the roster's cross-validation rule; a role can
    /// never sign its own work off, so this is refused rather than trusted.
    @discardableResult
    mutating func signOff(
        version: String,
        byRoleID: String,
        forRoleID: String,
        roster: AgentGoalTeamRoster
    ) -> Bool {
        guard roster.canSignOff(roleID: forRoleID, validatorRoleID: byRoleID),
              let index = milestones.firstIndex(where: {
                  $0.version.caseInsensitiveCompare(version) == .orderedSame
              }) else {
            return false
        }
        milestones[index].signedOffBy = byRoleID
        return true
    }

    static func periodicGate(version: String, verification: String, gitContract: String) -> AgentGoalMilestone {
        AgentGoalMilestone(
            version: version,
            scope: AgentGoalMilestone.periodicScope,
            verification: verification,
            gitContract: gitContract,
            gate: .periodic,
            signedOffBy: nil
        )
    }
}

// MARK: - Doc Capsule

/// Structured handoff between roles (goal-teams §5). Free text was the old
/// contract and it made "did you stay in scope?" unanswerable without reading
/// the whole report.
nonisolated struct AgentGoalTeamCapsule: Codable, Equatable, Sendable {
    nonisolated struct Evidence: Codable, Equatable, Sendable {
        var kind: String
        var path: String
        var summary: String
    }

    /// The self-report a validator checks against: what the member says it
    /// did NOT do.
    nonisolated struct ConstraintsHonored: Codable, Equatable, Sendable {
        var readOnly: Bool
        var scope: String
        var commandsRun: [String]

        enum CodingKeys: String, CodingKey {
            case readOnly = "read_only"
            case scope
            case commandsRun = "commands_run"
        }
    }

    var schema: String
    var role: String
    var milestone: String
    var conclusion: String
    var evidence: [Evidence]
    var filesTouched: [String]
    var constraintsHonored: ConstraintsHonored
    var nextSuggestion: String?

    static let schemaID = "goal-teams.capsule.v1"

    enum CodingKeys: String, CodingKey {
        case schema, role, milestone, conclusion, evidence
        case filesTouched = "files_touched"
        case constraintsHonored = "constraints_honored"
        case nextSuggestion = "next_suggestion"
    }

    init(
        role: String,
        milestone: String,
        conclusion: String,
        evidence: [Evidence] = [],
        filesTouched: [String] = [],
        constraintsHonored: ConstraintsHonored,
        nextSuggestion: String? = nil
    ) {
        self.schema = Self.schemaID
        self.role = role
        self.milestone = milestone
        self.conclusion = conclusion
        self.evidence = evidence
        self.filesTouched = filesTouched
        self.constraintsHonored = constraintsHonored
        self.nextSuggestion = nextSuggestion
    }

    /// A read-only role that reports touched files is contradicting itself;
    /// the validator should see that as a failed constraint, not prose.
    var selfReportIsConsistent: Bool {
        !(constraintsHonored.readOnly && !filesTouched.isEmpty)
    }
}

// MARK: - Archive

/// `<workspace>/.codex/goal-teams/` — the repo's existing convention, kept so
/// historical archives and new ones share one directory.
nonisolated enum AgentGoalTeamArchive {
    static let schemaHeader = "goal-teams.v1"

    static func versionDirectory(workspacePath: String, version: String) -> URL {
        AgentGoalTeamRoleStore.directoryURL(workspacePath: workspacePath)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    static func indexURL(workspacePath: String) -> URL {
        AgentGoalTeamRoleStore.directoryURL(workspacePath: workspacePath)
            .appendingPathComponent("INDEX.md", isDirectory: false)
    }

    @discardableResult
    static func writeCapsule(
        _ capsule: AgentGoalTeamCapsule,
        workspacePath: String
    ) -> URL? {
        let directory = versionDirectory(workspacePath: workspacePath, version: capsule.milestone)
            .appendingPathComponent("capsules", isDirectory: true)
        let fileName = "\(capsule.role).json"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let url = directory.appendingPathComponent(fileName, isDirectory: false)
            try encoder.encode(capsule).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Appends one line per milestone. The schema header is written once so a
    /// reader (or the other end of goal-teams.v1) can tell the format.
    @discardableResult
    static func appendIndexEntry(
        workspacePath: String,
        version: String,
        status: String,
        summary: String
    ) -> Bool {
        let url = indexURL(workspacePath: workspacePath)
        let line = "| \(version) | \(status) | \(summary.replacingOccurrences(of: "|", with: "/")) |\n"
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let existing = try? String(contentsOf: url, encoding: .utf8), !existing.isEmpty {
                guard !existing.contains("| \(version) |") else { return true }
                try (existing + line).write(to: url, atomically: true, encoding: .utf8)
            } else {
                let header = """
                # Goal teams archive (\(schemaHeader))

                | Version | Status | Summary |
                |---|---|---|

                """
                try (header + line).write(to: url, atomically: true, encoding: .utf8)
            }
            return true
        } catch {
            return false
        }
    }

    /// Cross-milestone memory (§4.3): the tester's notes about flaky tests and
    /// environment traps. Memory lives in a file, not in a session — which is
    /// the whole point of writing it down.
    static func memoryText(for role: AgentGoalTeamRole, workspacePath: String?) -> String? {
        guard let workspacePath,
              let fileName = role.memoryFileName,
              !fileName.isEmpty else {
            return nil
        }
        let url = AgentGoalTeamRoleStore.directoryURL(workspacePath: workspacePath)
            .appendingPathComponent(fileName, isDirectory: false)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
