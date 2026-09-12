import Foundation
import Testing
@testable import WillDeep

/// 台账不得写进用户真实的 AgentAudit。
///
/// 这不是洁癖问题。修之前，每跑一遍单测就往用户的 `worker-timing.jsonl` 灌一批
/// 桩运行：9 天积了 4060 条，其中 2755 条 `deep` 全是桩（rounds=1、工具调用 0、
/// token 1，模型里有 `test` / `test-model-16k`，父运行时 2212 个在磁盘上没有
/// 对应会话文件）。照那份数据算工种分布会得出「deep 占 68%、运维占 1%」，而
/// 真实开销的 98% 在 32 次 ops_runner 上——排查时正是被它带偏了一轮。
@Suite("Worker 计时台账的测试隔离")
struct AgentWorkerTimingLogIsolationTests {
    @Test("测试进程里台账落到临时目录，不碰用户的 AgentAudit")
    func defaultURLIsSandboxedUnderTests() {
        // 这个测试自己就跑在测试进程里，所以判据必须为真——它同时也是
        // isRunningUnderTests 那四项判据在本套件下确实命中的证据。
        #expect(AgentWorkerTimingLog.isRunningUnderTests)

        let url = AgentWorkerTimingLog.defaultURL()
        let path = url.path
        #expect(!path.contains("Application Support/WillDeep/AgentAudit"))
        #expect(path.hasPrefix(FileManager.default.temporaryDirectory.path))
        // 一个测试进程一份文件：并行跑的 suite 不互相追加。
        #expect(url.lastPathComponent
            == "\(ProcessInfo.processInfo.processIdentifier)-\(AgentWorkerTimingLog.fileName)")
    }

    @Test("共享写入器用的就是这个被隔离的路径")
    func sharedWriterUsesTheSandboxedURL() async {
        // shared 是 `AgentWorkerTimingLogWriter(url: AgentWorkerTimingLog.defaultURL())`，
        // 所以改 defaultURL 一处就能全覆盖；这条钉住这个联系，防止以后有人
        // 给 shared 单独写死一个路径。
        let url = await AgentWorkerTimingLogWriter.shared.url
        #expect(url == AgentWorkerTimingLog.defaultURL())
        #expect(!url.path.contains("Application Support/WillDeep/AgentAudit"))
    }

    @Test("真实写入落在隔离目录里，且内容仍是可解析的一行 JSON")
    func appendWritesToTheSandboxedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("worker-timing-isolation-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("worker-timing.jsonl")
        let writer = AgentWorkerTimingLogWriter(url: url)

        let entry = AgentWorkerTimingLog.WorkerRunEntry(
            runID: UUID(),
            sessionID: UUID(),
            userMessageID: nil,
            profileID: "ops_runner",
            source: "modelSpawn",
            status: "completed",
            model: "fixture-model",
            providerID: "fixture",
            requestedAt: Date(),
            startedAt: Date(),
            finishedAt: Date(),
            rounds: 1,
            toolInvocations: 0,
            promptTokens: 1,
            completionTokens: 0,
            totalTokens: 1
        )
        guard let line = AgentWorkerTimingLog.encodeLine(entry) else {
            Issue.record("台账行编码失败")
            return
        }
        await writer.append(line)

        let text = try String(contentsOf: url, encoding: .utf8)
        let rows = text.split(separator: "\n").filter { !$0.isEmpty }
        #expect(rows.count == 1)
        let decoded = try JSONSerialization.jsonObject(with: Data(rows[0].utf8)) as? [String: Any]
        #expect(decoded?["profileID"] as? String == "ops_runner")
        #expect(decoded?["kind"] as? String == "worker_run")
    }
}
