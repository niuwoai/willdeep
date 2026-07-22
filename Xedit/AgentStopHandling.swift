//
//  AgentStopHandling.swift
//  WillDeep
//
//  User-initiated Agent turn interruption and current-turn process cleanup.
//

import Foundation

nonisolated struct AgentStopJobCandidate: Equatable, Sendable {
    let id: UUID
    let displayHandle: String
    let command: String
}

nonisolated enum AgentStopProcessDecision {
    private struct Payload: Decodable {
        let stopJobIDs: [String]

        enum CodingKeys: String, CodingKey {
            case stopJobIDs = "stop_job_ids"
        }
    }

    static let systemPrompt = """
    You are a process-cleanup judge for a desktop coding agent. The human has
    explicitly stopped the newest Agent turn. Decide which listed background
    shell jobs created by THAT SAME TURN should also be stopped to avoid
    wasting CPU, memory, network, or tokens.

    Rules:
    - You may choose only ids from the supplied candidate list.
    - Stop disposable builds, tests, uploads, polling scripts, and commands
      whose purpose was interrupted with the turn.
    - Keep a process only when the user's request clearly requires it to
      continue independently after the answer stops.
    - Older dev servers and watchers are never candidates and must not be
      inferred or named.
    - Return strict JSON only: {"stop_job_ids":["UUID", ...]}.
    """

    static func userPayload(userRequest: String, candidates: [AgentStopJobCandidate]) -> String {
        let request = userRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        let jobs = candidates.map {
            "- id=\($0.id.uuidString) handle=\($0.displayHandle) command=\($0.command.prefix(500))"
        }.joined(separator: "\n")
        return """
        Latest user request:
        \(request.isEmpty ? "(not available)" : request)

        Current-turn live background jobs:
        \(jobs)
        """
    }

    /// A valid empty array is a real "keep running" decision. Invalid or
    /// unavailable AI output falls back to stopping every current-turn
    /// candidate: the scope token already guarantees older servers cannot be
    /// touched, and leaking interrupted work is the worse failure mode.
    static func selectedJobIDs(
        rawResponse: String?,
        candidates: [AgentStopJobCandidate]
    ) -> Set<UUID> {
        let allowed = Set(candidates.map(\.id))
        guard let json = extractedJSONObject(from: rawResponse),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return allowed
        }
        return Set(payload.stopJobIDs.compactMap(UUID.init(uuidString:))).intersection(allowed)
    }

    private static func extractedJSONObject(from rawResponse: String?) -> String? {
        guard let rawResponse,
              let start = rawResponse.firstIndex(of: "{"),
              let end = rawResponse.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        return String(rawResponse[start...end])
    }
}

extension AppState {
    @MainActor
    static func isStoppedTurnCancellation(
        _ error: Error,
        runtime: AgentRuntime,
        turnID: UUID
    ) -> Bool {
        guard runtime.userStoppedTurnID == turnID else { return false }
        if error is CancellationError || Task.isCancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorCancelled
    }

    @MainActor
    func finalizeInterruptedAssistantMessage(
        id: AgentMessage.ID,
        in runtime: AgentRuntime,
        startedAt: Date
    ) {
        guard let index = runtime.messages.firstIndex(where: { $0.id == id }) else { return }
        let message = runtime.messages[index]
        let isEmptyPlaceholder = message.content.isEmpty
            && message.images.isEmpty
            && message.toolCalls.isEmpty
            && (message.reasoningContent ?? "").isEmpty
        if isEmptyPlaceholder {
            runtime.messages.remove(at: index)
            AgentContextBuilder.removeDanglingTurnContextCarrier(from: &runtime.messages)
        } else {
            runtime.messages[index].elapsedSeconds = Date().timeIntervalSince(startedAt)
        }
    }

    /// Runs a small AI decision outside the cancelled conversation turn. Only
    /// the already-redacted command labels and current-turn ids are sent.
    @MainActor
    func decideStoppedTurnJobs(
        _ candidates: [AgentStopJobCandidate],
        userRequest: String,
        configuration: AgentConfiguration,
        runtime: AgentRuntime
    ) async -> Set<UUID> {
        guard !candidates.isEmpty else { return [] }
        let someIMContext: SomeIMRequestContext? = {
            guard configuration.providerID == AgentProviderPreset.someIMID else { return nil }
            let workspaceID = AgentWorkspaceIdentityStore.workspaceID(
                forWorkspaceKey: Self.managedWorkspaceKey(for: runtime)
            )
            return SomeIMRequestContext(sessionID: runtime.id.uuidString, workspaceID: workspaceID)
        }()
        let client = AgentClient(configuration: configuration, someIMContext: someIMContext)
        let rawResponse: String?
        if configuration.providerKind == .openAIChat {
            rawResponse = await client.routeJudge(
                model: configuration.model,
                systemPrompt: AgentStopProcessDecision.systemPrompt,
                userPayload: AgentStopProcessDecision.userPayload(
                    userRequest: userRequest,
                    candidates: candidates
                ),
                maxTokens: 200
            )
        } else {
            // The non-streaming judge transport is currently OpenAI-Chat only.
            // The deterministic fallback still remains strictly current-turn
            // scoped, so it cannot kill an older server.
            rawResponse = nil
        }
        return AgentStopProcessDecision.selectedJobIDs(
            rawResponse: rawResponse,
            candidates: candidates
        )
    }

    @MainActor
    func appendStoppedTurnEvent(to runtime: AgentRuntime, content: String) -> AgentMessage.ID {
        let event = AgentMessage(
            role: .system,
            content: content,
            transcriptEvent: .responseStopped
        )
        runtime.messages.append(event)
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
        return event.id
    }

    @MainActor
    func updateStoppedTurnEvent(
        id: AgentMessage.ID,
        in runtime: AgentRuntime,
        content: String
    ) {
        guard let index = runtime.messages.firstIndex(where: { $0.id == id }) else { return }
        runtime.messages[index].content = content
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
    }

    @MainActor
    func startStoppedTurnProcessCleanup(
        runtime: AgentRuntime,
        turnID: UUID,
        eventID: AgentMessage.ID,
        candidates: [AgentStopJobCandidate],
        configuration: AgentConfiguration?,
        userRequest: String,
        alreadyStoppedCount: Int
    ) {
        runtime.stopCleanupTasks[turnID]?.cancel()
        runtime.stopCleanupTasks[turnID] = Task { @MainActor [weak self, weak runtime] in
            guard let self, let runtime else { return }
            defer { runtime.stopCleanupTasks.removeValue(forKey: turnID) }
            let selectedIDs: Set<UUID>
            if let configuration {
                selectedIDs = await self.decideStoppedTurnJobs(
                    candidates,
                    userRequest: userRequest,
                    configuration: configuration,
                    runtime: runtime
                )
            } else {
                selectedIDs = Set(candidates.map(\.id))
            }
            guard !Task.isCancelled else { return }

            var killedCount = 0
            for candidate in candidates where selectedIDs.contains(candidate.id) {
                if self.agentJobRegistry.killForStoppedTurn(id: candidate.id) {
                    killedCount += 1
                } else {
                    self.agentJobRegistry.markCompletionSurfaced(
                        id: candidate.id,
                        forRuntime: runtime.id
                    )
                }
            }

            let totalStopped = alreadyStoppedCount + killedCount
            let finalContent: String
            if totalStopped > 0 {
                finalContent = L10n.Composer.stoppedAndCleanedUp(totalStopped)
            } else if selectedIDs.isEmpty {
                finalContent = L10n.Composer.stoppedProcessesKept
            } else {
                finalContent = L10n.Composer.stoppedProcessesFinished
            }
            self.updateStoppedTurnEvent(id: eventID, in: runtime, content: finalContent)
        }
    }
}
