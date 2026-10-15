import Foundation

extension AgentSubagentRunner {
    @MainActor static func run(
        prompt: String, configuration: AgentConfiguration, workspaceURL: URL?,
        localSandboxDisabled: Bool = false, additionalWorkspaceRoots: [URL] = [],
        runtimeDescriptor: RuntimeDescriptor? = nil, workspaceLocation: WorkspaceLocation? = nil,
        someIMContext: SomeIMRequestContext? = nil, compressionConfiguration: AgentConfiguration? = nil,
        nextTierConfiguration: AgentConfiguration? = nil, outputSchema: AgentStructuredSchema? = nil,
        profile: AgentSubagentProfile = AgentSubagentProfileCatalog.deep, writeAccess: AgentSubagentWriteAccess? = nil,
        verifierCommand: String? = nil, verifierMaxAttempts: Int = AgentSubagentTaskPacket.defaultMaxAttempts,
        patchProposalSink: (@MainActor (String?, String, Bool, URL) async throws -> AgentPatchProposal)? = nil,
        terminalController: AgentInteractiveTerminalController? = nil, approvedCommand: String? = nil,
        commandReviewer: CommandReviewer? = nil, toolReviewer: ToolReviewer? = nil,
        interventionChannel: AgentSubagentInterventionChannel? = nil, openingImages: [AgentImageAttachment] = [],
        executionBudget: AgentToolExecutionBudget? = nil,
        evidenceRunID: UUID? = nil, evidenceSessionID: UUID? = nil, evidenceMode: String = "foreground_worker",
        session: URLSession? = nil, firstContactTimeout: TimeInterval = AgentWorkerFirstContact.timeout,
        onProgress: ((AgentSubagentProgressUpdate) -> Void)? = nil
    ) async throws -> Outcome {
        let parent = AgentExecutionTrace.current
        let id = evidenceRunID ?? UUID()
        var seed = AgentExecutionEvidenceEvent(runID: id, rootRunID: parent?.seed.rootRunID ?? id,
            sessionID: evidenceSessionID ?? parent?.seed.sessionID, turnID: parent?.seed.turnID,
            parentRunID: parent?.seed.runID, mode: evidenceMode, kind: "started",
            definition: profile.registrySnapshot, provider: configuration.providerID, model: configuration.model,
            effectiveTools: profile.effectiveToolNames(writeAccessGranted: writeAccess != nil).sorted(),
            runtimeParameters: parent?.seed.runtimeParameters, maximumRounds: profile.maxRounds,
            contextWindow: profile.modelBinding.contextWindowTokens)
        seed.verifierCommandSHA256 = verifierCommand.map { AgentPackageV1.hash(Data($0.utf8)) }
        seed.skillsSHA256 = try profile.registrySnapshot.map { snapshot in
            AgentPackageV1.hash(try AgentRSIContract.raw(JSONEncoder().encode(snapshot.lockedSkills)).bytes)
        }
        seed.executionDeadline = executionBudget?.deadline; seed.executionWrapUpOnly = executionBudget?.wrapUpOnly
        seed.requestLedgerOwnerID = executionBudget?.requestLedger?.ownerID
        seed.experimentID = parent?.seed.experimentID; seed.trialID = parent?.seed.trialID
        seed.arm = parent?.seed.arm; seed.tasksetSHA256 = parent?.seed.tasksetSHA256
        let trace = AgentExecutionTrace(store: parent?.store ?? .local, seed: seed)
        trace.record("started")
        return try await AgentExecutionTrace.$current.withValue(trace) {
            do {
                let outcome = try await runUnrecorded(prompt: prompt, configuration: configuration, workspaceURL: workspaceURL,
                    localSandboxDisabled: localSandboxDisabled, additionalWorkspaceRoots: additionalWorkspaceRoots,
                    runtimeDescriptor: runtimeDescriptor, workspaceLocation: workspaceLocation, someIMContext: someIMContext,
                    compressionConfiguration: compressionConfiguration, nextTierConfiguration: nextTierConfiguration,
                    outputSchema: outputSchema, profile: profile, writeAccess: writeAccess, verifierCommand: verifierCommand,
                    verifierMaxAttempts: verifierMaxAttempts, patchProposalSink: patchProposalSink,
                    terminalController: terminalController, approvedCommand: approvedCommand, commandReviewer: commandReviewer,
                    toolReviewer: toolReviewer, interventionChannel: interventionChannel, openingImages: openingImages,
                    executionBudget: executionBudget, session: session, firstContactTimeout: firstContactTimeout, onProgress: onProgress)
                trace.record("finished") {
                    $0.status = outcome.evidenceStatus
                    $0.terminationReason = outcome.terminationReason.rawValue; $0.roundCount = outcome.roundCount
                    $0.verifierPassed = outcome.verifierPassed; $0.verifierAttempts = outcome.verifierAttempts
                    $0.usageTokens = outcome.usageTokens
                }
                return outcome
            } catch {
                trace.record("finished") { $0.status = error is CancellationError ? "interrupted" : "infra_error" }
                throw error
            }
        }
    }
}
