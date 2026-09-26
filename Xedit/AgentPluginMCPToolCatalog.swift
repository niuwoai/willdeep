//
//  AgentPluginMCPToolCatalog.swift
//  WillDeep
//
//  把已启用插件带的 MCP 工具展开成模型能直接看见的一等工具。
//
//  在此之前，插件的 MCP 服务器虽然已经被注册进总列表（进程由宿主在第一个
//  请求到来时按需拉起，启用插件本身不起进程），但模型只能走 `list_mcp_servers` → `list_mcp_tools` → `call_mcp_tool`
//  三段式绕过去：工具注册表是纯静态数组，没有动态表。三段式的代价不只是
//  多两轮，而是模型得先想到去问。
//
//  为什么是缓存而不是每次建提示词时现拉：`tools/list` 是一次 JSON-RPC，
//  会把 stdio 子进程拉起来。在提示词构建路径上同步做这件事，等于每个回合
//  都为可能根本用不到的插件付一次进程启动。所以这里存一份，靠三个时机刷新：
//  设置页点「刷新工具」、模型自己调过一次 `list_mcp_tools`、以及插件开关
//  变动时失效。
//
//  缓存过期不是灾难：名字对不上时调用会由 MCP 服务器自己报错，模型看得到。
//  真正要防的是反过来——把一个不存在的工具当成存在并声称已经调过。
//

import Foundation

nonisolated struct AgentPluginMCPToolEntry: Codable, Equatable {
    /// MCP 服务器自己报的工具名，可能带点号等模型工具名不允许的字符。
    let rawName: String
    /// 暴露给模型的名字。
    let exposedName: String
    let description: String
    /// 服务器在 `tools/list` 里用 MCP 标准注解 `annotations.readOnlyHint` 声明
    /// 自己只读。可选：旧缓存里没有这个键，解出来是 nil，按「没声明」处理。
    ///
    /// 只拿它换「标准信任下免批」，与只读名字启发式同一档：一个插件能把写工具
    /// 起名叫 `get_x`，也就能谎报这个注解；这道口子由插件安装批准和服务器
    /// 信任级别（可改成不受信）兜着，不在这里另设。
    var readOnlyHint: Bool? = nil
}

/// 审批期需要的一个插件工具的全部事实。
nonisolated struct AgentPluginMCPToolPolicyRoute: Equatable {
    let serverID: String
    let serverName: String
    let toolName: String
    let readOnlyHint: Bool
}

nonisolated enum AgentPluginMCPToolCatalog {
    /// 暴露名的前缀。与 `call_mcp_tool` 那条元工具并存，不替换它——用户手工
    /// 配置的 MCP 服务器仍然只走元工具，这里只管插件来源。
    static let exposedNamePrefix = "mcp__"

    private static let defaultsKey = "com.willdeep.pluginMCPToolCatalog.v1"

    nonisolated struct ServerTools: Codable, Equatable {
        let pluginID: String
        let serverName: String
        var tools: [AgentPluginMCPToolEntry]
    }

    /// 测试入口：把目录缓存挪到临时 suite，不碰开发机上的真实缓存。
    nonisolated(unsafe) private static var testDefaultsOverride: UserDefaults?

    static func _setTestDefaultsOverride(_ defaults: UserDefaults?) {
        testDefaultsOverride = defaults
    }

    private static var defaults: UserDefaults { testDefaultsOverride ?? .standard }

    nonisolated static func load() -> [String: ServerTools] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: ServerTools].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private nonisolated static func save(_ catalog: [String: ServerTools]) {
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// 收下一次 `tools/list` 的结果。
    ///
    /// 空列表照样写入：「这个服务器现在没有工具」和「还没问过」是两种状态，
    /// 压成一种会让一个刚被清空的服务器永远显示着上次的旧工具。
    nonisolated static func record(
        serverID: String,
        pluginID: String,
        serverName: String,
        listToolsPayload: String
    ) {
        guard let tools = parseTools(from: listToolsPayload, serverName: serverName) else { return }
        var catalog = load()
        catalog[serverID] = ServerTools(pluginID: pluginID, serverName: serverName, tools: tools)
        save(catalog)
    }

    nonisolated static func invalidate(pluginID: String) {
        let trimmed = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let catalog = load().filter { $0.value.pluginID != trimmed }
        save(catalog)
    }

    /// 当前该暴露给模型的工具。
    ///
    /// 只暴露仍然在册且已启用的服务器：缓存是持久化的，插件停用后它的条目
    /// 还在磁盘上，不按现状过一遍就会把一个已经停用的插件的工具端上去。
    /// 不标 nonisolated：`AgentToolDescriptor` 没有显式隔离标注，而工程的
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，所以构造它必须在主 actor 上。
    /// 调用点（提示词构建、设置页）本来都在主 actor。
    @MainActor
    static func descriptors(
        activeServers: [AgentMCPServerConfig]
    ) -> [AgentToolDescriptor] {
        let enabledIDs = Set(activeServers.filter { $0.isEnabled && $0.source == .plugin }.map(\.id))
        let catalog = load()
        return catalog
            .filter { enabledIDs.contains($0.key) }
            .sorted { $0.key < $1.key }
            .flatMap { entry in
                entry.value.tools.map { tool in
                    AgentToolDescriptor(
                        name: tool.exposedName,
                        description: tool.description.isEmpty
                            ? "Tool \(tool.rawName) provided by plugin MCP server \(entry.value.serverName)."
                            : tool.description,
                        // 一律按写处理。是否需要审批由既有的只读启发式和服务器
                        // 信任级别在审批期判定，和 call_mcp_tool 同一套；在这里
                        // 猜成 .read 等于绕过那道门。
                        risk: .write,
                        parameters: [
                            AgentToolParameter(
                                name: "arguments_json",
                                type: .string,
                                description: "JSON object string passed as the MCP tool arguments. Defaults to {}.",
                                required: false
                            )
                        ]
                    )
                }
            }
    }

    /// 从 `plugin:<插件ID>:<服务名>` 这个 id 里取插件 ID。
    ///
    /// 服务名本身可以含冒号，所以只切前两段，剩下的都算服务名。
    nonisolated static func pluginID(fromServerID id: String) -> String? {
        guard id.hasPrefix("plugin:") else { return nil }
        let rest = id.dropFirst("plugin:".count)
        guard let separator = rest.firstIndex(of: ":") else { return nil }
        let pluginID = String(rest[rest.startIndex..<separator])
        return pluginID.isEmpty ? nil : pluginID
    }

    /// 把暴露名解回「哪个插件的哪个服务器的哪个工具」。
    nonisolated static func route(
        exposedName: String
    ) -> (pluginID: String, serverName: String, toolName: String)? {
        guard exposedName.hasPrefix(exposedNamePrefix) else { return nil }
        let catalog = load()
        for (_, server) in catalog {
            if let tool = server.tools.first(where: { $0.exposedName == exposedName }) {
                return (server.pluginID, server.serverName, tool.rawName)
            }
        }
        return nil
    }

    /// 审批用的解析：比 `route` 多带服务器 id 和只读声明。
    ///
    /// 信任级别按服务器 **id** 查，不按名字：两个插件完全可以各带一个叫
    /// `server` 的 MCP 服务，按名字查会让一个的信任设置串到另一个身上。
    nonisolated static func policyRoute(exposedName: String) -> AgentPluginMCPToolPolicyRoute? {
        guard exposedName.hasPrefix(exposedNamePrefix) else { return nil }
        for (serverID, server) in load() {
            if let tool = server.tools.first(where: { $0.exposedName == exposedName }) {
                return AgentPluginMCPToolPolicyRoute(
                    serverID: serverID,
                    serverName: server.serverName,
                    toolName: tool.rawName,
                    readOnlyHint: tool.readOnlyHint == true
                )
            }
        }
        return nil
    }

    nonisolated static func isPluginToolName(_ toolName: String) -> Bool {
        toolName.hasPrefix(exposedNamePrefix)
    }

    /// 暴露名：`mcp__<服务器>__<工具>`，两段都做字符收敛。
    ///
    /// 分隔符用双下划线而不是单个：MCP 工具名里单下划线极常见，用单个会让
    /// `a_b` 的服务器和 `b` 的工具撞到同一个名字上。
    nonisolated static func exposedName(serverName: String, toolName: String) -> String {
        "\(exposedNamePrefix)\(sanitized(serverName))__\(sanitized(toolName))"
    }

    /// provider 侧的工具名只接受字母数字、下划线和连字符。插件工具名里的点号
    /// （`drama.list`）必须换掉，否则整份工具表会被 provider 拒掉。
    nonisolated static func sanitized(_ raw: String) -> String {
        let mapped = raw.map { character -> Character in
            if character.isLetter || character.isNumber || character == "_" || character == "-" {
                return character
            }
            return "_"
        }
        return String(mapped)
    }

    nonisolated static func parseTools(
        from payload: String,
        serverName: String
    ) -> [AgentPluginMCPToolEntry]? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any],
              let rawTools = dict["tools"] as? [[String: Any]] else {
            return nil
        }
        var entries: [AgentPluginMCPToolEntry] = []
        var used = Set<String>()
        for tool in rawTools {
            guard let name = (tool["name"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { continue }
            var exposed = exposedName(serverName: serverName, toolName: name)
            // 字符收敛会把 `a.b` 和 `a_b` 映到同一个名字。撞了就加序号，宁可
            // 名字丑一点，也不能两个工具共用一个名字——那会让调用打到错的那个。
            if used.contains(exposed) {
                var suffix = 2
                while used.contains("\(exposed)_\(suffix)") { suffix += 1 }
                exposed = "\(exposed)_\(suffix)"
            }
            used.insert(exposed)
            entries.append(AgentPluginMCPToolEntry(
                rawName: name,
                exposedName: exposed,
                description: (tool["description"] as? String) ?? "",
                // 只认布尔 true：`"true"` 字符串、缺省都不算声明。
                readOnlyHint: ((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool) == true ? true : nil
            ))
        }
        return entries
    }
}
