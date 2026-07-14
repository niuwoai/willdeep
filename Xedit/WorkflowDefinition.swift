//
//  WorkflowDefinition.swift
//  WillDeep
//
//  Protocol every built-in workflow conforms to. 1.81.0-rc1 不开放给用户
//  自定义；4 个内置 workflow 由 WorkflowRegistry 静态注册。
//

import Foundation

protocol WorkflowDefinition: Sendable {
    /// 内部 slug，与 slash 命令对齐（不带 `/`），如 `"deep-research"`。
    var name: String { get }
    /// 卡片标题。
    var displayTitle: String { get }
    /// 用户触发的 slash 命令，带 `/`。
    var slashCommand: String { get }
    /// 命令右侧短描述（在 palette 里显示）。
    var shortDescription: String { get }
    /// args 输入框 placeholder（"研究问题…" / "产品名，逗号分隔" 等）。
    var argsPlaceholder: String { get }
    /// 内部并发上限。Engine 严格遵守。
    var maxAgents: Int { get }
    /// 是否允许 args 为空。比如 code-review 不需要 args（看当前 diff），
    /// deep-research 必须有 query。
    var allowsEmptyArgs: Bool { get }

    /// 省心托管（some.im managed routing）会话里，workflow 子 agent 的
    /// 任务域 —— 决定解析到 auto*（general）还是 code*（coding）虚拟模型。
    /// 默认 general；读代码/diff 的 workflow 覆写成 coding。
    var managedDomain: SomeIMManagedDomain { get }

    /// 入口。Engine 提供 DSL 原语；workflow 自己组织 agent / parallel
    /// 调用，最后返回 synthesize 出的 markdown 总结，会被 engine 写到
    /// report.summary。`args` 是用户在 slash 命令后输入的原文。
    func run(engine: WorkflowEngine, args: String) async throws -> String
}

extension WorkflowDefinition {
    var managedDomain: SomeIMManagedDomain { .general }
}
