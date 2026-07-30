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

        // The wrapper lives in a runner file; only a short path is typed into
        // the terminal. Inlining it would overflow the pty input queue.
        #expect(FileManager.default.fileExists(atPath: artifacts.runnerURL.path))
        #expect(!artifacts.invocation.contains(command))
        // Quoted, not raw: this suite's directory name contains a single
        // quote, so the path is escaped inside the invocation.
        #expect(artifacts.invocation.contains(
            AgentDelegatedTerminalRunner.shellQuoted(artifacts.runnerURL.path)
        ))

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

    @Test("delegated invocation stays under the pty input-queue limit")
    func invocationStaysSmallEnoughForThePTY() throws {
        let directory = try makeTemporaryDirectory(named: "runner pty budget")
        defer { try? FileManager.default.removeItem(at: directory) }

        // A realistic worst case: a multi-kilobyte CJK prompt. Typed inline
        // this used to be truncated mid-path by the tty input queue, leaving
        // the shell parked at a PS2 prompt until the task timed out.
        let prompt = String(repeating: "让 claude code 检查一下这个问题是否真的存在。", count: 200)
        let command = AgentToolRunner.claudeCodeCommandLine(
            executable: "/usr/local/bin/claude",
            prompt: prompt,
            permissionMode: "acceptEdits",
            model: nil
        )
        let artifacts = try AgentDelegatedTerminalRunner.create(
            command: command,
            workingDirectory: directory.path,
            directory: directory,
            token: "PTYBUDGET"
        )
        defer { artifacts.removeAll() }

        #expect(command.utf8.count > 4000)
        #expect(artifacts.invocation.utf8.count
            <= AgentTerminalTab.maximumAutomationCommandBytes)
        #expect(!artifacts.invocation.contains("\n"))
    }

    @Test("runner echoes the real command to the screen but not into the log")
    func echoesCommandWithoutPollutingCapturedOutput() throws {
        let directory = try makeTemporaryDirectory(named: "runner banner")
        defer { try? FileManager.default.removeItem(at: directory) }

        let marker = "WILLDEEP-BANNER-MARKER"
        let artifacts = try AgentDelegatedTerminalRunner.create(
            command: "printf '%s' 'real-output' # \(marker)",
            directory: directory,
            token: "BANNER"
        )
        defer { artifacts.removeAll() }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", artifacts.invocation]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let screen = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        process.waitUntilExit()

        // Visible to the user reviewing the tab…
        #expect(screen.contains(marker))
        #expect(screen.contains(artifacts.runnerURL.path))
        // …but the captured log the agent reads stays clean.
        let log = try String(contentsOf: artifacts.outputURL, encoding: .utf8)
        #expect(log == "real-output")
        #expect(!log.contains(marker))
    }

    @Test("runner file is created private to the user")
    func runnerFileIsPrivate() throws {
        let directory = try makeTemporaryDirectory(named: "runner perms")
        defer { try? FileManager.default.removeItem(at: directory) }

        let artifacts = try AgentDelegatedTerminalRunner.create(
            command: "/bin/pwd",
            directory: directory,
            token: "PERMS"
        )
        defer { artifacts.removeAll() }

        let attributes = try FileManager.default
            .attributesOfItem(atPath: artifacts.runnerURL.path)
        #expect(attributes[.posixPermissions] as? Int
            == AgentDelegatedTerminalRunner.runnerPermissions)
    }

    @Test("screen echo is clipped without clipping what actually runs")
    func clipsEchoButNotExecution() throws {
        let directory = try makeTemporaryDirectory(named: "runner clip")
        defer { try? FileManager.default.removeItem(at: directory) }

        let longComment = String(repeating: "x", count: 10_000)
        let command = "printf '%s' 'ran' # \(longComment)"
        let artifacts = try AgentDelegatedTerminalRunner.create(
            command: command,
            directory: directory,
            token: "CLIP"
        )
        defer { artifacts.removeAll() }

        let echoed = AgentDelegatedTerminalRunner.echoedCommand(command)
        #expect(echoed.count < command.count)
        #expect(echoed.contains("truncated for display"))

        let script = try String(contentsOf: artifacts.runnerURL, encoding: .utf8)
        #expect(script.contains(command))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", artifacts.invocation]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(try String(contentsOf: artifacts.outputURL, encoding: .utf8) == "ran")
        #expect(try String(contentsOf: artifacts.statusURL, encoding: .utf8) == "0")
    }

    @Test("delegated command enters the requested workspace")
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
    }

    @Test("delegated artifacts are removed together")
    func removesRunnerFileOnCleanup() throws {
        let directory = try makeTemporaryDirectory(named: "runner cleanup")
        defer { try? FileManager.default.removeItem(at: directory) }

        let artifacts = try AgentDelegatedTerminalRunner.create(
            command: "/bin/pwd",
            directory: directory,
            token: "CLEANUP"
        )
        #expect(FileManager.default.fileExists(atPath: artifacts.runnerURL.path))

        artifacts.removeAll()

        #expect(!FileManager.default.fileExists(atPath: artifacts.runnerURL.path))
        #expect(!FileManager.default.fileExists(atPath: artifacts.outputURL.path))
        #expect(!FileManager.default.fileExists(atPath: artifacts.statusURL.path))
        #expect(!FileManager.default.fileExists(atPath: artifacts.startedURL.path))
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

    @Test("live output snapshots strip terminal controls and keep a bounded tail")
    func liveOutputSnapshotIsReadableAndBounded() throws {
        let lines = (1...12).map { "step-\($0)" }
        let raw = "\u{001B}[32m" + lines.joined(separator: "\n") + "\u{001B}[0m"

        let snapshot = AgentDelegatedLiveOutputSnapshot.make(
            from: raw,
            maximumLines: 4,
            maximumCharacters: 200
        )

        #expect(snapshot.currentActivity == "step-12")
        #expect(snapshot.currentActivity?.contains("\n") == false)
        let output = try #require(snapshot.recentOutput)
        #expect(output == "step-9\nstep-10\nstep-11\nstep-12")
        #expect(!output.contains("\u{001B}"))

        let longActivity = AgentDelegatedLiveOutputSnapshot.make(
            from: String(repeating: "x", count: 240)
        ).currentActivity
        #expect(longActivity?.count == 181)
        #expect(longActivity?.hasPrefix("…") == true)
        #expect(longActivity?.contains("\n") == false)
    }

    @Test("live output reader only returns the bounded file tail")
    func liveOutputReaderBoundsDiskReads() throws {
        let directory = try makeTemporaryDirectory(named: "runner live tail")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("executor.log")
        let prefix = String(repeating: "old-output\n", count: 200)
        try Data((prefix + "latest-one\nlatest-two\n").utf8)
            .write(to: outputURL, options: .atomic)

        let tail = AgentDelegatedTerminalRunner.readOutputTail(
            from: outputURL,
            maximumBytes: 48
        )

        #expect(tail.utf8.count <= 48)
        #expect(tail.hasSuffix("latest-one\nlatest-two\n"))
        #expect(tail.components(separatedBy: "old-output").count < 6)
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillDeepTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
