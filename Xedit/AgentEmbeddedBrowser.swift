//
//  AgentEmbeddedBrowser.swift
//  WillDeep
//
//  In-app browser workbench for the Agent side panel. It intentionally
//  controls only the visible WKWebView mounted in the right rail; the
//  Chrome bridge remains the path for the user's real Chrome profile.
//

import AppKit
import Combine
import Foundation
import SwiftUI
import WebKit

@MainActor
final class AgentEmbeddedBrowserController: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = AgentEmbeddedBrowserController()

    @Published var address: String = "https://example.com"
    @Published private(set) var currentURL: String = ""
    @Published private(set) var title: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastScreenshotPath: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    private weak var webView: WKWebView?

    private override init() {
        super.init()
    }

    func bind(_ webView: WKWebView) {
        self.webView = webView
        webView.navigationDelegate = self
        updateState(from: webView)
        if webView.url == nil, let url = normalizedURL(address) {
            webView.load(URLRequest(url: url))
        }
    }

    func unbind(_ webView: WKWebView) {
        if self.webView === webView {
            self.webView = nil
        }
    }

    var isReady: Bool {
        webView != nil
    }

    func navigate(to rawValue: String) throws {
        guard let webView else {
            throw AgentToolError.invalidArgument("Open the Embedded Browser side panel before using embedded browser tools.")
        }
        guard let url = normalizedURL(rawValue) else {
            throw AgentToolError.invalidArgument("Invalid browser URL: \(rawValue)")
        }
        address = rawValue
        lastError = nil
        webView.load(URLRequest(url: url))
        updateState(from: webView)
    }

    func reload() {
        webView?.reload()
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func statusPayload() -> [String: Any] {
        [
            "ready": isReady,
            "url": currentURL,
            "title": title,
            "is_loading": isLoading,
            "can_go_back": canGoBack,
            "can_go_forward": canGoForward,
            "last_error": lastError ?? NSNull(),
            "last_screenshot_path": lastScreenshotPath ?? NSNull(),
        ]
    }

    func readPage(maxChars: Int) async throws -> [String: Any] {
        let script = """
        (() => {
          const text = (document.body ? document.body.innerText : document.documentElement.innerText || '').slice(0, \(maxChars));
          const links = Array.from(document.querySelectorAll('a[href]')).slice(0, 50).map((a) => ({
            text: (a.innerText || a.getAttribute('aria-label') || '').trim().slice(0, 120),
            href: a.href
          }));
          const forms = Array.from(document.querySelectorAll('input, textarea, select, button')).slice(0, 80).map((el) => ({
            tag: el.tagName.toLowerCase(),
            type: el.getAttribute('type') || '',
            name: el.getAttribute('name') || '',
            id: el.id || '',
            placeholder: el.getAttribute('placeholder') || '',
            text: (el.innerText || el.value || '').slice(0, 80)
          }));
          return { title: document.title || '', url: location.href, text, links, forms };
        })()
        """
        return try await evaluateObject(script)
    }

    func click(selector: String) async throws -> [String: Any] {
        let selectorLiteral = try Self.javaScriptLiteral(selector)
        let script = """
        (() => {
          const selector = \(selectorLiteral);
          const element = document.querySelector(selector);
          if (!element) return { ok: false, error: `No element matched selector: ${selector}` };
          element.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
          element.click();
          return {
            ok: true,
            selector,
            tag: element.tagName.toLowerCase(),
            id: element.id || '',
            text: (element.innerText || element.value || element.getAttribute('aria-label') || '').trim().slice(0, 160)
          };
        })()
        """
        return try await evaluateObject(script)
    }

    func typeText(selector: String, text: String) async throws -> [String: Any] {
        let selectorLiteral = try Self.javaScriptLiteral(selector)
        let textLiteral = try Self.javaScriptLiteral(text)
        let script = """
        (() => {
          const selector = \(selectorLiteral);
          const text = \(textLiteral);
          const element = document.querySelector(selector);
          if (!element) return { ok: false, error: `No element matched selector: ${selector}` };
          element.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
          element.focus();
          if ('value' in element) {
            element.value = text;
          } else if (element.isContentEditable) {
            element.textContent = text;
          } else {
            return { ok: false, error: 'Matched element is not text-editable.' };
          }
          element.dispatchEvent(new Event('input', { bubbles: true }));
          element.dispatchEvent(new Event('change', { bubbles: true }));
          return {
            ok: true,
            selector,
            tag: element.tagName.toLowerCase(),
            id: element.id || '',
            length: text.length
          };
        })()
        """
        return try await evaluateObject(script)
    }

    func captureScreenshot() async throws -> String {
        guard let webView else {
            throw AgentToolError.invalidArgument("Open the Embedded Browser side panel before taking screenshots.")
        }
        let image: NSImage = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, any Error>) in
            webView.takeSnapshot(with: nil) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: AgentToolError.invalidArgument("WKWebView did not return a screenshot."))
                }
            }
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
            throw AgentToolError.invalidArgument("Could not encode embedded browser screenshot as PNG.")
        }
        let directory = try screenshotDirectory()
        let path = directory.appendingPathComponent("embedded-browser-\(Self.timestamp()).png")
        try png.write(to: path, options: Data.WritingOptions.atomic)
        lastScreenshotPath = path.path
        return path.path
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        lastError = nil
        updateState(from: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        updateState(from: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        lastError = error.localizedDescription
        updateState(from: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        lastError = error.localizedDescription
        updateState(from: webView)
    }

    private func evaluateObject(_ script: String) async throws -> [String: Any] {
        guard let webView else {
            throw AgentToolError.invalidArgument("Open the Embedded Browser side panel before using embedded browser tools.")
        }
        let value: Any = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, any Error>) in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value ?? NSNull())
                }
            }
        }
        guard let object = value as? [String: Any] else {
            throw AgentToolError.invalidArgument("Embedded browser script returned an invalid response.")
        }
        return object
    }

    private func updateState(from webView: WKWebView) {
        currentURL = webView.url?.absoluteString ?? currentURL
        if !currentURL.isEmpty {
            address = currentURL
        }
        title = webView.title ?? title
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    private func normalizedURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }

    private func screenshotDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base
            .appendingPathComponent("WillDeep", isDirectory: true)
            .appendingPathComponent("embedded-browser-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func javaScriptLiteral(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value], options: [])
        guard let array = String(data: data, encoding: .utf8),
              array.count >= 2 else {
            throw AgentToolError.invalidArgument("Could not encode JavaScript string literal.")
        }
        return String(array.dropFirst().dropLast())
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }
}

enum AgentEmbeddedBrowserTools {
    static func status(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let payload = AgentEmbeddedBrowserController.shared.statusPayload()
        return AgentToolResult(summary: "Embedded browser status", payload: prettyJSONString(payload))
    }

    static func navigate(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let url = try requiredString("url", arguments: arguments)
        try AgentEmbeddedBrowserController.shared.navigate(to: url)
        let payload = AgentEmbeddedBrowserController.shared.statusPayload()
        return AgentToolResult(summary: "Navigated embedded browser", payload: prettyJSONString(payload))
    }

    static func readPage(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let maxChars = arguments["max_chars"]?.intValue().map { max(1_000, min($0, 100_000)) } ?? 20_000
        let payload = try await AgentEmbeddedBrowserController.shared.readPage(maxChars: maxChars)
        return AgentToolResult(summary: "Read embedded browser page", payload: prettyJSONString(payload))
    }

    static func click(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let selector = try requiredString("selector", arguments: arguments)
        let payload = try await AgentEmbeddedBrowserController.shared.click(selector: selector)
        return AgentToolResult(summary: "Clicked embedded browser element", payload: prettyJSONString(payload))
    }

    static func typeText(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let selector = try requiredString("selector", arguments: arguments)
        let text = try requiredString("text", arguments: arguments)
        let payload = try await AgentEmbeddedBrowserController.shared.typeText(selector: selector, text: text)
        return AgentToolResult(summary: "Typed into embedded browser element", payload: prettyJSONString(payload))
    }

    static func captureScreenshot(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let path = try await AgentEmbeddedBrowserController.shared.captureScreenshot()
        return AgentToolResult(
            summary: "Captured embedded browser screenshot",
            payload: prettyJSONString(["path": path])
        )
    }

    private static func prettyJSONString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return string
    }

    private static func requiredString(_ name: String, arguments: [String: AgentJSONValue]) throws -> String {
        guard let value = arguments[name]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            throw AgentToolError.missingArgument(name)
        }
        return value
    }
}

struct AgentEmbeddedBrowserPanel: View {
    @ObservedObject private var controller = AgentEmbeddedBrowserController.shared
    @State private var screenshotError: String?
    var width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            AgentEmbeddedBrowserWebView(controller: controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: width)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button {
                controller.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!controller.canGoBack)
            .help(L10n.AgentEmbeddedBrowser.back)

            Button {
                controller.goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!controller.canGoForward)
            .help(L10n.AgentEmbeddedBrowser.forward)

            Button {
                controller.reload()
            } label: {
                Image(systemName: controller.isLoading ? "xmark" : "arrow.clockwise")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(L10n.AgentEmbeddedBrowser.reload)

            TextField(L10n.AgentEmbeddedBrowser.addressPlaceholder, text: $controller.address)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit {
                    loadAddress()
                }

            Button {
                loadAddress()
            } label: {
                Image(systemName: "arrow.forward")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(L10n.AgentEmbeddedBrowser.go)

            Button {
                captureScreenshot()
            } label: {
                Image(systemName: "camera")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(L10n.AgentEmbeddedBrowser.capture)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(controller.title.isEmpty ? L10n.AgentEmbeddedBrowser.untitled : controller.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(footerDetail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footerDetail: String {
        if let screenshotError {
            return screenshotError
        }
        if let path = controller.lastScreenshotPath {
            return L10n.AgentEmbeddedBrowser.lastScreenshot(path)
        }
        if let lastError = controller.lastError {
            return lastError
        }
        return controller.currentURL.isEmpty ? L10n.AgentEmbeddedBrowser.ready : controller.currentURL
    }

    private func loadAddress() {
        screenshotError = nil
        do {
            try controller.navigate(to: controller.address)
        } catch {
            screenshotError = error.localizedDescription
        }
    }

    private func captureScreenshot() {
        screenshotError = nil
        Task {
            do {
                _ = try await controller.captureScreenshot()
            } catch {
                screenshotError = error.localizedDescription
            }
        }
    }
}

private struct AgentEmbeddedBrowserWebView: NSViewRepresentable {
    let controller: AgentEmbeddedBrowserController

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        let webView = WKWebView(frame: .zero, configuration: configuration)
        controller.bind(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        controller.bind(webView)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
        AgentEmbeddedBrowserController.shared.unbind(nsView)
    }
}
