//
//  AppStateAgentDispatchQueue.swift
//  WillDeep
//
//  Provider concurrency gate and pending Agent dispatch queue.
//

import Foundation

extension AppState {
    /// Try to claim a slot for `providerID`. Returns true if the cap
    /// wasn't reached and a slot was reserved; false if the caller
    /// should queue. Always pairs with `releaseProviderSlot(providerID:)`
    /// from the turn loop's defer so counts stay accurate even on
    /// thrown errors / cancellation.
    func acquireProviderSlotIfPossible(providerID: String) -> Bool {
        let current = inFlightCountByProvider[providerID] ?? 0
        guard current < perProviderConcurrencyLimit else { return false }
        inFlightCountByProvider[providerID] = current + 1
        return true
    }

    func releaseProviderSlot(providerID: String) {
        let current = inFlightCountByProvider[providerID] ?? 0
        if current <= 1 {
            inFlightCountByProvider.removeValue(forKey: providerID)
        } else {
            inFlightCountByProvider[providerID] = current - 1
        }
        // Drain any pending entries that can now grab the freshly
        // released slot. Walk once: each released slot can promote at
        // most one queued entry for the same provider; entries for
        // other providers stay in line.
        drainPendingDispatchQueue()
        // Queued user dispatches take priority above; whatever capacity
        // is still left goes to runtimes whose background completions
        // (jobs / media tasks / subagent reports) were stranded because
        // their resume attempt lost an earlier slot race.
        resumeAgentLoopsWithPendingBackgroundCompletions()
    }

    func claimProviderSlot(for runtime: AgentRuntime, providerID: String) -> AgentProviderSlotClaim {
        let claim = AgentProviderSlotClaim(providerID: providerID)
        runtime.currentProviderSlotClaim = claim
        return claim
    }

    func releaseProviderSlot(
        for runtime: AgentRuntime,
        claimID: UUID,
        providerID: String
    ) {
        guard runtime.currentProviderSlotClaim?.id == claimID else { return }
        runtime.currentProviderSlotClaim = nil
        releaseProviderSlot(providerID: providerID)
    }

    func drainPendingDispatchQueue() {
        guard !pendingDispatchQueue.isEmpty else { return }
        var remaining: [PendingDispatch] = []
        remaining.reserveCapacity(pendingDispatchQueue.count)
        // Walk in FIFO order; promote the first entry per provider
        // that fits under the cap, leave the rest queued.
        var promotedByProvider: Set<String> = []
        for entry in pendingDispatchQueue {
            if promotedByProvider.contains(entry.providerID) {
                remaining.append(entry)
                continue
            }
            let current = inFlightCountByProvider[entry.providerID] ?? 0
            guard current < perProviderConcurrencyLimit else {
                remaining.append(entry)
                continue
            }
            guard let runtime = agentRuntimes[entry.runtimeID] else {
                // Runtime was torn down (session deleted) — drop it.
                continue
            }
            promotedByProvider.insert(entry.providerID)
            // The user message was already appended when the dispatch was
            // first queued — pass its id so the re-dispatch reuses it
            // instead of appending a duplicate into the transcript.
            dispatchAgentMessage(
                for: runtime,
                text: entry.text,
                images: entry.images,
                textAttachments: entry.textAttachments,
                attachedSkills: entry.attachedSkills,
                existingUserMessageID: entry.userMessageID
            )
        }
        pendingDispatchQueue = remaining
    }
}
