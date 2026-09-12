import Foundation
import Testing
@testable import WillDeep

@Suite("Worker timing log")
struct AgentWorkerTimingLogTests {
    private func temporaryLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("worker-timing-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(AgentWorkerTimingLog.fileName)
    }

    @Test("a worker run line carries kind, timings and no prose")
    func workerRunLineShape() throws {
        let requestedAt = Date(timeIntervalSince1970: 1_000)
        let entry = AgentWorkerTimingLog.WorkerRunEntry(
            runID: UUID(),
            sessionID: UUID(),
            userMessageID: nil,
            profileID: "scout",
            source: "speculativeScout",
            status: "delivered",
            model: "someim-32b-scout",
            providerID: "some-im",
            requestedAt: requestedAt,
            startedAt: requestedAt.addingTimeInterval(0.5),
            finishedAt: requestedAt.addingTimeInterval(12.5),
            rounds: 3,
            toolInvocations: 7,
            inlinedFiles: 2,
            inlinedCharacters: 4_096,
            deliveredAtToolBoundary: true
        )

        #expect(entry.queueSeconds == 0.5)
        #expect(entry.runSeconds == 12)
        let line = try #require(AgentWorkerTimingLog.encodeLine(entry))
        #expect(line.hasSuffix("\n"))
        #expect(line.contains("\"kind\":\"worker_run\""))
        #expect(line.contains("\"profileID\":\"scout\""))
        #expect(line.contains("\"deliveredAtToolBoundary\":true"))
        #expect(line.contains("\"inlinedFiles\":2"))
        #expect(line.contains("\"inlinedCharacters\":4096"))
        // No prose fields: identifiers, timestamps, counts and model names only.
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        #expect(object["report"] == nil)
        #expect(object["prompt"] == nil)
        #expect(object["queueSeconds"] as? Double == 0.5)
    }

    @Test("a turn line derives its spans from the probe anchors")
    func turnLineSpans() {
        let dispatchedAt = Date(timeIntervalSince1970: 2_000)
        var probe = AgentTurnTimingProbe(
            sessionID: UUID(),
            turnID: UUID(),
            dispatchedAt: dispatchedAt,
            providerID: "some-im",
            model: "glm-5",
            routeProfileID: "scout",
            routeConfidence: 90,
            delegationPolicy: "automatic"
        )
        probe.noteRequestSent(at: dispatchedAt.addingTimeInterval(0.8))
        probe.noteFirstToken(at: dispatchedAt.addingTimeInterval(2.3))
        probe.noteToolBoundary(at: dispatchedAt.addingTimeInterval(5))
        // Second round: request count grows, first-token anchor stays put.
        probe.noteRequestSent(at: dispatchedAt.addingTimeInterval(5.1))
        probe.noteFirstToken(at: dispatchedAt.addingTimeInterval(6))
        probe.workerRuns = 1
        probe.parallelScout = "delivered"

        let entry = AgentWorkerTimingLog.TurnEntry(
            probe: probe,
            finishedAt: dispatchedAt.addingTimeInterval(9),
            outcome: "succeeded"
        )

        // Date arithmetic is Double-based; compare with a tolerance.
        func close(_ value: Double?, _ expected: Double) -> Bool {
            guard let value else { return false }
            return abs(value - expected) < 0.001
        }
        #expect(entry.kind == "turn")
        #expect(close(entry.preStreamSeconds, 0.8))
        #expect(close(entry.firstTokenSeconds, 2.3))
        #expect(close(entry.firstToolBoundarySeconds, 5))
        #expect(close(entry.totalSeconds, 9))
        #expect(entry.rounds == 2)
        #expect(entry.workerRuns == 1)
        #expect(entry.parallelScout == "delivered")
        #expect(entry.routeProfileID == "scout")
    }

    @Test("lines append in order and rotate once past the threshold")
    func appendAndRotate() async throws {
        let url = temporaryLogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Each line is 22 bytes; two lines (44) cross a 40-byte threshold, so
        // the third append rotates before writing.
        let writer = AgentWorkerTimingLogWriter(url: url, rotationThresholdBytes: 40)

        await writer.append("{\"kind\":\"turn\",\"n\":1}\n")
        await writer.append("{\"kind\":\"turn\",\"n\":2}\n")
        let firstPass = try String(contentsOf: url, encoding: .utf8)
        #expect(firstPass.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 2)
        #expect(firstPass.hasPrefix("{\"kind\":\"turn\",\"n\":1}"))

        // The old file becomes the rotated sibling and the new line starts a
        // fresh file.
        await writer.append("{\"kind\":\"turn\",\"n\":3}\n")
        let rotated = url.deletingLastPathComponent()
            .appendingPathComponent(AgentWorkerTimingLog.rotatedFileName)
        #expect(FileManager.default.fileExists(atPath: rotated.path))
        let fresh = try String(contentsOf: url, encoding: .utf8)
        #expect(fresh == "{\"kind\":\"turn\",\"n\":3}\n")
    }

    @Test("the default log lives next to judge.jsonl under AgentAudit")
    func defaultLocation() {
        // 显式要生产分支。测试进程里 defaultURL() 会改道到临时目录（见
        // AgentWorkerTimingLogIsolationTests），不传这个参数就只能验到改道
        // 本身，验不到真实落点。
        let url = AgentWorkerTimingLog.defaultURL(underTests: false)
        #expect(url.lastPathComponent == "worker-timing.jsonl")
        #expect(url.deletingLastPathComponent().lastPathComponent == "AgentAudit")
        #expect(url.pathComponents.contains("WillDeep"))
    }
}
