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

    /// 随 App 一起签名发行的第一方内置插件（`BundledPlugins/`）执行自己的 MCP
    /// 工具时不再逐条弹确认框。它们和宿主是同一份签名产物，安装时也没有第三方
    /// 来源可核对，而收藏夹这种默认入口每翻一次页面就要点一次「执行」根本没法用。
    /// 其它来源（本地安装、Codex 缓存）仍然每次执行都要用户点头。
    nonisolated static func requiresExecutionConfirmation(source: AgentPluginPackageSource?) -> Bool {
        source != .bundled
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
