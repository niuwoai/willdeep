//
//  AgentPluginLivePageCacheTests.swift
//  WillDeepTests
//
//  插件页离屏保活缓存。切去聊天再切回来必须拿回同一张活着的页面，
//  而同一张页面不能同时挂在两个窗口上。
//

import Testing
import WebKit
@testable import WillDeep

@MainActor
@Suite struct AgentPluginLivePageCacheTests {
    private func makeWebView() -> WKWebView {
        WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    }

    @Test func offscreenPageComesBackAliveWithItsCoordinator() {
        let cache = AgentPluginLivePageCache()
        let key = AgentPluginLivePageCache.key(destinationID: "hive:page", packagePath: "/a")
        let webView = makeWebView()
        let coordinator = NSObject()
        cache.store(webView: webView, coordinator: coordinator, for: key)

        // 挂着的时候不能被别处抢走。
        #expect(cache.reusableEntry(for: key) == nil)

        #expect(cache.markUnmounted(webView))
        let reused = cache.reusableEntry(for: key)
        #expect(reused?.webView === webView)
        #expect(reused?.coordinator === coordinator)
    }

    @Test func unknownWebViewIsNotOwnedByTheCache() {
        let cache = AgentPluginLivePageCache()
        let stranger = makeWebView()
        #expect(cache.markUnmounted(stranger) == false)
        #expect(cache.holds(stranger) == false)
    }

    @Test func capacityEvictsTheLeastRecentlyUsedPage() {
        let cache = AgentPluginLivePageCache(capacity: 2)
        let first = makeWebView(), second = makeWebView(), third = makeWebView()
        let keys = (0..<3).map { AgentPluginLivePageCache.key(destinationID: "p\($0):page", packagePath: "/a") }
        cache.store(webView: first, coordinator: NSObject(), for: keys[0])
        cache.store(webView: second, coordinator: NSObject(), for: keys[1])
        cache.markUnmounted(first)
        cache.markUnmounted(second)
        // 回访第一张，最久未用的就变成第二张。
        _ = cache.reusableEntry(for: keys[0])
        let evicted = cache.store(webView: third, coordinator: NSObject(), for: keys[2])
        #expect(evicted.count == 1)
        #expect(evicted.first?.webView === second)
        #expect(cache.holds(first))
        #expect(cache.holds(third))
    }

    @Test func replacingTheSameKeyHandsBackTheOldPage() {
        let cache = AgentPluginLivePageCache()
        let key = AgentPluginLivePageCache.key(destinationID: "hive:page", packagePath: "/a")
        let old = makeWebView(), new = makeWebView()
        cache.store(webView: old, coordinator: NSObject(), for: key)
        let evicted = cache.store(webView: new, coordinator: NSObject(), for: key)
        #expect(evicted.first?.webView === old)
        #expect(cache.holds(new))
        #expect(cache.holds(old) == false)
    }

    @Test func switchingActivePackageDropsEveryCopyOfThatDestination() {
        let cache = AgentPluginLivePageCache()
        let bundled = makeWebView(), installed = makeWebView(), other = makeWebView()
        cache.store(
            webView: bundled,
            coordinator: NSObject(),
            for: AgentPluginLivePageCache.key(destinationID: "hive:page", packagePath: "/bundled")
        )
        cache.store(
            webView: installed,
            coordinator: NSObject(),
            for: AgentPluginLivePageCache.key(destinationID: "hive:page", packagePath: "/installed")
        )
        cache.store(
            webView: other,
            coordinator: NSObject(),
            for: AgentPluginLivePageCache.key(destinationID: "arcade:page", packagePath: "/bundled")
        )
        let dropped = cache.evictAll(destinationID: "hive:page")
        #expect(dropped.count == 2)
        #expect(cache.holds(other))
        #expect(cache.holds(bundled) == false)
        #expect(cache.holds(installed) == false)
    }
}
