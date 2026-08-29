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

        // MARK: Live Worker progress

        static func progressRound(_ round: Int, _ maximumRounds: Int) -> String {
            let template = String(
                localized: "agent-delegation.progress-round",
                defaultValue: "Round %1$d/%2$d"
            )
            return String(format: template, round, maximumRounds)
        }
        static func progressCompletedTools(_ count: Int) -> String {
            let template = String(
                localized: "agent-delegation.progress-completed-tools",
                defaultValue: "%d tools completed"
            )
            return String(format: template, count)
        }
        static let progressThinking = String(
            localized: "agent-delegation.progress-thinking",
            defaultValue: "Thinking about the next step"
        )
        static func progressRunningTool(_ toolName: String) -> String {
            let template = String(
                localized: "agent-delegation.progress-running-tool",
                defaultValue: "Running %@"
            )
            return String(format: template, toolName)
        }
        static let progressVerifying = String(
            localized: "agent-delegation.progress-verifying",
            defaultValue: "Verifying the result"
        )
        static let progressPreparingReport = String(
            localized: "agent-delegation.progress-preparing-report",
            defaultValue: "Preparing the result"
        )

        // MARK: Worker monitor

        static let monitorCurrentPhase = String(
            localized: "agent-delegation.monitor-current-phase",
            defaultValue: "Current phase"
        )
        static let monitorPhaseReading = String(
            localized: "agent-delegation.monitor-phase-reading",
            defaultValue: "Read"
        )
        static let monitorPhaseLocating = String(
            localized: "agent-delegation.monitor-phase-locating",
            defaultValue: "Locate"
        )
        static let monitorPhaseImplementing = String(
            localized: "agent-delegation.monitor-phase-implementing",
            defaultValue: "Implement"
        )
        static let monitorPhaseVerifying = String(
            localized: "agent-delegation.monitor-phase-verifying",
            defaultValue: "Verify"
        )
        static let monitorTaskFallback = String(
            localized: "agent-delegation.monitor-task-fallback",
            defaultValue: "Assigned Worker task"
        )
        static let monitorRoundsCompleted = String(
            localized: "agent-delegation.monitor-rounds-completed",
            defaultValue: "Completed"
        )
        static let monitorToolCalls = String(
            localized: "agent-delegation.monitor-tool-calls",
            defaultValue: "Tool calls"
        )
        static let monitorElapsed = String(
            localized: "agent-delegation.monitor-elapsed",
            defaultValue: "Elapsed"
        )
        static let monitorJustNow = String(
            localized: "agent-delegation.monitor-just-now",
            defaultValue: "Just now"
        )
        static let monitorRunDetails = String(
            localized: "agent-delegation.monitor-run-details",
            defaultValue: "Run details"
        )
        static let monitorHideDetails = String(
            localized: "agent-delegation.monitor-hide-details",
            defaultValue: "Hide details"
        )
        static let monitorWaitingForUpdate = String(
            localized: "agent-delegation.monitor-waiting-for-update",
            defaultValue: "Waiting for the next update"
        )
        static let monitorRunning = String(
            localized: "agent-delegation.monitor-running",
            defaultValue: "Worker is running"
        )
        static let monitorFinished = String(
            localized: "agent-delegation.monitor-finished",
            defaultValue: "Worker finished"
        )
        static let monitorPreviewRunningTask = String(
            localized: "agent-delegation.monitor-preview-running-task",
            defaultValue: "Implement the Worker monitor and verify its behavior"
        )
        static let monitorPreviewRunningSpeech = String(
            localized: "agent-delegation.monitor-preview-running-speech",
            defaultValue: "The monitor layout is in place. I am checking the status data and regression tests."
        )
        static let monitorPreviewCompletedTask = String(
            localized: "agent-delegation.monitor-preview-completed-task",
            defaultValue: "Review version consistency and release notes"
        )
        static let monitorPreviewCompletedSpeech = String(
            localized: "agent-delegation.monitor-preview-completed-speech",
            defaultValue: "Review completed. Version sources and documentation are consistent."
        )
        static let monitorPreviewFailedTask = String(
            localized: "agent-delegation.monitor-preview-failed-task",
            defaultValue: "Run the macOS regression test suite"
        )
        static let monitorPreviewFailedSpeech = String(
            localized: "agent-delegation.monitor-preview-failed-speech",
            defaultValue: "The test run stopped at a compile failure. The failing target is recorded below."
        )
        static let monitorPreviewFailureMessage = String(
            localized: "agent-delegation.monitor-preview-failure-message",
            defaultValue: "WillDeepTests failed to compile. Open the run details to inspect the recorded activity."
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

        /// Composer chip：这一回合派给谁。
        static func pinnedWorkerChip(_ name: String) -> String {
            String(
                format: String(
                    localized: "agent-delegation.pinned-worker-chip",
                    defaultValue: "Delegate to %@"
                ),
                name
            )
        }
        static let pinnedWorkerRemove = String(
            localized: "agent-delegation.pinned-worker-remove",
            defaultValue: "Cancel this delegation"
        )
        /// 点了名又用 `/no-subagent`：两条指令直接矛盾，宿主拒绝执行而不是
        /// 替用户挑一个。
        static let pinnedWorkerConflict = String(
            localized: "agent-delegation.pinned-worker-conflict",
            defaultValue: "You named a worker and asked for no delegation at the same time. Remove one of them."
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
        static let profileGeneralistName = String(
            localized: "agent-delegation.profile-generalist-name",
            defaultValue: "Generalist"
        )
        static let profileDeepName = String(
            localized: "agent-delegation.profile-deep-name",
            defaultValue: "Deep"
        )
        static let profileEditorName = String(
            localized: "agent-delegation.profile-editor-name",
            defaultValue: "Editor"
        )
        static let profileImplementerName = String(
            localized: "agent-delegation.profile-implementer-name",
            defaultValue: "Implementer"
        )
        static let profileSmallImplementerName = String(
            localized: "agent-delegation.profile-small-implementer-name",
            defaultValue: "Small Implementer"
        )

        static let profileTesterName = String(
            localized: "agent-delegation.profile-tester-name",
            defaultValue: "Tester"
        )
        static let profileReviewerName = String(
            localized: "agent-delegation.profile-reviewer-name",
            defaultValue: "Reviewer"
        )
        static let profileSmallReviewerName = String(
            localized: "agent-delegation.profile-small-reviewer-name",
            defaultValue: "Small Reviewer"
        )
        static let profileTestFixerName = String(
            localized: "agent-delegation.profile-test-fixer-name",
            defaultValue: "Test Fixer"
        )
        static let profileBuildFixerName = String(
            localized: "agent-delegation.profile-build-fixer-name",
            defaultValue: "Build Fixer"
        )
        static let profileLogInspectorName = String(
            localized: "agent-delegation.profile-log-inspector-name",
            defaultValue: "Log Inspector"
        )
        static let profileGitDetectiveName = String(
            localized: "agent-delegation.profile-git-detective-name",
            defaultValue: "Git Detective"
        )
        static let profileSecurityGuardName = String(
            localized: "agent-delegation.profile-security-guard-name",
            defaultValue: "Security Guard"
        )
        static let profileJudgeName = String(
            localized: "agent-delegation.profile-judge-name",
            defaultValue: "Judge"
        )

        static func profileName(for id: String, fallback: String? = nil) -> String {
            switch id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case AgentSubagentProfileCatalog.scoutID: return profileScoutName
            case AgentSubagentProfileCatalog.readerID: return profileReaderName
            case AgentSubagentProfileCatalog.generalistID: return profileGeneralistName
            case AgentSubagentProfileCatalog.deepID: return profileDeepName
            case AgentSubagentProfileCatalog.editorID: return profileEditorName
            case AgentSubagentProfileCatalog.smallImplementerID: return profileSmallImplementerName
            case AgentSubagentProfileCatalog.implementerID: return profileImplementerName
            case AgentSubagentProfileCatalog.testerID: return profileTesterName
            case AgentSubagentProfileCatalog.reviewerID: return profileReviewerName
            case AgentSubagentProfileCatalog.smallReviewerID: return profileSmallReviewerName
            case AgentSubagentProfileCatalog.testFixerID: return profileTestFixerName
            case AgentSubagentProfileCatalog.buildFixerID: return profileBuildFixerName
            case AgentSubagentProfileCatalog.logInspectorID: return profileLogInspectorName
            case AgentSubagentProfileCatalog.gitDetectiveID: return profileGitDetectiveName
            case AgentSubagentProfileCatalog.securityGuardID: return profileSecurityGuardName
            case AgentSubagentProfileCatalog.judgeID: return profileJudgeName
            case AgentSubagentProfileCatalog.opsRunnerID: return profileOpsRunnerName
            case AgentSubagentProfileCatalog.terminalOperatorID: return profileTerminalOperatorName
            default:
                let cleanFallback = fallback?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let cleanFallback, !cleanFallback.isEmpty {
                    return cleanFallback
                }
                return id.replacingOccurrences(of: "_", with: " ")
            }
        }

        static func delegatedToWorker(_ workerName: String) -> String {
            let template = String(
                localized: "agent-delegation.activity.delegated-to-worker",
                defaultValue: "Delegated to %@ Worker"
            )
            return String(format: template, workerName)
        }

        /// Several Workers at once. The count leads because the strip has one
        /// line and naming a single trade would understate what is running.
        static func fleetRunning(_ count: Int, _ primaryWorkerName: String) -> String {
            let template = String(
                localized: "agent-delegation.activity.fleet-running",
                defaultValue: "%1$d Workers running · %2$@"
            )
            return String(format: template, count, primaryWorkerName)
        }

        /// Round marker in front of one Worker utterance, matching the
        /// inspector's numbering so the two surfaces can be read together.
        static func speechRoundMarker(_ round: Int) -> String {
            let template = String(
                localized: "agent-delegation.speech-round-marker",
                defaultValue: "R%d"
            )
            return String(format: template, round)
        }

        /// Same marker for a run of consecutive rounds the Worker spent
        /// only calling tools — those collapse into one row, and the row has
        /// to say which rounds it covers or the numbering goes missing.
        static func speechRoundSpanMarker(_ first: Int, _ last: Int) -> String {
            let template = String(
                localized: "agent-delegation.speech-round-span-marker",
                defaultValue: "R%1$d–%2$d"
            )
            return String(format: template, first, last)
        }

        // MARK: Live Worker intervention

        static let interventionAction = String(
            localized: "agent-delegation.intervention-action",
            defaultValue: "Steer Worker"
        )
        static let interventionCollapse = String(
            localized: "agent-delegation.intervention-collapse",
            defaultValue: "Collapse"
        )
        static let interventionPlaceholder = String(
            localized: "agent-delegation.intervention-placeholder",
            defaultValue: "Correct the Worker's next step…"
        )
        static let interventionNextRound = String(
            localized: "agent-delegation.intervention-next-round",
            defaultValue: "Next round"
        )
        static let interventionInterruptAndSend = String(
            localized: "agent-delegation.intervention-interrupt-and-send",
            defaultValue: "Interrupt & send"
        )
        static let interventionHelp = String(
            localized: "agent-delegation.intervention-help",
            defaultValue: "Return adds a line; ⌘↩ sends for the next round. Normal send applies after the current step; interrupt stops the current step and injects your instruction immediately."
        )
        static let interventionEmptyError = String(
            localized: "agent-delegation.intervention-empty-error",
            defaultValue: "Enter an instruction first."
        )
        static let interventionUnavailableError = String(
            localized: "agent-delegation.intervention-unavailable-error",
            defaultValue: "This Worker has already finished."
        )
        static let interventionYou = String(
            localized: "agent-delegation.intervention-you",
            defaultValue: "You"
        )
        static let interventionJustNow = String(
            localized: "agent-delegation.intervention-just-now",
            defaultValue: "just now"
        )
        static let interventionInterrupting = String(
            localized: "agent-delegation.intervention-interrupting",
            defaultValue: "Interrupting current step"
        )
        static func interventionWaitingForRound(_ round: Int) -> String {
            let template = String(
                localized: "agent-delegation.intervention-waiting-for-round",
                defaultValue: "Waiting · applies in round %d"
            )
            return String(format: template, round)
        }
        static func interventionAppliedAtRound(_ round: Int) -> String {
            let template = String(
                localized: "agent-delegation.intervention-applied-at-round",
                defaultValue: "Delivered · round %d"
            )
            return String(format: template, round)
        }

        static let profilesSectionTitle = String(
            localized: "agent-delegation.profiles-section-title",
            defaultValue: "Subagent trades"
        )
        static let profilesSectionFooter = String(
            localized: "agent-delegation.profiles-section-footer",
            defaultValue: "Each trade runs with its own provider and model. Tool sets are fixed; provider and model bindings save automatically."
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
        static let profileProviderLabel = String(
            localized: "agent-delegation.profile-provider-label",
            defaultValue: "Provider"
        )
        static let profileModelPlaceholder = String(
            localized: "agent-delegation.profile-model-placeholder",
            defaultValue: "Type a model ID"
        )
        static let profilePickFetchedModel = String(
            localized: "agent-delegation.profile-pick-fetched-model",
            defaultValue: "Choose a configured or fetched model"
        )
        static let profileNoProviders = String(
            localized: "agent-delegation.profile-no-providers",
            defaultValue: "No providers configured"
        )
        static let profileNoModelsReturned = String(
            localized: "agent-delegation.profile-no-models-returned",
            defaultValue: "No models returned by /v1/models."
        )
        static func profileFetchedModels(_ count: Int, _ provider: String) -> String {
            let template = String(
                localized: "agent-delegation.profile-fetched-models",
                defaultValue: "Fetched %1$d models from %2$@."
            )
            return String(format: template, count, provider)
        }
        static let profileUnavailableFallback = String(
            localized: "agent-delegation.profile-unavailable-fallback",
            defaultValue: "Unavailable — falls back to this chat's model"
        )

        // MARK: Profile purposes (display-only)
        //
        // `AgentSubagentProfile.purpose` itself is model-facing — it goes
        // into the `spawn_agent` tool description verbatim and must stay
        // English. These are the user-facing translations of the same text.
        static let profileScoutPurpose = String(
            localized: "agent-delegation.profile-scout-purpose",
            defaultValue: "Locate things: find files, symbols, call sites, or answer \"where is X / does X exist\". Fastest and cheapest; read-only shell for listing and inspection only."
        )
        static let profileReaderPurpose = String(
            localized: "agent-delegation.profile-reader-purpose",
            defaultValue: "Read and summarize: digest long files, docs, or public web pages and answer questions about their content. Read-only shell for locating and listing the material."
        )
        static let profileGeneralistPurpose = String(
            localized: "agent-delegation.profile-generalist-purpose",
            defaultValue: "General-purpose read-only work on a smaller model than this session's: reads files, searches, runs read-only commands, checks git state. Use it when no narrower trade fits."
        )
        static let profileDeepPurpose = String(
            localized: "agent-delegation.profile-deep-purpose",
            defaultValue: "Complex investigation: reasoning across many files, read-only shell commands, and git status."
        )
        static let profileEditorPurpose = String(
            localized: "agent-delegation.profile-editor-purpose",
            defaultValue: "Edits one declared file inside the parent workspace policy; cannot touch any other path."
        )
        static let profileImplementerPurpose = String(
            localized: "agent-delegation.profile-implementer-purpose",
            defaultValue: "Implements a bounded multi-file feature or refactor across at most 16 declared existing or new paths on a deployable 256K model."
        )
        static let profileSmallImplementerPurpose = String(
            localized: "agent-delegation.profile-small-implementer-purpose",
            defaultValue: "Implements a verified low-risk change across at most three declared files on someim-32b."
        )
        static let profileTesterPurpose = String(
            localized: "agent-delegation.profile-tester-purpose",
            defaultValue: "Runs tests and gates, reports evidence, never edits code."
        )
        static let profileReviewerPurpose = String(
            localized: "agent-delegation.profile-reviewer-purpose",
            defaultValue: "Independent read-only review of a change's scope, version consistency and git hygiene."
        )
        static let profileSmallReviewerPurpose = String(
            localized: "agent-delegation.profile-small-reviewer-purpose",
            defaultValue: "Independently accepts, rejects, or escalates one verified low-risk change from supplied evidence."
        )
        static let profileTestFixerPurpose = String(
            localized: "agent-delegation.profile-test-fixer-purpose",
            defaultValue: "Fixes a failing test to green inside the files it was given. The verifier command decides success, not the model."
        )
        static let profileBuildFixerPurpose = String(
            localized: "agent-delegation.profile-build-fixer-purpose",
            defaultValue: "Fixes compiler, type-check and lint failures inside the files it was given, verified by the build command."
        )
        static let profileLogInspectorPurpose = String(
            localized: "agent-delegation.profile-log-inspector-purpose",
            defaultValue: "Clusters and explains errors, stack traces and log excerpts. Read-only, no shell."
        )
        static let profileGitDetectivePurpose = String(
            localized: "agent-delegation.profile-git-detective-purpose",
            defaultValue: "Answers repository-history questions such as which commit introduced a regression. Never modifies the repository."
        )
        static let profileSecurityGuardPurpose = String(
            localized: "agent-delegation.profile-security-guard-purpose",
            defaultValue: "Decides whether a command is safe to run unattended. No tools — it judges the command, it never runs it."
        )
        static let profileJudgePurpose = String(
            localized: "agent-delegation.profile-judge-purpose",
            defaultValue: "Returns one bounded verdict about material you supply: a routing choice, a quality check, a classification. No tools."
        )
        static let profileOpsRunnerName = String(
            localized: "agent-delegation.profile-ops-runner-name",
            defaultValue: "Ops Runner"
        )
        static let profileOpsRunnerPurpose = String(
            localized: "agent-delegation.profile-ops-runner-purpose",
            defaultValue: "Runs operations queries directly; bounded modifying commands require smart or human approval."
        )
        static let profileTerminalOperatorName = String(
            localized: "agent-delegation.profile-terminal-operator-name",
            defaultValue: "Terminal Operator"
        )
        static let profileTerminalOperatorPurpose = String(
            localized: "agent-delegation.profile-terminal-operator-purpose",
            defaultValue: "Drives the visible side-panel terminal. Read-only commands run directly; bounded modifying commands require smart or human approval."
        )

        // MARK: Hosted trades (some.im)

        static let profileHostedModelLocked = String(
            localized: "agent-delegation.profile-hosted-model-locked",
            defaultValue: "Model and prompt hosted by some.im"
        )
        static let profileHostedModelLockedHint = String(
            localized: "agent-delegation.profile-hosted-model-locked-hint",
            defaultValue: "While the current provider is some.im this trade runs on a managed model with a server-side prompt. Choose a private provider to keep the trade on that provider."
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
