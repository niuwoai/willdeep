//
//  SlashCommandChainTests.swift
//  WillDeepTests
//
//  一条消息开头串写多个斜杠命令：`/no-sandbox /subagent 修一下登录`。
//  正文只交给一个命令（否则两个「参数即正文」的命令会把同一句话发两遍）。
//

import Foundation
import Testing
@testable import WillDeep

@Suite("Slash command chain")
@MainActor
struct SlashCommandChainTests {
    private func command(_ id: String, _ mode: SlashCommandArgumentMode = .none, aliases: [String] = []) -> SlashCommand {
        SlashCommand(id: id, title: "/\(id)", subtitle: "", symbol: "circle", argumentMode: mode, aliases: aliases) { _ in }
    }

    private var commands: [SlashCommand] {
        [
            command("new"),
            command("no-sandbox", .optional(placeholder: "")),
            command("subagent", .required(placeholder: ""), aliases: ["delegate"]),
            command("handoff", .optional(placeholder: "")),
        ]
    }

    @Test("单个命令不算串写，沿用旧路径")
    func singleCommandIsNotAChain() {
        #expect(SlashCommand.invocationChain(in: "/subagent 修登录", commands: commands) == nil)
        #expect(SlashCommand.invocationChain(in: "修登录", commands: commands) == nil)
    }

    @Test("正文交给必须带参数的那个命令，其余先执行")
    func textGoesToTheRequiredCommand() throws {
        let chain = try #require(SlashCommand.invocationChain(in: "  /subagent /no-sandbox 修一下\n登录", commands: commands))
        #expect(chain.steps.map(\.command.id) == ["no-sandbox", "subagent"])
        #expect(chain.steps.map(\.args) == ["", "修一下\n登录"])
        #expect(chain.trailingMessage == nil)
        #expect(chain.missingRequiredArguments == nil)
    }

    @Test("没有必须参数的命令时交给最后一个接受参数的")
    func textGoesToTheLastOptionalCommand() throws {
        let chain = try #require(SlashCommand.invocationChain(in: "/no-sandbox /handoff 先跑测试", commands: commands))
        #expect(chain.steps.map(\.command.id) == ["no-sandbox", "handoff"])
        #expect(chain.steps.last?.args == "先跑测试")
    }

    @Test("都不收参数时正文作为普通消息最后发出")
    func trailingMessageWhenNoConsumer() throws {
        let chain = try #require(SlashCommand.invocationChain(in: "/new /new 你好", commands: commands))
        #expect(chain.steps.count == 2)
        #expect(chain.trailingMessage == "你好")
        let bare = try #require(SlashCommand.invocationChain(in: "/new /new", commands: commands))
        #expect(bare.trailingMessage == nil)
    }

    @Test("别名可以串写；不认识的斜杠词结束串写并归入正文")
    func aliasesAndUnknownTokens() throws {
        let chain = try #require(SlashCommand.invocationChain(in: "/no-sandbox /delegate 看 /Users/rocky/a.swift", commands: commands))
        #expect(chain.steps.last?.command.id == "subagent")
        #expect(chain.steps.last?.args == "看 /Users/rocky/a.swift")
        #expect(SlashCommand.invocationChain(in: "/new /Users/rocky", commands: commands) == nil)
    }

    @Test("必须参数的命令没拿到正文时整串不执行")
    func missingRequiredArgumentsBlocksChain() throws {
        let chain = try #require(SlashCommand.invocationChain(in: "/new /subagent", commands: commands))
        #expect(chain.missingRequiredArguments?.id == "subagent")
    }

    @Test("补全的不是第一个词时只补这个词，不执行")
    func completingNonLeadingToken() {
        #expect(SlashCommand.isCompletingNonLeadingToken(input: "/no-sandbox /sub", currentToken: "/sub"))
        #expect(!SlashCommand.isCompletingNonLeadingToken(input: "/sub", currentToken: "/sub"))
        // 正文后面打的 /no：以前会连半截话一起发出去。
        #expect(SlashCommand.isCompletingNonLeadingToken(input: "升级到 0.244.0-rc1 这个版本 /no", currentToken: "/no"))
    }

    @Test("开头命令任意，正文里只认修饰类命令")
    func recognizedTokensInProse() {
        let text = "/new 解释一下 /handoff 是什么 /subagent"
        let ids = SlashCommand.recognizedTokens(in: text, commands: commands).map(\.commandID)
        #expect(ids == ["new", "subagent"])
        let ns = text as NSString
        let ranges = SlashCommand.recognizedTokens(in: text, commands: commands).map { ns.substring(with: $0.range) }
        #expect(ranges == ["/new", "/subagent"])
        #expect(SlashCommand.recognizedTokens(in: "看下 /Users/rocky 目录", commands: commands).isEmpty)
    }

    @Test("句尾修饰命令：正文交给命令，命令词不进正文")
    func trailingModifierBecomesChain() throws {
        let chain = try #require(SlashCommand.composerChain(in: "帮我升级 tokenhub 到 0.244.0-rc1 /delegate", commands: commands))
        #expect(chain.steps.map(\.command.id) == ["subagent"])
        #expect(chain.steps.last?.args == "帮我升级 tokenhub 到 0.244.0-rc1")
        #expect(chain.trailingMessage == nil)
    }

    @Test("句中修饰命令与开头命令一起排成一串")
    func midTextModifiersJoinLeadingCommand() throws {
        let chain = try #require(SlashCommand.composerChain(in: "/no-sandbox 修一下 /subagent 登录", commands: commands))
        #expect(chain.steps.map(\.command.id) == ["no-sandbox", "subagent"])
        #expect(chain.steps.last?.args == "修一下 登录")
    }

    @Test("开头单个命令、正文里没有命令词时走原路径")
    func singleLeadingCommandKeepsInvocationPath() {
        #expect(SlashCommand.composerChain(in: "/subagent 修登录", commands: commands) == nil)
        #expect(SlashCommand.composerChain(in: "解释一下 /handoff 是干嘛的", commands: commands) == nil)
        #expect(SlashCommand.composerChain(in: "普通消息", commands: commands) == nil)
    }

    @Test("内置命令里有 /handoff 和 /sessions")
    func builtInCollaborationCommands() {
        let ids = SlashCommand.builtIn(state: AppState()).map(\.id)
        #expect(ids.contains("handoff"))
        #expect(ids.contains("sessions"))
        #expect(Set(ids).count == ids.count)
    }
}
