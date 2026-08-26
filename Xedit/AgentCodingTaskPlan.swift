//
//  AgentCodingTaskPlan.swift
//  WillDeep
//
//  Structured hand-off between the read-only scout and the automatic coding
//  lane. The scout proposes scope; the host independently clamps risk and
//  write authority before any model is allowed to edit.
//

import Foundation

nonisolated enum AgentCodingRiskLevel: String, Codable, CaseIterable, Sendable {
    case green
    case yellow
    case orange
    case red

    var rank: Int {
        switch self {
        case .green: return 0
        case .yellow: return 1
        case .orange: return 2
        case .red: return 3
        }
    }

    static func max(_ lhs: Self, _ rhs: Self) -> Self {
        lhs.rank >= rhs.rank ? lhs : rhs
    }
}

nonisolated struct AgentCodingTaskPlan: Codable, Equatable, Sendable {
    static let automaticMaximumWriteCount = 3

    var goal: String
    var readFiles: [String]
    var writeFiles: [String]
    var symbols: [String]
    var knownFacts: [String]
    var constraints: [String]
    var verifierCommand: String
    var suggestedRiskLevel: AgentCodingRiskLevel
    var riskFlags: [String]
    var unresolved: [String]

    enum CodingKeys: String, CodingKey {
        case goal
        case readFiles = "read_files"
        case writeFiles = "write_files"
        case symbols
        case knownFacts = "known_facts"
        case constraints
        case verifierCommand = "verifier_command"
        case suggestedRiskLevel = "suggested_risk_level"
        case riskFlags = "risk_flags"
        case unresolved
    }

    static var schema: AgentStructuredSchema {
        let string = { (description: String) in
            AgentStructuredSchema(type: .string, description: description)
        }
        let strings = { (description: String, maxItems: Int) in
            AgentStructuredSchema(
                type: .array,
                items: AgentStructuredSchema(type: .string),
                minItems: 0,
                maxItems: maxItems,
                description: description
            )
        }
        return AgentStructuredSchema(
            type: .object,
            properties: [
                "goal": string("A precise, testable description of done."),
                "read_files": strings("Workspace-relative context paths.", 12),
                "write_files": strings("Exact workspace-relative paths that may change.", 16),
                "symbols": strings("Relevant symbols or call sites already located.", 20),
                "known_facts": strings("Facts confirmed by inspection, not guesses.", 20),
                "constraints": strings("Compatibility and scope constraints.", 20),
                "verifier_command": string("The narrowest command whose exit 0 proves success, or an empty string if unknown."),
                "suggested_risk_level": AgentStructuredSchema(
                    type: .string,
                    enumValues: AgentCodingRiskLevel.allCases.map { .string($0.rawValue) }
                ),
                "risk_flags": strings("Concrete risk signals found in the code or request.", 20),
                "unresolved": strings("Questions that prevent bounded autonomous implementation.", 12),
            ],
            required: [
                "goal", "read_files", "write_files", "symbols", "known_facts",
                "constraints", "verifier_command", "suggested_risk_level",
                "risk_flags", "unresolved",
            ],
            additionalProperties: false,
            description: "A bounded coding task packet discovered by a read-only scout."
        )
    }

    func taskPacket(maxAttempts: Int = 2) -> AgentSubagentTaskPacket {
        AgentSubagentTaskPacket(
            goal: goal,
            skill: nil,
            readFiles: readFiles,
            writeFiles: writeFiles,
            relevantFiles: [],
            knownFacts: knownFacts + symbols.map { "Relevant symbol: \($0)" },
            constraints: constraints,
            verifierCommand: verifierCommand.trimmingCharacters(in: .whitespacesAndNewlines),
            maxAttempts: maxAttempts
        )
    }

    var normalizedWriteAccess: AgentSubagentWriteAccess? {
        AgentSubagentWriteAccess(targetRelativePaths: writeFiles)
    }

    func automaticIneligibilityReason(requestText: String) -> String? {
        guard let access = normalizedWriteAccess else {
            return "the scout did not produce a valid bounded write set"
        }
        guard access.targetRelativePaths.count <= Self.automaticMaximumWriteCount else {
            return "the change spans more than three files"
        }
        guard unresolved.isEmpty else {
            return "the scout left unresolved product or implementation questions"
        }
        guard !verifierCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "no deterministic verifier command was found"
        }
        guard access.targetRelativePaths.allSatisfy(Self.isSupportedCodingPath) else {
            return "the write set includes a non-code or high-impact configuration path"
        }
        let risk = AgentCodingRiskPolicy.assess(requestText: requestText, plan: self)
        guard risk.rank <= AgentCodingRiskLevel.yellow.rank else {
            return "host risk policy classified the task as \(risk.rawValue)"
        }
        return nil
    }

    private static func isSupportedCodingPath(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent.lowercased()
        let deniedNames: Set<String> = [
            ".env", "dockerfile", "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
            "project.pbxproj", "contents.xcworkspacedata",
        ]
        guard !deniedNames.contains(filename) else { return false }
        let allowedExtensions: Set<String> = [
            "c", "cc", "cpp", "css", "go", "h", "hpp", "html", "java", "js",
            "jsx", "kt", "kts", "m", "mm", "rb", "rs", "scss", "sh", "sql",
            "swift", "toml", "ts", "tsx", "vue", "xml", "yaml", "yml",
        ]
        return allowedExtensions.contains((path as NSString).pathExtension.lowercased())
    }
}

nonisolated enum AgentCodingRiskPolicy {
    private static let redMarkers = [
        "生产", "线上", "数据库迁移", "删表", "删字段", "权限", "鉴权", "认证",
        "支付", "密钥", "凭据", "令牌", "access token", "api token", "secret", "credential", "migration",
        "production", "permission", "authentication", "authorization", "payment",
        "encryption", "destructive",
    ]
    private static let orangeMarkers = [
        "数据库", "公开 api", "公共 api", "依赖升级", "并发", "线程", "跨端", "跨层",
        "database", "public api", "dependency", "concurrency", "thread safety",
        "schema", "protocol change",
    ]

    static func assess(requestText: String, plan: AgentCodingTaskPlan) -> AgentCodingRiskLevel {
        let evidence = ([requestText, plan.goal] + plan.riskFlags + plan.constraints)
            .joined(separator: "\n")
            .lowercased()
        let deterministic: AgentCodingRiskLevel
        if redMarkers.contains(where: evidence.contains) {
            deterministic = .red
        } else if orangeMarkers.contains(where: evidence.contains)
            || plan.writeFiles.count > AgentCodingTaskPlan.automaticMaximumWriteCount {
            deterministic = .orange
        } else if plan.writeFiles.count == 1 {
            deterministic = .green
        } else {
            deterministic = .yellow
        }
        return .max(deterministic, plan.suggestedRiskLevel)
    }
}

nonisolated struct AgentCodingReview: Codable, Equatable, Sendable {
    enum Verdict: String, Codable, CaseIterable, Sendable {
        case accept
        case reject
        case uncertain
    }

    var verdict: Verdict
    var scopeCompliant: Bool
    var goalSatisfied: Bool
    var requiresHighModel: Bool
    var issues: [String]
    var userSummary: String

    enum CodingKeys: String, CodingKey {
        case verdict
        case scopeCompliant = "scope_compliant"
        case goalSatisfied = "goal_satisfied"
        case requiresHighModel = "requires_high_model"
        case issues
        case userSummary = "user_summary"
    }

    static var schema: AgentStructuredSchema {
        AgentStructuredSchema(
            type: .object,
            properties: [
                "verdict": AgentStructuredSchema(
                    type: .string,
                    enumValues: Verdict.allCases.map { .string($0.rawValue) }
                ),
                "scope_compliant": AgentStructuredSchema(type: .boolean),
                "goal_satisfied": AgentStructuredSchema(type: .boolean),
                "requires_high_model": AgentStructuredSchema(type: .boolean),
                "issues": AgentStructuredSchema(
                    type: .array,
                    items: AgentStructuredSchema(type: .string),
                    minItems: 0,
                    maxItems: 12
                ),
                "user_summary": AgentStructuredSchema(
                    type: .string,
                    description: "A concise final summary in the operator's language."
                ),
            ],
            required: [
                "verdict", "scope_compliant", "goal_satisfied",
                "requires_high_model", "issues", "user_summary",
            ],
            additionalProperties: false
        )
    }

    var acceptsStraightThroughDelivery: Bool {
        verdict == .accept
            && scopeCompliant
            && goalSatisfied
            && !requiresHighModel
            && issues.isEmpty
    }
}
