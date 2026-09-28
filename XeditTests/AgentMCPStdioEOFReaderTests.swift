//
//  AgentMCPStdioEOFReaderTests.swift
//  XeditTests
//
//  stdio MCP 子进程退出后，输出管道读端停在 EOF 上永远「可读」。
//  readabilityHandler 不摘掉自己就会无限空转，每根管道钉死一个核。
//  这里钉住共享的 AgentPipeEOFReader.attach：数据照常交出去，EOF 后 handler 清空。
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct AgentMCPStdioEOFReaderTests {

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ data: Data) {
            lock.lock()
            storage.append(data)
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private static let eofDeadlineSeconds: TimeInterval = 10

    private static func waitUntilDetached(_ handle: FileHandle) async -> Bool {
        let deadline = Date().addingTimeInterval(eofDeadlineSeconds)
        while Date() < deadline {
            if handle.readabilityHandler == nil { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return handle.readabilityHandler == nil
    }

    /// 写端关闭后 handler 必须摘掉自己，之前写入的数据一字不差交给 sink。
    @Test
    func readerDeliversDataThenDetachesOnEOF() async throws {
        let pipe = Pipe()
        let collected = Collected()
        AgentPipeEOFReader.attach(to: pipe.fileHandleForReading) { data in
            collected.append(data)
        }
        #expect(pipe.fileHandleForReading.readabilityHandler != nil)

        try pipe.fileHandleForWriting.write(contentsOf: Data("{\"id\":1}\n".utf8))
        try pipe.fileHandleForWriting.close()

        let detached = await Self.waitUntilDetached(pipe.fileHandleForReading)
        #expect(detached)
        #expect(String(data: collected.data, encoding: .utf8) == "{\"id\":1}\n")
    }

    /// 真实子进程退出的场景：进程什么都没输出就结束，handler 也要摘掉。
    @Test
    func readerDetachesAfterChildProcessExits() async throws {
        let pipe = Pipe()
        let collected = Collected()
        AgentPipeEOFReader.attach(to: pipe.fileHandleForReading) { data in
            collected.append(data)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        // 父进程这边也持有写端，关掉它管道才会真正到 EOF。
        try pipe.fileHandleForWriting.close()

        let detached = await Self.waitUntilDetached(pipe.fileHandleForReading)
        #expect(detached)
        #expect(collected.data.isEmpty)
    }
}
