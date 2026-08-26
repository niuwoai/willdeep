import Foundation
import Testing
@testable import WillDeep

@Suite
nonisolated struct AgentDelegatedTaskControlTests {
    @Test("task contract uses goal checklist and clamps retry budget")
    func contractUsesGoalChecklist() {
        let goal = AgentGoal(
            statement: "Ship delegated acceptance",
            checklist: [
                .init(text: "Persist evidence"),
                .init(text: "Reject missing checks")
            ]
        )

        let contract = AgentDelegatedTaskControl.makeContract(
            objective: "  Implement the control plane.  ",
            executor: .codexCLI,
            goal: goal,
            allowedPaths: ["Xedit/**"],
            verificationCommands: ["  xcodebuild test  "],
            maxAttempts: 99,
            timeoutSeconds: 10
        )

        #expect(contract.schemaVersion == 2)
        #expect(contract.objective == "Implement the control plane.")
        #expect(contract.acceptanceCriteria.map(\.id) == ["AC-01", "AC-02"])
        #expect(contract.acceptanceCriteria.map(\.statement) == [
            "Persist evidence",
            "Reject missing checks"
        ])
        #expect(contract.allowedPaths == ["Xedit/**"])
        #expect(contract.verificationCommands == ["xcodebuild test"])
        #expect(contract.maxAttempts == 3)
        #expect(contract.timeoutSeconds == 60)
    }

    @Test("fresh review parser uses the last valid marked evidence")
    func parsesLastMarkedEvidence() {
        let output = """
        WILLDEEP_EXECUTOR_EVIDENCE_BEGIN
        {"schema_version":1,"verdict":"failed","summary":"old","criteria":[],"checks":[],"changed_paths":[],"known_risks":[]}
        WILLDEEP_EXECUTOR_EVIDENCE_END

        WILLDEEP_EXECUTOR_EVIDENCE_BEGIN
        {"schema_version":1,"verdict":"passed","summary":"fresh","criteria":[{"criterion_id":"AC-01","status":"passed","detail":"diff inspected"}],"checks":[],"changed_paths":["Xedit/File.swift"],"known_risks":[]}
        WILLDEEP_EXECUTOR_EVIDENCE_END
        """

        let evidence = AgentDelegatedTaskControl.parseExecutorEvidence(from: output)

        #expect(evidence?.verdict == .passed)
        #expect(evidence?.summary == "fresh")
        #expect(evidence?.criteria.first?.criterionID == "AC-01")
        #expect(evidence?.changedPaths == ["Xedit/File.swift"])
    }

    @Test("acceptance rejects missing criteria and sensitive changes")
    func rejectsIncompleteOrSensitiveEvidence() {
        let contract = AgentDelegatedTaskContract(
            objective: "Change one file",
            executor: .claudeCode,
            acceptanceCriteria: [
                .init(id: "AC-01", statement: "Implementation is complete"),
                .init(id: "AC-02", statement: "Tests pass")
            ],
            allowedPaths: ["**"]
        )
        let evidence = AgentDelegatedExecutorEvidence(
            schemaVersion: 1,
            verdict: .passed,
            summary: "Looks complete",
            criteria: [
                .init(criterionID: "AC-01", status: .passed, detail: "Diff inspected")
            ],
            checks: [],
            changedPaths: [".env"],
            knownRisks: []
        )

        let acceptance = AgentDelegatedTaskControl.structuralAcceptance(
            contract: contract,
            evidence: evidence,
            changedPaths: [".env"],
            rerunChecks: []
        )

        #expect(acceptance.accepted == false)
        #expect(acceptance.findings.contains(where: { $0.contains("AC-02") }))
        #expect(acceptance.findings.contains(where: { $0.contains("Sensitive files") }))
    }

    @Test("acceptance passes only with complete evidence and host rerun")
    func acceptsCompleteEvidence() {
        let contract = AgentDelegatedTaskContract(
            objective: "Change one file",
            executor: .codexCLI,
            acceptanceCriteria: [
                .init(id: "AC-01", statement: "Implementation is complete")
            ],
            allowedPaths: ["Xedit/**"]
        )
        let evidence = AgentDelegatedExecutorEvidence(
            schemaVersion: 1,
            verdict: .passed,
            summary: "Diff and test inspected",
            criteria: [
                .init(criterionID: "AC-01", status: .passed, detail: "Implemented")
            ],
            checks: [],
            changedPaths: ["Xedit/File.swift"],
            knownRisks: []
        )
        let hostCheck = AgentDelegatedHostCheck(
            id: "host-rerun-1",
            label: "Unit tests",
            status: .passed,
            detail: "Passed",
            command: "xcodebuild test",
            exitCode: 0
        )

        let acceptance = AgentDelegatedTaskControl.structuralAcceptance(
            contract: contract,
            evidence: evidence,
            changedPaths: ["Xedit/File.swift"],
            rerunChecks: [hostCheck]
        )

        #expect(acceptance.accepted)
        #expect(acceptance.findings.isEmpty)
        #expect(acceptance.checks.allSatisfy { $0.status == .passed })
    }

    @Test("verification command selection deduplicates and caps host reruns")
    func verificationCommandsAreBounded() {
        let contract = AgentDelegatedTaskContract(
            objective: "Verify",
            executor: .codexCLI,
            acceptanceCriteria: [.init(id: "AC-01", statement: "Pass")],
            verificationCommands: ["swift test", "swift test", "xcodebuild build", "ruby verify.rb"]
        )
        let evidence = AgentDelegatedExecutorEvidence(
            schemaVersion: 1,
            verdict: .passed,
            summary: "Reviewed",
            criteria: [.init(criterionID: "AC-01", status: .passed, detail: "ok")],
            checks: [
                .init(
                    id: "check-1",
                    label: "Extra",
                    command: "go test ./...",
                    status: .passed,
                    exitCode: 0,
                    detail: "ok"
                )
            ],
            changedPaths: [],
            knownRisks: []
        )

        let commands = AgentDelegatedTaskControl.verificationCommands(
            contract: contract,
            evidence: evidence
        )

        #expect(commands == ["swift test", "xcodebuild build", "ruby verify.rb"])
    }

    @Test("delegated ledger survives session JSON round trip")
    func ledgerPersistsInSession() throws {
        let contract = AgentDelegatedTaskContract(
            objective: "Persist me",
            executor: .claudeCode,
            acceptanceCriteria: [.init(id: "AC-01", statement: "Persisted")]
        )
        var run = AgentDelegatedTaskRun(contract: contract)
        run.phase = .readyForDelivery
        run.attempt = 2
        run.finishedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let session = AgentSession(delegatedTaskRuns: [run])

        let data = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(AgentSession.self, from: data)

        #expect(restored.delegatedTaskRuns == [run])
    }
}
