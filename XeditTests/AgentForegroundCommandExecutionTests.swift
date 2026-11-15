import Darwin
import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite("前台命令的双流收集、超时与取消", .timeLimit(.minutes(3)))
struct AgentForegroundCommandExecutionTests {
    private static let outputLimit = 32 * 1024
    private static let ordinaryTimeout = 30.0
    // 与夹具的 120s 自退出期限拉开距离，只检验有界返回，不做性能基准。
    private nonisolated static let returnBudget = 30.0

    @Test("普通退出保留 stdout、stderr 与结构化退出码")
    func ordinaryOutputAndExitCode() async throws {
        try await withDirectory { directory in
            let result = try await run(
                "printf 'ordinary stdout\\n'; printf 'ordinary stderr\\n' >&2",
                directory: directory
            )
            #expect(result.commandExitCode == 0)
            #expect(result.summary == "exit 0: ordinary stdout")
            #expect(result.payload == "exit=0\n--- stdout ---\nordinary stdout\n\n--- stderr ---\nordinary stderr\n")
        }
    }

    @Test("非零退出保留原始状态码和两条输出流")
    func nonzeroExitPreservesBothStreams() async throws {
        try await withDirectory { directory in
            do {
                _ = try await run(
                    "printf 'failure stdout\\n'; printf 'failure stderr\\n' >&2; exit 23",
                    directory: directory
                )
                Issue.record("非零退出应抛出 commandFailed")
            } catch let error as AgentToolError {
                guard case .commandFailed(let status, let output) = error else {
                    Issue.record("预期 commandFailed，实际为 \(error)")
                    return
                }
                #expect(status == 23)
                #expect(output == "exit=23\n--- stdout ---\nfailure stdout\n\n--- stderr ---\nfailure stderr\n")
            }
        }
    }

    @Test("后台 AND-list 持有管道时，根退出不能撤销显式 1s 超时", arguments: HeldStreams.allCases)
    func exitedRootStillHonorsTimeout(heldStreams: HeldStreams) async throws {
        try await withRunningFixture(heldStreams: heldStreams, keepRootAlive: false, timeout: 1) { fixture, task in
            // 观测在非主线程进行；满载时不能让 MainActor 的轮询饥饿冒充进程未退出。
            let (outcome, elapsed) = try await Task.detached {
                try await fixture.waitForStage(rootAlive: false)
                let startedAt = Date()
                let outcome = await task.result
                return (outcome, Date().timeIntervalSince(startedAt))
            }.value

            switch outcome {
            case .failure(let error):
                guard let toolError = error as? AgentToolError, case .commandTimeout = toolError else {
                    Issue.record("管道等待超过显式期限应抛出 commandTimeout，实际为 \(error)")
                    return
                }
            case .success:
                Issue.record("仍被后台 AND-list 持有的管道不应绕过显式 1s 超时")
            }
            #expect(elapsed < Self.returnBudget, "根退出后等待管道耗时 \(elapsed)s，应小于 \(Self.returnBudget)s")
        }
    }

    @Test("取消在根仍存活和根已退出两阶段均能结束管道等待", arguments: [true, false])
    func cancellationStopsBothLifecycleStages(rootAlive: Bool) async throws {
        try await withRunningFixture(heldStreams: .both, keepRootAlive: rootAlive, timeout: 150) { fixture, task in
            // PID 状态和服务 ready 同时满足才取消，避免 sleep 0.2 猜测启动阶段。
            // 直接在观测任务里 cancel，避免根退出后的 idle 收尾先于主线程再次获调度。
            let (outcome, elapsed) = try await Task.detached {
                try await fixture.waitForStage(rootAlive: rootAlive)
                let cancelledAt = Date()
                task.cancel()
                let outcome = await task.result
                return (outcome, Date().timeIntervalSince(cancelledAt))
            }.value

            switch outcome {
            case .failure(let error):
                #expect(error is CancellationError, "取消应保留 CancellationError，实际为 \(error)")
            case .success:
                Issue.record("取消前台命令应抛出 CancellationError")
            }
            #expect(elapsed < Self.returnBudget, "取消后等待 \(elapsed)s，应小于 \(Self.returnBudget)s")
        }
    }

    @Test("超过管道缓存的双流输出不会互相阻塞，并保留既有截断")
    func largeInterleavedOutputRemainsBounded() async throws {
        try await withDirectory { directory in
            let chunkSize = 1024
            let chunksPerStream = 256
            let stdoutChunk = String(repeating: "O", count: chunkSize)
            let stderrChunk = String(repeating: "E", count: chunkSize)
            let command = """
            __out=\(ShellFixture.quote(stdoutChunk)); __err=\(ShellFixture.quote(stderrChunk))
            printf 'stdout-start\\n'; printf 'stderr-start\\n' >&2
            __i=0
            while [ "$__i" -lt \(chunksPerStream) ]; do
                printf '%s' "$__out"
                printf '%s' "$__err" >&2
                __i=$((__i + 1))
            done
            printf 'stdout-end\\n'; printf 'stderr-end\\n' >&2
            """
            let result = try await run(command, directory: directory)

            #expect(result.commandExitCode == 0)
            #expect(result.payload.count <= Self.outputLimit)
            #expect(result.payload.hasPrefix("exit=0\n--- stdout ---\nstdout-start\n"))
            #expect(result.payload.contains(stdoutChunk))
            #expect(result.payload.contains(stderrChunk))
            #expect(result.payload.contains("middle output truncated"))
            #expect(result.payload.contains("...[truncated]"))
            // 现有协议按每流前缀收集，再对组合结果保留首尾；不能变成无限输出。
            #expect(!result.payload.contains("stdout-end"))
            #expect(!result.payload.contains("stderr-end"))
        }
    }

    @Test("正常退出能收齐两流最后一批字节，包括无换行的尾部")
    func normalExitDrainsCompleteTails() async throws {
        try await withDirectory { directory in
            let stdout = String(repeating: "stdout body\n", count: 600) + "final stdout without newline"
            let stderr = String(repeating: "stderr body\n", count: 600) + "final stderr without newline"
            let command = "printf '%s' \(ShellFixture.quote(stdout)); printf '%s' \(ShellFixture.quote(stderr)) >&2"
            let result = try await run(command, directory: directory)

            #expect(result.commandExitCode == 0)
            #expect(result.payload == "exit=0\n--- stdout ---\n\(stdout)\n--- stderr ---\n\(stderr)")
            #expect(!result.payload.contains("[truncated]"))
        }
    }

    private func run(_ command: String, directory: URL, timeout: Double = ordinaryTimeout) async throws -> AgentToolResult {
        try await AgentToolRunner.run(
            name: "run_command",
            arguments: [
                "command": .string(command),
                "run_in_background": .bool(false),
                "timeout_seconds": .number(timeout)
            ],
            context: AgentToolContext(
                rootDirectory: directory,
                localCommandEnvironment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"],
                sandboxMode: .escalated
            )
        )
    }

    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreground-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("清理前台命令测试目录失败：\(error)") }
        }
        try await body(directory)
    }

    private func withRunningFixture(
        heldStreams: HeldStreams,
        keepRootAlive: Bool,
        timeout: Double,
        body: (ShellFixture, Task<AgentToolResult, Error>) async throws -> Void
    ) async throws {
        try await withDirectory { directory in
            let fixture = try ShellFixture(directory: directory)
            let task = Task {
                try await run(fixture.command(holding: heldStreams, keepRootAlive: keepRootAlive),
                              directory: directory, timeout: timeout)
            }
            var bodyError: (any Error)?
            do { try await body(fixture, task) }
            catch { bodyError = error }

            // 即使断言失败或观测超时，也先开门、取消并 join，之后才删除临时目录。
            do { try Data().write(to: fixture.releaseGate) }
            catch { Issue.record("释放前台命令夹具失败：\(error)") }
            task.cancel()
            _ = await task.result
            do { try await Task.detached { try await fixture.waitForCleanup() }.value }
            catch { Issue.record("前台命令夹具未完成清理：\(error)") }
            if let bodyError { throw bodyError }
        }
    }

    nonisolated enum HeldStreams: String, CaseIterable, Sendable {
        case both
        case stdout
        case stderr
    }

    private nonisolated struct ShellFixture: Sendable {
        let directory: URL
        var releaseGate: URL { directory.appendingPathComponent("release.gate") }
        private var readyMarker: URL { directory.appendingPathComponent("service.ready") }
        private var rootStageMarker: URL { directory.appendingPathComponent("root.stage") }
        private var rootPIDFile: URL { directory.appendingPathComponent("root.pid") }
        private var holderPIDFile: URL { directory.appendingPathComponent("holder.pid") }
        private var servicePIDFile: URL { directory.appendingPathComponent("service.pid") }

        init(directory: URL) throws {
            self.directory = directory
            // 有限 600 次，每次 0.2s。即使旧实现堵在 EOF、测试宿主被杀或清理未运行，
            // 服务也会自行退出；没有网络、数据库、Keychain 或持久服务。
            let service = """
            trap 'exit 0' TERM HUP INT
            printf '%s\\n' "$$" > \(Self.quote(servicePIDFile.path))
            printf ready > \(Self.quote(readyMarker.path))
            __wd=0
            while [ ! -e \(Self.quote(releaseGate.path)) ] && [ "$__wd" -lt 600 ]; do
                /bin/sleep 0.2
                __wd=$((__wd + 1))
            done
            """
            try service.write(to: directory.appendingPathComponent("service.sh"), atomically: true, encoding: .utf8)
        }

        func command(holding streams: HeldStreams, keepRootAlive: Bool) -> String {
            // 与客户命令相同的 `cd && service > log 2>&1 &` 结构。
            // 末尾 builtin 确保等待服务的 AND-list shell 不会被 exec 优化掉。
            let andList = "cd \(Self.quote(directory.path)) && /bin/sh service.sh > service.log 2>&1 && :"
            let background: String
            switch streams {
            case .both: background = andList + " &"
            case .stdout: background = "{ \(andList); } 2>/dev/null &"
            case .stderr: background = "{ \(andList); } >/dev/null &"
            }
            let lastCommand = keepRootAlive ? "wait \"$__job\"" : "exit 0"
            return """
            printf '%s\\n' "$$" > \(Self.quote(rootPIDFile.path))
            \(background)
            __job=$!
            printf '%s\\n' "$__job" > \(Self.quote(holderPIDFile.path))
            printf staged > \(Self.quote(rootStageMarker.path))
            \(lastCommand)
            """
        }

        func waitForStage(rootAlive: Bool) async throws {
            let deadline = Date().addingTimeInterval(45)
            repeat {
                if FileManager.default.fileExists(atPath: readyMarker.path),
                   FileManager.default.fileExists(atPath: rootStageMarker.path),
                   let rootPID = try readPID(rootPIDFile),
                   Self.isAlive(rootPID) == rootAlive {
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            } while Date() < deadline
            throw FixtureError.stageNotReached(rootAlive: rootAlive)
        }

        func waitForCleanup() async throws {
            let deadline = Date().addingTimeInterval(30)
            repeat {
                let rootAlive = try readPID(rootPIDFile).map(Self.isAlive) ?? false
                let holderAlive = try readPID(holderPIDFile).map(Self.isAlive) ?? false
                let serviceAlive = try readPID(servicePIDFile).map(Self.isAlive) ?? false
                if !rootAlive && !holderAlive && !serviceAlive { return }
                try await Task.sleep(for: .milliseconds(20))
            } while Date() < deadline
            throw FixtureError.cleanupTimedOut
        }

        private func readPID(_ url: URL) throws -> pid_t? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return pid_t(try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        private static func isAlive(_ pid: pid_t) -> Bool {
            pid > 0 && (Darwin.kill(pid, 0) == 0 || errno == EPERM)
        }

        static func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    private nonisolated enum FixtureError: Error {
        case stageNotReached(rootAlive: Bool)
        case cleanupTimedOut
    }
}
