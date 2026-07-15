//
//  AgentDelegatedTerminalRunner.swift
//  Xedit
//
//  Builds a private POSIX-sh runner for delegated coding agents. The visible
//  terminal receives only a short `/bin/sh <runner>` invocation, so the
//  configured interactive shell never parses the real command or prompt.
//

import Foundation

struct AgentDelegatedTerminalArtifacts {
    let runnerURL: URL
    let outputURL: URL
    let pendingStatusURL: URL
    let statusURL: URL
    let startedURL: URL

    nonisolated var invocation: String {
        AgentDelegatedTerminalRunner.invocation(runnerURL: runnerURL)
    }

    nonisolated func removeAll(fileManager: FileManager = .default) {
        for url in [runnerURL, outputURL, pendingStatusURL, statusURL, startedURL] {
            try? fileManager.removeItem(at: url)
        }
    }
}

enum AgentDelegatedTerminalRunner {
    nonisolated static let runnerPermissions = 0o600

    nonisolated static func create(
        command: String,
        directory: URL = FileManager.default.temporaryDirectory,
        token: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        fileManager: FileManager = .default
    ) throws -> AgentDelegatedTerminalArtifacts {
        let baseName = "willdeep-terminal-\(token)"
        let artifacts = AgentDelegatedTerminalArtifacts(
            runnerURL: directory.appendingPathComponent("\(baseName).sh"),
            outputURL: directory.appendingPathComponent("\(baseName).log"),
            pendingStatusURL: directory.appendingPathComponent("\(baseName).status.pending"),
            statusURL: directory.appendingPathComponent("\(baseName).status"),
            startedURL: directory.appendingPathComponent("\(baseName).started")
        )
        let script = script(
            command: command,
            outputURL: artifacts.outputURL,
            pendingStatusURL: artifacts.pendingStatusURL,
            statusURL: artifacts.statusURL,
            startedURL: artifacts.startedURL
        )

        do {
            try Data(script.utf8).write(to: artifacts.runnerURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: runnerPermissions],
                ofItemAtPath: artifacts.runnerURL.path
            )
            return artifacts
        } catch {
            artifacts.removeAll(fileManager: fileManager)
            throw error
        }
    }

    nonisolated static func script(
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
        #!/bin/sh
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

    nonisolated static func invocation(runnerURL: URL) -> String {
        "/bin/sh \(shellQuoted(runnerURL.path))"
    }

    nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
