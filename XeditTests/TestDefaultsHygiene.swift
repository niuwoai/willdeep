import Foundation

/// 测试专用一次性 UserDefaults suite 的卫生工具。
///
/// 两个实测事实决定了这里的双层防御：
/// 1. `removePersistentDomain(forName:)` 只清空域内容，磁盘上会留下一个
///    ~42 字节的空壳 plist，进程退出也不会消失——只做这一步的测试每跑
///    一次就漏一个壳。
/// 2. 就算收尾时把壳文件也删了，cfprefsd 是异步落盘的，删除动作和它的
///    flush 之间存在竞态，每轮全量测试仍会漏出个位数的壳（开发机上曾
///    累积到 2000+ 个 `com.willdeep.agent.test.defaults.*`）。
///
/// 所以：每个 suite 用完即调 `cleanup`（尽力清），再由每个测试进程首次
/// 建 suite 时触发的 `sweepStaleSuiteFiles` 把上一轮漏网的壳扫掉——
/// 磁盘上的残留从此收敛在一轮的量以内，不再无限累积。
enum TestDefaultsHygiene {
    /// 本仓库测试所有一次性 suite 的命名前缀。新增一次性 suite 命名时
    /// 在此登记，前缀必须是 UUID 段之前的完整字面量，含结尾分隔符——
    /// 点或连字符，按实际命名字面量写（如 `willdeep-runtime-store-` 的
    /// UUID 直接用连字符相接），避免误伤 `com.willdeep.app`、`WillDeep`
    /// 等真实配置域。
    private nonisolated static let disposableSuitePrefixes = [
        "CollaborationConnectorSettingsTests.",
        "com.willdeep.agent.test.defaults.",
        "com.willdeep.mcp.test.",
        "com.willdeep.tests.font-smoothing.",
        "com.willdeep.tests.learningReview.",
        "test.workspace.identity.",
        "willdeep-agent-sidebar-state-",
        "willdeep-dispatch-",
        "willdeep-plugin-approvals-",
        "willdeep-mcp-config-tool-",
        "willdeep-mcp-credentials-",
        "willdeep-mobile-gateway-corrupt-",
        "willdeep-mobile-gateway-forcerelay-",
        "willdeep-mobile-gateway-legacy-",
        "willdeep-mobile-gateway-mode-",
        "willdeep-mobile-gateway-relay-room-",
        "willdeep-mobile-gateway-room-",
        "willdeep-profiles-",
        "willdeep-runtime-store-",
        "willdeep-telemetry-",
        "willdeep-workspace-trust-",
    ]

    /// once 语义：进程内首次访问时扫一遍 ~/Library/Preferences，删掉
    /// 上一轮测试遗留的壳 plist。误删并行测试进程正在用的 suite 文件
    /// 也无碍：这些 UUID 隔离的一次性域全程活在 cfprefsd 内存里，壳
    /// 文件只是落盘影子，读写不经过它。
    nonisolated static let sweepStaleSuiteFiles: Void = {
        let fileManager = FileManager.default
        for library in fileManager.urls(for: .libraryDirectory, in: .userDomainMask) {
            let preferences = library.appendingPathComponent("Preferences", isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: preferences, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ) else { continue }
            for url in entries where url.pathExtension == "plist" {
                let name = url.lastPathComponent
                guard disposableSuitePrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
                try? fileManager.removeItem(at: url)
            }
        }
    }()

    /// suite 用完后的完整收尾：清空域、移出搜索列表、删掉壳文件。
    /// best-effort：cfprefsd 会按自己的节奏把（已清空的）域 flush 成一个
    /// ~42 字节空壳，时机在测试进程内不可控——实测一轮 22 个 sandbox 会
    /// 复活约 19 个壳，在删除前插 `synchronize()` 也压不下去。所以这里
    /// 不追求进程内删干净，真正的收敛靠下一轮进程启动时的 sweep：磁盘
    /// 残留至多一轮的量，不再累积。
    nonisolated static func cleanup(suite: UserDefaults, named suiteName: String) {
        // 兜底触发 sweep：`-only-testing` 只跑单个套件时，创建点不一定
        // 经过已埋 sweep 的路径，这里保证每个测试进程至少扫一次。
        _ = sweepStaleSuiteFiles
        suite.removePersistentDomain(forName: suiteName)
        suite.removeSuite(named: suiteName)
        removeSuiteFile(named: suiteName)
    }

    /// 删除 suite 的壳 plist 文件本体。
    nonisolated static func removeSuiteFile(named suiteName: String) {
        let fileManager = FileManager.default
        for library in fileManager.urls(for: .libraryDirectory, in: .userDomainMask) {
            let plist = library
                .appendingPathComponent("Preferences", isDirectory: true)
                .appendingPathComponent("\(suiteName).plist")
            try? fileManager.removeItem(at: plist)
        }
    }
}
