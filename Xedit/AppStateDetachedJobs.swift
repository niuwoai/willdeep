//
//  AppStateDetachedJobs.swift
//  WillDeep
//
//  Hands adopted detached jobs (contract「C·三」) to their owner sessions once
//  the session catalog is known.
//

import Foundation

extension AppState {
    /// Finished-while-away detached jobs deliver their v1 notice exactly once,
    /// and only to a session that still exists. A deleted owner leaves the job
    /// visible in the jobs UI without waking anything.
    func releaseAdoptedDetachedJobCompletions() {
        let sessionIDs = Set(agentSessions.map(\.id))
        agentJobRegistry.releaseAdoptedDetachedCompletions { sessionIDs.contains($0) }
    }
}
