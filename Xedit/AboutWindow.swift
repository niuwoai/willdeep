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

enum AboutMenuInstaller {
    static func install() {
        DispatchQueue.main.async {
            guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
                  let aboutItem = findAboutItem(in: appMenu) else {
                return
            }

            aboutItem.title = L10n.About.menuItem
            aboutItem.target = AboutMenuHandler.shared
            aboutItem.action = #selector(AboutMenuHandler.openAboutWindow(_:))
        }
    }

    private static func findAboutItem(in menu: NSMenu) -> NSMenuItem? {
        let standardAboutAction = #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        if let item = menu.items.first(where: { $0.action == standardAboutAction }) {
            return item
        }

        return menu.items.first { item in
            item.title.hasPrefix("About ") || item.title.hasPrefix("关于")
        }
    }
}

private final class AboutMenuHandler: NSObject {
    static let shared = AboutMenuHandler()

    @objc func openAboutWindow(_ sender: Any?) {
        Task { @MainActor in
            AboutWindowOpener.open()
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
                    Image("DesktopPetPenguin")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 128, height: 128)

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
    case timeBill
    case qPic
    case qMarkView
    case qEcho
    case qMailMate
    case qNote

    var id: String { rawValue }

    var name: String {
        switch self {
        case .qTerm: return L10n.About.App.qTermName
        case .timeBill: return L10n.About.App.timeBillName
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
        case .timeBill: return L10n.About.App.timeBillSummary
        case .qPic: return L10n.About.App.qPicSummary
        case .qMarkView: return L10n.About.App.qMarkViewSummary
        case .qEcho: return L10n.About.App.qEchoSummary
        case .qMailMate: return L10n.About.App.qMailMateSummary
        case .qNote: return L10n.About.App.qNoteSummary
        }
    }

    var systemImage: String {
        switch self {
        case .qTerm: return "terminal.fill"
        case .timeBill: return "clock.badge.checkmark.fill"
        case .qPic: return "photo.stack.fill"
        case .qMarkView: return "doc.richtext.fill"
        case .qEcho: return "waveform.badge.mic"
        case .qMailMate: return "envelope.fill"
        case .qNote: return "note.text"
        }
    }

    var accent: Color {
        switch self {
        case .qTerm: return .indigo
        case .timeBill: return .orange
        case .qPic: return .pink
        case .qMarkView: return .blue
        case .qEcho: return .purple
        case .qMailMate: return .teal
        case .qNote: return .green
        }
    }

    var productURL: URL {
        URL(string: "https://83d.me/products/\(productSlug)")!
    }

    private var productSlug: String {
        switch self {
        case .qTerm: return "museterm"
        case .timeBill: return "timebill"
        case .qPic: return "qpic"
        case .qMarkView: return "qmarkview"
        case .qEcho: return "qecho"
        case .qMailMate: return "qmailmate"
        case .qNote: return "qnote"
        }
    }
}

private struct AboutRecommendedAppCard: View {
    let app: AboutRecommendedApp

    var body: some View {
        Link(destination: app.productURL) {
            HStack(spacing: 10) {
                Image(systemName: app.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(app.accent.gradient)
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
