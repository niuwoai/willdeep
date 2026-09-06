import Foundation
import Testing
@testable import WillDeep

@Suite("托管执行器启动窗口取消", .timeLimit(.minutes(1)))
struct AgentManagedTurnCancellationTests {
    @MainActor
    @Test("ACP 停止后返回的旧授权不能写文件或创建终端", arguments: [false, true])
    func acpLateApprovalDoesNotExecute(terminal: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acp-late-approval-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("ACP fixture cleanup: \(error)") }
        }
        let marker = root.appendingPathComponent("must-not-exist")
        let script = #"""
        require 'json'
        $stdout.sync = true
        def receive
          JSON.parse(STDIN.gets || abort('unexpected EOF'))
        end
        def emit(object)
          puts JSON.generate(object)
        end
        receive
        emit({'jsonrpc'=>'2.0', 'id'=>'initialize', 'result'=>{'protocolVersion'=>1}})
        receive
        emit({'jsonrpc'=>'2.0', 'id'=>'session', 'result'=>{'sessionId'=>'late-approval'}})
        receive
        terminal = ARGV[0] == 'terminal'
        params = terminal ? {'command'=>'/usr/bin/touch must-not-exist'} : {'path'=>ARGV[1], 'content'=>'unexpected'}
        emit({'jsonrpc'=>'2.0', 'id'=>1, 'method'=>terminal ? 'terminal/create' : 'fs/write_text_file', 'params'=>params})
        receive
        emit({'jsonrpc'=>'2.0', 'id'=>'prompt', 'result'=>{'stopReason'=>'end_turn'}})
        """#
        let approval = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        var writes = 0
        let turn = AgentACPClientTurn(configuration: .init(
            executableURL: URL(fileURLWithPath: "/usr/bin/ruby"),
            adapterArguments: ["-e", script, terminal ? "terminal" : "write", marker.path],
            claudeExecutableURL: URL(fileURLWithPath: "/usr/bin/true"), prompt: "fixture",
            model: nil, sessionID: nil, imagePaths: [], workingDirectory: root,
            environment: ["PATH": "/usr/bin:/bin"], sandboxMode: .escalated,
            permissionMode: "default", secretRedactionValues: []),
            approvalHandler: { _ in
                approval.continuation.yield(())
                for await _ in release.stream { break }
                return .accept
            }, readHandler: nil, writeHandler: { _, _ in writes += 1 },
            eventHandler: { _ in }, processHandler: { _ in })
        let task = Task {
            defer { approval.continuation.finish() }
            return try await turn.run()
        }
        defer { turn.cancel(); release.continuation.finish(); task.cancel() }
        var iterator = approval.stream.makeAsyncIterator()
        let requested = await iterator.next()
        #expect(requested != nil)
        turn.cancel()
        release.continuation.finish()
        do {
            _ = try await task.value
            Issue.record("Cancelled approval unexpectedly completed")
        } catch is CancellationError {
            // The old approval accepted, but ownership has already been revoked.
        } catch { Issue.record("Unexpected late approval error: \(error)") }
        #expect(writes == 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("ACP 记住启动前取消并在协议写入前检查", arguments: [false, true])
    func acpCancellation(afterLaunch: Bool) async throws {
        let started = AsyncStream<Int32>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let turn = AgentACPClientTurn(configuration: .init(
            executableURL: URL(fileURLWithPath: "/bin/sleep"), adapterArguments: ["60"],
            claudeExecutableURL: URL(fileURLWithPath: "/usr/bin/true"), prompt: "fixture",
            model: nil, sessionID: nil, imagePaths: [], workingDirectory: FileManager.default.temporaryDirectory,
            environment: ["PATH": "/usr/bin:/bin"], sandboxMode: .escalated,
            permissionMode: "default", secretRedactionValues: []),
            approvalHandler: nil, readHandler: nil, writeHandler: nil, eventHandler: { _ in },
            processHandler: { pid in
                started.continuation.yield(pid)
                for await _ in release.stream { break }
            })
        if !afterLaunch { turn.cancel() }
        let task = Task {
            defer { started.continuation.finish() }
            return try await turn.run()
        }
        defer { turn.cancel(); release.continuation.finish(); task.cancel() }
        var iterator = started.stream.makeAsyncIterator()
        let pid = await iterator.next()
        #expect((pid != nil) == afterLaunch)
        if afterLaunch { turn.cancel() }
        release.continuation.finish()
        do {
            _ = try await task.value
            Issue.record("Cancelled ACP turn unexpectedly completed")
        } catch is CancellationError {
            // The driver must preserve cancellation, not report a protocol or pipe failure.
        } catch { Issue.record("Unexpected ACP cancellation error: \(error)") }
    }

    @Test("Codex 记住启动前取消并在协议写入前检查", arguments: [false, true])
    func codexCancellation(afterLaunch: Bool) async throws {
        let started = AsyncStream<Int32>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let turn = AgentCodexAppServerTurn(configuration: .init(
            executableURL: URL(fileURLWithPath: "/bin/sleep"), prompt: "fixture",
            model: nil, sessionID: nil, imagePaths: [], workingDirectory: FileManager.default.temporaryDirectory,
            environment: ["PATH": "/usr/bin:/bin"], sandboxMode: .escalated,
            permissionMode: "default", secretRedactionValues: [], serverArguments: ["60"]),
            approvalHandler: nil, eventHandler: { _ in }, processHandler: { pid in
                started.continuation.yield(pid)
                for await _ in release.stream { break }
            })
        if !afterLaunch { turn.cancel() }
        let task = Task {
            defer { started.continuation.finish() }
            return try await turn.run()
        }
        defer { turn.cancel(); release.continuation.finish(); task.cancel() }
        var iterator = started.stream.makeAsyncIterator()
        let pid = await iterator.next()
        #expect((pid != nil) == afterLaunch)
        if afterLaunch { turn.cancel() }
        release.continuation.finish()
        do {
            _ = try await task.value
            Issue.record("Cancelled Codex turn unexpectedly completed")
        } catch is CancellationError {
            // Stopping a registered controller does not depend on cancelling its Swift task.
        } catch { Issue.record("Unexpected Codex cancellation error: \(error)") }
    }
}
