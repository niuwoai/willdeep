//
//  AgentEnvironmentTrust.swift
//  Xedit
//
//  用户显式声明的环境信任（“这个终端是一次性容器”“这个 mysql 是测试实例”）。
//  声明经 declare_environment_trust 工具建立，必须人工点卡确认后才生效，
//  存活在 AgentRuntime 上——关会话即失效，重开要重新声明。
//  canonical 设计文档：docs/ENVIRONMENT_TRUST_DECLARATIONS.md
//

import Foundation

nonisolated enum AgentEnvironmentTrustKind: String, Codable, Sendable, CaseIterable {
    /// 一次性 / 可随意操作的可见终端环境（docker 容器、临时 VM、用户明说
    /// “本地随便折腾”的 shell）。作用域：terminal_send_command /
    /// terminal_send_control；本机 run_command 不吃终端声明。
    case disposableTerminal = "disposable_terminal"
    /// 测试专用数据库实例。作用域：run_command 与 terminal_send_command 中
    /// 命令文本包含 `target` 子串的调用——不含目标标识的命令不享受声明。
    case testDatabase = "test_database"
    /// 一段部署作业。作用域：run_command 与 terminal_send_command 中**属于
    /// 部署命令族**的命令（见 `AgentDeploymentWindow`）。`target` 可选，
    /// 填了就额外要求命令包含该标识（集群 / namespace / 主机）。
    case deploymentWindow = "deployment_window"

    var displayLabel: String {
        switch self {
        case .disposableTerminal: return "一次性终端环境"
        case .testDatabase: return "测试专用数据库"
        case .deploymentWindow: return "部署作业窗口"
        }
    }
}

nonisolated struct AgentEnvironmentTrustDeclaration: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: AgentEnvironmentTrustKind
    /// testDatabase：命令必须包含的标识子串（容器名 / host / 库名），
    /// 长度下限见 `AgentEnvironmentTrust.minimumDatabaseTargetLength`。
    /// disposableTerminal：可选备注，不参与匹配。
    let target: String
    /// 用户原话，逐字引用。上审批卡给用户对质（注入文本骗 Agent 调工具时，
    /// 用户会看到“我从没说过这话”的原文并拒绝），也进裁判提示词（经围栏中和）。
    let userStatement: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        kind: AgentEnvironmentTrustKind,
        target: String,
        userStatement: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.userStatement = userStatement
        self.createdAt = createdAt
    }
}

nonisolated enum AgentEnvironmentTrust {
    /// testDatabase 匹配子串的最短长度——太短的子串（如 "db"）会把声明
    /// 泛化到不相干的命令上。
    static let minimumDatabaseTargetLength = 3

    /// 建立与撤销声明的工具本身永不自动通过，任何审批模式与 pin 都不例外。
    static let neverAutoApprovedToolNames: Set<String> = ["declare_environment_trust"]

    /// 声明可以放宽的工具。终端声明只覆盖可见终端（那才是被声明的环境），
    /// `run_command` 跑在本机沙箱里、不吃终端声明；数据库声明两者都覆盖，
    /// 但命令文本必须包含目标标识。
    static func toolIsInScope(_ toolName: String, for kind: AgentEnvironmentTrustKind) -> Bool {
        switch kind {
        case .disposableTerminal:
            return toolName == "terminal_send_command" || toolName == "terminal_send_control"
        case .testDatabase:
            return toolName == "run_command" || toolName == "terminal_send_command"
        case .deploymentWindow:
            return AgentDeploymentWindow.scopedToolNames.contains(toolName)
        }
    }

    /// 这条命令是否落在某条声明的覆盖范围内。
    static func covers(
        toolName: String,
        command: String,
        declarations: [AgentEnvironmentTrustDeclaration]
    ) -> AgentEnvironmentTrustDeclaration? {
        guard !declarations.isEmpty else { return nil }
        if let deployment = deploymentDeclarationCovering(
            toolName: toolName,
            command: command,
            in: declarations
        ) {
            return deployment
        }
        if let database = databaseDeclarationCovering(command: command, in: declarations),
           toolIsInScope(toolName, for: .testDatabase) {
            return database
        }
        if toolIsInScope(toolName, for: .disposableTerminal),
           let terminal = declarations.first(where: { $0.kind == .disposableTerminal }) {
            return terminal
        }
        return nil
    }

    /// 是否存在覆盖可见终端的 disposableTerminal 声明。
    static func coversTerminal(_ declarations: [AgentEnvironmentTrustDeclaration]) -> Bool {
        declarations.contains { $0.kind == .disposableTerminal }
    }

    /// 命令命中的 deploymentWindow 声明，无则 nil。与另外两类不同，这里
    /// 的匹配条件不是「命令里出现某个标识」，而是「命令属于部署命令族」——
    /// 一段部署作业里跑什么是可以枚举的，逐条问人才是那个不合理的默认。
    static func deploymentDeclarationCovering(
        toolName: String,
        command: String,
        in declarations: [AgentEnvironmentTrustDeclaration]
    ) -> AgentEnvironmentTrustDeclaration? {
        declarations.first { declaration in
            declaration.kind == .deploymentWindow
                && AgentDeploymentWindow.covers(
                    toolName: toolName,
                    command: command,
                    target: declaration.target
                )
        }
    }

    /// 命令命中的 testDatabase 声明（不区分大小写的子串匹配），无则 nil。
    static func databaseDeclarationCovering(
        command: String,
        in declarations: [AgentEnvironmentTrustDeclaration]
    ) -> AgentEnvironmentTrustDeclaration? {
        let lowered = command.lowercased()
        return declarations.first { declaration in
            declaration.kind == .testDatabase
                && declaration.target.count >= minimumDatabaseTargetLength
                && lowered.contains(declaration.target.lowercased())
        }
    }

    /// 判决缓存指纹：声明集不同 → 缓存键不同。revoke 后旧 YES 不会复用，
    /// 跨会话共享的判决缓存也不会把 A 会话声明下的 YES 泄给无声明的 B 会话。
    static func fingerprint(_ declarations: [AgentEnvironmentTrustDeclaration]) -> String {
        guard !declarations.isEmpty else { return "" }
        return declarations
            .map { "\($0.kind.rawValue):\($0.target.lowercased())" }
            .sorted()
            .joined(separator: "|")
    }
}
