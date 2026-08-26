import AppKit
import SwiftUI

@MainActor
enum AboutWindowOpener {
    private static var windowController: NSWindowController?

    static func open() {
        if let window = windowController?.window {
            window.setContentSize(AboutView.defaultWindowSize)
            centerAndClearFocus(window)
            window.makeKeyAndOrderFront(nil)
            activateApp()
            return
        }

        let hostingController = NSHostingController(rootView: AboutView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.About.windowTitle
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.initialFirstResponder = nil
        window.setContentSize(AboutView.defaultWindowSize)

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        centerAndClearFocus(window)
        activateApp()
    }

    private static func centerAndClearFocus(_ window: NSWindow) {
        window.center()
        window.makeFirstResponder(nil)
        DispatchQueue.main.async {
            window.center()
            window.makeFirstResponder(nil)
        }
    }

    private static func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct AboutView: View {
    static let defaultWindowSize = CGSize(width: 700, height: 500)

    private var version: String {
        bundleString("CFBundleShortVersionString")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 18) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .accessibilityLabel(L10n.About.appName)

                    DesktopPetAnimatedSceneView(
                        appearance: .bearGirl,
                        mood: .idle,
                        appIsActive: NSApp.isActive,
                        isAnimating: true,
                        schedulesAmbientBursts: false
                    )
                    .frame(width: 128, height: 128)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(L10n.About.appName)
                                .font(.title2.weight(.semibold))
                            Text(L10n.About.versionBadge(version))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Text(L10n.About.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Link(destination: URL(string: "https://83d.me")!) {
                            Label(L10n.About.authorHomepage, systemImage: "link")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.link)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.About.otherApps)
                        .font(.headline)
                    Text(L10n.About.otherAppsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 156), spacing: 10)], spacing: 10) {
                        ForEach(AboutRecommendedApp.allCases) { app in
                            AboutRecommendedAppCard(app: app)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: Self.defaultWindowSize.width, height: Self.defaultWindowSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable(false)
    }

    private func bundleString(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return L10n.About.unknownValue
        }
        return value
    }

}

private enum AboutRecommendedApp: String, CaseIterable, Identifiable {
    case qTerm
    case gitWise
    case timeBill
    case xomo
    case bearCleaner
    case qPic
    case qMarkView
    case qEcho
    case qMailMate
    case qNote

    var id: String { rawValue }

    var name: String {
        switch self {
        case .qTerm: return L10n.About.App.qTermName
        case .gitWise: return L10n.About.App.gitWiseName
        case .timeBill: return L10n.About.App.timeBillName
        case .xomo: return L10n.About.App.xomoName
        case .bearCleaner: return L10n.About.App.bearCleanerName
        case .qPic: return L10n.About.App.qPicName
        case .qMarkView: return L10n.About.App.qMarkViewName
        case .qEcho: return L10n.About.App.qEchoName
        case .qMailMate: return L10n.About.App.qMailMateName
        case .qNote: return L10n.About.App.qNoteName
        }
    }

    var summary: String {
        switch self {
        case .qTerm: return L10n.About.App.qTermSummary
        case .gitWise: return L10n.About.App.gitWiseSummary
        case .timeBill: return L10n.About.App.timeBillSummary
        case .xomo: return L10n.About.App.xomoSummary
        case .bearCleaner: return L10n.About.App.bearCleanerSummary
        case .qPic: return L10n.About.App.qPicSummary
        case .qMarkView: return L10n.About.App.qMarkViewSummary
        case .qEcho: return L10n.About.App.qEchoSummary
        case .qMailMate: return L10n.About.App.qMailMateSummary
        case .qNote: return L10n.About.App.qNoteSummary
        }
    }

    var iconAssetName: String {
        switch self {
        case .qTerm: return "AboutAppQTermIcon"
        case .gitWise: return "AboutAppGitWiseIcon"
        case .timeBill: return "AboutAppTimeBillIcon"
        case .xomo: return "AboutAppXomoIcon"
        case .bearCleaner: return "AboutAppBearCleanerIcon"
        case .qPic: return "AboutAppQPicIcon"
        case .qMarkView: return "AboutAppQMarkViewIcon"
        case .qEcho: return "AboutAppQEchoIcon"
        case .qMailMate: return "AboutAppQMailMateIcon"
        case .qNote: return "AboutAppQNoteIcon"
        }
    }

    var accent: Color {
        switch self {
        case .qTerm: return .indigo
        case .gitWise: return .mint
        case .timeBill: return .orange
        case .xomo: return .purple
        case .bearCleaner: return .brown
        case .qPic: return .pink
        case .qMarkView: return .blue
        case .qEcho: return .purple
        case .qMailMate: return .teal
        case .qNote: return .green
        }
    }

    var productURL: URL {
        switch self {
        case .qTerm: return URL(string: "https://83d.me/products/museterm")!
        case .gitWise: return URL(string: "https://83d.me/zh/products/gitwise")!
        case .timeBill: return URL(string: "https://83d.me/products/timebill")!
        case .xomo: return URL(string: "https://83d.me/zh/products/xomo")!
        case .bearCleaner: return URL(string: "https://83d.me/zh/products/bearcleaner")!
        case .qPic: return URL(string: "https://83d.me/products/qpic")!
        case .qMarkView: return URL(string: "https://83d.me/products/qmarkview")!
        case .qEcho: return URL(string: "https://83d.me/products/qecho")!
        case .qMailMate: return URL(string: "https://83d.me/products/qmailmate")!
        case .qNote: return URL(string: "https://83d.me/products/qnote")!
        }
    }
}

private struct AboutRecommendedAppCard: View {
    let app: AboutRecommendedApp

    var body: some View {
        Link(destination: app.productURL) {
            HStack(spacing: 10) {
                Image(app.iconAssetName)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(app.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(app.accent)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
