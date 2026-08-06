//
//  AgentLiveActivityHeadlineCache.swift
//  WillDeep
//
//  Rate-limits the live "what is the model doing right now" status line that
//  sits above the composer while reasoning streams in.
//
//  Two costs this exists to remove, both paid ~10×/s for the whole thinking
//  phase (the stream buffer's flush cadence):
//
//   1. Recomputation. `agentCurrentActivityHeadline` is a computed property
//      read from more than one view, so every flush re-derived the same
//      headline once per reader.
//   2. Re-layout and flicker. The status label re-measured, and its sweep
//      animation restarted, every time the tail line grew by a few
//      characters — visible as a jittering line that never finishes a sweep.
//
//  So: memoize per (message, reasoning length), and let the *text* settle on
//  a slower cadence than the stream. A genuinely new line still appears
//  immediately — only continued growth of the line already on screen waits.
//

import Foundation

nonisolated struct AgentLiveActivityHeadlineCache {
    /// Minimum spacing between visible updates of a line that is merely
    /// growing. Chosen well above the ~100ms flush interval so a long
    /// sentence settles instead of ticking, and well under the 1.9s sweep
    /// cycle so the animation still gets to finish.
    static let minimumUpdateInterval: TimeInterval = 0.45

    private struct Entry {
        let messageID: UUID
        let sourceLength: Int
        let value: AgentActivityHeadlinePresentation?
        let publishedAt: Date
    }

    private var entry: Entry?

    /// Returns the headline for this stream state, recomputing only when the
    /// input actually changed and the result is allowed to be shown yet.
    ///
    /// `compute` is called at most once per distinct `sourceLength`, so
    /// several views asking in the same frame share one evaluation.
    mutating func headline(
        messageID: UUID,
        sourceLength: Int,
        now: Date = Date(),
        compute: () -> AgentActivityHeadlinePresentation?
    ) -> AgentActivityHeadlinePresentation? {
        if let entry, entry.messageID == messageID, entry.sourceLength == sourceLength {
            return entry.value
        }

        let fresh = compute()

        // A new message, or a different line than the one on screen, replaces
        // the headline at once — latency here would read as a stale status.
        let isSameLine = entry?.messageID == messageID
            && entry?.value?.liveTitle != nil
            && fresh?.liveTitle != nil
            && isContinuation(of: entry!.value!.liveTitle, in: fresh!.liveTitle)

        if let entry, isSameLine, now.timeIntervalSince(entry.publishedAt) < Self.minimumUpdateInterval {
            // Hold the displayed text, but remember the length we have seen so
            // the next reader in this frame does not recompute it either.
            self.entry = Entry(
                messageID: messageID,
                sourceLength: sourceLength,
                value: entry.value,
                publishedAt: entry.publishedAt
            )
            return entry.value
        }

        self.entry = Entry(
            messageID: messageID,
            sourceLength: sourceLength,
            value: fresh,
            publishedAt: now
        )
        return fresh
    }

    mutating func reset() {
        entry = nil
    }

    /// True when `candidate` is the same status line as `previous`, just
    /// further along. Truncated lines (…) compare on their stable prefix.
    private func isContinuation(of previous: String, in candidate: String) -> Bool {
        if candidate == previous { return true }
        let previousStem = previous.hasSuffix("…") ? String(previous.dropLast()) : previous
        return candidate.hasPrefix(previousStem) || previousStem.hasPrefix(candidate)
    }
}
