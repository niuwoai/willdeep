//
//  AgentWidgetWebViewLifecycleTests.swift
//  XeditTests
//
//  Widget 卡片的 WKWebView 生命周期守卫：内容进程被回收后要能自己回来，
//  而无关的 SwiftUI 刷新不能把 widget 从头重灌（会清掉表单和游戏进度）。
//  这里只能做源码级断言——被测类型是 private 的 NSViewRepresentable，
//  行为依赖真实 WebContent 进程。守卫红了先确认是不是这里的断言文本过期了。
//

import Foundation
import Testing
@testable import WillDeep

struct AgentWidgetWebViewLifecycleTests {
    private func widgetCardSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent("Xedit/AgentWidgetCardView.swift"),
            encoding: .utf8
        )
    }

    @Test
    func widgetWebViewRecoversFromWebContentCrash() throws {
        let source = try widgetCardSource()

        #expect(source.contains("func webViewWebContentProcessDidTerminate"))
        #expect(source.contains("func reloadDocument(in webView: WKWebView)"))
        #expect(source.contains("didFailProvisionalNavigation"))
        // 崩溃恢复必须有上限，否则内容进程反复崩时会空转。
        #expect(source.contains("consecutiveProcessCrashes < 3"))
    }

    @Test
    func widgetWebViewOnlyReloadsWhenTheDocumentChanges() throws {
        let source = try widgetCardSource()

        #expect(source.contains("guard context.coordinator.loadedHTML != html"))
        #expect(source.contains("context.coordinator.prepareForLoad(html: html, baseURL: baseURL)"))
    }
}
