//
//  EditorLanguageServiceEvictionTests.swift
//  WillDeepTests
//
//  Regression tests for the LSP session LRU cap: before 1.129.0-rc28
//  `closeAll()` had no callers and sessions were never evicted, so every
//  workspace the user visited left its language-server process running
//  for the app's whole lifetime.
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct EditorLanguageServiceEvictionTests {
    @Test("LRU eviction stops the oldest LSP session once the cap is exceeded")
    func testEvictsLeastRecentlyUsedSessionBeyondCap() async throws {
        let box = EvictionTransportBox()
        let manager = EditorLanguageServiceManager(
            transportFactory: { _, _, _ in box.makeTransport() },
            executableResolver: { _ in URL(fileURLWithPath: "/usr/bin/true") }
        )

        // One session per distinct workspace root. The cap is 6, so the
        // 7th and 8th sessions must evict the two least-recently-used ones
        // (roots 0 and 1) — and only those.
        let totalSessions = 8
        for index in 0..<totalSessions {
            let root = URL(fileURLWithPath: "/tmp/lsp-evict-\(index)")
            try await manager.synchronizeDocument(
                fileURL: root.appendingPathComponent("main.go"),
                language: .go,
                rootDirectory: root,
                text: "package main\n"
            )
        }

        #expect(box.startedCount == totalSessions)
        #expect(box.stoppedIndices == [0, 1])

        // Touching a surviving session must not spin up a new transport —
        // the cache hit path still works after evictions.
        let survivorRoot = URL(fileURLWithPath: "/tmp/lsp-evict-7")
        try await manager.synchronizeDocument(
            fileURL: survivorRoot.appendingPathComponent("main.go"),
            language: .go,
            rootDirectory: survivorRoot,
            text: "package main\n\nfunc main() {}\n"
        )
        #expect(box.startedCount == totalSessions)

        // An evicted root re-materializes with a fresh session (and a
        // fresh didOpen), evicting the next-oldest survivor in turn.
        let evictedRoot = URL(fileURLWithPath: "/tmp/lsp-evict-0")
        try await manager.synchronizeDocument(
            fileURL: evictedRoot.appendingPathComponent("main.go"),
            language: .go,
            rootDirectory: evictedRoot,
            text: "package main\n"
        )
        #expect(box.startedCount == totalSessions + 1)

        await manager.closeAll()
        #expect(box.allLiveTransportsStopped)
    }
}

/// Hands out one fake transport per factory call and records lifecycle
/// order so the test can assert exactly which sessions were stopped.
private final class EvictionTransportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [EvictionFakeTransport] = []

    func makeTransport() -> LanguageServerTransport {
        lock.lock(); defer { lock.unlock() }
        let transport = EvictionFakeTransport(index: transports.count)
        transports.append(transport)
        return transport
    }

    var startedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return transports.count
    }

    var stoppedIndices: [Int] {
        lock.lock(); defer { lock.unlock() }
        return transports.filter(\.didStop).map(\.index)
    }

    var allLiveTransportsStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return transports.allSatisfy(\.didStop)
    }
}

private final class EvictionFakeTransport: LanguageServerTransport, @unchecked Sendable {
    let index: Int
    private(set) var didStop = false

    var onData: ((Data) -> Void)?
    var onTermination: ((Int32) -> Void)?

    init(index: Int) {
        self.index = index
    }

    func start() throws {}

    func send(_ data: Data) throws {
        var buffer = data
        for payload in LSPMessageFramer.extractMessages(from: &buffer) {
            respondIfNeeded(to: payload)
        }
    }

    func stop() {
        didStop = true
    }

    private func respondIfNeeded(to payload: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let id = object["id"] as? Int,
              let method = object["method"] as? String else {
            return
        }
        // Every request gets a minimal success reply so client calls
        // (initialize, shutdown, …) resolve instead of hanging the test.
        let result: Any = method == "initialize" ? ["capabilities": [:]] : NSNull()
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]
        let data = try! JSONSerialization.data(withJSONObject: response)
        onData?(LSPMessageFramer.frame(payload: data))
    }
}
