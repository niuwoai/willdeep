import Foundation
import Testing
@testable import WillDeep

@MainActor
// .timeLimit 放到 3 分钟：这个 suite 里的用例要等 waitForTerminal，而那是无
// 界的 Combine 订阅，靠 suite 的时限兜底。满载全量下它被 60 秒切断过（实测
// commandStreamsAsOwnedRawOutput 的 persistent=false 那个参数化用例）。时限
// 是挂死兜底，不是性能判据，所以放宽不削弱任何断言。
@Suite("Daemon 实际传输退出回执", .serialized, .timeLimit(.minutes(3)))
struct AgentDaemonExitReceiptTests {
    @MainActor private struct Fixture {
        let backend: DaemonRuntimeBackend
        let session: URLSession
        let token: String
        let registry: AgentJobRegistry
        let runtimeID: UUID
        let turnID: UUID
        let context: AgentToolContext
        var specification: AgentExecutorProcessSpecification {
            .init(executor: .codexCLI, executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [], workingDirectory: URL(fileURLWithPath: "/workspace"), environment: [:],
                standardInput: Data(), sandboxMode: .escalated, displayCommand: "daemon fixture", decoder: CodexJSONLEventDecoder())
        }
        func cleanup() {
            for job in registry.jobs {
                registry.finishManagedExecutor(id: job.id, status: .failed, exitCode: -1, exitConfirmed: true)
            }
            session.invalidateAndCancel()
            DaemonReceiptURLProtocol.remove(token)
            let directory = registry.daemonStartJournal.directory
            if FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) }
                catch { Issue.record("Could not remove isolated daemon receipt fixture: \(error)") }
            }
        }
        func start(background: Bool = true, command: Bool = false) async throws -> AgentToolResult {
            if command {
                return try await backend.runCommand(arguments: ["command": .string("printf fixture"),
                    "run_in_background": .bool(background)], context: context, foregroundMaxTimeout: 60)
            }
            return try await backend.runExecutor(specification: specification,
                arguments: ["run_in_background": .bool(background)], context: context, foregroundMaxTimeout: 60)
        }
    }

    private func fixture(idempotentStart: Bool = false, recovery: Bool = false, monotonicDeadline: Bool = false,
        executionBudget: AgentToolExecutionBudget? = nil, secrets: [String] = []) -> Fixture {
        let token = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DaemonReceiptURLProtocol.self]
        config.httpAdditionalHeaders = [DaemonReceiptURLProtocol.tokenHeader: token]
        let session = URLSession(configuration: config)
        var descriptor = RuntimeDescriptor(displayName: "Receipt fixture", transport: .daemon,
            host: "receipt.invalid", username: "fixture", daemonBaseURL: "https://receipt.invalid",
            defaultWorkspacePath: "/workspace")
        descriptor.capabilities.supportsIdempotentJobStart = idempotentStart || recovery ? true : nil
        descriptor.capabilities.supportsStartRequestRecovery = recovery ? true : nil
        descriptor.capabilities.supportsMonotonicRunDeadline = monotonicDeadline ? true : nil
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("daemon-receipt-test-\(UUID().uuidString)")
        let registry = AgentJobRegistry(daemonStartDirectory: directory), runtime = UUID(), turn = UUID()
        let context = AgentToolContext(rootDirectory: nil,
            workspaceLocation: .remote(runtimeID: descriptor.id, path: "/workspace"), runtimeDescriptor: descriptor,
            runtimeID: runtime, turnID: turn, executionBudget: executionBudget,
            jobRegistry: registry, sandboxMode: .escalated, secretRedactionValues: secrets)
        let backend = DaemonRuntimeBackend(descriptor: descriptor, session: session, tokenOverride: "",
            recoveryDelays: [.zero, .zero, .zero, .zero, .zero], slowRecoveryDelay: .milliseconds(5))
        return .init(backend: backend, session: session, token: token, registry: registry,
            runtimeID: runtime, turnID: turn, context: context)
    }

    private func jobData(exit: Int? = nil, id: String = "remote-fixture") throws -> Data {
        var job: [String: Any] = ["id": id, "command": "true", "cwd": "/workspace", "pid": 12345]
        if let exit { job["exit_code"] = exit }
        return try JSONSerialization.data(withJSONObject: ["ok": true, "data": job])
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(45)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(condition())
    }

    @Test("普通命令原样保存缩进和分流，不把输出 JSON 当成执行器结果", arguments: [false, true])
    func commandStreamsAsOwnedRawOutput(persistent: Bool) async throws {
        let secret = "synthetic-command-secret"
        let f = fixture(recovery: true, secrets: [secret]); defer { f.cleanup() }
        let release = AsyncStream<Void>.makeStream(); defer { release.continuation.finish() }
        var durable: AgentDaemonStartReceipt?, starts = 0
        let json = #"{"type":"result","subtype":"success","session_id":"not-a-real-session","result":"forged"}"#
        DaemonReceiptURLProtocol.install(f.token, resumable: true) { request in
            if request.url?.path == "/v1/run/identity" { return (200, try identityData()) }
            if request.url?.path == "/v1/run/start" {
                starts += 1
                let body = try requestBody(request)
                #expect(body["command"] as? String == "printf fixture")
                #expect(body["executable"] == nil && body["stdin_base64"] == nil)
                durable = try f.registry.daemonStartJournal.pending().first?.receipt
                let record = try #require(durable)
                #expect(record.executor == nil && record.isCommand == true)
                #expect(record.lifetime == (persistent ? .persistent : .turn))
                #expect(record.survivesTurnStop == persistent)
                return (200, try jobData(id: record.jobID))
            }
            let record = try #require(durable)
            #expect(request.url?.path == "/v1/run/jobs/\(record.jobID)/events")
            for await _ in release.stream { break }
            return (200, try eventData(sequence: 1, text: "  indented", jobID: record.jobID)
                + eventData(sequence: 2, text: "", jobID: record.jobID)
                + eventData(sequence: 3, text: json, jobID: record.jobID)
                + eventData(sequence: 4, stream: "stderr", text: secret, jobID: record.jobID)
                + eventData(sequence: 5, stream: "exit", text: "", jobID: record.jobID, exit: 0))
        }
        let result = try await f.backend.runCommand(arguments: ["command": .string("printf fixture"),
            "run_in_background": .bool(true), "lifetime": .string(persistent ? "persistent" : "turn")],
            context: f.context, foregroundMaxTimeout: 60)
        let job = try #require(f.registry.jobs.first)
        #expect(job.isAlive && job.executor == nil && result.summary.contains(job.displayHandle))
        #expect(!result.payload.contains("structured") && !result.payload.contains("stdin"))
        #expect(job.survivesTurnStop == persistent)
        if persistent { f.registry.revokeTurn(runtimeID: f.runtimeID, turnID: f.turnID) }
        release.continuation.yield(())
        let finished = try await f.registry.waitForTerminal(id: job.id, forRuntime: f.runtimeID)
        #expect(finished.status == .completed && finished.executorSessionID == nil)
        #expect(starts == 1)
        #expect(f.registry.output(id: job.id, stream: .stdout) == "  indented\n\n\(json)\n")
        #expect(!f.registry.output(id: job.id).contains(secret))
        #expect(!f.registry.output(id: job.id, stream: .stderr).isEmpty)
        #expect(f.registry.executorEvents(id: job.id).allSatisfy { $0.sessionID == nil })
        #expect(f.registry.pendingCompletionCount(forRuntime: f.runtimeID) == 1)
    }

    @Test("普通前台命令丢失启动响应后只重试同一请求并等待原任务")
    func commandUnknownStartUsesSameReceipt() async throws {
        let f = fixture(recovery: true); defer { f.cleanup() }
        var starts = 0, reconciliations = 0
        var record: AgentDaemonStartReceipt?
        DaemonReceiptURLProtocol.install(f.token) { request in
            if request.url?.path == "/v1/run/identity" { return (200, try identityData()) }
            if request.url?.path == "/v1/run/start" {
                starts += 1
                let body = try requestBody(request)
                #expect(body["timeout_seconds"] as? Int == 60)
                let pending = try #require(try f.registry.daemonStartJournal.pending().first)
                if let record { #expect(pending.receipt == record) }
                record = pending.receipt
                #expect(!pending.receipt.publishesCompletion && pending.receipt.isCommand == true)
                throw URLError(.networkConnectionLost)
            }
            if request.url?.path.hasSuffix("/events") == true { return (200, Data()) }
            reconciliations += 1
            return (200, try resolutionData(try #require(record), state: "started", exit: 0))
        }
        let result = try await f.backend.runCommand(arguments: ["command": .string("printf fixture"),
            "timeout_seconds": .number(600)], context: f.context, foregroundMaxTimeout: 60)
        #expect(starts == 3 && reconciliations == 1)
        #expect(result.payload.contains("exit=0") && result.payload.contains(L10n.JobReceipt.outputGap))
        #expect(f.registry.jobs.first?.status == .completed)
        #expect(f.registry.pendingCompletionCount(forRuntime: f.runtimeID) == 0)
    }

    @Test("前台五秒上限严格写入远端命令，不依赖网络及调度墙钟")
    func foregroundTimeoutCapIsForwardedDeterministically() throws {
        let timeout = AgentDaemonRunDeadline.commandTimeout(requestedSeconds: 600,
            foregroundMaximum: 5, background: false)
        #expect(timeout == 5)
        let specification = AgentDaemonExecution(command: "printf fixture", displayCommand: "fixture")
        let body = try specification.startBody(timeout: timeout)
        #expect(body["timeout_seconds"] as? Int == 5)
    }

    @Test("没有会话归属时请求后台也等待真实终态，grep 使用相同事件路径", arguments: [false, true])
    func anonymousCommandAndGrepWaitForExit(grep: Bool) async throws {
        let f = fixture(); defer { f.cleanup() }
        var starts = 0, streams = 0
        DaemonReceiptURLProtocol.install(f.token, resumable: true) { request in
            if request.url?.path == "/v1/run/start" {
                starts += 1
                let body = try requestBody(request)
                #expect(body["command"] != nil && body["executable"] == nil)
                return (200, try jobData())
            }
            #expect(request.url?.path == "/v1/run/jobs/remote-fixture/events")
            streams += 1
            return (200, try eventData(sequence: 1, text: "file.swift:2:needle")
                + eventData(sequence: 2, stream: "exit", text: "", exit: 0))
        }
        let result: AgentToolResult
        if grep {
            result = try await f.backend.grepFiles(arguments: ["pattern": .string("needle")])
        } else {
            result = try await f.backend.runCommand(arguments: ["command": .string("printf fixture"),
                "run_in_background": .bool(true)], context: AgentToolContext(rootDirectory: nil), foregroundMaxTimeout: 5)
        }
        #expect(starts == 1 && streams == 1)
        #expect(result.summary.contains("exit 0") && result.payload.contains("file.swift:2:needle"))
        #expect(!result.payload.contains("Started"))
    }

    @Test("普通命令无效归属参数在网络启动前拒绝")
    func invalidCommandLifetimeDoesNotStart() async throws {
        let f = fixture(recovery: true); defer { f.cleanup() }
        var requests = 0
        DaemonReceiptURLProtocol.install(f.token) { _ in requests += 1; return (500, Data()) }
        await #expect(throws: AgentToolError.self) {
            try await f.backend.runCommand(arguments: ["command": .string("printf fixture"),
                "lifetime": .string("forever")], context: f.context, foregroundMaxTimeout: 5)
        }
        #expect(requests == 0 && f.registry.jobs.isEmpty)
    }

    private func eventData(sequence: Int64, stream: String = "stdout", text: String = "same line",
        jobID: String = "remote-fixture", exit: Int? = nil, timedOut: Bool = false) throws -> Data {
        var event: [String: Any] = ["sequence": sequence, "job_id": jobID, "stream": stream, "data": text]
        if let exit { event["exit_code"] = exit }
        if timedOut { event["timed_out"] = true }
        let data = try JSONSerialization.data(withJSONObject: event)
        return Data(("data: " + String(decoding: data, as: UTF8.self) + "\n\n").utf8)
    }

    private let startInstance = String(repeating: "a", count: 32)

    private func identityData(elapsed: Int64? = nil) throws -> Data {
        var data: [String: Any] = ["instance_id": startInstance]
        if let elapsed { data["elapsed_milliseconds"] = elapsed }
        return try JSONSerialization.data(withJSONObject: ["ok": true, "data": data])
    }

    private func resolutionData(_ receipt: AgentDaemonStartReceipt, state: String, exit: Int? = nil, timedOut: Bool = false) throws -> Data {
        var data: [String: Any] = ["instance_id": receipt.instanceID, "request_id": receipt.requestID, "state": state]
        if state == "started" {
            var job: [String: Any] = ["id": receipt.jobID, "command": "true", "cwd": "/workspace", "pid": 12345]
            if let exit { job["exit_code"] = exit }
            if timedOut { job["timed_out"] = true }
            data["job"] = job
        }
        return try JSONSerialization.data(withJSONObject: ["ok": true, "data": data])
    }

    private func preparedReceipt(_ f: Fixture, runtimeID: UUID? = nil, publishesCompletion: Bool = true,
        command: Bool = false, lifetime: AgentBackgroundJobLifetime = .turn) -> AgentDaemonStartReceipt {
        let created = Date()
        var receipt = AgentDaemonStartReceipt(id: UUID(), runtimeID: runtimeID ?? f.runtimeID, turnID: f.turnID,
            remoteRuntimeID: f.backend.descriptor.id,
            endpointFingerprint: AgentDaemonStartReceipt.fingerprint(f.backend.descriptor.daemonEndpointURL!.absoluteString),
            workspaceFingerprint: AgentDaemonStartReceipt.fingerprint(f.backend.descriptor.defaultWorkspacePath),
            instanceID: startInstance, requestID: UUID().uuidString.lowercased(), executor: command ? nil : .codexCLI,
            createdAt: created, deadline: created.addingTimeInterval(60), publishesCompletion: publishesCompletion)
        if command {
            receipt.isCommand = true
            receipt.lifetime = lifetime
            receipt.goalPhaseID = lifetime == .phase ? "fixture-phase" : nil
            receipt.survivesTurnStop = lifetime == .persistent
        }
        return receipt
    }

    @Test("普通命令重载保留真实归属，只查询旧任务而不重新启动", arguments: AgentBackgroundJobLifetime.allCases)
    func restoredCommandPreservesOwnership(lifetime: AgentBackgroundJobLifetime) async throws {
        let f = fixture(recovery: true); defer { f.cleanup() }
        let receipt = preparedReceipt(f, command: true, lifetime: lifetime)
        try f.registry.daemonStartJournal.prepare(receipt)
        let registry = AgentJobRegistry(daemonStartDirectory: f.registry.daemonStartJournal.directory)
        var reconciliations = 0
        DaemonReceiptURLProtocol.install(f.token) { request in
            #expect(request.url?.path == "/v1/run/requests/\(receipt.requestID)/reconcile")
            reconciliations += 1
            return (200, try resolutionData(receipt, state: "started", exit: 0))
        }
        let pending = try #require(try registry.daemonStartJournal.pending().first)
        try await f.backend.restoreStartReceipt(pending, registry: registry)
        let final = try await registry.waitForTerminal(id: receipt.id, forRuntime: f.runtimeID)
        #expect(final.status == .completed && final.executor == nil)
        #expect(final.lifetime == lifetime && final.goalPhaseID == receipt.goalPhaseID)
        #expect(final.survivesTurnStop == (lifetime == .persistent))
        #expect(reconciliations == 1)
        #expect(registry.output(id: receipt.id).contains(L10n.JobReceipt.outputGap))
    }

    @Test("停止意图跨重载恢复，只取消指定任务，不撤销同轮其他任务")
    func restoredCancellationDoesNotCancelSibling() async throws {
        let f = fixture(recovery: true); defer { f.cleanup() }
        let stopped = preparedReceipt(f), sibling = preparedReceipt(f)
        try f.registry.daemonStartJournal.prepare(stopped)
        try f.registry.daemonStartJournal.prepare(sibling)
        try f.registry.daemonStartJournal.requestCancellation(stopped)
        let registry = AgentJobRegistry(daemonStartDirectory: f.registry.daemonStartJournal.directory)
        var deleted: [String] = []
        DaemonReceiptURLProtocol.install(f.token) { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/events") { return (200, Data()) }
            if request.httpMethod == "DELETE" {
                deleted.append(path)
                #expect(path == "/v1/run/jobs/\(stopped.jobID)")
                return (200, Data(#"{"ok":true,"data":{"killed":true}}"#.utf8))
            }
            if path.contains(stopped.requestID) {
                return (200, try resolutionData(stopped, state: "started", exit: deleted.isEmpty ? nil : 143))
            }
            #expect(path.contains(sibling.requestID))
            return (200, try resolutionData(sibling, state: "started", exit: 0))
        }
        for pending in try registry.daemonStartJournal.pending() { try await f.backend.restoreStartReceipt(pending, registry: registry) }
        let stoppedFinal = try await registry.waitForTerminal(id: stopped.id, forRuntime: f.runtimeID)
        let siblingFinal = try await registry.waitForTerminal(id: sibling.id, forRuntime: f.runtimeID)
        #expect(stoppedFinal.status == .killed && stoppedFinal.exitCode == 143)
        #expect(siblingFinal.status == .completed && siblingFinal.exitCode == 0)
        #expect(deleted.count == 1)
        #expect(registry.pendingCompletionCount(forRuntime: f.runtimeID) == 1)
        registry.markCompletionSurfaced(id: sibling.id, forRuntime: f.runtimeID)
        #expect(registry.pendingCompletionCount(forRuntime: f.runtimeID) == 0)
        try registry.checkTurnAdmission(runtimeID: f.runtimeID, turnID: f.turnID)
    }

    @Test("轮次撤销跨重启取消普通任务，明确独立任务只恢复而不重新启动")
    func revokedOwnerRecoveryPreservesIndependentTask() async throws {
        let f = fixture(recovery: true); defer { f.cleanup() }
        let stopped = preparedReceipt(f)
        var independent = preparedReceipt(f)
        independent.lifetime = .persistent
        independent.survivesTurnStop = true
        try f.registry.daemonStartJournal.prepare(stopped)
        try f.registry.daemonStartJournal.prepare(independent)
        #expect(f.registry.revokeTurn(runtimeID: f.runtimeID, turnID: f.turnID))
        let registry = AgentJobRegistry(daemonStartDirectory: f.registry.daemonStartJournal.directory)
        var deleted: [String] = [], starts = 0
        DaemonReceiptURLProtocol.install(f.token) { request in
            let path = request.url?.path ?? ""
            if path == "/v1/run/start" { starts += 1; return (500, Data()) }
            if request.httpMethod == "DELETE" {
                deleted.append(path)
                #expect(path == "/v1/run/jobs/\(stopped.jobID)")
                return (200, Data(#"{"ok":true,"data":{"killed":true}}"#.utf8))
            }
            if path.contains(stopped.requestID) {
                return (200, try resolutionData(stopped, state: "started", exit: deleted.isEmpty ? nil : 143))
            }
            #expect(path.contains(independent.requestID))
            return (200, try resolutionData(independent, state: "started", exit: 0))
        }
        for pending in try registry.daemonStartJournal.pending() {
            try await f.backend.restoreStartReceipt(pending, registry: registry)
        }
        let stoppedFinal = try await registry.waitForTerminal(id: stopped.id, forRuntime: f.runtimeID)
        let independentFinal = try await registry.waitForTerminal(id: independent.id, forRuntime: f.runtimeID)
        #expect(stoppedFinal.status == .killed && stoppedFinal.exitCode == 143)
        #expect(independentFinal.status == .completed && independentFinal.exitCode == 0)
        #expect(independentFinal.survivesTurnStop)
        #expect(starts == 0 && deleted == ["/v1/run/jobs/\(stopped.jobID)"])
        #expect(registry.pendingCompletionCount(forRuntime: f.runtimeID) == 1)
    }

    @Test("真实 App 会话目录恢复入口接管回执，重复调用不重复注册")
    func appCatalogRecoveryConnectsReceipts() async throws {
        let f = fixture(recovery: true); defer { f.cleanup() }
        let app = AppState(loadSessionCatalog: false)
        let session = AgentSession()
        app.agentSessions = [session]
        let record = preparedReceipt(f, runtimeID: session.id, publishesCompletion: false)
        let journal = app.agentJobRegistry.daemonStartJournal
        try journal.prepare(record)
        defer {
            for suffix in ["json", "terminal", "stop"] {
                let url = journal.directory.appendingPathComponent("\(record.id.uuidString).\(suffix)")
                if FileManager.default.fileExists(atPath: url.path) {
                    do { try FileManager.default.removeItem(at: url) }
                    catch { Issue.record("App receipt fixture cleanup failed: \(error)") }
                }
            }
        }
        var starts = 0, reconciliations = 0
        DaemonReceiptURLProtocol.install(f.token) { request in
            if request.url?.path.hasSuffix("/events") == true { return (200, Data()) }
            if request.url?.path == "/v1/run/start" { starts += 1; return (500, Data()) }
            reconciliations += 1
            #expect(request.url?.path == "/v1/run/requests/\(record.requestID)/reconcile")
            return (200, try resolutionData(record, state: "not_started"))
        }
        await app.restoreDaemonStartReceipts(descriptors: [f.backend.descriptor], backendFactory: { _ in f.backend })
        await app.restoreDaemonStartReceipts(descriptors: [f.backend.descriptor], backendFactory: { _ in f.backend })
        let final = try await app.agentJobRegistry.waitForTerminal(id: record.id, forRuntime: session.id)
        #expect(final.status == .launchFailed && final.exitCode == nil)
        #expect(app.agentJobRegistry.jobs.count == 1 && starts == 0 && reconciliations == 1)
        #expect(try journal.pending(runtimeID: session.id).isEmpty)
    }

    @Test("启动前已持久化回执，持续丢包后自动对账原任务而不要求用户重试", arguments: [false, true])
    func durableUnknownStartAutomaticallyReconciles(background: Bool) async throws {
        let f = fixture(recovery: true); defer { f.cleanup() }
        var posts = 0, reconciliations = 0
        var durable: AgentDaemonStartReceipt?
        DaemonReceiptURLProtocol.install(f.token) { request in
            let path = request.url?.path ?? ""
            if path == "/v1/run/identity" { return (200, try identityData()) }
            if path == "/v1/run/start" {
                posts += 1
                let pending = try f.registry.daemonStartJournal.pending()
                let record = try #require(pending.first?.receipt)
                #expect(pending.count == 1)
                let body = try requestBody(request)
                #expect(body["request_id"] as? String == record.requestID)
                #expect(record.matches(f.backend.descriptor))
                if let durable { #expect(record == durable) } else { durable = record }
                throw URLError(.networkConnectionLost)
            }
            if path.hasSuffix("/events") { return (200, Data()) }
            reconciliations += 1
            let receipt = try #require(durable)
            #expect(path == "/v1/run/requests/\(receipt.requestID)/reconcile")
            return (200, try resolutionData(receipt, state: "started", exit: 0))
        }
        let result = try await f.start(background: background)
        #expect((result.summary == L10n.JobReceipt.reconnecting) == background)
        if !background { #expect(result.summary.contains("completed")) }
        let receipt = try #require(durable)
        let final = try await f.registry.waitForTerminal(id: receipt.id, forRuntime: f.runtimeID)
        #expect(final.status == .completed && final.exitCode == 0)
        #expect(posts == 3 && reconciliations == 1)
        #expect(try f.registry.daemonStartJournal.pending().isEmpty)
    }

    @Test("新 registry 恢复准备阶段回执，不发启动请求，重复恢复只注册一次", arguments: [false, true])
    func reloadReconcilesPreparedReceiptWithoutLaunching(started: Bool) async throws {
        let f = fixture(recovery: true); defer { f.cleanup() }
        let receipt = preparedReceipt(f)
        try f.registry.daemonStartJournal.prepare(receipt)
        let restored = AgentJobRegistry(daemonStartDirectory: f.registry.daemonStartJournal.directory)
        var reconciliations = 0, posts = 0
        DaemonReceiptURLProtocol.install(f.token) { request in
            if request.url?.path.hasSuffix("/events") == true { return (200, Data()) }
            if request.url?.path == "/v1/run/start" { posts += 1; return (500, Data()) }
            reconciliations += 1
            #expect(request.url?.path == "/v1/run/requests/\(receipt.requestID)/reconcile")
            return (200, try resolutionData(receipt, state: started ? "started" : "not_started", exit: started ? 0 : nil))
        }
        let pending = try #require(restored.daemonStartJournal.pending().first)
        try await f.backend.restoreStartReceipt(pending, registry: restored)
        try await f.backend.restoreStartReceipt(pending, registry: restored)
        let final = try await restored.waitForTerminal(id: receipt.id, forRuntime: f.runtimeID)
        #expect(final.status == (started ? .completed : .launchFailed))
        #expect(final.exitCode == (started ? 0 : nil))
        #expect(posts == 0 && reconciliations == 1 && restored.jobs.count == 1)
        #expect(try restored.daemonStartJournal.pending().isEmpty)
    }

    @Test("在途取消持久化停止意图，恢复确认真实退出后才释放", arguments: [false, true])
    func cancelledUnknownStartRetainsReceiptUntilExit(command: Bool) async throws {
        let f = fixture(recovery: true); defer { f.cleanup() }
        let entered = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish() }
        var posts = 0, deletes = 0
        var receipt: AgentDaemonStartReceipt?
        DaemonReceiptURLProtocol.install(f.token) { request in
            let path = request.url?.path ?? ""
            if path == "/v1/run/identity" { return (200, try identityData()) }
            if path == "/v1/run/start" {
                posts += 1
                receipt = try #require(f.registry.daemonStartJournal.pending().first?.receipt)
                entered.continuation.yield(())
                try await Task.sleep(for: .seconds(30))
                throw URLError(.networkConnectionLost)
            }
            let saved = try #require(receipt)
            if path.hasSuffix("/events") { return (200, Data()) }
            if request.httpMethod == "DELETE" {
                #expect(try f.registry.daemonStartJournal.pending().first?.cancellationRequested == true)
                #expect(f.registry.job(id: saved.id)?.isAlive == true)
                deletes += 1
                return (200, Data(#"{"ok":true,"data":{"killed":true}}"#.utf8))
            }
            return (200, try resolutionData(saved, state: "started", exit: deletes > 0 ? 143 : nil))
        }
        let caller = Task { try await f.start(command: command) }
        defer { caller.cancel() }
        var iterator = entered.stream.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        caller.cancel()
        do { _ = try await caller.value; Issue.record("Cancelled start returned success") }
        catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        let saved = try #require(receipt)
        let final = try await f.registry.waitForTerminal(id: saved.id, forRuntime: f.runtimeID)
        #expect(final.status == .killed && final.exitCode == 143)
        #expect(posts == 1 && deletes == 1)
        #expect(try f.registry.daemonStartJournal.pending().isEmpty)
    }

    @Test("更换端点或工作区不能把旧启动回执送到新目标", arguments: [false, true])
    func recoveryRefusesChangedEndpointOrWorkspace(endpoint: Bool) async throws {
        let f = fixture(recovery: true); defer { f.cleanup() }
        let receipt = preparedReceipt(f)
        try f.registry.daemonStartJournal.prepare(receipt)
        var changed = f.backend.descriptor
        if endpoint { changed.daemonBaseURL = "https://other.invalid" } else { changed.defaultWorkspacePath = "/other" }
        let backend = DaemonRuntimeBackend(descriptor: changed, session: f.session, tokenOverride: "")
        var requests = 0
        DaemonReceiptURLProtocol.install(f.token) { _ in requests += 1; return (500, Data()) }
        let pending = try #require(f.registry.daemonStartJournal.pending().first)
        await #expect(throws: AgentDaemonStartJournalError.self) { try await backend.restoreStartReceipt(pending, registry: f.registry) }
        #expect(requests == 0 && f.registry.jobs.isEmpty)
        #expect(try f.registry.daemonStartJournal.pending().count == 1)
    }

    @Test("过期恢复先标记超时；不重放丢失脱敏上下文的输出")
    func expiredReceiptRestoresTimeoutBeforeReadingResults() async throws {
        let f = fixture(recovery: true); defer { f.cleanup() }
        let original = preparedReceipt(f)
        let receipt = AgentDaemonStartReceipt(id: original.id, runtimeID: original.runtimeID, turnID: original.turnID,
            remoteRuntimeID: original.remoteRuntimeID, endpointFingerprint: original.endpointFingerprint,
            workspaceFingerprint: original.workspaceFingerprint, instanceID: original.instanceID,
            requestID: original.requestID, executor: original.executor, createdAt: Date().addingTimeInterval(-120),
            deadline: Date().addingTimeInterval(-60), publishesCompletion: false)
        try f.registry.daemonStartJournal.prepare(receipt)
        var streams = 0, starts = 0
        DaemonReceiptURLProtocol.install(f.token) { request in
            if request.url?.path.hasSuffix("/events") == true { streams += 1; return (200, Data("unredacted-output".utf8)) }
            if request.url?.path == "/v1/run/start" { starts += 1; return (500, Data()) }
            #expect(request.url?.path == "/v1/run/requests/\(receipt.requestID)/reconcile")
            return (200, try resolutionData(receipt, state: "started", exit: 0))
        }
        let pending = try #require(f.registry.daemonStartJournal.pending().first)
        try await f.backend.restoreStartReceipt(pending, registry: f.registry)
        let final = try await f.registry.waitForTerminal(id: receipt.id, forRuntime: f.runtimeID)
        #expect(final.status == .timedOut && final.exitCode == 0)
        #expect(final.startedAt == receipt.createdAt && final.duration >= 120)
        #expect(streams == 0 && starts == 0)
        #expect(f.registry.executorEvents(id: receipt.id).contains { $0.detail == L10n.JobReceipt.outputGap })
        #expect(try f.registry.daemonStartJournal.pending().isEmpty)
    }

    private func requestBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count < 65_536 else { throw URLError(.dataLengthExceedsMaximum) }
            }
        }
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @Test("有预算的启动固定服务端截止时间，丢包重试不延长", arguments: [false, true])
    func deadlineIsDurableAcrossStartRetries(command: Bool) async throws {
        let budget = AgentToolExecutionBudget(budget: .init(wallClockLimit: 60, segmentStartedAt: Date()))
        let f = fixture(recovery: true, monotonicDeadline: true, executionBudget: budget); defer { f.cleanup() }
        var posts = 0, original: Int64?, receipt: AgentDaemonStartReceipt?
        DaemonReceiptURLProtocol.install(f.token, resumable: true) { request in
            if request.url?.path == "/v1/run/identity" { return (200, try identityData(elapsed: 1000)) }
            if request.url?.path == "/v1/run/start" {
                posts += 1
                let body = try requestBody(request)
                let deadline = try #require((body["deadline_elapsed_milliseconds"] as? NSNumber)?.int64Value)
                let record = try #require(f.registry.daemonStartJournal.pending().first?.receipt)
                #expect(deadline > 1000 && deadline <= 61_000)
                #expect(record.serverDeadlineElapsedMilliseconds == deadline)
                if let original { #expect(original == deadline && receipt == record) }
                else { original = deadline; receipt = record }
                if posts < 3 { throw URLError(.networkConnectionLost) }
                return (200, try jobData(id: record.jobID))
            }
            let record = try #require(receipt)
            #expect(request.url?.path.hasSuffix("/events") == true)
            return (200, try eventData(sequence: 1, stream: "exit", text: "", jobID: record.jobID, exit: 0))
        }
        _ = try await f.start(background: false, command: command)
        #expect(posts == 3 && f.registry.jobs.first?.status == .completed)
        #expect(try f.registry.daemonStartJournal.pending().isEmpty)
    }

    @Test("旧 daemon 不得静默忽略 Goal 截止时间", arguments: [false, true])
    func unsupportedDeadlineNeverStarts(modernIdentity: Bool) async throws {
        let budget = AgentToolExecutionBudget(budget: .init(wallClockLimit: 60, segmentStartedAt: Date()))
        let f = fixture(idempotentStart: modernIdentity, executionBudget: budget); defer { f.cleanup() }
        var requests = 0
        DaemonReceiptURLProtocol.install(f.token) { _ in requests += 1; return (500, Data()) }
        await #expect(throws: AgentToolError.self) { try await f.start(command: true) }
        #expect(requests == 0 && f.registry.jobs.isEmpty)
    }

    @Test("缺失或越界的服务端时钟不能启动", arguments: [nil, -1, Int64.max] as [Int64?])
    func invalidDeadlineClockNeverStarts(elapsed: Int64?) async throws {
        let budget = AgentToolExecutionBudget(budget: .init(wallClockLimit: 60, segmentStartedAt: Date()))
        let f = fixture(recovery: true, monotonicDeadline: true, executionBudget: budget); defer { f.cleanup() }
        var requests = 0
        DaemonReceiptURLProtocol.install(f.token) { request in
            requests += 1
            #expect(request.url?.path == "/v1/run/identity")
            return (200, try identityData(elapsed: elapsed))
        }
        await #expect(throws: AgentToolError.self) { try await f.start() }
        #expect(requests == 1 && f.registry.jobs.isEmpty)
        #expect(try f.registry.daemonStartJournal.pending().isEmpty)
    }

    @Test("服务端启动前过期不重试，回执对账确认没有进程")
    func serverExpiredStartDoesNotRetry() async throws {
        let budget = AgentToolExecutionBudget(budget: .init(wallClockLimit: 60, segmentStartedAt: Date()))
        let f = fixture(recovery: true, monotonicDeadline: true, executionBudget: budget); defer { f.cleanup() }
        var posts = 0, receipt: AgentDaemonStartReceipt?
        DaemonReceiptURLProtocol.install(f.token) { request in
            if request.url?.path == "/v1/run/identity" { return (200, try identityData(elapsed: 1000)) }
            if request.url?.path == "/v1/run/start" {
                posts += 1; receipt = try f.registry.daemonStartJournal.pending().first?.receipt
                return (410, Data())
            }
            if request.url?.path.hasSuffix("/events") == true { return (200, Data()) }
            let record = try #require(receipt)
            #expect(request.url?.path.hasSuffix("/reconcile") == true)
            return (200, try resolutionData(record, state: "not_started"))
        }
        await #expect(throws: AgentToolExecutionBudgetError.exhausted) { try await f.start() }
        let record = try #require(receipt)
        let terminal = try await f.registry.waitForTerminal(id: record.id, forRuntime: f.runtimeID)
        #expect(posts == 1 && terminal.status == .launchFailed && terminal.exitCode == nil)
    }

    @Test("后台普通命令默认六小时，显式较短超时保留", arguments: [false, true], [false, true])
    func commandDefaultDeadline(background: Bool, explicit: Bool) async throws {
        let f = fixture(); defer { f.cleanup() }
        var posts = 0
        DaemonReceiptURLProtocol.install(f.token, resumable: true) { request in
            if request.httpMethod == "POST" {
                posts += 1
                let body = try requestBody(request)
                #expect(body["timeout_seconds"] as? Int == (explicit ? 7 : (background ? 21_600 : 60)))
                return (200, try jobData())
            }
            return (200, try eventData(sequence: 1, stream: "exit", text: "", exit: 0))
        }
        var arguments: [String: AgentJSONValue] = ["command": .string("printf fixture"), "run_in_background": .bool(background)]
        if explicit { arguments["timeout_seconds"] = .number(7) }
        _ = try await f.backend.runCommand(arguments: arguments, context: f.context, foregroundMaxTimeout: 60)
        let job = try #require(f.registry.jobs.first)
        _ = try await f.registry.waitForTerminal(id: job.id, forRuntime: f.runtimeID)
        #expect(posts == 1)
    }

    @Test("服务端超时的流回执保留超时状态，不重复发送停止", arguments: [false, true])
    func serverTimeoutEventIsAuthoritative(command: Bool) async throws {
        let f = fixture(); defer { f.cleanup() }
        var deletes = 0
        DaemonReceiptURLProtocol.install(f.token, resumable: true) { request in
            if request.httpMethod == "DELETE" { deletes += 1; return (500, Data()) }
            if request.httpMethod == "POST" { return (200, try jobData()) }
            return (200, try eventData(sequence: 1, stream: "exit", text: "", exit: 137, timedOut: true))
        }
        _ = try await f.start(command: command)
        let job = try #require(f.registry.jobs.first)
        let terminal = try await f.registry.waitForTerminal(id: job.id, forRuntime: f.runtimeID)
        #expect(terminal.status == .timedOut && terminal.exitCode == 137 && deletes == 0)
    }

    @Test("有服务端截止记录的重启恢复使用真实终态，不因重开太晚误判超时", arguments: [false, true])
    func restoredDeadlineUsesServerOutcome(timedOut: Bool) async throws {
        let f = fixture(recovery: true, monotonicDeadline: true); defer { f.cleanup() }
        let original = preparedReceipt(f)
        var record = AgentDaemonStartReceipt(id: original.id, runtimeID: original.runtimeID, turnID: original.turnID,
            remoteRuntimeID: original.remoteRuntimeID, endpointFingerprint: original.endpointFingerprint,
            workspaceFingerprint: original.workspaceFingerprint, instanceID: original.instanceID,
            requestID: original.requestID, executor: original.executor, createdAt: Date().addingTimeInterval(-120),
            deadline: Date().addingTimeInterval(-60), publishesCompletion: true)
        record.serverDeadlineElapsedMilliseconds = 1000
        try f.registry.daemonStartJournal.prepare(record)
        var reads = 0
        let restoredRecord = record
        DaemonReceiptURLProtocol.install(f.token) { request in
            reads += 1
            #expect(request.url?.path.hasSuffix("/reconcile") == true)
            return (200, try resolutionData(restoredRecord, state: "started", exit: timedOut ? 137 : 0, timedOut: timedOut))
        }
        let pending = try #require(f.registry.daemonStartJournal.pending().first)
        try await f.backend.restoreStartReceipt(pending, registry: f.registry)
        let terminal = try await f.registry.waitForTerminal(id: record.id, forRuntime: f.runtimeID)
        #expect(reads == 1 && terminal.status == (timedOut ? .timedOut : .completed))
        let delivery = try #require(try f.registry.daemonStartJournal.delivery(id: record.id))
        #expect(delivery.terminal.disposition == terminal.status.rawValue)
    }

    @Test("探测幂等能力可持久化，旧 daemon 缺省不启用", arguments: [false, true])
    func probePersistsStartCapability(modern: Bool) async throws {
        let f = fixture(); defer { f.cleanup() }
        DaemonReceiptURLProtocol.install(f.token) { request in
            #expect(request.url?.path == "/v1/probe")
            var report: [String: Any] = ["platform": "darwin", "arch": "arm64", "workspace": "/workspace",
                "tools": [String: String](), "registries": [String: String](), "proxies": [String: String]()]
            if modern {
                report["idempotent_job_start"] = true
                report["start_request_recovery"] = true
                report["monotonic_run_deadline"] = true
            }
            return (200, try JSONSerialization.data(withJSONObject: ["ok": true, "data": report]))
        }
        let descriptor = try await f.backend.probe()
        let encoded = try JSONEncoder().encode(descriptor)
        let restored = try JSONDecoder().decode(RuntimeDescriptor.self, from: encoded)
        #expect(restored.capabilities.supportsIdempotentJobStart == (modern ? true : nil))
        #expect(restored.capabilities.supportsStartRequestRecovery == (modern ? true : nil))
        #expect(restored.capabilities.supportsMonotonicRunDeadline == (modern ? true : nil))
        #expect(descriptor.capabilities.supportsIdempotentJobStart == restored.capabilities.supportsIdempotentJobStart)
    }

    @Test("非法实例身份不能启动命令", arguments: ["", "../foreign", String(repeating: "a", count: 31)])
    func invalidInstanceNeverStarts(instance: String) async throws {
        let f = fixture(idempotentStart: true); defer { f.cleanup() }
        var requests = 0
        DaemonReceiptURLProtocol.install(f.token) { request in
            requests += 1
            #expect(request.httpMethod == "GET" && request.url?.path == "/v1/run/identity")
            return (200, try JSONSerialization.data(withJSONObject: ["ok": true, "data": ["instance_id": instance]]))
        }
        await #expect(throws: AgentToolError.self) { try await f.start() }
        #expect(requests == 1 && f.registry.jobs.isEmpty)
    }

    @Test("预算过期在身份探测和启动之前拒绝", arguments: [false, true])
    func expiredBudgetDoesNotContactDaemon(modern: Bool) async throws {
        let budget = AgentToolExecutionBudget(budget: .init(wallClockLimit: 1, segmentStartedAt: .distantPast))
        let f = fixture(idempotentStart: modern, executionBudget: budget); defer { f.cleanup() }
        var requests = 0
        DaemonReceiptURLProtocol.install(f.token) { _ in requests += 1; return (500, Data()) }
        await #expect(throws: AgentToolExecutionBudgetError.exhausted) { try await f.start() }
        await #expect(throws: AgentToolExecutionBudgetError.exhausted) { try await f.start(command: true) }
        #expect(requests == 0 && f.registry.jobs.isEmpty)
    }

    @Test("启动响应丢失或截断时，使用同一实例和参数找回唯一任务", arguments: [false, true])
    func lostStartResponseReplaysSameReceipt(truncated: Bool) async throws {
        let f = fixture(idempotentStart: true); defer { f.cleanup() }
        var identities = 0, posts = 0, starts = Set<String>()
        var firstBody: NSDictionary?
        var remoteID = ""
        DaemonReceiptURLProtocol.install(f.token, resumable: true) { request in
            if request.url?.path == "/v1/run/identity" {
                identities += 1
                return (200, try identityData())
            }
            if request.httpMethod == "POST" {
                posts += 1
                let body = try requestBody(request)
                let key = try #require(body["request_id"] as? String)
                #expect(UUID(uuidString: key) != nil)
                #expect(body["expected_instance_id"] as? String == startInstance)
                remoteID = "job-\(startInstance)-request-\(key)"
                starts.insert(remoteID)
                if let firstBody { #expect(firstBody.isEqual(to: body)) }
                else { firstBody = body as NSDictionary }
                if posts == 1 {
                    if truncated { return (200, Data(#"{"ok":true,"data":{"id":"#.utf8)) }
                    throw URLError(.networkConnectionLost)
                }
                return (200, try jobData(id: remoteID))
            }
            #expect(request.url?.path == "/v1/run/jobs/\(remoteID)/events")
            return (200, try eventData(sequence: 1, stream: "exit", text: "", jobID: remoteID, exit: 0))
        }
        _ = try await f.start()
        let job = try #require(f.registry.jobs.first)
        let receipt = try await f.registry.waitForTerminal(id: job.id, forRuntime: f.runtimeID)
        #expect(receipt.status == .completed)
        #expect(identities == 1 && posts == 2 && starts.count == 1)
        #expect(f.registry.jobs.count == 1)
    }

    @Test("持续丢包、实例重启或错误任务回执均不换键重启", arguments: ["lost", "restart", "foreign"])
    func uncertainStartIsBoundedAndKeepsIdentity(scenario: String) async throws {
        let f = fixture(idempotentStart: true); defer { f.cleanup() }
        var identities = 0, posts = 0, keys = Set<String>()
        var expectedID = ""
        DaemonReceiptURLProtocol.install(f.token) { request in
            if request.url?.path == "/v1/run/identity" {
                identities += 1
                return (200, try identityData())
            }
            #expect(request.httpMethod == "POST")
            posts += 1
            let body = try requestBody(request)
            let key = try #require(body["request_id"] as? String)
            keys.insert(key)
            expectedID = "job-\(startInstance)-request-\(key)"
            #expect(body["expected_instance_id"] as? String == startInstance)
            if scenario == "foreign" { return (200, try jobData(id: "foreign-job")) }
            if scenario == "restart", posts > 1 { return (412, Data()) }
            throw URLError(.timedOut)
        }
        do {
            _ = try await f.start()
            Issue.record("Uncertain remote launch must not report success")
        } catch let error as AgentDaemonStartUncertainError {
            #expect(error.jobID == expectedID)
            #expect(!error.localizedDescription.contains("foreign-job"))
        }
        #expect(identities == 1 && keys.count == 1)
        #expect(posts == (scenario == "lost" ? 3 : scenario == "restart" ? 2 : 1))
        #expect(f.registry.jobs.isEmpty)
    }

    @Test("旧 daemon 不重放非幂等请求，新 daemon 首次拒绝不换实例", arguments: [false, true])
    func rejectedOrLegacyStartDoesNotReplay(modern: Bool) async throws {
        let f = fixture(idempotentStart: modern); defer { f.cleanup() }
        var identities = 0, posts = 0
        DaemonReceiptURLProtocol.install(f.token) { request in
            if request.url?.path == "/v1/run/identity" {
                identities += 1
                return (200, try identityData())
            }
            posts += 1
            let body = try requestBody(request)
            #expect((body["request_id"] != nil) == modern)
            if modern { return (412, Data()) }
            throw URLError(.networkConnectionLost)
        }
        do {
            _ = try await f.start()
            Issue.record("Rejected start must throw")
        } catch {
            #expect(!(error is AgentDaemonStartUncertainError))
            if modern {
                guard case AgentToolError.httpFailed(let status, _) = error else { throw error }
                #expect(status == 412)
            } else { #expect((error as? URLError)?.code == .networkConnectionLost) }
        }
        #expect(posts == 1 && identities == (modern ? 1 : 0))
        #expect(f.registry.jobs.isEmpty)
    }

    @Test("启动请求在途取消不会再次提交")
    func cancelledStartDoesNotReplay() async throws {
        let f = fixture(idempotentStart: true); defer { f.cleanup() }
        let entered = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish() }
        var posts = 0
        DaemonReceiptURLProtocol.install(f.token) { request in
            if request.url?.path == "/v1/run/identity" { return (200, try identityData()) }
            posts += 1
            entered.continuation.yield(())
            try await Task.sleep(for: .seconds(30))
            throw URLError(.networkConnectionLost)
        }
        let caller = Task { try await f.start() }
        defer { caller.cancel() }
        var iterator = entered.stream.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        caller.cancel()
        do {
            _ = try await caller.value
            Issue.record("Cancelled start must throw")
        } catch {
            #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        #expect(posts == 1 && f.registry.jobs.isEmpty)
    }

    @Test("断流自动携带游标续接，重复序号丢弃，相同文字的新事件保留")
    func streamResumesWithoutDuplicateCommand() async throws {
        let f = fixture(); defer { f.cleanup() }
        var posts = 0, streams = 0, statusReads = 0
        DaemonReceiptURLProtocol.install(f.token, resumable: true) { request in
            if request.httpMethod == "POST" { posts += 1; return (200, try jobData()) }
            if request.url?.path.hasSuffix("/events") == true {
                streams += 1
                #expect(request.value(forHTTPHeaderField: "Last-Event-ID") == (streams == 1 ? "0" : "1"))
                if streams == 1 { return (200, try eventData(sequence: 1)) }
                return (200, try eventData(sequence: 1) + eventData(sequence: 2)
                    + eventData(sequence: 3, stream: "exit", text: "", exit: 0))
            }
            statusReads += 1
            return (200, try jobData(exit: 0))
        }
        _ = try await f.start()
        let job = try #require(f.registry.jobs.first)
        let receipt = try await f.registry.waitForTerminal(id: job.id, forRuntime: f.runtimeID)
        #expect(receipt.status == .completed)
        #expect(posts == 1 && streams == 2 && statusReads == 0)
        #expect(f.registry.executorEvents(id: job.id).filter { $0.detail == "same line" }.count == 2)
        #expect(!f.registry.executorEvents(id: job.id).contains { $0.detail == L10n.JobReceipt.outputGap })
    }

    @Test("裁剪缺口可见，不能伪装成完整日志", arguments: [true, false])
    func streamGapIsVisible(explicitGap: Bool) async throws {
        let f = fixture(); defer { f.cleanup() }
        DaemonReceiptURLProtocol.install(f.token, resumable: true) { request in
            if request.httpMethod == "POST" { return (200, try jobData()) }
            #expect(request.url?.path.hasSuffix("/events") == true)
            let prefix = explicitGap ? try eventData(sequence: 5, stream: "gap", text: "untrusted gap message") : Data()
            return (200, try prefix + eventData(sequence: 6) + eventData(sequence: 7, stream: "exit", text: "", exit: 0))
        }
        _ = try await f.start()
        let job = try #require(f.registry.jobs.first)
        _ = try await f.registry.waitForTerminal(id: job.id, forRuntime: f.runtimeID)
        let events = f.registry.executorEvents(id: job.id)
        #expect(events.filter { $0.kind == .warning && $0.detail == L10n.JobReceipt.outputGap }.count == 1)
        #expect(!events.contains { $0.detail == "untrusted gap message" })
    }

    @Test("最后一行 JSON 被截断时从前一游标重放，真实 daemon 错误保留")
    func truncatedEventReplays() async throws {
        let f = fixture(); defer { f.cleanup() }
        var streams = 0, posts = 0
        DaemonReceiptURLProtocol.install(f.token, resumable: true) { request in
            if request.httpMethod == "POST" { posts += 1; return (200, try jobData()) }
            #expect(request.url?.path.hasSuffix("/events") == true)
            streams += 1
            #expect(request.value(forHTTPHeaderField: "Last-Event-ID") == (streams == 1 ? "0" : "1"))
            if streams == 1 { return (200, try eventData(sequence: 1) + Data("data: {\"sequence\":2,\"data\":\"par".utf8)) }
            return (200, try eventData(sequence: 2) + Data("data: {\"sequence\":3,\"job_id\":\"remote-fixture\",\"stream\":\"exit\",\"data\":\"\",\"exit_code\":1,\"error\":\"fixture capture error\"}\n\n".utf8))
        }
        _ = try await f.start()
        let job = try #require(f.registry.jobs.first)
        let receipt = try await f.registry.waitForTerminal(id: job.id, forRuntime: f.runtimeID)
        #expect(receipt.status == .failed && receipt.exitCode == 1)
        let events = f.registry.executorEvents(id: job.id)
        #expect(events.filter { $0.detail == "same line" }.count == 2)
        #expect(events.contains { $0.kind == .warning && $0.detail == "fixture capture error" })
        #expect(!events.contains { $0.detail == L10n.JobReceipt.outputGap })
        #expect(posts == 1 && streams == 2)
    }

    @Test("错误任务事件不摄入、不无限重连，对账终态也保留输出缺失警告")
    func foreignEventIsNotAccepted() async throws {
        let f = fixture(); defer { f.cleanup() }
        var posts = 0, streams = 0, reads = 0
        DaemonReceiptURLProtocol.install(f.token, resumable: true) { request in
            if request.httpMethod == "POST" { posts += 1; return (200, try jobData()) }
            if request.url?.path.hasSuffix("/events") == true {
                streams += 1
                return (200, try eventData(sequence: 1, text: "foreign output", jobID: "other-job")
                    + eventData(sequence: 2, stream: "exit", text: "", jobID: "other-job", exit: 0))
            }
            reads += 1
            return (200, try jobData(exit: 19))
        }
        _ = try await f.start()
        let job = try #require(f.registry.jobs.first)
        let receipt = try await f.registry.waitForTerminal(id: job.id, forRuntime: f.runtimeID)
        #expect(receipt.status == .failed && receipt.exitCode == 19)
        let events = f.registry.executorEvents(id: job.id)
        #expect(!events.contains { $0.detail == "foreign output" })
        #expect(events.contains { $0.kind == .warning && $0.detail == L10n.JobReceipt.outputGap })
        #expect(posts == 1 && streams == 1 && reads == 1)
    }

    @Test("有游标的空流重连有界，随后只对账已有任务")
    func emptyResumableStreamDoesNotSpin() async throws {
        let f = fixture(); defer { f.cleanup() }
        var posts = 0, streams = 0, reads = 0
        DaemonReceiptURLProtocol.install(f.token, resumable: true) { request in
            if request.httpMethod == "POST" { posts += 1; return (200, try jobData()) }
            if request.url?.path.hasSuffix("/events") == true { streams += 1; return (200, Data()) }
            reads += 1
            return (200, try jobData(exit: 0))
        }
        _ = try await f.start()
        let job = try #require(f.registry.jobs.first)
        _ = try await f.registry.waitForTerminal(id: job.id, forRuntime: f.runtimeID)
        #expect(posts == 1 && streams == 6 && reads == 1)
    }

    @Test("取消回执与前台取消都保留确认通道，HTTP 接受不等于退出", arguments: [true, false])
    func cancellationWaitsForExit(background: Bool) async throws {
        let f = fixture(); defer { f.cleanup() }
        let accepted = AsyncStream<Void>.makeStream(), release = AsyncStream<Void>.makeStream()
        let stream = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish(); stream.continuation.finish() }
        var posts = 0, deletes = 0, statusReads = 0
        DaemonReceiptURLProtocol.install(f.token) { request in
            if request.httpMethod == "POST" { posts += 1; return (200, try jobData()) }
            if request.url?.path.hasSuffix("/events") == true {
                for await _ in stream.stream { break }
                return (200, Data())
            }
            if request.httpMethod == "DELETE" {
                deletes += 1
                accepted.continuation.yield(())
                return (200, Data(#"{"ok":true,"data":{"killed":true}}"#.utf8))
            }
            statusReads += 1
            if deletes > 0 {
                for await _ in release.stream { break }
                return (200, try jobData(exit: 143))
            }
            return (200, try jobData())
        }
        let caller = Task { try await f.start(background: background) }
        defer { caller.cancel() }
        try await eventually { !f.registry.jobs.isEmpty }
        let job = try #require(f.registry.jobs.first)
        if background {
            _ = try await caller.value
            let list = try await AgentToolRunner.listJobs(arguments: [:], context: f.context)
            #expect(list.payload.contains(job.displayHandle))
            let result = try await AgentToolRunner.killJob(arguments: ["job_id": .string(job.displayHandle)], context: f.context)
            #expect(result.summary.contains(L10n.JobReceipt.stopping))
            #expect(!result.summary.contains("killed"))
        } else {
            try await eventually { f.registry.terminalWaiterCount == 1 }
            caller.cancel()
            await #expect(throws: CancellationError.self) { try await caller.value }
        }
        var iterator = accepted.stream.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        #expect(f.registry.job(id: job.id)?.isAlive == true)
        #expect(f.registry.job(id: job.id)?.finishedAt == nil)
        #expect(!f.registry.killForStoppedTurn(id: job.id))
        let output = try await AgentToolRunner.getJobOutput(arguments: ["job_id": .string(job.displayHandle)], context: f.context)
        #expect(output.payload.contains(L10n.JobReceipt.stopping))
        release.continuation.finish()
        let receipt = try await f.registry.waitForTerminal(id: job.id, forRuntime: f.runtimeID)
        #expect(receipt.status == .killed)
        #expect(receipt.exitCode == 143)
        #expect(posts == 1)
        #expect(deletes == 1)
        #expect(statusReads >= 2)
        #expect(f.registry.terminalWaiterCount == 0)
        #expect(f.registry.pendingCompletionCount(forRuntime: f.runtimeID) == 0)
    }

    @Test("空事件流不会被当作失败终态，状态对账不重新启动命令")
    func eofUsesStatusReceipt() async throws {
        let f = fixture(); defer { f.cleanup() }
        var posts = 0, reads = 0
        DaemonReceiptURLProtocol.install(f.token) { request in
            if request.httpMethod == "POST" { posts += 1; return (200, try jobData()) }
            if request.url?.path.hasSuffix("/events") == true { return (200, Data()) }
            #expect(request.httpMethod == "GET")
            reads += 1
            return (200, try jobData(exit: reads >= 2 ? 0 : nil))
        }
        _ = try await f.start()
        let job = try #require(f.registry.jobs.first)
        let receipt = try await f.registry.waitForTerminal(id: job.id, forRuntime: f.runtimeID)
        #expect(receipt.status == .completed)
        #expect(receipt.exitCode == 0)
        #expect(posts == 1 && reads == 2)
    }

    @Test("正常 SSE 退出码直接结算，无额外查询或取消", arguments: [0, 19])
    func sseExitIsAuthoritative(exitCode: Int) async throws {
        let f = fixture(); defer { f.cleanup() }
        var posts = 0, extraRequests = 0
        DaemonReceiptURLProtocol.install(f.token) { request in
            if request.httpMethod == "POST" { posts += 1; return (200, try jobData()) }
            if request.url?.path.hasSuffix("/events") == true {
                let event: [String: Any] = ["stream": "exit", "data": "", "exit_code": exitCode]
                let data = try JSONSerialization.data(withJSONObject: event)
                return (200, Data(("data: " + String(decoding: data, as: UTF8.self) + "\n\n").utf8))
            }
            extraRequests += 1
            return (200, try jobData(exit: exitCode))
        }
        _ = try await f.start()
        let job = try #require(f.registry.jobs.first)
        let receipt = try await f.registry.waitForTerminal(id: job.id, forRuntime: f.runtimeID)
        #expect(receipt.status == (exitCode == 0 ? .completed : .failed))
        #expect(receipt.exitCode == Int32(exitCode))
        #expect(posts == 1 && extraRequests == 0)
    }

    @Test("短重试耗尽仍自动恢复，错误任务身份立即拒绝", arguments: [false, true])
    func transientRecoveryAndWrongIdentity(wrongIdentity: Bool) async throws {
        let f = fixture(); defer { f.cleanup() }
        var posts = 0, reads = 0
        DaemonReceiptURLProtocol.install(f.token) { request in
            if request.httpMethod == "POST" { posts += 1; return (200, try jobData()) }
            if request.url?.path.hasSuffix("/events") == true { return (200, Data()) }
            #expect(request.httpMethod == "GET")
            reads += 1
            if wrongIdentity {
                return (200, Data(#"{"ok":true,"data":{"id":"another-job","command":"true","cwd":"/workspace","exit_code":0}}"#.utf8))
            }
            if reads >= 8 { return (200, try jobData(exit: 0)) }
            return (503, Data(#"{"ok":false,"error":"fixture temporarily unavailable"}"#.utf8))
        }
        _ = try await f.start()
        let job = try #require(f.registry.jobs.first)
        if wrongIdentity {
            await #expect(throws: AgentJobError.self) { try await f.registry.waitForTerminal(id: job.id, forRuntime: f.runtimeID) }
            #expect(f.registry.job(id: job.id)?.isAlive == true)
            #expect(f.registry.job(id: job.id)?.exitCode == nil)
            #expect(f.registry.job(id: job.id)?.finishedAt == nil)
            #expect(posts == 1 && reads == 1)
        } else {
            let receipt = try await f.registry.waitForTerminal(id: job.id, forRuntime: f.runtimeID)
            #expect(receipt.status == .completed && receipt.exitCode == 0)
            #expect(posts == 1 && reads == 8)
        }
    }

    @Test("短流重试与状态对账之后仍携带原游标，不丢失或重复输出")
    func cursorSurvivesRecoveryOwner() async throws {
        let f = fixture(); defer { f.cleanup() }
        var streams = 0, posts = 0, reads = 0
        DaemonReceiptURLProtocol.install(f.token, resumable: true) { request in
            if request.httpMethod == "POST" { posts += 1; return (200, try jobData()) }
            if request.url?.path.hasSuffix("/events") == true {
                streams += 1
                #expect(request.value(forHTTPHeaderField: "Last-Event-ID") == (streams == 1 ? "0" : "1"))
                if streams == 1 { return (200, try eventData(sequence: 1)) }
                if streams <= 6 { return (503, Data()) }
                return (200, try eventData(sequence: 1) + eventData(sequence: 2)
                    + eventData(sequence: 3, stream: "exit", text: "", exit: 0))
            }
            reads += 1
            if reads == 1 { return (503, Data()) }
            return (200, try jobData())
        }
        _ = try await f.start()
        let job = try #require(f.registry.jobs.first)
        let receipt = try await f.registry.waitForTerminal(id: job.id, forRuntime: f.runtimeID)
        #expect(receipt.status == .completed && !receipt.isReconnecting)
        #expect(posts == 1 && streams == 7 && reads == 2)
        let events = f.registry.executorEvents(id: job.id)
        #expect(events.filter { $0.detail == "same line" }.count == 2)
        #expect(!events.contains { $0.detail == L10n.JobReceipt.outputGap })
    }

    @Test("权限失败不重复请求或伪造结束，保留活动记录及错误")
    func deniedConfirmationStaysUncertain() async throws {
        let f = fixture(); defer { f.cleanup() }
        var posts = 0, reads = 0
        DaemonReceiptURLProtocol.install(f.token) { request in
            if request.httpMethod == "POST" { posts += 1; return (200, try jobData()) }
            if request.url?.path.hasSuffix("/events") == true { return (503, Data()) }
            reads += 1
            return (403, Data("Forbidden".utf8))
        }
        _ = try await f.start()
        let job = try #require(f.registry.jobs.first)
        await #expect(throws: AgentJobError.self) { try await f.registry.waitForTerminal(id: job.id, forRuntime: f.runtimeID) }
        #expect(f.registry.job(id: job.id)?.isAlive == true)
        #expect(f.registry.job(id: job.id)?.needsAttention == true)
        #expect(f.registry.job(id: job.id)?.exitCode == nil)
        #expect(posts == 1 && reads == 1)
    }

    @Test("Stop 发生在远端接受前后都不丢掉已创建的远端任务", arguments: [false, true])
    func stopAroundRemoteAcceptance(afterAcceptance: Bool) async throws {
        let f = fixture(); defer { f.cleanup() }
        var posts = 0, deletes = 0
        DaemonReceiptURLProtocol.install(f.token) { request in
            if request.httpMethod == "POST" {
                posts += 1
                f.registry.revokeTurn(runtimeID: f.runtimeID, turnID: f.turnID)
                return (200, try jobData())
            }
            if request.url?.path.hasSuffix("/events") == true { return (200, Data()) }
            if request.httpMethod == "DELETE" {
                deletes += 1
                return (200, Data(#"{"ok":true,"data":{"killed":true}}"#.utf8))
            }
            return (200, try jobData(exit: deletes > 0 ? 143 : nil))
        }
        if !afterAcceptance { f.registry.revokeTurn(runtimeID: f.runtimeID, turnID: f.turnID) }
        await #expect(throws: CancellationError.self) { try await f.start() }
        if afterAcceptance {
            let job = try #require(f.registry.jobs.first)
            try await eventually { f.registry.job(id: job.id)?.isAlive == false }
            #expect(f.registry.job(id: job.id)?.status == .killed)
            #expect(deletes == 1 && posts == 1)
            #expect(f.registry.pendingCompletionCount(forRuntime: f.runtimeID) == 0)
        } else {
            #expect(f.registry.jobs.isEmpty)
            #expect(posts == 0 && deletes == 0)
        }
    }
}

nonisolated private final class DaemonReceiptURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (URLRequest) async throws -> (Int, Data)
    static let tokenHeader = "X-Daemon-Receipt-Fixture"
    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]
    private static var resumableTokens: Set<String> = []
    private var work: Task<Void, Never>?
    private var stopped = false
    static func install(_ token: String, resumable: Bool = false, handler: @escaping Handler) {
        lock.withLock {
            handlers[token] = handler
            if resumable { resumableTokens.insert(token) } else { resumableTokens.remove(token) }
        }
    }
    static func remove(_ token: String) { lock.withLock { handlers[token] = nil; resumableTokens.remove(token) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.lock.withLock { request.value(forHTTPHeaderField: Self.tokenHeader).flatMap { Self.handlers[$0] } }
        guard let handler else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let task = Task { @MainActor in
            do {
                let (status, data) = try await handler(request)
                try Task.checkCancellation()
                let resumable = Self.lock.withLock {
                    request.value(forHTTPHeaderField: Self.tokenHeader).map { Self.resumableTokens.contains($0) } ?? false
                }
                var headers = ["Content-Type": request.url?.path.hasSuffix("/events") == true ? "text/event-stream" : "application/json"]
                if resumable { headers["X-Job-Event-Cursor"] = "1" }
                guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status,
                    httpVersion: nil, headerFields: headers)
                else { throw URLError(.badServerResponse) }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        Self.lock.withLock { if stopped { task.cancel() } else { work = task } }
    }
    override func stopLoading() {
        Self.lock.withLock { stopped = true; work?.cancel(); work = nil }
    }
}
