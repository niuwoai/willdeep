import Foundation

extension AppState {
    private final class CheckpointPrefixCache: NSObject {
        let checkpoint: AgentContextCheckpoint
        let prefix: [AgentMessage]
        let prompt: String
        init(checkpoint: AgentContextCheckpoint, prefix: [AgentMessage], prompt: String) {
            self.checkpoint = checkpoint; self.prefix = prefix; self.prompt = prompt
        }
    }
    private static let checkpointPrefixCaches = NSMapTable<AgentRuntime, CheckpointPrefixCache>.weakToStrongObjects()

    struct ContextCompressionTicket {
        let checkpoint: AgentContextCheckpoint
        let stateDigest: String
        let stopRevision: UUID
        let sourceTokens: Int
        let previousSummary: String?
        let previousThroughID: UUID?
        let previousCheckpoint: AgentContextCheckpoint?
    }

    func makeContextCheckpoint(for runtime: AgentRuntime, through id: UUID) throws -> AgentContextCheckpoint {
        guard let index = runtime.messages.firstIndex(where: { $0.id == id }) else { throw AgentContextCheckpoint.Failure.stale }
        let prefix = Array(runtime.messages.prefix(index + 1))
        let inputs = prefix.filter { $0.role == .user && ($0.source == nil || $0.source == .operatorInput) }.map {
            AgentContextCheckpoint.UserInput(messageID: $0.id, text: $0.content,
                imageIDs: $0.images.map(\.id), textAttachmentIDs: $0.textAttachments.map(\.id))
        }
        let goal = runtime.currentGoal.map {
            AgentContextCheckpoint.Goal(contractDigest: AgentGoalVerification.contractDigest($0), statement: $0.statement,
                checklist: $0.checklist, budget: $0.continuationBudget, verificationPhase: $0.verification?.phase,
                historicalReceipts: $0.verification?.receipts ?? [], dispatchPlan: $0.dispatchPlan)
        }
        let covered = Set(prefix.map(\.id))
        let calls = runtime.toolCalls.filter { covered.contains($0.messageID) }
        let receipts = calls.suffix(AgentContextCheckpoint.recentToolLimit).map {
            AgentContextCheckpoint.ToolReceipt(callID: $0.id, toolName: $0.toolName,
                status: $0.status.rawValue, commandExitCode: $0.commandExitCode ?? $0.result?.commandExitCode,
                messageID: $0.messageID, externalID: $0.externalID)
        }
        let task = agentDispatchCoordinator.goals.first { $0.id == runtime.session.dispatchParentProjectID }?
            .tasks.first { $0.id == runtime.session.dispatchTaskID && $0.runtimeSessionID == runtime.id }
        return AgentContextCheckpoint(version: AgentContextCheckpoint.schemaVersion, sessionID: runtime.id,
            throughMessageID: id, prefixDigest: try AgentGoalTaskAuthorization.digest(prefix),
            workspace: runtime.workspaceLocation ?? runtime.workspaceRootPath.map { .local(path: $0) },
            executionAgent: runtime.executionAgent, userInputs: inputs, goal: goal, plan: runtime.currentPlan,
            attributedPaths: runtime.agentEditedPaths.sorted(), recentToolReceipts: receipts,
            omittedToolReceiptCount: max(0, calls.count - receipts.count), pendingDecisionIDs: task?.pendingDecisionIDs ?? [],
            roadmap: runtime.goalRoadmap)
    }

    func prepareContextCompression(for runtime: AgentRuntime, through id: UUID, sourceTokens: Int) throws -> ContextCompressionTicket {
        let checkpoint = try makeContextCheckpoint(for: runtime, through: id)
        let data = try checkpoint.encoded()
        return .init(checkpoint: checkpoint, stateDigest: AgentGoalVerification.digest(data),
                     stopRevision: runtime.goalAuthorizationRevision, sourceTokens: sourceTokens,
                     previousSummary: runtime.contextSummary, previousThroughID: runtime.contextSummaryThroughMessageID,
                     previousCheckpoint: runtime.contextCheckpoint)
    }

    func validateContextCompressionTicket(_ ticket: ContextCompressionTicket, for runtime: AgentRuntime) throws {
        try Task.checkCancellation()
        guard runtime.goalAuthorizationRevision == ticket.stopRevision,
              runtime.contextSummary == ticket.previousSummary,
              runtime.contextSummaryThroughMessageID == ticket.previousThroughID,
              runtime.contextCheckpoint == ticket.previousCheckpoint,
              AgentGoalVerification.digest(try makeContextCheckpoint(for: runtime, through: ticket.checkpoint.throughMessageID).encoded()) == ticket.stateDigest else {
            throw AgentContextCheckpoint.Failure.stale
        }
    }

    /// No suspension between validation and installing all three fields.
    /// A failed candidate preserves the prior summary/checkpoint and transcript.
    func installContextCompression(for runtime: AgentRuntime, summary: String, ticket: ContextCompressionTicket) throws {
        try validateContextCompressionTicket(ticket, for: runtime)
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw AgentContextCheckpoint.Failure.stale }
        let checkpointText = try ticket.checkpoint.prompt()
        let projected = projectedTokensAfterCompression(for: runtime, summary: summary,
            through: ticket.checkpoint.throughMessageID, checkpointText: checkpointText)
        let window = agentContextWindow(for: runtime)
        guard AgentContextCompressionReclamation.accepts(sourceTokens: ticket.sourceTokens,
            summaryTokens: Self.estimateTextTokens(summary) + Self.estimateTextTokens(checkpointText),
            projectedTokens: projected, window: window) else {
            throw AgentCompressionReclamationError(projectedTokens: projected, contextWindow: window)
        }
        runtime.contextCheckpoint = ticket.checkpoint
        runtime.contextSummary = summary
        runtime.contextSummaryThroughMessageID = ticket.checkpoint.throughMessageID
        if let index = runtime.messages.firstIndex(where: { $0.id == ticket.checkpoint.throughMessageID }) {
            Self.checkpointPrefixCaches.setObject(.init(checkpoint: ticket.checkpoint,
                prefix: Array(runtime.messages.prefix(index + 1)), prompt: checkpointText), forKey: runtime)
        }
    }

    func contextCheckpointText(for runtime: AgentRuntime) -> String? {
        guard let checkpoint = runtime.contextCheckpoint,
              checkpoint.version == AgentContextCheckpoint.schemaVersion,
              checkpoint.sessionID == runtime.id,
              checkpoint.throughMessageID == runtime.contextSummaryThroughMessageID,
              checkpoint.workspace == (runtime.workspaceLocation ?? runtime.workspaceRootPath.map { .local(path: $0) }),
              checkpoint.executionAgent == runtime.executionAgent,
              checkpoint.goal?.contractDigest == runtime.currentGoal.map(AgentGoalVerification.contractDigest),
              let index = runtime.messages.firstIndex(where: { $0.id == checkpoint.throughMessageID }) else { return nil }
        let prefix = Array(runtime.messages.prefix(index + 1))
        if let cached = Self.checkpointPrefixCaches.object(forKey: runtime),
           cached.checkpoint == checkpoint, cached.prefix == prefix { return cached.prompt }
        guard (try? AgentGoalTaskAuthorization.digest(prefix)) == checkpoint.prefixDigest,
              let prompt = try? checkpoint.prompt() else { return nil }
        Self.checkpointPrefixCaches.setObject(.init(checkpoint: checkpoint, prefix: prefix, prompt: prompt), forKey: runtime)
        return prompt
    }

    func discardContextCheckpointCache(for runtime: AgentRuntime) {
        Self.checkpointPrefixCaches.removeObject(forKey: runtime)
    }

    /// Recompress only the delta following an accepted prior summary. The
    /// checkpoint retains all operator constraints independently of that prose.
    func contextCompressionInput(for runtime: AgentRuntime, head: [AgentMessage], priorSummary: String?) throws
        -> (segments: [String], sourceTokens: Int) {
        guard !head.isEmpty, Array(runtime.messages.prefix(head.count)) == head else { throw AgentContextCheckpoint.Failure.stale }
        var delta = head
        var prior = priorSummary
        var checkpointTokens = 0
        if let priorSummary {
            guard priorSummary == effectiveContextSummary(for: runtime) else { throw AgentContextCheckpoint.Failure.stale }
            if let through = runtime.contextSummaryThroughMessageID, let index = head.firstIndex(where: { $0.id == through }) {
                delta = Array(head.dropFirst(index + 1))
                checkpointTokens = contextCheckpointText(for: runtime).map(Self.estimateTextTokens) ?? 0
            } else { prior = nil }
        }
        let segments = Self.compressionTranscriptSegments(head: delta, priorSummary: prior)
        return (segments, checkpointTokens + segments.reduce(0) { $0 + Self.estimateTextTokens($1) })
    }

    func effectiveContextSummary(for runtime: AgentRuntime) -> String? {
        runtime.contextCheckpoint == nil || contextCheckpointText(for: runtime) != nil ? runtime.contextSummary : nil
    }

    /// A stale structured checkpoint cannot silently degrade to its old prose
    /// summary. Fall back to the intact transcript until it is recompressed.
    func modelFacingHistory(for runtime: AgentRuntime, excludingMessageID: UUID? = nil) -> [AgentMessage] {
        let text = contextCheckpointText(for: runtime)
        let summary = runtime.contextCheckpoint == nil || text != nil ? runtime.contextSummary : nil
        return Self.modelFacingHistory(messages: runtime.messages, contextSummary: summary,
            contextSummaryThroughMessageID: runtime.contextSummaryThroughMessageID,
            excludingMessageID: excludingMessageID, checkpointText: text)
    }
}
