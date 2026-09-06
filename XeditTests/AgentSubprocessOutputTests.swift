import Foundation
import Testing
@testable import WillDeep

struct AgentSubprocessOutputTests {
    @Test("并发短命令退出时 stdout 与 stderr 完整返回")
    func concurrentShortOutputIsComplete() async throws {
        let expected = "0123456789abcdef0123456789abcdef01234567\n"
        for _ in 0..<4 {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/bin/sh")
                        process.arguments = ["-c", "printf '0123456789abcdef0123456789abcdef01234567\\n'; printf '0123456789abcdef0123456789abcdef01234567\\n' >&2"]
                        let output = try await AgentSubprocess.run(process, timeout: 15)
                        #expect(output.exitStatus == 0)
                        #expect(output.stdoutText == expected)
                        #expect(output.stderrText == expected)
                    }
                }
                try await group.waitForAll()
            }
        }
    }

    @Test("并发大输出收尾不丢字节，同步入口同样完整且保留截断语义")
    func binaryOutputIsComplete() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    let output = try await AgentSubprocess.run(Self.binaryProcess(), timeout: 15, stdoutLimit: 300_000)
                    #expect(output.stdout.count == 262_144)
                    #expect(!output.stdoutWasTruncated)
                }
            }
            try await group.waitForAll()
        }
        let complete = try AgentSubprocess.runSynchronously(Self.binaryProcess(), stdoutLimit: 300_000)
        #expect(complete.stdout.count == 262_144)
        let truncated = try AgentSubprocess.runSynchronously(Self.binaryProcess(), stdoutLimit: 4_096)
        #expect(truncated.stdout.count == 4_096)
        #expect(truncated.stdoutWasTruncated)
    }

    nonisolated private static func binaryProcess() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/head")
        process.arguments = ["-c", "262144", "/dev/zero"]
        return process
    }
}
