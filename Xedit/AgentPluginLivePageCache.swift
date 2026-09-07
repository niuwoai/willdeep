//
//  AgentPluginLivePageCache.swift
//  WillDeep
//
//  插件页面离屏保活。
//
//  插件页挂在 `agentPrimaryDestination` 的分支里：切去聊天，整棵 SwiftUI
//  子树被拆，WKWebView 随之释放，页面内存里的一切（玩到一半的游戏、填了
//  一半的表单、滚动位置）全部归零。回来时是一张崭新的页面。而在插件和
//  聊天之间来回切换恰恰是最平常的操作。
//
//  这里按「目标 + 激活包」缓存活着的 WKWebView 与它的 Coordinator：离屏
//  时不拆，回来时原样挂回去，JS 从没停过（离屏的 WebView 不派发
//  requestAnimationFrame，等于自动暂停）。
//
//  三条边界：
//  - 容量有限（默认 3 个），超出按最久未用淘汰，被淘汰的条目交还调用方
//    去做真正的拆卸，缓存自己不碰 WebKit 的拆卸语义。
//  - 一个条目同时只能挂在一处。多窗口同时打开同一个插件页时，第二处必须
//    另建 WebView：NSView 只有一个父视图，共享会把先挂的那处抠成空白。
//  - 换包（重装、内置↔本地切换）会得到不同的键，旧页面自然被淘汰，不会
//    拿旧 HTML 配新资源根。
//

import Foundation
import WebKit

@MainActor
final class AgentPluginLivePageCache {
    static let shared = AgentPluginLivePageCache()

    struct Entry {
        let webView: WKWebView
        let coordinator: AnyObject
        var isMounted: Bool
    }

    /// 同时保活的页面数。放大只会线性吃内存，3 个足够覆盖「聊天 ↔ 插件」
    /// 和在两三个插件之间来回跳这两种真实用法。
    let capacity: Int

    private var entries: [String: Entry] = [:]
    /// 最近使用排在末尾。
    private var order: [String] = []

    init(capacity: Int = 3) {
        self.capacity = max(1, capacity)
    }

    static func key(destinationID: String, packagePath: String) -> String {
        "\(destinationID)|\(packagePath)"
    }

    /// 可复用的条目。已经挂在别处的条目不返回——调用方应当另建一个。
    func reusableEntry(for key: String) -> Entry? {
        guard let entry = entries[key], !entry.isMounted else { return nil }
        touch(key)
        return entry
    }

    /// 记下一个新建的页面，并返回被顶掉或被容量挤掉的条目，由调用方拆卸。
    /// 顶掉同键旧条目的情形真实存在：同一个插件页在两个窗口里打开时，
    /// 后一处拿不到复用（旧条目正挂着），只能另建，缓存随即换成新的那张。
    @discardableResult
    func store(webView: WKWebView, coordinator: AnyObject, for key: String) -> [Entry] {
        var evicted: [Entry] = []
        if let previous = entries[key], previous.webView !== webView {
            evicted.append(previous)
        }
        entries[key] = Entry(webView: webView, coordinator: coordinator, isMounted: true)
        touch(key)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            if let entry = entries.removeValue(forKey: oldest) { evicted.append(entry) }
        }
        return evicted
    }

    func markMounted(_ key: String) {
        guard var entry = entries[key] else { return }
        entry.isMounted = true
        entries[key] = entry
        touch(key)
    }

    /// 页面离屏。返回 true 表示这个 WebView 归缓存所有，调用方不要拆它。
    @discardableResult
    func markUnmounted(_ webView: WKWebView) -> Bool {
        guard let key = entries.first(where: { $0.value.webView === webView })?.key else { return false }
        entries[key]?.isMounted = false
        return true
    }

    func holds(_ webView: WKWebView) -> Bool {
        entries.values.contains { $0.webView === webView }
    }

    /// 丢弃某个目标的所有缓存副本（不同激活包会有多个键），返回给调用方拆卸。
    @discardableResult
    func evictAll(destinationID: String) -> [Entry] {
        let prefix = "\(destinationID)|"
        let keys = entries.keys.filter { $0.hasPrefix(prefix) }
        return keys.compactMap { key in
            order.removeAll { $0 == key }
            return entries.removeValue(forKey: key)
        }
    }

    @discardableResult
    func removeAll() -> [Entry] {
        let all = Array(entries.values)
        entries.removeAll()
        order.removeAll()
        return all
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
