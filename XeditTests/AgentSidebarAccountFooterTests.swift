import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WillDeep

struct AgentSidebarAccountFooterTests {
    @Test("account footer follows the compact Codex reference metrics")
    func accountFooterMetrics() {
        #expect(AgentSidebarAccountMetrics.accountRowHeight == 32)
        #expect(AgentSidebarAccountMetrics.accountCornerRadius == 8)
        #expect(AgentSidebarAccountMetrics.avatarSize == 20)
        #expect(AgentSidebarAccountMetrics.helpButtonSize == 28)
        #expect(AgentSidebarAccountMetrics.menuWidth == 344)
        #expect(AgentSidebarAccountMetrics.menuHeaderHeight == 34)
        #expect(AgentSidebarAccountMetrics.menuRowHeight == 34)
        #expect(AgentSidebarAccountMetrics.accountBaseFillOpacity == 0.68)
        #expect(AgentSidebarAccountMetrics.accountSkinTintOpacity == 0.055)
        #expect(AgentSidebarAccountMetrics.accountDepthOpacity == 0.035)
    }

    @Test("help link uses a localized some.im WillDeep page")
    func helpLinkUsesLocalizedProductPage() {
        let chinese = AgentSidebarAccountLinks.helpURL(preferredLanguages: ["zh-Hans-CN"])
        let english = AgentSidebarAccountLinks.helpURL(preferredLanguages: ["en-US"])

        #expect(chinese.scheme == "https")
        #expect(chinese.host == "some.im")
        #expect(chinese.path == "/zh/products/willdeep")
        #expect(english.path == "/en/products/willdeep")
    }

    @Test("cached account is not presented as logged in without a shared credential")
    @MainActor
    func cachedAccountRequiresAuthenticatedSession() {
        let cached = SomeIMAccount(
            email: "cached@example.invalid",
            nickname: "Cached",
            avatarURL: nil,
            tenantID: nil,
            balanceUSD: "1.00",
            credits: "100000",
            creditsPerUSD: 100000,
            defaultModel: SomeIMIntegrationSettings.defaultTextModel,
            lastUpdatedAt: .distantPast
        )

        #expect(SomeIMIntegrationStore.authenticatedAccount(cachedAccount: cached, apiKey: "") == nil)
        #expect(
            SomeIMIntegrationStore.authenticatedAccount(
                cachedAccount: cached,
                apiKey: " shared-session-key "
            ) == cached
        )

        let signedOut = SomeIMIntegrationStore.authenticationSnapshot(
            cachedAccount: cached,
            apiKey: "  "
        )
        #expect(!signedOut.isAuthenticated)
        #expect(signedOut.apiKey.isEmpty)
        #expect(signedOut.account == nil)

        let signedIn = SomeIMIntegrationStore.authenticationSnapshot(
            cachedAccount: cached,
            apiKey: " shared-session-key "
        )
        #expect(signedIn.isAuthenticated)
        #expect(signedIn.apiKey == "shared-session-key")
        #expect(signedIn.account == cached)
    }

    @Test("account popover actions stay out of the keyboard focus chain")
    func accountPopoverActionsAreNotFocusable() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Xedit", isDirectory: true)
            .appendingPathComponent("AgentSidebarAccountFooter.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let menuRow = try #require(source.range(of: "private struct AgentSidebarAccountMenuRow"))
        let trailingSource = source[menuRow.lowerBound...]
        let buttonStyle = try #require(trailingSource.range(of: ".buttonStyle(.plain)"))
        let focusPolicy = try #require(trailingSource.range(of: ".focusable(false)"))

        #expect(focusPolicy.lowerBound > buttonStyle.lowerBound)
        #expect(trailingSource.distance(from: buttonStyle.lowerBound, to: focusPolicy.lowerBound) < 80)
    }

    @Test("account footer and popover header share the cached remote avatar renderer")
    func accountChromeSharesAvatarRenderer() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Xedit", isDirectory: true)
            .appendingPathComponent("AgentSidebarAccountFooter.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.components(separatedBy: "AgentSidebarAccountAvatar(").count - 1 == 2)
        #expect(source.contains("CachedAvatarImage(url: url)"))
    }

    @Test("render account menu and footer for design QA")
    @MainActor
    func renderAccountChromeForDesignQA() throws {
        let outputPath = ProcessInfo.processInfo.environment["WILLDEEP_ACCOUNT_FOOTER_QA_OUTPUT"]
            ?? "/tmp/Xedit-account-footer-design-qa.png"
        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.ricePaper.id
        let appState = AppState(editorSettings: settings)
        let account = SomeIMAccount(
            email: "xiaoxi@example.invalid",
            nickname: "小溪 滚",
            avatarURL: nil,
            tenantID: nil,
            balanceUSD: "12.00",
            credits: "1880000",
            creditsPerUSD: 1_000_000,
            defaultModel: "someim-auto-flash",
            lastUpdatedAt: Date(timeIntervalSince1970: 1_784_070_000)
        )

        let size = NSSize(width: 364, height: 232)
        let root = VStack(spacing: 10) {
            AgentSidebarAccountMenu(
                account: account,
                isRefreshingAccount: false,
                onOpenAccount: {},
                onToggleDesktopPet: {},
                onOpenSettings: {},
                onLogOut: {}
            )
            .environmentObject(appState)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
            )

            AgentSidebarAccountFooter(
                account: account,
                isAuthenticated: true,
                isRefreshingAccount: false,
                accountStatus: "",
                onOpenAccount: {},
                onOpenLogin: {},
                onRefreshAccount: {},
                onOpenSettings: {},
                onLogOut: {},
                onOpenHelp: {}
            )
            .environmentObject(appState)
        }
        .padding(10)
        .frame(width: size.width, height: size.height, alignment: .bottom)
        .background(appState.editorSettings.interfaceSkin.sidebarBackground)
        .preferredColorScheme(.light)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}
