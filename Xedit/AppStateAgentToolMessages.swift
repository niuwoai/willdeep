//
//  AppStateAgentToolMessages.swift
//  WillDeep
//
//  Subagent tool execution and tool-message persistence helpers extracted
//  from AppStateAgentLoop.swift so the streaming loop stays below the
//  repository's hard file-size limit.
//

import Foundation
import OSLog

private let agentSpawnLog = Logger(subsystem: "com.willdeep.agent", category: "spawn-agent")

extension AppState {
    func denyPlanProgressReconciliationToolCall(
        _ call: AgentMessageToolCall,
        messageID: UUID,
        arguments: [String: AgentJSONValue],
        risk: AgentToolRisk,
        runtime: AgentRuntime
    ) {
        let errorMessage = "Unavailable during Plan status reconciliation"
        let record = AgentToolCall(
            messageID: messageID,
            externalID: call.externalID,
            toolName: call.toolName,
            arguments: arguments,
            risk: risk,
            status: .denied,
            errorMessage: errorMessage
        )
        runtime.toolCalls.append(record)
        appendToolMessage(
            for: runtime,
            toolCallID: call.externalID,
            payload: "Blocked: Plan status reconciliation permits only read-only inspection. Use existing evidence or read-only status tools, then emit the required progress block without repeating execution.",
            source: .systemNotice,
            outcomeStatus: .denied,
            errorMessage: errorMessage
        )
    }

    /// Record whether a `/subagent` turn actually delegated.
    ///
    /// `.required` cannot be enforced in code (see `AgentDelegationPolicy`),
    /// so instead of silently pretending the directive held, the turn's user
    /// message keeps an honest verdict that the transcript marker renders.
    /// `.forbidden` needs no audit — the tool table already guaranteed it.
    func auditDelegationPolicyForFinishedTurn(in runtime: AgentRuntime) {
        let policy = runtime.currentTurnDelegationPolicy
        runtime.currentTurnDelegationPolicy = .automatic
        guard policy == .required else { return }
        guard let index = runtime.messages.lastIndex(where: {
            $0.role == .user && $0.delegationPolicy == .required
        }) else { return }

        let unhonored = !policy.isHonored(spawnCallCount: runtime.currentTurnSpawnAgentCallCount)
        guard runtime.messages[index].delegationPolicyUnhonored != unhonored else { return }
        runtime.messages[index].delegationPolicyUnhonored = unhonored
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
    }

    /// Execute one `spawn_agent` tool call: synchronous runs await the
    /// child loop and return its report inline; background runs return
    /// a handle and deliver via `subagentReportNotice` on a later round.
    func executeSpawnAgentToolCall(
        _ call: AgentMessageToolCall,
        recordID: AgentToolCall.ID,
        arguments: [String: AgentJSONValue],
        runtime: AgentRuntime,
        configuration: AgentConfiguration,
        workspaceURL: URL?,
        runtimeDescriptor: RuntimeDescriptor?,
        workspaceLocation: WorkspaceLocation?
    ) async {
        // Counted before any validation: a `/subagent` turn that tried to
        // delegate and failed still honored the directive.
        runtime.currentTurnSpawnAgentCallCount += 1

        func finishRecord(status: AgentToolCallStatus, summary: String, payload: String, errorMessage: String? = nil) {
            if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                runtime.toolCalls[index].status = status
                runtime.toolCalls[index].errorMessage = errorMessage
                runtime.toolCalls[index].subagentProgress = nil
                if status == .succeeded {
                    runtime.toolCalls[index].result = AgentToolResult(summary: summary, payload: payload)
                }
            }
            appendToolMessage(
                for: runtime,
                toolCallID: call.externalID,
                payload: payload,
                source: status == .succeeded ? .toolOutput : .systemNotice,
                outcomeStatus: status,
                errorMessage: errorMessage
            )
        }

        // Stamp the child's effective model + a live progress line onto the
        // tool-call record so the card can show "用的哪个子代理 · 进度到哪了"
        // instead of an opaque spinner. Both fields are render-only.
        func updateSubagent(
            model: String? = nil,
            workerName: String? = nil,
            progress: String? = nil
        ) {
            guard let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) else { return }
            if let model { runtime.toolCalls[index].subagentModel = model }
            if let workerName { runtime.toolCalls[index].subagentWorkerName = workerName }
            if let progress { runtime.toolCalls[index].subagentProgress = progress }
        }

        // Bind the run to both the live card and the persisted assistant
        // message: the former drives the inspector button this session, the
        // latter is what survives a reopen.
        func bindSubagentRun(_ runID: UUID) {
            if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
                runtime.toolCalls[index].subagentRunID = runID
            }
            bindSubagentRunToPersistedToolCall(
                runID: runID,
                externalID: call.externalID,
                runtime: runtime
            )
        }

        var prompt = arguments["prompt"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else {
            agentSpawnLog.error(
                "spawn_agent rejected reason=missing_prompt runtime=\(runtime.id.uuidString, privacy: .public) call=\(call.externalID, privacy: .public)"
            )
            finishRecord(
                status: .failed,
                summary: "missing prompt",
                payload: "Tool error: \(AgentSubagentError.missingPrompt.localizedDescription)",
                errorMessage: AgentSubagentError.missingPrompt.localizedDescription
            )
            return
        }

        let label: String = {
            if let raw = arguments["label"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                return String(raw.prefix(60))
            }
            return String(prompt.prefix(40))
        }()
        let runInBackground = arguments["run_in_background"]?.boolValue() ?? false
        agentSpawnLog.info(
            "spawn_agent received runtime=\(runtime.id.uuidString, privacy: .public) turn=\(runtime.activeTurnID?.uuidString ?? "none", privacy: .public) call=\(call.externalID, privacy: .public) label=\(label, privacy: .public) requestedProfile=\(arguments["profile"]?.stringValue() ?? "default", privacy: .public) background=\(runInBackground ? "true" : "false", privacy: .public) promptChars=\(prompt.count, privacy: .public)"
        )

        // Which trade to run. An absent profile still means `deep`, which is
        // what every pre-profile caller expects.
        let requestedProfileID = arguments["profile"]?.stringValue()
        var profile = AgentSubagentProfileStore.resolvedProfile(id: requestedProfileID)
        var profileNotices: [String] = []
        // Validity is decided against the *resolved* trades, not the built-in
        // catalog: since agent-profile.v2 a user-created profile is a real
        // trade, and checking the catalog would report it as unknown while
        // happily running it.
        let availableTradeIDs = AgentSubagentProfileStore.resolvedProfiles().map(\.id)
        let compatibleTradeIDs = AgentSubagentProfileStore.allResolvedProfiles().map(\.id)
        if let requestedProfileID,
           !requestedProfileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !compatibleTradeIDs.contains(where: {
               $0.caseInsensitiveCompare(requestedProfileID.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
           }) {
            // A typo used to be a free upgrade: unknown names fell through to
            // `deep`, so `profile="scoutt"` quietly bought the 1M tier while
            // reporting a note nobody acts on. Refuse instead — the retry
            // costs one round and lands on the trade that was meant.
            let message = "Unknown profile `\(requestedProfileID)`. Valid trades: \(availableTradeIDs.joined(separator: ", ")). Pick one and call spawn_agent again — this was not run as `deep`."
            agentSpawnLog.error(
                "spawn_agent rejected reason=unknown_profile runtime=\(runtime.id.uuidString, privacy: .public) call=\(call.externalID, privacy: .public) requestedProfile=\(requestedProfileID, privacy: .public)"
            )
            finishRecord(
                status: .failed,
                summary: "unknown profile",
                payload: "Tool error: \(message)",
                errorMessage: message
            )
            return
        }

        // Admission for the scarce 1M tier. Checked before write-scope and
        // runtime setup so a refused escalation costs nothing and does not
        // perform unnecessary worker setup.
        if profile.id == AgentSubagentProfileCatalog.deepID {
            let ticket = AgentDeepAdmissionTicket.parse(arguments["escalation"])
            switch AgentDeepAdmission.authorize(
                ticket: ticket,
                observation: runtime.deepAdmissionObservation,
                budget: AgentSettingsStore.loadDeepAdmissionBudget()
            ) {
            case .success(let updated):
                runtime.deepAdmissionObservation = updated
            case .failure(let refusal):
                agentSpawnLog.error(
                    "spawn_agent rejected reason=deep_refused runtime=\(runtime.id.uuidString, privacy: .public) call=\(call.externalID, privacy: .public) profile=\(profile.id, privacy: .public) refusal=\(refusal.modelFacingMessage, privacy: .private)"
                )
                finishRecord(
                    status: .failed,
                    summary: "deep escalation refused",
                    payload: "Tool error: \(refusal.modelFacingMessage)",
                    errorMessage: refusal.modelFacingMessage
                )
                return
            }
        }

        // A goal-team role binds a trade and may only narrow it further
        // (docs/GOAL_TEAMS_ROLES_DESIGN.md §2.3). Roles live in the
        // workspace's roles file, so an unknown role degrades to the plain
        // trade rather than failing the spawn.
        if let requestedRoleID = arguments["role"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedRoleID.isEmpty {
            let workspacePath = activeRuntime?.workspaceRootPath
            let roster = AgentGoalTeamRoleStore.load(workspacePath: workspacePath)
            if let role = roster.role(id: requestedRoleID),
               let roleTrade = role.resolvedTrade(
                   profiles: AgentProfileStore().profiles(),
                   profileID: requestedProfileID
               ) {
                profile = roleTrade
                // Cross-milestone memory (goal-teams §4.3): the flaky tests
                // and environment traps the previous milestone's holder of
                // this role wrote down. Memory lives in a file precisely so a
                // fresh child context can still have it.
                if let roleMemory = AgentGoalTeamArchive.memoryText(
                    for: role,
                    workspacePath: workspacePath
                ) {
                    prompt += """


                    Notes carried over from earlier milestones in this role (read before starting):
                    \(roleMemory)
                    """
                }
            } else {
                profileNotices.append(
                    "Note: unknown role `\(requestedRoleID)` — ran the `\(profile.id)` trade without role narrowing. Roles in this workspace: \(roster.roles.map(\.id).joined(separator: ", "))."
                )
            }
        }
        // The `model` parameter is retired: cost policy is the user's
        // configuration now, not something the model re-decides per call.
        // Ignored rather than rejected so older prompts keep working.
        if let staleModel = arguments["model"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !staleModel.isEmpty {
            profileNotices.append(
                "Note: the `model` parameter is no longer supported and was ignored. Choose a `profile` instead — each trade carries its own model binding."
            )
        }

        // Parse the packet before the write scope: implementer/fixer trades
        // may declare their write set as `task.write_files` (the same field
        // the Rust runtime uses), with `task.relevant_files` still honored for
        // older packets. An explicit `target_files` remains authoritative for
        // parents that want a narrower write set than the read context.
        let taskPacket = AgentSubagentTaskPacket.parse(arguments["task"])

        // Writing trades need a bounded, locked target set before anything
        // runs. Smart / Workspace Access inherit the parent workspace grant;
        // Strict still gates the whole spawn. Every path stays enforced here.
        var writeAccess: AgentSubagentWriteAccess?
        if profile.requiresWriteAccess {
            var rawTargets: [String] = []
            if case .array(let values)? = arguments["target_files"] {
                rawTargets = values.compactMap { $0.stringValue() }
            } else if let single = arguments["target_file"]?.stringValue() {
                rawTargets = [single]
            } else if profile.id != AgentSubagentProfileCatalog.editorID {
                // `write_files` when the packet declares it, else the legacy
                // combined set. Context in `read_files` never lands here —
                // that is the whole point of the split.
                rawTargets = taskPacket?.requestedWriteFiles ?? []
            }
            guard !rawTargets.isEmpty,
                  let access = AgentSubagentWriteAccess(targetRelativePaths: rawTargets) else {
                agentSpawnLog.error(
                    "spawn_agent rejected reason=missing_write_scope runtime=\(runtime.id.uuidString, privacy: .public) call=\(call.externalID, privacy: .public) profile=\(profile.id, privacy: .public) requestedTargets=\(rawTargets.count, privacy: .public)"
                )
                finishRecord(
                    status: .failed,
                    summary: "missing target files",
                    payload: "Tool error: `profile=\"\(profile.id)\"` requires 1–\(AgentSubagentWriteAccess.maxTargetCount) files it may create or edit: `target_file` (editor), `target_files`, or `task.write_files`. Context-only paths belong in `task.read_files` and do not count. Paths are workspace-relative; absolute paths, `~`, and `..` are rejected.",
                    errorMessage: "Missing target files"
                )
                return
            }
            if profile.id == AgentSubagentProfileCatalog.smallImplementerID,
               access.targetRelativePaths.count > AgentCodingTaskPlan.automaticMaximumWriteCount {
                agentSpawnLog.error(
                    "spawn_agent rejected reason=write_scope_too_broad runtime=\(runtime.id.uuidString, privacy: .public) call=\(call.externalID, privacy: .public) profile=\(profile.id, privacy: .public) targetCount=\(access.targetRelativePaths.count, privacy: .public)"
                )
                finishRecord(
                    status: .failed,
                    summary: "small implementer scope too broad",
                    payload: "Tool error: `profile=\"\(profile.id)\"` may edit at most \(AgentCodingTaskPlan.automaticMaximumWriteCount) declared files. Split the task into bounded packets or use the ordinary implementer profile.",
                    errorMessage: "Small implementer write scope exceeds host limit"
                )
                return
            }
            writeAccess = access
        }

        // 单命令授权（ops_runner 专属）：spawn 审批卡上用户批准的那条确切
        // 命令。传给了别的工种就是路由错误——报回去让父模型改，不静默吞。
        var approvedCommand: String?
        if let targetCommand = arguments["target_command"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !targetCommand.isEmpty {
            guard profile.id == AgentSubagentProfileCatalog.opsRunnerID else {
                agentSpawnLog.error(
                    "spawn_agent rejected reason=target_command_misrouted runtime=\(runtime.id.uuidString, privacy: .public) call=\(call.externalID, privacy: .public) profile=\(profile.id, privacy: .public)"
                )
                finishRecord(
                    status: .failed,
                    summary: "target_command misrouted",
                    payload: "Tool error: `target_command` is only honored for `profile=\"ops_runner\"`. Re-spawn with that profile, or drop the parameter.",
                    errorMessage: "target_command requires ops_runner"
                )
                return
            }
            approvedCommand = targetCommand
        }

        // Crossing this point means the routed trade passed its packet and
        // scope validation. The host's delegate-first guard may now allow the
        // parent to integrate or repair after the bounded worker attempt. An
        // ops inspection alone does not unlock a mutating command: that route
        // must carry the exact approved command.
        if profile.requiresWriteAccess
            || (profile.id == AgentSubagentProfileCatalog.opsRunnerID && approvedCommand != nil) {
            runtime.currentTurnAttemptedWorkerProfiles.insert(profile.id)
        }

        // A task packet lets the worker start hot: the parent already knows
        // which files matter, so their contents ride along instead of costing
        // the worker half its window to rediscover.
        if let taskPacket {
            prompt = await composedTaskPacketPrompt(
                packet: taskPacket,
                fallbackPrompt: prompt,
                workspaceURL: workspaceURL,
                runtimeDescriptor: runtimeDescriptor,
                workspaceLocation: workspaceLocation
            )
        }
        // The verifier runs unattended and repeatedly, so it needs a gate —
        // but "read-only" is the wrong gate. Plenty of honest verifiers write
        // (a build emits objects, a test writes fixtures), and refusing them
        // would push users back to trusting the model's own "it passes".
        // So: read-tier commands go straight through, and anything else is put
        // to the security-guard judge — the same choke point every other
        // unattended command in the app already goes through.
        var verifierCommand = taskPacket?.verifierCommand
        if let candidate = verifierCommand,
           !AgentSubagentRunner.verifierCommandIsReadTier(candidate, workspaceURL: workspaceURL) {
            let verdict = await safetyJudgeApproval(
                toolName: "run_command",
                command: candidate,
                taskContext: taskPacket?.goal ?? ""
            )
            if verdict == nil {
                verifierCommand = nil
                profileNotices.append(
                    "Note: the `verifier.command` `\(candidate)` was not cleared by the security guard, so it did not run. The subagent reported its own result instead, which is weaker evidence — supply a verifier the guard accepts if you need a real verdict."
                )
            }
        }

        let childConfiguration = resolvedSubagentConfiguration(
            for: profile,
            parentConfiguration: configuration
        )
        let resolvedWorkerName = AgentProfileStore()
            .profiles(usage: .subagent)
            .first { $0.id.caseInsensitiveCompare(profile.id) == .orderedSame }?
            .localizedName
            ?? L10n.AgentDelegation.profileName(for: profile.id)
        agentSpawnLog.info(
            "spawn_agent resolved runtime=\(runtime.id.uuidString, privacy: .public) call=\(call.externalID, privacy: .public) profile=\(profile.id, privacy: .public) model=\(childConfiguration.model, privacy: .public) provider=\(childConfiguration.providerID, privacy: .public) background=\(runInBackground ? "true" : "false", privacy: .public) verifier=\(verifierCommand == nil ? "none" : "present", privacy: .public) approvedCommand=\(approvedCommand == nil ? "none" : "present", privacy: .public)"
        )
        updateSubagent(
            model: childConfiguration.model,
            workerName: resolvedWorkerName,
            progress: "启动中…"
        )

        if runInBackground {
            // Editor trades are synchronous by construction: the file lock
            // and the approval are scoped to a turn the user is watching.
            if profile.requiresWriteAccess {
                agentSpawnLog.error(
                    "spawn_agent rejected reason=write_trade_background runtime=\(runtime.id.uuidString, privacy: .public) call=\(call.externalID, privacy: .public) profile=\(profile.id, privacy: .public)"
                )
                finishRecord(
                    status: .failed,
                    summary: "editor cannot run in background",
                    payload: "Tool error: the `editor` trade cannot run in the background — its file lock and approval are scoped to this turn. Re-spawn without `run_in_background`.",
                    errorMessage: "Editor trade requires foreground"
                )
                return
            }
            do {
                let run = try agentSubagentRegistry.startBackground(
                    prompt: prompt,
                    label: label,
                    configuration: childConfiguration,
                    workspaceURL: workspaceURL,
                    runtimeDescriptor: runtimeDescriptor,
                    workspaceLocation: workspaceLocation,
                    parentRuntimeID: runtime.id,
                    originatingTurnID: runtime.activeTurnID,
                    profile: profile
                )
                bindSubagentRun(run.id)
                agentSpawnLog.info(
                    "spawn_agent background started runtime=\(runtime.id.uuidString, privacy: .public) call=\(call.externalID, privacy: .public) run=\(run.id.uuidString, privacy: .public) handle=\(run.displayHandle, privacy: .public) profile=\(profile.id, privacy: .public) model=\(childConfiguration.model, privacy: .public)"
                )
                finishRecord(
                    status: .succeeded,
                    summary: "started \(run.displayHandle)",
                    payload: "Subagent \(run.displayHandle) (\(label)) started in the background on model \(childConfiguration.model). Its report will arrive as a <subagent-report> system message when it finishes — keep working on other things or end your turn; do not poll."
                )
            } catch {
                agentSpawnLog.error(
                    "spawn_agent background failed_to_start runtime=\(runtime.id.uuidString, privacy: .public) call=\(call.externalID, privacy: .public) profile=\(profile.id, privacy: .public) errorType=\(String(describing: type(of: error)), privacy: .public) error=\(error.localizedDescription, privacy: .private)"
                )
                finishRecord(
                    status: .failed,
                    summary: "spawn failed",
                    payload: "Tool error: \(error.localizedDescription)",
                    errorMessage: error.localizedDescription
                )
            }
            return
        }

        // Synchronous runs bypass the registry, so mint the inspector
        // identity here — without it this run would finish with a report and
        // no reviewable record, which is the gap the inspector exists to fix.
        let runID = UUID()
        let startedAt = Date()
        bindSubagentRun(runID)
        agentSpawnLog.info(
            "spawn_agent synchronous started runtime=\(runtime.id.uuidString, privacy: .public) call=\(call.externalID, privacy: .public) run=\(runID.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) model=\(childConfiguration.model, privacy: .public)"
        )

        // One editor per file per session. Two children patching the same
        // file would interleave hunks against a moving base.
        if let writeAccess {
            guard AgentSubagentEditorLock.shared.acquire(
                paths: writeAccess.targetRelativePaths,
                parentRuntimeID: runtime.id,
                runID: runID
            ) else {
                let busy = AgentSubagentEditorLock.shared.conflictingPaths(
                    writeAccess.targetRelativePaths,
                    parentRuntimeID: runtime.id,
                    runID: runID
                )
                let busyList = busy.map { "`\($0)`" }.joined(separator: ", ")
                agentSpawnLog.error(
                    "spawn_agent rejected reason=files_locked runtime=\(runtime.id.uuidString, privacy: .public) call=\(call.externalID, privacy: .public) run=\(runID.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) busyCount=\(busy.count, privacy: .public)"
                )
                finishRecord(
                    status: .failed,
                    summary: "files locked",
                    payload: "Tool error: another subagent is already editing \(busyList). Wait for it to finish, or narrow this spawn to files it does not hold.",
                    errorMessage: "Target files locked"
                )
                return
            }
        }
        defer {
            if writeAccess != nil {
                AgentSubagentEditorLock.shared.release(runID: runID)
            }
        }

        // A lower-tier attempt counts as evidence only once its packet, write
        // set and file locks have all passed. A spawn rejected for an
        // undeclared path never ran, and must not become the thing that
        // unlocks the 1M tier on the next call.
        if profile.id != AgentSubagentProfileCatalog.deepID {
            runtime.deepAdmissionObservation.recordProfileAttempt(profile.id)
        }

        func persist(
            status: AgentSubagentRun.Status,
            outcome: AgentSubagentRunner.Outcome?,
            report: String,
            model: String,
            providerID: String,
            escalatedFrom: String? = nil
        ) {
            // Worker accounting rides every terminal path, including failures
            // and cancellations: tokens a stalled child already burned are
            // exactly the ones a cheap tier must be judged on.
            recordSubagentRunUsage(
                AgentSubagentRunUsage(
                    profileID: profile.id,
                    model: model,
                    providerID: providerID,
                    usageTokens: outcome?.usageTokens ?? 0,
                    promptTokens: outcome?.usageSplit.prompt ?? 0,
                    completionTokens: outcome?.usageSplit.completion ?? 0,
                    cachedPromptTokens: outcome?.usageSplit.cachedPrompt ?? 0,
                    roundCount: outcome?.roundCount ?? 0,
                    toolInvocationCount: outcome?.toolInvocationCount ?? 0,
                    escalatedFromModel: escalatedFrom,
                    verifierPassed: outcome?.verifierPassed,
                    citationsChecked: (outcome?.citationsChecked).flatMap { $0 > 0 ? $0 : nil },
                    citationsUnverifiable: (outcome?.citationsChecked).flatMap {
                        $0 > 0 ? (outcome?.citationsUnverifiable ?? 0) : nil
                    }
                ),
                runID: runID,
                runtime: runtime
            )
            AppState.persistSubagentTranscript(
                AgentSubagentTranscript(
                    runID: runID,
                    label: label,
                    prompt: AgentSubagentTranscript.clamped(
                        prompt,
                        to: AgentSubagentTranscript.Limits.promptCharacters
                    ).text,
                    model: model,
                    status: status,
                    rounds: outcome?.rounds ?? [],
                    report: AgentSubagentTranscript.clamped(
                        report,
                        to: AgentSubagentTranscript.Limits.reportCharacters
                    ).text,
                    usageTokens: outcome?.usageTokens ?? 0,
                    startedAt: startedAt,
                    finishedAt: Date(),
                    didTruncate: outcome?.didTruncate ?? false,
                    profileID: profile.id,
                    escalatedFromModel: escalatedFrom,
                    verifierCommand: verifierCommand,
                    verifierPassed: outcome?.verifierPassed,
                    attemptCount: outcome?.verifierAttempts,
                    // Only record a citation check that actually ran: zero
                    // checked would otherwise be indistinguishable from a
                    // clean sheet.
                    citationsChecked: (outcome?.citationsChecked).flatMap { $0 > 0 ? $0 : nil },
                    citationsUnverifiable: (outcome?.citationsChecked).flatMap {
                        $0 > 0 ? (outcome?.citationsUnverifiable ?? 0) : nil
                    },
                    repoCommit: AppState.workspaceHeadCommitShortSHA(for: workspaceURL)
                )
            )
        }

        func statsLine(_ outcome: AgentSubagentRunner.Outcome) -> String {
            "(subagent \(label) · \(profile.id): \(outcome.roundCount) round\(outcome.roundCount == 1 ? "" : "s"), \(outcome.toolInvocationCount) tool call\(outcome.toolInvocationCount == 1 ? "" : "s")\(outcome.usageTokens > 0 ? ", \(outcome.usageTokens) tokens" : ""))"
        }

        // Editor patches ride the parent's normal patch pipeline, so the
        // change lands in the worktree card, the artifact ledger and the
        // undo path exactly like a patch the main agent produced. They apply
        // immediately: the user already approved "let a subagent edit this
        // file" at spawn time, and re-asking per hunk would turn one decision
        // into a dozen.
        let editorPatchSink: (@MainActor (String?, String, Bool, URL) async throws -> AgentPatchProposal)? = {
            guard writeAccess != nil else { return nil }
            let hostMessageID = runtime.toolCalls.first { $0.id == recordID }?.messageID
            guard let hostMessageID else { return nil }
            return { [weak self] title, diff, _, workspaceRoot in
                guard let self else { throw AgentToolError.noWorkspace }
                return try self.enqueueAgentPatchProposal(
                    for: runtime,
                    messageID: hostMessageID,
                    title: title,
                    diff: diff,
                    workspaceRoot: workspaceRoot,
                    autoApplySource: .subagentEditor,
                    applyImmediately: true
                )
            }
        }()

        func runChild(
            configuration: AgentConfiguration,
            profile: AgentSubagentProfile
        ) async throws -> AgentSubagentRunner.Outcome {
            let effectiveTools = profile.effectiveToolNames(
                writeAccessGranted: writeAccess != nil,
                approvedCommandGranted: approvedCommand != nil
            )
            let commandReviewer: AgentSubagentRunner.CommandReviewer? = {
                guard effectiveTools.contains("run_command")
                        || effectiveTools.contains("terminal_send_command"),
                      runtime.approvalMode == .smart || runtime.interactionMode == .goal else {
                    return nil
                }
                return { [weak self] toolName, command in
                    guard let self else { return false }
                    return await self.safetyJudgeApproval(
                        toolName: toolName,
                        command: command,
                        taskContext: "Subagent trade: \(profile.id). \(profile.purpose)\nTask:\n\(prompt)"
                    ) != nil
                }
            }()
            return try await AgentSubagentRunner.run(
                prompt: prompt,
                configuration: configuration,
                workspaceURL: workspaceURL,
                runtimeDescriptor: runtimeDescriptor,
                workspaceLocation: workspaceLocation,
                profile: profile,
                writeAccess: writeAccess,
                verifierCommand: verifierCommand,
                verifierMaxAttempts: taskPacket?.maxAttempts
                    ?? AgentSubagentTaskPacket.defaultMaxAttempts,
                patchProposalSink: editorPatchSink,
                // terminal_operator 与带 target_command 的 ops_runner 需要
                // 父会话侧栏终端；其余工种在执行层拿不到这个 controller。
                terminalController: agentTerminalController,
                approvedCommand: approvedCommand,
                commandReviewer: commandReviewer,
                onProgress: { round, toolInvocations in
                    let toolPart = toolInvocations > 0 ? " · \(toolInvocations) 次工具" : ""
                    updateSubagent(progress: "第 \(round)/\(profile.maxRounds) 轮\(toolPart)")
                }
            )
        }

        do {
            // A hosted trade whose relay chain is gone answers
            // `model_not_configured` and kills the spawn outright. The roster
            // in `hostedTradeIDs` is hand-maintained, so it goes stale without
            // anyone noticing — one retry on a concrete model turns that into
            // a slower success, and the note keeps the stale entry visible.
            var attemptConfiguration = childConfiguration
            var hostedFallbackNote: String?
            var outcome: AgentSubagentRunner.Outcome
            do {
                agentSpawnLog.info(
                    "spawn_agent child attempt runtime=\(runtime.id.uuidString, privacy: .public) call=\(call.externalID, privacy: .public) run=\(runID.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) model=\(attemptConfiguration.model, privacy: .public)"
                )
                outcome = try await runChild(configuration: attemptConfiguration, profile: profile)
            } catch let error where AgentSubagentHostedModelFallback.retryModel(
                afterError: error,
                attemptedModel: attemptConfiguration.model,
                hostedModel: profile.hostedVirtualModel
            ) != nil {
                let staleModel = attemptConfiguration.model
                // Non-nil by the `where` clause above.
                let fallback = AgentSubagentHostedModelFallback.retryModel(
                    afterError: error,
                    attemptedModel: staleModel,
                    hostedModel: profile.hostedVirtualModel
                ) ?? AgentSubagentHostedModelFallback.fallbackModel
                agentSpawnLog.error(
                    "spawn_agent hosted_model_missing retrying runtime=\(runtime.id.uuidString, privacy: .public) call=\(call.externalID, privacy: .public) run=\(runID.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) staleModel=\(staleModel, privacy: .public) fallbackModel=\(fallback, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
                )
                updateSubagent(model: fallback, progress: "托管模型缺失，改用 \(fallback) 重跑…")
                attemptConfiguration.model = fallback
                outcome = try await runChild(configuration: attemptConfiguration, profile: profile)
                hostedFallbackNote = AgentSubagentHostedModelFallback.fallbackNote(
                    hostedModel: staleModel,
                    ranOn: fallback
                )
            }
            var effectiveModel = attemptConfiguration.model
            var effectiveProviderID = attemptConfiguration.providerID
            var escalatedFrom: String?

            // A cheap trade that ran out of rounds without a report is the
            // failure mode profiles introduce, so it gets the fallback the
            // design promised: one clean re-run on the parent's model. Not a
            // continuation — a small model's stuck history is noise to a
            // bigger one.
            if profile.escalation == .retryWithParentModel,
               attemptConfiguration.model != configuration.model,
               AgentSubagentEscalation.shouldEscalate(outcome: outcome, profile: profile) {
                agentSpawnLog.info(
                    "spawn_agent escalating retry runtime=\(runtime.id.uuidString, privacy: .public) call=\(call.externalID, privacy: .public) run=\(runID.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) fromModel=\(attemptConfiguration.model, privacy: .public) toModel=\(configuration.model, privacy: .public) firstRounds=\(outcome.roundCount, privacy: .public) firstReportChars=\(outcome.report.count, privacy: .public)"
                )
                updateSubagent(model: configuration.model, progress: "升级重跑中…")
                let escalatedProfile = AgentSubagentEscalation.escalatedProfile(from: profile)
                if let retried = try? await runChild(
                    configuration: configuration,
                    profile: escalatedProfile
                ) {
                    escalatedFrom = attemptConfiguration.model
                    effectiveModel = configuration.model
                    effectiveProviderID = configuration.providerID
                    outcome = retried
                }
            }

            var stats = statsLine(outcome)
            if let hostedFallbackNote {
                stats += hostedFallbackNote
            }
            if let escalatedFrom {
                stats += "\n(escalated from \(escalatedFrom) to \(effectiveModel) after the first attempt stalled)"
            }
            persist(
                status: .completed,
                outcome: outcome,
                report: outcome.report,
                model: effectiveModel,
                providerID: effectiveProviderID,
                escalatedFrom: escalatedFrom
            )
            agentSpawnLog.info(
                "spawn_agent synchronous completed runtime=\(runtime.id.uuidString, privacy: .public) call=\(call.externalID, privacy: .public) run=\(runID.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) model=\(effectiveModel, privacy: .public) rounds=\(outcome.roundCount, privacy: .public) tools=\(outcome.toolInvocationCount, privacy: .public) tokens=\(outcome.usageTokens, privacy: .public) reportChars=\(outcome.report.count, privacy: .public) verifierPassed=\(outcome.verifierPassed.map { $0 ? "true" : "false" } ?? "none", privacy: .public)"
            )
            let notices = profileNotices.isEmpty ? "" : "\n\n" + profileNotices.joined(separator: "\n")
            // A report-only run has no exit code to judge it. The citation
            // audit inside the runner already checked that its locations
            // exist; this checks the half a program cannot — whether the
            // report answers the task and rests on what it showed.
            let verdict = await reportVerdictNote(
                profile: profile,
                task: prompt,
                outcome: outcome,
                parentConfiguration: configuration
            )
            finishRecord(
                status: .succeeded,
                summary: stats,
                payload: "\(outcome.report)\(verdict)\n\n\(stats)\(notices)"
            )
        } catch is CancellationError {
            agentSpawnLog.info(
                "spawn_agent synchronous cancelled runtime=\(runtime.id.uuidString, privacy: .public) call=\(call.externalID, privacy: .public) run=\(runID.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) model=\(childConfiguration.model, privacy: .public)"
            )
            // No outcome to record, but the prompt/model/timing still explain
            // what was cancelled — better than an inspector button that opens
            // onto nothing.
            persist(
                status: .cancelled,
                outcome: nil,
                report: "(subagent cancelled)",
                model: childConfiguration.model,
                providerID: childConfiguration.providerID
            )
            finishRecord(
                status: .failed,
                summary: "cancelled",
                payload: "Subagent cancelled.",
                errorMessage: "Cancelled"
            )
        } catch {
            agentSpawnLog.error(
                "spawn_agent synchronous failed runtime=\(runtime.id.uuidString, privacy: .public) call=\(call.externalID, privacy: .public) run=\(runID.uuidString, privacy: .public) profile=\(profile.id, privacy: .public) model=\(childConfiguration.model, privacy: .public) errorType=\(String(describing: type(of: error)), privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            persist(
                status: .failed,
                outcome: nil,
                report: "Subagent failed: \(error.localizedDescription)",
                model: childConfiguration.model,
                providerID: childConfiguration.providerID
            )
            finishRecord(
                status: .failed,
                summary: "subagent failed",
                payload: "Tool error: \(error.localizedDescription)",
                errorMessage: error.localizedDescription
            )
        }
    }

    /// Workspace HEAD, short form, for anchoring a transcript as a replayable
    /// case. Nil outside a git checkout — a case without a commit is still a
    /// useful record, just not a reproducible one.
    nonisolated static func workspaceHeadCommitShortSHA(for workspaceURL: URL?) -> String? {
        guard let workspaceURL,
              let root = findGitRepositoryRoot(startingAt: workspaceURL) else { return nil }
        let output = runGit(arguments: ["rev-parse", "--short", "HEAD"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    /// Render a task packet into the worker's opening message, inlining each
    /// relevant file's contents.
    ///
    /// Files are read through the normal tool path rather than off disk so a
    /// remote (SSH) workspace resolves the same way the worker's own reads
    /// would — inlining that silently only worked locally would make the
    /// packet a local-only feature without saying so.
    func composedTaskPacketPrompt(
        packet: AgentSubagentTaskPacket,
        fallbackPrompt: String,
        workspaceURL: URL?,
        runtimeDescriptor: RuntimeDescriptor?,
        workspaceLocation: WorkspaceLocation?
    ) async -> String {
        var contents: [String: String] = [:]
        let context = AgentToolContext(
            rootDirectory: workspaceURL,
            workspaceLocation: workspaceLocation,
            runtimeDescriptor: runtimeDescriptor
        )
        for path in packet.inlineFiles {
            guard let result = try? await AgentToolRunner.run(
                name: "read_file",
                arguments: ["path": .string(path)],
                context: context
            ) else { continue }
            contents[path] = result.payload
        }
        return packet.openingMessage(fallbackPrompt: fallbackPrompt) { contents[$0] }
    }

    /// Copy the run id onto the persisted assistant tool call so reopening
    /// the session still resolves the inspector record. `runtime.toolCalls`
    /// is render-only state and does not survive a restart.
    func bindSubagentRunToPersistedToolCall(
        runID: UUID,
        externalID: String,
        runtime: AgentRuntime
    ) {
        guard let messageIndex = runtime.messages.lastIndex(where: { message in
            message.toolCalls.contains { $0.externalID == externalID }
        }) else { return }
        guard let callIndex = runtime.messages[messageIndex].toolCalls
            .firstIndex(where: { $0.externalID == externalID }) else { return }
        runtime.messages[messageIndex].toolCalls[callIndex].subagentRunID = runID
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
    }

    /// Stamp what a finished child loop cost onto the persisted tool call.
    ///
    /// The stats dashboard is a pure function over session snapshots, so this
    /// is the only route by which worker tokens reach it. Without the stamp a
    /// cheap-model tier looks free: the parent's tokens are counted and the
    /// child's are not.
    func recordSubagentRunUsage(
        _ usage: AgentSubagentRunUsage,
        runID: UUID,
        runtime: AgentRuntime
    ) {
        guard let messageIndex = runtime.messages.lastIndex(where: { message in
            message.toolCalls.contains { $0.subagentRunID == runID }
        }) else { return }
        guard let callIndex = runtime.messages[messageIndex].toolCalls
            .firstIndex(where: { $0.subagentRunID == runID }) else { return }
        runtime.messages[messageIndex].toolCalls[callIndex].subagentUsage = usage
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
    }

    /// Writes off the main actor: a long child loop's record can run to
    /// hundreds of KB, and this is autosave-adjacent work the UI must not
    /// wait on.
    nonisolated static func persistSubagentTranscript(_ transcript: AgentSubagentTranscript) {
        Task.detached(priority: .utility) {
            AgentSubagentTranscriptStore.save(transcript)
        }
    }

    nonisolated static func subagentReportNotice(for run: AgentSubagentRun) -> String {
        let durationText: String = {
            let total = Int(run.duration.rounded())
            if total < 60 { return "\(total)s" }
            let m = total / 60, s = total % 60
            if m < 60 { return "\(m)m\(s)s" }
            let h = m / 60, mm = m % 60
            return "\(h)h\(mm)m"
        }()
        return """
        <subagent-report>
        Subagent \(run.displayHandle) (\(run.label)) finished: \(run.status.rawValue), duration \(durationText), \(run.roundCount) rounds, \(run.toolInvocationCount) tool calls.
        Report:
        \(run.report)
        </subagent-report>
        """
    }

    /// Append a `tool` message to runtime.messages, running it through
    /// `AgentInjectionDefense` first. Default `source` is `.toolOutput`
    /// — the conservative case where the payload contains arbitrary
    /// bytes from the workspace / MCP / shell, any of which could carry
    /// injection markers. Callers that hand-author the payload string
    /// (denial notices, host-owned Goal gates) should pass `.systemNotice`
    /// to skip the neutralizer; the `ask_user` reply path should pass
    /// `.userAnswer` so the content gets wrapped in `<user_answer>` and
    /// the model can tell a typed reply apart from a tool result.
    func appendToolMessage(
        for runtime: AgentRuntime,
        toolCallID: String,
        payload: String,
        images: [AgentImageAttachment] = [],
        source: AgentInjectionDefense.ToolMessageSource = .toolOutput,
        outcomeStatus: AgentToolCallStatus? = nil,
        errorMessage: String? = nil,
        /// Set by callers relaying a real tool's output. Truncation is the
        /// deterministic trigger for the read-only trades, and picking the
        /// right one needs to know what produced the payload. Nil keeps the
        /// old behaviour for hand-authored notices.
        toolName: String? = nil,
        toolCommand: String? = nil
    ) {
        let sanitized = AgentInjectionDefense.sanitizedToolMessageContent(
            payload: payload,
            source: source
        )
        let limited: String
        let maxPayload = 24_000
        if sanitized.count > maxPayload {
            let handoff: String
            if let toolName,
               let note = AgentReadOnlyWorkerHandoffHint.hint(
                   toolName: toolName,
                   command: toolCommand,
                   omittedCharacters: sanitized.count - maxPayload,
                   alreadyHintedThisTurn: runtime.currentTurnEmittedReadOnlyHandoffHint
               ) {
                runtime.currentTurnEmittedReadOnlyHandoffHint = true
                handoff = note
            } else {
                handoff = ""
            }
            limited = String(sanitized.prefix(maxPayload)) + "\n...[tool output truncated]" + handoff
        } else {
            limited = sanitized
        }
        // Images ride on the tool message so vision-capable providers
        // re-see them every turn (Anthropic re-attaches as tool_result
        // image blocks). Text-only providers ignore `images` and use the
        // sanitized text payload.
        runtime.messages.append(
            AgentMessage(
                role: .tool,
                content: limited,
                images: images,
                toolCallID: toolCallID,
                toolCallStatus: outcomeStatus,
                toolErrorMessage: errorMessage
            )
        )
    }

    func attachRecentVisibleToolImages(to assistantID: UUID, in runtime: AgentRuntime) {
        guard let assistantIndex = runtime.messages.firstIndex(where: { $0.id == assistantID }) else {
            return
        }
        let images = recentVisibleToolImages(before: assistantIndex, in: runtime.messages)
        guard !images.isEmpty else { return }
        let existingIDs = Set(runtime.messages[assistantIndex].images.map(\.id))
        let newImages = images.filter { !existingIDs.contains($0.id) }
        guard !newImages.isEmpty else { return }
        runtime.messages[assistantIndex].images.append(contentsOf: newImages)
    }

    private func recentVisibleToolImages(
        before assistantIndex: Int,
        in messages: [AgentMessage]
    ) -> [AgentImageAttachment] {
        guard assistantIndex > 0 else { return [] }
        let toolNamesByCallID = toolNameLookup(in: messages)
        var grouped: [[AgentImageAttachment]] = []
        var index = assistantIndex - 1
        while index >= 0 {
            let message = messages[index]
            if message.role == .assistant {
                break
            }
            if message.role == .tool {
                let toolName = message.toolCallID.flatMap { toolNamesByCallID[$0] }
                let visible = message.images
                    .filter { $0.source == .generated || $0.source == .capture }
                    .map { image -> AgentImageAttachment in
                        // Stamp provenance while the tool message is still
                        // in reach. Once the image is lifted onto the
                        // assistant message the settled transcript has no
                        // way back to the call that produced it.
                        guard image.originToolName == nil, let toolName else { return image }
                        var stamped = image
                        stamped.originToolName = toolName
                        return stamped
                    }
                if !visible.isEmpty {
                    grouped.append(visible)
                }
            }
            index -= 1
        }
        return grouped.reversed().flatMap { $0 }
    }

    /// Maps `tool_call_id` → tool name across the whole conversation. Tool
    /// results carry only the call ID; the name lives on the assistant
    /// message that requested the call.
    private func toolNameLookup(in messages: [AgentMessage]) -> [String: String] {
        var lookup: [String: String] = [:]
        for message in messages where message.role == .assistant {
            for call in message.toolCalls {
                lookup[call.externalID] = call.toolName
            }
        }
        return lookup
    }

    func diagnoseLocalWorkspaceIfNeeded(
        after error: Error,
        runtime: AgentRuntime,
        workspaceURL: URL?
    ) -> String? {
        guard workspaceURL != nil else { return nil }
        if let availabilityError = error as? AgentWorkspaceAvailabilityError {
            return availabilityError.localizedDescription
        }
        guard let availability = runtime.diagnoseLocalWorkspaceAfterFailure(),
              availability.blocksLocalWorkspaceUse,
              let message = availability.message else {
            return nil
        }
        runtime.errorMessage = message
        runtime.errorDetails = nil
        persistAgentSession(runtime: runtime)
        return message
    }

    func terminalShortcutResultRequiresChatPasswordCard(_ result: AgentToolResult) -> Bool {
        guard let data = result.payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if object["has_pending_protected_input"] as? Bool == true {
            return true
        }
        if let pendingCount = object["pending_protected_input_count"] as? Int,
           pendingCount > 0 {
            return true
        }
        return false
    }
}
