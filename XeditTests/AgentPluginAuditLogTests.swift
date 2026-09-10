import Foundation
import Testing
@testable import WillDeep

/// 在此之前插件干的活一行都不落盘：问模型走的是 `AgentClient` 直连，跑命令
/// 走的是和 Agent 同一套沙箱但没有任何一次 `AgentSandboxAuditLog.append`。
/// 同一条 `npm install`，Agent 跑留痕，页面跑不留痕。
///
/// 这个 suite 守三件事：目录名不能被插件 ID 带出去、两种记录各自装该装的
/// 东西（AI 那份不含正文，命令那份含命令原文因为命令就是审计本身）、以及
/// 「以后不再询问」之后的每一次执行仍然可数。
@Suite(.serialized)
struct AgentPluginAuditLogTests {
    private func withRoot(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    /// 记录用 ISO8601 编码日期，读回来必须用同一套策略，否则这些用例测的
    /// 是解码器配置而不是落盘行为。
    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 落盘是 detached 的，别的什么都不做就断言会读到空文件。
    private func waitForFile(_ url: URL, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    /// 插件 ID 来自插件清单，可能带斜杠或 `..`。直接当目录名会写到别处去。
    @Test("插件 ID 不能把写入带出 plugins 目录")
    func directoryNameIsContained() {
        #expect(AgentPluginAuditLog.directoryName(forPluginID: "com.willdeep.video-studio") == "com.willdeep.video-studio")
        #expect(!AgentPluginAuditLog.directoryName(forPluginID: "../../etc").contains("/"))
        #expect(!AgentPluginAuditLog.directoryName(forPluginID: "../../etc").contains(".."))
        #expect(AgentPluginAuditLog.directoryName(forPluginID: "a/b").contains("_"))
        #expect(AgentPluginAuditLog.directoryName(forPluginID: "") == "unknown")
        #expect(AgentPluginAuditLog.directoryName(forPluginID: "...") == "unknown")
        #expect(AgentPluginAuditLog.directoryName(forPluginID: String(repeating: "x", count: 500)).count <= 120)
    }

    @Test("一插件一目录，两类记录分开落")
    func eachPluginGetsItsOwnDirectory() async throws {
        try await withRoot { root in
            AgentPluginAuditLog.recordAICall(.init(
                recordedAt: Date(), pluginID: "video-studio", providerID: "some.im", model: "gpt-5.6-sol",
                seconds: 12.5, messageCount: 3, promptCharacters: 4200, skillCount: 0,
                declaredTools: ["write_episode"], toolCalls: ["write_episode"],
                responseCharacters: 800, outcome: "succeeded", errorDescription: nil
            ), root: root)
            AgentPluginAuditLog.recordCommandRun(.init(
                recordedAt: Date(), pluginID: "arcade", command: "yarn build",
                sandboxMode: "workspaceWrite", approval: "remembered",
                seconds: 3.1, outcome: "succeeded", errorDescription: nil
            ), root: root)

            let aiURL = AgentPluginAuditLog.directory(forPluginID: "video-studio", root: root)
                .appendingPathComponent(AgentPluginAuditLog.aiFileName)
            let commandURL = AgentPluginAuditLog.directory(forPluginID: "arcade", root: root)
                .appendingPathComponent(AgentPluginAuditLog.commandsFileName)
            #expect(await waitForFile(aiURL))
            #expect(await waitForFile(commandURL))
            // 两个插件互不串目录。
            #expect(!FileManager.default.fileExists(
                atPath: AgentPluginAuditLog.directory(forPluginID: "arcade", root: root)
                    .appendingPathComponent(AgentPluginAuditLog.aiFileName).path
            ))
        }
    }

    /// AI 那份要能直接交给别人看，所以只装标识符、计数和耗时。
    @Test("AI 记录装的是计数和耗时，不装正文")
    func aiEntryCarriesNoContent() async throws {
        try await withRoot { root in
            AgentPluginAuditLog.recordAICall(.init(
                recordedAt: Date(), pluginID: "video-studio", providerID: "some.im", model: "gpt-5.6-sol",
                seconds: 85.1, messageCount: 4, promptCharacters: 585_622, skillCount: 1,
                declaredTools: ["write_episode"], toolCalls: [],
                responseCharacters: 1200, outcome: "succeeded", errorDescription: nil
            ), root: root)
            let url = AgentPluginAuditLog.directory(forPluginID: "video-studio", root: root)
                .appendingPathComponent(AgentPluginAuditLog.aiFileName)
            #expect(await waitForFile(url))
            let text = try String(contentsOf: url, encoding: .utf8)
            let entry = try decoder.decode(
                AgentPluginAuditLog.AICall.self,
                from: Data(text.split(separator: "\n")[0].utf8)
            )
            #expect(entry.kind == "plugin_ai")
            #expect(entry.promptCharacters == 585_622)
            #expect(entry.seconds == 85.1)
            // 模型用正文回答时 toolCalls 为空——排查「工具没生效」要靠这个。
            #expect(entry.toolCalls.isEmpty)
            #expect(entry.declaredTools == ["write_episode"])
        }
    }

    /// 命令那份相反：命令原文**就是**审计本身，不记等于没记。
    @Test("命令记录带命令原文与放行方式")
    func commandEntryCarriesTheCommandAndHowItWasAllowed() async throws {
        try await withRoot { root in
            for approval in ["alwaysSafe", "remembered", "confirmed", "declined"] {
                AgentPluginAuditLog.recordCommandRun(.init(
                    recordedAt: Date(), pluginID: "arcade", command: "rm -rf node_modules",
                    sandboxMode: "workspaceWrite", approval: approval,
                    seconds: 1.0, outcome: "succeeded", errorDescription: nil
                ), root: root)
            }
            let url = AgentPluginAuditLog.directory(forPluginID: "arcade", root: root)
                .appendingPathComponent(AgentPluginAuditLog.commandsFileName)
            #expect(await waitForFile(url))
            // 四条都要在，尤其是 remembered：勾了「不再询问」之后仍然可数。
            let deadline = Date().addingTimeInterval(5)
            var lines: [String] = []
            while Date() < deadline {
                lines = (try? String(contentsOf: url, encoding: .utf8))?
                    .split(separator: "\n").map(String.init) ?? []
                if lines.count >= 4 { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(lines.count == 4)
            let entries = lines.compactMap {
                try? decoder.decode(AgentPluginAuditLog.CommandRun.self, from: Data($0.utf8))
            }
            #expect(entries.count == 4)
            #expect(Set(entries.map(\.approval)) == ["alwaysSafe", "remembered", "confirmed", "declined"])
            #expect(entries.allSatisfy { $0.command == "rm -rf node_modules" })
        }
    }

    /// 并发页面写同一个文件，两条 JSON 交错进一行就整段解不出来。
    @Test("并发写入不会把两条记录搅在一行")
    func concurrentWritesStayOnTheirOwnLines() async throws {
        try await withRoot { root in
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<25 {
                    group.addTask {
                        AgentPluginAuditLog.recordCommandRun(.init(
                            recordedAt: Date(), pluginID: "arcade", command: "echo \(index)",
                            sandboxMode: "readOnly", approval: "alwaysSafe",
                            seconds: 0.1, outcome: "succeeded", errorDescription: nil
                        ), root: root)
                    }
                }
            }
            let url = AgentPluginAuditLog.directory(forPluginID: "arcade", root: root)
                .appendingPathComponent(AgentPluginAuditLog.commandsFileName)
            #expect(await waitForFile(url))
            let deadline = Date().addingTimeInterval(8)
            var lines: [String] = []
            while Date() < deadline {
                lines = (try? String(contentsOf: url, encoding: .utf8))?
                    .split(separator: "\n").map(String.init) ?? []
                if lines.count >= 25 { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(lines.count == 25)
            // 每一行都必须能单独解出来。
            let decoded = lines.compactMap {
                try? decoder.decode(AgentPluginAuditLog.CommandRun.self, from: Data($0.utf8))
            }
            #expect(decoded.count == lines.count)
        }
    }

    /// `executeCommand` 是页面调宿主命令那条路。它以前一行不记，于是页面
    /// 报「JSON Parse error: Unterminated string」时，除了一句 toast 什么
    /// 线索都没有。记尺寸而不是内容：这类故障要问的是「回了多少字节」。
    @Test("宿主命令调用记尺寸和结果，不记参数与返回内容")
    func hostCallEntryRecordsSizesNotContent() async throws {
        try await withRoot { root in
            AgentPluginAuditLog.recordHostCall(.init(
                recordedAt: Date(), pluginID: "video-studio", commandID: "drama.list",
                argumentCount: 1, argumentBytes: 42, resultBytes: 2_960_028,
                seconds: 1.8, outcome: "succeeded", errorDescription: nil
            ), root: root)
            let url = AgentPluginAuditLog.directory(forPluginID: "video-studio", root: root)
                .appendingPathComponent(AgentPluginAuditLog.hostCallsFileName)
            #expect(await waitForFile(url))
            let text = try String(contentsOf: url, encoding: .utf8)
            let entry = try decoder.decode(
                AgentPluginAuditLog.HostCall.self,
                from: Data(text.split(separator: "\n")[0].utf8)
            )
            #expect(entry.kind == "plugin_host_call")
            #expect(entry.commandID == "drama.list")
            #expect(entry.resultBytes == 2_960_028)
            // 内容一个字都不该在里面。
            #expect(!text.contains("dramas"))
        }
    }

    /// 三类记录各走各的文件，互不覆盖——否则一个插件跑得频繁，另外两类就
    /// 被挤出轮转窗口了。
    @Test("三类记录落在同一目录的三个文件里")
    func threeKindsOfRecordStayInTheirOwnFiles() async throws {
        try await withRoot { root in
            AgentPluginAuditLog.recordAICall(.init(
                recordedAt: Date(), pluginID: "video-studio", providerID: "some.im", model: "m",
                seconds: 1, messageCount: 1, promptCharacters: 10, skillCount: 0,
                declaredTools: [], toolCalls: [], responseCharacters: 5,
                outcome: "succeeded", errorDescription: nil
            ), root: root)
            AgentPluginAuditLog.recordCommandRun(.init(
                recordedAt: Date(), pluginID: "video-studio", command: "yarn build",
                sandboxMode: "workspaceWrite", approval: "confirmed",
                seconds: 1, outcome: "succeeded", errorDescription: nil
            ), root: root)
            AgentPluginAuditLog.recordHostCall(.init(
                recordedAt: Date(), pluginID: "video-studio", commandID: "drama.saveShot",
                argumentCount: 3, argumentBytes: 900, resultBytes: 120,
                seconds: 0.2, outcome: "succeeded", errorDescription: nil
            ), root: root)
            let directory = AgentPluginAuditLog.directory(forPluginID: "video-studio", root: root)
            for name in [AgentPluginAuditLog.aiFileName,
                         AgentPluginAuditLog.commandsFileName,
                         AgentPluginAuditLog.hostCallsFileName] {
                #expect(await waitForFile(directory.appendingPathComponent(name)), "\(name)")
            }
        }
    }
}
