//
//  AgentTaskMonitorSnapshot.swift
//  WillDeep
//
//  Comparable task monitor state used to coordinate the rail with chat chrome.
//

import Foundation

struct AgentTaskMonitorSnapshot: Equatable {
    var sessionID: UUID?
    var isAgentResponding: Bool
    var isCompressingContext: Bool
    var runningTaskCount: Int
    var attentionToolIDs: [String]
    var jobDigest: [String]
    var mediaTaskDigest: [String]
    var todoDigest: [String]
    var workFileDigest: [String]
    var learningDigest: [String]

    var isAgentActivityActive: Bool {
        // 「思考中」(`isAgentResponding` 但没有任何 tool / 后台任务) 是日
        // 常状态,不应触发任务监控自动展开。只把有实质动作的状态算
        // 作 active:正在压缩上下文、有后台任务在跑、或有 tool 在等审
        // 批 / 等确认 / 等回答 / 正在执行。
        isCompressingContext
            || runningTaskCount > 0
            || !attentionToolIDs.isEmpty
    }

    var hasVisibleMonitorContent: Bool {
        isAgentActivityActive
            || !jobDigest.isEmpty
            || !mediaTaskDigest.isEmpty
            || !todoDigest.isEmpty
            || !workFileDigest.isEmpty
            || !learningDigest.isEmpty
    }

    static func capture(from appState: AppState) -> AgentTaskMonitorSnapshot {
        AgentTaskMonitorSnapshot(
            sessionID: appState.activeAgentSessionID,
            isAgentResponding: appState.isAgentResponding,
            isCompressingContext: appState.isCompressingAgentContext,
            runningTaskCount: appState.agentRunningTaskCount,
            attentionToolIDs: appState.agentToolCalls
                .filter { call in
                    switch call.status {
                    case .pendingApproval, .awaitingConfirm, .awaitingUserAnswer, .running:
                        return true
                    case .succeeded, .failed, .denied:
                        return false
                    }
                }
                .map { "\($0.id.uuidString):\($0.status.rawValue):\($0.toolName)" },
            jobDigest: jobDigest(from: appState),
            mediaTaskDigest: mediaTaskDigest(from: appState),
            todoDigest: todoDigest(from: appState),
            workFileDigest: appState.agentWorktreeChanges.files.map { change in
                [
                    change.path,
                    change.kind.rawValue,
                    String(change.addedLines),
                    String(change.deletedLines)
                ].joined(separator: ":")
            },
            learningDigest: learningDigest(from: appState)
        )
    }

    private static func todoDigest(from appState: AppState) -> [String] {
        if let plan = appState.agentCurrentPlan, !plan.steps.isEmpty {
            return ["plan:\(plan.status.rawValue)"] + plan.steps.map { step in
                "\(step.id.uuidString):\(step.status.rawValue):\(step.text)"
            }
        }
        if let goal = appState.agentCurrentGoal, !goal.checklist.isEmpty {
            return ["goal:\(goal.statement)"] + goal.checklist.map { item in
                "\(item.id.uuidString):\(item.done):\(item.text)"
            }
        }
        return []
    }

    private static func jobDigest(from appState: AppState) -> [String] {
        guard let runtimeID = appState.activeAgentSessionID else { return [] }
        return appState.agentJobRegistry.jobs(forRuntime: runtimeID).map { job in
            [
                job.id.uuidString,
                job.status.rawValue,
                String(job.exitCode ?? Int32.min),
                String(job.outputByteCount),
                String(Int((job.finishedAt ?? job.startedAt).timeIntervalSince1970)),
                job.command
            ].joined(separator: ":")
        }
    }

    private static func mediaTaskDigest(from appState: AppState) -> [String] {
        appState.agentMediaTaskRegistry
            .tasks(forRuntime: appState.activeAgentSessionID)
            .filter { task in task.isActive || task.needsAttention || task.status == .succeeded }
            .sorted {
                ($0.finishedAt ?? $0.updatedAt) > ($1.finishedAt ?? $1.updatedAt)
            }
            .prefix(8)
            .map { task in
                [
                    task.id.uuidString,
                    task.status.rawValue,
                    task.provider.rawValue,
                    task.kind.rawValue,
                    String(task.artifacts.count),
                    String(Int(task.updatedAt.timeIntervalSince1970))
                ].joined(separator: ":")
            }
    }

    private static func learningDigest(from appState: AppState) -> [String] {
        // 同 learningSummary:digest 只反映本轮事件,避免历史轮次写
        // 进 snapshot 后触发 hasVisibleMonitorContent 自动展开。
        let events = appState.agentCurrentTurnLearningEvents
        return events.map { event in
            [
                event.id.uuidString,
                event.kind.rawValue,
                event.status.rawValue,
                event.title
            ].joined(separator: ":")
        }
    }
}
