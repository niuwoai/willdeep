//
//  AgentSubagentIntervention.swift
//  WillDeep
//
//  A user-visible steering channel for a running Worker. The channel is kept
//  outside the provider transcript so the UI can queue an instruction while
//  the child is awaiting a model response or a tool. The runner drains it at
//  a safe boundary and injects the user's text as a real user message.
//

import Foundation

enum AgentSubagentInterventionMode: String, Equatable, Sendable {
    case nextRound
    case interruptCurrentStep
}

/// Who steered the Worker. The user types into the card (1000 characters);
/// the main Agent uses `send_agent_message` (4000 characters). Neither
/// channel truncates: over-length input is rejected.
nonisolated enum AgentSubagentInterventionOrigin: String, Equatable, Sendable {
    case user
    case parentAgent

    static let userCharacterLimit = 1_000
    static let parentAgentCharacterLimit = 4_000

    var characterLimit: Int {
        switch self {
        case .user: return Self.userCharacterLimit
        case .parentAgent: return Self.parentAgentCharacterLimit
        }
    }
}

struct AgentSubagentInterventionSubmission: Equatable, Sendable, Identifiable {
    let id: UUID
    let text: String
    let mode: AgentSubagentInterventionMode
    let submittedAt: Date
    let requestedRound: Int
    var origin: AgentSubagentInterventionOrigin = .user
}

/// The card's draft rule, kept pure so it is testable without a view: the
/// counter shows what is left, and an over-length draft cannot be sent.
nonisolated enum AgentSubagentInterventionDraftPolicy {
    static func characterCount(_ draft: String) -> Int {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    static func remainingCharacters(_ draft: String) -> Int {
        AgentSubagentInterventionOrigin.userCharacterLimit - characterCount(draft)
    }

    static func canSubmit(_ draft: String) -> Bool {
        let count = characterCount(draft)
        return count > 0 && count <= AgentSubagentInterventionOrigin.userCharacterLimit
    }
}

enum AgentSubagentInterventionEvent: Equatable, Sendable {
    case queued(AgentSubagentInterventionSubmission)
    case applied(AgentSubagentInterventionSubmission, effectiveRound: Int)
}

enum AgentSubagentInterventionError: LocalizedError, Equatable {
    case emptyInstruction
    case runUnavailable
    case tooLong(characters: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .emptyInstruction:
            return L10n.AgentDelegation.interventionEmptyError
        case .runUnavailable:
            return L10n.AgentDelegation.interventionUnavailableError
        case .tooLong(let characters, let limit):
            return L10n.AgentDelegation.interventionTooLongError(characters, limit: limit)
        }
    }
}

/// Main-actor ownership is intentional. Both the SwiftUI action and the
/// subagent loop already rendezvous on the main actor, so cancellation can be
/// installed and fired without a second synchronization regime.
@MainActor
final class AgentSubagentInterventionChannel {
    typealias EventHandler = (AgentSubagentInterventionEvent) -> Void

    static let instructionCharacterLimit = AgentSubagentInterventionOrigin.userCharacterLimit
    /// `send_agent_message` limit, counted in Unicode scalars like the CLI.
    static let parentAgentMessageCharacterLimit = AgentSubagentInterventionOrigin.parentAgentCharacterLimit

    var onEvent: EventHandler?

    private struct ActiveStep {
        let id: UUID
        let cancel: () -> Void
    }

    private(set) var currentRound = 0
    private var pending: [AgentSubagentInterventionSubmission] = []
    private var activeStep: ActiveStep?

    var hasPendingInterruption: Bool {
        pending.contains { $0.mode == .interruptCurrentStep }
    }

    var hasPendingSubmission: Bool { !pending.isEmpty }

    /// Whether a child step is registered and therefore cancellable right
    /// now. The runner never needs to ask; tests do. Waiting on this is the
    /// only honest way to know the step has actually registered — a fixed
    /// sleep in its place is a race that stays invisible on an idle machine
    /// and fails under a full-load run, where the MainActor can be busy far
    /// longer than any constant anyone would write.
    var hasActiveStep: Bool { activeStep != nil }

    func beginRound(_ round: Int) {
        currentRound = max(0, round)
    }

    @discardableResult
    func submit(
        text: String,
        mode: AgentSubagentInterventionMode,
        submittedAt: Date = Date(),
        origin: AgentSubagentInterventionOrigin = .user
    ) throws -> AgentSubagentInterventionSubmission {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The card counts what it shows (trimmed characters); the model
        // channel counts the message as sent, in scalars, like the CLI.
        let count = origin == .user
            ? AgentSubagentInterventionDraftPolicy.characterCount(text)
            : text.unicodeScalars.count
        guard count <= origin.characterLimit else {
            throw AgentSubagentInterventionError.tooLong(characters: count, limit: origin.characterLimit)
        }
        guard !trimmed.isEmpty else {
            throw AgentSubagentInterventionError.emptyInstruction
        }
        let submission = AgentSubagentInterventionSubmission(
            id: UUID(),
            text: trimmed,
            mode: mode,
            submittedAt: submittedAt,
            requestedRound: max(1, currentRound + 1),
            origin: origin
        )
        pending.append(submission)
        onEvent?(.queued(submission))

        if mode == .interruptCurrentStep {
            activeStep?.cancel()
        }
        return submission
    }

    /// Drains in submission order. Multiple quick corrections therefore keep
    /// the same order in both the provider transcript and the visible receipt.
    func drainPending(effectiveRound: Int) -> [AgentSubagentInterventionSubmission] {
        guard !pending.isEmpty else { return [] }
        let drained = pending
        pending.removeAll(keepingCapacity: true)
        for submission in drained {
            onEvent?(.applied(submission, effectiveRound: effectiveRound))
        }
        return drained
    }

    /// Runs one provider/tool step behind an independently cancellable child
    /// task. Cancelling this task stops only the current Worker step; it does
    /// not cancel the parent turn or the Worker run itself.
    func runCancellableStep<T>(
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let task = Task { try await operation() }
        let stepID = UUID()
        activeStep = ActiveStep(id: stepID, cancel: { task.cancel() })
        defer {
            if activeStep?.id == stepID {
                activeStep = nil
            }
        }
        return try await task.value
    }
}
