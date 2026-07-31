//
//  AgentDelegatedTaskControl.swift
//  WillDeep
//
//  Host-owned control plane for delegated coding agents. External CLIs may
//  execute and self-review work, but only WillDeep owns the durable contract,
//  acceptance state, evidence ledger, retry budget, and delivery verdict.
//

import Foundation

nonisolated enum AgentDelegatedTaskRisk: String, Codable, Equatable, Sendable {
    case readOnly = "read_only"
    case workspaceWrite = "workspace_write"
    case externalSideEffect = "external_side_effect"
}

nonisolated enum AgentDelegatedTaskPhase: String, Codable, Equatable, Sendable {
    case contracted
    case executing
    case selfVerifying = "self_verifying"
    case willDeepVerifying = "willdeep_verifying"
    case reworkRequired = "rework_required"
    case readyForDelivery = "ready_for_delivery"
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .readyForDelivery, .failed, .cancelled:
            return true
        case .contracted, .executing, .selfVerifying, .willDeepVerifying, .reworkRequired:
            return false
        }
    }
}

nonisolated struct AgentDelegatedAcceptanceCriterion: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let statement: String
    let required: Bool

    init(id: String, statement: String, required: Bool = true) {
        self.id = id
        self.statement = statement
        self.required = required
    }
}

nonisolated struct AgentDelegatedTaskContract: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let id: UUID
    let objective: String
    let executorID: String
    let executorName: String
    let createdAt: Date
    let risk: AgentDelegatedTaskRisk
    let acceptanceCriteria: [AgentDelegatedAcceptanceCriterion]
    let allowedPaths: [String]
    let forbiddenActions: [String]
    let verificationCommands: [String]
    let maxAttempts: Int
    let timeoutSeconds: Int
    let requiresFreshSelfReview: Bool
    let requiresWillDeepVerification: Bool

    init(
        id: UUID = UUID(),
        objective: String,
        executor: AgentExecutionAgent,
        risk: AgentDelegatedTaskRisk = .workspaceWrite,
        acceptanceCriteria: [AgentDelegatedAcceptanceCriterion],
        allowedPaths: [String] = ["**"],
        forbiddenActions: [String] = [
            "git commit",
            "git push",
            "release or deployment",
            "production access",
            "database mutation outside the workspace",
            "sending external messages"
        ],
        verificationCommands: [String] = [],
        maxAttempts: Int = 2,
        timeoutSeconds: Int = 21_600,
        requiresFreshSelfReview: Bool = true,
        requiresWillDeepVerification: Bool = true,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.objective = objective
        self.executorID = executor.rawValue
        self.executorName = executor.displayName
        self.createdAt = createdAt
        self.risk = risk
        self.acceptanceCriteria = acceptanceCriteria
        self.allowedPaths = allowedPaths.isEmpty ? ["**"] : allowedPaths
        self.forbiddenActions = forbiddenActions
        self.verificationCommands = Array(verificationCommands.prefix(6))
        self.maxAttempts = min(max(maxAttempts, 1), 3)
        self.timeoutSeconds = min(max(timeoutSeconds, 60), 21_600)
        self.requiresFreshSelfReview = requiresFreshSelfReview
        self.requiresWillDeepVerification = requiresWillDeepVerification
    }
}

nonisolated enum AgentDelegatedEvidenceStatus: String, Codable, Equatable, Sendable {
    case passed
    case failed
    case skipped
    case inconclusive
}

nonisolated struct AgentDelegatedCriterionEvidence: Codable, Equatable, Identifiable, Sendable {
    let criterionID: String
    let status: AgentDelegatedEvidenceStatus
    let detail: String

    var id: String { criterionID }

    private enum CodingKeys: String, CodingKey {
        case criterionID = "criterion_id"
        case status
        case detail
    }
}

nonisolated struct AgentDelegatedCheckEvidence: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let command: String?
    let status: AgentDelegatedEvidenceStatus
    let exitCode: Int?
    let detail: String

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case command
        case status
        case exitCode = "exit_code"
        case detail
    }
}

nonisolated struct AgentDelegatedExecutorEvidence: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let verdict: AgentDelegatedEvidenceStatus
    let summary: String
    let criteria: [AgentDelegatedCriterionEvidence]
    let checks: [AgentDelegatedCheckEvidence]
    let changedPaths: [String]
    let knownRisks: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case verdict
        case summary
        case criteria
        case checks
        case changedPaths = "changed_paths"
        case knownRisks = "known_risks"
    }
}

nonisolated struct AgentDelegatedHostCheck: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let status: AgentDelegatedEvidenceStatus
    let detail: String
    let command: String?
    let exitCode: Int?

    init(
        id: String,
        label: String,
        status: AgentDelegatedEvidenceStatus,
        detail: String,
        command: String? = nil,
        exitCode: Int? = nil
    ) {
        self.id = id
        self.label = label
        self.status = status
        self.detail = detail
        self.command = command
        self.exitCode = exitCode
    }
}

nonisolated struct AgentDelegatedWillDeepAcceptance: Codable, Equatable, Sendable {
    let accepted: Bool
    let summary: String
    let checks: [AgentDelegatedHostCheck]
    let findings: [String]
    let verifiedAt: Date
}

nonisolated struct AgentDelegatedTaskRun: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let contract: AgentDelegatedTaskContract
    var phase: AgentDelegatedTaskPhase
    var attempt: Int
    var startedAt: Date?
    var finishedAt: Date?
    var executorEvidence: AgentDelegatedExecutorEvidence?
    var willDeepAcceptance: AgentDelegatedWillDeepAcceptance?
    var changedPaths: [String]
    var lastError: String?

    init(contract: AgentDelegatedTaskContract) {
        self.id = contract.id
        self.contract = contract
        self.phase = .contracted
        self.attempt = 0
        self.startedAt = nil
        self.finishedAt = nil
        self.executorEvidence = nil
        self.willDeepAcceptance = nil
        self.changedPaths = []
        self.lastError = nil
    }
}

/// Ephemeral progress rendered while an external CLI is running. The durable
/// acceptance ledger remains `AgentDelegatedTaskRun`; this snapshot deliberately
/// keeps only a bounded, redacted output tail and is never written to session JSON.
nonisolated struct AgentDelegatedLiveProgress: Equatable, Sendable {
    var phase: AgentDelegatedTaskPhase
    var attempt: Int
    var maximumAttempts: Int
    var terminalTabID: UUID?
    var currentActivity: String?
    var recentOutput: String?

    init(
        phase: AgentDelegatedTaskPhase = .contracted,
        attempt: Int = 0,
        maximumAttempts: Int,
        terminalTabID: UUID? = nil,
        currentActivity: String? = nil,
        recentOutput: String? = nil
    ) {
        self.phase = phase
        self.attempt = attempt
        self.maximumAttempts = maximumAttempts
        self.terminalTabID = terminalTabID
        self.currentActivity = currentActivity
        self.recentOutput = recentOutput
    }
}

/// Bounded terminal update emitted by the delegated runner after secret
/// redaction. AppState merges it into the matching tool-call presentation.
nonisolated struct AgentDelegatedTerminalProgressUpdate: Equatable, Sendable {
    let terminalTabID: UUID
    let currentActivity: String?
    let recentOutput: String?
}

nonisolated enum AgentDelegatedTaskControl {
    static let evidenceStartMarker = "WILLDEEP_EXECUTOR_EVIDENCE_BEGIN"
    static let evidenceEndMarker = "WILLDEEP_EXECUTOR_EVIDENCE_END"

    static func makeContract(
        objective rawObjective: String,
        executor: AgentExecutionAgent,
        goal: AgentGoal?,
        acceptanceCriteria explicitCriteria: [String] = [],
        allowedPaths: [String] = ["**"],
        verificationCommands: [String] = [],
        maxAttempts: Int = 2,
        timeoutSeconds: Int = 21_600
    ) -> AgentDelegatedTaskContract {
        let objective = clipped(rawObjective.trimmingCharacters(in: .whitespacesAndNewlines), limit: 12_000)
        let goalCriteria = goal?.checklist.map(\.text) ?? []
        let sourceCriteria = !explicitCriteria.isEmpty
            ? explicitCriteria
            : (!goalCriteria.isEmpty ? goalCriteria : defaultCriteria)
        let criteria: [AgentDelegatedAcceptanceCriterion] = sourceCriteria.enumerated().compactMap {
            offset, raw -> AgentDelegatedAcceptanceCriterion? in
            let statement = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !statement.isEmpty else { return nil }
            return AgentDelegatedAcceptanceCriterion(
                id: String(format: "AC-%02d", offset + 1),
                statement: clipped(statement, limit: 1_200)
            )
        }
        return AgentDelegatedTaskContract(
            objective: objective,
            executor: executor,
            acceptanceCriteria: criteria,
            allowedPaths: normalizedPaths(allowedPaths),
            verificationCommands: sanitizedCommands(verificationCommands),
            maxAttempts: maxAttempts,
            timeoutSeconds: timeoutSeconds
        )
    }

    static func contractJSON(_ contract: AgentDelegatedTaskContract) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(contract),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    static func executorInstructions(contract: AgentDelegatedTaskContract) -> String {
        """
        ### WillDeep delegated-task contract

        The JSON contract below is host-owned. Do not weaken, replace, or silently ignore its acceptance criteria, allowed paths, forbidden actions, retry limit, or verification requirements.

        ```json
        \(contractJSON(contract))
        ```

        Work protocol:
        1. Inspect repository instructions before editing.
        2. Keep every change inside `allowed_paths`; treat `forbidden_actions` as hard prohibitions.
        3. Run the most relevant repository-native checks. Do not invent a build command when the repository provides no evidence for it.
        4. Before reporting completion, review the actual diff against every acceptance criterion.
        5. A later fresh read-only reviewer and WillDeep will independently verify the work. Do not mark an unverified criterion as passed.
        6. Keep commits, pushes, releases, deployments, external messages, production access, and external database writes outside this task unless the contract explicitly permits them.
        """
    }

    static func freshReviewPrompt(
        contract: AgentDelegatedTaskContract,
        changedPaths: [String],
        executionOutput: String
    ) -> String {
        let paths = changedPaths.isEmpty ? "(no host-attributed changed paths)" : changedPaths.joined(separator: "\n- ")
        return """
        You are the fresh, read-only acceptance reviewer for a delegated coding task. You did not perform the implementation. Do not edit files, do not commit, do not push, and do not lower the contract.

        \(executorInstructions(contract: contract))

        Host-attributed changed paths:
        - \(paths)

        Compact execution handoff:
        \(clipped(executionOutput, limit: 8_000))

        Inspect the current workspace and diff. Verify every acceptance criterion and check the claimed commands/results when practical. Then emit exactly one JSON evidence object between these markers:

        \(evidenceStartMarker)
        {
          "schema_version": 1,
          "verdict": "passed | failed | inconclusive",
          "summary": "short evidence-based summary",
          "criteria": [
            {"criterion_id": "AC-01", "status": "passed | failed | skipped | inconclusive", "detail": "evidence"}
          ],
          "checks": [
            {"id": "check-1", "label": "test/build/lint/diff check", "command": "exact command or null", "status": "passed | failed | skipped | inconclusive", "exit_code": 0, "detail": "evidence"}
          ],
          "changed_paths": ["workspace/relative/path"],
          "known_risks": ["remaining risk"]
        }
        \(evidenceEndMarker)

        Use valid JSON, include every contract criterion exactly once, and never claim a command ran unless you observed its result.
        """
    }

    static func reworkPrompt(
        contract: AgentDelegatedTaskContract,
        findings: [String],
        attempt: Int
    ) -> String {
        """
        WillDeep rejected delegated task \(contract.id.uuidString) after attempt \(attempt).
        Continue in the current workspace and address only the findings below without weakening the original contract.

        \(executorInstructions(contract: contract))

        Rework findings:
        \(findings.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

        Re-run relevant verification. Do not commit or push. Return a concise implementation handoff; a fresh read-only review will run again.
        """
    }

    static func parseExecutorEvidence(from output: String) -> AgentDelegatedExecutorEvidence? {
        guard let json = lastMarkedBody(
            in: output,
            startMarker: evidenceStartMarker,
            endMarker: evidenceEndMarker
        ), let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(AgentDelegatedExecutorEvidence.self, from: data)
    }

    static func verificationCommands(
        contract: AgentDelegatedTaskContract,
        evidence: AgentDelegatedExecutorEvidence?
    ) -> [String] {
        let evidenceCommands = evidence?.checks.compactMap { check -> String? in
            guard check.status == .passed,
                  let command = check.command?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty else {
                return nil
            }
            return command
        } ?? []
        var seen = Set<String>()
        return sanitizedCommands(contract.verificationCommands + evidenceCommands)
            .filter { seen.insert($0).inserted }
            .prefix(3)
            .map { $0 }
    }

    static func structuralAcceptance(
        contract: AgentDelegatedTaskContract,
        evidence: AgentDelegatedExecutorEvidence?,
        changedPaths: [String],
        rerunChecks: [AgentDelegatedHostCheck]
    ) -> AgentDelegatedWillDeepAcceptance {
        var checks: [AgentDelegatedHostCheck] = []
        var findings: [String] = []

        if let evidence {
            let status: AgentDelegatedEvidenceStatus = evidence.verdict == .passed ? .passed : .failed
            checks.append(.init(
                id: "executor-evidence",
                label: "Fresh executor self-review",
                status: status,
                detail: evidence.summary
            ))
            if evidence.verdict != .passed {
                findings.append("Fresh executor review verdict is \(evidence.verdict.rawValue): \(evidence.summary)")
            }
        } else {
            checks.append(.init(
                id: "executor-evidence",
                label: "Fresh executor self-review",
                status: .failed,
                detail: "No valid structured evidence block was produced."
            ))
            findings.append("The fresh executor review did not produce a valid structured evidence block.")
        }

        let evidenceByCriterion = Dictionary(
            evidence?.criteria.map { ($0.criterionID, $0) } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        for criterion in contract.acceptanceCriteria where criterion.required {
            let item = evidenceByCriterion[criterion.id]
            let status = item?.status ?? .inconclusive
            checks.append(.init(
                id: "criterion-\(criterion.id)",
                label: criterion.statement,
                status: status,
                detail: item?.detail ?? "No evidence was supplied for \(criterion.id)."
            ))
            if status != .passed {
                findings.append("\(criterion.id) is \(status.rawValue): \(item?.detail ?? "missing evidence")")
            }
        }

        let outOfScope = changedPaths.filter { !path($0, matchesAny: contract.allowedPaths) }
        if outOfScope.isEmpty {
            checks.append(.init(
                id: "scope",
                label: "Workspace change scope",
                status: .passed,
                detail: changedPaths.isEmpty
                    ? "No new host-attributed workspace changes."
                    : "\(changedPaths.count) changed path(s) are inside the contract scope."
            ))
        } else {
            checks.append(.init(
                id: "scope",
                label: "Workspace change scope",
                status: .failed,
                detail: "Out-of-scope paths: \(outOfScope.joined(separator: ", "))"
            ))
            findings.append("Out-of-scope changes must be reverted or explicitly authorized: \(outOfScope.joined(separator: ", ")).")
        }

        let sensitivePaths = changedPaths.filter(isSensitivePath)
        if sensitivePaths.isEmpty {
            checks.append(.init(
                id: "sensitive-paths",
                label: "Sensitive-file boundary",
                status: .passed,
                detail: "No changed path matches WillDeep's sensitive-file patterns."
            ))
        } else {
            checks.append(.init(
                id: "sensitive-paths",
                label: "Sensitive-file boundary",
                status: .failed,
                detail: "Sensitive paths changed: \(sensitivePaths.joined(separator: ", "))"
            ))
            findings.append("Sensitive files changed and require explicit review: \(sensitivePaths.joined(separator: ", ")).")
        }

        checks.append(contentsOf: rerunChecks)
        for check in rerunChecks where check.status != .passed {
            findings.append("WillDeep verification failed: \(check.label) — \(check.detail)")
        }

        let accepted = findings.isEmpty && checks.allSatisfy { check in
            check.status == .passed || check.status == .skipped
        }
        return AgentDelegatedWillDeepAcceptance(
            accepted: accepted,
            summary: accepted
                ? "Executor self-review and WillDeep verification passed."
                : "WillDeep found \(findings.count) acceptance issue(s).",
            checks: checks,
            findings: findings,
            verifiedAt: Date()
        )
    }

    static func isSafeVerificationCommand(_ command: String, workspaceURL: URL?) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2_000 else { return false }
        let lowered = " \(trimmed.lowercased()) "
        let forbiddenFragments = [
            " git commit", " git push", " git tag", " gh pr", " curl ", " wget ",
            " ssh ", " scp ", " rsync ", " rm ", " sudo ", " deploy", " release"
        ]
        guard !forbiddenFragments.contains(where: lowered.contains) else { return false }
        let decision = AgentSandboxPolicy.commandDecision(
            command: trimmed,
            rootDirectory: workspaceURL
        )
        return !decision.requiresTypedConfirmation && decision.mode != .escalated
    }

    private static let defaultCriteria = [
        "The requested change or analysis is complete and directly addresses the user objective.",
        "Changes stay within the requested scope and preserve unrelated user work.",
        "Relevant repository-native verification passes, or every unavailable check is explicitly reported with a reason.",
        "The final handoff lists changed files, verification performed, and any remaining risk."
    ]

    private static func normalizedPaths(_ paths: [String]) -> [String] {
        let values = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(100)
        return values.isEmpty ? ["**"] : Array(values)
    }

    private static func sanitizedCommands(_ commands: [String]) -> [String] {
        commands
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { clipped($0, limit: 2_000) }
    }

    private static func lastMarkedBody(
        in value: String,
        startMarker: String,
        endMarker: String
    ) -> String? {
        guard let start = value.range(of: startMarker, options: .backwards) else { return nil }
        let bodyStart = start.upperBound
        guard let end = value.range(of: endMarker, range: bodyStart..<value.endIndex) else { return nil }
        return String(value[bodyStart..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func path(_ candidate: String, matchesAny patterns: [String]) -> Bool {
        let normalized = candidate.replacingOccurrences(of: "\\", with: "/")
        return patterns.contains { rawPattern in
            let pattern = rawPattern.replacingOccurrences(of: "\\", with: "/")
            if pattern == "**" || pattern == "*" { return true }
            if pattern.hasSuffix("/**") {
                let prefix = String(pattern.dropLast(3)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return normalized == prefix || normalized.hasPrefix(prefix + "/")
            }
            if pattern.hasSuffix("/*") {
                let prefix = String(pattern.dropLast(2)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard normalized.hasPrefix(prefix + "/") else { return false }
                return !normalized.dropFirst(prefix.count + 1).contains("/")
            }
            return normalized == pattern
        }
    }

    private static func isSensitivePath(_ path: String) -> Bool {
        let lowered = "/" + path.lowercased()
        let fileName = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if fileName == ".env" || fileName.hasPrefix(".env.") {
            return !fileName.hasSuffix(".example")
        }
        return [
            "/.ssh/", "/.gnupg/", "/.aws/", "/credentials", "/secrets/",
            "id_rsa", "id_ed25519", ".p12", ".pem", ".key"
        ].contains(where: lowered.contains)
    }

    private static func clipped(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let end = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<end]) + "\n[truncated]"
    }
}
