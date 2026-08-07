//
//  L10n+AgentDelegation.swift
//  WillDeep
//
//  Strings for the `/subagent` and `/no-subagent` per-turn delegation
//  controls and the subagent detail inspector.
//

import Foundation

extension L10n {
    enum AgentDelegation {
        // MARK: Slash commands

        static let subagentCommandSubtitle = String(
            localized: "agent-delegation.subagent-command-subtitle",
            defaultValue: "Send this turn with delegation to subagents required"
        )
        static let subagentCommandPlaceholder = String(
            localized: "agent-delegation.subagent-command-placeholder",
            defaultValue: "<what the subagents should investigate>"
        )
        static let noSubagentCommandSubtitle = String(
            localized: "agent-delegation.no-subagent-command-subtitle",
            defaultValue: "Send this turn with spawn_agent removed from the tool set"
        )
        static let noSubagentCommandPlaceholder = String(
            localized: "agent-delegation.no-subagent-command-placeholder",
            defaultValue: "<what the main agent should do alone>"
        )

        // MARK: Transcript markers

        static let markerRequired = String(
            localized: "agent-delegation.marker-required",
            defaultValue: "Subagents required"
        )
        static let markerForbidden = String(
            localized: "agent-delegation.marker-forbidden",
            defaultValue: "Subagents disabled"
        )
        /// Shown when `/subagent` was used but the model never delegated.
        /// This is an audit signal, not an error — see AgentDelegationPolicy.
        static let markerRequiredNotHonored = String(
            localized: "agent-delegation.marker-required-not-honored",
            defaultValue: "Subagents required · none spawned"
        )

        // MARK: Subagent inspector

        static let inspectorTitle = String(
            localized: "agent-delegation.inspector-title",
            defaultValue: "Subagent run"
        )
        static let inspectorEmpty = String(
            localized: "agent-delegation.inspector-empty",
            defaultValue: "No recorded activity for this run."
        )
        static let inspectorPrompt = String(
            localized: "agent-delegation.inspector-prompt",
            defaultValue: "Prompt"
        )
        static let inspectorReport = String(
            localized: "agent-delegation.inspector-report",
            defaultValue: "Final report"
        )
        static let inspectorReasoning = String(
            localized: "agent-delegation.inspector-reasoning",
            defaultValue: "Reasoning"
        )
        static let inspectorToolResult = String(
            localized: "agent-delegation.inspector-tool-result",
            defaultValue: "Result"
        )
        static let inspectorArguments = String(
            localized: "agent-delegation.inspector-arguments",
            defaultValue: "Arguments"
        )
        static func inspectorRound(_ a1: String) -> String {
            let template = String(
                localized: "agent-delegation.inspector-round",
                defaultValue: "Round %@"
            )
            return String(format: template, a1)
        }
        static func inspectorStats(_ a1: String, _ a2: String, _ a3: String) -> String {
            let template = String(
                localized: "agent-delegation.inspector-stats",
                defaultValue: "%@ rounds · %@ tool calls · %@ tokens"
            )
            return String(format: template, a1, a2, a3)
        }
        static let inspectorTruncated = String(
            localized: "agent-delegation.inspector-truncated",
            defaultValue: "Output truncated for storage."
        )

        // MARK: Subagent profiles (trades)

        static let profileScoutName = String(
            localized: "agent-delegation.profile-scout-name",
            defaultValue: "Scout"
        )
        static let profileReaderName = String(
            localized: "agent-delegation.profile-reader-name",
            defaultValue: "Reader"
        )
        static let profileDeepName = String(
            localized: "agent-delegation.profile-deep-name",
            defaultValue: "Deep"
        )
        static let profileEditorName = String(
            localized: "agent-delegation.profile-editor-name",
            defaultValue: "Editor"
        )

        static let profilesSectionTitle = String(
            localized: "agent-delegation.profiles-section-title",
            defaultValue: "Subagent trades"
        )
        static let profilesSectionFooter = String(
            localized: "agent-delegation.profiles-section-footer",
            defaultValue: "Each trade runs on its own model with a narrowed tool set. Tool sets are fixed; only the model binding is configurable."
        )
        static let profileInheritsParent = String(
            localized: "agent-delegation.profile-inherits-parent",
            defaultValue: "Same as this chat"
        )
        static let profileToolsLabel = String(
            localized: "agent-delegation.profile-tools-label",
            defaultValue: "Tools"
        )
        static let profileModelLabel = String(
            localized: "agent-delegation.profile-model-label",
            defaultValue: "Model"
        )
        static let profileUnavailableFallback = String(
            localized: "agent-delegation.profile-unavailable-fallback",
            defaultValue: "Unavailable — falls back to this chat's model"
        )

        // MARK: Escalation

        static func escalatedFrom(_ a1: String) -> String {
            let template = String(
                localized: "agent-delegation.escalated-from",
                defaultValue: "Escalated from %@ to this chat's model"
            )
            return String(format: template, a1)
        }
        static func inspectorProfile(_ a1: String) -> String {
            let template = String(
                localized: "agent-delegation.inspector-profile",
                defaultValue: "Trade: %@"
            )
            return String(format: template, a1)
        }

        // MARK: Editor trade

        static func editorApprovalTitle(_ a1: String) -> String {
            let template = String(
                localized: "agent-delegation.editor-approval-title",
                defaultValue: "Let a subagent edit %@?"
            )
            return String(format: template, a1)
        }
        static let editorTargetLocked = String(
            localized: "agent-delegation.editor-target-locked",
            defaultValue: "Another subagent is already editing this file."
        )
    }
}
