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

    @Test("补全的是后面的斜杠词时只补这个词")
    func completingChainedToken() {
        #expect(SlashCommand.isCompletingChainedCommand(input: "/no-sandbox /sub", currentToken: "/sub"))
        #expect(!SlashCommand.isCompletingChainedCommand(input: "/sub", currentToken: "/sub"))
        #expect(!SlashCommand.isCompletingChainedCommand(input: "跑测试 /no-sub", currentToken: "/no-sub"))
    }

    @Test("内置命令里有 /handoff 和 /sessions")
    func builtInCollaborationCommands() {
        let ids = SlashCommand.builtIn(state: AppState()).map(\.id)
        #expect(ids.contains("handoff"))
        #expect(ids.contains("sessions"))
        #expect(Set(ids).count == ids.count)
    }
}
