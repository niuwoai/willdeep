//
//  AgentToolsExpertsAndSchedules.swift
//  WillDeep
//
//  AgentToolRunner 的专家激活与会话内定时任务工具：activate_expert、
//  schedule_task、complete_scheduled_task。自 AgentTools.swift 拆出，行为不变。

import Foundation

extension AgentToolRunner {
    static func activateExpert(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let rawID = arguments["expert_id"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawID.isEmpty else {
            throw AgentToolError.missingArgument("expert_id")
        }
        guard let expert = AgentExpert(rawValue: rawID) else {
            throw AgentToolError.invalidArgument("Unknown expert_id: \(rawID)")
        }
        guard let runtimeID = context.runtimeID else {
            throw AgentToolError.invalidArgument("activate_expert requires a conversational runtime.")
        }
        let activated = await MainActor.run { () -> Bool in
            guard let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID),
                  let runtime = appState.agentRuntimes[runtimeID] else {
                return false
            }
            if runtime.activeExperts.contains(expert) {
                return true
            }
            var experts = runtime.activeExperts
            experts.insert(expert)
            runtime.activeExperts = experts
            return true
        }
        guard activated else {
            throw AgentToolError.invalidArgument("No active app session found for activate_expert.")
        }
        let reason = arguments["reason"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasonLine = reason?.isEmpty == false ? "\nReason: \(reason!)" : ""
        return AgentToolResult(
            summary: "Activated expert: \(expert.rawValue)",
            payload: "Activated \(expert.displayName) for this session.\(reasonLine)"
        )
    }

    // MARK: scheduled tasks

    /// `schedule_task` — create a scheduled task (backed by an AgentRoutine)
    /// from within the conversation and drop an inline card into the transcript.
    static func scheduleTask(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let runtimeID = context.runtimeID else {
            throw AgentToolError.invalidArgument("schedule_task requires a conversational runtime.")
        }
        let title = arguments["title"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = arguments["prompt"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else { throw AgentToolError.missingArgument("prompt") }
        let goalRaw = arguments["goal"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = (goalRaw?.isEmpty == false) ? goalRaw : nil

        let schedule: AgentRoutineSchedule
        if let minutesString = arguments["interval_minutes"]?.stringValue(),
           let minutes = Int(minutesString), minutes > 0 {
            schedule = .interval(minutes: max(1, minutes))
        } else if let dailyAt = arguments["daily_at"]?.stringValue(),
                  let time = parseHHMM(dailyAt) {
            schedule = .dailyAt(hour: time.hour, minute: time.minute)
        } else {
            throw AgentToolError.invalidArgument(
                "schedule_task needs either interval_minutes (e.g. \"30\") or daily_at (\"HH:MM\")."
            )
        }

        let name: String = {
            if !title.isEmpty { return title }
            if let goal, !goal.isEmpty { return String(goal.prefix(48)) }
            return String(prompt.prefix(48))
        }()

        let created: AgentRoutine? = await MainActor.run {
            guard let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) else {
                return nil
            }
            let routine = AgentRoutine(
                name: name,
                prompt: prompt,
                workspaceRootPath: appState.agentRuntimes[runtimeID]?.workspaceRootPath,
                schedule: schedule,
                originSessionID: runtimeID,
                goal: goal
            )
            appState.saveAgentRoutine(routine)
            AgentScheduledTaskRegistry.shared.add(
                AgentScheduledTaskCard(
                    id: routine.id,
                    title: name,
                    scheduleSummary: schedule.summary,
                    goal: goal,
                    prompt: prompt
                ),
                forRuntime: runtimeID
            )
            return routine
        }
        guard let routine = created else {
            throw AgentToolError.invalidArgument("No active app session found for schedule_task.")
        }

        let goalLine = goal.map { "\nGoal (task self-completes when met): \($0)" } ?? ""
        return AgentToolResult(
            summary: "Scheduled task: \(name) · \(schedule.summary)",
            payload: "Scheduled task \"\(name)\" created (task_id: \(routine.id.uuidString)); it will run \(schedule.summary). Each run receives this prompt: \(prompt)\(goalLine)"
        )
    }

    /// `complete_scheduled_task` — remove a scheduled task once its goal is met.
    /// Called by the fired run when it judges the goal achieved; also usable to
    /// cancel a task by id.
    static func completeScheduledTask(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let runtimeID = context.runtimeID else {
            throw AgentToolError.invalidArgument("complete_scheduled_task requires a conversational runtime.")
        }
        let idString = arguments["task_id"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let taskID = UUID(uuidString: idString) else {
            throw AgentToolError.invalidArgument("task_id must be a valid scheduled-task id.")
        }
        let reason = arguments["reason"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)

        let existed: Bool = await MainActor.run {
            guard let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) else {
                return false
            }
            let found = appState.agentRoutines.contains { $0.id == taskID }
            appState.deleteAgentRoutine(id: taskID)
            return found
        }

        let reasonLine = reason?.isEmpty == false ? " Reason: \(reason!)" : ""
        if existed {
            return AgentToolResult(
                summary: "Completed scheduled task",
                payload: "Scheduled task \(taskID.uuidString) marked complete and removed.\(reasonLine)"
            )
        }
        return AgentToolResult(
            summary: "Scheduled task already gone",
            payload: "No scheduled task with id \(taskID.uuidString) (it may already be removed).\(reasonLine)"
        )
    }

    /// Parse "HH:MM" (24h) into components; returns nil on malformed input.
    private static func parseHHMM(_ raw: String) -> (hour: Int, minute: Int)? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), (0...23).contains(hour),
              let minute = Int(parts[1]), (0...59).contains(minute) else {
            return nil
        }
        return (hour, minute)
    }
}
