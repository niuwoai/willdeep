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
import WillDeepCore

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

    /// 按「找一段、换一段」改文件，而不是整文件覆盖。
    ///
    /// 与 Agent 的 `edit_file` 共用 `AgentEditFileSupport.makeEdit`，所以
    /// 「找不到」「不唯一」「改了个寂寞」这三种失败的判定和报错跟 Agent
    /// 完全一致——插件作者读到的错误消息，和他在聊天里看到的是同一套。
    ///
    /// 为什么不是整文件覆盖就够了：页面拿到的是被 `fs.read` 截断过的文本
    /// （256 KiB 封顶），拿它回写等于把超出部分悄悄删掉。改一段就没有这个
    /// 问题，也不会踩掉别人同时对同一文件做的其它修改。
    func pluginPatchWorkspaceFile(
        path: String,
        oldString: String,
        newString: String,
        replaceAll: Bool,
        pluginID: AgentPluginID
    ) throws -> [String: Any] {
        guard AgentPluginRegistry.shared.hasPermission(.workspaceWrite, pluginID: pluginID) else {
            throw AgentPluginCapabilityError.permissionDenied(AgentPluginPermission.workspaceWrite.rawValue)
        }
        let roots = pluginAccessibleWorkspaceRoots
        guard let runtime = activeRuntime, let root = roots.first else {
            throw AgentPluginCapabilityError.noWorkspace
        }
        let url = try AgentPluginFileAccess.resolve(path: path, roots: [root])
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentPluginCapabilityError.notFound(url.path)
        }
        // 编辑器里开着这个文件时以缓冲区为准，否则会把用户没存盘的改动
        // 当成不存在。
        let current: String
        if let buffered = try? editableContent(forAgentPatchURL: url) {
            current = buffered
        } else {
            current = AppState.decodeText(from: try Data(contentsOf: url))
        }
        let relative = url.path == root.path
            ? url.lastPathComponent
            : String(url.path.dropFirst(root.path.count + 1))
        let edit = try AgentEditFileSupport.makeEdit(
            path: relative,
            oldContent: current,
            oldString: oldString,
            newString: newString,
            replaceAll: replaceAll
        )
        guard Data(edit.newContent.utf8).count <= Self.pluginFileWriteMaximumBytes else {
            throw AgentPluginCapabilityError.payloadTooLarge(Self.pluginFileWriteMaximumBytes)
        }
        try writeDelegatedAgentContent(edit.newContent, to: url, runtime: runtime, workspaceRoot: root)
        return ["path": url.path, "occurrences": edit.occurrences]
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

        // 只读命令直接跑；其余要么此前被记住过，要么弹确认框。
        // 一律**不看审批档位**：完全访问是用户对「自己指挥的 Agent」的
        // 授权，不是对第三方页面的授权，两者不该共用一个开关。
        //
        // `approval` 一路带到审计行里：「以后不再询问」之后的每一次执行都
        // 要能被数出来，否则记住一次等于此后无痕。
        var approval = "alwaysSafe"
        if SafeCommand.classify(command: trimmed) != .alwaysSafe {
            if AgentPluginCommandApprovalStore.isRemembered(
                command: trimmed,
                pluginID: pluginID,
                packageDigest: AgentPluginRegistry.shared.packageDigest(for: pluginID)
            ) {
                approval = "remembered"
            } else {
            approval = "confirmed"
            let outcome = confirmPluginCommand(trimmed, pluginID: pluginID, workspaceRoot: root)
            guard outcome.approved else {
                AgentPluginAuditLog.recordCommandRun(AgentPluginAuditLog.CommandRun(
                    recordedAt: Date(),
                    pluginID: pluginID,
                    command: AgentSandboxPolicy.scrub(String(trimmed.prefix(AgentPluginAuditLog.maximumCommandCharacters))),
                    sandboxMode: "",
                    approval: "declined",
                    seconds: 0,
                    outcome: "declined",
                    errorDescription: nil
                ))
                throw AgentPluginCapabilityError.commandDeclined
            }
            if outcome.remember {
                AgentPluginCommandApprovalStore.remember(
                    command: trimmed,
                    pluginID: pluginID,
                    packageDigest: AgentPluginRegistry.shared.packageDigest(for: pluginID)
                )
            }
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
                sandboxDecision: sandboxDecision,
                localSandboxDisabled: runtime.localSandboxDisabled
            )
        )
        // 主 Agent 跑同一条命令会写进 sandbox.jsonl；插件页面这条路以前
        // 一行都不写。补上，落在这个插件自己的目录里。
        let startedAt = Date()
        let scrubbed = AgentSandboxPolicy.scrub(
            String(trimmed.prefix(AgentPluginAuditLog.maximumCommandCharacters))
        )
        func recordRun(outcome: String, error: Error?) {
            AgentPluginAuditLog.recordCommandRun(AgentPluginAuditLog.CommandRun(
                recordedAt: Date(),
                pluginID: pluginID,
                command: scrubbed,
                sandboxMode: context.sandboxMode.rawValue,
                approval: approval,
                seconds: Date().timeIntervalSince(startedAt),
                outcome: outcome,
                errorDescription: error.map { String($0.localizedDescription.prefix(240)) }
            ))
        }
        do {
            let result = try await AgentToolRunner.runCommand(
                arguments: arguments,
                context: context,
                foregroundMaxTimeout: Self.pluginCommandTimeout
            )
            recordRun(outcome: "succeeded", error: nil)
            return ["summary": result.summary, "output": result.payload]
        } catch {
            recordRun(outcome: error is CancellationError ? "cancelled" : "failed", error: error)
            throw error
        }
    }

    /// 非只读命令的确认框。把插件名、完整命令和工作目录摊开给用户看——
    /// 他要判断的是「这个页面替我跑这条命令，行不行」。
    ///
    /// 勾上「以后不再询问」记住的是**这一条命令的完整原文**，不是前缀、
    /// 更不是「这个插件以后随便跑」：`git status` 被记住，不该让
    /// `git push --force` 跟着免检。
    private func confirmPluginCommand(
        _ command: String,
        pluginID: AgentPluginID,
        workspaceRoot: URL
    ) -> (approved: Bool, remember: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.PluginCommandConfirm.title(
            AgentPluginRegistry.shared.displayName(for: pluginID) ?? pluginID
        )
        alert.informativeText = "\(command)\n\n\(workspaceRoot.path)"
        alert.addButton(withTitle: L10n.PluginCommandConfirm.run)
        alert.addButton(withTitle: L10n.PluginCommandConfirm.cancel)
        let remember = NSButton(checkboxWithTitle: L10n.PluginCommandConfirm.remember, target: nil, action: nil)
        remember.state = .off
        alert.accessoryView = remember
        let approved = alert.runModal() == .alertFirstButtonReturn
        return (approved, approved && remember.state == .on)
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

    // MARK: 最近项目与选文件夹

    /// 插件页面要让用户「挑一个项目」时的两条路：主 App 最近打开过的文件夹，
    /// 或者弹系统的选文件夹面板。都只回路径，**不扩大读权限**——`fs.*`
    /// 依旧只认当前会话已授权的根。需要 `workspace.read`。
    func pluginRecentWorkspaces(pluginID: AgentPluginID) throws -> [[String: Any]] {
        try requirePluginWorkspaceRead(pluginID: pluginID)
        let sessionRoots = agentSessions.compactMap { session -> AgentPluginRecentWorkspaces.SessionRoot? in
            guard let path = session.workspaceRootPath, !path.isEmpty else { return nil }
            return AgentPluginRecentWorkspaces.SessionRoot(path: path, lastActivityAt: session.lastActivityAt)
        }
        return AgentPluginRecentWorkspaces.entries(recentFolders: recentFolders, sessionRoots: sessionRoots)
    }

    /// 弹系统选文件夹面板。用户取消时回 `nil`，不算错误。
    /// 一个页面同一时刻只开一个面板，连点按钮不会叠出一摞。
    func pluginPickFolder(title: String, pluginID: AgentPluginID) async throws -> String? {
        try requirePluginWorkspaceRead(pluginID: pluginID)
        guard !Self.pluginFolderPanelIsOpen else {
            throw AgentPluginCapabilityError.invalidArgument("a folder panel is already open")
        }
        Self.pluginFolderPanelIsOpen = true
        defer { Self.pluginFolderPanelIsOpen = false }

        let panel = NSOpenPanel()
        let trimmedTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        panel.title = trimmedTitle.isEmpty ? L10n.ComposerWorkspace.chooseFolder : trimmedTitle
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let first = recentFolders.first { panel.directoryURL = first.deletingLastPathComponent() }

        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            // 同 composer 选附件：挂成当前窗口的 sheet。不带父窗口的
            // `panel.begin` 在 macOS 26 + MainActor 下出现过卡死。
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        guard response == .OK, let url = panel.url else { return nil }
        return url.standardizedFileURL.path
    }

    private static var pluginFolderPanelIsOpen = false

    private func requirePluginWorkspaceRead(pluginID: AgentPluginID) throws {
        guard AgentPluginRegistry.shared.hasPermission(.workspaceRead, pluginID: pluginID)
                || AgentPluginRegistry.shared.hasPermission(.workspaceWrite, pluginID: pluginID) else {
            throw AgentPluginCapabilityError.permissionDenied(AgentPluginPermission.workspaceRead.rawValue)
        }
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
        guard !AgentToolApprovalNotifier.isSuppressedForTests else { return }
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
