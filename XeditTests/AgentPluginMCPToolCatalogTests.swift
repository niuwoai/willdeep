import Foundation
import Testing
@testable import WillDeep

/// 插件带的 MCP 服务器早就被注册进总列表了，但模型只能走
/// list_mcp_servers → list_mcp_tools → call_mcp_tool 三段式绕过去。
/// 这个 suite 守住把它们展开成一等工具时的命名与解析。
@Suite
struct AgentPluginMCPToolCatalogTests {
    private let payload = """
    {"tools":[
      {"name":"drama.list","description":"列出短剧"},
      {"name":"drama_list","description":"撞名用的另一个"},
      {"name":"todo.quick_add","description":""}
    ]}
    """

    @Test("点号等非法字符被收敛，provider 才收得下这份工具表")
    func sanitizesToolNames() {
        let tools = AgentPluginMCPToolCatalog.parseTools(from: payload, serverName: "video-studio")
        #expect(tools?.first?.rawName == "drama.list")
        #expect(tools?.first?.exposedName == "mcp__video-studio__drama_list")
        // 连字符是合法字符，不该被换掉。
        #expect(AgentPluginMCPToolCatalog.sanitized("video-studio") == "video-studio")
        #expect(AgentPluginMCPToolCatalog.sanitized("drama.list") == "drama_list")
    }

    /// 字符收敛会把 `a.b` 和 `a_b` 映到同一个名字。两个工具共用一个名字会让
    /// 调用打到错的那个，所以撞了必须加序号。
    @Test("收敛后撞名时加序号，不让两个工具共用一个名字")
    func disambiguatesCollisions() {
        let tools = AgentPluginMCPToolCatalog.parseTools(from: payload, serverName: "video-studio") ?? []
        let exposed = tools.map(\.exposedName)
        #expect(Set(exposed).count == exposed.count)
        #expect(exposed.contains("mcp__video-studio__drama_list"))
        #expect(exposed.contains("mcp__video-studio__drama_list_2"))
    }

    /// 分隔符用双下划线：MCP 工具名里单下划线极常见，用单个会让 `a_b` 的
    /// 服务器和 `b` 的工具撞到同一个名字上。
    @Test("服务器与工具之间用双下划线分隔")
    func usesDoubleUnderscoreSeparator() {
        #expect(AgentPluginMCPToolCatalog.exposedName(serverName: "a_b", toolName: "c")
            != AgentPluginMCPToolCatalog.exposedName(serverName: "a", toolName: "b_c"))
    }

    @Test("从 plugin: 前缀的 id 里取出插件 ID")
    func extractsPluginID() {
        #expect(AgentPluginMCPToolCatalog.pluginID(fromServerID: "plugin:video-studio:video-studio")
            == "video-studio")
        // 服务名本身可以含冒号，只切前两段。
        #expect(AgentPluginMCPToolCatalog.pluginID(fromServerID: "plugin:p:a:b") == "p")
        #expect(AgentPluginMCPToolCatalog.pluginID(fromServerID: "user:whatever") == nil)
        #expect(AgentPluginMCPToolCatalog.pluginID(fromServerID: "plugin:") == nil)
    }

    @Test("返回格式不对时返回 nil，不写一份空目录进缓存")
    func refusesMalformedPayloads() {
        #expect(AgentPluginMCPToolCatalog.parseTools(from: "not json", serverName: "s") == nil)
        #expect(AgentPluginMCPToolCatalog.parseTools(from: "{}", serverName: "s") == nil)
        // 「这个服务器确实没有工具」是合法答案，要和「返回坏了」分开。
        #expect(AgentPluginMCPToolCatalog.parseTools(from: "{\"tools\":[]}", serverName: "s") == [])
    }

    @Test("没有名字的条目被丢掉")
    func dropsNamelessEntries() {
        let tools = AgentPluginMCPToolCatalog.parseTools(
            from: "{\"tools\":[{\"description\":\"无名\"},{\"name\":\"  \"},{\"name\":\"ok\"}]}",
            serverName: "s"
        )
        #expect(tools?.map(\.rawName) == ["ok"])
    }
}
