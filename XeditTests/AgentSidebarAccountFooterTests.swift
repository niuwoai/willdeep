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
