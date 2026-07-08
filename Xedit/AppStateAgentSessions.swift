//
//  AppStateAgentSessions.swift
//  WillDeep
//
//  Extracted from AppState.swift in v1.52.1-rc42 (stage-3 code-health
//  pass). Houses the Agent-mode session lifecycle, routines, plan and
//  goal management, and provider-library switch:
//
//    - Provider library: apply/select/upsert/remove + sync helpers
//    - Plan mode: approve/reject/complete/restart/edit/insert/remove +
//      capture from latest message + step status
//    - Goal mode: setAgentGoal / toggleAgentGoalItem +
//      captureAgentGoalEvaluationFromLatestMessage
//    - reviewAgentWorktreeChanges / showAgentWorktreeDiff
//    - stopAgentResponse / clearAgentQueue / addAgentImage /
//      removeAgentImage staging helpers
//    - setAppMode / toggleAppMode + sessions: startNewAgentSession,
//      selectAgentSession, pruneEmptyAgentSessions, deleteAgentSession
//    - Routines: saveAgentRoutine / deleteAgentRoutine /
//      toggleAgentRoutineEnabled / runAgentRoutineNow / fireRoutine
//    - toggleAgentSessionPinned / toggleAgentSessionArchived /
//      persistActiveAgentSession / persistAgentSession
//    - recordFetchedAgentModels / setAgentSessionModel /
//      selectAgentEntryAndModel
//
//  Lives on AppState via extension; call sites in the chat / Settings
//  / routine UIs keep using appState.startNewAgentSession(),
//  appState.setAgentInteractionMode(_:) etc. unchanged.
//

import AppKit
import Foundation

extension AppState {

    // MARK: - Provider library

    /// Reflect the active library entry's tier picks back into
    /// `agentConfiguration` so the existing agent loop (which still
    /// reads from the single configuration) sees the right provider
    /// + key + model the moment the user picks one in Settings.
    ///
    /// A 方案：这是 library → cfg 的**唯一**写入方向。cfg.didSet
    /// 不再回灌 library，所以这里无需 reentrancy 守卫。
    func applyActiveProviderLibraryEntry() {
        guard let entry = agentProviderLibrary.active else { return }
        if !entry.apiKeyLoaded {
            var loadedLibrary = agentProviderLibrary
            if AgentSettingsStore.materializeProviderLibraryAPIKey(in: &loadedLibrary, id: entry.id) {
                agentProviderLibrary = loadedLibrary
                return
            }
        }
        var cfg = agentConfiguration
        cfg.providerID = entry.providerID
        cfg.baseURL = entry.baseURL
        cfg.apiKey = entry.apiKey
        cfg.flashModel = entry.flashPrimary
        cfg.proModel = entry.proPrimary
        cfg.routingMode = entry.routingMode
        if cfg.model.isEmpty { cfg.model = entry.flashPrimary }
        agentConfiguration = cfg.normalized
        clearIncompatibleAgentSessionModelOverride()
    }

    /// Activate a different library entry by id and immediately apply
    /// it to the live configuration. No-op if the id is unknown.
    func setActiveProviderLibraryEntry(id: UUID) {
        guard agentProviderLibrary.entries.contains(where: { $0.id == id }) else { return }
        var library = agentProviderLibrary
        library.setActive(id)
        AgentSettingsStore.materializeProviderLibraryAPIKey(in: &library, id: id)
        agentProviderLibrary = library
        applyActiveProviderLibraryEntry()
    }

    func materializeProviderLibraryEntryAPIKey(id: UUID) {
        guard agentProviderLibrary.entries.contains(where: { $0.id == id }) else { return }
        var library = agentProviderLibrary
        guard AgentSettingsStore.materializeProviderLibraryAPIKey(in: &library, id: id) else { return }
        agentProviderLibrary = library
    }

    /// Add or update a library entry. If the entry is the active one,
    /// the live configuration is refreshed too.
    func upsertProviderLibraryEntry(_ entry: AgentProviderEntry) {
        agentProviderLibrary.upsert(entry)
        if agentProviderLibrary.activeID == entry.id {
            applyActiveProviderLibraryEntry()
        }
    }

    func syncSomeIMProvider(settings: SomeIMIntegrationSettings, apiKey: String, activate: Bool = true) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        let normalizedSettings = settings.normalized
        let presetID = "some-im"
        let existing = agentProviderLibrary.entries.first { entry in
            entry.providerID == presetID
                || entry.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedSettings.baseURL
        }

        let entryID = existing?.id ?? UUID()
        let entry = AgentProviderEntry(
            id: entryID,
            providerID: presetID,
            displayName: existing?.displayName ?? AgentProviderPreset.preset(id: presetID)?.displayName,
            baseURL: normalizedSettings.baseURL,
            apiKey: trimmedKey,
            flashPrimary: SomeIMIntegrationSettings.defaultTextModel,
            flashAlternates: existing?.flashAlternates ?? [],
            proPrimary: existing?.proPrimary ?? SomeIMIntegrationSettings.defaultTextModel,
            proAlternates: existing?.proAlternates ?? [],
            routingMode: existing?.routingMode ?? .flash
        )

        agentProviderLibrary.upsert(entry)
        if activate {
            agentProviderLibrary.setActive(entryID)
        }
        if agentProviderLibrary.activeID == entryID {
            applyActiveProviderLibraryEntry()
        }
    }

    func syncSomeIMImageUnderstanding(apiKey: String) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        var configuration = agentConfiguration.normalized
        configuration.imageDescription = AgentImageDescriptionConfiguration(
            providerID: "some-im",
            baseURL: SomeIMRelayRegion.chinaBaseURL,
            model: SomeIMIntegrationSettings.defaultVisionModel,
            apiKey: trimmedKey
        ).normalized
        agentConfiguration = configuration.normalized
    }

    /// React to a shared some.im session change (this app or another one sharing
    /// the Keychain access group). Login/key-change adopts the fresh key without
    /// hijacking the user's active provider; logout drops the some-im entry.
    func reconcileSomeIMProviderFromSharedSession() {
        let apiKey = SomeIMIntegrationStore.loadAPIKey()
        if apiKey.isEmpty {
            clearSomeIMProvider()
        } else {
            syncSomeIMProvider(
                settings: SomeIMIntegrationStore.loadSettings(),
                apiKey: apiKey,
                activate: false
            )
            syncSomeIMImageUnderstanding(apiKey: apiKey)
        }
    }

    /// Remove every some.im provider entry (used when the shared session is
    /// cleared). `removeProviderLibraryEntry` re-points `activeID` to a
    /// surviving entry when one exists.
    func clearSomeIMProvider() {
        let someIMEntryIDs = agentProviderLibrary.entries
            .filter { $0.providerID == "some-im" }
            .map(\.id)
        for id in someIMEntryIDs {
            removeProviderLibraryEntry(id: id)
        }
    }

    /// Remove a library entry. The library auto-repoints `activeID`
    /// to the next entry; if nothing remains the live configuration
    /// is left as-is (the Settings UI is expected to require at
    /// least one entry to chat).
    func removeProviderLibraryEntry(id: UUID) {
        let wasActive = agentProviderLibrary.activeID == id
        agentProviderLibrary.remove(id: id)
        // Drop the Keychain row for the removed entry's API key.
        AgentSettingsStore.deleteLibraryEntryAPIKey(for: id)
        if wasActive, agentProviderLibrary.active != nil {
            applyActiveProviderLibraryEntry()
        }
    }

    // A 方案：原先的 `syncActiveLibraryEntryFromConfiguration` 已被移除。
    // 该函数曾从 cfg.didSet 回灌 active entry，把 legacy
    // `agentConfiguration.providerID = "openai"` 默认值写到 DeepSeek
    // 条目身上，造成 "OpenAI 顶着 DeepSeek 的 API key" 这类 bug。
    // 单向流：library → cfg via `applyActiveProviderLibraryEntry`。

    // MARK: - Interaction modes (plan / goal)

    /// Flip the session into a different interaction mode. Switching out
    /// of Plan or Goal also drops any associated state so the next
    /// session pick-up starts clean.
    func setAgentInteractionMode(_ mode: AgentInteractionMode) {
        guard agentInteractionMode != mode else { return }
        agentInteractionMode = mode
        if mode != .plan { agentCurrentPlan = nil }
        if mode != .goal { agentCurrentGoal = nil }
        persistActiveAgentSession()
    }

    /// Update the active session's tool approval posture. This is
    /// intentionally session-scoped so a cautious remote-runtime chat
    /// can require every approval while a local scratch chat stays
    /// frictionless.
    func setAgentApprovalMode(_ mode: AgentApprovalMode) {
        guard agentApprovalMode != mode else { return }
        agentApprovalMode = mode
        persistActiveAgentSession()
    }

    /// Choose which execution backend the composer should use for this
    /// session. Provider/model selection remains separate; this only
    /// controls whether the next user turn runs natively or delegates to
    /// an external coding-agent CLI.
    func setAgentExecutionAgent(_ agent: AgentExecutionAgent) {
        guard agentExecutionAgent != agent else { return }
        agentExecutionAgent = agent
        persistActiveAgentSession()
    }

    /// Activate an optional expert pack for the active session. Experts widen
    /// the model-facing tool surface and add a small domain contract once
    /// enabled; activation is intentionally one-way for the session.
    func activateAgentExpert(_ expert: AgentExpert) {
        var experts = agentActiveExperts
        guard !experts.contains(expert) else { return }
        experts.insert(expert)
        agentActiveExperts = experts
        persistActiveAgentSession()
    }

    /// User clicks Approve on the proposed plan — flips it to approved
    /// so the next turn's system prompt unlocks write tools.
    func approveAgentPlan() {
        guard var plan = agentCurrentPlan else { return }
        plan.status = .approved
        agentCurrentPlan = plan
        persistActiveAgentSession()
    }

    /// User clicks Reject — drops the plan so the agent re-plans next turn.
    func rejectAgentPlan() {
        agentCurrentPlan = nil
        persistActiveAgentSession()
    }

    /// 1.79.0 plan 自动执行 banner 入口。用户点「执行」或倒计时归零
    /// 时调用。等效于 approve plan + 立刻派发一条「按 plan 执行」的
    /// user 消息，agent 下个 turn 就会开干。
    ///
    /// 故意**留在 Plan 模式**，不切到 Normal：plan 模式的 system
    /// prompt 在 `plan.status == .approved` 时已自动解锁 write tools，
    /// 留在 plan 模式可以保留 plan card 的步骤勾选 / 进度跟踪体验。
    /// 如果 agent 当前 turn 还在跑（罕见 —— banner 只在 plan 刚解析
    /// 完时出现），prompt 会进队列。
    func confirmAgentPlanAndExecute() {
        guard agentInteractionMode == .plan,
              var plan = agentCurrentPlan,
              plan.status == .proposed else { return }
        plan.status = .approved
        agentCurrentPlan = plan
        persistActiveAgentSession()

        let prompt = """
        Plan approved. Please proceed with executing the plan step by step. \
        Emit a ```progress fenced block to mark each step as in_progress / done / failed as you go, \
        and stop when every step has reached a terminal state.
        """
        guard let runtime = activeRuntime else { return }
        if runtime.isResponding {
            runtime.queuedMessages.append(AgentQueuedMessage(text: prompt, images: []))
            return
        }
        dispatchAgentMessage(for: runtime, text: prompt, images: [])
    }

    /// Manually retire an approved plan (e.g. after the agent reported done).
    func completeAgentPlan() {
        guard var plan = agentCurrentPlan else { return }
        plan.status = .done
        agentCurrentPlan = plan
        persistActiveAgentSession()
    }

    /// Ask the agent to revise the current plan. Drops the existing
    /// plan (so the system prompt flips back to "needs a plan") and
    /// auto-sends a user message — either the bare "please revise"
    /// boilerplate, or the caller's free-form note appended to it.
    /// Falls through to the normal queue path if the agent is busy.
    func requestPlanRevision(note: String) {
        guard agentInteractionMode == .plan else { return }
        // Drop the existing plan so the next turn's system prompt
        // sends the "you must emit a ```plan block" instructions.
        agentCurrentPlan = nil
        persistActiveAgentSession()

        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt: String
        if trimmed.isEmpty {
            prompt = "Please revise the plan. Re-emit a fresh ```plan``` block reflecting the new approach, then stop and wait for approval."
        } else {
            prompt = """
            Please revise the plan with this guidance from me:

            \(trimmed)

            Re-emit a fresh ```plan``` block reflecting the new approach, then stop and wait for approval.
            """
        }

        guard let runtime = activeRuntime else { return }
        if runtime.isResponding {
            runtime.queuedMessages.append(AgentQueuedMessage(text: prompt, images: []))
            return
        }
        dispatchAgentMessage(for: runtime, text: prompt, images: [])
    }

    /// Parse the most recent assistant message looking for a ```plan
    /// fenced block and replace `agentCurrentPlan` if one is found and
    /// the user hasn't already approved a plan this session. Convenience
    /// wrapper that targets `activeRuntime`; the turn loop calls the
    /// runtime-explicit variant below.
    func captureAgentPlanFromLatestMessage() {
        guard let runtime = activeRuntime else { return }
        captureAgentPlanFromLatestMessage(for: runtime)
    }

    func captureAgentPlanFromLatestMessage(for runtime: AgentRuntime) {
        guard runtime.interactionMode == .plan else { return }
        if let existing = runtime.currentPlan,
           existing.status == .approved || existing.status == .executing || existing.status == .done {
            applyAgentPlanProgressFromLatestMessage(for: runtime, existingPlan: existing)
            return
        }
        guard let last = runtime.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }),
              let parsed = AgentPlanParser.extract(from: last.content) else {
            return
        }
        runtime.currentPlan = parsed
    }

    func applyAgentPlanProgressFromLatestMessage(for runtime: AgentRuntime, existingPlan: AgentPlan) {
        guard let last = runtime.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }) else { return }
        if let next = AgentPlanParser.applyProgress(to: existingPlan, from: last.content) {
            runtime.currentPlan = next
        }
    }

    /// Convenience wrapper that targets `activeRuntime`.
    func captureAgentGoalEvaluationFromLatestMessage() {
        guard let runtime = activeRuntime else { return }
        captureAgentGoalEvaluationFromLatestMessage(for: runtime)
    }

    func captureAgentGoalDefinitionFromLatestMessage(for runtime: AgentRuntime) {
        guard runtime.interactionMode == .goal,
              runtime.currentGoal == nil || runtime.currentGoal?.isEmpty == true else { return }
        guard let last = runtime.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }),
              let parsed = AgentGoalParser.extract(from: last.content),
              !parsed.isEmpty else {
            return
        }
        runtime.currentGoal = parsed
        persistAgentSession(runtime: runtime)
    }

    func captureAgentGoalEvaluationFromLatestMessage(for runtime: AgentRuntime) {
        guard runtime.interactionMode == .goal,
              let goal = runtime.currentGoal,
              !goal.checklist.isEmpty else { return }
        guard let last = runtime.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }) else { return }
        if let editedAt = runtime.currentGoalEditedAt,
           last.createdAt < editedAt {
            return
        }
        if let updated = AgentGoalChecklistParser.applyEvaluation(to: goal, from: last.content) {
            runtime.currentGoal = updated
            persistAgentSession(runtime: runtime)
        }
    }

    /// Manually override a single step's status from the UI checkbox.
    /// Mirrors the model-driven path: bumps the plan to .executing on
    /// first touch, .done when everything is terminal.
    func setAgentPlanStepStatus(id: UUID, status: AgentPlan.StepStatus) {
        guard var plan = agentCurrentPlan,
              let idx = plan.steps.firstIndex(where: { $0.id == id }) else { return }
        plan.steps[idx].status = status
        let terminal: Set<AgentPlan.StepStatus> = [.done, .skipped, .failed]
        if plan.steps.allSatisfy({ terminal.contains($0.status) }) {
            plan.status = .done
        } else if plan.status == .approved {
            plan.status = .executing
        }
        agentCurrentPlan = plan
        persistActiveAgentSession()
    }

    /// Edit a step's text in place — handy when the agent's wording
    /// isn't quite right and the user wants to fix it before/during
    /// execution. Status is preserved.
    func editAgentPlanStepText(id: UUID, newText: String) {
        guard var plan = agentCurrentPlan,
              let idx = plan.steps.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        plan.steps[idx].text = trimmed
        agentCurrentPlan = plan
        persistActiveAgentSession()
    }

    /// Insert a fresh pending step before/after another step (or at the
    /// list start/end if `relativeToID` is nil). Plan status is left
    /// alone — adding a step to an executing plan keeps it executing.
    func insertAgentPlanStep(text: String, relativeToID: UUID?, before: Bool) {
        guard var plan = agentCurrentPlan else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let newStep = AgentPlan.Step(text: trimmed, status: .pending)
        let insertIdx: Int
        if let relativeToID, let i = plan.steps.firstIndex(where: { $0.id == relativeToID }) {
            insertIdx = before ? i : i + 1
        } else {
            insertIdx = before ? 0 : plan.steps.count
        }
        plan.steps.insert(newStep, at: insertIdx)
        // If the plan was already .done but a step was added, it's not
        // done anymore — bump it back to executing.
        if plan.status == .done {
            plan.status = .executing
        }
        agentCurrentPlan = plan
        persistActiveAgentSession()
    }

    /// Remove a step entirely. Promotes to .done if the remaining steps
    /// are all terminal; demotes to .approved if the plan becomes empty.
    func removeAgentPlanStep(id: UUID) {
        guard var plan = agentCurrentPlan,
              let idx = plan.steps.firstIndex(where: { $0.id == id }) else { return }
        plan.steps.remove(at: idx)
        let terminal: Set<AgentPlan.StepStatus> = [.done, .skipped, .failed]
        if plan.steps.isEmpty {
            plan.status = .approved   // back to "no progress yet" rather than .done
        } else if plan.steps.allSatisfy({ terminal.contains($0.status) }) {
            plan.status = .done
        }
        agentCurrentPlan = plan
        persistActiveAgentSession()
    }

    /// Reset a step (and every step after it) back to .pending, then
    /// ask the agent to resume from that point. "Run from here" — the
    /// common need when an earlier step's output turned out wrong and
    /// every downstream step has to be redone.
    func restartAgentPlanFromStep(id: UUID, note: String) {
        guard agentInteractionMode == .plan,
              var plan = agentCurrentPlan,
              let startIdx = plan.steps.firstIndex(where: { $0.id == id }) else { return }
        for i in startIdx..<plan.steps.count {
            plan.steps[i].status = .pending
        }
        // Plan stays approved/executing — we're not redoing the
        // approval gate, just rewinding the execution head.
        if plan.status == .done { plan.status = .executing }
        agentCurrentPlan = plan
        persistActiveAgentSession()

        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = "Please restart execution from step \(startIdx + 1) onward."
        let prompt: String
        if trimmed.isEmpty {
            prompt = "\(header) Steps \(startIdx + 1)..\(plan.steps.count) have been reset to pending. Pick up there and emit a `progress` block as you go."
        } else {
            prompt = """
            \(header) Steps \(startIdx + 1)..\(plan.steps.count) have been reset to pending. Here's why:

            \(trimmed)

            Pick up from step \(startIdx + 1) and emit a `progress` block as you go.
            """
        }
        guard let runtime = activeRuntime else { return }
        if runtime.isResponding {
            runtime.queuedMessages.append(AgentQueuedMessage(text: prompt, images: []))
            return
        }
        dispatchAgentMessage(for: runtime, text: prompt, images: [])
    }

    /// Replace the goal definition for Goal mode. Empty values clear it.
    /// Preserves existing checklist `done` state when an item's text
    /// hasn't changed — so the user can tweak the goal statement or add
    /// new items without losing what's already ticked.
    func setAgentGoal(statement: String, items: [String]) {
        guard let runtime = activeRuntime else { return }
        let trimmedStatement = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedItems = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let previousGoal = runtime.currentGoal

        if trimmedStatement.isEmpty && trimmedItems.isEmpty {
            runtime.currentGoal = nil
            if previousGoal != nil {
                runtime.currentGoalEditedAt = Date()
            }
            persistActiveAgentSession()
            enqueueGoalUpdateNoticeIfNeeded(for: runtime, previousGoal: previousGoal, updatedGoal: nil)
            return
        }
        var priorItemsByText: [String: AgentGoal.Item] = [:]
        for item in runtime.currentGoal?.checklist ?? [] {
            if priorItemsByText[item.text] == nil {
                priorItemsByText[item.text] = item
            }
        }
        let updatedGoal = AgentGoal(
            statement: trimmedStatement,
            checklist: trimmedItems.map { text in
                if let prior = priorItemsByText[text] {
                    return AgentGoal.Item(id: prior.id, text: text, done: prior.done)
                }
                return AgentGoal.Item(text: text)
            }
        )
        runtime.currentGoal = updatedGoal
        if previousGoal != updatedGoal {
            runtime.currentGoalEditedAt = Date()
        }
        persistActiveAgentSession()
        enqueueGoalUpdateNoticeIfNeeded(for: runtime, previousGoal: previousGoal, updatedGoal: updatedGoal)
    }

    private func enqueueGoalUpdateNoticeIfNeeded(
        for runtime: AgentRuntime,
        previousGoal: AgentGoal?,
        updatedGoal: AgentGoal?
    ) {
        guard runtime.interactionMode == .goal,
              runtime.isResponding,
              previousGoal != updatedGoal else { return }
        runtime.queuedMessages.append(
            AgentQueuedMessage(
                text: Self.goalUpdateFollowUpPrompt(for: updatedGoal),
                images: [],
                executionAgent: runtime.executionAgent
            )
        )
    }

    private static func goalUpdateFollowUpPrompt(for goal: AgentGoal?) -> String {
        guard let goal, !goal.isEmpty else {
            return "The user cleared the active Goal while you were working. Stop following the previous goal. Ask for a new goal if needed before continuing Goal-mode work."
        }

        var lines = [
            "The user updated the active Goal while you were working. Continue using this updated goal and ignore the previous goal.",
            "",
            "Updated goal:",
            goal.statement.isEmpty ? "- Goal statement: (none)" : "- Goal statement: \(goal.statement)"
        ]
        if !goal.checklist.isEmpty {
            lines.append("- Acceptance checklist:")
            for (index, item) in goal.checklist.enumerated() {
                lines.append("  \(index + 1). [\(item.done ? "x" : " ")] \(item.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Toggle a single checklist item by id. The flipped state shows up
    /// in the next system prompt, so the agent sees progress.
    func toggleAgentGoalItem(_ id: UUID) {
        guard var goal = agentCurrentGoal else { return }
        guard let idx = goal.checklist.firstIndex(where: { $0.id == id }) else { return }
        goal.checklist[idx].done.toggle()
        agentCurrentGoal = goal
        persistActiveAgentSession()
    }

    func reviewAgentWorktreeChanges() {
        guard !agentWorktreeChanges.isEmpty else { return }

        let files = agentWorktreeChanges.files
            .prefix(40)
            .map { change in
                "- \(change.path) \(Self.formatLineStats(change.lineStats))"
            }
            .joined(separator: "\n")
        let extraCount = max(0, agentWorktreeChanges.fileCount - 40)
        let extraLine = extraCount > 0 ? "\n- ...and \(extraCount) more files" : ""
        let prompt = """
        Please review the current uncommitted workspace changes.

        Focus on bugs, hangs/freezes, regressions, approval/security risks, and missing tests. Start with findings ordered by severity and cite file paths.

        Change summary:
        \(files)\(extraLine)
        """

        guard let runtime = activeRuntime else { return }
        runtime.input = ""
        runtime.pendingImages = []

        if runtime.isResponding {
            runtime.queuedMessages.append(AgentQueuedMessage(text: prompt, images: []))
            return
        }

        if appMode == .editor {
            isAgentPanelVisible = true
        }
        dispatchAgentMessage(for: runtime, text: prompt, images: [])
    }

    func showAgentWorktreeDiff() {
        let changes = agentWorktreeChanges
        guard !changes.isEmpty else { return }

        let repositoryRoot = changes.repositoryRoot
            ?? activeRuntime?.workspaceRootPath.map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? rootDirectory?.standardizedFileURL
        guard let repositoryRoot else { return }

        Task { [weak self] in
            let preview = await Task.detached(priority: .utility) {
                Self.loadAgentWorktreeDiffPreview(changes: changes, repositoryRoot: repositoryRoot)
            }.value
            await MainActor.run {
                self?.agentWorktreeDiffPreview = preview
            }
        }
    }

    /// Cancel the in-flight response (if any). Queued messages are kept and
    /// the next one is dispatched automatically. Use `clearAgentQueue` to
    /// drop them explicitly.
    func stopAgentResponse() {
        guard let runtime = activeRuntime, runtime.isResponding else { return }
        closeBlockingAgentToolDecision(for: runtime, reason: "Response stopped")
        runtime.shouldConsumeQueueAfterStop = !runtime.queuedMessages.isEmpty
        runtime.requestTask?.cancel()
        Task { @MainActor [weak self, weak runtime] in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self, let runtime else { return }
                guard runtime.shouldConsumeQueueAfterStop else { return }
                if !runtime.isResponding, runtime.requestTask == nil {
                    runtime.shouldConsumeQueueAfterStop = false
                    self.consumeNextQueuedMessageIfNeeded(for: runtime)
                    return
                }
            }
        }
    }

    @discardableResult
    func closeBlockingAgentToolDecision(for runtime: AgentRuntime, reason: String) -> Bool {
        var closedAny = false
        for index in runtime.toolCalls.indices where runtime.toolCalls[index].status.isBlockingForUserDecision {
            runtime.pendingToolDecisions.removeValue(forKey: runtime.toolCalls[index].id)
            runtime.toolCalls[index].status = .denied
            runtime.toolCalls[index].errorMessage = reason
            closedAny = true
        }
        if let waiter = runtime.toolDecisionWaiter {
            runtime.toolDecisionWaiter = nil
            runtime.toolDecisionWaiterCallID = nil
            waiter.resume(returning: .denied(reason: reason))
            closedAny = true
        }
        return closedAny
    }

    func clearAgentQueue() {
        agentQueuedMessages.forEach(Self.removeStoredImageFiles)
        agentQueuedMessages.removeAll()
    }

    func removeQueuedAgentMessage(id: AgentQueuedMessage.ID) {
        let removed = agentQueuedMessages.filter { $0.id == id }
        removed.forEach(Self.removeStoredImageFiles)
        agentQueuedMessages.removeAll { $0.id == id }
    }

    func editQueuedAgentMessage(id: AgentQueuedMessage.ID) {
        guard let runtime = activeRuntime,
              let index = runtime.queuedMessages.firstIndex(where: { $0.id == id })
        else { return }

        let message = runtime.queuedMessages.remove(at: index)
        runtime.input = message.text
        runtime.pendingImages = message.images
        runtime.pendingTextAttachments = message.textAttachments
        runtime.pendingSkills = []
        runtime.pendingFiles = []
        runtime.pendingIncludeWorkspaceOverview = false
    }

    func sendQueuedAgentMessageNow(id: AgentQueuedMessage.ID) {
        guard let runtime = activeRuntime,
              let index = runtime.queuedMessages.firstIndex(where: { $0.id == id })
        else { return }

        let message = runtime.queuedMessages.remove(at: index)
        runtime.queuedMessages.insert(message, at: 0)

        if runtime.isResponding {
            closeBlockingAgentToolDecision(for: runtime, reason: "Sending queued message")
            runtime.shouldConsumeQueueAfterStop = true
            runtime.requestTask?.cancel()
        } else {
            consumeNextQueuedMessageIfNeeded(for: runtime)
        }
    }

    func addAgentImage(data: Data, mimeType: String) {
        let attachment = (try? AgentImageAttachment.fileBacked(data: data, mimeType: mimeType))
            ?? AgentImageAttachment(mimeType: mimeType, dataBase64: data.base64EncodedString())
        agentPendingImages.append(attachment)
    }

    func removeAgentImage(id: AgentImageAttachment.ID) {
        agentPendingImages
            .filter { $0.id == id }
            .forEach { $0.removeStoredFileIfNeeded() }
        agentPendingImages.removeAll { $0.id == id }
    }

    private nonisolated static func removeStoredImageFiles(_ message: AgentQueuedMessage) {
        message.images.forEach { $0.removeStoredFileIfNeeded() }
    }

    // MARK: - Agent mode + sessions

    func setAppMode(_ mode: AppMode) {
        guard appMode != mode else { return }
        appMode = mode
        if mode == .agent, activeAgentSessionID == nil {
            // Drop any stale Editor-mode chat state when first entering
            // Agent mode so the user lands on an empty New Chat.
            agentRequestTask?.cancel()
            agentMessages = []
            agentPatchProposals = []
            agentToolCalls = []
            agentQueuedMessages = []
            agentPendingImages = []
            agentErrorMessage = nil
            agentErrorDetails = nil
            isAgentResponding = false
            agentTurnStartedAt = nil
            startNewAgentSession()
        }
    }

    func toggleAppMode() {
        setAppMode(appMode == .agent ? .editor : .agent)
    }

    private func upsertAgentUsageSnapshot(for session: AgentSession) {
        let snapshot = AgentUsageSessionSnapshot(session: session)
        if let index = agentUsageSnapshots.firstIndex(where: { $0.id == session.id }) {
            agentUsageSnapshots[index] = snapshot
        } else {
            agentUsageSnapshots.insert(snapshot, at: 0)
        }
        agentUsageSnapshots.sort { $0.updatedAt > $1.updatedAt }
    }

    private func removeAgentUsageSnapshot(id: AgentSession.ID) {
        agentUsageSnapshots.removeAll { $0.id == id }
    }

    @discardableResult
    func startNewAgentSession() -> AgentSession {
        // Pre-rc2 this function cleared a wall of `agent*` fields on
        // AppState (messages, toolCalls, queued, errors, …). Under rc2
        // those fields delegate to `activeRuntime`, so clearing them
        // here would actually wipe the OUTGOING session's runtime —
        // the wrong thing. rc4 went further: the outgoing turn isn't
        // even cancelled. With per-runtime concurrency, "I want a new
        // chat" no longer implies "kill the one I was on" — the old
        // one keeps streaming in the background and the user can pick
        // it back up from the sidebar.

        // Garbage-collect any prior empty "New Chat" rows before adding a
        // fresh one — otherwise repeatedly pressing ⌘N stacks up empty
        // placeholders in the sidebar.
        pruneEmptyAgentSessions()

        let session = AgentSession(
            workspaceRootPath: rootDirectory?.standardizedFileURL.path,
            workspaceLocation: (rootDirectory?.standardizedFileURL.path).map { WorkspaceLocation.local(path: $0) },
            modelID: activeAgentModelID
        )
        agentSessions.insert(session, at: 0)
        // Build the runtime BEFORE flipping activeAgentSessionID — the
        // delegated `agent*` setters below all route to `activeRuntime`,
        // and there has to be one in `agentRuntimes` for those writes
        // to land somewhere.
        let newRuntime = AgentRuntime(session: session)
        agentRuntimes[session.id] = newRuntime
        activeAgentSessionID = session.id
        subscribeToActiveRuntime()
        evictInactiveAgentRuntimesIfNeeded()
        // These now go to the freshly-built runtime via delegation.
        agentSessionDidEditFiles = false
        agentInteractionMode = .normal
        agentApprovalMode = .smart
        agentCurrentPlan = nil
        agentCurrentGoal = nil
        AgentSessionStore.save(session)
        upsertAgentUsageSnapshot(for: session)
        return session
    }

    /// Start a new session bound to a specific workspace. 1.85.0-rc11 起
    /// 不再顺手把 editor 窗口的 `rootDirectory` 切过去 —— agent runtime 自
    /// 己持有 workspace 路径就够了,editor 不应该被 agent 这边的切换拖着
    /// 走。Pass `nil` for the "no workspace" group。
    ///
    /// 注意:`startNewAgentSession()` 是从 `rootDirectory` 推 workspace 的
    /// (老路径默认认为 agent 跟 editor 同根)。rc11 解耦后,这里必须显式
    /// 用入参重建 session,而不是甩给无参版本 —— 否则新会话会继承 editor
    /// 当前的根,跟用户在菜单里选的目录对不上。
    @discardableResult
    func startNewAgentSession(inWorkspaceAt workspacePath: String?) -> AgentSession {
        let normalizedPath: String?
        if let workspacePath, !workspacePath.isEmpty {
            let url = URL(fileURLWithPath: workspacePath).standardizedFileURL
            if Self.isExistingDirectory(url) {
                _ = activateSecurityScope(for: url)
                registerRecentFolder(url)
            }
            normalizedPath = url.path
        } else {
            normalizedPath = nil
        }

        pruneEmptyAgentSessions()

        let session = AgentSession(
            workspaceRootPath: normalizedPath,
            workspaceLocation: normalizedPath.map { WorkspaceLocation.local(path: $0) },
            modelID: activeAgentModelID
        )
        agentSessions.insert(session, at: 0)
        let newRuntime = AgentRuntime(session: session)
        agentRuntimes[session.id] = newRuntime
        activeAgentSessionID = session.id
        subscribeToActiveRuntime()
        evictInactiveAgentRuntimesIfNeeded()
        agentSessionDidEditFiles = false
        agentInteractionMode = .normal
        agentApprovalMode = .smart
        agentCurrentPlan = nil
        agentCurrentGoal = nil
        AgentSessionStore.save(session)
        upsertAgentUsageSnapshot(for: session)
        unhideWorkspace(key: session.workspaceSidebarGroupKey)
        return session
    }

    // MARK: - Hidden workspaces

    private static let hiddenWorkspaceKeysDefaultsKey = "com.willdeep.sidebar.hiddenWorkspaceKeys.v1"

    static func loadHiddenWorkspaceKeys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hiddenWorkspaceKeysDefaultsKey) ?? [])
    }

    private func persistHiddenWorkspaceKeys() {
        UserDefaults.standard.set(Array(hiddenWorkspaceKeys), forKey: Self.hiddenWorkspaceKeysDefaultsKey)
    }

    /// Hide a workspace group from the sidebar. Sessions stay on disk —
    /// this only flips visibility, so re-adding the same folder restores
    /// the full chat list. The catch-all "no workspace" group can't be
    /// hidden.
    func hideWorkspace(key: String) {
        guard key != AgentSession.noWorkspaceSidebarGroupKey else { return }
        hiddenWorkspaceKeys.insert(key)
        persistHiddenWorkspaceKeys()
    }

    /// Un-hide a workspace (called when the user re-adds / switches into
    /// it), bringing its preserved sessions back into the sidebar.
    func unhideWorkspace(key: String) {
        guard hiddenWorkspaceKeys.contains(key) else { return }
        hiddenWorkspaceKeys.remove(key)
        persistHiddenWorkspaceKeys()
    }

    /// Bind the current composer/session to a selected workspace. Empty
    /// placeholder sessions are migrated in place. A history-bearing
    /// session is also migrated when it currently lives under "No
    /// workspace", because the user is anchoring that same conversation
    /// rather than switching between real project roots. Sessions with
    /// real history and an existing workspace still get a fresh chat so
    /// old tool context is never silently rewritten to a different folder.
    @discardableResult
    func moveActiveAgentSessionToWorkspace(at workspacePath: String) -> AgentSession {
        let url = URL(fileURLWithPath: workspacePath).standardizedFileURL
        if Self.isExistingDirectory(url) {
            // 1.85.0-rc9：agent 选 folder 不再联动 editor 窗口的 rootDirectory。
            // 只为 agent 子进程拿读取权限 + 写 recents,editor 侧保持原样。
            _ = activateSecurityScope(for: url)
            registerRecentFolder(url)
        }

        if let runtime = activeRuntime, canRebindActiveRuntimeInPlace(runtime) {
            pruneEmptyAgentSessions(excluding: runtime.id)
            runtime.rebindWorkspace(to: url.path)
            runtime.worktreeChanges = .init()
            persistAgentSession(runtime: runtime)
            unhideWorkspace(key: runtime.session.workspaceSidebarGroupKey)
            return runtime.session
        }

        return startNewAgentSession(inWorkspaceAt: url.path)
    }

    private func canRebindActiveRuntimeInPlace(_ runtime: AgentRuntime) -> Bool {
        guard !runtime.isResponding else { return false }
        if runtime.isEmpty { return true }
        return runtime.workspaceLocation == nil
            && (runtime.workspaceRootPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    @discardableResult
    func moveActiveAgentSessionToRemoteWorkspace(runtimeID: UUID, path: String) -> AgentSession {
        let normalizedPath = RemotePathValidator.normalizedWorkspaceRoot(path)
        if let runtime = activeRuntime, runtime.isEmpty, !runtime.isResponding {
            pruneEmptyAgentSessions(excluding: runtime.id)
            runtime.rebindRemoteWorkspace(runtimeID: runtimeID, path: normalizedPath)
            runtime.worktreeChanges = .init()
            persistAgentSession(runtime: runtime)
            unhideWorkspace(key: runtime.session.workspaceSidebarGroupKey)
            return runtime.session
        }

        pruneEmptyAgentSessions()
        let session = AgentSession(
            workspaceRootPath: nil,
            workspaceLocation: .remote(runtimeID: runtimeID, path: normalizedPath),
            modelID: activeAgentModelID
        )
        agentSessions.insert(session, at: 0)
        let newRuntime = AgentRuntime(session: session)
        agentRuntimes[session.id] = newRuntime
        activeAgentSessionID = session.id
        subscribeToActiveRuntime()
        evictInactiveAgentRuntimesIfNeeded()
        agentSessionDidEditFiles = false
        agentInteractionMode = .normal
        agentApprovalMode = .smart
        agentCurrentPlan = nil
        agentCurrentGoal = nil
        AgentSessionStore.save(session)
        upsertAgentUsageSnapshot(for: session)
        unhideWorkspace(key: session.workspaceSidebarGroupKey)
        return session
    }

    func selectAgentSession(id: AgentSession.ID) {
        guard agentSessions.contains(where: { $0.id == id }) else { return }
        // Save the outgoing session first.
        persistActiveAgentSession()

        // rc4: switching away from a session no longer kills its in-flight
        // turn. Each runtime owns its own request task and waiter; with
        // real concurrency in place, switching is purely a UI focus
        // change. The outgoing turn keeps streaming, and the sidebar's
        // status dot makes that visible (green pulse on the row you
        // just left). If the user actually wants to stop it, the Stop
        // button on that runtime's chat pane is the explicit affordance.

        // Make sure the destination runtime is built before flipping
        // `activeAgentSessionID` — delegated readers fall back to
        // safe defaults if the runtime is missing, which would briefly
        // show the new session as empty before the runtime appears.
        guard runtime(for: id) != nil else { return }
        activeAgentSessionID = id
        subscribeToActiveRuntime()
        evictInactiveAgentRuntimesIfNeeded()

        // Re-derive the session model override from the persisted
        // session record. The runtime carries it across the lifetime
        // of one launch, but a freshly-built runtime started from a
        // disk session needs this seeded.
        if let runtime = activeRuntime {
            let session = runtime.session
            if runtime.managedRouting != nil {
                // Managed session: the model is resolved per-turn by the
                // judge, so there is no single override to seed.
                runtime.sessionModelOverride = nil
            } else {
                let routedModel = agentConfiguration.normalized.model(for: .interactive)
                runtime.sessionModelOverride = session.modelID == routedModel ? nil : session.modelID
            }
            syncWorkspaceContext(for: session)
            autoSummarizeTitleIfPlaceholder(runtime)
        }
    }

    /// When the user opens a session still carrying a generic placeholder
    /// title ("New Chat" / "新对话" / "Chat"), kick off a one-shot LLM title
    /// summary so the sidebar stops showing the placeholder. The summarizer
    /// self-gates: it no-ops unless there's a finished user→assistant
    /// exchange, a usable provider, and no summary already in flight — so an
    /// empty new chat won't trigger a request. `force` bypasses the
    /// "only on the first assistant turn" gate so older multi-turn sessions
    /// still get titled on reopen. User-renamed titles are left alone.
    private func autoSummarizeTitleIfPlaceholder(_ runtime: AgentRuntime) {
        guard !runtime.session.titleIsUserSet,
              AgentSessionStore.isPlaceholderTitle(runtime.session.title) else { return }
        summarizeAgentSessionTitleIfNeeded(runtime: runtime, force: true)
    }

    /// 1.85.0-rc11:切到历史会话时不再把 editor 窗口的 `rootDirectory`
    /// 一起拽过去。Agent 工具读 / git status / quick-open 等都基于
    /// `runtime.session.workspaceRootPath` 走 agent 自己的上下文,editor
    /// 窗口保持用户当前的浏览状态。这里只确保子进程拿到该路径的
    /// security scope。Remote 会话本来就不动 editor。
    private func syncWorkspaceContext(for session: AgentSession) {
        let location = session.workspaceLocation ?? session.workspaceRootPath.map { .local(path: $0) }
        guard case .local(let path) = location, !path.isEmpty else {
            return
        }

        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard Self.isExistingDirectory(url) else { return }
        _ = activateSecurityScope(for: url)
    }

    /// Drop sessions that never received a user message — they're
    /// indistinguishable "New Chat" placeholders left behind by users
    /// who hit ⌘N and walked away. The currently-active session is
    /// preserved even when empty (the user is presumably about to type
    /// into it). Wipes both the in-memory list and the persisted JSON.
    func pruneEmptyAgentSessions(excluding protectedID: AgentSession.ID? = nil) {
        let activeID = activeAgentSessionID
        let toRemove = agentSessions.filter { session in
            if session.id == activeID { return false }
            if session.id == protectedID { return false }
            if AgentSessionStore.isMetadataOnly(session.id) {
                return !AgentSessionStore.metadataOnlySessionHasUserMessage(session.id)
            }
            if pendingDispatchQueue.contains(where: { $0.runtimeID == session.id }) { return false }
            if let runtime = agentRuntimes[session.id] {
                if runtime.isResponding || runtime.requestTask != nil || runtime.toolDecisionWaiter != nil {
                    return false
                }
                if runtime.messages.contains(where: { $0.role == .user }) {
                    return false
                }
            }
            return !session.messages.contains(where: { $0.role == .user })
        }
        guard !toRemove.isEmpty else { return }
        for session in toRemove {
            AgentSessionStore.delete(id: session.id)
        }
        let removedIDs = Set(toRemove.map(\.id))
        agentSessions.removeAll { removedIDs.contains($0.id) }
        agentUsageSnapshots.removeAll { removedIDs.contains($0.id) }
        // Tear down any runtimes left for the pruned sessions, lest
        // they keep republishing change events into AppState and
        // hold onto in-flight tasks for sessions that no longer exist.
        for id in removedIDs {
            if let runtime = agentRuntimes[id] {
                runtime.requestTask?.cancel()
                runtime.toolDecisionWaiter?.resume(returning: .denied(reason: "Empty session pruned"))
                runtime.toolDecisionWaiter = nil
                runtime.toolDecisionWaiterCallID = nil
                runtime.pendingToolDecisions.removeAll()
            }
            agentSubagentRegistry.cancelAll(forParentRuntime: id)
            agentRuntimes.removeValue(forKey: id)
        }
    }

    /// Lazy lookup: returns the existing runtime for `sessionID` or
    /// builds one on demand from the persisted session list. Used by
    /// the session lifecycle hooks below to make sure every selected
    /// session has a runtime entry sitting in `agentRuntimes`. Returns
    /// nil only when the session id doesn't exist anymore (e.g. it was
    /// just deleted on disk).
    @discardableResult
    func runtime(for sessionID: AgentSession.ID) -> AgentRuntime? {
        if let existing = agentRuntimes[sessionID] { return existing }
        guard let session = materializeAgentSessionIfNeeded(id: sessionID) else { return nil }
        let runtime = AgentRuntime(session: session)
        agentRuntimes[sessionID] = runtime
        evictInactiveAgentRuntimesIfNeeded()
        return runtime
    }

    @discardableResult
    private func materializeAgentSessionIfNeeded(id: AgentSession.ID) -> AgentSession? {
        guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return nil }
        guard AgentSessionStore.isMetadataOnly(id) else {
            return agentSessions[index]
        }
        guard let fullSession = AgentSessionStore.load(id: id) else {
            return nil
        }
        agentSessions[index] = fullSession
        return fullSession
    }

    private func evictInactiveAgentRuntimesIfNeeded() {
        let maximumIdleRuntimes = 6
        var protectedIDs = Set([activeAgentSessionID].compactMap { $0 })
        protectedIDs.formUnion(pendingDispatchQueue.map(\.runtimeID))
        protectedIDs.formUnion(titleSummarizationsInFlight)
        let idle = agentRuntimes.values
            .filter { runtime in
                !protectedIDs.contains(runtime.id)
                    && !runtime.isResponding
                    && runtime.requestTask == nil
                    && runtime.toolDecisionWaiter == nil
                    // A session waiting on background work is not idle:
                    // evicting it here would cancel its live subagents
                    // (cancelAll below) and orphan alive shell jobs, and
                    // any already-queued completion would depend on the
                    // finish-hook re-materializing the runtime. Keep it
                    // resident until the work is surfaced.
                    && agentJobRegistry.aliveJobs(forRuntime: runtime.id).isEmpty
                    && agentSubagentRegistry.activeCount(forParentRuntime: runtime.id) == 0
                    && !hasPendingBackgroundWakeups(for: runtime)
            }
            .sorted { $0.session.updatedAt > $1.session.updatedAt }

        guard idle.count > maximumIdleRuntimes else { return }
        for runtime in idle.dropFirst(maximumIdleRuntimes) {
            persistAgentSession(runtime: runtime)
            agentSubagentRegistry.cancelAll(forParentRuntime: runtime.id)
            agentRuntimes.removeValue(forKey: runtime.id)
        }
    }

    func deleteAgentSession(id: AgentSession.ID) {
        // If the doomed session is currently mid-turn, cancel its
        // in-flight work before tearing down the runtime so the URL
        // session task and tool-decision waiter don't leak. The
        // turn loop's defer will release the provider slot when the
        // cancellation propagates.
        if let doomed = agentRuntimes[id] {
            doomed.requestTask?.cancel()
            doomed.toolDecisionWaiter?.resume(returning: .denied(reason: "Session deleted"))
            doomed.toolDecisionWaiter = nil
            doomed.toolDecisionWaiterCallID = nil
            doomed.pendingToolDecisions.removeAll()
        }
        // Orphaned background subagents must not keep burning tokens
        // for a session that no longer exists.
        agentSubagentRegistry.cancelAll(forParentRuntime: id)
        // Drop any not-yet-started dispatches queued for this session
        // so they don't fire after the session is gone.
        pendingDispatchQueue.removeAll { $0.runtimeID == id }

        AgentSessionStore.delete(id: id)
        agentSessions.removeAll { $0.id == id }
        removeAgentUsageSnapshot(id: id)
        agentRuntimes.removeValue(forKey: id)
        if activeAgentSessionID == id {
            activeAgentSessionID = nil
            subscribeToActiveRuntime()
        }
    }

    // MARK: - Routines

    /// Insert or replace a routine, then persist + notify the scheduler.
    /// Used by both "create" (id not in list) and "edit" (id already
    /// present) paths from the routine editor sheet.
    func saveAgentRoutine(_ routine: AgentRoutine) {
        var updated = routine
        updated.updatedAt = Date()
        if let index = agentRoutines.firstIndex(where: { $0.id == updated.id }) {
            agentRoutines[index] = updated
        } else {
            agentRoutines.insert(updated, at: 0)
        }
        AgentRoutineStore.save(updated)
        agentRoutines.sort { $0.updatedAt > $1.updatedAt }
        agentRoutineScheduler.routinesChanged(agentRoutines)
        if updated.isEnabled {
            agentRoutineScheduler.requestNotificationAuthorizationIfNeeded()
        }
    }

    func deleteAgentRoutine(id: AgentRoutine.ID) {
        AgentRoutineStore.delete(id: id)
        agentRoutines.removeAll { $0.id == id }
        agentRoutineScheduler.routinesChanged(agentRoutines)
    }

    /// Flip enabled on/off in place. Cheaper than going through the
    /// editor sheet for the sidebar inline toggle.
    func toggleAgentRoutineEnabled(id: AgentRoutine.ID) {
        guard let index = agentRoutines.firstIndex(where: { $0.id == id }) else { return }
        agentRoutines[index].isEnabled.toggle()
        agentRoutines[index].updatedAt = Date()
        AgentRoutineStore.save(agentRoutines[index])
        agentRoutineScheduler.routinesChanged(agentRoutines)
        if agentRoutines[index].isEnabled {
            agentRoutineScheduler.requestNotificationAuthorizationIfNeeded()
        }
    }

    /// User-driven manual fire ("Run now" button in editor or sidebar).
    /// Ignores `isEnabled` — a disabled routine can still be run on demand.
    ///
    /// 1.96.0-rc2:点完"立即运行"以后立刻把活动会话切到新建的 routine
    /// 会话 —— 否则用户什么反馈都看不到,体感是"按了没反应"。
    /// 调度器自动触发(`force == false`)不走这条路,继续保持后台运行。
    func runAgentRoutineNow(id: AgentRoutine.ID) {
        guard let newSessionID = fireRoutine(id: id, force: true) else { return }
        if appMode != .agent {
            setAppMode(.agent)
        }
        selectAgentSession(id: newSessionID)
    }

    /// Scheduler entry point. Returns the new session ID when the routine
    /// actually started a session; nil if the routine was empty / missing
    /// (the scheduler will retry next tick if appropriate).
    ///
    /// Concurrency model (rc3+): scheduler-driven fires spawn a background
    /// runtime rather than yanking the user's UI — they do NOT change
    /// `activeAgentSessionID` and do NOT flip `appMode`. The user keeps
    /// working in whatever session they had on screen; the routine's
    /// session shows up in the sidebar and they can click into it later.
    /// Manual "Run now" (`runAgentRoutineNow`) does switch the active
    /// session — that path is handled by the wrapper above.
    @discardableResult
    func fireRoutine(id: AgentRoutine.ID, force: Bool = false) -> AgentSession.ID? {
        _ = force // The per-provider concurrency cap replaces the old
                  // "is anyone responding?" gate; manual "Run now"
                  // doesn't need to bypass anything different.

        guard let index = agentRoutines.firstIndex(where: { $0.id == id }) else { return nil }
        let routine = agentRoutines[index]
        let prompt = routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }

        // Build the session and its runtime, but DO NOT touch
        // activeAgentSessionID or appMode — that would yank the user
        // out of whatever they're reading.
        let session = AgentSession(
            workspaceRootPath: routine.workspaceRootPath,
            modelID: routine.modelID?.isEmpty == false
                ? routine.modelID
                : agentConfiguration.normalized.model(for: .interactive)
        )
        agentSessions.insert(session, at: 0)
        AgentSessionStore.save(session)
        upsertAgentUsageSnapshot(for: session)
        let runtime = AgentRuntime(session: session)
        agentRuntimes[session.id] = runtime
        // Routine session stays a background runtime — no activeRuntime
        // forward subscription. Sidebar status dot observes it directly.
        if let modelID = routine.modelID, !modelID.isEmpty {
            runtime.sessionModelOverride = modelID
        }

        agentRoutines[index].lastRunAt = Date()
        agentRoutines[index].lastSessionID = session.id
        agentRoutines[index].updatedAt = Date()
        AgentRoutineStore.save(agentRoutines[index])
        agentRoutineScheduler.routinesChanged(agentRoutines)

        // Goal-bearing tasks self-complete: tell this run to evaluate the goal
        // and, if met, call complete_scheduled_task with its own id so the task
        // (and its card) disappears. Plain routines just run the prompt.
        let dispatchText: String
        if let goal = routine.goal?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty {
            dispatchText = """
            \(prompt)

            [定时任务 · 自完成判定] 本次运行来自定时任务「\(routine.name)」(task_id: \(routine.id.uuidString))。
            目标:\(goal)
            完成上述工作后,判断该目标是否已达成:
            - 已达成 → 调用 complete_scheduled_task 工具(task_id 传 \(routine.id.uuidString)),移除这个定时任务;它将不再运行,卡片也会消失。
            - 未达成 → 正常简短汇报当前进展即可,不要调用 complete_scheduled_task。
            """
        } else {
            dispatchText = prompt
        }

        // dispatchAgentMessage handles the per-provider concurrency
        // cap — if the cap is hit, the dispatch queues and drains
        // FIFO as slots free. So even a fleet of 10 routines hitting
        // the same provider all at 09:00 won't stomp on each other.
        dispatchAgentMessage(for: runtime, text: dispatchText, images: [])

        // Sidebar hides sessions whose persisted `session.messages` is
        // still empty (the "empty New Chat" filter in AgentSessionsSidebar
        // groupedSessions). For interactive chats the activeID branch
        // keeps the row visible, but a routine-spawned session is NEVER
        // active by design (rc3+ keeps the user on whatever they were
        // reading). The first message only lands on `session.messages`
        // when runAgentLoop's defer calls persistAgentSession — which is
        // way after the click, and never if the provider call hangs. So
        // here, right after the dispatch synchronously appended the user
        // message to `runtime.messages`, push that state to the session
        // so the row pops into the sidebar immediately. Provider-queue
        // path (cap full → PendingDispatch) leaves runtime.messages
        // empty, which is fine: persist is a no-op-cheap copy in that
        // case and the drain will re-trigger this path soon.
        persistAgentSession(runtime: runtime)
        return session.id
    }

    /// Toggle pin state. Pinned sessions float to the top of their
    /// workspace group, sorted by `pinnedAt` (most recently pinned
    /// first). The timestamp doubles as both the on/off flag and the
    /// within-pinned ordering key, so re-pinning sends the row back to
    /// the top of the pinned block.
    func toggleAgentSessionPinned(id: AgentSession.ID) {
        _ = materializeAgentSessionIfNeeded(id: id)
        guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
        agentSessions[index].pinnedAt = agentSessions[index].pinnedAt == nil ? Date() : nil
        // Mirror onto the live runtime's session copy (rename already
        // does) — otherwise the runtime's next persist() writes its own
        // stale copy back and silently un-pins the row.
        if let runtime = agentRuntimes[id] {
            runtime.session.pinnedAt = agentSessions[index].pinnedAt
        }
        AgentSessionStore.saveAsync(agentSessions[index])
        upsertAgentUsageSnapshot(for: agentSessions[index])
    }

    /// Toggle archive state. Archived sessions disappear from the main
    /// workspace list and instead live under a collapsed "已归档" row
    /// at the bottom of each workspace group. Unarchiving puts them
    /// back into the active set with their original `updatedAt` intact
    /// so they sort back into their natural recency position.
    func toggleAgentSessionArchived(id: AgentSession.ID) {
        _ = materializeAgentSessionIfNeeded(id: id)
        guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
        let willArchive = agentSessions[index].archivedAt == nil
        agentSessions[index].archivedAt = willArchive ? Date() : nil
        // Mirror onto the live runtime's session copy (rename already
        // does) — otherwise the runtime's next persist() writes its own
        // stale copy back and silently un-archives the row.
        if let runtime = agentRuntimes[id] {
            runtime.session.archivedAt = agentSessions[index].archivedAt
        }
        // Archiving the currently-active session shouldn't kick the
        // user out — the chat stays selected. They can pick another
        // session whenever they want; in the meantime the row simply
        // vanishes from the visible list, which is exactly what every
        // other chat app (Cursor, Slack, Linear) does.
        AgentSessionStore.saveAsync(agentSessions[index])
        upsertAgentUsageSnapshot(for: agentSessions[index])
    }

    /// Rename a session to a user-provided title. Sets `titleIsUserSet`
    /// so neither the per-persist deriveTitle nor the LLM summarizer
    /// will overwrite it later. Empty/whitespace-only input is treated
    /// as "cancel" (no-op) — clearing a session title to "" would just
    /// confuse the sidebar.
    func renameAgentSession(id: AgentSession.ID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = materializeAgentSessionIfNeeded(id: id)
        guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
        agentSessions[index].title = trimmed
        agentSessions[index].titleIsUserSet = true
        if let runtime = agentRuntimes[id] {
            runtime.session.title = trimmed
            runtime.session.titleIsUserSet = true
        }
        // Async: rename must not stall the main thread behind a backlog
        // of large session writes (the caller discards the result anyway).
        AgentSessionStore.saveAsync(agentSessions[index])
        upsertAgentUsageSnapshot(for: agentSessions[index])
    }

    /// Manually request an LLM title summary for a session. Bypasses
    /// the "only on first assistant turn" gate so the user can refresh
    /// the title at any point. Clears `titleIsUserSet` so the
    /// summarizer is allowed to run, then defers to the shared
    /// summarizer path; the summarizer itself re-sets the flag on
    /// success.
    func manuallySummarizeAgentSessionTitle(id: AgentSession.ID) {
        guard let runtime = agentRuntimes[id] else { return }
        // Temporarily unlock so the summarizer doesn't bail at rule (1).
        runtime.session.titleIsUserSet = false
        if let index = agentSessions.firstIndex(where: { $0.id == id }) {
            agentSessions[index].titleIsUserSet = false
        }
        summarizeAgentSessionTitleIfNeeded(runtime: runtime, force: true)
    }

    /// Write the active session back to disk. No-op if no session is
    /// active (Editor-mode chats aren't persisted). Convenience wrapper
    /// that targets `activeRuntime`; concurrent code paths that need to
    /// persist a specific (potentially background) runtime should call
    /// `persistAgentSession(runtime:)` directly.
    func persistActiveAgentSession() {
        guard let runtime = activeRuntime else { return }
        persistAgentSession(runtime: runtime)
    }

    /// Persist a specific runtime's session. Used by the turn loop's
    /// defer so background runtimes that finish while the user is on a
    /// different session still write their final state to disk.
    func persistAgentSession(runtime: AgentRuntime) {
        guard let index = agentSessions.firstIndex(where: { $0.id == runtime.id }) else { return }
        if runtime.managedRouting != nil {
            // Managed routing resolves a model per-turn; there is no single
            // session model. Keep modelID clear so nothing downstream mistakes
            // a route-default snapshot for an explicit user choice.
            runtime.session.modelID = nil
        } else if let override = runtime.sessionModelOverride, !override.isEmpty {
            runtime.session.modelID = override
        } else if runtime.id == activeAgentSessionID {
            runtime.session.modelID = agentConfiguration.normalized.model(for: .interactive)
        } else if runtime.session.modelID == nil {
            runtime.session.modelID = agentConfiguration.normalized.model(for: .interactive)
        }
        let activeProvider = agentProviderLibrary.active
        runtime.session.providerID = activeProvider?.providerID ?? agentConfiguration.normalized.providerID
        runtime.session.providerDisplayName = activeProvider?.displayName
            ?? AgentProviderPreset.preset(id: runtime.session.providerID ?? "")?.displayName
        runtime.persist()
        agentSessions[index] = runtime.session
        // `persist()` just stamped `updatedAt = now`, so this session is
        // the newest — a single move-to-front keeps the list sorted.
        // The previous full `sort` here ran on EVERY persist (several
        // times per turn, for every concurrent runtime), re-comparing
        // hundreds of already-ordered sessions each time; and because
        // `agentSessions` is @Published, the wholesale reorder also
        // invalidated the sidebar more than needed.
        if index > 0 {
            let updated = agentSessions.remove(at: index)
            agentSessions.insert(updated, at: 0)
        }
        upsertAgentUsageSnapshot(for: runtime.session)

        // After every persist, give the LLM summarizer a chance to
        // upgrade the auto-derived first-message-prefix title to a
        // polished one. The method is no-op-cheap on hot paths
        // (returns immediately when there's no first user→assistant
        // exchange yet, or the title is already locked, or a request
        // is in flight), so it's safe to fire unconditionally here.
        summarizeAgentSessionTitleIfNeeded(runtime: runtime)
    }

    func recordFetchedAgentModels(_ ids: [String]) {
        let merged = Array(Set(agentKnownModelIDs + ids))
            .filter { !$0.isEmpty }
            .sorted()
        agentKnownModelIDs = merged
        AgentSettingsStore.saveKnownModelIDs(merged)
    }

    func recordFetchedAgentModelDiscoveries(_ models: [AgentModelDiscovery]) {
        recordFetchedAgentModels(models.map(\.id))
        agentDiscoveredModelMetadata = models
        AgentSettingsStore.saveDiscoveredModelMetadata(models)
    }

    func recordRecentlyUsedAgentModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let withoutExisting = agentRecentlyUsedModelIDs.filter {
            $0.caseInsensitiveCompare(trimmed) != .orderedSame
        }
        let updated = [trimmed] + withoutExisting
        agentRecentlyUsedModelIDs = Array(updated.prefix(24))
        AgentSettingsStore.saveRecentlyUsedModelIDs(agentRecentlyUsedModelIDs)
    }

    func setAgentSessionModel(_ model: String?) {
        // Picking any explicit model (or route-default) exits managed
        // routing — the three session-selection states (route default /
        // explicit model / managed) are mutually exclusive.
        activeRuntime?.managedRouting = nil
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            if agentModelIsCompatibleWithActiveProvider(trimmed) {
                agentSessionModelOverride = trimmed
                recordFetchedAgentModels([trimmed])
                recordRecentlyUsedAgentModel(trimmed)
            } else {
                agentSessionModelOverride = nil
            }
        } else {
            agentSessionModelOverride = nil
        }
        persistActiveAgentSession()
    }

    func agentModelIsCompatibleWithActiveProvider(_ model: String) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let active = agentProviderLibrary.active,
              let preset = AgentProviderPreset.preset(id: active.providerID),
              preset.id != AgentProviderPreset.customID else {
            return true
        }
        return preset.recognizesModelID(trimmed)
    }

    private func clearIncompatibleAgentSessionModelOverride() {
        guard let override = agentSessionModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
              !override.isEmpty,
              !agentModelIsCompatibleWithActiveProvider(override) else {
            return
        }
        agentSessionModelOverride = nil
        persistActiveAgentSession()
    }

    /// Chat-mode picker entry point — pick a (library entry, model)
    /// pair in one shot. When `entryID` differs from the current
    /// active, activates that entry first (rebuilds configuration),
    /// then sets the session override to `model`. Picking a model
    /// that already matches the route default clears the override so
    /// the chip falls back to displaying the routed name.
    func selectAgentEntryAndModel(entryID: UUID, model: String) {
        // Activate the target library entry — this rebuilds
        // agentConfiguration's provider / base URL / key / primaries.
        if agentProviderLibrary.activeID != entryID {
            setActiveProviderLibraryEntry(id: entryID)
        }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setAgentSessionModel(nil)
            return
        }
        // If the chosen model is already what the route would pick by
        // default, clear the override so the picker shows the natural
        // "Use route default" state instead of a redundant lock.
        let routed = agentConfiguration.normalized.model(for: .interactive)
        if trimmed == routed {
            recordRecentlyUsedAgentModel(trimmed)
            setAgentSessionModel(nil)
        } else {
            setAgentSessionModel(trimmed)
        }
    }

    // MARK: - some.im managed routing ("省心托管") selection

    /// Composer entry point for "省心托管". Only valid when the active
    /// provider is some.im. Sets a fresh `.low` managed-routing floor and
    /// clears any explicit model override so the three session-selection
    /// states stay mutually exclusive.
    func selectSomeIMManagedRouting() {
        guard let runtime = activeRuntime else { return }
        guard agentProviderLibrary.active?.providerID == AgentProviderPreset.someIMID else { return }
        runtime.sessionModelOverride = nil
        if runtime.managedRouting == nil {
            runtime.managedRouting = AgentManagedRoutingState()
        }
        persistActiveAgentSession()
    }

    /// User tapped "重置托管档位" — drop the only-goes-up floor back to `.low`.
    func resetManagedRoutingFloor() {
        guard let runtime = activeRuntime else { return }
        runtime.resetManagedFloor()
        persistActiveAgentSession()
    }
}
