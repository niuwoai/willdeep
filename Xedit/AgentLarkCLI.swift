//
//  AgentLarkCLI.swift
//  WillDeep
//
//  Thin, argument-array based wrapper around the official @larksuite/cli.
//  Keep this separate from run_command so model-supplied Lark operations
//  do not pass through a free-form shell string.
//

import Foundation
import Darwin

enum AgentLarkCLI {
    nonisolated private static let maxOutputCharacters = 48 * 1024
    nonisolated private static let defaultTimeout: TimeInterval = 120

    nonisolated private static let dangerousArgs: Set<String> = [
        "delete", "remove", "destroy", "revoke", "logout", "reset",
        "permission", "role", "scope", "token", "secret"
    ]

    nonisolated static func executablePath(
        environment: [String: String] = AgentToolRunner.shellEnvironment(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        AgentToolRunner.executablePath(
            commandName: "lark-cli",
            preferredPaths: [
                "\(NSHomeDirectory())/.local/bin/lark-cli",
                "/opt/homebrew/bin/lark-cli",
                "/usr/local/bin/lark-cli",
            ],
            environment: environment,
            isExecutable: isExecutable
        )
    }

    nonisolated static var installCommand: String {
        "npx @larksuite/cli@latest install"
    }

    nonisolated static func commandPreview(arguments: [String]) -> String {
        (["lark-cli"] + arguments).map(AgentToolRunner.shellQuoted).joined(separator: " ")
    }

    nonisolated static func risk(arguments: [String]) -> AgentToolRisk {
        let normalized = arguments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return .read }
        if normalized.contains(where: { dangerousArgs.contains($0) || $0.hasPrefix("--app-secret") }) {
            return .danger
        }
        if normalized.contains("--dry-run") || normalized.contains("--help") || normalized.contains("-h") {
            return .read
        }
        if normalized.first == "auth" {
            guard normalized.count >= 2 else { return .read }
            return ["status", "check", "scopes", "list"].contains(normalized[1]) ? .read : .write
        }
        if normalized.first == "config" {
            guard normalized.count >= 2 else { return .read }
            return ["list", "show", "get", "status"].contains(normalized[1]) ? .read : .write
        }
        if normalized.first == "schema" {
            return .read
        }
        let nonFlagArgs = normalized.filter { !$0.hasPrefix("-") }
        if nonFlagArgs.contains(where: { ["create", "update", "patch", "send", "reply", "append", "write", "complete", "approve", "reject", "transfer", "cancel", "publish"].contains($0) }) {
            return .write
        }
        return .write
    }

    static func run(arguments: [String], timeoutSeconds: Int? = nil) async throws -> AgentToolResult {
        let executable = executablePath()
        guard let executable else {
            throw AgentToolError.commandFailed(
                127,
                "lark-cli not found. Install the official Feishu/Lark CLI first with `\(installCommand)`, then run `lark-cli config init --new` and `lark-cli auth login --recommend`."
            )
        }
        return try await runExecutable(
            executable: executable,
            arguments: normalizedArguments(arguments),
            timeout: timeoutSeconds.map { TimeInterval(max(1, min($0, 600))) } ?? defaultTimeout
        )
    }

    static func runExecutable(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout
    ) async throws -> AgentToolResult {
        let cleanArguments = normalizedArguments(arguments)
        let outcome = await Task.detached(priority: .userInitiated) {
            runProcess(executable: executable, arguments: cleanArguments, timeout: timeout)
        }.value
        let payload = trimmedPayload(outcome: outcome, command: commandPreview(arguments: cleanArguments))
        if outcome.timedOut {
            throw AgentToolError.commandTimeout
        }
        if outcome.exitStatus != 0 {
            throw AgentToolError.commandFailed(outcome.exitStatus, payload)
        }
        let firstLine = outcome.stdout.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return AgentToolResult(
            summary: firstLine.isEmpty ? "lark-cli exit 0" : "lark-cli: \(firstLine.prefix(80))",
            payload: payload
        )
    }

    static func runCapture(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout
    ) async -> ProcessResult {
        await Task.detached(priority: .userInitiated) {
            let outcome = runProcess(executable: executable, arguments: arguments, timeout: timeout)
            return ProcessResult(
                exitStatus: outcome.exitStatus,
                stdout: outcome.stdout,
                stderr: outcome.stderr,
                timedOut: outcome.timedOut
            )
        }.value
    }

    static func installOfficialCLI() async -> ProcessResult {
        await runCapture(
            executable: "/usr/bin/env",
            arguments: ["npx", "@larksuite/cli@latest", "install"],
            timeout: 600
        )
    }

    nonisolated static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector
            .matches(in: text, options: [], range: range)
            .compactMap(\.url)
            .first { url in
                guard let scheme = url.scheme?.lowercased() else { return false }
                return scheme == "http" || scheme == "https"
            }
    }

    nonisolated static func normalizedArguments(_ arguments: [String]) -> [String] {
        arguments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private nonisolated static func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> CommandOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = AgentToolRunner.shellEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return CommandOutcome(exitStatus: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        let runState = LarkCLIRunState()
        let timeoutWorkItem = DispatchWorkItem {
            runState.markTimedOut()
            if process.isRunning {
                process.terminate()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
        process.waitUntilExit()
        timeoutWorkItem.cancel()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandOutcome(
            exitStatus: process.terminationStatus,
            stdout: AgentSandboxPolicy.scrub(stdout),
            stderr: AgentSandboxPolicy.scrub(stderr),
            timedOut: runState.didTimeout
        )
    }

    private nonisolated static func trimmedPayload(outcome: CommandOutcome, command: String) -> String {
        let payload = "command=\(command)\nexit=\(outcome.exitStatus)\n--- stdout ---\n\(outcome.stdout)\n--- stderr ---\n\(outcome.stderr)"
        guard payload.count > maxOutputCharacters else { return payload }
        return String(payload.prefix(maxOutputCharacters)) + "\n...[truncated]"
    }

    private struct CommandOutcome: Sendable {
        let exitStatus: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    struct ProcessResult: Equatable, Sendable {
        let exitStatus: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool

        var combinedOutput: String {
            [stdout, stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        var isSuccess: Bool {
            exitStatus == 0 && !timedOut
        }
    }

    private nonisolated final class LarkCLIRunState: @unchecked Sendable {
        private let lock = NSLock()
        private var timedOut = false

        var didTimeout: Bool {
            lock.lock()
            defer { lock.unlock() }
            return timedOut
        }

        func markTimedOut() {
            lock.lock()
            timedOut = true
            lock.unlock()
        }
    }
}
