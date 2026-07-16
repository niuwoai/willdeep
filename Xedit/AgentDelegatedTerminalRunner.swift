//
//  AgentDelegatedTerminalRunner.swift
//  Xedit
//
//  Builds a POSIX-sh command wrapper for delegated coding agents. The wrapper
//  is sent directly to a dedicated visible `/bin/sh` terminal tab so users can
//  inspect the real command and prompt instead of seeing an opaque temp script.
//

import Foundation

struct AgentDelegatedTerminalArtifacts {
    let command: String
    let outputURL: URL
    let pendingStatusURL: URL
    let statusURL: URL
    let startedURL: URL

    nonisolated var invocation: String {
        AgentDelegatedTerminalRunner.invocation(
            command: command,
            outputURL: outputURL,
            pendingStatusURL: pendingStatusURL,
            statusURL: statusURL,
            startedURL: startedURL
        )
    }

    nonisolated func removeAll(fileManager: FileManager = .default) {
        for url in [outputURL, pendingStatusURL, statusURL, startedURL] {
            try? fileManager.removeItem(at: url)
        }
    }
}

enum AgentDelegatedTerminalRunner {
    nonisolated static func create(
        command: String,
        workingDirectory: String? = nil,
        directory: URL = FileManager.default.temporaryDirectory,
        token: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        fileManager: FileManager = .default
    ) throws -> AgentDelegatedTerminalArtifacts {
        let baseName = "willdeep-terminal-\(token)"
        let artifacts = AgentDelegatedTerminalArtifacts(
            command: scopedCommand(command, workingDirectory: workingDirectory),
            outputURL: directory.appendingPathComponent("\(baseName).log"),
            pendingStatusURL: directory.appendingPathComponent("\(baseName).status.pending"),
            statusURL: directory.appendingPathComponent("\(baseName).status"),
            startedURL: directory.appendingPathComponent("\(baseName).started")
        )
        guard fileManager.isWritableFile(atPath: directory.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return artifacts
    }

    nonisolated static func scopedCommand(_ command: String, workingDirectory: String?) -> String {
        guard let workingDirectory = workingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !workingDirectory.isEmpty else {
            return command
        }
        return "cd \(shellQuoted(workingDirectory)) || exit 1\n\(command)"
    }

    nonisolated static func invocation(
        command: String,
        outputURL: URL,
        pendingStatusURL: URL,
        statusURL: URL,
        startedURL: URL
    ) -> String {
        let output = shellQuoted(outputURL.path)
        let pendingStatus = shellQuoted(pendingStatusURL.path)
        let status = shellQuoted(statusURL.path)
        let started = shellQuoted(startedURL.path)
        return """
        umask 077
        set +e
        printf '%s' '' > \(started)
        (
        \(command)
        willdeep_exit=$?
        printf '%s' "$willdeep_exit" > \(pendingStatus)
        exit "$willdeep_exit"
        ) 2>&1 | /usr/bin/tee \(output)
        if [ -f \(pendingStatus) ]; then
            /bin/mv -f \(pendingStatus) \(status)
        else
            printf '%s' '1' > \(status)
        fi
        """
    }

    nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
