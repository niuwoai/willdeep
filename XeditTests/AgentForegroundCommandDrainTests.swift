import Darwin
import Foundation
import Testing
@testable import WillDeep

@Suite("前台命令管道等待的完成原因", .timeLimit(.minutes(2)))
struct AgentForegroundCommandDrainTests {
    // 独立列出行为期限，不从生产常量派生，避免错误的 idle/hardcap 改动同时改绿预期。
    private static let shortDeadline: TimeInterval = 1
    private static let idleObservationDeadline: TimeInterval = 6
    private static let hardCapObservationDeadline: TimeInterval = 15
    private static let lateActivityOffset: TimeInterval = 8
    private static let writerLifetime: TimeInterval = 30
    private static let writerReadyBudget: TimeInterval = 10
    private static let stdoutSeed = Data("OUT\n".utf8)
    private static let stderrSeed = Data("ERR\n".utf8)

    @Test("根已退出后，从实际读取回调取消必须返回 cancelled", arguments: Stream.allCases)
    func cancellationReturnsItsOwnCompletion(stream: Stream) async throws {
        let observed = try await Self.observe(
            deadlineAfter: Self.idleObservationDeadline,
            cancelOn: stream
        )

        #expect(observed.rootExited)
        #expect(observed.writersStayedOpen)
        #expect(observed.requestedCancellation, "读取回调必须确实取消执行 wait 的当前 Task")
        #expect(observed.completion == .cancelled, "idle 或显式期限收尾不能冒充取消")
        switch stream {
        case .stdout:
            #expect(observed.stdout.prefix == Self.stdoutSeed)
        case .stderr:
            #expect(observed.stderr.prefix == Self.stderrSeed)
        }
    }

    @Test("被持有的双流按 idle、hardcap 或显式期限返回准确原因", arguments: HeldScenario.allCases)
    func heldStreamsChooseExpectedCompletion(scenario: HeldScenario) async throws {
        let observed = try await Self.observe(
            deadlineAfter: scenario.deadlineAfter,
            continuous: scenario.continuous
        )

        #expect(observed.rootExited)
        #expect(observed.writersStayedOpen, "完成前不得用关闭写端制造 EOF")
        #expect(observed.completion == scenario.expectedCompletion)
        #expect(observed.stdout.prefix.starts(with: Self.stdoutSeed))
        #expect(observed.stderr.prefix.starts(with: Self.stderrSeed))
        if scenario.continuous {
            #expect(observed.writerWasRunning, "生产者的自退出不能冒充 hardcap 或 timeout")
            #expect(observed.stdout.totalBytes > Self.stdoutSeed.count)
            #expect(observed.stderr.totalBytes > Self.stderrSeed.count)
        }
        if scenario == .continuousHardCap {
            // 首次实际读取 8s 后才生产小写标记，避免 wait 前的调度停顿造成过早 finished 假绿。
            // 不设严格耗时上界；最终原因仍由上面的 expectedCompletion 判定。
            #expect(observed.stdout.sawLateMarker)
            #expect(observed.stderr.sawLateMarker)
        }
    }

    @Test("根退出且两流 EOF 时收齐尾部并返回 finished")
    func eofPreservesBothTails() async throws {
        let observed = try await Self.observe(
            deadlineAfter: Self.idleObservationDeadline,
            closeWritersBeforeWaiting: true
        )

        #expect(observed.rootExited)
        #expect(!observed.writersStayedOpen)
        #expect(observed.completion == .finished)
        #expect(observed.stdout.prefix == Self.stdoutSeed)
        #expect(observed.stderr.prefix == Self.stderrSeed)
        #expect(observed.stdout.totalBytes == Self.stdoutSeed.count)
        #expect(observed.stderr.totalBytes == Self.stderrSeed.count)
    }

    enum Stream: String, CaseIterable, Sendable {
        case stdout
        case stderr
    }

    enum HeldScenario: String, CaseIterable, Sendable {
        case quietIdle
        case quietTimeout
        case continuousHardCap
        case continuousTimeout

        var continuous: Bool {
            self == .continuousHardCap || self == .continuousTimeout
        }

        var deadlineAfter: TimeInterval {
            switch self {
            case .quietIdle: return AgentForegroundCommandDrainTests.idleObservationDeadline
            case .continuousHardCap: return AgentForegroundCommandDrainTests.hardCapObservationDeadline
            case .quietTimeout, .continuousTimeout: return AgentForegroundCommandDrainTests.shortDeadline
            }
        }

        var expectedCompletion: AgentForegroundCommandDrain.Completion {
            switch self {
            case .quietIdle, .continuousHardCap: return .finished
            case .quietTimeout, .continuousTimeout: return .timedOut
            }
        }
    }

    private struct StreamEvidence: Sendable {
        private static let prefixLimit = 64
        var prefix = Data()
        var totalBytes = 0
        var sawLateMarker = false

        mutating func record(_ data: Data, lateMarker: UInt8) {
            totalBytes += data.count
            prefix.append(data.prefix(max(0, Self.prefixLimit - prefix.count)))
            sawLateMarker = sawLateMarker || data.contains(lateMarker)
        }
    }

    private struct Observation: Sendable {
        let completion: AgentForegroundCommandDrain.Completion
        let rootExited: Bool
        let writersStayedOpen: Bool
        let writerWasRunning: Bool
        let requestedCancellation: Bool
        let stdout: StreamEvidence
        let stderr: StreamEvidence
    }

    private static func observe(
        deadlineAfter: TimeInterval,
        continuous: Bool = false,
        cancelOn: Stream? = nil,
        closeWritersBeforeWaiting: Bool = false
    ) async throws -> Observation {
        // 同步 poll 循环与根退出观测均离开 MainActor；取消不依赖另一个 Task 抢到调度。
        try await Task.detached(priority: .userInitiated) {
            let fixture = PipeFixture()
            defer { fixture.cleanup() }
            try fixture.startAndReapRoot()
            if cancelOn != .stderr {
                try fixture.stdout.fileHandleForWriting.write(contentsOf: stdoutSeed)
            }
            if cancelOn != .stdout {
                try fixture.stderr.fileHandleForWriting.write(contentsOf: stderrSeed)
            }
            if continuous { try fixture.startWriter() }
            if closeWritersBeforeWaiting { fixture.closeWriters() }

            var stdout = StreamEvidence()
            var stderr = StreamEvidence()
            var requestedCancellation = false
            let completion = try AgentForegroundCommandDrain.wait(
                for: fixture.root,
                stdout: fixture.stdout.fileHandleForReading,
                stderr: fixture.stderr.fileHandleForReading,
                deadline: ProcessInfo.processInfo.systemUptime + deadlineAfter,
                receiveStdout: { data in
                    fixture.writer?.markReadObserved()
                    stdout.record(data, lateMarker: DualStreamWriter.stdoutLateMarker)
                    if cancelOn == .stdout {
                        withUnsafeCurrentTask { task in
                            guard let task else { return }
                            requestedCancellation = true
                            task.cancel()
                        }
                    }
                },
                receiveStderr: { data in
                    fixture.writer?.markReadObserved()
                    stderr.record(data, lateMarker: DualStreamWriter.stderrLateMarker)
                    if cancelOn == .stderr {
                        withUnsafeCurrentTask { task in
                            guard let task else { return }
                            requestedCancellation = true
                            task.cancel()
                        }
                    }
                }
            )
            return Observation(
                completion: completion,
                rootExited: !fixture.root.isRunning,
                writersStayedOpen: fixture.writersOpen,
                writerWasRunning: fixture.writer?.isRunning ?? false,
                requestedCancellation: requestedCancellation,
                stdout: stdout,
                stderr: stderr
            )
        }.value
    }

    private final class PipeFixture {
        let root = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        private(set) var writersOpen = true
        private(set) var writer: DualStreamWriter?

        func startAndReapRoot() throws {
            try AgentForegroundCommandDrain.prepare(stdout.fileHandleForReading)
            try AgentForegroundCommandDrain.prepare(stderr.fileHandleForReading)
            try Self.prepareWriter(stdout.fileHandleForWriting, stream: "stdout")
            try Self.prepareWriter(stderr.fileHandleForWriting, stream: "stderr")
            root.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            root.standardInput = FileHandle.nullDevice
            // 使用 FileHandle，保留父进程写端来模拟根退出后仍持有管道的后代。
            root.standardOutput = stdout.fileHandleForWriting
            root.standardError = stderr.fileHandleForWriting
            try root.run()
            root.waitUntilExit()
            try #require(!root.isRunning)
            try #require(root.terminationStatus == 0)
        }

        func startWriter() throws {
            let writer = DualStreamWriter(
                stdout: stdout.fileHandleForWriting.fileDescriptor,
                stderr: stderr.fileHandleForWriting.fileDescriptor
            )
            self.writer = writer
            try #require(writer.waitUntilReady(), "连续生产者必须先向两流实际写入，再开始观测期限")
        }

        func closeWriters() {
            guard writersOpen else { return }
            writersOpen = false
            Self.close(stdout.fileHandleForWriting, label: "stdout 写端")
            Self.close(stderr.fileHandleForWriting, label: "stderr 写端")
        }

        func cleanup() {
            // 所有返回/抛错路径统一先停 writer 并 join，再关闭任何读端，避免 SIGPIPE。
            if let failure = writer?.stopAndJoin() {
                Issue.record("双流生产者失败：\(failure)")
            }
            if root.isRunning {
                root.terminate()
                root.waitUntilExit()
            }
            closeWriters()
            Self.close(stdout.fileHandleForReading, label: "stdout 读端")
            Self.close(stderr.fileHandleForReading, label: "stderr 读端")
        }

        private static func prepareWriter(_ handle: FileHandle, stream: String) throws {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw Self.posixError(operation: "设置 \(stream) 非阻塞写端")
            }
        }

        static func posixError(operation: String) -> POSIXError {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            return POSIXError(code, userInfo: [
                NSLocalizedDescriptionKey: "前台管道夹具\(operation)失败：\(String(cString: strerror(code.rawValue)))"
            ])
        }

        private static func close(_ handle: FileHandle, label: String) {
            do { try handle.close() }
            catch { Issue.record("关闭前台管道夹具 \(label) 失败：\(error)") }
        }
    }

    private final class DualStreamWriter: @unchecked Sendable {
        static let stdoutLateMarker: UInt8 = 0x6f
        static let stderrLateMarker: UInt8 = 0x65
        private static let chunkBytes = 4 * 1024
        private static let writeInterval: TimeInterval = 0.01
        private let stdout: Int32
        private let stderr: Int32
        private let ready = DispatchSemaphore(value: 0)
        private let stop = DispatchSemaphore(value: 0)
        private let finished = DispatchGroup()
        private let observationLock = NSLock()
        // 首次实际读取回调与 writer 线程共享，所有访问都持有 observationLock。
        private var firstReadAt: TimeInterval?
        // 只有 writer 线程写入，stopAndJoin 在 group.wait 之后读取。
        private var failure: POSIXError?

        init(stdout: Int32, stderr: Int32) {
            self.stdout = stdout
            self.stderr = stderr
            finished.enter()
            let thread = Thread { [self] in
                defer { finished.leave() }
                run()
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        var isRunning: Bool { finished.wait(timeout: .now()) == .timedOut }

        func waitUntilReady() -> Bool {
            ready.wait(timeout: .now() + writerReadyBudget) == .success
        }

        func markReadObserved() {
            observationLock.lock()
            defer { observationLock.unlock() }
            if firstReadAt == nil {
                firstReadAt = ProcessInfo.processInfo.systemUptime
            }
        }

        private var lateMarkerIsReady: Bool {
            observationLock.lock()
            defer { observationLock.unlock() }
            guard let firstReadAt else { return false }
            return ProcessInfo.processInfo.systemUptime >= firstReadAt + lateActivityOffset
        }

        func stopAndJoin() -> POSIXError? {
            stop.signal()
            finished.wait()
            return failure
        }

        private func run() {
            let startedAt = ProcessInfo.processInfo.systemUptime
            let expiresAt = startedAt + writerLifetime
            let earlyStdout = [UInt8](repeating: 0x4f, count: Self.chunkBytes)
            let earlyStderr = [UInt8](repeating: 0x45, count: Self.chunkBytes)
            let lateStdout = [UInt8](repeating: Self.stdoutLateMarker, count: Self.chunkBytes)
            let lateStderr = [UInt8](repeating: Self.stderrLateMarker, count: Self.chunkBytes)
            var stdoutReady = false
            var stderrReady = false
            var announcedReady = false

            while ProcessInfo.processInfo.systemUptime < expiresAt {
                let late = lateMarkerIsReady
                let stdoutCount = write(late ? lateStdout : earlyStdout, to: stdout, label: "stdout")
                if failure != nil { return }
                let stderrCount = write(late ? lateStderr : earlyStderr, to: stderr, label: "stderr")
                if failure != nil { return }
                stdoutReady = stdoutReady || stdoutCount > 0
                stderrReady = stderrReady || stderrCount > 0
                if stdoutReady, stderrReady, !announcedReady {
                    announcedReady = true
                    ready.signal()
                }
                // 写端 O_NONBLOCK：缓存满时跳过该流；停止信号可立即唤醒短暂节拍等待。
                if stop.wait(timeout: .now() + Self.writeInterval) == .success { return }
            }
        }

        private func write(_ bytes: [UInt8], to descriptor: Int32, label: String) -> Int {
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno != EAGAIN, errno != EINTR {
                failure = PipeFixture.posixError(operation: "写入 \(label)")
            }
            return max(0, count)
        }
    }
}
