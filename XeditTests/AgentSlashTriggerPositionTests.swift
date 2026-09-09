//
//  AgentSlashTriggerPositionTests.swift
//  WillDeepTests
//
//  斜杠词写在句尾。
//
//  `@` 与 `$` 一直可以出现在正文中间（触发符紧跟空白即可），斜杠却只在
//  整条消息开头才认。对 `/code-review` 那种「命令 + 参数」是合理的，但
//  `/no-subagent` 这类的参数**就是正文**，用户自然想写成「把这批测试跑
//  一遍 /no-subagent」。
//
//  放宽唤起位置只是一半：另一半是提交时怎么切正文。按第一个空格切会把
//  整句连标记一起当成参数，于是发出去的消息里带着一个没被消费掉的
//  `/no-subagent`——那比唤不起面板更糟，因为它看起来成功了。
//

import Foundation
import Testing
@testable import WillDeep

@Suite("Slash command position")
nonisolated struct AgentSlashTriggerPositionTests {
    @Test("斜杠在开头时按旧规则切参数")
    func leadingSlashKeepsTheOldSplit() {
        #expect(SlashCommand.hasLeadingSlash("/no-subagent 把这批测试跑一遍"))
        #expect(SlashCommand.argsForCommand("/no-subagent 把这批测试跑一遍") == "把这批测试跑一遍")
        // 前导空白不该改变判断。
        #expect(SlashCommand.hasLeadingSlash("  /code-review"))
    }

    @Test("斜杠在句尾时正文是去掉那个词剩下的部分")
    func trailingSlashLeavesTheProseIntact() {
        let input = "把这批测试跑一遍 /no-subagent"
        #expect(!SlashCommand.hasLeadingSlash(input))
        #expect(
            SlashCommand.argsByRemovingTrailingCommand(input, token: "/no-subagent")
                == "把这批测试跑一遍"
        )
    }

    @Test("斜杠在句中时同样只摘掉那一个词")
    func slashInTheMiddleIsRemovedInPlace() {
        let input = "先跑测试 /no-subagent 再告诉我结果"
        let args = SlashCommand.argsByRemovingTrailingCommand(input, token: "/no-subagent")
        // 摘掉标记，前后正文都保住。多余的空格由调用方的 trim 收拾两端，
        // 中间那一个空格留着——把它也吞掉会让两句话粘在一起。
        #expect(args.contains("先跑测试"))
        #expect(args.contains("再告诉我结果"))
        #expect(!args.contains("/no-subagent"))
    }

    @Test("同一个词出现两次时摘最后那个")
    func repeatedTokenRemovesTheLastOccurrence() {
        // 用户先打错又重打一遍是常见的。面板认的是光标所在那个，也就是
        // 最后那个。
        let input = "/no-subagent 说错了 /no-subagent"
        let args = SlashCommand.argsByRemovingTrailingCommand(input, token: "/no-subagent")
        #expect(args == "/no-subagent 说错了")
    }

    @Test("找不到那个词时原样返回，不静默丢正文")
    func missingTokenReturnsTheProse() {
        #expect(
            SlashCommand.argsByRemovingTrailingCommand("把测试跑一遍", token: "/no-subagent")
                == "把测试跑一遍"
        )
    }

    @Test("过滤器认「带斜杠的 token」这个形状")
    func filterAcceptsTheTokenShape() {
        let all = SlashCommand.builtIn(state: AppState())
        // composer 推给面板的是光标所在那个 token 补回斜杠后的样子，
        // 不是整个缓冲区——斜杠不在开头时，整个缓冲区会被过滤器的
        // hasPrefix("/") 判掉。
        let byToken = SlashCommand.filter("/no-sub", allCommands: all)
        #expect(byToken.contains { $0.id == "no-subagent" })
        // 整句喂进去必然为空，这正是为什么要推 token 而不是缓冲区。
        #expect(SlashCommand.filter("把测试跑一遍 /no-sub", allCommands: all).isEmpty)
    }
}
