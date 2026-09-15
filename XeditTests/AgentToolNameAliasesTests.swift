//
//  AgentToolNameAliasesTests.swift
//  WillDeepTests
//

import Testing

@testable import WillDeep

@Suite("工具名归一与未知工具")
nonisolated struct AgentToolNameAliasesTests {
    /// 本例来自真实现场：deepseek-v4-flash 把 `update_plan` 写成 `plan`，
    /// 用户收到一张「Agent 准备 plan」的确认卡，看不到任何内容，等了 1 分
    /// 48 秒，批准之后只等来 unknownTool。
    @Test("plan 归一到 update_plan")
    func planAliasResolvesToUpdatePlan() {
        #expect(AgentToolNameAliases.canonical("plan") == "update_plan")
        #expect(AgentToolNameAliases.canonical("todo_write") == "update_plan")
        #expect(AgentToolNameAliases.canonical("update_todo_list") == "update_plan")
    }

    /// 归一只改认得出的错名。正式名和陌生名都必须原样穿过去，否则这层
    /// 会变成一个会偷偷改写工具调用的隐形中间人。
    @Test("未收录的名字原样返回")
    func unknownNamesPassThroughUnchanged() {
        #expect(AgentToolNameAliases.canonical("update_plan") == "update_plan")
        #expect(AgentToolNameAliases.canonical("run_command") == "run_command")
        #expect(AgentToolNameAliases.canonical("frobnicate") == "frobnicate")
    }

    /// 别名表里的每个正式名都必须真的存在于注册表。写错一个字母，归一
    /// 就会把一次可修复的调用改成一次必然失败的调用。
    @Test("别名的目标工具都在注册表里")
    func aliasTargetsExistInRegistry() {
        for (alias, target) in AgentToolNameAliases.aliases {
            #expect(
                AgentToolRegistry.descriptor(for: target) != nil,
                "别名 \(alias) 指向的 \(target) 不在工具注册表里"
            )
        }
    }

    /// 插件带来的 MCP 工具不在 AgentToolRegistry.all 里。只查注册表就会
    /// 把整类插件工具判成未知、直接打成失败——插件功能会一刀切没。
    @Test("插件 MCP 工具算可派发")
    func pluginToolsCountAsDispatchable() {
        #expect(
            AgentToolNameAliases.isDispatchable(
                "some_plugin_tool",
                advertisedToolNames: ["some_plugin_tool"]
            )
        )
        #expect(
            !AgentToolNameAliases.isDispatchable(
                "some_plugin_tool",
                advertisedToolNames: []
            )
        )
    }

    /// 注册表里有、但本回合因工具包懒加载没公布的工具仍然可派发：
    /// AgentTools.run 的 switch 不看公布与否，判它失败等于凭空掐掉一条
    /// 眼下跑得通的路径。
    @Test("注册表内的工具不受本回合公布范围影响")
    func registeredToolsStayDispatchableWhenUnadvertised() {
        #expect(
            AgentToolNameAliases.isDispatchable("update_plan", advertisedToolNames: [])
        )
    }

    /// `glob` 不对模型公布，却有真实执行分支。未知工具检查不能误伤它。
    @Test("未公布但可执行的 glob 不算未知")
    func unlistedDispatchableNamesAreNotUnknown() {
        #expect(AgentToolNameAliases.isDispatchable("glob", advertisedToolNames: []))
    }

    /// 宿主真不认识的名字才判未知。
    @Test("彻底陌生的名字判为不可派发")
    func trulyUnknownNamesAreRejected() {
        #expect(
            !AgentToolNameAliases.isDispatchable(
                "definitely_not_a_tool",
                advertisedToolNames: ["run_command", "read_file"]
            )
        )
    }

    /// 候选名只能从真实工具表里挑。编一个不存在的名字出来，模型下一轮会
    /// 照着它再错一次。
    @Test("候选名来自真实工具表")
    func suggestionsComeFromAdvertisedTools() {
        let hints = AgentToolNameAliases.suggestions(
            for: "plan",
            advertisedToolNames: ["update_plan", "run_command", "read_file"]
        )
        #expect(hints.contains("update_plan"))
        #expect(!hints.contains("run_command"))
    }

    @Test("没有形近工具时不给建议")
    func suggestionsStayEmptyWithoutMatches() {
        #expect(
            AgentToolNameAliases.suggestions(
                for: "zzz",
                advertisedToolNames: ["run_command", "read_file"]
            ).isEmpty
        )
    }

    /// 喂回模型的文案必须说清「没执行、不涉及审批」。少了这句，模型容易
    /// 把失败读成「被用户拒绝」，转头去问用户要授权——又是一次无谓打断。
    @Test("失败说明写明未执行且与审批无关")
    func unknownToolMessageRulesOutApproval() {
        let message = AgentToolNameAliases.unknownToolMessage(
            for: "frobnicate",
            advertisedToolNames: ["run_command"]
        )
        #expect(message.contains("Unknown tool: frobnicate"))
        #expect(message.contains("Nothing was executed"))
        #expect(message.contains("no user approval"))
    }

    @Test("有形近工具时把候选名带进失败说明")
    func unknownToolMessageCarriesSuggestions() {
        let message = AgentToolNameAliases.unknownToolMessage(
            for: "read_files",
            advertisedToolNames: ["read_file", "run_command"]
        )
        #expect(message.contains("read_file"))
    }
}
