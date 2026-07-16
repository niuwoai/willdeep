import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct AgentDelegatedTerminalRunnerTests {
    @Test("delegated runner preserves a long prompt with shell metacharacters")
    func preservesLongSpecialPrompt() throws {
        let directory = try makeTemporaryDirectory(named: "runner special ' path")
        defer { try? FileManager.default.removeItem(at: directory) }

        let mockCLI = directory.appendingPathComponent("mock-claude")
        let mockScript = """
        #!/bin/sh
        [ "$1" = "-p" ] || exit 64
        printf '%s' "$2"
        exit 7
        """
        try Data(mockScript.utf8).write(to: mockCLI, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: mockCLI.path
        )

        let prompt = "开头 ' 单引号 `反引号` $(不会执行) $HOME\\n" + String(repeating: "长提示🙂\n", count: 12_000)
        let command = AgentToolRunner.claudeCodeCommandLine(
            executable: mockCLI.path,
            prompt: prompt,
            permissionMode: "acceptEdits",
            model: nil
        )
        let artifacts = try AgentDelegatedTerminalRunner.create(
            command: command,
            directory: directory,
            token: "SPECIAL"
        )
        defer { artifacts.removeAll() }

        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("willdeep-terminal-SPECIAL.sh").path
        ))
        #expect(artifacts.invocation.contains(command))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", artifacts.invocation]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(FileManager.default.fileExists(atPath: artifacts.startedURL.path))
        #expect(try String(contentsOf: artifacts.statusURL, encoding: .utf8) == "7")
        #expect(try String(contentsOf: artifacts.outputURL, encoding: .utf8) == prompt)
    }

    @Test("delegated command enters the requested workspace without a runner file")
    func entersRequestedWorkspaceDirectly() throws {
        let directory = try makeTemporaryDirectory(named: "runner workspace")
        defer { try? FileManager.default.removeItem(at: directory) }

        let artifacts = try AgentDelegatedTerminalRunner.create(
            command: "/bin/pwd",
            workingDirectory: directory.path,
            directory: directory,
            token: "WORKSPACE"
        )
        defer { artifacts.removeAll() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", artifacts.invocation]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: artifacts.outputURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == directory.path)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("willdeep-terminal-WORKSPACE.sh").path
        ))
    }

    @Test("direct delegated invocation works in POSIX shells")
    func invocationWorksInPOSIXShells() throws {
        let directory = try makeTemporaryDirectory(named: "runner shells ' path")
        defer { try? FileManager.default.removeItem(at: directory) }

        let shells = ["/bin/sh", "/bin/bash", "/bin/zsh"]

        for (index, shell) in shells.enumerated() {
            let artifacts = try AgentDelegatedTerminalRunner.create(
                command: "printf '%s' \(AgentDelegatedTerminalRunner.shellQuoted((shell as NSString).lastPathComponent))",
                directory: directory,
                token: "SHELL\(index)"
            )
            defer { artifacts.removeAll() }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", artifacts.invocation]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()

            #expect(process.terminationStatus == 0)
            #expect(try String(contentsOf: artifacts.statusURL, encoding: .utf8) == "0")
            #expect(
                try String(contentsOf: artifacts.outputURL, encoding: .utf8)
                    == (shell as NSString).lastPathComponent
            )
        }
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillDeepTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
