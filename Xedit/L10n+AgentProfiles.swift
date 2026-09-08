import Foundation

// Strings for the unified agent profile settings pane (subagent trades +
// dispatch execution profiles). Split out of L10n.swift to keep that façade
// under the 3000-line guard.
extension L10n {
    nonisolated enum AgentProfiles {
        static let generalTab = String(localized: "agent-profiles.general-tab", defaultValue: "General")
        static let responsibilitiesTab = String(localized: "agent-profiles.responsibilities-tab", defaultValue: "Responsibilities")
        static let toolsTab = String(localized: "agent-profiles.tools-tab", defaultValue: "Tool permissions")
        static let searchPlaceholder = String(localized: "agent-profiles.search", defaultValue: "Search profiles")
        static let autoSaved = String(localized: "agent-profiles.auto-saved", defaultValue: "Changes are saved automatically")
        static let sharedModels = String(localized: "agent-profiles.shared-models", defaultValue: "Shared model tiers")
        static let builtInInstructions = String(localized: "agent-profiles.builtin-instructions", defaultValue: "Built-in instructions")
        static let restoreInstructions = String(localized: "agent-profiles.restore-instructions", defaultValue: "Restore default instructions")
        static let tabTitle = String(localized: "agent-profiles.tab-title", defaultValue: "Agent profiles")
        static let paneDescription = String(
            localized: "agent-profiles.pane-description",
            defaultValue: "One list for both the trades `spawn_agent` can pick and the executors a dispatch node can run on. A profile carries its own soul: what it is for, its own prompt section, and the skills it preloads."
        )
        static let filterAll = String(localized: "agent-profiles.filter-all", defaultValue: "All")
        static let filterSubagent = String(localized: "agent-profiles.filter-subagent", defaultValue: "Subagents")
        static let filterDispatch = String(localized: "agent-profiles.filter-dispatch", defaultValue: "Dispatch")

        static let originBuiltIn = String(localized: "agent-profiles.origin-built-in", defaultValue: "Built-in")
        static let originManaged = String(localized: "agent-profiles.origin-managed", defaultValue: "Custom")
        static let originDiscovered = String(localized: "agent-profiles.origin-discovered", defaultValue: "Detected")

        static let sectionProfile = String(localized: "agent-profiles.section-profile", defaultValue: "Profile")
        static let sectionModel = String(localized: "agent-profiles.section-model", defaultValue: "Model")
        static let sectionSoul = String(localized: "agent-profiles.section-soul", defaultValue: "Soul")
        static let sectionCapability = String(localized: "agent-profiles.section-capability", defaultValue: "Tools and budget")

        static let fieldName = String(localized: "agent-profiles.field-name", defaultValue: "Name")
        static let fieldUsages = String(localized: "agent-profiles.field-usages", defaultValue: "Used as")
        static let usageSubagent = String(localized: "agent-profiles.usage-subagent", defaultValue: "Subagent trade")
        static let usageDispatch = String(localized: "agent-profiles.usage-dispatch", defaultValue: "Dispatch executor")
        static let fieldExecutor = String(localized: "agent-profiles.field-executor", defaultValue: "Executor")
        static let fieldNativeProfile = String(localized: "agent-profiles.field-native-profile", defaultValue: "CLI profile name")
        static let fieldProvider = String(localized: "agent-profiles.field-provider", defaultValue: "Provider")
        static let fieldModel = String(localized: "agent-profiles.field-model", defaultValue: "Model")
        static let modelPlaceholder = String(localized: "agent-profiles.model-placeholder", defaultValue: "Inherit the parent session")

        static let fieldPurpose = String(localized: "agent-profiles.field-purpose", defaultValue: "What it is for")
        static let purposePlaceholder = String(
            localized: "agent-profiles.purpose-placeholder",
            defaultValue: "One line, in English — the model reads this to choose a trade"
        )
        static let fieldPrompt = String(localized: "agent-profiles.field-prompt", defaultValue: "Its own prompt")
        static let promptNote = String(
            localized: "agent-profiles.prompt-note",
            defaultValue: "Appended after the trade's built-in section. The runner's own rules — read-only boundary, “your final message is the deliverable”, “you cannot ask the user” — are not editable here: they exist because models violated them."
        )
        static let soulExternalNote = String(
            localized: "agent-profiles.soul-external-note",
            defaultValue: "This profile runs on an external CLI, which brings its own harness. Prompt and skills configured here would not be delivered, so they are disabled."
        )
        static let fieldSkills = String(localized: "agent-profiles.field-skills", defaultValue: "Preloaded skills")
        static let skillsEmpty = String(localized: "agent-profiles.skills-empty", defaultValue: "None")
        static let skillsNone = String(localized: "agent-profiles.skills-none", defaultValue: "No skills installed")

        static let capabilityBuiltInNote = String(
            localized: "agent-profiles.capability-built-in-note",
            defaultValue: "A built-in trade's tool set is code, not settings: the narrow tool set is what makes it cheap and accurate. Its budgets are yours to tune. Create a custom profile to choose your own tools."
        )
        static let capabilityExternalNote = String(
            localized: "agent-profiles.capability-external-note",
            defaultValue: "Decided by this CLI's own harness."
        )
        static let fieldTools = String(localized: "agent-profiles.field-tools", defaultValue: "Tools")
        static let fieldMaxRounds = String(localized: "agent-profiles.field-max-rounds", defaultValue: "Max rounds")
        static let fieldContextWindow = String(
            localized: "agent-profiles.field-context-window",
            defaultValue: "Max context"
        )
        static let contextWindowInherits = String(
            localized: "agent-profiles.context-window-inherits",
            defaultValue: "Inherit"
        )
        static let contextWindowNote = String(
            localized: "agent-profiles.context-window-note",
            defaultValue: "Tokens this trade may fill before its payload is trimmed. Leave empty to use the trade's default. This is a budget, not a claim about the model: setting it above what the model accepts produces provider overflow errors."
        )
        static func maxRoundsNote(_ minimum: Int, _ maximum: Int) -> String {
            let template = String(
                localized: "agent-profiles.max-rounds-note",
                defaultValue: "How many tool rounds the worker may take before it must report. %1$d–%2$d; leave empty for the trade's default."
            )
            return String(format: template, minimum, maximum)
        }
        static let fieldPayloadLimit = String(localized: "agent-profiles.field-payload-limit", defaultValue: "Tool output limit")
        static let writeAccessNote = String(
            localized: "agent-profiles.write-access-note",
            defaultValue: "Write access belongs to the built-in editor trade only, gated by per-file approval and a lock."
        )

        static let addProfile = String(localized: "agent-profiles.add", defaultValue: "New profile")
        static let newProfileName = String(localized: "agent-profiles.new-name", defaultValue: "New profile")
        static let deleteProfile = String(localized: "agent-profiles.delete", defaultValue: "Delete profile")
        static let deleteTitle = String(localized: "agent-profiles.delete-title", defaultValue: "Delete this profile?")
        static func deleteMessage(_ a1: String) -> String {
            let template = String(
                localized: "agent-profiles.delete-message",
                defaultValue: "“%@” will stop being offered to spawn_agent and to dispatch nodes. Nodes already assigned to it fall back to the default trade."
            )
            return String(format: template, a1)
        }
        static let emptySelection = String(
            localized: "agent-profiles.empty-selection",
            defaultValue: "Select a profile to edit it."
        )
        static func workerModelRecommended(_ a1: String) -> String {
            let template = String(
                localized: "agent-profiles.hosted-model-recommended",
                defaultValue: "Recommended: %@"
            )
            return String(format: template, a1)
        }
        static func workerModelUsingRecommended(_ a1: String) -> String {
            let template = String(
                localized: "agent-profiles.local-prompt-model-recommended",
                defaultValue: "Leave empty to run on %@, or enter another model. WillDeep always sends this trade's instructions.",
                table: "WorkerModelPrompts"
            )
            return String(format: template, a1)
        }
        static let workerModelOverridden = String(
            localized: "agent-profiles.local-prompt-model-overridden",
            defaultValue: "Using a custom model. This trade's instructions and tool permissions stay unchanged.",
            table: "WorkerModelPrompts"
        )
    }
}
