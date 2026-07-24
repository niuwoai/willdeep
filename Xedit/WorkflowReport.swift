//
//  WorkflowReport.swift
//  WillDeep
//
//  Data model for a workflow run — 用户 /research / /code-review /
//  /bug-hunt / /competitor 启动后，由 WorkflowEngine 边跑边 mutate；
//  transcript 里的 AgentWorkflowCardView 直接展示这里的字段。
//
//  Workflow report 不污染普通 messages 流，但是会作为
//  `AgentMessage(role: .workflowReport, workflowReport: report)` 塞进
//  runtime.messages 数组、按时间序混排到 transcript。UI 渲染时按
//  role 分支识别。
//

import Foundation

nonisolated struct WorkflowReport: Codable, Equatable, Identifiable {
    enum Status: String, Codable {
        case planning
        case running
        case done
        case failed
        case cancelled
    }

    struct SubAgent: Codable, Equatable, Identifiable {
        enum Status: String, Codable {
            case pending
            case running
            case done
            case failed
        }

        let id: UUID
        var label: String
        var status: Status
        var startedAt: Date?
        var finishedAt: Date?
        var usageTokens: Int
        var roundCount: Int
        /// 子 agent 的最终报告。运行中是空。完成后填入。失败时填错误消息。
        var report: String

        init(
            id: UUID = UUID(),
            label: String,
            status: Status = .pending,
            startedAt: Date? = nil,
            finishedAt: Date? = nil,
            usageTokens: Int = 0,
            roundCount: Int = 0,
            report: String = ""
        ) {
            self.id = id
            self.label = label
            self.status = status
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.usageTokens = usageTokens
            self.roundCount = roundCount
            self.report = report
        }
    }

    let id: UUID
    /// Internal slug, e.g. `"deep-research"`. Matches WorkflowDefinition.name.
    let workflowName: String
    /// Human-facing title, e.g. `"Deep Research"`.
    var displayTitle: String
    /// User-supplied args (查询词、产品列表等). Echoed on the card.
    var args: String
    var status: Status
    /// Sub-agent run summary. Engine appends as it spawns each agent;
    /// 卡片折叠展开可看每条状态。
    var subAgents: [SubAgent]
    var startedAt: Date
    var finishedAt: Date?
    /// 累计所有 sub-agent + 任何 engine 直接消耗的 token。卡片
    /// footer 显示，给用户烧 token 的概念。
    var totalUsageTokens: Int
    /// Engine 跑完后的综合输出（synthesize 步骤的产物）。空字符串表示
    /// 还没到 synthesize / workflow 失败。供 agent 下回合 quote。
    var summary: String
    /// Present only for the multi-expert consultation workflow. The generic
    /// workflow fields remain intact so older cards and decoders stay valid.
    var consultation: AgentConsultationReport?
    /// Present only for the expert-roundtable workflow. Optional so older
    /// cards written before roundtable existed decode unchanged.
    var roundtable: AgentRoundtableReport?

    init(
        id: UUID = UUID(),
        workflowName: String,
        displayTitle: String,
        args: String,
        status: Status = .planning,
        subAgents: [SubAgent] = [],
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        totalUsageTokens: Int = 0,
        summary: String = "",
        consultation: AgentConsultationReport? = nil,
        roundtable: AgentRoundtableReport? = nil
    ) {
        self.id = id
        self.workflowName = workflowName
        self.displayTitle = displayTitle
        self.args = args
        self.status = status
        self.subAgents = subAgents
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.totalUsageTokens = totalUsageTokens
        self.summary = summary
        self.consultation = consultation
        self.roundtable = roundtable
    }

    var elapsedSeconds: TimeInterval {
        let end = finishedAt ?? Date()
        return end.timeIntervalSince(startedAt)
    }

    var completedAgentCount: Int {
        subAgents.filter { $0.status == .done || $0.status == .failed }.count
    }
}
