//
//  L10n+AgentRuntimeKernel.swift
//  WillDeep
//

import Foundation

extension L10n {
    enum RuntimeEvents {
        static let sectionTitle = String(localized: "runtime-events.section-title", defaultValue: "Event Center", table: "RuntimeEvents")
        static let empty = String(localized: "runtime-events.empty", defaultValue: "No runtime events in this session", table: "RuntimeEvents")
        static let needsAction = String(localized: "runtime-events.needs-action", defaultValue: "Needs action", table: "RuntimeEvents")
        static let deliveringToMainAgent = String(localized: "runtime-events.delivering-to-main-agent", defaultValue: "Delivering to main Agent", table: "RuntimeEvents")
        static let processedByMainAgent = String(localized: "runtime-events.processed-by-main-agent", defaultValue: "Processed by main Agent", table: "RuntimeEvents")
        static let dismissedByUser = String(localized: "runtime-events.dismissed-by-user", defaultValue: "Dismissed by you", table: "RuntimeEvents")
        static let resolvedAtSource = String(localized: "runtime-events.resolved-at-source", defaultValue: "Resolved in conversation", table: "RuntimeEvents")
        static let dismiss = String(localized: "runtime-events.dismiss", defaultValue: "Dismiss event", table: "RuntimeEvents")
        static let handledInConversation = String(localized: "runtime-events.handled-in-conversation", defaultValue: "Handle this request in the conversation", table: "RuntimeEvents")
        static let orchestratorTitle = String(localized: "runtime-events.orchestrator-title", defaultValue: "Event Orchestrator", table: "RuntimeEvents")
        static let planReview = String(localized: "runtime-events.plan-review", defaultValue: "Plan review", table: "RuntimeEvents")
        static let journalSaveFailed = String(localized: "runtime-events.journal-save-failed", defaultValue: "Failed to save the runtime event journal. Incoming events may be replayed after relaunch; check free disk space and folder permissions.", table: "RuntimeEvents")

        static func occurrences(_ count: Int) -> String {
            String(
                format: String(localized: "runtime-events.occurrences", defaultValue: "%lld occurrences", table: "RuntimeEvents"),
                Int64(count)
            )
        }

        static func source(_ source: AgentKernelEventSource) -> String {
            switch source {
            case .user: return String(localized: "runtime-events.source.user", defaultValue: "User", table: "RuntimeEvents")
            case .worker: return String(localized: "runtime-events.source.worker", defaultValue: "Worker", table: "RuntimeEvents")
            case .terminal: return String(localized: "runtime-events.source.terminal", defaultValue: "Terminal", table: "RuntimeEvents")
            case .backgroundJob: return String(localized: "runtime-events.source.job", defaultValue: "Job", table: "RuntimeEvents")
            case .mediaTask: return String(localized: "runtime-events.source.media", defaultValue: "Media", table: "RuntimeEvents")
            case .workflow: return String(localized: "runtime-events.source.workflow", defaultValue: "Workflow", table: "RuntimeEvents")
            case .webhook: return String(localized: "runtime-events.source.webhook", defaultValue: "Webhook", table: "RuntimeEvents")
            case .email: return String(localized: "runtime-events.source.email", defaultValue: "Email", table: "RuntimeEvents")
            case .connector: return String(localized: "runtime-events.source.connector", defaultValue: "Connector", table: "RuntimeEvents")
            case .timer: return String(localized: "runtime-events.source.timer", defaultValue: "Timer", table: "RuntimeEvents")
            case .fileSystem: return String(localized: "runtime-events.source.files", defaultValue: "Files", table: "RuntimeEvents")
            case .approval: return String(localized: "runtime-events.source.approval", defaultValue: "Approval", table: "RuntimeEvents")
            case .system: return String(localized: "runtime-events.source.system", defaultValue: "System", table: "RuntimeEvents")
            }
        }

        static func handlingStatus(_ event: AgentKernelEvent) -> String? {
            if event.isAwaitingUserAction { return needsAction }
            if event.isLeasedForModel { return deliveringToMainAgent }
            switch event.resolutionOutcome {
            case .processedByModel: return processedByMainAgent
            case .dismissedByUser: return dismissedByUser
            case .resolvedAtSource: return resolvedAtSource
            case nil: return nil
            }
        }
    }
}
