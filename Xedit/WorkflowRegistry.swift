//
//  WorkflowRegistry.swift
//  WillDeep
//
//  Static registry of built-in workflows. 1.81.0-rc1 不暴露用户自定义；
//  4 个内置 workflow 在 init 时注册，slash 命令分发查这里。
//

import Foundation

enum WorkflowRegistry {
    /// 全部内置 workflow。slash 命令分发 + composer palette 都从这里
    /// 读。顺序就是 palette 显示顺序。
    static let all: [any WorkflowDefinition] = [
        DeepResearchWorkflow(),
        CodeReviewWorkflow(),
        BugHuntWorkflow(),
        CompetitorAnalysisWorkflow(),
        // 1.81.0-rc2：GitHub 系 workflow。所有这些 workflow 开跑前会
        // 通过 GitHubCLIPreflight 同步检查 `gh` 是否装好且登录，未通过
        // 直接报错给用户，避免子 agent 跑到 LLM 调用层才发现 401。
        PRReviewWorkflow(),
        ReleaseNotesWorkflow(),
        IssueTriageWorkflow(),
        // 1.81.0-rc3：BI / 数据库系 workflow。开跑前用
        // DatabaseToolingPreflight 解析 target 类型 + 检测对应 CLI
        // （duckdb / psql / mysql / sqlite3）。所有查询 prompt 强制
        // read-only —— sub-agent 看到 SELECT 之外的语句应当拒绝。
        CSVAskWorkflow(),
        DBExploreWorkflow(),
        DBSchemaDocWorkflow(),
    ]

    static func find(slashCommand: String) -> (any WorkflowDefinition)? {
        all.first { $0.slashCommand == slashCommand }
    }

    static func find(name: String) -> (any WorkflowDefinition)? {
        all.first { $0.name == name }
    }
}
