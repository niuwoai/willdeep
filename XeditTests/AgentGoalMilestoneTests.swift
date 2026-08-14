import Foundation
import Testing
@testable import WillDeep

/// Version-anchored milestones, the periodic gate, and the Doc Capsule
/// handoff written into `.codex/goal-teams/`.
@Suite
@MainActor
struct AgentGoalMilestoneTests {
    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-goal-milestones-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func milestone(_ version: String) -> AgentGoalMilestone {
        AgentGoalMilestone(
            version: version,
            scope: "scope for \(version)",
            verification: "targeted unit tests, Test Owner: tester",
            gitContract: "separate commit; tag v\(version); no push",
            gate: .none,
            signedOffBy: nil
        )
    }

    // MARK: Ledger rules

    @Test("one milestone is one version — a reused version is refused")
    func versionsAreUnique() {
        var ledger = AgentGoalMilestoneLedger()

        #expect(ledger.append(milestone("1.248.0-rc1")).isEmpty)
        let errors = ledger.append(milestone("1.248.0-RC1"))

        #expect(errors.contains { $0.contains("already used") })
        #expect(ledger.milestones.count == 1)
    }

    @Test("a periodic gate cannot smuggle feature scope in")
    func periodicGateCarriesNoScope() {
        var ledger = AgentGoalMilestoneLedger()
        var sneaky = milestone("1.249.0-rc1")
        sneaky.gate = .periodic

        let errors = ledger.append(sneaky)
        #expect(errors.contains { $0.contains("cannot carry its own scope") })

        #expect(ledger.append(
            AgentGoalMilestoneLedger.periodicGate(
                version: "1.249.0-rc1",
                verification: "full suite + guards + smoke",
                gitContract: "gate only, no feature commits"
            )
        ).isEmpty)
    }

    @Test("the periodic gate falls due every N milestones and resets after one")
    func periodicGateCadence() {
        var ledger = AgentGoalMilestoneLedger(gateInterval: 3)
        #expect(!ledger.nextMilestoneNeedsPeriodicGate)

        for index in 1...3 {
            ledger.append(milestone("1.250.0-rc\(index)"))
        }
        #expect(ledger.nextMilestoneNeedsPeriodicGate)

        ledger.append(AgentGoalMilestoneLedger.periodicGate(
            version: "1.250.0-rc4",
            verification: "full suite",
            gitContract: "gate only"
        ))
        #expect(!ledger.nextMilestoneNeedsPeriodicGate)
    }

    @Test("gate interval defaults to 40 and never degenerates to zero")
    func gateIntervalIsSane() {
        #expect(AgentGoalMilestoneLedger().gateInterval == 40)
        #expect(AgentGoalMilestoneLedger(gateInterval: 0).gateInterval == 1)
        #expect(AgentGoalMilestoneLedger(gateInterval: -5).gateInterval == 1)
    }

    // MARK: Cross-validation

    @Test("a milestone can only be signed off by the role's named validator")
    func signOffGoesThroughCrossValidation() {
        var ledger = AgentGoalMilestoneLedger()
        ledger.append(milestone("1.251.0-rc1"))
        let roster = AgentGoalTeamRoster.builtIn

        // The developer cannot sign its own milestone off.
        #expect(!ledger.signOff(
            version: "1.251.0-rc1",
            byRoleID: AgentGoalTeamRoster.developerID,
            forRoleID: AgentGoalTeamRoster.developerID,
            roster: roster
        ))
        #expect(!ledger.milestones[0].isSignedOff)

        #expect(ledger.signOff(
            version: "1.251.0-rc1",
            byRoleID: AgentGoalTeamRoster.reviewerID,
            forRoleID: AgentGoalTeamRoster.developerID,
            roster: roster
        ))
        #expect(ledger.milestones[0].signedOffBy == AgentGoalTeamRoster.reviewerID)
    }

    // MARK: Capsule

    @Test("a read-only member reporting touched files contradicts itself")
    func capsuleSelfReportIsChecked() {
        var capsule = AgentGoalTeamCapsule(
            role: "reviewer",
            milestone: "1.251.0-rc1",
            conclusion: "Scope holds.",
            constraintsHonored: .init(readOnly: true, scope: "stayed in locked scope", commandsRun: [])
        )
        #expect(capsule.selfReportIsConsistent)

        capsule.filesTouched = ["Xedit/Foo.swift"]
        #expect(!capsule.selfReportIsConsistent)
    }

    @Test("capsules land in .codex/goal-teams/versions/<version>/capsules and keep the wire schema")
    func capsuleIsArchived() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let capsule = AgentGoalTeamCapsule(
            role: "tester",
            milestone: "1.252.0-rc1",
            conclusion: "128 passed, 0 failed.",
            evidence: [.init(kind: "test-report", path: "build/report.json", summary: "128 passed")],
            constraintsHonored: .init(
                readOnly: true,
                scope: "did not leave locked scope",
                commandsRun: ["ruby scripts/run_tests_fast.rb"]
            ),
            nextSuggestion: "rc2 should only fix X"
        )
        let url = try #require(AgentGoalTeamArchive.writeCapsule(capsule, workspacePath: workspace.path))

        #expect(url.path.contains(".codex/goal-teams/versions/1.252.0-rc1/capsules"))
        let raw = try String(contentsOf: url, encoding: .utf8)
        // The JSON keys are the cross-repo contract, so they are asserted as
        // written, not as Swift property names.
        #expect(raw.contains("\"schema\" : \"goal-teams.capsule.v1\""))
        #expect(raw.contains("\"constraints_honored\""))
        #expect(raw.contains("\"files_touched\""))
        #expect(raw.contains("\"next_suggestion\""))
    }

    @Test("the archive index is created once with a schema header and never duplicates a version")
    func indexIsIdempotent() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        #expect(AgentGoalTeamArchive.appendIndexEntry(
            workspacePath: workspace.path, version: "1.252.0-rc1", status: "done", summary: "profiles merge"
        ))
        #expect(AgentGoalTeamArchive.appendIndexEntry(
            workspacePath: workspace.path, version: "1.252.0-rc1", status: "done", summary: "written twice"
        ))

        let text = try String(
            contentsOf: AgentGoalTeamArchive.indexURL(workspacePath: workspace.path),
            encoding: .utf8
        )
        #expect(text.contains("goal-teams.v1"))
        #expect(text.components(separatedBy: "| 1.252.0-rc1 |").count == 2)
    }

    // MARK: Cross-milestone memory

    @Test("a role's memory file is read back for the next milestone")
    func roleMemoryIsRecalled() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        var role = try #require(AgentGoalTeamRoster.builtIn.role(id: AgentGoalTeamRoster.testerID))
        role.memoryFileName = "qa-notes.md"
        #expect(AgentGoalTeamArchive.memoryText(for: role, workspacePath: workspace.path) == nil)

        let directory = AgentGoalTeamRoleStore.directoryURL(workspacePath: workspace.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "- WorkflowPipelineTests 的 watchdog 用例在满载下 flaky\n"
            .write(to: directory.appendingPathComponent("qa-notes.md"), atomically: true, encoding: .utf8)

        let recalled = AgentGoalTeamArchive.memoryText(for: role, workspacePath: workspace.path)
        #expect(recalled?.contains("flaky") == true)

        // A role without a memory file simply has no memory — not an error.
        var forgetful = role
        forgetful.memoryFileName = nil
        #expect(AgentGoalTeamArchive.memoryText(for: forgetful, workspacePath: workspace.path) == nil)
    }
}
