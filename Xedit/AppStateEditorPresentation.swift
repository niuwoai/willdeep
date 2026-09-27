import Foundation
import AppKit

nonisolated enum EditorDefinitionFallbackPolicy {
    static func shouldFallbackToRegex(didReceiveLanguageServerResponse: Bool) -> Bool {
        !didReceiveLanguageServerResponse
    }
}

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
        case .system, .workflowReport, .widget, .scheduledTask, .specProposal:
            return false
        }
    }

    /// Stable text activity indicator for the lifetime of an autonomous turn.
    /// Unlike `shouldShowAgentThinkingIndicator`, this intentionally remains
    /// visible after the first assistant token arrives so the transcript never
    /// swaps the elapsed-time label for a centered animation. Interactive tool
    /// cards already explain that the agent is waiting for the user, so those
    /// states suppress the activity label entirely.
    var shouldShowAgentActivityTextIndicator: Bool {
        guard isAgentResponding, !isCompressingAgentContext else { return false }
        return !isAgentWaitingForUserDecision
    }

    /// A confirm / approval / answer card is the authoritative activity
    /// surface while the turn is blocked on the user. Generic thinking and
    /// running-task markers stay hidden even if another tool or background job
    /// remains alive, so no star competes with the requested decision.
    var isAgentWaitingForUserDecision: Bool {
        agentToolCalls.contains { $0.status.isBlockingForUserDecision }
    }

    /// 「正在思考」状态行下方的实时正文：当前流式 assistant 占位消息
    /// 正在累积的 reasoningContent。生命周期与指示器完全一致——首个
    /// 正文 token / 工具调用到达后思考正文消失，由正式正文原位接替。
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

    /// Complete one-line action headline for the active provider turn.
    /// Visible reply text is still held to the strict phase-led format;
    /// the reasoning stream additionally gets a Codex 式宽松兜底——识别
    /// 不出阶段动词时,模型 reasoning 的最新一行原样作为 live 标题参与
    /// 扫光,"正在进行的这一步"在任何模型下都持续有内容。
    var agentCurrentActivityHeadline: AgentActivityHeadlinePresentation? {
        guard isAgentResponding else {
            agentLiveActivityHeadlineCache.reset()
            return nil
        }
        if let lastMessage = agentMessages.last,
           lastMessage.role == .assistant,
           let headline = AgentActivityHeadlinePresentation.make(from: lastMessage.content) {
            return headline
        }
        guard let reasoning = agentLiveThinkingPreview,
              let messageID = agentMessages.last?.id else {
            return nil
        }
        // Streams at ~10 flushes/second and is read by more than one view, so
        // it goes through the cache: one evaluation per distinct length, and a
        // settled cadence for a line that is merely getting longer.
        return agentLiveActivityHeadlineCache.headline(
            messageID: messageID,
            sourceLength: reasoning.count
        ) {
            AgentActivityHeadlinePresentation.makeLive(fromReasoning: reasoning)
        }
    }

    /// Show a detached action row only while the provider action has not yet
    /// appeared in the visible assistant message. Once it is inline, a second
    /// bottom row would duplicate both the action and its activity feedback.
    var shouldShowDetachedAgentCurrentActivityIndicator: Bool {
        guard shouldShowAgentActivityTextIndicator,
              agentCurrentActivityHeadline != nil else {
            return false
        }
        guard let lastMessage = agentMessages.last,
              lastMessage.role == .assistant else {
            return true
        }
        return AgentActivityHeadlinePresentation.make(from: lastMessage.content) == nil
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

    /// A single delegated CLI gets a real phase-aware headline instead of the
    /// generic "1 running task" label. Multiple concurrent tasks keep the
    /// compact count so the transcript footer does not turn into a log wall.
    var agentRunningTaskHeadline: String? {
        guard isAgentResponding else { return nil }
        let runningCalls = agentToolCalls.filter { $0.status == .running }
        let aliveJobCount = activeAgentSessionID
            .map { agentJobRegistry.aliveJobs(forRuntime: $0).count } ?? 0
        guard runningCalls.count == 1,
              aliveJobCount == 0,
              let call = runningCalls.first,
              let progress = call.delegatedProgress else {
            return nil
        }

        var detail = L10n.DelegatedTask.liveProgress(
            phase: progress.phase,
            attempt: progress.attempt,
            maximum: progress.maximumAttempts
        )
        if let activity = progress.currentActivity?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !activity.isEmpty {
            let clipped = activity.count > 80
                ? String(activity.prefix(80)) + "…"
                : activity
            detail += " · \(clipped)"
        }
        return L10n.DelegatedTask.liveHeadline(
            executor: AgentToolDisplay.name(for: call.toolName),
            progress: detail
        )
    }

    /// A Goal waiting to retry is still running: the card shows pause, and
    /// pause (Stop) is what takes the wait down.
    var isAgentGoalExecutionActive: Bool {
        activeRuntime?.isResponding == true
            || activeRuntime?.isAwaitingProviderSlot == true
            || activeRuntime?.currentGoal?.scheduledWake != nil
    }

    var shouldShowGoalRunningStatusBar: Bool {
        agentInteractionMode == .goal
            && isAgentGoalExecutionActive
            && agentCurrentGoal?.isEmpty == false
    }

    var shouldShowComposerGoalCard: Bool {
        agentInteractionMode == .goal
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

    func goToDefinition(request: EditorDefinitionRequest) {
        let fileURL = openedFileURL
        let language = effectiveLanguage
        let root = rootDirectory
        let text = fileContent

        if let fileURL,
           EditorLanguageServiceRegistry.isFirstStageIDELanguage(language) {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let locations = try await self.editorLanguageServiceManager.definition(
                        fileURL: fileURL,
                        language: language,
                        rootDirectory: root,
                        text: text,
                        characterOffset: request.characterOffset
                    )
                    if let location = locations.first,
                       await self.navigateToLanguageServerLocation(location) {
                        return
                    }
                    if EditorDefinitionFallbackPolicy.shouldFallbackToRegex(didReceiveLanguageServerResponse: true) {
                        await MainActor.run {
                            self.goToRegexDefinition(symbol: request.symbol)
                        }
                    } else {
                        await MainActor.run {
                            NSSound.beep()
                        }
                    }
                    return
                } catch {
                    // Missing or failing language servers fall back to the
                    // lightweight resolver so existing editor behavior survives.
                    NSLog("[EditorLSP] definition lookup failed: %@", error.localizedDescription)
                }
                if EditorDefinitionFallbackPolicy.shouldFallbackToRegex(didReceiveLanguageServerResponse: false) {
                    await MainActor.run {
                        self.goToRegexDefinition(symbol: request.symbol)
                    }
                }
            }
            return
        }

        goToRegexDefinition(symbol: request.symbol)
    }

    func goToDeclaration(request: EditorDeclarationRequest) {
        guard let fileURL = openedFileURL,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            NSSound.beep()
            return
        }

        let language = effectiveLanguage
        let root = rootDirectory
        let text = fileContent

        Task { [weak self] in
            guard let self else { return }
            do {
                let locations = try await self.editorLanguageServiceManager.declaration(
                    fileURL: fileURL,
                    language: language,
                    rootDirectory: root,
                    text: text,
                    characterOffset: request.characterOffset
                )
                if let location = locations.first,
                   await self.navigateToLanguageServerLocation(location) {
                    return
                }
            } catch {
                // Declaration lookup is semantic-only; do not fall back to a
                // regex match that may land on an implementation instead.
                NSLog("[EditorLSP] declaration lookup failed: %@", error.localizedDescription)
            }
            await MainActor.run {
                NSSound.beep()
            }
        }
    }

    func goToTypeDefinition(request: EditorTypeDefinitionRequest) {
        guard let fileURL = openedFileURL,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            NSSound.beep()
            return
        }

        let language = effectiveLanguage
        let root = rootDirectory
        let text = fileContent

        Task { [weak self] in
            guard let self else { return }
            do {
                let locations = try await self.editorLanguageServiceManager.typeDefinition(
                    fileURL: fileURL,
                    language: language,
                    rootDirectory: root,
                    text: text,
                    characterOffset: request.characterOffset
                )
                if let location = locations.first,
                   await self.navigateToLanguageServerLocation(location) {
                    return
                }
            } catch {
                // Type definition has no reliable regex fallback; avoid jumping
                // to an unrelated text match when the language server cannot help.
                NSLog("[EditorLSP] type definition lookup failed: %@", error.localizedDescription)
            }
            await MainActor.run {
                NSSound.beep()
            }
        }
    }

    func goToImplementation(request: EditorImplementationRequest) {
        guard let fileURL = openedFileURL,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            NSSound.beep()
            return
        }

        let language = effectiveLanguage
        let root = rootDirectory
        let text = fileContent

        Task { [weak self] in
            guard let self else { return }
            do {
                let locations = try await self.editorLanguageServiceManager.implementation(
                    fileURL: fileURL,
                    language: language,
                    rootDirectory: root,
                    text: text,
                    characterOffset: request.characterOffset
                )
                if let location = locations.first,
                   await self.navigateToLanguageServerLocation(location) {
                    return
                }
            } catch {
                // Implementation lookup is semantic-only; a regex fallback would
                // look confident while often landing on the wrong declaration.
                NSLog("[EditorLSP] implementation lookup failed: %@", error.localizedDescription)
            }
            await MainActor.run {
                NSSound.beep()
            }
        }
    }

    func goToRegexDefinition(symbol: String) {
        let currentFileURL = openedFileURL
        let rootDirectory = rootDirectory
        Task { [weak self] in
            let location = await Task.detached(priority: .userInitiated) {
                EditorDefinitionResolver.definition(
                    for: symbol,
                    from: currentFileURL,
                    rootDirectory: rootDirectory
                )
            }.value
            guard let self else { return }
            guard let location else {
                NSSound.beep()
                return
            }
            navigateToDefinitionLocation(location)
        }
    }

    func navigateToDefinitionLocation(_ location: EditorDefinitionLocation) {
        if openedFileURL?.standardizedFileURL == location.url.standardizedFileURL {
            navigateEditor(toLine: location.line)
            return
        }

        pendingDefinitionNavigation = location
        openEditorFile(location.url)
    }

    func toggleFocusMode() {
        isFocusModeEnabled.toggle()
    }

    func toggleAgentPanel() {
        isAgentPanelVisible.toggle()
    }

    @discardableResult
    func showEditor() -> Bool {
        if tabs.isEmpty {
            createNewTab()
        }
        isAgentPanelVisible = false
        isPreviewVisible = false
        isEditorTerminalVisible = false
        isFocusModeEnabled = false
        return EditorAppStateRegistry.shared.focusCurrentEditorWindow()
    }

    func togglePreview() {
        guard canShowPreview else { return }
        isPreviewVisible.toggle()
    }

}
