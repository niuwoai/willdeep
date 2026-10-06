//
//  AgentToolNameAliases.swift
//  WillDeep
//
//  Canonical tool-name resolution for hallucinated aliases, plus the
//  dispatchability test the loop uses before it lets an unknown name reach
//  the risk classifier.
//

import Foundation

/// 模型写错工具名是常态，不是异常。它们见过别家 agent 的工具表，于是
/// 把 `update_plan` 写成光秃秃的 `plan`、把 `list_directory` 写成 `ls`。
///
/// 这件事本身无害，坏就坏在下游的兜底：`AgentToolRegistry.risk(for:)`
/// 对查不到 descriptor 的名字一律返回 `.danger`，而 danger 必须由人确认。
/// 于是用户会收到一张「Agent 准备 plan」的确认卡——标题是原始 id（中文名
/// 表里当然也没有它），卡里没有任何可读的操作内容（宿主自己都不知道这个
/// 工具要干什么），而且批准之后 `AgentTools.run` 只会抛 `unknownTool`。
/// 一次纯粹的打断：看不懂、批不批都一样、还白等一分钟。
///
/// 这里把它拆成两件事：认得出的错名归一到正式名（本表），彻底不认识的
/// 名字由调用方判成失败并把错误喂回模型，两条路都不再惊动用户。
nonisolated enum AgentToolNameAliases {
    /// 幻觉名 → 正式工具名。只收录**语义确定**的错名：读这条映射的人
    /// 应当一眼认同「模型想调的就是它」。凡是需要猜参数语义才能对上的
    /// （比如把 `bash` 映射到 `run_command`，两者参数名并不一致），宁可
    /// 让它走未知工具失败路径重发，也不要静默改调一个参数对不上的工具。
    static let aliases: [String: String] = [
        // 计划工具。Codex / Claude Code 侧的同类工具有叫 `update_plan`、
        // `plan`、`todo_write` 的，模型串台的频率最高。
        "plan": "update_plan",
        "plan_update": "update_plan",
        "update_todo_list": "update_plan",
        "todo_write": "update_plan",
    ]

    /// 注册表里没有 descriptor、但 `AgentTools.run` 确实能执行的名字。
    /// `glob` 是历史遗留的兼容分支（见 AgentTools.run / AgentFileTools.glob）：
    /// 它不对模型公布，却是可派发的，所以不能被未知工具检查打成失败。
    static let unlistedDispatchableNames: Set<String> = ["glob"]

    /// 归一到正式名。未收录的名字原样返回——这个函数只做改名，不做判断。
    static func canonical(_ name: String) -> String {
        aliases[name] ?? name
    }

    /// 这个名字能不能真的跑起来。
    ///
    /// `advertisedToolNames` 传本回合实际发给模型的工具表：插件带来的 MCP
    /// 工具不在 `AgentToolRegistry.all` 里（由调用方拼进请求），只查注册表
    /// 会把它们全判成未知，等于把插件功能一刀切掉。
    ///
    /// 反过来，注册表里有、但本回合因工具包懒加载没公布的工具仍算可派发：
    /// `AgentTools.run` 的 switch 并不看公布与否，判它失败会凭空改掉一条
    /// 眼下能跑通的路径。这里只拦宿主**根本不认识**的名字。
    static func isDispatchable(_ name: String, advertisedToolNames: Set<String>) -> Bool {
        if advertisedToolNames.contains(name) { return true }
        if unlistedDispatchableNames.contains(name) { return true }
        // 卸下的工具包：模型这一侧当作不认识（页面按钮不走这里，照常可用）。
        if AgentToolPackCatalog.isUnmounted(toolName: name) { return false }
        return AgentToolRegistry.descriptor(for: name) != nil
    }

    /// 未知工具的纠正提示：从本回合真实可用的工具里挑几个形近的。
    ///
    /// 光说 "Unknown tool: xxx" 等于让模型在几十个工具里重猜一次；带上
    /// 候选名，它通常下一轮就能改对。按「包含关系 → 共同下划线词」两档
    /// 匹配，都落空就不给建议，绝不编一个不存在的工具名出来。
    static func suggestions(
        for name: String,
        advertisedToolNames: Set<String>,
        limit: Int = 3
    ) -> [String] {
        let normalized = name.lowercased()
        guard !normalized.isEmpty else { return [] }
        let candidates = advertisedToolNames.sorted()

        var contained: [String] = []
        var sharedWord: [String] = []
        let words = Set(normalized.split(separator: "_").map(String.init).filter { $0.count > 2 })

        for candidate in candidates {
            let lowered = candidate.lowercased()
            if lowered.contains(normalized) || normalized.contains(lowered) {
                contained.append(candidate)
                continue
            }
            let candidateWords = Set(lowered.split(separator: "_").map(String.init))
            if !words.isDisjoint(with: candidateWords) {
                sharedWord.append(candidate)
            }
        }

        return Array((contained + sharedWord).prefix(limit))
    }

    /// 喂回模型的失败说明。明说「没执行、不需要审批」，否则模型容易把这条
    /// 错误读成「被用户拒绝了」，转头去问用户要授权。
    static func unknownToolMessage(
        for name: String,
        advertisedToolNames: Set<String>
    ) -> String {
        if let unmounted = AgentToolPackCatalog.unmountedToolMessage(for: name) {
            return unmounted
        }
        var text = "Unknown tool: \(name). Nothing was executed and no user approval is involved."
        let hints = suggestions(for: name, advertisedToolNames: advertisedToolNames)
        if !hints.isEmpty {
            text += " Did you mean: \(hints.joined(separator: ", "))?"
        }
        text += " Re-emit the call with one of the tool names from this session's tool list, or continue without it."
        return text
    }
}
