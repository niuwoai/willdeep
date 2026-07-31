//
//  AgentDelegatedTerminalRunner.swift
//  Xedit
//
//  Builds a private POSIX-sh runner for delegated coding agents. The visible
//  terminal receives only a short `/bin/sh <runner>` invocation.
//
//  Why the runner file exists (do NOT inline the wrapper again): the
//  invocation is typed into an interactive terminal's pty as *input*. An
//  interactive shell echoes every input byte back, and readline redraws whole
//  logical lines — a multi-kilobyte wrapper carrying a CJK prompt amplifies
//  into far more echo output than the visible view can drain. Once the tty
//  output queue backs up, the tty *input* queue overflows and the kernel
//  silently discards the remaining bytes. The shell then sees a truncated
//  command: mangled UTF-8, a broken temp-file path, and an unterminated quote
//  that parks it at a PS2 continuation prompt forever, so the wrapper never
//  writes its status file and the delegated task hangs until timeout. A
//  one-line invocation stays far below that threshold.
//
//  Users still get to inspect the real command: the runner echoes it to the
//  screen before executing. That travels the *output* path, which is not
//  subject to input-queue overflow, and stays out of the captured log so the
//  tool result keeps only the delegated CLI's own output.
//

import Foundation

struct AgentDelegatedTerminalArtifacts {
    let command: String
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

nonisolated struct AgentDelegatedLiveOutputSnapshot: Equatable, Sendable {
    let currentActivity: String?
    let recentOutput: String?

    static func make(
        from rawOutput: String,
        maximumLines: Int = 8,
        maximumCharacters: Int = 2_400
    ) -> Self {
        let withoutANSI = AgentDelegatedTerminalRunner.removingTerminalControlSequences(
            from: rawOutput
        )
        let lines = withoutANSI
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return Self(currentActivity: nil, recentOutput: nil)
        }

        let selectedLines = Array(lines.suffix(max(maximumLines, 1)))
        let lastLine = selectedLines.last ?? ""
        let activity = lastLine.count > 180
            ? "…" + String(lastLine.suffix(180))
            : lastLine
        let output = clippedSuffix(
            selectedLines.joined(separator: "\n"),
            maximumCharacters: max(maximumCharacters, 1)
        )
        return Self(
            currentActivity: activity.isEmpty ? nil : activity,
            recentOutput: output.isEmpty ? nil : output
        )
    }

    private static func clippedSuffix(
        _ value: String,
        maximumCharacters: Int
    ) -> String {
        guard value.count > maximumCharacters else { return value }
        return "…\n" + String(value.suffix(maximumCharacters))
    }
}

enum AgentDelegatedTerminalRunner {
    nonisolated static let runnerPermissions = 0o600
    nonisolated static let maximumLiveOutputBytes: UInt64 = 16 * 1_024

    /// Upper bound on the command echoed to the visible terminal. The full
    /// text always reaches the shell through the runner file; this only caps
    /// how much is mirrored to the screen so a huge prompt cannot flood the
    /// scrollback. The runner path is printed alongside, so the untruncated
    /// command remains inspectable.
    nonisolated static let maximumEchoedCommandLength = 4000

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
            runnerURL: directory.appendingPathComponent("\(baseName).sh"),
            outputURL: directory.appendingPathComponent("\(baseName).log"),
            pendingStatusURL: directory.appendingPathComponent("\(baseName).status.pending"),
            statusURL: directory.appendingPathComponent("\(baseName).status"),
            startedURL: directory.appendingPathComponent("\(baseName).started")
        )
        guard fileManager.isWritableFile(atPath: directory.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let script = script(
            command: artifacts.command,
            runnerURL: artifacts.runnerURL,
            outputURL: artifacts.outputURL,
            pendingStatusURL: artifacts.pendingStatusURL,
            statusURL: artifacts.statusURL,
            startedURL: artifacts.startedURL
        )
        try Data(script.utf8).write(to: artifacts.runnerURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: runnerPermissions],
            ofItemAtPath: artifacts.runnerURL.path
        )
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

    /// What the user sees before the command runs. Long commands are clipped
    /// for the screen only — never for execution.
    nonisolated static func echoedCommand(_ command: String) -> String {
        guard command.count > maximumEchoedCommandLength else { return command }
        return String(command.prefix(maximumEchoedCommandLength)) + "\n… [truncated for display]"
    }

    nonisolated static func script(
        command: String,
        runnerURL: URL,
        outputURL: URL,
        pendingStatusURL: URL,
        statusURL: URL,
        startedURL: URL
    ) -> String {
        let output = shellQuoted(outputURL.path)
        let pendingStatus = shellQuoted(pendingStatusURL.path)
        let status = shellQuoted(statusURL.path)
        let started = shellQuoted(startedURL.path)
        // The banner is deliberately outside the `tee` subshell: it is for the
        // human watching the tab, not part of the delegated command's output.
        return """
        umask 077
        set +e
        printf '%s\\n' \(shellQuoted(echoedCommand(command)))
        printf '%s\\n' \(shellQuoted("[willdeep] runner: \(runnerURL.path)"))
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

    nonisolated static func readOutputTail(
        from outputURL: URL,
        maximumBytes: UInt64 = maximumLiveOutputBytes
    ) -> String {
        guard let handle = try? FileHandle(forReadingFrom: outputURL) else {
            return ""
        }
        defer { try? handle.close() }

        guard let endOffset = try? handle.seekToEnd() else { return "" }
        let startOffset = endOffset > maximumBytes ? endOffset - maximumBytes : 0
        do {
            try handle.seek(toOffset: startOffset)
            guard let data = try handle.readToEnd(), !data.isEmpty else {
                return ""
            }
            var output = String(decoding: data, as: UTF8.self)
            if startOffset > 0, let firstNewline = output.firstIndex(of: "\n") {
                output.removeSubrange(output.startIndex...firstNewline)
            }
            return output
        } catch {
            return ""
        }
    }

    nonisolated static func removingTerminalControlSequences(
        from value: String
    ) -> String {
        let escape = "\u{001B}"
        let bell = "\u{0007}"
        let pattern = "\(escape)(?:\\[[0-?]*[ -/]*[@-~]|\\][^\(bell)]*(?:\(bell)|\(escape)\\\\))"
        return value.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
    }

    nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
