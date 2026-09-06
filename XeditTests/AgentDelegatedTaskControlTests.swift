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

    @Test("verification command selection deduplicates without dropping required checks")
    func verificationCommandsPreserveRequiredChecks() {
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

        #expect(commands == ["swift test", "xcodebuild build", "ruby verify.rb", "go test ./..."])
    }

    @Test("宿主缺失、跳过或没有退出成功回执均不能验收", arguments: ["missing", "skipped", "no-exit", "failed-exit", "wrong-command"])
    func rejectsMissingHostReceipt(scenario: String) {
        let contract = AgentDelegatedTaskContract(
            objective: "Implement", executor: .codexCLI,
            acceptanceCriteria: [.init(id: "AC-01", statement: "Tests pass")],
            verificationCommands: ["swift test"]
        )
        let evidence = AgentDelegatedExecutorEvidence(
            schemaVersion: 1, verdict: .passed, summary: "Claims done",
            criteria: [.init(criterionID: "AC-01", status: .passed, detail: "Claims verified")],
            checks: [], changedPaths: [], knownRisks: []
        )
        let check = AgentDelegatedHostCheck(
            id: "host", label: "Tests", status: scenario == "skipped" ? .skipped : .passed,
            detail: "Fixture", command: scenario == "wrong-command" ? "git status" : "swift test",
            exitCode: scenario == "no-exit" ? nil : (scenario == "failed-exit" ? 1 : 0)
        )
        let acceptance = AgentDelegatedTaskControl.structuralAcceptance(
            contract: contract, evidence: evidence, changedPaths: [], rerunChecks: scenario == "missing" ? [] : [check]
        )
        #expect(!acceptance.accepted)
        #expect(!acceptance.findings.isEmpty)
    }

    @Test("未指定命令的任务也不能凭空验收结果集通过")
    func emptyHostResultsCannotPassWithoutDeclaredCommands() {
        let contract = AgentDelegatedTaskContract(
            objective: "Analyze", executor: .codexCLI,
            acceptanceCriteria: [.init(id: "AC-01", statement: "Verified analysis")]
        )
        let evidence = AgentDelegatedExecutorEvidence(
            schemaVersion: 1, verdict: .passed, summary: "Claims done",
            criteria: [.init(criterionID: "AC-01", status: .passed, detail: "Claim")],
            checks: [], changedPaths: [], knownRisks: []
        )
        #expect(!AgentDelegatedTaskControl.structuralAcceptance(
            contract: contract, evidence: evidence, changedPaths: [], rerunChecks: []
        ).accepted)
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

    @Test("a review run that never started says so instead of blaming the evidence block")
    func surfacesReviewRunFailure() {
        let contract = AgentDelegatedTaskContract(
            objective: "Say hello",
            executor: .codexCLI,
            acceptanceCriteria: [.init(id: "AC-01", statement: "Answers the user")]
        )

        let acceptance = AgentDelegatedTaskControl.structuralAcceptance(
            contract: contract,
            evidence: nil,
            changedPaths: [],
            rerunChecks: [],
            evidenceFailure: "codex exited without returning any output"
        )

        #expect(acceptance.accepted == false)
        // 用户此前看到的是「没产出结构化证据块」，于是去查执行器的输出格式；
        // 真正的事实是那一趟根本没跑成，原因必须原样带出来。
        #expect(acceptance.findings.contains(where: { $0.contains("without returning any output") }))
        #expect(!acceptance.findings.contains("The fresh executor review did not produce a valid structured evidence block."))
    }

    @Test("an executor that exits silently is reported as a failure, not an empty success")
    func emptyExecutorOutputReadsAsFailure() {
        let message = AgentStructuredExecutorDiagnostics.emptyOutputMessage(executor: "codex_cli")
        #expect(message.contains("codex_cli"))
        #expect(message.contains("without returning any output"))
        // 别再让用户从一串验收条目里反推「执行器没装好 / 没登录」
        #expect(message.contains("signed in"))
    }
}
