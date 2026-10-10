import Foundation
import Testing
@testable import WillDeep

@Suite("凭据缓存并发访问", .serialized)
nonisolated struct AgentCredentialConcurrencyTests {
    private static let readerCount = 256
    private static let readsPerReader = 128

    @Test("后台并发读取不会损坏共享访问计数或缓存字典")
    func concurrentReadsKeepSharedStateValid() {
        let account = "concurrency-fixture/\(UUID())"
        DispatchQueue.concurrentPerform(iterations: Self.readerCount) { _ in
            for _ in 0..<Self.readsPerReader {
                _ = AgentCredentialStore.load(account: account)
                _ = AgentCredentialStore.accounts(matchingPrefix: account)
            }
        }
        #expect(AgentCredentialStore.load(account: account).isEmpty)
        #expect(AgentCredentialStore.accounts(matchingPrefix: account).isEmpty)
    }
}
