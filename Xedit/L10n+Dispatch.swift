//
//  L10n+Dispatch.swift
//  WillDeep
//

import Foundation

extension L10n {
    enum Dispatch {
        static let navigationTitle = String(
            localized: "dispatch.navigation-title",
            defaultValue: "Orchestrator"
        )
        static let goalsHeader = String(
            localized: "dispatch.goals-header",
            defaultValue: "Goals"
        )
        static let environmentsHeader = String(
            localized: "dispatch.environments-header",
            defaultValue: "Execution Environments"
        )
        static let localEnvironment = String(
            localized: "dispatch.local-environment",
            defaultValue: "This Mac"
        )
        static let ready = String(localized: "dispatch.ready", defaultValue: "Ready")
        static let probed = String(localized: "dispatch.probed", defaultValue: "Probed")
        static let notProbed = String(localized: "dispatch.not-probed", defaultValue: "Not probed")
        static let addSSH = String(localized: "dispatch.add-ssh", defaultValue: "Add SSH")
        static let emptyTitle = String(
            localized: "dispatch.empty-title",
            defaultValue: "No active Goals yet"
        )
        static let emptyMessage = String(
            localized: "dispatch.empty-message",
            defaultValue: "Create a Goal in a conversation. WillDeep will project its checklist here as an executable plan."
        )
        static let openConversation = String(
            localized: "dispatch.open-conversation",
            defaultValue: "Start a Goal conversation"
        )
        static let addWorkspaceMapping = String(
            localized: "dispatch.add-workspace-mapping",
            defaultValue: "Add checkout mapping"
        )
        static let bindWorkspace = String(
            localized: "dispatch.bind-workspace",
            defaultValue: "Bind Workspace"
        )
        static let chooseLocalWorkspace = String(
            localized: "dispatch.choose-local-workspace",
            defaultValue: "Choose local folder…"
        )
        static let chooseWorkspace = String(
            localized: "dispatch.choose-workspace",
            defaultValue: "Choose Goal Workspace"
        )
        static let chooseWorkspaceAction = String(
            localized: "dispatch.choose-workspace-action",
            defaultValue: "Choose"
        )
        static let chooseWorkspaceMessage = String(
            localized: "dispatch.choose-workspace-message",
            defaultValue: "A Goal must belong to a workspace before it can run."
        )
        static let chooseWorkspaceAndStart = String(
            localized: "dispatch.choose-workspace-and-start",
            defaultValue: "Choose Workspace and Start"
        )
        static let goalWorkspace = String(
            localized: "dispatch.goal-workspace",
            defaultValue: "Goal Workspace"
        )
        static let mapWorkspaceMessage = String(
            localized: "dispatch.map-workspace-message",
            defaultValue: "Choose a checkout of the same project for this Goal."
        )
        static let remoteWorkspaceUnavailable = String(
            localized: "dispatch.remote-workspace-unavailable",
            defaultValue: "The selected SSH workspace is unavailable."
        )
        static let workspaceBindingFailed = String(
            localized: "dispatch.workspace-binding-failed",
            defaultValue: "Couldn’t bind workspace"
        )
        static let workspaceBusy = String(
            localized: "dispatch.workspace-busy",
            defaultValue: "Stop the current Goal turn before binding its workspace."
        )
        static let workspaceMappingHelp = String(
            localized: "dispatch.workspace-mapping-help",
            defaultValue: "Only map checkouts of the same project."
        )
        static let workspaceMappingRequired = String(
            localized: "dispatch.workspace-mapping-required",
            defaultValue: "Map a workspace for this execution environment before launching the task."
        )
        static let workspaceMissing = String(
            localized: "dispatch.workspace-missing",
            defaultValue: "The selected local workspace no longer exists."
        )
        static let workspaceRequired = String(
            localized: "dispatch.workspace-required",
            defaultValue: "Bind this Goal to a workspace before continuing."
        )
        static let workspaceRequiredShort = String(
            localized: "dispatch.workspace-required-short",
            defaultValue: "Workspace required"
        )
        static let addTask = String(localized: "dispatch.add-task", defaultValue: "Add Task")
        static let startPlan = String(localized: "dispatch.start-plan", defaultValue: "Start Plan")
        static let resumePlan = String(localized: "dispatch.resume-plan", defaultValue: "Resume Plan")
        static let paused = String(localized: "dispatch.paused", defaultValue: "Paused")
        static let executor = String(localized: "dispatch.executor", defaultValue: "Executor")
        static let environment = String(localized: "dispatch.environment", defaultValue: "Environment")
        static let automatic = String(localized: "dispatch.automatic", defaultValue: "Automatic")
        static let automaticExecutor = String(
            localized: "dispatch.automatic-executor",
            defaultValue: "Executor: Automatic"
        )
        static let automaticEnvironment = String(
            localized: "dispatch.automatic-environment",
            defaultValue: "Environment: Automatic"
        )
        static let forceExecutor = String(
            localized: "dispatch.force-executor",
            defaultValue: "Force executor"
        )
        static let useAutomatic = String(
            localized: "dispatch.use-automatic",
            defaultValue: "Use automatic selection"
        )
        static let currentMac = String(localized: "dispatch.current-mac", defaultValue: "This Mac")
        static let selectedTask = String(localized: "dispatch.selected-task", defaultValue: "Selected Task")
        static let status = String(localized: "dispatch.status", defaultValue: "Status")
        static let branchAndWorkspace = String(
            localized: "dispatch.branch-workspace",
            defaultValue: "Branch & Workspace"
        )
        static let branch = String(localized: "dispatch.branch", defaultValue: "Branch")
        static let workspace = String(localized: "dispatch.workspace", defaultValue: "Workspace")
        static let acceptance = String(localized: "dispatch.acceptance", defaultValue: "Acceptance")
        static let defaultAcceptanceCriterion = String(
            localized: "dispatch.default-acceptance",
            defaultValue: "Task evidence passes independent review"
        )
        static let availableExecutors = String(
            localized: "dispatch.available-executors",
            defaultValue: "Available executors"
        )
        static let launchTask = String(localized: "dispatch.launch-task", defaultValue: "Launch Task")
        static let openTaskConversation = String(
            localized: "dispatch.open-task-conversation",
            defaultValue: "Open Task Conversation"
        )
        static let waitingForDependencies = String(
            localized: "dispatch.waiting-dependencies",
            defaultValue: "Waiting for dependencies"
        )
        static let goalCommandTitle = String(
            localized: "dispatch.goal-command-title",
            defaultValue: "Send an instruction to this Goal"
        )
        static let goalCommandPlaceholder = String(
            localized: "dispatch.goal-command-placeholder",
            defaultValue: "For example: let Codex run regression tests first, then ask Claude to review"
        )
        static let send = String(localized: "dispatch.send", defaultValue: "Send")
        static let adjustPlan = String(localized: "dispatch.adjust-plan", defaultValue: "Adjust Plan")
        static let pauseAll = String(localized: "dispatch.pause-all", defaultValue: "Pause All")
        static let resumeAll = String(localized: "dispatch.resume-all", defaultValue: "Resume All")
        static let recentInstructions = String(
            localized: "dispatch.recent-instructions",
            defaultValue: "Recent instructions"
        )
        static let noRecentInstructions = String(
            localized: "dispatch.no-recent-instructions",
            defaultValue: "No Goal instructions yet"
        )
        static let appliedImmediately = String(
            localized: "dispatch.applied-immediately",
            defaultValue: "Applied immediately"
        )
        static let queuedForSafePoint = String(
            localized: "dispatch.queued-safe-point",
            defaultValue: "Queued · applies after the current step"
        )
        static let interruptRequired = String(
            localized: "dispatch.interrupt-required",
            defaultValue: "Confirmation required · current execution will be interrupted"
        )
        static let cancelled = String(localized: "dispatch.cancelled", defaultValue: "Cancelled")
        static let interruptTitle = String(
            localized: "dispatch.interrupt-title",
            defaultValue: "Interrupt the current Goal execution?"
        )
        static let interruptMessage = String(
            localized: "dispatch.interrupt-message",
            defaultValue: "WillDeep will preserve existing output, stop the current round, and apply the new instruction next."
        )
        static let interruptNow = String(
            localized: "dispatch.interrupt-now",
            defaultValue: "Interrupt Now"
        )
        static let keepRunning = String(
            localized: "dispatch.keep-running",
            defaultValue: "Keep Running"
        )
        static let launchFailed = String(
            localized: "dispatch.launch-failed",
            defaultValue: "Unable to launch task"
        )
        static let noExecutorOnTarget = String(
            localized: "dispatch.no-executor-target",
            defaultValue: "The forced executor is not available in this execution environment."
        )
        static let goalPausedLaunch = String(
            localized: "dispatch.goal-paused-launch",
            defaultValue: "Resume this Goal before launching another task."
        )
        static let taskStarted = String(
            localized: "dispatch.task-started",
            defaultValue: "Task started"
        )
        static let acceptanceGate = String(
            localized: "dispatch.acceptance-gate",
            defaultValue: "Acceptance Gate"
        )

        static func taskCount(_ count: Int) -> String {
            String(
                localized: "dispatch.task-count",
                defaultValue: "\(count) tasks"
            )
        }

        static func activeCount(_ count: Int) -> String {
            String(
                localized: "dispatch.active-count",
                defaultValue: "\(count) active"
            )
        }

        static func remoteRuntimeSuffix(_ count: Int) -> String {
            String(
                localized: "dispatch.remote-runtime-suffix",
                defaultValue: "+ \(count) SSH"
            )
        }

        static func automaticResolved(_ name: String) -> String {
            String(
                localized: "dispatch.automatic-resolved",
                defaultValue: "Automatic → \(name)"
            )
        }

        static func executorReason(_ reason: AgentDispatchExecutorReason) -> String {
            switch reason {
            case .userPinned:
                return String(localized: "dispatch.reason-pinned", defaultValue: "Pinned by you")
            case .testAndSearchFit:
                return String(
                    localized: "dispatch.reason-test-search",
                    defaultValue: "Best match for tests and repository search"
                )
            case .refactorAndArchitectureFit:
                return String(
                    localized: "dispatch.reason-refactor",
                    defaultValue: "Best match for cross-file architecture work"
                )
            case .localFallback:
                return String(
                    localized: "dispatch.reason-fallback",
                    defaultValue: "Available now with the current workspace context"
                )
            case .onlyAvailable:
                return String(
                    localized: "dispatch.reason-only",
                    defaultValue: "Only available executor in this environment"
                )
            }
        }

        static func state(_ state: AgentDispatchTaskState) -> String {
            switch state {
            case .blocked: return String(localized: "dispatch.state-blocked", defaultValue: "Blocked")
            case .queued: return String(localized: "dispatch.state-queued", defaultValue: "Queued")
            case .running: return String(localized: "dispatch.state-running", defaultValue: "Running")
            case .reviewing: return String(localized: "dispatch.state-reviewing", defaultValue: "Reviewing")
            case .accepted: return String(localized: "dispatch.state-accepted", defaultValue: "Accepted")
            case .failed: return String(localized: "dispatch.state-failed", defaultValue: "Failed")
            case .cancelled: return String(localized: "dispatch.state-cancelled", defaultValue: "Cancelled")
            case .merged: return String(localized: "dispatch.state-merged", defaultValue: "Merged")
            }
        }
    }
}
