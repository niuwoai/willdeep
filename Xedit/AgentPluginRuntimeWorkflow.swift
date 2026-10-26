import Foundation

/// Only durable short-drama controls cross this boundary. Ordinary plugin tools
/// keep their existing host. Runtime owns workflow state, plugin data and budgets.
@MainActor
enum AgentPluginRuntimeWorkflow {
    static let pluginID = "willdeep-video-studio"
    static let tools: Set<String> = [
        "screenplay.start", "screenplay.list", "screenplay.inspect", "screenplay.cancel",
        "screenplay.resume", "screenplay.budget", "screenplay.download",
        "production.start", "production.list", "production.inspect", "production.cancel",
        "production.resume", "production.budget", "production.pause", "production.music",
        "production.delivery", "production.file", "production.configuration"
    ]

    static func routes(server: AgentMCPServerConfig, method: String, params: [String: Any]) -> Bool {
        method == "tools/call" && AgentMCPHostRequests.pluginID(for: server) == pluginID
            && (params["name"] as? String).map { tools.contains($0) } == true
    }

    static func call(tool: String, arguments: [String: Any]) async throws -> String {
        guard tools.contains(tool), AgentPluginRegistry.shared.hasPermission(.aiChat, pluginID: pluginID) else {
            throw AgentPluginCapabilityError.permissionDenied(AgentPluginPermission.aiChat.rawValue)
        }
        let registry = EditorAppStateRegistry.shared
        guard let appState = registry.current ?? registry.appStatesForTerminationCheck.first else {
            throw AgentPluginCapabilityError.noWorkspace
        }
        let roots = appState.pluginAccessibleWorkspaceRoots.map { $0.resolvingSymlinksInPath().path }
        guard !roots.isEmpty else { throw AgentPluginCapabilityError.noWorkspace }
        guard let connection = WillDeepRuntimeDiscovery.connection() else {
            throw WillDeepRuntimeTransportError.noRuntime
        }
        let params = try JSONSerialization.data(withJSONObject: [
            "tool": tool, "arguments": arguments, "workspaces": roots
        ])
        // The read-only Runtime observer remains read-only. This dedicated
        // controller never starts/restarts Runtime and exposes no arbitrary API.
        let data = try await Task.detached {
            guard let object = try JSONSerialization.jsonObject(with: params) as? [String: Any] else {
                throw WillDeepRuntimeTransportError.malformedResponse("plugin.workflow parameters")
            }
            return try WillDeepRuntimeTransport.send(operation: "plugin.workflow", params: object,
                                                    connection: connection, timeout: 120)
        }.value
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WillDeepRuntimeTransportError.malformedResponse("plugin.workflow envelope")
        }
        if let error = envelope["error"] as? [String: Any] {
            throw WillDeepRuntimeTransportError.api(code: error["code"] as? String ?? "unknown",
                                                   message: error["message"] as? String ?? "plugin.workflow failed")
        }
        guard let result = envelope["data"] as? [String: Any] else {
            throw WillDeepRuntimeTransportError.malformedResponse("plugin.workflow data")
        }
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        return String(decoding: encoded, as: UTF8.self)
    }
}
