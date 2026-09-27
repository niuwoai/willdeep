//
//  AppStateAgentTranscriptMedia.swift
//  WillDeep
//
//  Where the transcript resolves relative media paths (`![](out/demo.mp4)`).
//

import Foundation

@MainActor
extension AppState {
    /// The active session's local workspace root. Nil for a remote workspace:
    /// its relative paths name files on another machine, and resolving them
    /// against a same-named local folder would play the wrong file.
    var agentTranscriptMediaBaseURL: URL? {
        guard let runtime = activeRuntime else { return nil }
        return AgentTranscriptMediaResolver.localBaseURL(
            workspaceLocation: runtime.workspaceLocation,
            workspaceRootPath: runtime.workspaceRootPath
        )
    }
}
