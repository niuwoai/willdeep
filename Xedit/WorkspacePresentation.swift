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
