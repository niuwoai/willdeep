//
//  HelpBookWindow.swift
//  WillDeep
//
//  「帮助 > WillDeep 帮助」自己开窗，不再把用户丢给系统帮助查看器。
//
//  macOS 26 起系统帮助由「提示」(Tips.app) 接管，第三方 Help Book 经常
//  显示成「所选内容当前不可用」——它转头去 Apple 的在线帮助库找内容，
//  找不到就报错，用户看到的是一张与 WillDeep 无关的错误页。帮助内容明明
//  就在 App 包里，没有理由依赖系统组件和网络。
//
//  这里直接把 Help Book 里的 HTML 用 WKWebView 显示。Help Book 本身保留：
//  旧系统上系统查看器仍能用，两边读的是同一份文件。
//

import AppKit
import SwiftUI
import WebKit

/// 在 App 包内定位 Help Book 的入口页面。纯函数，便于测试。
nonisolated enum HelpBookLocator {
    static let bookFolder = "WillDeep.help"
    static let accessFile = "index.html"

    /// 按用户偏好语言挑一个 `.lproj`，挑不中就回落到英文，再不行取任意一个。
    /// 返回 nil 表示这个包里根本没有可显示的帮助页面。
    static func indexURL(
        resourceURL: URL?,
        preferredLanguages: [String] = Locale.preferredLanguages,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let resourceURL else { return nil }
        let root = resourceURL
            .appendingPathComponent(bookFolder)
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return nil }

        let lprojs = contents.filter { $0.pathExtension == "lproj" }
        guard !lprojs.isEmpty else { return nil }

        func page(in lproj: URL) -> URL? {
            let candidate = lproj.appendingPathComponent(accessFile)
            return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
        }

        for language in preferredLanguages {
            let normalized = language.replacingOccurrences(of: "_", with: "-").lowercased()
            // "zh-Hans-CN" 要能选中 "zh-Hans.lproj"，所以按前缀逐段退让匹配。
            var components = normalized.split(separator: "-").map(String.init)
            while !components.isEmpty {
                let tag = components.joined(separator: "-")
                if let match = lprojs.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == tag }),
                   let url = page(in: match) {
                    return url
                }
                components.removeLast()
            }
        }

        if let english = lprojs.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == "en" }),
           let url = page(in: english) {
            return url
        }
        return lprojs.compactMap(page).first
    }
}

@MainActor
enum HelpWindowOpener {
    private static var windowController: NSWindowController?

    static func open() {
        if let window = windowController?.window {
            window.makeKeyAndOrderFront(nil)
            activateApp()
            return
        }

        let hostingController = NSHostingController(rootView: HelpBookView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.HelpMenu.windowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: 720))
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        activateApp()
    }

    private static func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct HelpBookView: View {
    var body: some View {
        if let url = HelpBookLocator.indexURL(resourceURL: Bundle.main.resourceURL) {
            HelpBookWebView(indexURL: url)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(L10n.HelpMenu.unavailableTitle)
                    .font(.system(size: 15, weight: .semibold))
                Text(L10n.HelpMenu.unavailableDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
    }
}

private struct HelpBookWebView: NSViewRepresentable {
    let indexURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != indexURL else { return }
        context.coordinator.loadedURL = indexURL
        // 只放行 lproj 目录，样式表和同目录锚点够用，也不给页面翻出包外的机会。
        webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?

        /// 页面里的外部链接（例如「联系支持」）交给默认浏览器，不在帮助窗口里导航走。
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.isFileURL || url.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType == .linkActivated,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
