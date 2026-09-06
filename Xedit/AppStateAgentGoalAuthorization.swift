import Foundation

extension AppState {
    /// Start with native execution, whose final sandbox boundary we own.
    /// Delegated CLIs/children must not inherit a grant through a Bool approval
    /// callback until they can enforce the same scope at execution time.
    func canOfferGoalTaskAuthorization(id: AgentToolCall.ID) -> Bool {
        guard let (runtime, index) = runtimeAndToolCallIndex(containing: id) else { return false }
        let call = runtime.toolCalls[index]
        guard call.status == .pendingApproval,
              !runtime.localPanelPreviewCallIDs.contains(id),
              !call.externalID.hasPrefix("delegated:"), !call.externalID.hasPrefix("subagent:") else { return false }
        return goalAuthorizationRequest(runtime: runtime, toolName: call.toolName, arguments: call.arguments,
                                        risk: call.risk, root: try? runtime.localWorkspaceURLForOptimisticUse()) != nil
    }

    /// Called only by the explicit user-facing task-scope button. Suspending
    /// file reads cannot revive a cancelled waiter or a replaced Goal.
    func allowAgentVerifierForGoal(id: AgentToolCall.ID) async {
        guard canOfferGoalTaskAuthorization(id: id),
              let (runtime, index) = runtimeAndToolCallIndex(containing: id),
              let goal = runtime.currentGoal, runtime.toolDecisionWaiters[id] != nil else { return }
        let call = runtime.toolCalls[index]
        let root = try? runtime.localWorkspaceURLForOptimisticUse()
        let revision = runtime.goalAuthorizationRevision
        guard let request = goalAuthorizationRequest(runtime: runtime, toolName: call.toolName,
                arguments: call.arguments, risk: call.risk, root: root) else { return }
        do {
            let snapshot = try await AgentGoalEvidenceFiles.capture(root: request.root, paths: request.paths)
            guard canOfferGoalTaskAuthorization(id: id),
                  runtime.toolDecisionWaiters[id] != nil,
                  runtime.goalAuthorizationRevision == revision,
                  let currentIndex = runtime.toolCalls.firstIndex(where: { $0.id == id }),
                  runtime.toolCalls[currentIndex].arguments == call.arguments,
                  runtime.currentGoal.map(AgentGoalVerification.contractDigest) == AgentGoalVerification.contractDigest(goal),
                  goalAuthorizationRequest(runtime: runtime, toolName: call.toolName, arguments: call.arguments,
                                           risk: call.risk, root: root) == request,
                  snapshot.digests.values.contains(where: { $0 != "deleted" }) else { return }
            let now = Date()
            let expiry = min(now.addingTimeInterval(AgentGoalTaskAuthorization.maximumLifetime),
                             toolExecutionBudget(for: runtime)?.deadline ?? .distantFuture)
            let grant = AgentGoalTaskAuthorization(id: UUID(), issuerCallID: id, sessionID: runtime.id,
                contractDigest: AgentGoalVerification.contractDigest(goal), workspacePath: request.root.path,
                requestDigest: request.digest, environmentDigest: request.environmentDigest,
                inputDigests: snapshot.digests, grantedAt: now, expiresAt: expiry)
            var grants = (runtime.currentGoal?.taskAuthorizations ?? []).filter {
                $0.expiresAt > now && $0.requestDigest != grant.requestDigest
            }
            grants.append(grant)
            runtime.currentGoal?.taskAuthorizations = Array(grants.suffix(AgentGoalTaskAuthorization.maximumGrants))
            persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
            runtime.toolCalls[currentIndex].approvalSource = .taskGrant
            resolveAgentToolCallDecision(id: id, decision: .approved)
            // One explicit decision may settle identical pending native calls,
            // never a different command or a delegated permission question.
            await resolveMatchingGoalVerifierApprovals(runtime: runtime, root: root)
        } catch {
            // Leave the original one-shot decision available; failure cannot
            // silently fall back to an unrestricted grant.
            if runtime.goalAuthorizationRevision == revision,
               let index = runtime.toolCalls.firstIndex(where: { $0.id == id && $0.status == .pendingApproval }),
               runtime.toolDecisionWaiters[id] != nil {
                runtime.toolCalls[index].errorMessage = L10n.GoalAuthorization.unavailable
            }
            NSLog("[goal-authorization] Grant capture failed; original approval remains pending (%@).", String(describing: type(of: error)))
        }
    }

    private func resolveMatchingGoalVerifierApprovals(runtime: AgentRuntime, root: URL?) async {
        let candidates = runtime.toolCalls.filter {
            ($0.status == .pendingApproval || AgentSerialToolApprovalQueue.contains($0))
                && !$0.externalID.hasPrefix("delegated:") && !$0.externalID.hasPrefix("subagent:")
                && !runtime.localPanelPreviewCallIDs.contains($0.id)
        }
        for call in candidates {
            // Do not send unmatched calls to the generic judge as a side effect
            // of this click. Only the exact still-valid task grant may settle it.
            guard await goalTaskAuthorizationMatches(runtime: runtime, toolName: call.toolName,
                    arguments: call.arguments, risk: call.risk, root: root),
                  let index = runtime.toolCalls.firstIndex(where: { $0.id == call.id }),
                  runtime.toolCalls[index] == call else { continue }
            runtime.toolCalls[index].approvalSource = .taskGrant
            if AgentSerialToolApprovalQueue.contains(call) {
                runtime.toolCalls[index].arguments.removeValue(forKey: AgentSerialToolApprovalQueue.argumentKey)
            } else {
                resolveAgentToolCallDecision(id: call.id, decision: .approved)
            }
        }
    }

    func goalTaskAuthorizationMatches(runtime: AgentRuntime, toolName: String,
                                      arguments: [String: AgentJSONValue], risk: AgentToolRisk, root: URL?) async -> Bool {
        guard let goal = runtime.currentGoal,
              let request = goalAuthorizationRequest(runtime: runtime, toolName: toolName, arguments: arguments, risk: risk, root: root),
              let grant = goal.taskAuthorizations?.last(where: {
                  $0.sessionID == runtime.id && $0.contractDigest == AgentGoalVerification.contractDigest(goal)
                    && $0.workspacePath == request.root.path && $0.requestDigest == request.digest
                    && $0.environmentDigest == request.environmentDigest && $0.expiresAt > Date()
              }) else { return false }
        let revision = runtime.goalAuthorizationRevision
        guard let snapshot = try? await AgentGoalEvidenceFiles.capture(root: request.root, paths: request.paths),
              runtime.goalAuthorizationRevision == revision,
              snapshot.digests == grant.inputDigests,
              runtime.currentGoal?.taskAuthorizations?.contains(grant) == true,
              runtime.currentGoal.map(AgentGoalVerification.contractDigest) == grant.contractDigest,
              goalAuthorizationRequest(runtime: runtime, toolName: toolName, arguments: arguments, risk: risk, root: root) == request,
              grant.expiresAt > Date() else { return false }
        return true
    }

    func goalTaskAuthorizationExecutionCheck(runtime: AgentRuntime, source: AgentToolApprovalSource?, root: URL?)
        -> (@MainActor (String, [String: AgentJSONValue], AgentToolContext) async throws -> Void)? {
        guard source == .taskGrant else { return nil }
        return { [weak self, weak runtime] name, arguments, context in
            guard let self, let runtime,
                  context.rootDirectory?.standardizedFileURL.resolvingSymlinksInPath() == root?.standardizedFileURL.resolvingSymlinksInPath(),
                  context.workspaceRoots.count == 1, context.remoteBackend == nil,
                  context.sandboxMode == .readOnly || context.sandboxMode == .workspaceWrite,
                  let command = arguments["command"]?.stringValue(),
                  AgentSandboxPolicy.canEnforceLocalTaskVerification(command: command, mode: context.sandboxMode),
                  context.localCommandEnvironment == AgentToolRunner.localCommandEnvironment(settings: self.editorTerminalSettings),
                  await self.goalTaskAuthorizationMatches(runtime: runtime, toolName: name,
                      arguments: arguments, risk: .write, root: root) else {
                throw AgentToolError.invalidArgument("Task-scoped verification permission expired or its inputs changed. Nothing ran. Request a fresh bounded approval; do not escalate or retry under a broader policy.")
            }
        }
    }

    private struct GoalAuthorizationRequest: Equatable {
        let root: URL
        let paths: [String]
        let digest: String
        let environmentDigest: String
    }

    private func goalAuthorizationRequest(runtime: AgentRuntime, toolName: String,
            arguments: [String: AgentJSONValue], risk: AgentToolRisk, root: URL?) -> GoalAuthorizationRequest? {
        let displayKeys = ["_sandbox", "_approval_reason", "_prefix_rule", AgentSerialToolApprovalQueue.argumentKey]
        let executableArguments = arguments.filter { !displayKeys.contains($0.key) }
        guard !Task.isCancelled, runtime.interactionMode == .goal, runtime.executionAgent == .willDeep,
              !runtime.isUnattendedDispatchTask,
              runtime.approvalMode != .requestEveryTime, runtime.approvalMode != .fullAccess,
              !runtime.currentTurnPlanningOnly,
              !runtime.isPlanGateActive, runtime.currentPlan?.isInterrupted != true,
              !runtime.queuedMessages.contains(where: { $0.source == .operatorInput }),
              let goal = runtime.currentGoal, !goal.isEmpty, goal.checklist.contains(where: { !$0.done }),
              toolName == "run_command", risk == .write, let root,
              let activeRoot = try? runtime.localWorkspaceURLForOptimisticUse(),
              root.standardizedFileURL.resolvingSymlinksInPath() == activeRoot.standardizedFileURL.resolvingSymlinksInPath(),
              agentWorkspaceRoots(for: runtime.session).count == 1,
              executableArguments.keys.allSatisfy({ ["command", "timeout_seconds", "run_in_background"].contains($0) }),
              arguments["run_in_background"] == nil || arguments["run_in_background"] == .bool(false),
              !AgentRunCommandExecutionPolicy.shouldRunInBackground(arguments: arguments),
              let command = arguments["command"]?.stringValue(),
              Self.isCandidateVerificationCommand(command), AgentDelegatedTaskControl.isSafeVerificationCommand(command, workspaceURL: root),
              let paths = AgentGoalTaskAuthorization.inputs(command: command) else { return nil }
        do { try toolExecutionBudget(for: runtime)?.check() } catch { return nil }
        let decision = AgentSandboxPolicy.decision(toolName: toolName, arguments: arguments, rootDirectory: root)
        // The old build-command heuristic requests network/real HOME even for
        // every Ruby verifier. This explicit choice is a *narrower* permission:
        // always execute inside workspaceWrite, never adopt that heuristic's
        // network/credential mode. Explicit external or sensitive use stays gated.
        guard decision.mode != .escalated, !AgentSandboxPolicy.commandUsesExternalAccess(command),
              AgentSandboxPolicy.canEnforceLocalTaskVerification(command: command, mode: .workspaceWrite),
              arguments["_sandbox"] == nil || arguments["_sandbox"] == .string(decision.mode.rawValue),
              !decision.requiresTypedConfirmation, !decision.credentialSensitive else { return nil }
        if let timeout = arguments["timeout_seconds"] {
            switch timeout {
            case .number(let value): guard value.isFinite, (1...600).contains(value), value.rounded() == value else { return nil }
            case .string(let value): guard Int(value).map({ (1...600).contains($0) }) == true else { return nil }
            default: return nil
            }
        }
        guard let digest = try? AgentGoalTaskAuthorization.digest(executableArguments),
              let environment = try? AgentGoalTaskAuthorization.digest(
                AgentToolRunner.localCommandEnvironment(settings: editorTerminalSettings)) else { return nil }
        return .init(root: root.standardizedFileURL.resolvingSymlinksInPath(), paths: paths,
                     digest: digest, environmentDigest: environment)
    }
}
