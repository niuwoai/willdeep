import Foundation

extension AppState {
    var primaryAgentChangedFile: AgentFileChangeSummary? {
        if let openedFileURL,
           let repositoryRoot = agentWorktreeChanges.repositoryRoot {
            let rootPath = repositoryRoot.standardizedFileURL.path
            let filePath = openedFileURL.standardizedFileURL.path
            if filePath == rootPath || filePath.hasPrefix(rootPath + "/") {
                let relativePath = String(filePath.dropFirst(rootPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if let activeChange = agentWorktreeChanges.change(for: relativePath) {
                    return activeChange
                }
            }
        }

        return agentWorktreeChanges.files.first
    }

    var shouldShowAgentThinkingIndicator: Bool {
        guard isAgentResponding, !isCompressingAgentContext else { return false }
        if agentToolCalls.contains(where: { call in
            call.status == .pendingApproval
                || call.status == .awaitingConfirm
                || call.status == .awaitingUserAnswer
        }) {
            return false
        }

        guard let lastMessage = agentMessages.last else { return false }
        switch lastMessage.role {
        case .user, .tool:
            return true
        case .assistant:
            return lastMessage.content.isEmpty && lastMessage.toolCalls.isEmpty
        case .system:
            return false
        }
    }

    /// 「正在思考」分割线下方的两行实时预览：当前流式 assistant 占位
    /// 消息正在累积的 reasoningContent。生命周期与指示器完全一致——
    /// 首个正文 token / 工具调用到达后指示器消失，预览随之消失。
    /// 不单独输出 reasoning 流的服务商（未开 thinking 的 Claude 等）
    /// 返回 nil，分割线退回纯标签样式。
    var agentLiveThinkingPreview: String? {
        guard shouldShowAgentThinkingIndicator,
              let lastMessage = agentMessages.last,
              lastMessage.role == .assistant,
              let reasoning = lastMessage.reasoningContent,
              !reasoning.isEmpty else { return nil }
        return reasoning
    }

    /// 把完整 reasoning 轨迹压成适合两行展示的尾巴：换行折叠成空格、
    /// 只留末尾 `maxLength` 个字符。截断时前置省略号示意"前面还有"。
    /// 上限按两行 caption 字号的容量取值，配合视图层的
    /// `truncationMode(.head)` 兜底——窗口再窄也保证看到的是最新内容。
    nonisolated static func agentThinkingPreviewTail(_ raw: String, maxLength: Int = 160) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard collapsed.count > maxLength else { return collapsed }
        return "…" + collapsed.suffix(maxLength)
    }

    /// Claude Code 式「✳ N running task」计数：正在执行的前台工具调用
    /// + 本会话仍存活的后台作业。
    ///
    /// 前台工具只在 turn 进行中统计——被取消的 turn 理论上可能留下
    /// `.running` 残骸，不能让它把状态行永远钉在底部。后台作业则刻意
    /// **跨 turn 存活**：turn 已结束但编译还在跑时，transcript 底部
    /// 继续显示"N 个任务运行中"，这正是参照 Claude Code 界面的关键
    /// 行为（输出停了 ≠ 没事干了）。
    var agentRunningTaskCount: Int {
        let runningTools = isAgentResponding
            ? agentToolCalls.filter { $0.status == .running }.count
            : 0
        let aliveJobs = activeAgentSessionID
            .map { agentJobRegistry.aliveJobs(forRuntime: $0).count } ?? 0
        return runningTools + aliveJobs
    }

    /// Tooltip 明细：每行一个运行中条目 — 前台工具显示工具名，后台
    /// 作业显示 `job_xxxxxx · 命令前缀`。没有任何运行中条目时为 nil。
    var agentRunningTaskSummary: String? {
        var lines: [String] = []
        if isAgentResponding {
            lines += agentToolCalls
                .filter { $0.status == .running }
                .map(\.toolName)
        }
        if let runtimeID = activeAgentSessionID {
            lines += agentJobRegistry.aliveJobs(forRuntime: runtimeID).map { job in
                let command = job.command.replacingOccurrences(of: "\n", with: " ")
                let preview = command.count > 60 ? String(command.prefix(60)) + "…" : command
                return "\(job.displayHandle) · \(preview)"
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    var shouldShowGoalRunningStatusBar: Bool {
        agentInteractionMode == .goal
            && isAgentResponding
            && agentCurrentGoal?.isEmpty == false
    }

    var canShowPreview: Bool {
        let language = effectiveLanguage
        return language == .markdown || language == .html
    }

    var detectedLanguage: Language? {
        openedFileURL.map(Language.fromURL) ?? nil
    }

    var syntaxHighlightingSelection: SyntaxHighlightingSelection {
        activeTab?.syntaxHighlightingSelection ?? .automatic
    }

    var effectiveLanguage: Language? {
        switch syntaxHighlightingSelection {
        case .automatic:
            return detectedLanguage
        case .plainText:
            return nil
        case .language(let language):
            return language
        }
    }

    func showFindBar() {
        isFindBarVisible = true
    }

    func hideFindBar() {
        isFindBarVisible = false
    }

    func showQuickOpen() {
        guard rootDirectory != nil else { return }
        quickOpenQuery = ""
        isQuickOpenVisible = true
    }

    func hideQuickOpen() {
        isQuickOpenVisible = false
        quickOpenQuery = ""
    }

    func showGoToLine() {
        guard activeTabID != nil else { return }
        goToLineText = ""
        isGoToLineVisible = true
    }

    func hideGoToLine() {
        isGoToLineVisible = false
        goToLineText = ""
    }

    func showCommandPalette() {
        commandPaletteQuery = ""
        isCommandPaletteVisible = true
    }

    func hideCommandPalette() {
        isCommandPaletteVisible = false
        commandPaletteQuery = ""
    }

    func showSymbolJump() {
        guard activeTabID != nil else { return }
        symbolJumpQuery = ""
        isSymbolJumpVisible = true
    }

    func hideSymbolJump() {
        isSymbolJumpVisible = false
        symbolJumpQuery = ""
    }

    func toggleFocusMode() {
        isFocusModeEnabled.toggle()
    }

    func toggleAgentPanel() {
        isAgentPanelVisible.toggle()
    }

    func togglePreview() {
        guard canShowPreview else { return }
        isPreviewVisible.toggle()
    }

}
