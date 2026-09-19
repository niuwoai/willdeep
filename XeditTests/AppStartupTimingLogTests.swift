import Foundation
import os
import Testing
@testable import WillDeep

@Suite
struct AppStartupTimingLogTests {
    private func makeRecorder(
        startedAt: Date,
        captured: OSAllocatedUnfairLock<[AppStartupTimingLog.Entry]>
    ) -> AppStartupTimingRecorder {
        AppStartupTimingRecorder(
            launchID: UUID(),
            processStartedAt: startedAt,
            appVersion: "9.9.9-rc1",
            build: "999",
            sink: { entry in captured.withLock { $0.append(entry) } }
        )
    }

    @Test("each milestone is recorded once per process, timed from process start")
    func milestoneRecordedOnceFromProcessStart() throws {
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let captured = OSAllocatedUnfairLock(initialState: [AppStartupTimingLog.Entry]())
        let recorder = makeRecorder(startedAt: startedAt, captured: captured)

        let first = try #require(recorder.record(
            .usageDashboardReady,
            at: startedAt.addingTimeInterval(31.5),
            durationSeconds: 28.25,
            count: 304
        ))
        // 统计面板再次出现、第二个窗口打开：同一里程碑不再重复记。
        #expect(recorder.record(.usageDashboardReady, at: startedAt.addingTimeInterval(40)) == nil)
        #expect(recorder.record(.agentWindowAppeared, at: startedAt.addingTimeInterval(1.5)) != nil)

        #expect(first.secondsSinceProcessStart == 31.5)
        #expect(first.durationSeconds == 28.25)
        #expect(first.count == 304)
        #expect(first.launchID == recorder.launchID)
        #expect(first.appVersion == "9.9.9-rc1")
        #expect(first.build == "999")
        #expect(captured.withLock { $0.map(\.milestone) } == [.usageDashboardReady, .agentWindowAppeared])
    }

    @Test("entries encode as one grep-friendly JSONL line with stable keys")
    func entryEncodesAsJSONLine() throws {
        let entry = AppStartupTimingLog.Entry(
            recordedAt: Date(timeIntervalSince1970: 0),
            launchID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            milestone: .sessionCatalogLoaded,
            secondsSinceProcessStart: 2.5,
            durationSeconds: nil,
            count: 12,
            appVersion: "1.0.0",
            build: "1"
        )
        let line = try #require(AgentWorkerTimingLog.encodeLine(entry))
        #expect(line.hasSuffix("\n"))
        #expect(line.filter { $0 == "\n" }.count == 1)
        #expect(line.contains(#""kind":"startup""#))
        #expect(line.contains(#""milestone":"sessionCatalogLoaded""#))
        #expect(line.contains(#""secondsSinceProcessStart":2.5"#))
        let decoded = try JSONDecoder.iso8601.decode(AppStartupTimingLog.Entry.self, from: Data(line.utf8))
        #expect(decoded == entry)
    }

    @Test("process start time comes from the kernel and precedes now")
    func processStartDateIsReal() throws {
        let started = try #require(AppStartupTimingLog.processStartDate())
        let age = Date().timeIntervalSince(started)
        #expect(age >= 0)
        // 测试进程不会活一天以上；读到 1970 之类的垃圾值会在这里暴露。
        #expect(age < 86_400)
    }

    @Test("tests never write into the user's AgentAudit; production sits beside worker-timing.jsonl")
    func logLocationFollowsTestIsolation() {
        let production = AppStartupTimingLog.defaultURL(underTests: false)
        #expect(production.lastPathComponent == AppStartupTimingLog.fileName)
        #expect(production.deletingLastPathComponent().lastPathComponent == "AgentAudit")
        #expect(
            production.deletingLastPathComponent()
                == AgentWorkerTimingLog.defaultURL(underTests: false).deletingLastPathComponent()
        )

        let underTests = AppStartupTimingLog.defaultURL(underTests: true)
        #expect(underTests.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(underTests.lastPathComponent.hasSuffix(AppStartupTimingLog.fileName))
        #expect(underTests.lastPathComponent != AgentWorkerTimingLog.defaultURL(underTests: true).lastPathComponent)
    }

    @Test("the shared writer rotates to the file name it was given")
    func writerRotatesToConfiguredName() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-startup-timing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(AppStartupTimingLog.fileName)
        let writer = AgentWorkerTimingLogWriter(
            url: url,
            rotatedFileName: AppStartupTimingLog.rotatedFileName,
            rotationThresholdBytes: 8
        )
        await writer.append("first line over eight bytes\n")
        await writer.append("second\n")

        let rotated = directory.appendingPathComponent(AppStartupTimingLog.rotatedFileName)
        #expect(try String(contentsOf: rotated, encoding: .utf8) == "first line over eight bytes\n")
        #expect(try String(contentsOf: url, encoding: .utf8) == "second\n")
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(AgentWorkerTimingLog.rotatedFileName).path
        ))
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
