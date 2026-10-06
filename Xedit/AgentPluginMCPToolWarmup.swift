//
//  AgentPluginMCPToolWarmup.swift
//  WillDeep
//
//  插件 MCP 工具目录的后台预热（1.410.0-rc1）。
//
//  起因：聊天里的插件工具来自 `AgentPluginMCPToolCatalog` 这份缓存，以前只在三个时机写入——
//  设置页点「刷新工具」、模型自己调 `list_mcp_tools`、网关拉起插件。新装或刚启用一个插件，
//  主会话里一个工具都看不到，模型多半也想不到先去问；插件升级加了工具，目录还是旧的。
//
//  做法：
//  - App 启动后、插件启用 / 停用 / 安装 / 升级（都会落到 `AgentPluginRuntimeSnapshotStore.update`）后，
//    对每个启用插件的 MCP 服务看一眼目录：没有条目，或者条目记的插件包摘要和当前启用的不一样，
//    就在后台问一次 `tools/list`。摘要一样就不碰，不为「可能用不到」的插件起进程。
//  - 插件发 `notifications/tools/list_changed` 时强制重拉那一个服务。
//  - stdio 连接已经活着时不探测（插件可能正忙，见 `AgentMCPBridge.refreshPluginToolCatalog`），
//    除非是 `list_changed` 触发的。
//  - 串行：同一时间只跑一轮；跑的时候又有变化就记一笔，跑完再来一轮。
//  - 只有 App 启动时调了 `start()` 才生效；单测进程不调，`pluginServersDidChange` 是空操作。
//

import Foundation
import os

@MainActor
final class AgentPluginMCPToolWarmup {
    static let shared = AgentPluginMCPToolWarmup()

    private static let log = Logger(subsystem: "com.willdeep.app", category: "PluginMCPToolWarmup")

    private var started = false
    private var running: Task<Void, Never>?
    private var pendingPass = false
    /// `list_changed` 点名要重拉的服务器 id。
    private var forcedServerIDs: Set<String> = []
    private var observer: NSObjectProtocol?

    func start() {
        guard !started else { return }
        started = true
        observer = NotificationCenter.default.addObserver(
            forName: .agentMCPToolsDidChange, object: nil, queue: .main
        ) { notification in
            let serverID = notification.userInfo?[AgentMCPResourceNotificationKey.serverID] as? String
            MainActor.assumeIsolated {
                AgentPluginMCPToolWarmup.shared.toolsDidChange(serverID: serverID)
            }
        }
        schedule()
    }

    /// 插件集合变了（从任意线程调）。没 `start()` 过时什么也不做。
    nonisolated static func pluginServersDidChange() {
        Task { @MainActor in shared.schedule() }
    }

    func toolsDidChange(serverID: String?) {
        guard started else { return }
        if let serverID, !serverID.isEmpty { forcedServerIDs.insert(serverID) }
        schedule()
    }

    private func schedule() {
        guard started else { return }
        if running != nil {
            pendingPass = true
            return
        }
        running = Task { @MainActor [weak self] in
            await self?.runPasses()
        }
    }

    private func runPasses() async {
        repeat {
            pendingPass = false
            await runPass()
        } while pendingPass
        running = nil
    }

    private func runPass() async {
        let servers = AgentMCPServerDirectory.list().filter { $0.source == .plugin && $0.isEnabled }
        let catalog = AgentPluginMCPToolCatalog.load()
        let digests = Dictionary(
            AgentPluginRuntimeSnapshotStore.activePackages().map { ($0.pluginID, $0.digest) },
            uniquingKeysWith: { first, _ in first }
        )
        for server in servers {
            guard let pluginID = AgentPluginMCPToolCatalog.pluginID(fromServerID: server.id) else { continue }
            let forced = forcedServerIDs.remove(server.id) != nil
            let digest = digests[pluginID]
            guard forced || Self.needsRefresh(cached: catalog[server.id], currentDigest: digest) else { continue }
            do {
                let asked = try await AgentMCPBridge.refreshPluginToolCatalog(
                    server: server, pluginID: pluginID, packageDigest: digest, skipIfLive: !forced
                )
                if asked {
                    Self.log.info("refreshed tool catalog for \(server.id, privacy: .public)")
                }
            } catch {
                // 预热失败不打扰用户：模型仍可调 list_mcp_tools，设置页也能手动刷新。
                Self.log.error("tool catalog warmup failed for \(server.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 没有条目，或条目记的插件包摘要与当前启用版本不一致（含旧缓存没记摘要）时要重拉。
    nonisolated static func needsRefresh(
        cached: AgentPluginMCPToolCatalog.ServerTools?,
        currentDigest: String?
    ) -> Bool {
        guard let cached else { return true }
        return cached.packageDigest != currentDigest
    }
}
