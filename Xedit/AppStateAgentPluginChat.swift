//
//  AppStateAgentPluginChat.swift
//  WillDeep
//
//  `window.willdeep.chat.*`：插件把活交给主 Agent。
//
//  这是这批能力里杠杆最大的一条。Agent 能做的事很多（读写文件、跑命令、
//  调工具、委派子代理），插件不必为每一件都等宿主开一个新 API——把要求
//  写成一句话递过去就行。代价是它会**花钱、会动工作区**，所以：
//   · 独立权限 `conversation.write`，与只读的 `conversation.read` 分开；
//   · `insert` 只填输入框，回车与否是用户的事；`send` 才真的起回合；
//   · 递过去的文本有长度上限，且当成普通用户输入走同一条发送路径——
//     审批档位、沙箱、委派策略一个都不绕。
//

import Foundation

@MainActor
extension AppState {
    /// 单次递过来的文本上限。插件要塞的是一句话，不是一篇上下文；
    /// 真有大段材料应该写进文件再让 Agent 去读。
    static let pluginChatMaximumLength = 8_000

    /// 把文本填进当前会话的输入框，并切到聊天界面，但不发送。
    ///
    /// 必须跟着切过去：插件页是自己占满主区的一张页面，只把字填进输入框而
    /// 人还停在插件页上，用户看到的就是「点了没反应」。发送与否仍留给用户，
    /// 他多半还要再补一句上下文。
    @discardableResult
    func pluginPrefillAgentInput(_ text: String, pluginID: AgentPluginID) throws -> Bool {
        let trimmed = try validatedPluginChatText(text, pluginID: pluginID)
        guard let runtime = activeRuntime ?? activeRuntimeAfterCreatingNewSession() else {
            return false
        }
        runtime.input = trimmed
        agentPrimaryDestination = .conversation
        return true
    }

    /// 把文本当成一次普通的用户发言发出去，起一个回合。
    @discardableResult
    func pluginSendAgentMessage(_ text: String, pluginID: AgentPluginID) throws -> Bool {
        let trimmed = try validatedPluginChatText(text, pluginID: pluginID)
        guard let runtime = activeRuntime ?? activeRuntimeAfterCreatingNewSession() else {
            return false
        }
        runtime.input = trimmed
        agentPrimaryDestination = .conversation
        sendAgentMessage()
        return true
    }

    private func validatedPluginChatText(_ text: String, pluginID: AgentPluginID) throws -> String {
        guard AgentPluginRegistry.shared.hasPermission(.conversationWrite, pluginID: pluginID) else {
            throw AgentPluginCapabilityError.permissionDenied(AgentPluginPermission.conversationWrite.rawValue)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.pluginChatMaximumLength else {
            throw AgentPluginCapabilityError.invalidArgument("text")
        }
        return trimmed
    }

    /// 当前会话已授权的工作区根，给 `window.willdeep.fs.*` 用。
    /// 远端工作区返回空——那些路径不在本机上，本机解析出来的是另一台
    /// 机器的答案。
    var pluginAccessibleWorkspaceRoots: [URL] {
        guard let runtime = activeRuntime else { return [] }
        if case .remote = runtime.workspaceLocation { return [] }
        return agentWorkspaceRoots(for: runtime.session)
    }
}
