//
//  AppStateAgentSessions.swift
//  WillDeep
//
//  Extracted from AppState.swift in v1.52.1-rc42 (stage-3 code-health
//  pass). Houses the Agent-mode session lifecycle, routines, plan and
//  goal management, composer attachments, and provider-library switch:
//
//    - sendAgentMessage entry point + composer attached prompt /
//      readAttachedFileBody / workspaceOverviewBlock helpers
//    - attach/detach skill, file, workspace overview
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

    func sendAgentMessage() {
        // The UI's send button always targets whatever session is on
        // screen — that's the active runtime by definition. If there
        // isn't one, lazily create one so a brand-new install can fire
        // off its first message without manually picking ⌘N first.
        guard let runtime = activeRuntime ?? activeRuntimeAfterCreatingNewSession() else { return }

        let userText = runtime.input.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = runtime.pendingImages
        let textAttachments = runtime.pendingTextAttachments
        let skills = runtime.pendingSkills
        let files = runtime.pendingFiles
        let includeWorkspaceOverview = runtime.pendingIncludeWorkspaceOverview
        guard !userText.isEmpty
                || !images.isEmpty
                || !textAttachments.isEmpty
                || !skills.isEmpty
                || !files.isEmpty
                || includeWorkspaceOverview else { return }

        // Splice attached context (skills / files / workspace overview) in
        // front of the user's prose under labelled headers so the model
        // treats them as task setup rather than verbatim user text.
        let prompt = composeAttachedPrompt(
            userText: userText,
            skills: skills,
            files: files,
            includeWorkspaceOverview: includeWorkspaceOverview
        )

        runtime.input = ""
        runtime.pendingImages = []
        runtime.pendingTextAttachments = []
        runtime.pendingSkills = []
        runtime.pendingFiles = []
        runtime.pendingIncludeWorkspaceOverview = false

        if runtime.isResponding {
            runtime.queuedMessages.append(
                AgentQueuedMessage(text: prompt, images: images, textAttachments: textAttachments)
            )
            return
        }

        dispatchAgentMessage(for: runtime, text: prompt, images: images, textAttachments: textAttachments)
    }

    /// Fallback used by `sendAgentMessage` when the user typed into the
    /// composer before ever opening a session. Starts a new one so
    /// their message has somewhere to go.
    func activeRuntimeAfterCreatingNewSession() -> AgentRuntime? {
        _ = startNewAgentSession()
        return activeRuntime
    }

    /// Build the outgoing prompt, prepending sections for attached
    /// skills, file contents (re-read from disk so the model sees the
    /// latest), and an optional workspace overview. Returns the user
    /// text unchanged when nothing is attached.
    func composeAttachedPrompt(
        userText: String,
        skills: [AgentSkillEntry],
        files: [AgentFileAttachment],
        includeWorkspaceOverview: Bool
    ) -> String {
        guard !skills.isEmpty || !files.isEmpty || includeWorkspaceOverview else { return userText }
        var blocks: [String] = []
        blocks.append("The user attached the following context for this turn — treat it as task setup, not verbatim user text:")

        if includeWorkspaceOverview {
            blocks.append(workspaceOverviewBlock())
        }

        for skill in skills {
            let body = AgentSkillDirectory.loadBody(for: skill) ?? "(skill body unavailable)"
            blocks.append("""
            ### Skill: \(skill.identifier)
            > \(skill.description)

            \(body)
            """)
        }

        for file in files {
            let body = readAttachedFileBody(at: file.url)
            blocks.append("""
            ### File: \(file.relativePath)

            \(body)
            """)
        }

        if !userText.isEmpty {
            blocks.append("---")
            blocks.append(userText)
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Fenced excerpt of a file's contents, capped to keep one
    /// attachment from blowing the context budget. Falls back to a
    /// short placeholder when the file is unreadable or binary.
    func readAttachedFileBody(at url: URL) -> String {
        let maxChars = 20_000
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return "```\n(file unreadable or binary)\n```"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if trimmed.count > maxChars {
            let idx = trimmed.index(trimmed.startIndex, offsetBy: maxChars)
            body = "\(trimmed[..<idx])\n\n[truncated at \(maxChars) chars]"
        } else {
            body = trimmed
        }
        return "```\n\(body)\n```"
    }

    /// A compact workspace overview: root path + a flat list of project
    /// files (already cached via `quickOpenFiles`). Capped so even a
    /// large repo overview stays reasonable.
    func workspaceOverviewBlock() -> String {
        guard let root = rootDirectory else {
            return "### Workspace\n(no folder is currently open)"
        }
        let rootPath = root.standardizedFileURL.path
        let entries = quickOpenFiles
            .prefix(120)
            .map { url -> String in
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
                let rel = String(path.dropFirst(rootPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return rel.isEmpty ? url.lastPathComponent : rel
            }
        let extraCount = max(0, quickOpenFiles.count - 120)
        let extraLine = extraCount > 0 ? "\n…and \(extraCount) more files" : ""
        return """
        ### Workspace
        Root: \(rootPath)
        Files (first \(entries.count)):
        ```
        \(entries.joined(separator: "\n"))\(extraLine)
        ```
        """
    }

    // MARK: - Skill attachment

    /// Stage a skill for the next send. Idempotent — re-attaching the
    /// same skill is a no-op.
    func attachAgentSkill(_ skill: AgentSkillEntry) {
        guard !agentPendingSkills.contains(where: { $0.identifier == skill.identifier }) else { return }
        agentPendingSkills.append(skill)
    }

    /// Drop a single staged skill by identifier.
    func detachAgentSkill(identifier: String) {
        agentPendingSkills.removeAll { $0.identifier == identifier }
    }

    // MARK: - File / workspace attachment

    /// Stage a workspace file for the next send. Dedup by URL.
    func attachAgentFile(url: URL) {
        let standardized = url.standardizedFileURL
        guard !agentPendingFiles.contains(where: { $0.url.standardizedFileURL == standardized }) else { return }
        let relative: String = {
            guard let root = rootDirectory?.standardizedFileURL.path else { return standardized.lastPathComponent }
            let path = standardized.path
            guard path.hasPrefix(root) else { return standardized.lastPathComponent }
            let rel = String(path.dropFirst(root.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return rel.isEmpty ? standardized.lastPathComponent : rel
        }()
        agentPendingFiles.append(AgentFileAttachment(url: standardized, relativePath: relative))
    }

    /// Drop a single staged file by id (which is its standardized path).
    func detachAgentFile(id: String) {
        agentPendingFiles.removeAll { $0.id == id }
    }

    // MARK: - Pasted text attachment

    func addAgentTextAttachment(content rawContent: String) {
        let content = AgentTextAttachment.sanitizedPastedContent(rawContent)
        guard !content.isEmpty else { return }
        agentPendingTextAttachments.append(
            AgentTextAttachment(filename: L10n.AgentTextAttachment.pastedFilename, content: content)
        )
    }

    func removeAgentTextAttachment(id: AgentTextAttachment.ID) {
        agentPendingTextAttachments.removeAll { $0.id == id }
    }

    /// Toggle whether the workspace overview rides along next send.
    func toggleAgentWorkspaceOverview() {
        agentPendingIncludeWorkspaceOverview.toggle()
    }

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
        agentProviderLibrary.setActive(id)
        applyActiveProviderLibraryEntry()
    }

    /// Add or update a library entry. If the entry is the active one,
    /// the live configuration is refreshed too.
    func upsertProviderLibraryEntry(_ entry: AgentProviderEntry) {
        agentProviderLibrary.upsert(entry)
        if agentProviderLibrary.activeID == entry.id {
            applyActiveProviderLibraryEntry()
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

    func captureAgentGoalEvaluationFromLatestMessage(for runtime: AgentRuntime) {
        guard runtime.interactionMode == .goal,
              let goal = runtime.currentGoal,
              !goal.checklist.isEmpty else { return }
        guard let last = runtime.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }) else { return }
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
        let trimmedStatement = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedItems = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if trimmedStatement.isEmpty && trimmedItems.isEmpty {
            agentCurrentGoal = nil
            persistActiveAgentSession()
            return
        }
        let priorDone: [String: Bool] = Dictionary(uniqueKeysWithValues:
            (agentCurrentGoal?.checklist ?? []).map { ($0.text, $0.done) })
        agentCurrentGoal = AgentGoal(
            statement: trimmedStatement,
            checklist: trimmedItems.map { text in
                AgentGoal.Item(text: text, done: priorDone[text] ?? false)
            }
        )
        persistActiveAgentSession()
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
        guard isAgentResponding else { return }
        agentToolDecisionWaiter?.resume(returning: .denied(reason: "Response stopped"))
        agentToolDecisionWaiter = nil
        agentRequestTask?.cancel()
        // The loop's defer clears `isAgentResponding` and triggers
        // `consumeNextQueuedMessageIfNeeded()`.
    }

    func clearAgentQueue() {
        agentQueuedMessages.removeAll()
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
            stopAgentResponse()
        } else {
            consumeNextQueuedMessageIfNeeded(for: runtime)
        }
    }

    func addAgentImage(data: Data, mimeType: String) {
        let attachment = AgentImageAttachment(mimeType: mimeType, dataBase64: data.base64EncodedString())
        agentPendingImages.append(attachment)
    }

    func removeAgentImage(id: AgentImageAttachment.ID) {
        agentPendingImages.removeAll { $0.id == id }
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
        // These now go to the freshly-built runtime via delegation.
        agentSessionDidEditFiles = false
        agentInteractionMode = .normal
        agentCurrentPlan = nil
        agentCurrentGoal = nil
        AgentSessionStore.save(session)
        return session
    }

    /// Start a new session that belongs to a specific workspace, switching
    /// the current window's `rootDirectory` to that workspace first so the
    /// Agent's tool context matches the session's group. Used by the
    /// sidebar workspace-row context menu. Pass `nil` for the "no
    /// workspace" group — the new session is created with no root.
    @discardableResult
    func startNewAgentSession(inWorkspaceAt workspacePath: String?) -> AgentSession {
        if let workspacePath, !workspacePath.isEmpty {
            let url = URL(fileURLWithPath: workspacePath)
            // Only switch root if the target really is an existing
            // directory — a stale persisted path shouldn't break anything.
            if Self.isExistingDirectory(url),
               rootDirectory?.standardizedFileURL.path != url.standardizedFileURL.path {
                openFolderURL(url)
            }
        }
        return startNewAgentSession()
    }

    /// Bind the current composer/session to a selected workspace. Empty
    /// placeholder sessions are migrated in place; sessions with real
    /// history get a fresh chat so old tool context is never silently
    /// rewritten to a different folder.
    @discardableResult
    func moveActiveAgentSessionToWorkspace(at workspacePath: String) -> AgentSession {
        let url = URL(fileURLWithPath: workspacePath).standardizedFileURL
        if Self.isExistingDirectory(url),
           rootDirectory?.standardizedFileURL.path != url.path {
            openFolderURL(url)
        }

        if let runtime = activeRuntime, runtime.isEmpty, !runtime.isResponding {
            pruneEmptyAgentSessions(excluding: runtime.id)
            runtime.rebindWorkspace(to: url.path)
            runtime.worktreeChanges = .init()
            persistAgentSession(runtime: runtime)
            return runtime.session
        }

        return startNewAgentSession(inWorkspaceAt: url.path)
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
        _ = runtime(for: id)
        activeAgentSessionID = id
        subscribeToActiveRuntime()

        // Re-derive the session model override from the persisted
        // session record. The runtime carries it across the lifetime
        // of one launch, but a freshly-built runtime started from a
        // disk session needs this seeded.
        if let runtime = activeRuntime {
            let session = runtime.session
            let routedModel = agentConfiguration.normalized.model(for: .interactive)
            runtime.sessionModelOverride = session.modelID == routedModel ? nil : session.modelID
        }
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
        // Tear down any runtimes left for the pruned sessions, lest
        // they keep republishing change events into AppState and
        // hold onto in-flight tasks for sessions that no longer exist.
        for id in removedIDs {
            if let runtime = agentRuntimes[id] {
                runtime.requestTask?.cancel()
                runtime.toolDecisionWaiter?.resume(returning: .denied(reason: "Empty session pruned"))
                runtime.toolDecisionWaiter = nil
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
        guard let session = agentSessions.first(where: { $0.id == sessionID }) else { return nil }
        let runtime = AgentRuntime(session: session)
        agentRuntimes[sessionID] = runtime
        return runtime
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
        }
        // Orphaned background subagents must not keep burning tokens
        // for a session that no longer exists.
        agentSubagentRegistry.cancelAll(forParentRuntime: id)
        // Drop any not-yet-started dispatches queued for this session
        // so they don't fire after the session is gone.
        pendingDispatchQueue.removeAll { $0.runtimeID == id }

        AgentSessionStore.delete(id: id)
        agentSessions.removeAll { $0.id == id }
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
    func runAgentRoutineNow(id: AgentRoutine.ID) {
        _ = fireRoutine(id: id, force: true)
    }

    /// Scheduler entry point. Returns true if the routine actually
    /// started a session; false if the routine was empty / missing
    /// (the scheduler will retry next tick if appropriate).
    ///
    /// Concurrency model (rc3+): routines spawn a background runtime
    /// rather than yanking the user's UI. They do NOT change
    /// `activeAgentSessionID` and do NOT flip `appMode`. The user
    /// keeps working in whatever session they had on screen; the
    /// routine's session shows up in the sidebar (with a "busy" dot
    /// once rc4 lands) and they can click into it later to inspect.
    @discardableResult
    func fireRoutine(id: AgentRoutine.ID, force: Bool = false) -> Bool {
        _ = force // The per-provider concurrency cap replaces the old
                  // "is anyone responding?" gate; manual "Run now"
                  // doesn't need to bypass anything different.

        guard let index = agentRoutines.firstIndex(where: { $0.id == id }) else { return false }
        let routine = agentRoutines[index]
        let prompt = routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return false }

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

        // dispatchAgentMessage handles the per-provider concurrency
        // cap — if the cap is hit, the dispatch queues and drains
        // FIFO as slots free. So even a fleet of 10 routines hitting
        // the same provider all at 09:00 won't stomp on each other.
        dispatchAgentMessage(for: runtime, text: prompt, images: [])

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
        return true
    }

    /// Toggle pin state. Pinned sessions float to the top of their
    /// workspace group, sorted by `pinnedAt` (most recently pinned
    /// first). The timestamp doubles as both the on/off flag and the
    /// within-pinned ordering key, so re-pinning sends the row back to
    /// the top of the pinned block.
    func toggleAgentSessionPinned(id: AgentSession.ID) {
        guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
        agentSessions[index].pinnedAt = agentSessions[index].pinnedAt == nil ? Date() : nil
        _ = AgentSessionStore.save(agentSessions[index])
    }

    /// Toggle archive state. Archived sessions disappear from the main
    /// workspace list and instead live under a collapsed "已归档" row
    /// at the bottom of each workspace group. Unarchiving puts them
    /// back into the active set with their original `updatedAt` intact
    /// so they sort back into their natural recency position.
    func toggleAgentSessionArchived(id: AgentSession.ID) {
        guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
        let willArchive = agentSessions[index].archivedAt == nil
        agentSessions[index].archivedAt = willArchive ? Date() : nil
        // Archiving the currently-active session shouldn't kick the
        // user out — the chat stays selected. They can pick another
        // session whenever they want; in the meantime the row simply
        // vanishes from the visible list, which is exactly what every
        // other chat app (Cursor, Slack, Linear) does.
        _ = AgentSessionStore.save(agentSessions[index])
    }

    /// Rename a session to a user-provided title. Sets `titleIsUserSet`
    /// so neither the per-persist deriveTitle nor the LLM summarizer
    /// will overwrite it later. Empty/whitespace-only input is treated
    /// as "cancel" (no-op) — clearing a session title to "" would just
    /// confuse the sidebar.
    func renameAgentSession(id: AgentSession.ID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = agentSessions.firstIndex(where: { $0.id == id }) else { return }
        agentSessions[index].title = trimmed
        agentSessions[index].titleIsUserSet = true
        if let runtime = agentRuntimes[id] {
            runtime.session.title = trimmed
            runtime.session.titleIsUserSet = true
        }
        _ = AgentSessionStore.save(agentSessions[index])
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
        if let override = runtime.sessionModelOverride, !override.isEmpty {
            runtime.session.modelID = override
        } else if runtime.id == activeAgentSessionID {
            runtime.session.modelID = agentConfiguration.normalized.model(for: .interactive)
        } else if runtime.session.modelID == nil {
            runtime.session.modelID = agentConfiguration.normalized.model(for: .interactive)
        }
        runtime.persist()
        agentSessions[index] = runtime.session
        agentSessions.sort { $0.updatedAt > $1.updatedAt }

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

    func setAgentSessionModel(_ model: String?) {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            if agentModelIsCompatibleWithActiveProvider(trimmed) {
                agentSessionModelOverride = trimmed
                recordFetchedAgentModels([trimmed])
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
            setAgentSessionModel(nil)
        } else {
            setAgentSessionModel(trimmed)
        }
    }
}
