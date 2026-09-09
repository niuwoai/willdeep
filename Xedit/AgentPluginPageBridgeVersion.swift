//
//  AgentPluginPageBridgeVersion.swift
//  WillDeep
//
//  插件页面桥的版本与能力清单。
//
//  没有这个，一个用了新 API 的插件装到旧宿主上只会在调用那一刻抛
//  `undefined is not a function`，用户看到的是白屏或半截页面，作者也没法
//  提前判断。有了它，插件可以先问再用：
//
//      if ((window.willdeep.capabilities || []).includes('fs.search')) { … }
//      else { /* 降级：让用户自己粘路径 */ }
//
//  规矩：**只增不改**。某个能力真要下线，先让它在清单里消失一个版本，
//  别直接把函数抽掉。
//

import Foundation

nonisolated enum AgentPluginPageBridge {
    /// 桥的语义化版本。加能力升 minor，改既有调用签名升 major。
    static let version = "2.4.0"

    /// 页面可用的能力标识。与注入的 `window.willdeep.*` 一一对应。
    static let capabilities: [String] = [
        "context",
        "commands",
        "conversation.open",
        "ai.complete",
        "ai.cancel",
        "ai.reasoning",
        "ai.image",
        "ai.providers",
        "skills.list",
        "fs.list",
        "fs.read",
        "fs.search",
        "storage",
        "events",
        "chat.insert",
        "chat.send",
        "fs.write",
        "fs.patch",
        "process.run",
        "net.fetch",
        "clipboard.write",
        "notify",
    ]

    /// 直接嵌进注入脚本的 JSON 字面量。
    static var capabilitiesJSONLiteral: String {
        guard let data = try? JSONSerialization.data(withJSONObject: capabilities),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}
