//
//  AgentPipeDrainTests.swift
//  XeditTests
//
//  The end-of-process drain must read everything the child wrote, even when
//  the readability handler never got to it, and must still return when a
//  leaked descendant keeps the write end open.
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentPipeDrainTests {
    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// Several times a pipe buffer is still unread when the process exits —
    /// the load-induced case where one `availableData` lost the tail.
    @Test
    func drainReadsBacklogLargerThanOneReadToEOF() async throws {
        let pipe = Pipe()
        let received = Received()
        let reader = AgentPipeReader(handle: pipe.fileHandleForReading) { received.append($0) }
        var expected = Data()
        for index in 0..<6_000 { expected.append(Data("line \(index) padding-padding-padding\n".utf8)) }
        expected.append(Data("RESULT=42\n".utf8))

        let writer = Thread {
            pipe.fileHandleForWriting.write(expected)
            try? pipe.fileHandleForWriting.close()
        }
        writer.start()

        reader.drainToEnd(graceSeconds: 5)
        #expect(received.value.count == expected.count)
        #expect(received.value == expected)
    }

    @Test
    func drainReturnsWithinGraceWhenWriterStaysOpen() {
        let pipe = Pipe()
        let received = Received()
        let reader = AgentPipeReader(handle: pipe.fileHandleForReading) { received.append($0) }
        pipe.fileHandleForWriting.write(Data("partial\n".utf8))

        let started = Date()
        reader.drainToEnd(graceSeconds: 0.2)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(received.value == Data("partial\n".utf8))
        try? pipe.fileHandleForWriting.close()
    }

    @Test
    func drainStopsAtHardCapWhileWriterKeepsWriting() {
        let pipe = Pipe()
        // ~3 s of 5-byte writes stays far below the pipe buffer, so the writer
        // never blocks and always finishes on its own after the drain gives up.
        let writer = Thread {
            for _ in 0..<3_000 {
                pipe.fileHandleForWriting.write(Data("spam\n".utf8))
                usleep(1_000)
            }
            try? pipe.fileHandleForWriting.close()
        }
        writer.start()

        var total = 0
        let started = Date()
        AgentPipeReader.readUntilEOF(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
            graceSeconds: 1,
            maximumSeconds: 0.5
        ) { total += $0.count }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(total > 0)
    }

    /// No handler read may land after the drain returned.
    @Test
    func handlerReadsNeverLandAfterDrain() async throws {
        let pipe = Pipe()
        let received = Received()
        let reader = AgentPipeReader(handle: pipe.fileHandleForReading) { received.append($0) }
        reader.startReading()
        let payload = Data(repeating: 0x61, count: 200_000)
        let writer = Thread {
            pipe.fileHandleForWriting.write(payload)
            try? pipe.fileHandleForWriting.close()
        }
        writer.start()
        reader.drainToEnd(graceSeconds: 5)
        let atDrain = received.value.count
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(received.value.count == atDrain)
        #expect(atDrain == payload.count)
    }
}
