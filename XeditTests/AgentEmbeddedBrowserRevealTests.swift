//
//  AgentEmbeddedBrowserRevealTests.swift
//  XeditTests
//
//  Embedded-browser tools show the session's side-panel browser before they
//  run, and the web view presents itself as Safari so sites do not bounce it.
//

import Foundation
import Testing
import WebKit
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentEmbeddedBrowserRevealTests {
    @Test("只有 embedded_browser_ 工具需要亮出浏览器侧栏")
    func policyMatchesEmbeddedBrowserToolsOnly() {
        for toolName in ["embedded_browser_navigate", "embedded_browser_read_page", "embedded_browser_status"] {
            #expect(AgentEmbeddedBrowserAutomationPolicy.requiresVisiblePanel(toolName: toolName))
        }
        for toolName in ["chrome_navigate", "terminal_send_command", "web_fetch"] {
            #expect(!AgentEmbeddedBrowserAutomationPolicy.requiresVisiblePanel(toolName: toolName))
        }
    }

    @Test("当前会话调用浏览器工具时立即打开侧栏浏览器，工具与面板用同一个 WebView")
    func activeSessionRevealsBrowserPanel() throws {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        defer {
            AgentEmbeddedBrowserController.release(for: session.id)
            AgentSessionStore.delete(id: session.id)
        }
        let runtime = try #require(appState.agentRuntimes[session.id])
        runtime.sidePanelState.kind = .files

        #expect(!appState.revealEmbeddedBrowserPanelForToolExecution(toolName: "web_fetch", runtime: runtime))
        #expect(runtime.sidePanelState.kind == .files)

        let now = Date(timeIntervalSince1970: 1_777_777_777)
        #expect(appState.revealEmbeddedBrowserPanelForToolExecution(
            toolName: "embedded_browser_navigate",
            runtime: runtime,
            now: now
        ))
        #expect(runtime.sidePanelState.kind == .embeddedBrowser)
        #expect(runtime.sidePanelState.lastViewedAt == now)
        #expect(appState.agentSidePanelRequest?.kind == .embeddedBrowser)
        let tab = try #require(runtime.sidePanelState.selectedTab)
        let resourceID = try #require(tab.resourceID)
        #expect(AgentEmbeddedBrowserController.activeTabID(for: runtime.id) == resourceID)
        #expect(
            AgentEmbeddedBrowserController.controller(for: runtime.id)
                === AgentEmbeddedBrowserController.controller(for: runtime.id, tabID: resourceID)
        )
    }

    @Test("多个浏览器标签时亮出工具正在驱动的那个")
    func revealSelectsTheDrivenBrowserTab() throws {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        defer {
            AgentEmbeddedBrowserController.release(for: session.id)
            AgentSessionStore.delete(id: session.id)
        }
        let runtime = try #require(appState.agentRuntimes[session.id])
        _ = try #require(appState.createPanelTab(.embeddedBrowser, runtime: runtime))
        let second = try #require(appState.createPanelTab(.embeddedBrowser, runtime: runtime))
        appState.updatePanelTabs(runtime: runtime) { _ = $0.openTab(kind: .files) }
        #expect(runtime.sidePanelState.kind == .files)

        #expect(appState.revealEmbeddedBrowserPanelForToolExecution(
            toolName: "embedded_browser_read_page",
            runtime: runtime
        ))
        #expect(runtime.sidePanelState.selectedTab?.id == second.tabID)
        #expect(runtime.sidePanelState.openTabs.filter { $0.kind == .embeddedBrowser }.count == 2)
    }

    @Test("后台会话的浏览器工具不抢当前会话的侧栏")
    func backgroundSessionDoesNotTakeOverVisiblePanel() throws {
        let appState = AppState()
        let backgroundSession = appState.startNewAgentSession()
        let visibleSession = appState.startNewAgentSession()
        defer {
            AgentEmbeddedBrowserController.release(for: backgroundSession.id)
            AgentSessionStore.delete(id: backgroundSession.id)
            AgentSessionStore.delete(id: visibleSession.id)
        }
        let backgroundRuntime = try #require(appState.agentRuntimes[backgroundSession.id])
        let visibleRuntime = try #require(appState.agentRuntimes[visibleSession.id])
        visibleRuntime.sidePanelState.kind = .files
        appState.agentSidePanelRequest = nil

        #expect(!appState.revealEmbeddedBrowserPanelForToolExecution(
            toolName: "embedded_browser_navigate",
            runtime: backgroundRuntime
        ))
        #expect(appState.activeAgentSessionID == visibleSession.id)
        #expect(backgroundRuntime.sidePanelState.kind == .embeddedBrowser)
        #expect(visibleRuntime.sidePanelState.kind == .files)
        #expect(appState.agentSidePanelRequest == nil)
    }

    @Test("WebView 的 UA 带 Safari 标记")
    func webViewPresentsAsSafari() throws {
        let runtimeID = UUID()
        defer { AgentEmbeddedBrowserController.release(for: runtimeID) }
        let webView = AgentEmbeddedBrowserController.controller(for: runtimeID)
            .ensureWebView(loadInitialPage: false)
        let suffix = try #require(webView.configuration.applicationNameForUserAgent)
        #expect(suffix.hasPrefix("Version/"))
        #expect(suffix.hasSuffix("Safari/605.1.15"))
    }
}
