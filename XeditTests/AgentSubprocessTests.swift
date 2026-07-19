import Foundation
import Testing
@testable import WillDeep

struct AgentSubprocessTests {
    @Test("concurrent pipe draining cannot deadlock on noisy stdout and stderr")
    func drainsBothPipesWithBoundedCapture() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "i=0; while [ $i -lt 12000 ]; do printf 'stdout-%05d-xxxxxxxxxxxxxxxx\\n' $i; printf 'stderr-%05d-yyyyyyyyyyyyyyyy\\n' $i >&2; i=$((i+1)); done"
        ]

        let output = try await AgentSubprocess.run(
            process,
            timeout: 10,
            stdoutLimit: 4_096,
            stderrLimit: 4_096
        )

        #expect(output.exitStatus == 0)
        #expect(output.stdout.count <= 4_096)
        #expect(output.stderr.count <= 4_096)
        #expect(output.stdoutWasTruncated)
        #expect(output.stderrWasTruncated)
    }

    @Test("subprocess timeout escalates before natural exit")
    func timeoutTerminatesChild() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]

        let output = try await AgentSubprocess.run(process, timeout: 0.1)

        #expect(output.timedOut)
        #expect(output.exitStatus != 0)
    }
}
