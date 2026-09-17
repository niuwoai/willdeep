//
//  AgentMonitorToolTests.swift
//  XeditTests
//
//  `monitor` 工具的运行时行为（真实短进程，≤3s）与审批等价性。合同见
//  docs/BACKGROUND_TASK_CONTRACT.md「第三批 · C·一」。
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentMonitorToolTests {
    @MainActor
    private final class Harness {
        let root: URL
        let registry: AgentJobRegistry
        let runtimeID = UUID()
        var publications: [AgentMonitorSession.Publication] = []

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("willdeep-monitor-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            registry = AgentJobRegistry(outputLogRootDirectory: root.appendingPathComponent("background-jobs"))
            registry.onMonitorPublication = { [unowned self] in self.publications.append($0) }
        }

        var context: AgentToolContext {
            AgentToolContext(rootDirectory: root, runtimeID: runtimeID, jobRegistry: registry,
                             sandboxMode: .escalated, canSpawnSubagents: true)
        }

        func start(_ command: String, timeout: Int? = nil, label: String = "watch the build") async throws -> String {
            var arguments: [String: AgentJSONValue] = ["command": .string(command), "label": .string(label)]
            if let timeout { arguments["timeout_seconds"] = .number(Double(timeout)) }
            let form = AgentMonitorTool.authorizationForm(toolName: "monitor", arguments: arguments)
            #expect(form.toolName == "run_command")
            let result = try await AgentToolRunner.runCommand(arguments: form.arguments, context: context)
            let handle = result.payload.split(separator: " ")
                .first { $0.hasPrefix("mon_") }
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            return try #require(handle)
        }

        func waitFor(_ predicate: (AgentMonitorSession.Publication) -> Bool) async -> AgentMonitorSession.Publication? {
            for _ in 0..<500 {
                if let match = publications.first(where: predicate) { return match }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return nil
        }

        func job(_ handle: String) -> AgentBackgroundJob? {
            registry.job(matchingHandle: handle, runtimeID: runtimeID)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test("stdout 行在命令结束前就作为事件到达；stderr 只进日志；结束通知带退出码与投递数")
    func linesArriveWhileTheCommandIsStillRunning() async throws {
        let harness = try Harness()
        let handle = try await harness.start(
            "printf 'ok 1\\n'; printf 'to-stderr\\n' >&2; sleep 1; printf 'ERR%s: boom\\n' OR; printf '   \\n'; sleep 1; exit 1",
            timeout: 30
        )
        #expect(handle.hasPrefix("mon_") && handle.count == 10)
        let job = try #require(harness.job(handle))
        #expect(job.isMonitor && job.displayHandle == handle)

        let first = try #require(await harness.waitFor { $0.payload.contains("ok 1") })
        #expect(first.dedupeKey == "monitor:\(handle):1")
        #expect(first.wakes)
        #expect(first.payload.hasPrefix("<monitor-event>\nid: \(handle)\nlabel: watch the build\nseq: 1\nlines: 1\n"))
        #expect(!first.payload.contains("to-stderr"))

        let error = try #require(await harness.waitFor { $0.payload.contains("ERROR: boom") })
        #expect(error.dedupeKey == "monitor:\(handle):2")
        #expect(!error.wakes, "the second event inside 30s must only enqueue")
        #expect(harness.job(handle)?.isAlive == true, "the ERROR event must arrive before the command exits")

        let listed = try await AgentToolRunner.listJobs(arguments: [:], context: harness.context)
        #expect(listed.payload.contains(handle))
        let progress = try await AgentToolRunner.getJobOutput(
            arguments: ["job_id": .string(handle), "tail_lines": .number(5)], context: harness.context)
        #expect(progress.payload.contains("status: running"))
        #expect(progress.payload.contains("ERROR: boom"))

        let ended = try #require(await harness.waitFor { $0.isEnded })
        #expect(ended.dedupeKey == "monitor:\(handle):ended")
        #expect(ended.payload.contains("reason: exited\nexit_code: 1\n"), "\(ended.payload)")
        #expect(ended.payload.contains("events: 2\n"))
        #expect(ended.wakes && ended.isUrgent)
        let logURL = harness.root.appendingPathComponent("background-jobs/\(handle)/output.log")
        #expect(ended.payload.contains("output_path: \(logURL.path)\n"))
        let log = try String(contentsOf: logURL, encoding: .utf8)
        #expect(log.contains("ok 1\n") && log.contains("to-stderr\n") && log.contains("ERROR: boom\n") && log.contains("   \n"))
        #expect(harness.publications.filter { !$0.isEnded }.count == 2)
        // A monitor reports its own end: no v1 completion is queued for it.
        #expect(harness.registry.consumePendingCompletions(forRuntime: harness.runtimeID).isEmpty)
        #expect(harness.job(handle)?.status == .failed)
    }

    @Test("超过 2000 字符的行截到 2000 字符以 … 结尾，日志保留原文")
    func longLinesAreTruncatedInEventsButNotInTheLog() async throws {
        let harness = try Harness()
        let handle = try await harness.start("printf '%03000d\\n' 7", timeout: 30)
        let event = try #require(await harness.waitFor { !$0.isEnded })
        let body = event.payload.components(separatedBy: "```text\n")[1].components(separatedBy: "\n```")[0]
        #expect(body.unicodeScalars.count == 2_000)
        #expect(body.hasSuffix("…"))
        _ = await harness.waitFor { $0.isEnded }
        let log = try String(contentsOf: harness.root.appendingPathComponent("background-jobs/\(handle)/output.log"), encoding: .utf8)
        #expect(log.count == 3_001)
    }

    @Test("刷屏命令在 30 个事件后被停下，结束原因 flooded，作业记为 killed")
    func aFloodingCommandIsStopped() async throws {
        let harness = try Harness()
        let handle = try await harness.start("i=0; while true; do echo \"spam $i\"; i=$((i+1)); done", timeout: 60)
        let ended = try #require(await harness.waitFor { $0.isEnded })
        #expect(ended.payload.contains("reason: flooded\nexit_code: unknown\n"), "\(ended.payload)")
        #expect(ended.payload.contains("events: 30\n"))
        #expect(harness.publications.filter { !$0.isEnded }.count == 30)
        for _ in 0..<100 where harness.job(handle)?.isAlive == true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(harness.job(handle)?.status == .killed)
    }

    @Test("kill_job 停下监视器记 killed；到点记 timed_out")
    func killJobStopsAMonitorAndADeadlineTimesItOut() async throws {
        let harness = try Harness()
        let killed = try await harness.start("sleep 30")
        let killResult = try await AgentToolRunner.killJob(arguments: ["job_id": .string(killed)], context: harness.context)
        #expect(killResult.summary.contains(killed))
        let killedEnd = try #require(await harness.waitFor {
            $0.isEnded && $0.payload.contains("id: \(killed)\nlabel: watch the build\nreason: killed\n")
        })
        #expect(killedEnd.payload.contains("exit_code: unknown\n"))

        let timed = try await harness.start("sleep 30", timeout: 1)
        let timedEnd = try #require(await harness.waitFor {
            $0.isEnded && $0.payload.contains("id: \(timed)\nlabel: watch the build\nreason: timed_out\n")
        })
        #expect(timedEnd.payload.contains("events: 0\n"))
    }

    @Test("子 Agent 上下文与远端工作区拿不到 monitor；缺 label 被拒")
    func monitorIsMainConversationAndLocalOnly() async throws {
        let harness = try Harness()
        let form = AgentMonitorTool.authorizationForm(
            toolName: "monitor", arguments: ["command": .string("echo hi"), "label": .string("x")])
        let child = AgentToolContext(rootDirectory: harness.root, runtimeID: harness.runtimeID,
                                     jobRegistry: harness.registry, sandboxMode: .escalated, canSpawnSubagents: false)
        await #expect(throws: AgentToolError.self) {
            _ = try await AgentToolRunner.runCommand(arguments: form.arguments, context: child)
        }
        #expect(AgentToolRegistry.argumentValidationError(for: "monitor", arguments: ["command": .string("echo")]) != nil)
        #expect(harness.registry.jobs(forRuntime: harness.runtimeID).isEmpty)
    }

    // MARK: - Approval equivalence

    private static let commands = [
        "ls -la",
        "tail -f build.log | grep --line-buffered -E 'Error|FAILED'",
        "npm install left-pad",
        "curl -s https://example.com/status",
        "rm -rf ~/Documents/project",
        "cat ~/.ssh/id_rsa",
        "git push --force origin main",
    ]

    @Test("同一条命令：monitor 与后台 run_command 的风险、沙箱判定与自动批准逐项相同")
    func monitorAuthorizationIsIdenticalToRunCommand() async throws {
        let root = URL(fileURLWithPath: "/tmp/willdeep-monitor-approval")
        let appState = AppState()
        for command in Self.commands {
            let monitor = AgentMonitorTool.authorizationForm(
                toolName: "monitor",
                arguments: ["command": .string(command), "label": .string("watch"), "timeout_seconds": .number(60)])
            let plain: [String: AgentJSONValue] = [
                "command": .string(command), "label": .string("watch"), "run_in_background": .bool(true)]
            #expect(monitor.toolName == "run_command")
            var withoutHostKey = monitor.arguments
            withoutHostKey.removeValue(forKey: AgentMonitorTool.hostArgumentKey)
            #expect(withoutHostKey == plain)

            let monitorRisk = AgentToolRegistry.risk(for: monitor.toolName, arguments: monitor.arguments, rootDirectory: root)
            let plainRisk = AgentToolRegistry.risk(for: "run_command", arguments: plain, rootDirectory: root)
            #expect(monitorRisk == plainRisk, "risk differs for \(command)")
            #expect(AgentSandboxPolicy.decision(toolName: monitor.toolName, arguments: monitor.arguments, rootDirectory: root)
                == AgentSandboxPolicy.decision(toolName: "run_command", arguments: plain, rootDirectory: root),
                "sandbox decision differs for \(command)")
            // Smart mode may consult the network judge for writes; the
            // deterministic modes are compared for every command.
            for mode in [AgentApprovalMode.fullAccess, .workspaceAccess, .requestEveryTime] {
                let monitorSource = await appState.autoApprovalSource(
                    toolName: monitor.toolName, arguments: monitor.arguments, risk: monitorRisk,
                    rootDirectory: root, approvalMode: mode)
                let plainSource = await appState.autoApprovalSource(
                    toolName: "run_command", arguments: plain, risk: plainRisk,
                    rootDirectory: root, approvalMode: mode)
                #expect(monitorSource == plainSource, "auto-approval differs for \(command) in \(mode)")
            }
        }
    }

    @Test("模型自己塞进 run_command 的 _monitor 被剥掉，普通工具原样通过")
    func forgedHostArgumentIsStripped() {
        let forged = AgentMonitorTool.authorizationForm(
            toolName: "run_command",
            arguments: ["command": .string("echo hi"), AgentMonitorTool.hostArgumentKey: .object(["label": .string("x")])])
        #expect(forged.toolName == "run_command")
        #expect(!AgentMonitorTool.isMonitorInvocation(forged.arguments))
        let other = AgentMonitorTool.authorizationForm(toolName: "read_file", arguments: ["path": .string("a")])
        #expect(other.toolName == "read_file" && other.arguments == ["path": .string("a")])
    }

    @Test("monitor 与两个子 Agent 控制工具进主会话核心工具面，子 Agent 工具面一律没有")
    func toolSurfaces() {
        let names = [AgentMonitorTool.name, "send_agent_message", "stop_agent"]
        for name in names {
            #expect(AgentToolPackCatalog.coreToolNames.contains(name))
            #expect(AgentToolRegistry.descriptor(for: name) != nil)
            #expect(!AgentSubagentRunner.allowedToolNames.contains(name))
        }
        for profile in AgentSubagentProfileCatalog.builtIn {
            let permitted = profile.effectiveToolNames(writeAccessGranted: true, approvedCommandGranted: true)
            #expect(permitted.isDisjoint(with: names), "\(profile.id) exposes a parent-only tool")
        }
        #expect(AgentMonitorTool.descriptor.description.contains("run_in_background"))
        #expect(AgentMonitorTool.descriptor.description.contains("grep --line-buffered"))
        #expect(AgentMonitorTool.descriptor.description.contains("Traceback"))
    }
}
