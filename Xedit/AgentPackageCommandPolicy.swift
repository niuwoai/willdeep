//
//  AgentPackageCommandPolicy.swift
//  WillDeep
//
//  Package-manager command classification shared by SafeCommand and the
//  sandbox policy. Keep this as the single source of truth so install/build
//  workflows do not drift between "safe to auto-run" and "needs network".
//

import Foundation

enum AgentPackageCommandPolicy {
    nonisolated private static let packageManagers: Set<String> = ["npm", "pnpm", "yarn"]
    nonisolated private static let globalInstallFlags: Set<String> = ["-g", "--global", "--location=global"]
    nonisolated private static let safeScripts: Set<String> = [
        "dev", "build", "test", "start", "preview", "lint",
        "format", "typecheck", "check"
    ]
    nonisolated private static let npmInstallCommands: Set<String> = ["install", "i", "ci", "add"]
    nonisolated private static let pnpmInstallCommands: Set<String> = ["install", "i", "add"]
    nonisolated private static let yarnInstallCommands: Set<String> = ["install", "add"]

    nonisolated static func isPackageManager(_ head: String) -> Bool {
        packageManagers.contains(head.lowercased())
    }

    nonisolated static func classify(firstToken: String, tokens: [String]) -> CommandSafety {
        let manager = firstToken.lowercased()
        guard isPackageManager(manager) else { return .needsJudgment }
        guard tokens.count >= 2 else { return .alwaysSafe }
        guard !hasDisallowedWorkspaceScope(tokens) else { return .needsJudgment }

        let lowered = tokens.map { $0.lowercased() }
        guard let command = packageCommand(in: lowered, manager: manager) else {
            return .needsJudgment
        }

        if isDependencyInstallCommand(manager: manager, command: command) {
            return .alwaysSafe
        }

        if manager == "yarn" {
            if command == "run", let script = packageCommand(after: command, in: lowered) {
                return safeScripts.contains(script) ? .alwaysSafe : .needsJudgment
            }
            return safeScripts.contains(command) ? .alwaysSafe : .needsJudgment
        }

        guard command == "run", let script = packageCommand(after: command, in: lowered) else {
            return .needsJudgment
        }
        return safeScripts.contains(script) ? .alwaysSafe : .needsJudgment
    }

    nonisolated static func isDependencyInstallCommand(tokens: [String]) -> Bool {
        guard let head = tokens.first?.lowercased(), isPackageManager(head) else {
            return false
        }
        guard !hasDisallowedWorkspaceScope(tokens) else { return false }
        let lowered = tokens.map { $0.lowercased() }
        guard let command = packageCommand(in: lowered, manager: head) else {
            return false
        }
        return isDependencyInstallCommand(manager: head, command: command)
    }

    nonisolated private static func isDependencyInstallCommand(manager: String, command: String) -> Bool {
        switch manager {
        case "npm":
            return npmInstallCommands.contains(command)
        case "pnpm":
            return pnpmInstallCommands.contains(command)
        case "yarn":
            return yarnInstallCommands.contains(command)
        default:
            return false
        }
    }

    /// Install scope that reaches outside the workspace (`-g`, `--global`,
    /// `--prefix`). Such commands write where the sandbox denies writes
    /// anyway, so they earn neither auto-approval nor the workspace network
    /// grant that ordinary in-workspace builds get.
    nonisolated static func hasGlobalInstallScope(_ tokens: [String]) -> Bool {
        hasDisallowedWorkspaceScope(tokens)
    }

    nonisolated private static func hasDisallowedWorkspaceScope(_ tokens: [String]) -> Bool {
        let lowered = tokens.map { $0.lowercased() }
        return lowered.contains(where: { globalInstallFlags.contains($0) })
            || lowered.contains("--prefix")
            || lowered.contains(where: { $0.hasPrefix("--prefix=") })
    }

    nonisolated private static func packageCommand(in loweredTokens: [String], manager: String) -> String? {
        guard loweredTokens.first == manager else { return nil }
        var index = 1
        while index < loweredTokens.count {
            let token = loweredTokens[index]
            if token == "--" {
                index += 1
                continue
            }
            if token.hasPrefix("-") {
                index += optionConsumesValue(token) ? 2 : 1
                continue
            }
            return token
        }
        return nil
    }

    nonisolated private static func packageCommand(after command: String, in loweredTokens: [String]) -> String? {
        guard let commandIndex = loweredTokens.firstIndex(of: command) else { return nil }
        var index = commandIndex + 1
        while index < loweredTokens.count {
            let token = loweredTokens[index]
            if token == "--" {
                index += 1
                continue
            }
            if token.hasPrefix("-") {
                index += optionConsumesValue(token) ? 2 : 1
                continue
            }
            return token
        }
        return nil
    }

    nonisolated private static func optionConsumesValue(_ token: String) -> Bool {
        let flag = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
        return [
            "--cache", "--registry", "--userconfig", "--tag", "--filter",
            "--workspace", "--cwd", "-C"
        ].contains(flag)
    }
}
