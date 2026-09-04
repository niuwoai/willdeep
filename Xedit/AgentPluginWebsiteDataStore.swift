//
//  AgentPluginWebsiteDataStore.swift
//  WillDeep
//
//  插件页面的 WebKit 数据仓（localStorage / IndexedDB / sessionStorage）。
//
//  此前这里是 `.nonPersistent()`，页面刷一次 localStorage 就空了。直接换成
//  `.default()` 却不行，**因为所有插件页面共用同一个源**
//  （`willdeep-plugin://bundle/`）：一旦持久化，A 插件能原样读到 B 插件
//  存的东西，源隔离在这里等于不存在。这也是当初选 nonPersistent 的原因。
//
//  正确的修法是**一个插件一个仓**：`WKWebsiteDataStore(forIdentifier:)`
//  给的是各自独立的持久化仓，同源不同仓，互相看不见。标识符由插件 ID
//  哈希出来，稳定且不可逆推。
//
//  macOS 13 没有这个 API，那里保持 nonPersistent —— 刷新丢数据，但绝不
//  会把两个插件的数据混在一起。跨版本一致的持久化请用
//  `window.willdeep.storage`（见 AgentPluginHostCapabilities）。
//

import CryptoKit
import Foundation
import WebKit

nonisolated enum AgentPluginWebsiteDataStore {
    /// 把插件 ID 稳定地映射成一个 UUID。同一个插件每次启动都要落到同一个
    /// 仓上，所以不能用随机 UUID；取 SHA256 前 16 字节即可，够稳且不必
    /// 在磁盘上再维护一张映射表。
    static func identifier(for pluginID: AgentPluginID) -> UUID {
        let digest = SHA256.hash(data: Data(pluginID.utf8))
        var bytes = Array(digest.prefix(16))
        // 按 RFC 4122 打上版本与变体位，免得撞上 WebKit 对保留 UUID 的处理。
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// 该插件页面用的数据仓。
    @MainActor
    static func store(for pluginID: AgentPluginID) -> WKWebsiteDataStore {
        if #available(macOS 14.0, *) {
            return WKWebsiteDataStore(forIdentifier: identifier(for: pluginID))
        }
        return .nonPersistent()
    }

    /// 卸载插件时把它的仓一并删掉。留着既占地方，也让「删了再装」拿到
    /// 上一次的残留状态——那是最难查的一类故障。
    ///
    /// **必须等它回来**。WebKit 把删除放在自己的 IO 队列上做，做完再跳回
    /// 主 RunLoop 调回调；发射后不管的话，调用方（测试进程收尾、App 退出）
    /// 可能已经把主 RunLoop 拆了，回调那一跳就会解空指针崩在
    /// `WTF::RunLoop::dispatch` 上。改成 async 并等到回调，让调用方自己
    /// 决定在哪儿等。
    @MainActor
    static func remove(for pluginID: AgentPluginID) async {
        guard #available(macOS 14.0, *) else { return }
        let id = identifier(for: pluginID)
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.remove(forIdentifier: id) { _ in
                continuation.resume()
            }
        }
    }
}
