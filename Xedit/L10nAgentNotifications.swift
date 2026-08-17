//
//  L10nAgentNotifications.swift
//  WillDeep
//
//  Agent notification copy split from the core localization catalogue.
//

import Foundation

extension L10n {
    enum AgentNotifications {
        enum Settings {
            static let tabTitle = String(localized: "agent-notification.settings.tab", defaultValue: "Notifications")
            static let soundSection = String(localized: "agent-notification.settings.sound-section", defaultValue: "Background notification sound")
            static let soundLabel = String(localized: "agent-notification.settings.sound-label", defaultValue: "Sound")
            static let soundNone = String(localized: "agent-notification.settings.sound-none", defaultValue: "None")
            static let soundSystemDefault = String(localized: "agent-notification.settings.sound-system-default", defaultValue: "System default")
            static let soundCustom = String(localized: "agent-notification.settings.sound-custom", defaultValue: "Custom audio")
            static let previewSound = String(localized: "agent-notification.settings.preview-sound", defaultValue: "Preview")
            static let chooseAudio = String(localized: "agent-notification.settings.choose-audio", defaultValue: "Choose audio…")
            static let noAudioSelected = String(localized: "agent-notification.settings.no-audio-selected", defaultValue: "No audio selected")
            static let audioEmpty = String(localized: "agent-notification.settings.audio-empty", defaultValue: "The selected audio file is empty or unreadable.")
            static let audioTooLong = String(localized: "agent-notification.settings.audio-too-long", defaultValue: "Notification sounds must be 30 seconds or shorter.")
            static let soundHelp = String(localized: "agent-notification.settings.sound-help", defaultValue: "Used when WillDeep needs authorization, confirmation, or an answer while it is in the background. Custom MP3, AIFF, WAV, CAF, and M4A files are converted to a system-compatible notification sound.")
            static let webhookSection = String(localized: "agent-notification.settings.webhook-section", defaultValue: "Webhook")
            static let webhookEnabled = String(localized: "agent-notification.settings.webhook-enabled", defaultValue: "Send webhook events")
            static let webhookURL = String(localized: "agent-notification.settings.webhook-url", defaultValue: "Webhook URL")
            static let webhookOnTaskCompleted = String(localized: "agent-notification.settings.webhook-task-completed", defaultValue: "External executor task completed")
            static let webhookOnAttentionRequired = String(localized: "agent-notification.settings.webhook-attention-required", defaultValue: "Authorization, confirmation, or answer required")
            static let webhookPrivacyHelp = String(localized: "agent-notification.settings.webhook-privacy-help", defaultValue: "Webhook payloads include only event metadata, session title, executor, status, and time. Commands, model output, and your answers are not sent.")
            static let save = String(localized: "agent-notification.settings.save", defaultValue: "Save")
            static let saved = String(localized: "agent-notification.settings.saved", defaultValue: "Saved")
            static let testWebhook = String(localized: "agent-notification.settings.test-webhook", defaultValue: "Send test")
            static let webhookTestSucceeded = String(localized: "agent-notification.settings.webhook-test-succeeded", defaultValue: "Test delivered")
            static let webhookInvalidURL = String(localized: "agent-notification.settings.webhook-invalid-url", defaultValue: "Enter a valid HTTP or HTTPS webhook URL.")
        }

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
