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

struct AgentSubagentInterventionSubmission: Equatable, Sendable, Identifiable {
    let id: UUID
    let text: String
    let mode: AgentSubagentInterventionMode
    let submittedAt: Date
    let requestedRound: Int
}

enum AgentSubagentInterventionEvent: Equatable, Sendable {
    case queued(AgentSubagentInterventionSubmission)
    case applied(AgentSubagentInterventionSubmission, effectiveRound: Int)
}

enum AgentSubagentInterventionError: LocalizedError, Equatable {
    case emptyInstruction
    case runUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyInstruction:
            return L10n.AgentDelegation.interventionEmptyError
        case .runUnavailable:
            return L10n.AgentDelegation.interventionUnavailableError
        }
    }
}

/// Main-actor ownership is intentional. Both the SwiftUI action and the
/// subagent loop already rendezvous on the main actor, so cancellation can be
/// installed and fired without a second synchronization regime.
@MainActor
final class AgentSubagentInterventionChannel {
    typealias EventHandler = (AgentSubagentInterventionEvent) -> Void

    static let instructionCharacterLimit = 1_000

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
        submittedAt: Date = Date()
    ) throws -> AgentSubagentInterventionSubmission {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentSubagentInterventionError.emptyInstruction
        }
        let submission = AgentSubagentInterventionSubmission(
            id: UUID(),
            text: String(trimmed.prefix(Self.instructionCharacterLimit)),
            mode: mode,
            submittedAt: submittedAt,
            requestedRound: max(1, currentRound + 1)
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
