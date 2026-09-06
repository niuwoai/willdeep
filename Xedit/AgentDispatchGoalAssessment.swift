//
//  AgentDispatchGoalAssessment.swift
//  WillDeep
//
//  Structured, user-assistive goal convergence analysis for the dispatch
//  project setup screen.
//

import Foundation

nonisolated struct AgentDispatchGoalAssessment: Codable, Equatable {
    enum Verdict: String, Codable, Equatable {
        case ready
        case needsRevision = "needs_revision"
    }

    var verdict: Verdict
    var summary: String
    var acceptanceCriteria: [String]
    var missingInformation: [String]
    var suggestedGoalStatement: String

    enum CodingKeys: String, CodingKey {
        case verdict
        case summary
        case acceptanceCriteria = "acceptance_criteria"
        case missingInformation = "missing_information"
        case suggestedGoalStatement = "suggested_goal_statement"
    }

    var isReady: Bool { verdict == .ready }

    func normalized() -> Self {
        Self(
            verdict: verdict,
            summary: Self.trimmed(summary, limit: 1_000),
            acceptanceCriteria: Self.normalizedList(
                acceptanceCriteria,
                itemLimit: 1_000,
                countLimit: 10
            ),
            missingInformation: Self.normalizedList(
                missingInformation,
                itemLimit: 800,
                countLimit: 6
            ),
            suggestedGoalStatement: Self.trimmed(suggestedGoalStatement, limit: 2_000)
        )
    }

    private static func normalizedList(
        _ values: [String],
        itemLimit: Int,
        countLimit: Int
    ) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let item = trimmed(value, limit: itemLimit)
            guard !item.isEmpty, seen.insert(item).inserted else { return nil }
            return item
        }
        .prefix(countLimit)
        .map { $0 }
    }

    private static func trimmed(_ value: String, limit: Int) -> String {
        let sanitized = AgentMemorySanitizer.sanitize(value).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard sanitized.count > limit else { return sanitized }
        return String(sanitized.prefix(limit)) + "…"
    }
}

nonisolated enum AgentDispatchGoalAssessmentContract {
    @MainActor
    static let outputSchema = AgentStructuredSchema(
        type: .object,
        properties: [
            "verdict": .init(
                type: .string,
                enumValues: [.string("ready"), .string("needs_revision")],
                description: "ready only when the goal can converge without inventing material scope"
            ),
            "summary": .init(
                type: .string,
                description: "brief plain-language diagnosis for the user"
            ),
            "acceptance_criteria": .init(
                type: .array,
                items: .init(type: .string),
                minItems: 3,
                maxItems: 10,
                description: "observable, outcome-level acceptance criteria; never implementation tasks"
            ),
            "missing_information": .init(
                type: .array,
                items: .init(type: .string),
                maxItems: 6,
                description: "specific missing decisions or boundaries; empty when ready"
            ),
            "suggested_goal_statement": .init(
                type: .string,
                description: "a more convergent editable goal statement; empty when no rewrite is needed"
            ),
        ],
        required: [
            "verdict",
            "summary",
            "acceptance_criteria",
            "missing_information",
            "suggested_goal_statement",
        ],
        additionalProperties: false
    )

    static func prompt(statement: String) -> String {
        """
        Analyze the following project goal before execution planning. Help a non-expert user turn intent into a project that can actually converge.

        <goal>
        \(statement)
        </goal>

        Decide whether the goal is sufficiently bounded to converge without inventing material product scope. Check at least: intended outcome, target user or usage context when relevant, scope boundaries, observable completion evidence, important constraints, external commitments, credentials or private user takeover, and destructive/irreversible choices that can be predicted before execution. A short goal can still be ready when its outcome is unambiguous. A long goal can still need revision when it hides essential choices.

        Always produce 3-10 concise, observable, outcome-level acceptance criteria that the user may edit. Do not turn implementation steps, code structure, model choices, or task assignments into acceptance criteria. When facts are missing, keep the checklist provisional and do not silently invent them.

        For `needs_revision`, list the smallest concrete decisions the user should add, including predictable user confirmations that should be settled before an unattended run, and provide one editable suggested goal statement. Never list ordinary Git/worktree repair, dependency installation, build/test debugging, path discovery, or other recoverable implementation mechanics as user blockers. Use explicit bracketed placeholders only when a missing fact cannot be inferred safely. For `ready`, keep missing_information empty and suggested_goal_statement empty unless a materially clearer rewrite helps.

        This is advisory: never claim that the user is forbidden to continue. Return the required structured payload only.
        """
    }

    static func decode(_ report: String) throws -> AgentDispatchGoalAssessment {
        let data = Data(report.utf8)
        let decoded = try JSONDecoder().decode(AgentDispatchGoalAssessment.self, from: data)
        let normalized = decoded.normalized()
        guard normalized.acceptanceCriteria.count >= 3 else {
            throw WorkflowError.structuredOutputUnavailable(
                reason: "goal assessment returned fewer than three usable acceptance criteria"
            )
        }
        return normalized
    }
}

nonisolated enum AgentDispatchGoalSetupPolicy {
    static func canCreateProject(statement: String, acceptanceCriteria: [String]) -> Bool {
        !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && acceptanceCriteria.contains {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    static func assessmentIsStale(
        assessedStatement: String,
        currentStatement: String
    ) -> Bool {
        assessedStatement.trimmingCharacters(in: .whitespacesAndNewlines)
            != currentStatement.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
extension AppState {
    func assessDispatchGoal(
        statement: String,
        planningProfileID: String,
        planningFallbackProfileIDs: [String]
    ) async throws -> AgentDispatchGoalAssessment {
        guard let runtime = activeRuntime else {
            throw WorkflowError.structuredOutputUnavailable(reason: "dispatch draft runtime is unavailable")
        }
        let normalizedStatement = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedStatement.isEmpty else {
            throw WorkflowError.structuredOutputUnavailable(reason: "goal statement is empty")
        }

        let profiles = AgentExecutionProfileStore().availableProfiles(
            workspacePath: runtime.workspaceLocation?.path ?? runtime.workspaceRootPath
        )
        var seen: Set<String> = []
        let candidateIDs = ([planningProfileID]
            + planningFallbackProfileIDs
            + [AgentExecutionProfile.recommendedPlannerID])
            .filter { seen.insert($0).inserted }
        let candidates = candidateIDs.compactMap { id in
            profiles.first { $0.id == id && $0.executor == .willDeep }
        }
        guard !candidates.isEmpty else {
            throw WorkflowError.structuredOutputUnavailable(reason: "no WillDeep AI profile is available for goal assessment")
        }

        let workspaceLocation = runtime.workspaceLocation
            ?? runtime.workspaceRootPath.map { .local(path: $0) }
        let workspaceURL = try? runtime.localWorkspaceURLForOptimisticUse()
        let runtimeDescriptor = workspaceLocation?.remoteRuntimeID.flatMap {
            AgentRuntimeStore.descriptor(id: $0)
        }
        var lastError: Error?

        for profile in candidates {
            do {
                let configuration = dispatchGoalAssessmentConfiguration(
                    profile: profile,
                    runtime: runtime
                )
                let someIMContext = dispatchGoalAssessmentSomeIMContext(
                    configuration: configuration,
                    runtime: runtime
                )
                let outcome = try await agentSubagentRegistry.runGoalPlanningSynchronously(
                    prompt: AgentDispatchGoalAssessmentContract.prompt(
                        statement: normalizedStatement
                    ),
                    configuration: configuration,
                    workspaceURL: workspaceURL,
                    runtimeDescriptor: runtimeDescriptor,
                    workspaceLocation: workspaceLocation,
                    someIMContext: someIMContext,
                    outputSchema: AgentDispatchGoalAssessmentContract.outputSchema,
                    executionBudget: auxiliaryModelExecutionBudget(for: runtime)
                )
                return try AgentDispatchGoalAssessmentContract.decode(outcome.report)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if AgentAuxiliaryRequestStop(error) != nil { throw error }
                lastError = error
            }
        }

        throw lastError ?? WorkflowError.structuredOutputUnavailable(
            reason: "goal assessment did not return a usable result"
        )
    }

    private func dispatchGoalAssessmentConfiguration(
        profile: AgentExecutionProfile,
        runtime: AgentRuntime
    ) -> AgentConfiguration {
        var configuration = configurationForCurrentTurn(for: runtime)
        if let providerID = profile.providerID {
            if let entry = agentProviderLibrary.entries.first(where: { $0.providerID == providerID }) {
                configuration = entry.makeConfiguration(
                    imageDescription: agentConfiguration.imageDescription
                ).normalized.resolved(for: .interactive)
            } else if providerID == AgentProviderPreset.someIMID {
                let settings = SomeIMIntegrationStore.loadSettings().normalized
                let entry = AgentProviderEntry(
                    providerID: AgentProviderPreset.someIMID,
                    baseURL: settings.baseURL,
                    apiKey: SomeIMIntegrationStore.loadAPIKey(),
                    flashPrimary: SomeIMIntegrationSettings.defaultTextModel,
                    proPrimary: SomeIMIntegrationSettings.defaultTextModel,
                    routingMode: .flash
                )
                configuration = entry.makeConfiguration(
                    imageDescription: agentConfiguration.imageDescription
                ).normalized.resolved(for: .interactive)
            }
        }
        if let modelID = profile.modelID {
            configuration.model = modelID
        }
        return configuration.normalized
    }

    private func dispatchGoalAssessmentSomeIMContext(
        configuration: AgentConfiguration,
        runtime: AgentRuntime
    ) -> SomeIMRequestContext? {
        guard configuration.providerID == AgentProviderPreset.someIMID else { return nil }
        let workspaceID = AgentWorkspaceIdentityStore.workspaceID(
            forWorkspaceKey: Self.managedWorkspaceKey(for: runtime)
        )
        return SomeIMRequestContext(
            sessionID: runtime.id.uuidString,
            workspaceID: workspaceID
        )
    }
}
