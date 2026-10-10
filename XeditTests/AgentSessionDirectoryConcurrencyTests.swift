import Foundation
import Testing
@testable import WillDeep

@Suite("存储目录快照并发访问")
nonisolated struct AgentSessionDirectoryConcurrencyTests {
    private static let workerCount = 128
    private static let roundsPerWorker = 256

    private nonisolated final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var invalidPaths: [String] = []

        func record(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            invalidPaths.append(path)
        }

        var failures: [String] {
            lock.lock(); defer { lock.unlock() }
            return invalidPaths
        }
    }

    @Test("并发替换目录不会使读者持有的 URL 快照失效")
    func concurrentDirectorySnapshotsStayValid() {
        // Exercise the same state used by both stores without redirecting
        // other parallel tests' session files or touching the user's data.
        let state = AgentSessionStore.DirectoryOverrideState()
        let root = URL(fileURLWithPath: "/private/tmp/directory-snapshot-fixture", isDirectory: true)
        let observations = Observations()
        DispatchQueue.concurrentPerform(iterations: Self.workerCount) { worker in
            for round in 0..<Self.roundsPerWorker {
                state.value = root.appendingPathComponent("\(worker)-\(round)", isDirectory: true)
                let captured = state.value
                state.value = nil
                if let captured {
                    let path = captured.path
                    if !path.hasPrefix(root.path + "/") { observations.record(path) }
                    // Foundation bridging is the crash path, so force its
                    // absolute URL/path operations after the shared reset.
                    let absolute = (captured as NSURL).absoluteURL?.path ?? ""
                    if absolute != path { observations.record(absolute) }
                }
            }
        }
        #expect(observations.failures.isEmpty)
        state.value = root
        #expect(state.value == root)
    }
}
