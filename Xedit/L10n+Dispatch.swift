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
            defaultValue: "Projects"
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
            defaultValue: "No dispatch projects yet"
        )
        static let emptyMessage = String(
            localized: "dispatch.empty-message",
            defaultValue: "Create a project here. WillDeep will turn its outcome and acceptance criteria into an executable task graph."
        )
        static let openConversation = String(
            localized: "dispatch.open-conversation",
            defaultValue: "Create a dispatch project"
        )
        static let goalSetupTitle = String(
            localized: "dispatch.goal-setup-title",
            defaultValue: "Define this project"
        )
        static let goalSetupMessage = String(
            localized: "dispatch.goal-setup-message",
            defaultValue: "Describe the outcome and acceptance criteria. WillDeep will turn them into an executable plan here."
        )
        static let goalAssessmentAction = String(
            localized: "dispatch.goal-assessment-action",
            defaultValue: "Ask AI to check the goal and draft acceptance criteria"
        )
        static let goalAssessmentAgain = String(
            localized: "dispatch.goal-assessment-again",
            defaultValue: "Check again"
        )
        static let goalAssessmentAnalyzing = String(
            localized: "dispatch.goal-assessment-analyzing",
            defaultValue: "Analyzing the goal…"
        )
        static let goalAssessmentHelp = String(
            localized: "dispatch.goal-assessment-help",
            defaultValue: "AI will front-load missing decisions and fill an editable checklist so execution can run unattended."
        )
        static let goalAssessmentReady = String(
            localized: "dispatch.goal-assessment-ready",
            defaultValue: "This goal can converge"
        )
        static let goalAssessmentNeedsRevision = String(
            localized: "dispatch.goal-assessment-needs-revision",
            defaultValue: "This goal needs a little more focus"
        )
        static let goalAssessmentStale = String(
            localized: "dispatch.goal-assessment-stale",
            defaultValue: "The goal changed — check it again"
        )
        static let goalAssessmentStaleHelp = String(
            localized: "dispatch.goal-assessment-stale-help",
            defaultValue: "The previous diagnosis no longer matches the current goal. Run the check again to refresh it."
        )
        static let goalAssessmentMissingInformation = String(
            localized: "dispatch.goal-assessment-missing-information",
            defaultValue: "Add these decisions"
        )
        static let goalAssessmentSuggestedStatement = String(
            localized: "dispatch.goal-assessment-suggested-statement",
            defaultValue: "Suggested goal statement"
        )
        static let goalAssessmentUseSuggestion = String(
            localized: "dispatch.goal-assessment-use-suggestion",
            defaultValue: "Use this draft"
        )
        static let goalAssessmentCanIgnore = String(
            localized: "dispatch.goal-assessment-can-ignore",
            defaultValue: "This is advice, not a gate. You can ignore it and create the project with the current checklist."
        )
        static func goalAssessmentFailed(_ reason: String) -> String {
            String(
                format: String(
                    localized: "dispatch.goal-assessment-failed",
                    defaultValue: "AI goal check failed: %@"
                ),
                reason
            )
        }
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
        static let chooseRemoteWorkspace = String(
            localized: "dispatch.choose-remote-workspace",
            defaultValue: "Map SSH Checkout"
        )
        static let chooseWorkspace = String(
            localized: "dispatch.choose-workspace",
            defaultValue: "Choose Project Workspace"
        )
        static let chooseWorkspaceAction = String(
            localized: "dispatch.choose-workspace-action",
            defaultValue: "Choose"
        )
        static let chooseWorkspaceMessage = String(
            localized: "dispatch.choose-workspace-message",
            defaultValue: "A project must belong to a workspace before it can run."
        )
        static let chooseWorkspaceAndStart = String(
            localized: "dispatch.choose-workspace-and-start",
            defaultValue: "Choose Workspace and Start"
        )
        static let goalWorkspace = String(
            localized: "dispatch.goal-workspace",
            defaultValue: "Project Workspace"
        )
        static let mapWorkspaceMessage = String(
            localized: "dispatch.map-workspace-message",
            defaultValue: "Choose another checkout of this project."
        )
        static let remoteWorkspaceUnavailable = String(
            localized: "dispatch.remote-workspace-unavailable",
            defaultValue: "The selected SSH workspace is unavailable."
        )
        static let remoteWorkspacePathRequired = String(
            localized: "dispatch.remote-workspace-path-required",
            defaultValue: "Enter the corresponding project directory on this SSH runtime."
        )
        static let workspaceBindingFailed = String(
            localized: "dispatch.workspace-binding-failed",
            defaultValue: "Couldn’t bind workspace"
        )
        static let workspaceBusy = String(
            localized: "dispatch.workspace-busy",
            defaultValue: "Stop the current project turn before binding its workspace."
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
        static let workspaceProjectMismatch = String(
            localized: "dispatch.workspace-project-mismatch",
            defaultValue: "This checkout belongs to a different project."
        )
        static let workspaceRequired = String(
            localized: "dispatch.workspace-required",
            defaultValue: "Bind this project to a workspace before continuing."
        )
        static let workspaceRequiredShort = String(
            localized: "dispatch.workspace-required-short",
            defaultValue: "Workspace required"
        )
        static let selectWorkspaceFirst = String(
            localized: "dispatch.select-workspace-first",
            defaultValue: "Choose a workspace first"
        )
        static let cancel = String(
            localized: "dispatch.cancel",
            defaultValue: "Cancel"
        )
        static let addTask = String(localized: "dispatch.add-task", defaultValue: "Add Task")
        static let createProject = String(
            localized: "dispatch.create-project",
            defaultValue: "Create Project"
        )
        static let startExecution = String(
            localized: "dispatch.start-execution",
            defaultValue: "Start Execution"
        )
        static let planningInProgress = String(
            localized: "dispatch.planning-in-progress",
            defaultValue: "Planning…"
        )
        static let planNotReady = String(
            localized: "dispatch.plan-not-ready",
            defaultValue: "Wait for the planner to produce a validated task graph before launching Workers."
        )
        static let continueExecution = String(
            localized: "dispatch.continue-execution",
            defaultValue: "Continue Execution"
        )
        static let resumeExecution = String(
            localized: "dispatch.resume-execution",
            defaultValue: "Resume Execution"
        )
        static let executionRunning = String(
            localized: "dispatch.execution-running",
            defaultValue: "Execution Running"
        )
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

        static func remoteWorkspaceMessage(
            projectName: String,
            runtimeName: String
        ) -> String {
            String(
                format: String(
                    localized: "dispatch.remote-workspace-message",
                    defaultValue: "Enter the directory where %@ is checked out on %@. This maps an execution checkout; it does not change the project."
                ),
                projectName,
                runtimeName
            )
        }
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
        static let planningModel = String(
            localized: "dispatch.planning-model",
            defaultValue: "Planning model"
        )
        static let executionModel = String(
            localized: "dispatch.execution-model",
            defaultValue: "Execution model"
        )
        static let followCurrentModel = String(
            localized: "dispatch.follow-current-model",
            defaultValue: "Follow current model"
        )
        static let modelRoutingHelp = String(
            localized: "dispatch.model-routing-help",
            defaultValue: "Use different models for project planning and ordinary task execution."
        )
        static let currentExecutionModel = String(
            localized: "dispatch.current-execution-model",
            defaultValue: "Current execution model"
        )
        static let modelUnknown = String(
            localized: "dispatch.model-unknown",
            defaultValue: "Model unknown"
        )
        static let modelSwitchSafePointHelp = String(
            localized: "dispatch.model-switch-safe-point-help",
            defaultValue: "A running request keeps its current model. The selection applies from the next turn."
        )
        static let modelSwitchUnavailableForExecutor = String(
            localized: "dispatch.model-switch-unavailable-for-executor",
            defaultValue: "This executor manages its model in its native profile."
        )
        static func modelSwitchAppliesNextTurn(_ modelID: String) -> String {
            String(
                format: String(
                    localized: "dispatch.model-switch-applies-next-turn",
                    defaultValue: "%@ will be used from the next turn"
                ),
                modelID
            )
        }
        static let profile = String(localized: "dispatch.profile", defaultValue: "Profile")
        static let planningProfile = String(
            localized: "dispatch.planning-profile",
            defaultValue: "Planning Profile"
        )
        static let planningFallbacks = String(
            localized: "dispatch.planning-fallbacks",
            defaultValue: "Planning Fallbacks"
        )
        static let primaryProfile = String(
            localized: "dispatch.primary-profile",
            defaultValue: "Primary Profile"
        )
        static let fallbackProfiles = String(
            localized: "dispatch.fallback-profiles",
            defaultValue: "Fallback Profiles"
        )
        static let manageProfiles = String(
            localized: "dispatch.manage-profiles",
            defaultValue: "Manage Profiles…"
        )
        static let workers = String(
            localized: "dispatch.workers",
            defaultValue: "Workers"
        )
        static let workerPoolHelp = String(
            localized: "dispatch.worker-pool-help",
            defaultValue: "Selected Workers run ready nodes in parallel and provide the automatic failover order."
        )
        static let workerUnavailable = String(
            localized: "dispatch.worker-unavailable",
            defaultValue: "Unavailable"
        )
        static func selectedWorkerCount(_ count: Int) -> String {
            String(
                format: String(
                    localized: "dispatch.selected-worker-count",
                    defaultValue: "%@ Workers"
                ),
                String(count)
            )
        }
        static let profileManagerTitle = String(
            localized: "dispatch.profile-manager-title",
            defaultValue: "Workers & Execution Profiles"
        )
        static let profileManagerMessage = String(
            localized: "dispatch.profile-manager-message",
            defaultValue: "Workers bind WillDeep models or discovered external CLI profiles. Selected Workers execute graph nodes and fail over automatically."
        )
        static let addProfile = String(
            localized: "dispatch.add-profile",
            defaultValue: "Add Profile"
        )
        static let deleteProfile = String(
            localized: "dispatch.delete-profile",
            defaultValue: "Delete Profile"
        )
        static let profileName = String(
            localized: "dispatch.profile-name",
            defaultValue: "Profile name"
        )
        static let modelID = String(
            localized: "dispatch.model-id",
            defaultValue: "Model ID"
        )
        static let providerID = String(
            localized: "dispatch.provider-id",
            defaultValue: "Provider ID"
        )
        static let nativeProfile = String(
            localized: "dispatch.native-profile",
            defaultValue: "Native profile / agent name"
        )
        static let profileManaged = String(
            localized: "dispatch.profile-managed",
            defaultValue: "Managed"
        )
        static let profileDiscovered = String(
            localized: "dispatch.profile-discovered",
            defaultValue: "Discovered"
        )
        static let profileBuiltIn = String(
            localized: "dispatch.profile-built-in",
            defaultValue: "Built in"
        )
        static let humanOverride = String(
            localized: "dispatch.human-override",
            defaultValue: "Human Override"
        )
        static let aiPlansGraph = String(
            localized: "dispatch.ai-plans-graph",
            defaultValue: "AI will choose the nodes, dependencies, primary profiles, and fallback chain."
        )
        static let defaultProfile = String(
            localized: "dispatch.default-profile",
            defaultValue: "Default profile"
        )
        static let openTaskConversation = String(
            localized: "dispatch.open-task-conversation",
            defaultValue: "Open Task Conversation"
        )
        static let openFullTaskConversation = String(
            localized: "dispatch.open-full-task-conversation",
            defaultValue: "Open Full Task Conversation"
        )
        static let returnToDispatchBoard = String(
            localized: "dispatch.return-to-board",
            defaultValue: "Return to the dispatch board"
        )
        static let moreTaskTools = String(
            localized: "dispatch.more-task-tools",
            defaultValue: "More task tools"
        )
        static let takeoverInstructionPlaceholder = String(
            localized: "dispatch.takeover-instruction-placeholder",
            defaultValue: "Send an instruction to the running task…"
        )
        static let sendTakeoverInstruction = String(
            localized: "dispatch.send-takeover-instruction",
            defaultValue: "Send Instruction"
        )
        static let takeoverQueuesAtSafePoint = String(
            localized: "dispatch.takeover-queues-at-safe-point",
            defaultValue: "The instruction will be queued and applied at a safe point."
        )
        static let takeoverStartsNextTurn = String(
            localized: "dispatch.takeover-starts-next-turn",
            defaultValue: "The instruction starts the next task turn."
        )
        static let metricUnavailable = String(
            localized: "dispatch.metric.unavailable",
            defaultValue: "—"
        )
        static let metricUnpricedHelp = String(
            localized: "dispatch.metric.unpriced-help",
            defaultValue: "This executor did not report billable usage or WillDeep has no matching price."
        )

        static func taskConversationProjectBreadcrumb(_ project: String) -> String {
            let template = String(
                localized: "dispatch.task-conversation-project-breadcrumb",
                defaultValue: "Task Graph · %@"
            )
            return String(format: template, project)
        }

        static func metricApproximate(_ value: String) -> String {
            let template = String(
                localized: "dispatch.metric.approximate",
                defaultValue: "≈%@"
            )
            return String(format: template, value)
        }

        static func metricTokensLabel(_ value: String) -> String {
            let template = String(
                localized: "dispatch.metric.tokens-label",
                defaultValue: "%@ Token"
            )
            return String(format: template, value)
        }

        static func metricDurationHours(_ hours: Int, _ minutes: Int) -> String {
            let template = String(
                localized: "dispatch.metric.duration-hours",
                defaultValue: "%dh %02dm"
            )
            return String(format: template, hours, minutes)
        }

        static func metricDurationMinutes(_ minutes: Int, _ seconds: Int) -> String {
            let template = String(
                localized: "dispatch.metric.duration-minutes",
                defaultValue: "%dm %02ds"
            )
            return String(format: template, minutes, seconds)
        }

        static func metricDurationSeconds(_ seconds: Int) -> String {
            let template = String(
                localized: "dispatch.metric.duration-seconds",
                defaultValue: "%ds"
            )
            return String(format: template, seconds)
        }

        static func metricEstimatedCost(_ value: String) -> String {
            let template = String(
                localized: "dispatch.metric.estimated-cost",
                defaultValue: "≈ $%@"
            )
            return String(format: template, value)
        }

        static func metricTokensHelp(_ value: String) -> String {
            let template = String(
                localized: "dispatch.metric.tokens-help",
                defaultValue: "Token usage: %@"
            )
            return String(format: template, value)
        }

        static func metricDurationHelp(_ value: String) -> String {
            let template = String(
                localized: "dispatch.metric.duration-help",
                defaultValue: "Elapsed time: %@"
            )
            return String(format: template, value)
        }

        static func metricCostHelp(_ value: String) -> String {
            let template = String(
                localized: "dispatch.metric.cost-help",
                defaultValue: "Estimated cost: %@"
            )
            return String(format: template, value)
        }

        static func metricsAccessibility(
            _ tokens: String,
            _ duration: String,
            _ cost: String
        ) -> String {
            let template = String(
                localized: "dispatch.metric.accessibility",
                defaultValue: "Tokens %@, elapsed %@, estimated cost %@"
            )
            return String(format: template, tokens, duration, cost)
        }
        static let waitingForDependencies = String(
            localized: "dispatch.waiting-dependencies",
            defaultValue: "Waiting for dependencies"
        )
        static let goalCommandTitle = String(
            localized: "dispatch.goal-command-title",
            defaultValue: "Send an instruction to this project"
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
            defaultValue: "No project instructions yet"
        )
        static let deleteGoal = String(
            localized: "dispatch.delete-goal",
            defaultValue: "Delete Project"
        )
        static let deleteGoalConfirmationTitle = String(
            localized: "dispatch.delete-goal-confirmation-title",
            defaultValue: "Delete this project?"
        )
        static func deleteGoalConfirmationMessage(_ title: String) -> String {
            String(
                format: String(
                    localized: "dispatch.delete-goal-confirmation-message",
                    defaultValue: "“%@” has received project instructions. Deleting it will stop its current work and remove its task conversations. This cannot be undone."
                ),
                title
            )
        }
        static let deleteGoalConfirm = String(
            localized: "dispatch.delete-goal-confirm",
            defaultValue: "Delete and Stop"
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
            defaultValue: "Interrupt the current project execution?"
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
        static let noProfileAvailable = String(
            localized: "dispatch.no-profile-available",
            defaultValue: "No untried profile in this node's fallback chain is available."
        )
        static let goalPausedLaunch = String(
            localized: "dispatch.goal-paused-launch",
            defaultValue: "Resume this project before launching another task."
        )
        static func projectAlreadyRunning(_ projectName: String) -> String {
            String(
                format: String(
                    localized: "dispatch.project-already-running",
                    defaultValue: "“%@” is already the active dispatch project for this workspace. Open or pause it before starting another one."
                ),
                projectName
            )
        }
        static let taskStarted = String(
            localized: "dispatch.task-started",
            defaultValue: "Task started"
        )
        static let acceptanceGate = String(
            localized: "dispatch.acceptance-gate",
            defaultValue: "Acceptance Gate"
        )
        static let graphTitle = String(
            localized: "dispatch.graph-title",
            defaultValue: "Task Graph"
        )
        static let graphActive = String(
            localized: "dispatch.graph-active",
            defaultValue: "Active"
        )
        static let graphReview = String(
            localized: "dispatch.graph-review",
            defaultValue: "Review"
        )
        static let graphComplete = String(
            localized: "dispatch.graph-complete",
            defaultValue: "Complete"
        )
        static let graphSummaryTitle = String(
            localized: "dispatch.graph-summary-title",
            defaultValue: "Graph Summary"
        )
        static let graphTasks = String(
            localized: "dispatch.graph-tasks",
            defaultValue: "Tasks"
        )
        static let graphPending = String(
            localized: "dispatch.graph-pending",
            defaultValue: "Pending"
        )
        static let graphCriteria = String(
            localized: "dispatch.graph-criteria",
            defaultValue: "Criteria"
        )
        static let zoomOut = String(
            localized: "dispatch.zoom-out",
            defaultValue: "Zoom out"
        )
        static let zoomIn = String(
            localized: "dispatch.zoom-in",
            defaultValue: "Zoom in"
        )
        static let resetZoom = String(
            localized: "dispatch.reset-zoom",
            defaultValue: "Reset zoom"
        )
        static let addNode = String(
            localized: "dispatch.add-node",
            defaultValue: "Add Node"
        )
        static let editNode = String(
            localized: "dispatch.edit-node",
            defaultValue: "Edit Node"
        )
        static let saveNode = String(
            localized: "dispatch.save-node",
            defaultValue: "Save Node"
        )
        static let nodeSelectionHint = String(
            localized: "dispatch.node-selection-hint",
            defaultValue: "Select to inspect this node."
        )
        static let nodeEditorMessage = String(
            localized: "dispatch.node-editor-message",
            defaultValue: "Define the node, its prerequisites, and the evidence required to pass."
        )
        static let nodeOverrideMessage = String(
            localized: "dispatch.node-override-message",
            defaultValue: "Adjust the node objective and acceptance criteria. Its graph relationships stay managed by the dispatch plan."
        )
        static let nodeObjective = String(
            localized: "dispatch.node-objective",
            defaultValue: "Node objective"
        )
        static let nodeTaskTitle = String(
            localized: "dispatch.node-task-title",
            defaultValue: "Task title"
        )
        static let nodeTaskTitlePlaceholder = String(
            localized: "dispatch.node-task-title-placeholder",
            defaultValue: "Describe the outcome of this node"
        )
        static let nodeDependencies = String(
            localized: "dispatch.node-dependencies",
            defaultValue: "Prerequisite nodes"
        )
        static let nodeDependenciesHelp = String(
            localized: "dispatch.node-dependencies-help",
            defaultValue: "This node remains blocked until every selected prerequisite is merged."
        )
        static let noDependenciesAvailable = String(
            localized: "dispatch.no-dependencies-available",
            defaultValue: "No other nodes are available."
        )
        static let nodeAcceptanceHelp = String(
            localized: "dispatch.node-acceptance-help",
            defaultValue: "Enter one acceptance criterion per line."
        )
        static let runtimeInstructions = String(
            localized: "dispatch.runtime-instructions",
            defaultValue: "Runtime Instructions"
        )
        static let showInstructions = String(
            localized: "dispatch.show-instructions",
            defaultValue: "Show Instructions"
        )
        static let hideInstructions = String(
            localized: "dispatch.hide-instructions",
            defaultValue: "Hide Instructions"
        )
        static let planUpdateFailed = String(
            localized: "dispatch.plan-update-failed",
            defaultValue: "Couldn’t update the graph"
        )
        static let planUpdateFailedMessage = String(
            localized: "dispatch.plan-update-failed-message",
            defaultValue: "Check that the title is present, the task is not running, and the selected prerequisites do not create a cycle."
        )
        static let outcomeUpdateFailedMessage = String(
            localized: "dispatch.outcome-update-failed-message",
            defaultValue: "Check that the node objective is present and the task is not currently running or under review."
        )
        static let saveIntervention = String(
            localized: "dispatch.save-intervention",
            defaultValue: "Save Changes"
        )
        static let acceptanceInspectorMessage = String(
            localized: "dispatch.acceptance-inspector-message",
            defaultValue: "Final evidence and task readiness"
        )
        static let acceptanceByTask = String(
            localized: "dispatch.acceptance-by-task",
            defaultValue: "Acceptance by task"
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

        static func graphSummary(_ tasks: Int, _ edges: Int) -> String {
            String(
                localized: "dispatch.graph-summary",
                defaultValue: "\(tasks) nodes · \(edges) connections"
            )
        }

        static func nodeOrdinal(_ ordinal: Int) -> String {
            String(
                localized: "dispatch.node-ordinal",
                defaultValue: "NODE \(ordinal)"
            )
        }

        static func taskNodeAccessibility(_ ordinal: Int, _ title: String) -> String {
            String(
                localized: "dispatch.task-node-accessibility",
                defaultValue: "Task node \(ordinal): \(title)"
            )
        }

        static func acceptanceProgress(_ completed: Int, _ total: Int) -> String {
            String(
                localized: "dispatch.acceptance-progress",
                defaultValue: "\(completed) of \(total) tasks passed"
            )
        }

        static func criteriaCount(_ count: Int) -> String {
            String(
                localized: "dispatch.criteria-count",
                defaultValue: "\(count) acceptance criteria"
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
            case .blocked: return String(localized: "dispatch.state-blocked", defaultValue: "Pending start")
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
