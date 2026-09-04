//
//  AppStateAgentPluginWorkspace.swift
//  WillDeep
//
//  插件页面第二批能力里要动 AppState 的那几条：写文件、跑命令、代发
//  网络请求、写剪贴板、发通知。
//
//  这几条的共同点是**会留下痕迹**，所以每一条都接回宿主已有的那套机制，
//  而不是自己另起一套：
//   · 写文件走 `writeDelegatedAgentContent`，与 Agent 改文件同一条路——
//     路径守卫、编辑器同步、改动登记（Changes 面板看得到）全都继承；
//   · 跑命令过 `AgentMaliciousCommandDenylist` 与 `SafeCommand`，非只读
//     的一律弹确认框，且执行时带上与 Agent 同款的沙箱；
//   · 网络请求的门在 manifest 的 `networkDomains`，权限只是开关。
//

import AppKit
import Foundation
import UserNotifications

@MainActor
extension AppState {
    // MARK: 写工作区文件

    /// 单次写入上限。插件要落的是配置、草稿、导出的一小段文本，
    /// 真有大文件应该让 Agent 去写。
    static let pluginFileWriteMaximumBytes = 512 * 1024

    func pluginWriteWorkspaceFile(
        path: String,
        text: String,
        pluginID: AgentPluginID
    ) throws -> [String: Any] {
        guard AgentPluginRegistry.shared.hasPermission(.workspaceWrite, pluginID: pluginID) else {
            throw AgentPluginCapabilityError.permissionDenied(AgentPluginPermission.workspaceWrite.rawValue)
        }
        guard Data(text.utf8).count <= Self.pluginFileWriteMaximumBytes else {
            throw AgentPluginCapabilityError.payloadTooLarge(Self.pluginFileWriteMaximumBytes)
        }
        let roots = pluginAccessibleWorkspaceRoots
        guard let runtime = activeRuntime, let root = roots.first else {
            throw AgentPluginCapabilityError.noWorkspace
        }
        // 先用只读那套守卫把路径落定（相对/绝对都收、越界就抛），再交给
        // Agent 的写入路径——后者只认主根，正好是我们想给插件的范围。
        let destination = try AgentPluginFileAccess.resolve(path: path, roots: [root])
        try writeDelegatedAgentContent(text, to: destination, runtime: runtime, workspaceRoot: root)
        return ["path": destination.path, "byteSize": Data(text.utf8).count]
    }

    // MARK: 跑命令

    /// 命令执行的墙钟上限。前台执行，不登记后台任务——插件页要的是
    /// 一个立刻能用的结果，长活该交给 Agent。
    static let pluginCommandTimeout: TimeInterval = 120

    func pluginRunCommand(_ command: String, pluginID: AgentPluginID) async throws -> [String: Any] {
        guard AgentPluginRegistry.shared.hasPermission(.processExecute, pluginID: pluginID) else {
            throw AgentPluginCapabilityError.permissionDenied(AgentPluginPermission.processExecute.rawValue)
        }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2_000 else {
            throw AgentPluginCapabilityError.invalidArgument("command")
        }
        // 恶意名单是硬地板：这类命令连「问一下用户」的机会都不给。用户
        // 在一个插件页面上看到的确认框，没有足够上下文让他判断
        // `curl … | sh` 到底在装什么。
        if let match = AgentMaliciousCommandDenylist.match(command: trimmed) {
            throw AgentPluginCapabilityError.commandRefused(match.reason)
        }
        guard let runtime = activeRuntime else {
            throw AgentPluginCapabilityError.noWorkspace
        }
        let roots = pluginAccessibleWorkspaceRoots
        guard let root = roots.first else {
            throw AgentPluginCapabilityError.noWorkspace
        }

        // 只读命令直接跑；其余一律弹确认框，**不看审批档位**。
        // 完全访问是用户对「自己指挥的 Agent」的授权，不是对第三方页面的
        // 授权，两者不该共用一个开关。
        if SafeCommand.classify(command: trimmed) != .alwaysSafe {
            guard confirmPluginCommand(trimmed, pluginID: pluginID, workspaceRoot: root) else {
                throw AgentPluginCapabilityError.commandDeclined
            }
        }

        var arguments: [String: AgentJSONValue] = [
            "command": .string(trimmed),
            "run_in_background": .bool(false),
            "timeout_seconds": .number(Self.pluginCommandTimeout),
        ]
        arguments["_plugin"] = .string(pluginID)
        let sandboxDecision = AgentSandboxPolicy.decision(
            toolName: "run_command",
            arguments: arguments,
            rootDirectory: root,
            additionalWorkspaceRoots: Array(roots.dropFirst())
        )
        let risk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: arguments,
            rootDirectory: root,
            additionalWorkspaceRoots: Array(roots.dropFirst())
        )
        let context = AgentToolContext(
            rootDirectory: root,
            additionalWorkspaceRoots: Array(roots.dropFirst()),
            runtimeID: runtime.id,
            localCommandEnvironment: AgentToolRunner.localCommandEnvironment(
                settings: editorTerminalSettings
            ),
            sandboxMode: sandboxModeForToolExecution(
                risk: risk,
                approvalSource: nil,
                sandboxDecision: sandboxDecision
            )
        )
        let result = try await AgentToolRunner.runCommand(
            arguments: arguments,
            context: context,
            foregroundMaxTimeout: Self.pluginCommandTimeout
        )
        return ["summary": result.summary, "output": result.payload]
    }

    /// 非只读命令的确认框。把插件名、完整命令和工作目录摊开给用户看——
    /// 他要判断的是「这个页面替我跑这条命令，行不行」。
    private func confirmPluginCommand(
        _ command: String,
        pluginID: AgentPluginID,
        workspaceRoot: URL
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.PluginCommandConfirm.title(
            AgentPluginRegistry.shared.displayName(for: pluginID) ?? pluginID
        )
        alert.informativeText = "\(command)\n\n\(workspaceRoot.path)"
        alert.addButton(withTitle: L10n.PluginCommandConfirm.run)
        alert.addButton(withTitle: L10n.PluginCommandConfirm.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: 代发网络请求

    func pluginFetch(
        url: String,
        method: String,
        headers: [String: String],
        body: String?,
        pluginID: AgentPluginID
    ) async throws -> [String: Any] {
        guard AgentPluginRegistry.shared.hasPermission(.networkAccess, pluginID: pluginID) else {
            throw AgentPluginCapabilityError.permissionDenied(AgentPluginPermission.networkAccess.rawValue)
        }
        let domains = AgentPluginRegistry.shared.networkDomains(for: pluginID)
        let request = try AgentPluginNetworkProxy.makeRequest(
            urlString: url,
            method: method,
            headers: headers,
            body: body,
            domains: domains
        )
        return try await AgentPluginNetworkProxy.send(request, domains: domains)
    }

    // MARK: 剪贴板与通知

    func pluginWriteClipboard(_ text: String, pluginID: AgentPluginID) throws {
        guard AgentPluginRegistry.shared.hasPermission(.clipboardWrite, pluginID: pluginID) else {
            throw AgentPluginCapabilityError.permissionDenied(AgentPluginPermission.clipboardWrite.rawValue)
        }
        guard !text.isEmpty, text.count <= 100_000 else {
            throw AgentPluginCapabilityError.invalidArgument("text")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func pluginPostNotification(title: String, body: String, pluginID: AgentPluginID) throws {
        guard AgentPluginRegistry.shared.hasPermission(.notifications, pluginID: pluginID) else {
            throw AgentPluginCapabilityError.permissionDenied(AgentPluginPermission.notifications.rawValue)
        }
        let title = String(title.prefix(200))
        let body = String(body.prefix(1_000))
        guard !title.isEmpty else { throw AgentPluginCapabilityError.invalidArgument("title") }
        let content = UNMutableNotificationContent()
        // 通知中心里不写清是哪个插件发的，用户就没法把噪音关掉。
        content.title = "\(AgentPluginRegistry.shared.displayName(for: pluginID) ?? pluginID) · \(title)"
        content.body = body
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            center.add(
                UNNotificationRequest(
                    identifier: "willdeep.plugin.\(pluginID).\(Int(Date().timeIntervalSince1970))",
                    content: content,
                    trigger: nil
                ),
                withCompletionHandler: nil
            )
        }
    }
}
