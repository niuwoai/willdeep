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
    ]

    static func find(slashCommand: String) -> (any WorkflowDefinition)? {
        all.first { $0.slashCommand == slashCommand }
    }

    static func find(name: String) -> (any WorkflowDefinition)? {
        all.first { $0.name == name }
    }
}
