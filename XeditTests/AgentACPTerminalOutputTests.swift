//
//  AgentACPTerminalOutputTests.swift
//  XeditTests
//
//  ACP terminal/create runs arbitrary commands. One that closes its output
//  and keeps running leaves the pipe at EOF for the command's lifetime; the
//  reader must detach there instead of spinning until termination.
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentACPTerminalOutputTests {
    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    @Test
    func readerDetachesAtEOFWhileCommandKeepsRunning() async throws {
        let pipe = Pipe()
        let received = Received()
        AgentACPTerminalOutput.attachReader(to: pipe.fileHandleForReading) { received.append($0) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf ready; exec >&- 2>&-; sleep 20"]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        try? pipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(10)
        while pipe.fileHandleForReading.readabilityHandler != nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(pipe.fileHandleForReading.readabilityHandler == nil)
        #expect(process.isRunning)
        #expect(received.value == Data("ready".utf8))
    }
}
