//
//  AgentEmbeddedBrowserProfileTests.swift
//  XeditTests
//
//  The isolated browser: its own data store (nothing shared with the user's
//  sign-ins), switching rebuilds the web view and carries to new tabs of the
//  session, ordinary actions there run without a card, and a call approved
//  under one profile never runs under the other.
//
//  The default store is only ever read here, never written: the test host
//  shares the app's container with the real WillDeep.
//

import Foundation
import Testing
import SwiftUI
import WebKit
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentEmbeddedBrowserProfileTests {
    private let profileKey = AgentToolAuthorization.embeddedBrowserProfileArgument
    private let hostKey = AgentToolAuthorization.embeddedBrowserPageHostArgument
    private let labelKey = AgentToolAuthorization.embeddedBrowserTargetLabelArgument

    private func isolated(_ extra: [String: AgentJSONValue] = [:]) -> [String: AgentJSONValue] {
        extra.merging([profileKey: .string("isolated"), hostKey: .string("www.example.com")]) { new, _ in new }
    }

    @Test("独立浏览器的 cookie 不会出现在我的浏览器里")
    func isolatedStoreSharesNothingWithDefault() async throws {
        let isolatedStore = AgentEmbeddedBrowserDataStores.store(for: .isolated)
        #expect(isolatedStore !== WKWebsiteDataStore.default())
        let name = "willdeep-isolation-probe-\(UUID().uuidString.prefix(8))"
        let cookie = try #require(HTTPCookie(properties: [
            .name: name, .value: "1", .domain: "isolation.willdeep.test", .path: "/",
        ]))
        await isolatedStore.httpCookieStore.setCookie(cookie)
        defer { Task { @MainActor in await isolatedStore.httpCookieStore.deleteCookie(cookie) } }
        #expect(await isolatedStore.httpCookieStore.allCookies().contains { $0.name == name })
        #expect(await !WKWebsiteDataStore.default().httpCookieStore.allCookies().contains { $0.name == name })
    }

    @Test("切换配置重建 WebView，状态里能看到，同一会话的新标签页沿用；释放会话后恢复默认")
    func switchingRebuildsAndCarriesToNewTabs() throws {
        let runtimeID = UUID()
        defer { AgentEmbeddedBrowserController.release(for: runtimeID) }
        let controller = AgentEmbeddedBrowserController.controller(for: runtimeID)
        let before = controller.ensureWebView(loadInitialPage: false)
        #expect(controller.profile == .personal)
        #expect(AgentEmbeddedBrowserController.profile(for: runtimeID) == .personal)

        controller.switchProfile(to: .isolated, runtimeID: runtimeID)
        let after = controller.ensureWebView(loadInitialPage: false)
        #expect(after !== before)
        #expect(after.configuration.websiteDataStore !== WKWebsiteDataStore.default())
        #expect(controller.statusPayload()["profile"] as? String == "isolated")
        #expect(AgentEmbeddedBrowserController.profile(for: runtimeID) == .isolated)

        let newTab = AgentEmbeddedBrowserController.controller(for: runtimeID, tabID: UUID())
        #expect(newTab.profile == .isolated)

        controller.switchProfile(to: .isolated, runtimeID: runtimeID)
        #expect(controller.ensureWebView(loadInitialPage: false) === after, "switching to the same profile keeps the web view")

        AgentEmbeddedBrowserController.release(for: runtimeID)
        #expect(AgentEmbeddedBrowserController.profile(for: runtimeID) == .personal)
    }

    /// Regression: the panel's representable holds the same controller before
    /// and after a switch, so SwiftUI skipped `updateNSView` and the rebuilt
    /// web view stayed out of any window — blank panel, `innerHeight == 0`,
    /// and a 0×0 snapshot that failed to encode as PNG.
    @Test("切换配置后面板挂上的是新 WebView，而不是留空")
    func switchingProfileAttachesNewWebViewToPanel() async throws {
        let runtimeID = UUID()
        defer { AgentEmbeddedBrowserController.release(for: runtimeID) }
        let controller = AgentEmbeddedBrowserController.controller(for: runtimeID)
        controller.ensureWebView(loadInitialPage: false)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: AgentEmbeddedBrowserPanel(runtimeID: runtimeID, width: 480))
        window.contentView?.layoutSubtreeIfNeeded()
        let before = controller.ensureWebView(loadInitialPage: false)
        #expect(before.window === window)

        controller.switchProfile(to: .isolated, runtimeID: runtimeID)
        let after = controller.ensureWebView(loadInitialPage: false)
        for _ in 0..<20 where after.window == nil {
            try await Task.sleep(for: .milliseconds(20))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        #expect(after.window === window)
        #expect(after.bounds.height > 0)
        #expect(before.superview == nil)
    }

    @Test("宿主给所有内置浏览器调用写入配置（含 navigate），Chrome 不写")
    func profileIsStamped() {
        let navigate = AgentToolAuthorization.stampingEmbeddedBrowserProfile(
            toolName: "embedded_browser_navigate", arguments: [profileKey: .string("personal")], profile: .isolated
        )
        #expect(navigate[profileKey]?.stringValue() == "isolated")
        #expect(AgentToolAuthorization.stampingEmbeddedBrowserProfile(
            toolName: "chrome_click", arguments: [:], profile: .isolated
        )[profileKey] == nil)
    }

    @Test("独立浏览器里普通操作免确认；上传、有后果的点击、带密钥占位符的调用、我的浏览器照旧要确认")
    func isolatedBrowserApprovalScope() {
        for toolName in ["embedded_browser_navigate", "embedded_browser_click", "embedded_browser_type", "embedded_browser_eval", "embedded_browser_scroll"] {
            #expect(AgentToolAuthorization.isolatedBrowserAllowsWithoutAsking(
                toolName: toolName, arguments: isolated(["javascript": .string("document.body.remove()")])
            ), "\(toolName)")
        }
        #expect(!AgentToolAuthorization.isolatedBrowserAllowsWithoutAsking(
            toolName: "embedded_browser_upload_file", arguments: isolated()
        ))
        #expect(!AgentToolAuthorization.isolatedBrowserAllowsWithoutAsking(
            toolName: "embedded_browser_click", arguments: isolated([labelKey: .string("立即付款")])
        ))
        #expect(!AgentToolAuthorization.isolatedBrowserAllowsWithoutAsking(
            toolName: "embedded_browser_type", arguments: isolated(["text": .string("${secret:api-key}")])
        ))
        var personal = isolated()
        personal[profileKey] = .string("personal")
        #expect(!AgentToolAuthorization.isolatedBrowserAllowsWithoutAsking(toolName: "embedded_browser_click", arguments: personal))
        #expect(!AgentToolAuthorization.isolatedBrowserAllowsWithoutAsking(toolName: "chrome_click", arguments: isolated()))
    }

    @Test("审批链路：独立浏览器的点击在智能模式直接放行，严格模式仍然询问")
    func isolatedApprovalHonorsStrictMode() async {
        let appState = AppState()
        appState.agentAlwaysAllowedCommands = []
        let smart = await appState.autoApprovalSource(
            toolName: "embedded_browser_click", arguments: isolated(["selector": .string("a")]), risk: .write, rootDirectory: nil
        )
        #expect(smart == .staticAllowlist)
        let strict = await appState.autoApprovalSource(
            toolName: "embedded_browser_click", arguments: isolated(["selector": .string("a")]), risk: .write, rootDirectory: nil,
            approvalMode: .requestEveryTime
        )
        #expect(strict == nil)
    }

    @Test("批准后切换过配置的调用在执行前被拒绝")
    func profileDriftIsRefused() {
        #expect(AgentToolAuthorization.embeddedBrowserProfileDriftMessage(arguments: isolated(), currentProfile: .isolated) == nil)
        #expect(AgentToolAuthorization.embeddedBrowserProfileDriftMessage(arguments: isolated(), currentProfile: .personal) != nil)
        #expect(AgentToolAuthorization.embeddedBrowserProfileDriftMessage(arguments: [:], currentProfile: .personal) == nil)
    }
}
