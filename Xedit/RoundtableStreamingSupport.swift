//
//  RoundtableStreamingSupport.swift
//  WillDeep
//
//  A small actor-backed buffer for expert speech. Provider deltas may arrive
//  token-by-token; publishing every token makes SwiftUI churn, while persisting
//  every token hammers the session store. This buffer emits UI snapshots and
//  slower persistence checkpoints independently, then always flushes the final
//  value.
//

import Foundation

actor RoundtableStreamingDraftBuffer {
    struct Publication: Equatable, Sendable {
        let text: String
        let shouldRefreshUI: Bool
        let shouldCheckpoint: Bool
        let isFinal: Bool
        let isReset: Bool
    }

    static let defaultUIInterval: Duration = .milliseconds(80)
    static let defaultCheckpointInterval: Duration = .seconds(1)

    private let uiInterval: Duration
    private let checkpointInterval: Duration
    private var text = ""
    private var lastUIPublishAt: ContinuousClock.Instant?
    private var lastCheckpointAt: ContinuousClock.Instant?

    init(
        uiInterval: Duration = defaultUIInterval,
        checkpointInterval: Duration = defaultCheckpointInterval
    ) {
        self.uiInterval = max(.zero, uiInterval)
        self.checkpointInterval = max(.zero, checkpointInterval)
    }

    /// Append one provider text delta. Returns nil while both clocks are still
    /// inside their throttle windows; the accumulated text remains buffered.
    func append(
        _ delta: String,
        now: ContinuousClock.Instant = ContinuousClock().now
    ) -> Publication? {
        guard !delta.isEmpty else { return nil }
        text += delta

        let shouldRefreshUI: Bool
        if let lastUIPublishAt {
            shouldRefreshUI = lastUIPublishAt.duration(to: now) >= uiInterval
        } else {
            // Show the first token immediately so the expert visibly starts.
            shouldRefreshUI = true
        }

        let shouldCheckpoint: Bool
        if let lastCheckpointAt {
            shouldCheckpoint = lastCheckpointAt.duration(to: now) >= checkpointInterval
        } else {
            // Start the persistence clock with the first token. Do not write a
            // one-token draft to disk.
            shouldCheckpoint = false
        }

        if lastCheckpointAt == nil {
            lastCheckpointAt = now
        }
        if shouldRefreshUI {
            lastUIPublishAt = now
        }
        if shouldCheckpoint {
            lastCheckpointAt = now
        }

        guard shouldRefreshUI || shouldCheckpoint else { return nil }
        return Publication(
            text: text,
            shouldRefreshUI: shouldRefreshUI,
            shouldCheckpoint: shouldCheckpoint,
            isFinal: false,
            isReset: false
        )
    }

    /// Force the last buffered characters to the UI and persistence layer.
    /// Call this before replacing the draft with the finalized roundtable
    /// message.
    func finish() -> Publication {
        Publication(
            text: text,
            shouldRefreshUI: true,
            shouldCheckpoint: true,
            isFinal: true,
            isReset: false
        )
    }

    /// Clear an abandoned draft after cancellation or provider failure.
    func reset() -> Publication {
        text = ""
        lastUIPublishAt = nil
        lastCheckpointAt = nil
        return Publication(
            text: "",
            shouldRefreshUI: true,
            shouldCheckpoint: true,
            isFinal: false,
            isReset: true
        )
    }

    func snapshot() -> String {
        text
    }
}
