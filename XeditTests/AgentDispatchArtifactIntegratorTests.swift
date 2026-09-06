import Foundation
import Testing
@testable import WillDeep

@Suite("调度产物真实集成与下游交付")
struct AgentDispatchArtifactIntegratorTests {
    private struct Fixture {
        let root: URL
        let repository: URL
        let base: String

        static func make() async throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-artifact-test-\(UUID().uuidString)")
            let repository = root.appendingPathComponent("repository")
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            _ = try await AgentDispatchArtifactIntegratorTests.git(["init", "-b", "develop"], at: repository)
            try Data("base\n".utf8).write(to: repository.appendingPathComponent("interface.txt"))
            try Data("user baseline\n".utf8).write(to: repository.appendingPathComponent("notes.md"))
            _ = try await AgentDispatchArtifactIntegratorTests.git(["add", "interface.txt", "notes.md"], at: repository)
            _ = try await AgentDispatchArtifactIntegratorTests.git(["commit", "-m", "fixture baseline"], at: repository)
            let base = try await AgentDispatchArtifactIntegratorTests.git(["rev-parse", "HEAD"], at: repository)
            return .init(root: root, repository: repository, base: base)
        }

        func write(_ path: String, _ text: String, at directory: URL? = nil) throws {
            try Data(text.utf8).write(to: (directory ?? repository).appendingPathComponent(path))
        }

        func cleanup() {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Fixture cleanup failed: \(error)") }
        }
    }

    private static func git(_ arguments: [String], at directory: URL) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment.merge([
            "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@localhost",
            "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@localhost",
        ]) { _, new in new }
        process.environment = environment
        let result = try await AgentSubprocess.run(process, timeout: 30)
        #expect(!result.timedOut)
        guard result.exitStatus == 0 else {
            throw AgentDispatchIntegrationError.commandFailed(operation: arguments.first ?? "git", status: result.exitStatus)
        }
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fixture verifier only. Production acceptance must additionally validate
    /// the task contract; these tests exercise Git publication, not that gate.
    private static func integrate(
        _ snapshot: AgentDispatchArtifactSnapshot, in repository: URL,
        goalID: UUID, goalBaseRevision: String
    ) async throws -> AgentDispatchIntegrationReceipt {
        let candidate = try await AgentDispatchArtifactIntegrator.prepareIntegration(
            snapshot, in: repository, goalID: goalID, goalBaseRevision: goalBaseRevision
        )
        _ = try await git(["cat-file", "-e", "\(candidate.revision)^{commit}"], at: repository)
        return try await AgentDispatchArtifactIntegrator.publish(
            candidate, verifiedRevision: candidate.revision, in: repository
        )
    }

    @Test("A 的接口产物可被 B 的真实工作树消费，重复集成不再生成提交")
    func downstreamConsumesIntegratedRevision() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let goalID = UUID()
        try fixture.write("interface.txt", "interface from A\n")
        let first = try await AgentDispatchArtifactIntegrator.snapshot(
            in: fixture.repository, goalID: goalID, taskID: UUID(), baseRevision: fixture.base, paths: ["interface.txt"]
        )
        let receipt = try await Self.integrate(first, in: fixture.repository, goalID: goalID, goalBaseRevision: fixture.base)
        let downstream = fixture.root.appendingPathComponent("downstream")
        _ = try await Self.git(["worktree", "add", "--detach", downstream.path, receipt.integratedRevision], at: fixture.repository)
        #expect(try String(contentsOf: downstream.appendingPathComponent("interface.txt"), encoding: .utf8) == "interface from A\n")
        try fixture.write("report.md", "B verified A's interface\n", at: downstream)
        let second = try await AgentDispatchArtifactIntegrator.snapshot(
            in: downstream, goalID: goalID, taskID: UUID(), baseRevision: receipt.integratedRevision, paths: ["report.md"]
        )
        let integrated = try await Self.integrate(second, in: fixture.repository, goalID: goalID, goalBaseRevision: fixture.base)
        #expect(try await Self.git(["show", "\(integrated.integratedRevision):report.md"], at: fixture.repository) == "B verified A's interface")
        let replay = try await Self.integrate(second, in: fixture.repository, goalID: goalID, goalBaseRevision: fixture.base)
        #expect(replay.integratedRevision == integrated.integratedRevision)
        let recoveredFirst = try await AgentDispatchArtifactIntegrator.publish(
            AgentDispatchIntegrationCandidate(goalID: goalID, snapshot: first, expectedRefRevision: nil, previousRevision: fixture.base, revision: receipt.integratedRevision),
            verifiedRevision: receipt.integratedRevision, in: fixture.repository
        )
        #expect(recoveredFirst.integratedRevision == receipt.integratedRevision)
        #expect(try await AgentDispatchArtifactIntegrator.currentRevision(in: fixture.repository, goalID: goalID, baseRevision: fixture.base) == integrated.integratedRevision)
        #expect(try await Self.git(["rev-parse", "HEAD"], at: fixture.repository) == fixture.base)
    }

    @Test("快照保留用户分支、索引和非本任务改动")
    func snapshotDoesNotConsumeUnrelatedWork() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        try fixture.write("notes.md", "user staged edit\n")
        _ = try await Self.git(["add", "notes.md"], at: fixture.repository)
        let indexBefore = try await Self.git(["diff", "--cached"], at: fixture.repository)
        try fixture.write("interface.txt", "task edit\n")
        let goalID = UUID(), taskID = UUID()
        let snapshot = try await AgentDispatchArtifactIntegrator.snapshot(
            in: fixture.repository, goalID: goalID, taskID: taskID, baseRevision: fixture.base, paths: ["interface.txt"]
        )
        #expect(try await Self.git(["diff", "--cached"], at: fixture.repository) == indexBefore)
        #expect(try await Self.git(["show", "\(snapshot.revision):notes.md"], at: fixture.repository) == "user baseline")
        #expect(try String(contentsOf: fixture.repository.appendingPathComponent("notes.md"), encoding: .utf8) == "user staged edit\n")
        let replay = try await AgentDispatchArtifactIntegrator.snapshot(
            in: fixture.repository, goalID: goalID, taskID: taskID, baseRevision: fixture.base, paths: ["interface.txt"]
        )
        #expect(replay == snapshot)
    }

    @Test("同一基础版本的冲突不会推进集成引用")
    func conflictDoesNotPublish() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let goalID = UUID()
        try fixture.write("interface.txt", "first conflicting edit\n")
        let first = try await AgentDispatchArtifactIntegrator.snapshot(
            in: fixture.repository, goalID: goalID, taskID: UUID(), baseRevision: fixture.base, paths: ["interface.txt"]
        )
        try fixture.write("interface.txt", "second conflicting edit\n")
        let second = try await AgentDispatchArtifactIntegrator.snapshot(
            in: fixture.repository, goalID: goalID, taskID: UUID(), baseRevision: fixture.base, paths: ["interface.txt"]
        )
        let receipt = try await Self.integrate(first, in: fixture.repository, goalID: goalID, goalBaseRevision: fixture.base)
        await #expect(throws: AgentDispatchIntegrationError.conflict) {
            _ = try await Self.integrate(second, in: fixture.repository, goalID: goalID, goalBaseRevision: fixture.base)
        }
        #expect(try await AgentDispatchArtifactIntegrator.currentRevision(in: fixture.repository, goalID: goalID, baseRevision: fixture.base) == receipt.integratedRevision)
    }

    @Test("候选版本未验收或验收版本不匹配时下游输入不变")
    func preparationDoesNotPublish() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let goalID = UUID()
        try fixture.write("interface.txt", "candidate\n")
        let snapshot = try await AgentDispatchArtifactIntegrator.snapshot(
            in: fixture.repository, goalID: goalID, taskID: UUID(), baseRevision: fixture.base, paths: ["interface.txt"]
        )
        let candidate = try await AgentDispatchArtifactIntegrator.prepareIntegration(
            snapshot, in: fixture.repository, goalID: goalID, goalBaseRevision: fixture.base
        )
        #expect(try await AgentDispatchArtifactIntegrator.currentRevision(in: fixture.repository, goalID: goalID, baseRevision: fixture.base) == fixture.base)
        await #expect(throws: AgentDispatchIntegrationError.unverifiedCandidate) {
            _ = try await AgentDispatchArtifactIntegrator.publish(candidate, verifiedRevision: snapshot.revision, in: fixture.repository)
        }
        #expect(try await AgentDispatchArtifactIntegrator.currentRevision(in: fixture.repository, goalID: goalID, baseRevision: fixture.base) == fixture.base)
    }

    @Test("并发候选只发布一个，过期候选必须重新集成和验收")
    func staleCandidateCannotReplaceNewerIntegration() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        let goalID = UUID()
        try fixture.write("interface.txt", "A\n")
        let first = try await AgentDispatchArtifactIntegrator.snapshot(
            in: fixture.repository, goalID: goalID, taskID: UUID(), baseRevision: fixture.base, paths: ["interface.txt"]
        )
        try fixture.write("report.md", "B\n")
        let second = try await AgentDispatchArtifactIntegrator.snapshot(
            in: fixture.repository, goalID: goalID, taskID: UUID(), baseRevision: fixture.base, paths: ["report.md"]
        )
        let firstCandidate = try await AgentDispatchArtifactIntegrator.prepareIntegration(first, in: fixture.repository, goalID: goalID, goalBaseRevision: fixture.base)
        let staleCandidate = try await AgentDispatchArtifactIntegrator.prepareIntegration(second, in: fixture.repository, goalID: goalID, goalBaseRevision: fixture.base)
        _ = try await AgentDispatchArtifactIntegrator.publish(firstCandidate, verifiedRevision: firstCandidate.revision, in: fixture.repository)
        await #expect(throws: AgentDispatchIntegrationError.concurrentUpdate) {
            _ = try await AgentDispatchArtifactIntegrator.publish(staleCandidate, verifiedRevision: staleCandidate.revision, in: fixture.repository)
        }
        let retry = try await Self.integrate(second, in: fixture.repository, goalID: goalID, goalBaseRevision: fixture.base)
        #expect(try await Self.git(["show", "\(retry.integratedRevision):interface.txt"], at: fixture.repository) == "A")
        #expect(try await Self.git(["show", "\(retry.integratedRevision):report.md"], at: fixture.repository) == "B")
        let restored = try JSONDecoder().decode(AgentDispatchIntegrationCandidate.self, from: JSONEncoder().encode(staleCandidate))
        await #expect(throws: AgentDispatchIntegrationError.concurrentUpdate) {
            _ = try await AgentDispatchArtifactIntegrator.publish(restored, verifiedRevision: restored.revision, in: fixture.repository)
        }
        #expect(try await AgentDispatchArtifactIntegrator.currentRevision(in: fixture.repository, goalID: goalID, baseRevision: fixture.base) == retry.integratedRevision)
    }

    @Test("越界及敏感路径不能进入产物快照", arguments: ["../escape", "/absolute", ".git/config", ".env", "secrets/key.pem"])
    func rejectsUnsafePath(path: String) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanup() }
        await #expect(throws: AgentDispatchIntegrationError.unsafePath(path)) {
            _ = try await AgentDispatchArtifactIntegrator.snapshot(
                in: fixture.repository, goalID: UUID(), taskID: UUID(), baseRevision: fixture.base, paths: [path]
            )
        }
    }
}
