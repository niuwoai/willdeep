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
    static let defaultWindowSize = CGSize(width: 620, height: 360)

    private var version: String {
        bundleString("CFBundleShortVersionString")
    }

    private var build: String {
        bundleString(kCFBundleVersionKey as String)
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? L10n.About.unknownValue
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 18) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 116, height: 116)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 10)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(L10n.About.appName)
                                .font(.title2.weight(.semibold))
                            Text(L10n.About.versionBadge(version))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 12) {
                            Link(destination: URL(string: "https://willdeep.com")!) {
                                Label(L10n.About.website, systemImage: "link")
                            }
                            .buttonStyle(.link)

                            Button {
                                copyVersionInfo()
                            } label: {
                                Label(L10n.About.copyVersionInfo, systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.link)
                        }
                        .font(.subheadline.weight(.medium))
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.About.versionDetails)
                        .font(.headline)

                    VStack(spacing: 0) {
                        AboutFactRow(title: L10n.About.versionLabel, value: version)
                        Divider()
                        AboutFactRow(title: L10n.About.buildLabel, value: build)
                        Divider()
                        AboutFactRow(title: L10n.About.bundleIDLabel, value: bundleIdentifier)
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }
            }
            .padding(22)
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

    private func copyVersionInfo() {
        let lines = [
            "\(L10n.About.appName) \(version)",
            "\(L10n.About.buildLabel): \(build)",
            "\(L10n.About.bundleIDLabel): \(bundleIdentifier)"
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

private struct AboutFactRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
