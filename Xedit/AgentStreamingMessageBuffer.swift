//
//  AgentStreamingMessageBuffer.swift
//  WillDeep
//
//  Batches streaming assistant deltas before mutating AgentRuntime messages.
//
//  Two publish tiers, because a `runtime.messages` mutation is not a local
//  event: `AppState` forwards the active runtime's `objectWillChange` into
//  its own publisher, and *every* `appState`-observing view in the window
//  re-evaluates + re-lays-out. `sample` during a long streaming turn showed
//  the main thread pinned inside SwiftUI's layout recursion with even the
//  Settings panes' `body` getters re-running — a whole-window invalidation
//  10×/second for the entire turn.
//
//   - Fast tier (~10 Hz): deltas land in `AgentStreamingContentOverlay`,
//     a dedicated publisher observed ONLY by the transcript's streaming
//     bubble subtree. Token-by-token liveness keeps its cadence without
//     touching the rest of the window.
//   - Slow tier (1 Hz): the canonical `messages` array syncs from the
//     overlay, so everything reading `appState.agentMessages` (persistence,
//     minimap fingerprint, thinking headline, context gauge) stays fresh
//     within a second at 1/10th the invalidation cost. The first visible
//     content / reasoning of a message still syncs immediately so the
//     bubble and the thinking preview appear without a perceptible delay.
//
//  `flushPending()` drains both tiers synchronously; every non-delta event
//  in the stream loop (tool calls, usage, finish, errors) calls it first,
//  so canonical ordering around those events is unchanged.
//

import Combine
import Foundation

/// Live text of the currently-streaming assistant message, published on its
/// own channel so per-flush invalidation stays inside the streaming bubble
/// subtree instead of re-laying-out the whole window.
@MainActor
final class AgentStreamingContentOverlay: ObservableObject {
    struct Snapshot: Equatable {
        var messageID: AgentMessage.ID
        var content: String
        var reasoningContent: String?
        /// Live tool-call list while the model streams call argument
        /// fragments. Nil until the first `toolCallsUpdated` event; the
        /// canonical message keeps its own list until then.
        var toolCalls: [AgentMessageToolCall]?
    }

    @Published private(set) var current: Snapshot?

    func snapshot(for messageID: AgentMessage.ID) -> Snapshot? {
        guard let current, current.messageID == messageID else { return nil }
        return current
    }

    func replace(_ snapshot: Snapshot) {
        current = snapshot
    }

    /// Overlays the live text onto the canonical (up to a second stale)
    /// message value. Content only grows during a turn, so an overlay that
    /// is *behind* the canonical value (stale snapshot from an earlier turn
    /// that reused the id, or an external rewrite) is ignored.
    func applying(to base: AgentMessage) -> AgentMessage {
        guard let snapshot = snapshot(for: base.id) else { return base }
        var live = base
        if snapshot.content.utf8.count >= live.content.utf8.count {
            live.content = snapshot.content
        }
        if let reasoning = snapshot.reasoningContent,
           reasoning.utf8.count >= (live.reasoningContent?.utf8.count ?? 0) {
            live.reasoningContent = reasoning
        }
        if let toolCalls = snapshot.toolCalls, toolCalls.count >= live.toolCalls.count {
            live.toolCalls = toolCalls
        }
        return live
    }
}

@MainActor
final class AgentStreamingMessageBuffer {
    /// Fast tier: overlay (streaming bubble) refresh cadence.
    private static let flushIntervalNanoseconds: UInt64 = 100_000_000
    /// Slow tier: canonical `messages` publish cadence. Every canonical
    /// publish is a whole-window SwiftUI invalidation via the AppState
    /// forward, so this deliberately lags the bubble.
    private static let canonicalFlushIntervalNanoseconds: UInt64 = 1_000_000_000
    private static let immediateFlushCharacterCount = 2_400

    private weak var runtime: AgentRuntime?
    private let assistantID: AgentMessage.ID
    private var pendingContent = ""
    private var pendingReasoning = ""
    private var flushTask: Task<Void, Never>?
    private var canonicalFlushTask: Task<Void, Never>?
    private var canonicalNeedsSync = false

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

    /// Streams the growing tool-call list (the model typing call arguments).
    /// The client already gates these events to ~10 Hz, but each one used to
    /// mutate `runtime.messages` directly — a whole-window invalidation at
    /// full cadence for the entire argument stream (edit_file diffs are
    /// long). Argument-fragment growth now rides the overlay/slow tier like
    /// text; only a *new call appearing* (count change) syncs the canonical
    /// array immediately, so the live activity timeline mounts each call
    /// promptly while its argument tail updates at 1 Hz.
    func updateToolCalls(_ calls: [AgentMessageToolCall]) {
        // Drain pending text first so overlay ordering matches the event
        // stream (text delta → tool calls), same as the old flushPending().
        flushTask?.cancel()
        flushTask = nil
        applyPendingDeltas()

        guard let runtime else { return }
        var snapshot: AgentStreamingContentOverlay.Snapshot
        if let existing = runtime.streamingOverlay.snapshot(for: assistantID) {
            snapshot = existing
        } else if let message = runtime.messages.first(where: { $0.id == assistantID }) {
            snapshot = AgentStreamingContentOverlay.Snapshot(
                messageID: assistantID,
                content: message.content,
                reasoningContent: message.reasoningContent
            )
        } else {
            return
        }
        snapshot.toolCalls = calls
        runtime.streamingOverlay.replace(snapshot)
        canonicalNeedsSync = true

        let canonicalCallCount = runtime.messages
            .first(where: { $0.id == assistantID })?.toolCalls.count ?? 0
        if calls.count != canonicalCallCount {
            canonicalFlushTask?.cancel()
            canonicalFlushTask = nil
            syncCanonicalIfNeeded()
        } else {
            syncCanonicalIfDue()
        }
    }

    func flushPending() {
        flushTask?.cancel()
        flushTask = nil
        applyPendingDeltas()
        canonicalFlushTask?.cancel()
        canonicalFlushTask = nil
        syncCanonicalIfNeeded()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.flushIntervalNanoseconds)
            } catch {
                // Cancelled by flushPending(), which already drained.
                return
            }
            guard let self else { return }
            self.flushTask = nil
            self.applyPendingDeltas()
            self.syncCanonicalIfDue()
        }
    }

    private func flushIfNeeded() {
        guard pendingContent.count + pendingReasoning.count >= Self.immediateFlushCharacterCount else {
            return
        }
        flushTask?.cancel()
        flushTask = nil
        applyPendingDeltas()
        syncCanonicalIfDue()
    }

    /// Moves pending deltas into the overlay (fast tier). Does not publish
    /// `runtime.messages` except through the explicit canonical syncs.
    private func applyPendingDeltas() {
        guard !pendingContent.isEmpty || !pendingReasoning.isEmpty,
              let runtime else {
            pendingContent = ""
            pendingReasoning = ""
            return
        }

        // Seed from the canonical message so mid-turn retries that already
        // flushed content keep accumulating instead of restarting from "".
        var snapshot: AgentStreamingContentOverlay.Snapshot
        if let existing = runtime.streamingOverlay.snapshot(for: assistantID) {
            snapshot = existing
        } else if let message = runtime.messages.first(where: { $0.id == assistantID }) {
            snapshot = AgentStreamingContentOverlay.Snapshot(
                messageID: assistantID,
                content: message.content,
                reasoningContent: message.reasoningContent
            )
        } else {
            pendingContent = ""
            pendingReasoning = ""
            return
        }

        let appendedContent = !pendingContent.isEmpty
        let appendedReasoning = !pendingReasoning.isEmpty
        snapshot.content += pendingContent
        if appendedReasoning {
            snapshot.reasoningContent = (snapshot.reasoningContent ?? "") + pendingReasoning
        }
        pendingContent = ""
        pendingReasoning = ""
        runtime.streamingOverlay.replace(snapshot)
        canonicalNeedsSync = true

        // First visible answer text mounts the streaming bubble; first
        // reasoning lights the thinking preview. Both live outside the
        // overlay-observing subtree until the canonical array knows about
        // them, so give each one immediate publish instead of a 1 s lag.
        let canonical = runtime.messages.first(where: { $0.id == assistantID })
        let isFirstVisibleContent = appendedContent && (canonical?.content.isEmpty ?? true)
        let isFirstReasoning = appendedReasoning
            && (canonical?.reasoningContent?.isEmpty ?? true)
        if isFirstVisibleContent || isFirstReasoning {
            canonicalFlushTask?.cancel()
            canonicalFlushTask = nil
            syncCanonicalIfNeeded()
        }
    }

    /// Slow-tier scheduling: at most one canonical sync per interval.
    private func syncCanonicalIfDue() {
        guard canonicalNeedsSync, canonicalFlushTask == nil else { return }
        canonicalFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.canonicalFlushIntervalNanoseconds)
            } catch {
                // Cancelled by flushPending(), which already synced.
                return
            }
            guard let self else { return }
            self.canonicalFlushTask = nil
            self.syncCanonicalIfNeeded()
        }
    }

    /// Writes the overlay snapshot into `runtime.messages` as one value
    /// replacement — reasoning + answer text land in the same publish, so
    /// the 100 ms debounce boundary stays atomic for observers of the
    /// canonical array, exactly as before the tier split.
    private func syncCanonicalIfNeeded() {
        guard canonicalNeedsSync else { return }
        canonicalNeedsSync = false
        guard let runtime,
              let snapshot = runtime.streamingOverlay.snapshot(for: assistantID),
              let index = runtime.messages.firstIndex(where: { $0.id == assistantID }) else {
            return
        }
        var updated = runtime.messages[index]
        updated.content = snapshot.content
        if let reasoning = snapshot.reasoningContent {
            updated.reasoningContent = reasoning
        }
        if let toolCalls = snapshot.toolCalls {
            updated.toolCalls = toolCalls
        }
        runtime.messages[index] = updated
    }
}
