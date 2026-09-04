//
//  AgentPluginCommandApprovalStore.swift
//  WillDeep
//
//  「以后不再询问这条命令」记在哪。
//
//  这是一个刻意做窄的记忆：
//   · 记的是**这一条命令的完整原文**，不是前缀，也不是「这个插件随便跑」。
//     `git status` 被记住，不该让 `git push --force` 跟着免检；
//   · 绑在**包的摘要**上。插件一升级，代码就换了人，上一版拿到的信任不该
//     自动过继给新版本——摘要变了，所有记忆自动失效；
//   · 只对已经过了恶意名单、且用户亲手点过一次「运行」的命令生效。
//
//  存在 UserDefaults 里：这是一份可以随时丢弃的便利，丢了最多是多问一次，
//  不值得为它单开一个需要迁移的落盘格式。
//

import Foundation

nonisolated enum AgentPluginCommandApprovalStore {
    private static let defaultsKey = "com.willdeep.plugin.command-approvals"
    /// 单个插件最多记住多少条。上不封顶会让一个话痨插件把用户的确认
    /// 疲劳变成一张永久白名单。
    static let maximumPerPlugin = 40

    /// 记忆的键：插件 ID + 包摘要 + 命令原文。摘要缺失（例如包信息还没
    /// 装载完）时按空串处理，等于与「有摘要」的记忆互不相认——宁可多问
    /// 一次。
    static func signature(command: String, pluginID: AgentPluginID, packageDigest: String?) -> String {
        [pluginID, packageDigest ?? "", command].joined(separator: "\u{1f}")
    }

    static func isRemembered(
        command: String,
        pluginID: AgentPluginID,
        packageDigest: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let stored = defaults.stringArray(forKey: defaultsKey) ?? []
        return stored.contains(signature(command: command, pluginID: pluginID, packageDigest: packageDigest))
    }

    static func remember(
        command: String,
        pluginID: AgentPluginID,
        packageDigest: String?,
        defaults: UserDefaults = .standard
    ) {
        let entry = signature(command: command, pluginID: pluginID, packageDigest: packageDigest)
        var stored = defaults.stringArray(forKey: defaultsKey) ?? []
        guard !stored.contains(entry) else { return }
        stored.append(entry)
        // 按插件裁剪：一个插件的记忆爆掉，不该把别人的挤没。
        let prefix = pluginID + "\u{1f}"
        let mine = stored.filter { $0.hasPrefix(prefix) }
        if mine.count > maximumPerPlugin {
            let dropping = Set(mine.prefix(mine.count - maximumPerPlugin))
            stored.removeAll { dropping.contains($0) }
        }
        defaults.set(stored, forKey: defaultsKey)
    }

    /// 忘掉某个插件的全部记忆。停用、卸载、以及用户在插件中心点「重置」
    /// 时调用。
    static func forget(pluginID: AgentPluginID, defaults: UserDefaults = .standard) {
        let prefix = pluginID + "\u{1f}"
        let stored = (defaults.stringArray(forKey: defaultsKey) ?? []).filter { !$0.hasPrefix(prefix) }
        defaults.set(stored, forKey: defaultsKey)
    }

    /// 某个插件当前记住了几条。插件中心据此显示「已免询问 N 条命令」。
    static func rememberedCount(pluginID: AgentPluginID, defaults: UserDefaults = .standard) -> Int {
        let prefix = pluginID + "\u{1f}"
        return (defaults.stringArray(forKey: defaultsKey) ?? []).filter { $0.hasPrefix(prefix) }.count
    }
}
