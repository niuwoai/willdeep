//
//  WorkspacePresentation.swift
//  WillDeep
//
//  Shared display helpers for local and remote workspace bindings.
//  Keeping this small avoids sidebar/composer/status-bar drift.
//

import Foundation
import SwiftUI

enum WorkspacePresentation {
    /// Parses the `remote:<uuid>:<path>` sidebar group key.
    static func remoteWorkspaceGroup(from key: String) -> (runtimeID: UUID, path: String)? {
        let prefix = "remote:"
        guard key.hasPrefix(prefix) else { return nil }
        let remainder = String(key.dropFirst(prefix.count))
        guard let separator = remainder.firstIndex(of: ":") else { return nil }
        guard let runtimeID = UUID(uuidString: String(remainder[..<separator])) else { return nil }
        return (runtimeID, String(remainder[remainder.index(after: separator)...]))
    }

    /// The single place that turns a sidebar group key into a human name.
    ///
    /// The recent-sessions rail used to carry its own copy that handled the
    /// `noWorkspace` and `remote:` keys but not `project:`, so a project group
    /// fell through to `lastPathComponent` and rendered as the raw key —
    /// "project:6F…262" instead of the project's name. Every surface that
    /// labels a group key goes through here now.
    static func groupDisplayName(
        for key: String,
        projects: [AgentProject],
        remoteRuntime: (UUID) -> RuntimeDescriptor?
    ) -> String {
        if key == AgentSession.noWorkspaceSidebarGroupKey { return L10n.Workspace.noWorkspace }
        if let projectID = AgentSession.projectID(fromSidebarGroupKey: key) {
            // Falls back when the project has since been deleted, so a stale
            // key still reads as something rather than the raw UUID.
            guard let project = projects.first(where: { $0.id == projectID }) else {
                return L10n.Workspace.noWorkspace
            }
            return project.resolvedDisplayName
        }
        if let remote = remoteWorkspaceGroup(from: key) {
            return remoteDisplayName(runtime: remoteRuntime(remote.runtimeID), path: remote.path)
        }
        return localDisplayName(path: key)
    }

    static func localDisplayName(path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    static func remoteDisplayName(runtime: RuntimeDescriptor?, path: String) -> String {
        let runtimeName = runtime?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = runtimeName?.isEmpty == false ? runtimeName! : "Remote"
        let folder = localDisplayName(path: path)
        return "\(prefix): \(folder.isEmpty ? path : folder)"
    }

    static func remoteHelp(runtime: RuntimeDescriptor?, path: String) -> String {
        guard let runtime else {
            return "Remote workspace: \(path)"
        }
        switch runtime.transport {
        case .ssh:
            return "SSH runtime \(runtime.displayName) (\(runtime.sshTarget)): \(path)"
        case .daemon:
            let endpoint = runtime.daemonEndpointURL?.absoluteString ?? runtime.host
            return "Daemon runtime \(runtime.displayName) (\(endpoint)): \(path)"
        case .local:
            return "\(runtime.displayName): \(path)"
        }
    }

    static func remoteSymbolName(for runtime: RuntimeDescriptor?) -> String {
        switch runtime?.transport {
        case .ssh:
            return "terminal.fill"
        case .daemon:
            return "server.rack"
        case .local, .none:
            return "globe"
        }
    }

    static func remoteBadge(for runtime: RuntimeDescriptor?) -> String {
        switch runtime?.transport {
        case .ssh:
            return "SSH"
        case .daemon:
            return "DAEMON"
        case .local, .none:
            return "REMOTE"
        }
    }

    static func remoteTint(for runtime: RuntimeDescriptor?) -> Color {
        switch runtime?.transport {
        case .ssh:
            return Color.cyan
        case .daemon:
            return Color.purple
        case .local, .none:
            return Color.accentColor
        }
    }
}
