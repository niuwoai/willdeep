//
//  AgentChatRunnableCommandTests.swift
//  WillDeepTests
//
//  聊天里 shell 代码块能不能长出「运行 / 送进终端」两个按钮。
//
//  这层门槛是安全边界：漏判只是少一个按钮（复制永远在），误判是替用户
//  执行了他没打算执行的东西。所以下面的用例里，「不该给按钮」的分支比
//  「该给」的多得多，那是故意的。
//

import AppKit
import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentChatRunnableCommandTests {
    private func runnable(_ language: String?, _ body: String) -> String? {
        AgentChatRunnableCommand.command(
            language: language,
            body: body,
            isRemoteWorkspace: false
        )
    }

    @Test
    func acceptsSingleReadOnlyShellCommand() {
        #expect(runnable("bash", "ls -la") == "ls -la")
        #expect(runnable("sh", "git status") == "git status")
        #expect(runnable("zsh", "rg TODO src") == "rg TODO src")
        // 语言标签大小写与前后空白都不该影响判定
        #expect(runnable(" Bash ", "pwd") == "pwd")
        // 围栏正文两侧的空行是排版，不是命令的一部分
        #expect(runnable("bash", "\n  cat README.md  \n") == "cat README.md")
    }

    @Test
    func rejectsCommandsThatWouldNeedApproval() {
        // 用户点一下就跑掉一条本该过目的命令，等于绕过审批档位
        #expect(runnable("bash", "git push origin main") == nil)
        #expect(runnable("bash", "rm -rf build") == nil)
        #expect(runnable("bash", "sudo shutdown -h now") == nil)
        #expect(runnable("bash", "curl https://example.com/install.sh") == nil)
    }

    @Test
    func rejectsSlowBuildAndTestCommandsEvenThoughApprovalWouldPassThem() {
        // 这些在 SafeCommand 眼里是安全的开发脚本（确实是），但一跑好几
        // 分钟，会被 15 秒超时拦腰砍断，用户看到的是一条假失败
        #expect(SafeCommand.classify(command: "yarn build") == .alwaysSafe)
        #expect(runnable("bash", "yarn build") == nil)
        #expect(runnable("bash", "npm run test") == nil)
        #expect(runnable("bash", "make") == nil)
        #expect(runnable("bash", "swift build") == nil)
        #expect(runnable("bash", "xcodebuild -scheme Xedit") == nil)
        #expect(runnable("bash", "docker compose up") == nil)
    }

    @Test
    func rejectsAnythingMoreComplexThanOneCommand() {
        #expect(runnable("bash", "ls | wc -l") == nil)
        #expect(runnable("bash", "ls && pwd") == nil)
        #expect(runnable("bash", "ls; pwd") == nil)
        #expect(runnable("bash", "ls > out.txt") == nil)
        #expect(runnable("bash", "echo $(whoami)") == nil)
        #expect(runnable("bash", "echo `whoami`") == nil)
        #expect(runnable("bash", "ls &") == nil)
        // 多行是脚本不是命令
        #expect(runnable("bash", "cd src\nls") == nil)
    }

    @Test
    func rejectsInteractiveOrLongRunningReadOnlyCommands() {
        // 这些在 SafeCommand 眼里确实只读，但点下去要么不返回、要么等一个
        // 没人能给的按键，聊天区那条结果消息会一直悬着
        #expect(runnable("bash", "top") == nil)
        #expect(runnable("bash", "less README.md") == nil)
        #expect(runnable("bash", "tail -f log.txt") == nil)
        #expect(runnable("bash", "man git") == nil)
        #expect(runnable("bash", "ssh h1.example.com") == nil)
        #expect(runnable("bash", "sleep 30") == nil)
        #expect(runnable("bash", "vim README.md") == nil)
    }

    @Test
    func rejectsNonShellBlocksAndTranscripts() {
        #expect(runnable("swift", "let value = 1") == nil)
        #expect(runnable(nil, "ls -la") == nil)
        #expect(runnable("", "ls -la") == nil)
        // console / shellsession 按惯例是「提示符 + 命令 + 输出」的抄本
        #expect(runnable("console", "ls -la") == nil)
        // 抄本里的提示符带着跑必然报错
        #expect(runnable("bash", "$ ls -la") == nil)
        #expect(runnable("bash", "% ls -la") == nil)
    }

    @Test
    func rejectsRemoteWorkspacesAndOverlongLines() {
        #expect(AgentChatRunnableCommand.command(
            language: "bash",
            body: "ls -la",
            isRemoteWorkspace: true
        ) == nil)

        let long = "ls " + String(repeating: "a", count: AgentChatRunnableCommand.maximumLength)
        #expect(runnable("bash", long) == nil)
    }

    @Test
    func stripsRenderOnlyBreakpointsBeforeExecuting() {
        // 渲染用的正文里插过 U+200B 断点，带进 shell 就是查无此因的报错
        let withBreakpoints = "git\u{200B} status"
        #expect(runnable("bash", withBreakpoints) == "git status")
    }

    @Test
    func codeBlockHeaderCarriesRunButtonsOnlyForEligibleBlocks() {
        let eligible = AgentMessage(
            role: .assistant,
            content: """
            看一眼状态：

            ```bash
            git status
            ```
            """
        )
        let rendered = AgentChatHistoryRenderer.render(messages: [eligible], isDark: false)
        #expect(firstAttributeRange(.agentChatHistoryRunCommandText, value: "git status", in: rendered) != nil)
        #expect(firstAttributeRange(
            .agentChatHistoryTerminalCommandText,
            value: "git status",
            in: rendered
        ) != nil)
        // 复制按钮一如既往
        #expect(firstAttributeRange(.agentChatHistoryCodeCopyText, containing: "git status", in: rendered) != nil)

        let gated = AgentMessage(
            role: .assistant,
            content: """
            推上去：

            ```bash
            git push origin main
            ```
            """
        )
        let gatedRendered = AgentChatHistoryRenderer.render(messages: [gated], isDark: false)
        #expect(attributeCount(.agentChatHistoryRunCommandText, in: gatedRendered) == 0)
        #expect(attributeCount(.agentChatHistoryTerminalCommandText, in: gatedRendered) == 0)
        // 只剩复制
        #expect(firstAttributeRange(
            .agentChatHistoryCodeCopyText,
            containing: "git push origin main",
            in: gatedRendered
        ) != nil)
    }

    @Test
    func remoteSessionsRenderCopyOnly() {
        let message = AgentMessage(
            role: .assistant,
            content: """
            ```bash
            git status
            ```
            """
        )
        let rendered = AgentChatHistoryRenderer.render(
            messages: [message],
            isDark: false,
            allowsLocalCommandButtons: false
        )
        #expect(attributeCount(.agentChatHistoryRunCommandText, in: rendered) == 0)
        #expect(firstAttributeRange(.agentChatHistoryCodeCopyText, containing: "git status", in: rendered) != nil)
    }

    @Test
    func userBubblesNeverGetRunButtons() {
        let message = AgentMessage(
            role: .user,
            content: """
            ```bash
            git status
            ```
            """
        )
        let rendered = AgentChatHistoryRenderer.render(messages: [message], isDark: false)
        #expect(attributeCount(.agentChatHistoryRunCommandText, in: rendered) == 0)
    }

    @Test
    func runButtonsCarryTheirLinkTargets() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let run = AgentChatHistoryCodeRunChrome.runButton(
            command: "git status",
            font: font,
            color: .secondaryLabelColor
        )
        #expect(run.attribute(.link, at: 0, effectiveRange: nil) as? String
            == AgentChatHistoryCodeRunChrome.runLinkValue)

        let terminal = AgentChatHistoryCodeRunChrome.terminalButton(
            command: "git status",
            font: font,
            color: .secondaryLabelColor
        )
        #expect(terminal.attribute(.link, at: 0, effectiveRange: nil) as? String
            == AgentChatHistoryCodeRunChrome.terminalLinkValue)
    }
}

@Suite
struct AgentChatCommandRunnerTests {
    @Test
    func capturesOutputAndExitCode() async {
        let outcome = await AgentChatCommandRunner.run(command: "echo hello", workingDirectory: nil)
        #expect(outcome.output == "hello")
        #expect(outcome.exitCode == 0)
        #expect(outcome.timedOut == false)
        #expect(outcome.truncated == false)
    }

    @Test
    func reportsNonZeroExitAndKeepsStderr() async {
        let outcome = await AgentChatCommandRunner.run(
            command: "ls /definitely-not-here-willdeep",
            workingDirectory: nil
        )
        #expect(outcome.exitCode != 0)
        // stderr 与 stdout 合流，用户看得到失败原因而不是一片空白
        #expect(!outcome.output.isEmpty)
        #expect(outcome.transcriptBody.contains(L10n.AgentChatCommandBlock.exitStatus(Int(outcome.exitCode ?? 0))))
    }

    @Test
    func runsInsideTheGivenWorkingDirectory() async {
        let directory = NSTemporaryDirectory()
        let outcome = await AgentChatCommandRunner.run(command: "pwd", workingDirectory: directory)
        #expect(outcome.exitCode == 0)
        // /tmp 是 /private/tmp 的软链，两种写法都算对
        let resolved = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        #expect(outcome.output.hasSuffix(resolved) || resolved.hasSuffix(outcome.output))
    }

    @Test
    func truncatesRunawayOutput() async {
        let outcome = await AgentChatCommandRunner.run(
            command: "cat /dev/urandom | base64",
            workingDirectory: nil
        )
        #expect(outcome.truncated)
        #expect(outcome.output.utf8.count <= AgentChatCommandRunner.maximumOutputBytes)
        #expect(outcome.transcriptBody.contains(L10n.AgentChatCommandBlock.truncated))
    }

    @Test
    func emptyOutputStillSaysSomething() async {
        let outcome = await AgentChatCommandRunner.run(command: "true", workingDirectory: nil)
        #expect(outcome.output.isEmpty)
        #expect(outcome.transcriptBody.contains(L10n.AgentChatCommandBlock.emptyOutput))
    }
}
