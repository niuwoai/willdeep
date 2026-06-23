//
//  AgentStreamingMessageBuffer.swift
//  WillDeep
//
//  Batches streaming assistant deltas before mutating AgentRuntime messages.
//

import Foundation

@MainActor
final class AgentStreamingMessageBuffer {
    private static let flushIntervalNanoseconds: UInt64 = 100_000_000
    private static let immediateFlushCharacterCount = 2_400

    private weak var runtime: AgentRuntime?
    private let assistantID: AgentMessage.ID
    private var pendingContent = ""
    private var pendingReasoning = ""
    private var flushTask: Task<Void, Never>?

    init(runtime: AgentRuntime, assistantID: AgentMessage.ID) {
        self.runtime = runtime
        self.assistantID = assistantID
    }

    func appendTextDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        pendingContent += delta
        scheduleFlush()
        flushIfNeeded()
    }

    func appendReasoningDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        pendingReasoning += delta
        scheduleFlush()
        flushIfNeeded()
    }

    func flushPending() {
        flushTask?.cancel()
        flushTask = nil
        applyPendingDeltas()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.flushIntervalNanoseconds)
            guard let self else { return }
            self.flushTask = nil
            self.applyPendingDeltas()
        }
    }

    private func flushIfNeeded() {
        guard pendingContent.count + pendingReasoning.count >= Self.immediateFlushCharacterCount else {
            return
        }
        flushPending()
    }

    private func applyPendingDeltas() {
        guard !pendingContent.isEmpty || !pendingReasoning.isEmpty,
              let runtime,
              let index = runtime.messages.firstIndex(where: { $0.id == assistantID }) else {
            pendingContent = ""
            pendingReasoning = ""
            return
        }

        if !pendingContent.isEmpty {
            runtime.messages[index].content += pendingContent
            pendingContent = ""
        }
        if !pendingReasoning.isEmpty {
            var existing = runtime.messages[index].reasoningContent ?? ""
            existing += pendingReasoning
            runtime.messages[index].reasoningContent = existing
            pendingReasoning = ""
        }
    }
}
