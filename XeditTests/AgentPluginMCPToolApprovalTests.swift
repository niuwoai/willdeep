//
//  AgentPluginMCPToolApprovalTests.swift
//  XeditTests
//
//  插件 MCP 一等工具（`mcp__<服务>__<工具>`）的自动审批。
//
//  这些工具此前完全绕开 MCP 的信任策略：服务器设成完全信任不生效，读工具
//  也张张弹卡。守住四件事：完全信任全放行；标准信任下只读（注解或名字）
//  放行；不受信一律人工，Goal 模式也不例外；目录里查不到的名字交给人。
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentPluginMCPToolApprovalTests {
    private static let serverID = "plugin:willdeep-video-studio:video-studio"
    private let root = URL(fileURLWithPath: "/tmp/willdeep-test-workspace")

    private func withSandbox(_ body: () async -> Void) async {
        _ = TestDefaultsHygiene.sweepStaleSuiteFiles
        let suiteName = "com.willdeep.mcp.test.\(UUID().uuidString)"
        guard let sandbox = UserDefaults(suiteName: suiteName) else {
            Issue.record("cannot allocate sandbox defaults suite")
            return
        }
        sandbox.removePersistentDomain(forName: suiteName)
        AgentMCPSettingsStore._setTestDefaultsOverride(sandbox)
        AgentPluginMCPToolCatalog._setTestDefaultsOverride(sandbox)
        defer {
            AgentMCPSettingsStore._setTestDefaultsOverride(nil)
            AgentPluginMCPToolCatalog._setTestDefaultsOverride(nil)
            TestDefaultsHygiene.cleanup(suite: sandbox, named: suiteName)
        }
        AgentPluginMCPToolCatalog.record(
            serverID: Self.serverID,
            pluginID: "willdeep-video-studio",
            serverName: "video-studio",
            listToolsPayload: """
            {"tools":[
              {"name":"drama.get","annotations":{"readOnlyHint":true}},
              {"name":"drama.save_shot"},
              {"name":"list_things"},
              {"name":"drama.sneaky","annotations":{"readOnlyHint":"true"}}
            ]}
            """
        )
        await body()
    }

    private func approval(
        _ tool: String,
        interactionMode: AgentInteractionMode = .normal,
        approvalMode: AgentApprovalMode = .smart
    ) async -> AgentToolApprovalSource? {
        await AppState().autoApprovalSource(
            toolName: "mcp__video-studio__\(tool)",
            arguments: ["arguments_json": .string("{}")],
            risk: .write,
            rootDirectory: root,
            interactionMode: interactionMode,
            approvalMode: approvalMode
        )
    }

    @Test("readOnlyHint 只认布尔 true，旧缓存没有这个键也能解")
    func parsesReadOnlyHint() throws {
        let tools = AgentPluginMCPToolCatalog.parseTools(
            from: #"{"tools":[{"name":"a","annotations":{"readOnlyHint":true}},{"name":"b","annotations":{"readOnlyHint":"true"}},{"name":"c"}]}"#,
            serverName: "s"
        )
        #expect(tools?.map(\.readOnlyHint) == [true, nil, nil])

        let legacy = Data(#"{"rawName":"a","exposedName":"mcp__s__a","description":""}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentPluginMCPToolEntry.self, from: legacy)
        #expect(decoded.readOnlyHint == nil)
    }

    @Test("标准信任：声明只读或名字像只读的放行，写工具不静态放行")
    func standardTrustAllowsReadOnlyTools() async {
        await withSandbox {
            #expect(await approval("drama_get") == .staticAllowlist)
            #expect(await approval("list_things") == .staticAllowlist)
            // 写工具交给安全裁判；测试环境没配裁判，结果必须是「交给人」，不能是静态放行。
            #expect(await approval("drama_save_shot") != .staticAllowlist)
            #expect(await approval("drama_sneaky") != .staticAllowlist, "字符串 \"true\" 不算声明")
        }
    }

    @Test("完全信任：写工具也自动放行，按服务器 id 而不是名字判")
    func fullyTrustedPluginServerAutoApproves() async {
        await withSandbox {
            AgentMCPSettingsStore.setServerTrustLevel(id: Self.serverID, level: .fullyTrusted)
            #expect(await approval("drama_save_shot") == .trustedServer)
            #expect(await approval("drama_save_shot", approvalMode: .workspaceAccess) == .workspaceAccess)
        }
    }

    @Test("不受信：读也要人工，Goal 模式同样不绕过")
    func untrustedPluginServerAlwaysAsks() async {
        await withSandbox {
            AgentMCPSettingsStore.setServerTrustLevel(id: Self.serverID, level: .untrusted)
            #expect(await approval("drama_get") == nil)
            #expect(await approval("drama_save_shot", interactionMode: .goal) == nil)
        }
    }

    @Test("严格模式下插件工具照样每次都问")
    func strictModeStillAsks() async {
        await withSandbox {
            #expect(await approval("drama_get", approvalMode: .requestEveryTime) == nil)
        }
    }

    @Test("目录里查不到的插件工具名交给人")
    func unknownPluginToolAsks() async {
        await withSandbox {
            #expect(await approval("drama_vanished") == nil)
        }
    }

    /// 1.410.0-rc2 之前插件工具的风险等级落到注册表的 `.danger` 兜底：上面这些用例都直接传 `.write`，
    /// 所以没发现主会话里只读工具照样张张弹卡。这里守住真实的风险分级。
    @Test("目录里的插件工具按写级分级（只读放行由审批层判断），查不到的仍是危险级")
    func pluginToolRiskTier() async {
        await withSandbox {
            #expect(AgentToolRegistry.risk(for: "mcp__video-studio__drama_get", arguments: [:]) == .write)
            #expect(AgentToolRegistry.risk(for: "mcp__video-studio__drama_save_shot", arguments: [:]) == .write)
            #expect(AgentToolRegistry.risk(for: "mcp__video_studio__drama_get", arguments: [:]) == .write)
            #expect(AgentToolRegistry.risk(for: "mcp__video-studio__drama_vanished", arguments: [:]) == .danger)
            let risk = AgentToolRegistry.risk(for: "mcp__video-studio__drama_get", arguments: [:])
            let source = await AppState().autoApprovalSource(
                toolName: "mcp__video-studio__drama_get",
                arguments: ["dramaID": .string("d")],
                risk: risk,
                rootDirectory: root,
                interactionMode: .normal,
                approvalMode: .smart
            )
            #expect(source == .staticAllowlist)
        }
    }

    @Test("安全审核看到按参数表直接传的真实参数，不是空的 arguments_json")
    func judgeSeesSchemaArguments() {
        let direct = AgentToolAuthorization.pluginToolArgumentsJSON([
            "dramaID": .string("d1"), "countPerModel": .number(2), "dryRun": .bool(false)
        ])
        #expect(direct == #"{"countPerModel":2,"dramaID":"d1","dryRun":false}"#)
        #expect(AgentToolAuthorization.pluginToolArgumentsJSON(["arguments_json": .string(#"{"a":1}"#)]) == #"{"a":1}"#)
        #expect(AgentToolAuthorization.pluginToolArgumentsJSON([:]) == "{}")
    }
}
