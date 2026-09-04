//
//  L10n+AgentChatCommandBlock.swift
//  WillDeep
//
//  聊天里可执行 shell 代码块的两个图标按钮，以及执行结果那条消息。
//

import Foundation

extension L10n {
    enum AgentChatCommandBlock {
        static let runTooltip = String(
            localized: "agent-chat-command-block.run-tooltip",
            defaultValue: "Run this command here and show the output below"
        )
        static let terminalTooltip = String(
            localized: "agent-chat-command-block.terminal-tooltip",
            defaultValue: "Run this command in the terminal panel"
        )

        /// 执行结果消息的抬头。%@ 是命令原文。
        static func resultHeader(_ command: String) -> String {
            String(
                format: String(
                    localized: "agent-chat-command-block.result-header",
                    defaultValue: "Ran from the conversation: `%@`"
                ),
                command
            )
        }

        static let emptyOutput = String(
            localized: "agent-chat-command-block.empty-output",
            defaultValue: "(no output)"
        )

        /// %lld 是退出码。
        static func exitStatus(_ code: Int) -> String {
            String(
                format: String(
                    localized: "agent-chat-command-block.exit-status",
                    defaultValue: "Exit code %lld"
                ),
                code
            )
        }

        /// %lld 是超时秒数。
        static func timedOut(_ seconds: Int) -> String {
            String(
                format: String(
                    localized: "agent-chat-command-block.timed-out",
                    defaultValue: "Killed after %lld seconds without finishing"
                ),
                seconds
            )
        }

        static let truncated = String(
            localized: "agent-chat-command-block.truncated",
            defaultValue: "(output truncated)"
        )

        static let refused = String(
            localized: "agent-chat-command-block.refused",
            defaultValue: "This command is no longer eligible to run from the conversation; copy it and run it yourself."
        )

        static let launchFailed = String(
            localized: "agent-chat-command-block.launch-failed",
            defaultValue: "Could not start the command"
        )
    }
}
