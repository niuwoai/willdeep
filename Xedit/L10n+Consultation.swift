import Foundation

extension L10n {
    enum Consultation {
        static let title = String(localized: "consultation.title", defaultValue: "Multi-Expert Consultation")
        static let chairName = String(localized: "consultation.chair-name", defaultValue: "WillDeep Chair")
        static let buttonHelp = String(localized: "consultation.button-help", defaultValue: "Open multi-expert consultation or roundtable chat")
        static let setupTitle = String(localized: "consultation.setup-title", defaultValue: "Multi-Expert Consultation")
        static let setupDescription = String(localized: "consultation.setup-description", defaultValue: "WillDeep drafts first; selected experts review independently, challenge each other once, and WillDeep writes the final synthesis. All external rounds are read-only.")
        static let setupOverview = String(localized: "consultation.setup-overview", defaultValue: "Choose a discussion style and at least two local experts. All external expert turns are read-only.")
        static let modeLabel = String(localized: "consultation.mode-label", defaultValue: "Mode")
        static let structuredMode = String(localized: "consultation.mode.structured", defaultValue: "Structured consultation")
        static let groupChatMode = String(localized: "consultation.mode.group-chat", defaultValue: "Roundtable chat")
        static let structuredDescription = String(localized: "consultation.mode.structured-description", defaultValue: "Parallel independent review, one peer-review round, then WillDeep synthesis.")
        static let groupChatDescription = String(localized: "consultation.mode.group-chat-description", defaultValue: "Experts speak in turn and see the full conversation; WillDeep moderates between rounds.")
        static let groupRounds = String(localized: "consultation.group-rounds", defaultValue: "Chat rounds")
        static let groupChatTitle = String(localized: "consultation.group-chat-title", defaultValue: "Expert Roundtable")
        static let groupOpeningLabel = String(localized: "consultation.group-opening-label", defaultValue: "Opening")
        static let taskLabel = String(localized: "consultation.task-label", defaultValue: "Consultation topic")
        static let expertsLabel = String(localized: "consultation.experts-label", defaultValue: "Experts")
        static let modelPlaceholder = String(localized: "consultation.model-placeholder", defaultValue: "Model ID (optional; blank uses CLI default)")
        static let useCLIDefaultModel = String(localized: "consultation.model.use-cli-default", defaultValue: "Use CLI default model")
        static let installed = String(localized: "consultation.installed", defaultValue: "Installed")
        static let notInstalled = String(localized: "consultation.not-installed", defaultValue: "CLI not installed")
        static let readOnlyBadge = String(localized: "consultation.read-only", defaultValue: "External experts are read-only")
        static let cancel = String(localized: "consultation.cancel", defaultValue: "Cancel")
        static let start = String(localized: "consultation.start", defaultValue: "Start consultation")
        static let startGroupChat = String(localized: "consultation.start-group-chat", defaultValue: "Start roundtable")
        static let stop = String(localized: "consultation.stop", defaultValue: "Stop")
        static let copyFinal = String(localized: "consultation.copy-final", defaultValue: "Copy final conclusion")
        static let taskRequired = String(localized: "consultation.error.task-required", defaultValue: "Enter a consultation topic first.")
        static let twoExpertsRequired = String(localized: "consultation.error.two-experts", defaultValue: "Select at least two installed experts.")
        static let alreadyRunning = String(localized: "consultation.error.already-running", defaultValue: "A consultation is already running.")
        static let interrupted = String(localized: "consultation.interrupted", defaultValue: "This consultation was interrupted when the previous app session ended.")
        static let initialDraft = String(localized: "consultation.section.initial-draft", defaultValue: "WillDeep initial draft")
        static let firstRound = String(localized: "consultation.section.first-round", defaultValue: "Independent reviews")
        static let preliminary = String(localized: "consultation.section.preliminary", defaultValue: "Chair's preliminary synthesis")
        static let peerRound = String(localized: "consultation.section.peer-round", defaultValue: "Second-round peer review")
        static let finalConclusion = String(localized: "consultation.section.final", defaultValue: "Final conclusion")
        static let pending = String(localized: "consultation.status.pending", defaultValue: "Pending")
        static let reviewing = String(localized: "consultation.status.reviewing", defaultValue: "Reviewing")
        static let completed = String(localized: "consultation.status.completed", defaultValue: "Completed")
        static let failedStatus = String(localized: "consultation.status.failed", defaultValue: "Failed")
        static let cancelledStatus = String(localized: "consultation.status.cancelled", defaultValue: "Cancelled")

        static func role(_ kind: AgentConsultationExpertKind) -> String {
            switch kind {
            case .claudeCode:
                return String(localized: "consultation.role.claude", defaultValue: "Architecture, assumptions, edge cases, maintainability, and safety")
            case .codexCLI:
                return String(localized: "consultation.role.codex", defaultValue: "Implementation correctness, repository evidence, tests, and regressions")
            case .cursorAgent:
                return String(localized: "consultation.role.cursor", defaultValue: "Alternative solutions, product usability, integration cost, and delivery")
            }
        }

        static func progress(_ done: Int, _ total: Int) -> String {
            let template = String(localized: "consultation.progress", defaultValue: "%1$d/%2$d experts")
            return String(format: template, done, total)
        }

        static func roundProgress(_ current: Int, _ total: Int) -> String {
            let template = String(localized: "consultation.round-progress", defaultValue: "Round %1$d/%2$d")
            return String(format: template, current, total)
        }

        static func roundLabel(_ round: Int) -> String {
            let template = String(localized: "consultation.round-label", defaultValue: "Round %d")
            return String(format: template, round)
        }

        static func groupRoundsValue(_ rounds: Int) -> String {
            let template = String(localized: "consultation.group-rounds-value", defaultValue: "Chat rounds: %d")
            return String(format: template, rounds)
        }

        static func modeName(_ mode: AgentConsultationMode) -> String {
            mode == .structured ? structuredMode : groupChatMode
        }

        static func modeDescription(_ mode: AgentConsultationMode) -> String {
            mode == .structured ? structuredDescription : groupChatDescription
        }

        static func modelPickerHelp(_ expertName: String) -> String {
            let template = String(localized: "consultation.model-picker-help", defaultValue: "Choose a suggested %@ model ID")
            return String(format: template, expertName)
        }

        static func failed(_ reason: String) -> String {
            let template = String(localized: "consultation.failed", defaultValue: "Consultation failed: %@")
            return String(format: template, reason)
        }

        static func phase(_ phase: AgentConsultationReport.Phase) -> String {
            switch phase {
            case .preparingDraft:
                return String(localized: "consultation.phase.draft", defaultValue: "WillDeep is preparing the initial draft")
            case .independentReview:
                return String(localized: "consultation.phase.independent", defaultValue: "Experts are reviewing independently")
            case .preliminarySynthesis:
                return String(localized: "consultation.phase.preliminary", defaultValue: "WillDeep is reconciling first-round opinions")
            case .peerReview:
                return String(localized: "consultation.phase.peer", defaultValue: "Experts are challenging each other")
            case .groupOpening:
                return String(localized: "consultation.phase.group-opening", defaultValue: "WillDeep is opening the roundtable")
            case .groupDiscussion:
                return String(localized: "consultation.phase.group-discussion", defaultValue: "Experts are speaking in turn")
            case .groupModeration:
                return String(localized: "consultation.phase.group-moderation", defaultValue: "WillDeep is moderating the round")
            case .finalSynthesis:
                return String(localized: "consultation.phase.final", defaultValue: "WillDeep is writing the final conclusion")
            case .completed: return completed
            case .failed: return failedStatus
            case .cancelled: return cancelledStatus
            }
        }
    }
}
