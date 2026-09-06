import Foundation
import Testing
@testable import WillDeep

@MainActor
@Suite("结构化进程输入隔离", .timeLimit(.minutes(1)))
struct AgentExecutorInputIsolationTests {
    @Test("不读 stdin 或提前退出的子进程不影响宿主和其他进程", arguments: [false, true])
    func blockedInputDoesNotBlockLifecycleOrOtherInputs(_ exitsImmediately: Bool) async throws {
        let registry = AgentJobRegistry()
        let runtimeID = UUID()
        defer { registry.killAllAlive(forRuntime: runtimeID) }
        let blocker = try registry.startExecutor(specification: .init(
            executor: .codexCLI, executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: [exitsImmediately ? "0" : "30"], workingDirectory: FileManager.default.temporaryDirectory,
            environment: ["PATH": "/usr/bin:/bin"], standardInput: Data(repeating: 65, count: 1_048_576),
            sandboxMode: .escalated, displayCommand: "non-reading stdin fixture", decoder: CodexJSONLEventDecoder()),
            runtimeID: runtimeID, timeoutSeconds: 1, publishesCompletion: false)
        let payload = Data("independent input".utf8)
        let script = """
        require 'json'
        count = STDIN.read.bytesize
        puts JSON.generate(type: 'item.completed', item: {id: 'fixture', type: 'agent_message', text: "bytes=#{count}"})
        puts JSON.generate(type: 'turn.completed')
        """
        let reader = try registry.startExecutor(specification: .init(
            executor: .codexCLI, executableURL: URL(fileURLWithPath: "/usr/bin/ruby"),
            arguments: ["-e", script], workingDirectory: FileManager.default.temporaryDirectory,
            environment: ["PATH": "/usr/bin:/bin"], standardInput: payload,
            sandboxMode: .escalated, displayCommand: "independent stdin fixture", decoder: CodexJSONLEventDecoder()),
            runtimeID: runtimeID, timeoutSeconds: 10, publishesCompletion: false)
        // Observe real terminal states, not a guessed main-actor delay. The
        // child sleeps 30s; only a working lifecycle timer yields .timedOut.
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline,
              registry.job(id: blocker.id)?.isAlive == true || registry.job(id: reader.id)?.isAlive == true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(registry.job(id: blocker.id)?.status == (exitsImmediately ? .completed : .timedOut))
        #expect(registry.job(id: reader.id)?.status == .completed)
        #expect(registry.executorResultText(id: reader.id) == "bytes=\(payload.count)")
        #expect(registry.pendingCompletionCount(forRuntime: runtimeID) == 0)
    }
}
