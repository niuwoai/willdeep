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

        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: artifacts.runnerURL.path)[.posixPermissions] as? NSNumber
        )
        #expect(permissions.intValue == AgentDelegatedTerminalRunner.runnerPermissions)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [artifacts.runnerURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(FileManager.default.fileExists(atPath: artifacts.startedURL.path))
        #expect(try String(contentsOf: artifacts.statusURL, encoding: .utf8) == "7")
        #expect(try String(contentsOf: artifacts.outputURL, encoding: .utf8) == prompt)
    }

    @Test("short runner invocation works from sh, bash, zsh, and fish when installed")
    func invocationWorksAcrossInteractiveShells() throws {
        let directory = try makeTemporaryDirectory(named: "runner shells ' path")
        defer { try? FileManager.default.removeItem(at: directory) }

        var shells = ["/bin/sh", "/bin/bash", "/bin/zsh"]
        let fish = "/opt/homebrew/bin/fish"
        if FileManager.default.isExecutableFile(atPath: fish) {
            shells.append(fish)
        }

        for (index, shell) in shells.enumerated() {
            let artifacts = try AgentDelegatedTerminalRunner.create(
                command: "printf '%s' \(AgentDelegatedTerminalRunner.shellQuoted((shell as NSString).lastPathComponent))",
                directory: directory,
                token: "SHELL\(index)"
            )
            defer { artifacts.removeAll() }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = shell == fish
                ? ["--no-config", "-c", artifacts.invocation]
                : ["-c", artifacts.invocation]
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
