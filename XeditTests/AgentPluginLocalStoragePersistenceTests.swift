//
//  AgentPluginLocalStoragePersistenceTests.swift
//  WillDeepTests
//
//  真的把 localStorage 修好了吗？
//
//  「换成持久化仓 localStorage 就活了」是个关于 WebKit 行为的断言，不是
//  关于我们代码的断言——自定义 scheme 的源能不能持久化，只有 WebKit 说了
//  算。所以这里起一个真的 WKWebView，用与线上同款的自定义 scheme 写一次
//  localStorage，再换一个 WebView 用同一个仓读回来。
//
//  跨插件那一半同样重要：所有插件页面共用同一个源，分仓是它们之间**唯一**
//  的隔离，这条要是破了，持久化就是把一个漏洞打开。
//
//  这里**不删**用完的数据仓，是踩过两次才定下来的：
//  `WKWebsiteDataStore.remove(forIdentifier:)` 在自己的 IO 队列上收尾，
//  而本用例创建的 WKWebView 仍持有那个仓，WebKit 拆仓后回调那一跳会解到
//  已经没了的 RunLoop，整个测试进程 SIGSEGV 在 `WTF::RunLoop::dispatch`。
//  症状很有迷惑性：报出来的失败用例是崩溃时恰好在跑的那个，跟本文件无关。
//  改成 await 等回调也没用——崩的是 WebKit 自己的工作项。
//  代价只是每跑一轮在磁盘上留两个几 KB 的测试仓，标识符带 `test.` 前缀。
//

import Foundation
import Testing
import WebKit
@testable import WillDeep

/// 用与线上同样的 scheme/host 供一张空页面，好让源与生产环境一致。
private final class ProbeSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let html = Data("<!doctype html><html><body>probe</body></html>".utf8)
        let response = HTTPURLResponse(
            url: urlSchemeTask.request.url ?? URL(string: "willdeep-plugin://bundle/")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(html)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

@Suite(.serialized)
@MainActor
struct AgentPluginLocalStoragePersistenceTests {
    private static let probeURL = URL(string: "willdeep-plugin://bundle/index.html")!

    private func makeWebView(pluginID: AgentPluginID) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = AgentPluginWebsiteDataStore.store(for: pluginID)
        configuration.setURLSchemeHandler(ProbeSchemeHandler(), forURLScheme: "willdeep-plugin")
        return WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
    }

    /// 加载探针页并跑一段 JS，返回它的字符串结果。
    private func evaluate(_ script: String, in webView: WKWebView) async throws -> String? {
        webView.load(URLRequest(url: Self.probeURL))
        // 轮询到页面可用为止：navigationDelegate 回调在测试里更难收拢，
        // 而这里只关心「能不能跑 JS」。
        for _ in 0..<80 where webView.isLoading {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let value = try await webView.evaluateJavaScript(script)
        return value as? String
    }

    @Test
    func localStorageSurvivesANewWebViewOnTheSameStore() async throws {
        guard #available(macOS 14.0, *) else { return } // 13.x 上仍是 nonPersistent，见实现注释
        let pluginID = "test.persistence.\(UUID().uuidString.prefix(8))"

        let writer = makeWebView(pluginID: pluginID)
        let written = try await evaluate(
            "localStorage.setItem('probe', 'kept'); localStorage.getItem('probe');",
            in: writer
        )
        #expect(written == "kept")

        // 换一个 WebView（等价于刷新/重开页面），仓不变
        let reader = makeWebView(pluginID: pluginID)
        let readBack = try await evaluate("localStorage.getItem('probe') || 'MISSING';", in: reader)
        #expect(readBack == "kept")

    }

    @Test
    func onePluginCannotReadAnothersLocalStorage() async throws {
        guard #available(macOS 14.0, *) else { return }
        let first = "test.isolation.a.\(UUID().uuidString.prefix(8))"
        let second = "test.isolation.b.\(UUID().uuidString.prefix(8))"

        _ = try await evaluate(
            "localStorage.setItem('secret', 'a-only'); localStorage.getItem('secret');",
            in: makeWebView(pluginID: first)
        )
        // 两个插件页面的源是同一个（willdeep-plugin://bundle），隔离全靠分仓
        let leaked = try await evaluate(
            "localStorage.getItem('secret') || 'MISSING';",
            in: makeWebView(pluginID: second)
        )
        #expect(leaked == "MISSING")
    }
}
