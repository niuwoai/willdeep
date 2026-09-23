//
//  AppStateAgentRoutines.swift
//  WillDeep
//
//  Agent 例行任务（routines）：保存、删除、启停、立即运行、到点触发，
//  以及运行结果的回填。
//
//  从 AppStateAgentSessions.swift 抽出（3000 行硬上限治理）。例行任务本就
//  自成一域，与会话生命周期只经由 AppState 上的既有属性交互。
//
//  仍以 extension 挂在 AppState 上，调用点一律不变。
//

import AppKit
import Foundation

extension AppState {
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
        let session = makeRoutineRunSession(for: routine)
        agentSessions.insert(session, at: 0)
        // saveAsync, not save: sync save can beachball behind another
        // instance's NSFileCoordinator hold on the session directory.
        AgentSessionStore.saveAsync(session)
        upsertAgentUsageSnapshot(for: session)
        let runtime = AgentRuntime(session: session)
        agentRuntimes[session.id] = runtime
        let startedAt = Date()
        publishAgentKernelEvent(
            AgentKernelEvent(
                runtimeID: session.id,
                source: .timer,
                kind: .scheduledWake,
                priority: .normal,
                interruptPolicy: .enqueue,
                trust: .host,
                contentProvenance: .host,
                audience: .user,
                title: routine.name,
                payload: "Scheduled routine fired.",
                metadata: ["resource_id": routine.id.uuidString],
                dedupeKey: "routine:\(routine.id.uuidString):\(Int(startedAt.timeIntervalSince1970))",
                requiresUserAction: false
            )
        )
        // Routine session stays a background runtime — no activeRuntime
        // forward subscription. Sidebar status dot observes it directly.
        if let modelID = routine.modelID, !modelID.isEmpty {
            runtime.sessionModelOverride = modelID
        }
        agentRoutines[index].lastRunAt = startedAt
        agentRoutines[index].lastSessionID = session.id
        agentRoutines[index].updatedAt = startedAt
        AgentRoutineStore.save(agentRoutines[index])
        agentRoutineScheduler.routinesChanged(agentRoutines)
        agentRoutineRuns.insert(
            AgentRoutineRunRecord(
                routineID: routine.id,
                routineName: routine.name,
                sessionID: session.id,
                startedAt: startedAt
            ),
            at: 0
        )
        agentRoutineRuns = AgentRoutineRunHistory.recent(
            agentRoutineRuns,
            limit: AgentRoutineRunHistory.maximumStoredRuns
        )
        AgentRoutineRunStore.save(agentRoutineRuns)

        // Scheduled runs have no operator watching their terminal. Give the
        // model a durable least-side-effect execution contract so diagnostic
        // routines naturally choose the statically approvable path (for
        // example, stream journalctl output over SSH instead of creating
        // remote /tmp files). Explicitly requested mutations still go through
        // the normal approval boundary.
        let unattendedGuidance = """
        [周期任务 · 无人值守执行边界]
        本次运行来自后台周期任务。优先使用只读工具和只读命令完成分析；远程日志巡检应直接读取并流式筛选 journalctl/systemctl 输出，不要为了分析创建远端临时文件，也不要重启服务、修改配置、改变权限或删除数据。只有原任务明确要求产生外部副作用时才可提出相应操作；无法在安全边界内完成时，请在结果中说明具体阻塞原因，不要等待无人值守的交互确认。
        """

        // Goal-bearing tasks self-complete: tell this run to evaluate the goal
        // and, if met, call complete_scheduled_task with its own id so the task
        // (and its card) disappears. Plain routines receive the same unattended
        // execution boundary after their saved prompt.
        let dispatchText: String
        if let goal = routine.goal?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty {
            dispatchText = """
            \(prompt)

            \(unattendedGuidance)

            [定时任务 · 自完成判定] 本次运行来自定时任务「\(routine.name)」(task_id: \(routine.id.uuidString))。
            目标:\(goal)
            完成上述工作后,判断该目标是否已达成:
            - 已达成 → 调用 complete_scheduled_task 工具(task_id 传 \(routine.id.uuidString)),移除这个定时任务;它将不再运行,卡片也会消失。
            - 未达成 → 正常简短汇报当前进展即可,不要调用 complete_scheduled_task。
            """
        } else {
            dispatchText = """
            \(prompt)

            \(unattendedGuidance)
            """
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

    /// The conversation one run of `routine` starts in.
    ///
    /// `forRoutineRun` stamps `originRoutineID`, which marks the run
    /// unattended for the rest of its life: nobody is watching this
    /// conversation at 22:00, so its turn loop gets the minutes-long
    /// transient-network recovery window instead of the interactive "show
    /// the error card and wait for a click" path. The approval mode is the
    /// one saved on the task, never the composer's current setting.
    func makeRoutineRunSession(for routine: AgentRoutine) -> AgentSession {
        let routineProvider = agentProviderLibrary.active
        return AgentSession.forRoutineRun(
            routineID: routine.id,
            workspaceRootPath: routine.workspaceRootPath,
            modelID: routine.modelID?.isEmpty == false
                ? routine.modelID
                : agentConfiguration.normalized.model(for: .interactive),
            providerEntryID: routineProvider?.id,
            providerID: routineProvider?.providerID,
            providerDisplayName: routineProvider?.displayName,
            approvalMode: routine.approvalMode
        )
    }

    /// Close out the run-history record for a scheduled-routine conversation.
    ///
    /// Every path that ends a routine turn calls this, so the Automations page
    /// can answer "did the 22:00 job work?" instead of only "did it start?".
    /// Failures additionally raise a system notification — the start-only
    /// notice meant a routine announced itself and then went quiet whether it
    /// succeeded or died.
    ///
    /// Deliberately once per run: a later manual 重试 in the same conversation
    /// does not rewrite history, because what the page reports is how the
    /// *scheduled* run went.
    func recordRoutineRunCompletionIfNeeded(for runtime: AgentRuntime) {
        guard runtime.session.originRoutineID != nil else { return }
        guard let index = agentRoutineRuns.firstIndex(where: {
            $0.sessionID == runtime.id && $0.finishedAt == nil && $0.outcome == .running
        }) else { return }

        let failure = runtime.lastTurnFailure
        let outcome: AgentRoutineRunOutcome
        if failure != nil {
            outcome = .failed
        } else if runtime.messages.last(where: { $0.role == .assistant })?.content.isEmpty == false {
            outcome = .succeeded
        } else {
            // No error and no reply: a user Stop, or a turn that unwound
            // without ever reaching the provider. Claiming success here is
            // exactly the kind of flattering guess this record exists to stop.
            outcome = .interrupted
        }

        agentRoutineRuns[index].finishedAt = Date()
        agentRoutineRuns[index].outcome = outcome
        agentRoutineRuns[index].failureMessage = failure?.message
        AgentRoutineRunStore.save(agentRoutineRuns)

        if let failure {
            agentRoutineScheduler.postFailureNotificationIfAuthorized(
                routineName: agentRoutineRuns[index].routineName,
                reason: failure.message
            )
        }
    }
}
