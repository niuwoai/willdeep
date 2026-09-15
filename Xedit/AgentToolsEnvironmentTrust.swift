//
//  AgentToolsEnvironmentTrust.swift
//  Xedit
//
//  declare_environment_trust 的实现。声明只在用户人工确认那张审批卡之后
//  才会写进 runtime——工具本身在 autoApprovalSource 入口被硬排除，任何
//  审批模式、Goal 免审、always-allow pin 都够不到它。
//  设计文档：docs/ENVIRONMENT_TRUST_DECLARATIONS.md
//

import Foundation

extension AgentToolRunner {
    static func declareEnvironmentTrust(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let runtimeID = context.runtimeID else {
            throw AgentToolError.invalidArgument(
                "declare_environment_trust requires a conversational runtime."
            )
        }
        let kindRaw = (arguments["kind"]?.stringValue() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let statement = (arguments["user_statement"]?.stringValue() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let target = (arguments["target"]?.stringValue() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if kindRaw == "revoke_all" {
            let removed = await MainActor.run { () -> Int in
                guard let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID),
                      let runtime = appState.agentRuntimes[runtimeID] else { return 0 }
                let count = runtime.environmentTrustDeclarations.count
                runtime.environmentTrustDeclarations.removeAll()
                return count
            }
            return AgentToolResult(
                summary: removed > 0 ? "已撤销 \(removed) 条环境信任声明" : "当前没有环境信任声明",
                payload: "Revoked \(removed) environment trust declaration(s). "
                    + "Approvals are back to the default policy for this conversation."
            )
        }

        guard let kind = AgentEnvironmentTrustKind(rawValue: kindRaw) else {
            throw AgentToolError.invalidArgument(
                "kind must be one of: disposable_terminal, test_database, deployment_window, revoke_all."
            )
        }
        guard !statement.isEmpty else {
            throw AgentToolError.missingArgument("user_statement")
        }
        if kind == .deploymentWindow,
           !target.isEmpty,
           target.count < AgentDeploymentWindow.minimumTargetLength {
            // target 对部署窗口是可选的收窄条件；一旦填了就不能是「k8」这种
            // 到处都能撞上的短串，否则等于没收窄。
            throw AgentToolError.invalidArgument(
                "deployment_window accepts an optional `target` (cluster, namespace, or host); "
                    + "when provided it must be at least "
                    + "\(AgentDeploymentWindow.minimumTargetLength) characters."
            )
        }
        if kind == .testDatabase,
           target.count < AgentEnvironmentTrust.minimumDatabaseTargetLength {
            // 太短的子串会把声明泛化到不相干的命令上，等于给整台机器开门。
            throw AgentToolError.invalidArgument(
                "test_database requires a `target` of at least "
                    + "\(AgentEnvironmentTrust.minimumDatabaseTargetLength) characters "
                    + "(the container name, host, or database name that identifies the instance)."
            )
        }

        let declaration = AgentEnvironmentTrustDeclaration(
            kind: kind,
            target: target,
            userStatement: statement
        )
        await MainActor.run {
            guard let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID),
                  let runtime = appState.agentRuntimes[runtimeID] else { return }
            // 同 kind + 同 target 的重复声明只保留最新一条，避免反复确认后
            // 堆出一串等价声明，也让撤销语义保持简单。
            runtime.environmentTrustDeclarations.removeAll {
                $0.kind == declaration.kind
                    && $0.target.lowercased() == declaration.target.lowercased()
            }
            runtime.environmentTrustDeclarations.append(declaration)
        }

        let scopeNote: String
        switch kind {
        case .disposableTerminal:
            scopeNote = "Routine writes, deletions, and service restarts in the visible terminal "
                + "now go to intelligent review instead of a confirmation card."
        case .testDatabase:
            scopeNote = "Destructive statements against commands containing `\(target)` "
                + "now go to intelligent review instead of a confirmation card."
        case .deploymentWindow:
            let scope = target.isEmpty
                ? "Deployment-family commands"
                : "Deployment-family commands mentioning `\(target)`"
            scopeNote = "\(scope) — kubectl / helm / docker / systemctl deployment subcommands — "
                + "now run without a confirmation card. Anything outside that family "
                + "(deleting namespaces or volumes, reading secrets, `rm -rf`, piped or "
                + "redirected commands) is unaffected and still asks."
        }
        return AgentToolResult(
            summary: "已登记环境信任：\(kind.displayLabel)",
            payload: """
            Environment trust recorded for this conversation only.
            kind: \(kind.rawValue)
            target: \(target.isEmpty ? "(unspecified)" : target)
            \(scopeNote)
            Reading or exporting credentials (.env, ~/.ssh, API keys) still requires \
            explicit confirmation and is never covered by this declaration.
            """
        )
    }
}
