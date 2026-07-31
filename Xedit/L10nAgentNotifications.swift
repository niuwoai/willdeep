//
//  L10nAgentNotifications.swift
//  WillDeep
//
//  Agent notification copy split from the core localization catalogue.
//

import Foundation

extension L10n {
    enum AgentNotifications {
        static let approvalTitle = String(
            localized: "agent-notification.interaction.approval-title",
            defaultValue: "Agent needs authorization"
        )
        static let confirmationTitle = String(
            localized: "agent-notification.interaction.confirmation-title",
            defaultValue: "Agent needs confirmation"
        )
        static let answerTitle = String(
            localized: "agent-notification.interaction.answer-title",
            defaultValue: "Agent is waiting for your answer"
        )
        static let attentionTitle = String(
            localized: "agent-notification.interaction.attention-title",
            defaultValue: "Agent needs your attention"
        )
        static let command = String(
            localized: "agent-notification.command",
            defaultValue: "Command"
        )
        static let toolRunCommand = String(
            localized: "agent-notification.tool.run-command",
            defaultValue: "Run command"
        )
        static let toolTerminalCommand = String(
            localized: "agent-notification.tool.terminal-command",
            defaultValue: "Send command to terminal"
        )
        static let toolTerminalControl = String(
            localized: "agent-notification.tool.terminal-control",
            defaultValue: "Control terminal"
        )
        static let toolEditFile = String(
            localized: "agent-notification.tool.edit-file",
            defaultValue: "Edit file"
        )
        static let toolCreateFile = String(
            localized: "agent-notification.tool.create-file",
            defaultValue: "Create file"
        )
        static let toolApplyPatch = String(
            localized: "agent-notification.tool.apply-patch",
            defaultValue: "Apply patch"
        )
        static let toolFetchWebpage = String(
            localized: "agent-notification.tool.fetch-webpage",
            defaultValue: "Fetch webpage"
        )
        static let toolBrowserControl = String(
            localized: "agent-notification.tool.browser-control",
            defaultValue: "Control browser"
        )
        static let toolComputerUse = String(
            localized: "agent-notification.tool.computer-use",
            defaultValue: "Use computer"
        )
        static let toolAskUser = String(
            localized: "agent-notification.tool.ask-user",
            defaultValue: "Answer Agent question"
        )

        static func toolWithFile(_ tool: String, fileName: String) -> String {
            let template = String(
                localized: "agent-notification.tool-with-file",
                defaultValue: "%1$@ · %2$@"
            )
            return String(format: template, tool, fileName)
        }
    }
}
