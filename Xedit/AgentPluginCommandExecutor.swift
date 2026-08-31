//
//  AgentPluginCommandExecutor.swift
//  WillDeep
//

import AppKit
import Foundation

@MainActor
enum AgentPluginCommandExecutor {
    static func execute(
        pluginID: AgentPluginID,
        commandID: AgentPluginCommandID,
        arguments: [String: String],
        destinationID: AgentPluginDestinationID,
        appState: AppState
    ) async throws -> String? {
        let jsonArguments = arguments.reduce(into: [String: Any]()) { result, entry in
            result[entry.key] = entry.value
        }
        return try await executeJSON(
            pluginID: pluginID,
            commandID: commandID,
            arguments: jsonArguments,
            destinationID: destinationID,
            appState: appState
        )
    }

    static func executeJSON(
        pluginID: AgentPluginID,
        commandID: AgentPluginCommandID,
        arguments: [String: Any],
        destinationID: AgentPluginDestinationID,
        appState: AppState
    ) async throws -> String? {
        guard let command = AgentPluginRegistry.shared.command(
            pluginID: pluginID,
            commandID: commandID
        ) else {
            throw AgentPluginPackageError.missingContribution(commandID)
        }
        switch command.handler.type {
        case .host:
            let stringArguments = arguments.compactMapValues { value -> String? in
                if let string = value as? String { return string }
                if let number = value as? NSNumber { return number.stringValue }
                return nil
            }
            return try executeHost(
                action: command.handler.action ?? "",
                arguments: stringArguments,
                destinationID: destinationID,
                appState: appState
            )
        case .navigate:
            guard let localID = command.handler.destination else {
                throw AgentPluginPackageError.invalidContribution(commandID)
            }
            let qualifiedID = localID.contains(":") ? localID : "\(pluginID):\(localID)"
            guard AgentPluginRegistry.shared.destination(id: qualifiedID) != nil else {
                throw AgentPluginPackageError.missingContribution(qualifiedID)
            }
            appState.agentPrimaryDestination = .plugin(qualifiedID)
            appState.agentSidePanelKind = nil
            appState.agentSidePanelRequest = nil
            return nil
        case .mcpTool:
            guard let server = command.handler.server,
                  let tool = command.handler.tool else {
                throw AgentPluginPackageError.invalidContribution(commandID)
            }
            if Self.requiresExecutionConfirmation(
                source: AgentPluginRegistry.shared.record(pluginID: pluginID)?.activePackage.source
            ) {
                let commandTitle = AgentPluginRegistry.shared.localizedString(
                    command.titleKey,
                    pluginID: pluginID
                )
                guard confirmMCPCommand(pluginID: pluginID, commandTitle: commandTitle) else { return nil }
            }
            return try await AgentMCPBridge.callPluginTool(
                pluginID: pluginID,
                serverName: server,
                toolName: tool,
                arguments: arguments
            )
        }
    }

    private static func executeHost(
        action: String,
        arguments: [String: String],
        destinationID: AgentPluginDestinationID,
        appState: AppState
    ) throws -> String? {
        switch action {
        case "plugin.refresh":
            AgentPluginDestinationSessionState.shared.requestRefresh(destinationID: destinationID)
            return nil
        case "destination.select":
            AgentPluginDestinationSessionState.shared.select(
                itemID: arguments["itemID"] ?? arguments["id"],
                destinationID: destinationID
            )
            return nil
        case "settings.mcp":
            EditorSettingsNavigation.shared.open(.mcp, appState: appState)
            return nil
        case "plugins.open-center":
            appState.agentPrimaryDestination = .pluginCenter
            appState.agentSidePanelKind = nil
            appState.agentSidePanelRequest = nil
            return nil
        default:
            throw AgentPluginPackageError.invalidContribution("unsupported host action \(action)")
        }
    }

    /// 授权在安装那一刻拿到，执行时不再重复问（2026-09-01 用户确认）：
    /// - `.bundled`：随 App 签名发行的第一方插件，和宿主同一份产物，免确认。
    /// - `.installed`：安装面板已列出插件要求的全部权限（MCP 服务可能访问
    ///   文件、进程或网络），用户点「安装」即完成授权——之后每次执行再弹
    ///   一遍「允许插件命令？」是重复把关，Todo 这类高频入口每点一下都要
    ///   确认根本没法用。
    /// - `.draft`（插件草稿，内容随时在改、从没走过安装授权）和
    ///   `.codexCache`（从 `~/.codex` 外部缓存目录自动发现，同样没向
    ///   WillDeep 授过权）仍然每次执行都要用户点头。
    nonisolated static func requiresExecutionConfirmation(source: AgentPluginPackageSource?) -> Bool {
        switch source {
        case .bundled, .installed:
            return false
        case .codexCache, .draft, nil:
            return true
        }
    }

    private static func confirmMCPCommand(pluginID: String, commandTitle: String) -> Bool {
        let pluginName = AgentPluginRegistry.shared.record(pluginID: pluginID)?.activePackage.displayName ?? pluginID
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.Plugins.executeCommandTitle
        alert.informativeText = L10n.Plugins.commandConfirmation(pluginName, commandTitle)
        alert.addButton(withTitle: L10n.Plugins.executeCommand)
        alert.addButton(withTitle: L10n.Plugins.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
