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
final class AgentEmbeddedBrowserController: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = AgentEmbeddedBrowserController()
    static let diagnosticsMessageHandlerName = "willdeepBrowserDiagnostics"

    @Published var address: String = "https://example.com"
    @Published private(set) var currentURL: String = ""
    @Published private(set) var title: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastScreenshotPath: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    private weak var webView: WKWebView?
    private var consoleEvents: [[String: Any]] = []
    private let consoleEventLimit = 300

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

    func snapshot(maxElements: Int) async throws -> [String: Any] {
        let limit = max(10, min(maxElements, 300))
        let script = """
        (() => {
          const selectorFor = (el) => {
            if (!el || !el.tagName) return '';
            if (el.id) return `#${CSS.escape(el.id)}`;
            const testId = el.getAttribute('data-testid') || el.getAttribute('data-test') || el.getAttribute('aria-label') || el.getAttribute('name');
            if (testId) {
              const attr = el.getAttribute('data-testid') ? 'data-testid' : (el.getAttribute('data-test') ? 'data-test' : (el.getAttribute('aria-label') ? 'aria-label' : 'name'));
              return `${el.tagName.toLowerCase()}[${attr}="${CSS.escape(testId)}"]`;
            }
            const parts = [];
            let node = el;
            while (node && node.nodeType === 1 && parts.length < 5) {
              let part = node.tagName.toLowerCase();
              if (node.id) {
                part += `#${CSS.escape(node.id)}`;
                parts.unshift(part);
                break;
              }
              const parent = node.parentElement;
              if (parent) {
                const siblings = Array.from(parent.children).filter((child) => child.tagName === node.tagName);
                if (siblings.length > 1) part += `:nth-of-type(${siblings.indexOf(node) + 1})`;
              }
              parts.unshift(part);
              node = parent;
            }
            return parts.join(' > ');
          };
          const visible = (el) => {
            const style = getComputedStyle(el);
            const rect = el.getBoundingClientRect();
            return style.visibility !== 'hidden' && style.display !== 'none' && rect.width > 0 && rect.height > 0;
          };
          const candidates = Array.from(document.querySelectorAll('a[href], button, input, textarea, select, [contenteditable="true"], [role="button"], [role="link"], [onclick], summary'));
          const elements = candidates.filter(visible).slice(0, \(limit)).map((el, index) => {
            const ref = `wd${index + 1}`;
            el.setAttribute('data-wd-browser-ref', ref);
            const rect = el.getBoundingClientRect();
            const editable = ['input', 'textarea', 'select'].includes(el.tagName.toLowerCase()) || el.isContentEditable;
            const clickable = !editable || el.tagName.toLowerCase() === 'select' || el.tagName.toLowerCase() === 'button';
            return {
              ref,
              selector: `[data-wd-browser-ref="${ref}"]`,
              stable_selector: selectorFor(el),
              tag: el.tagName.toLowerCase(),
              role: el.getAttribute('role') || '',
              type: el.getAttribute('type') || '',
              name: el.getAttribute('name') || '',
              id: el.id || '',
              text: (el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('placeholder') || '').trim().slice(0, 160),
              href: el.href || '',
              editable,
              clickable,
              bounds: { x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height) }
            };
          });
          return { title: document.title || '', url: location.href, count: elements.length, elements };
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

    func waitFor(condition: String, value: String, timeoutMS: Int) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(TimeInterval(max(500, min(timeoutMS, 30_000))) / 1_000)
        var lastPayload: [String: Any] = [:]
        while Date() < deadline {
            let payload = try await waitConditionPayload(condition: condition, value: value)
            lastPayload = payload
            if payload["matched"] as? Bool == true {
                return payload
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return [
            "matched": false,
            "condition": condition,
            "value": value,
            "timeout_ms": timeoutMS,
            "last": lastPayload,
        ]
    }

    func evaluate(source: String, maxChars: Int) async throws -> [String: Any] {
        let sourceLiteral = try Self.javaScriptLiteral(source)
        let script = """
        (async () => {
          const source = \(sourceLiteral);
          let result = await (new Function(`return (async () => {\\n${source}\\n})()`))();
          const type = result === null ? 'null' : Array.isArray(result) ? 'array' : typeof result;
          let value;
          try {
            value = type === 'undefined' ? 'undefined' : JSON.stringify(result);
          } catch (error) {
            value = String(result);
          }
          if (value && value.length > \(maxChars)) value = value.slice(0, \(maxChars)) + '\\n[truncated]';
          return { ok: true, type, value };
        })().catch((error) => ({ ok: false, error: String(error && error.stack ? error.stack : error) }))
        """
        return try await evaluateObject(script)
    }

    func consolePayload(maxEntries: Int, levels: [String]) -> [String: Any] {
        let allowedLevels = Set(levels.map { $0.lowercased() }.filter { !$0.isEmpty })
        var events = consoleEvents
        if !allowedLevels.isEmpty {
            events = events.filter { event in
                guard let level = (event["level"] as? String)?.lowercased() else { return false }
                return allowedLevels.contains(level)
            }
        }
        events = Array(events.suffix(max(1, min(maxEntries, consoleEventLimit))))
        return [
            "url": currentURL,
            "title": title,
            "count": events.count,
            "events": events,
        ]
    }

    func networkPayload(maxEntries: Int, includeDataURLs: Bool) async throws -> [String: Any] {
        let script = """
        (() => {
          const includeDataURLs = \(includeDataURLs ? "true" : "false");
          const round = (value) => Number.isFinite(value) ? Math.round(value * 100) / 100 : 0;
          const entries = performance.getEntriesByType('resource')
            .filter((entry) => includeDataURLs || !String(entry.name || '').startsWith('data:'))
            .slice(-\(max(1, min(maxEntries, 500))))
            .map((entry) => {
              const durationMs = round(entry.duration || 0);
              const transferBytes = Number(entry.transferSize || 0);
              const encodedBytes = Number(entry.encodedBodySize || 0);
              const decodedBytes = Number(entry.decodedBodySize || 0);
              const bytes = transferBytes || encodedBytes || decodedBytes || 0;
              const bytesPerSecond = durationMs > 0 && bytes > 0 ? Math.round(bytes / (durationMs / 1000)) : 0;
              return {
                name: entry.name || '',
                initiator_type: entry.initiatorType || '',
                next_hop_protocol: entry.nextHopProtocol || '',
                render_blocking_status: entry.renderBlockingStatus || '',
                response_status: entry.responseStatus || 0,
                start_time_ms: round(entry.startTime || 0),
                duration_ms: durationMs,
                transfer_size_bytes: transferBytes,
                encoded_body_size_bytes: encodedBytes,
                decoded_body_size_bytes: decodedBytes,
                estimated_bytes_per_second: bytesPerSecond,
                domain_lookup_ms: round((entry.domainLookupEnd || 0) - (entry.domainLookupStart || 0)),
                connect_ms: round((entry.connectEnd || 0) - (entry.connectStart || 0)),
                request_to_response_ms: round((entry.responseStart || 0) - (entry.requestStart || 0)),
                download_ms: round((entry.responseEnd || 0) - (entry.responseStart || 0))
              };
            });
          const totals = entries.reduce((acc, entry) => {
            acc.transfer_size_bytes += entry.transfer_size_bytes || 0;
            acc.encoded_body_size_bytes += entry.encoded_body_size_bytes || 0;
            acc.decoded_body_size_bytes += entry.decoded_body_size_bytes || 0;
            acc.duration_ms += entry.duration_ms || 0;
            return acc;
          }, { transfer_size_bytes: 0, encoded_body_size_bytes: 0, decoded_body_size_bytes: 0, duration_ms: 0 });
          const navigationEntry = performance.getEntriesByType('navigation').slice(-1)[0];
          const navigation = navigationEntry ? {
            type: navigationEntry.type || '',
            redirect_count: navigationEntry.redirectCount || 0,
            duration_ms: round(navigationEntry.duration || 0),
            dom_content_loaded_ms: round((navigationEntry.domContentLoadedEventEnd || 0) - (navigationEntry.startTime || 0)),
            load_event_ms: round((navigationEntry.loadEventEnd || 0) - (navigationEntry.startTime || 0)),
            transfer_size_bytes: Number(navigationEntry.transferSize || 0),
            encoded_body_size_bytes: Number(navigationEntry.encodedBodySize || 0),
            decoded_body_size_bytes: Number(navigationEntry.decodedBodySize || 0)
          } : null;
          const slowest = entries.slice().sort((a, b) => b.duration_ms - a.duration_ms).slice(0, 10);
          const largest = entries.slice().sort((a, b) => (b.transfer_size_bytes || b.encoded_body_size_bytes || b.decoded_body_size_bytes) - (a.transfer_size_bytes || a.encoded_body_size_bytes || a.decoded_body_size_bytes)).slice(0, 10);
          return {
            url: location.href,
            title: document.title || '',
            navigation,
            count: entries.length,
            totals,
            slowest,
            largest,
            entries
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

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.diagnosticsMessageHandlerName,
              let body = message.body as? [String: Any] else {
            return
        }
        var event: [String: Any] = [
            "received_at": ISO8601DateFormatter().string(from: Date()),
            "url": currentURL,
        ]
        for key in ["kind", "level", "message", "timestamp", "source", "line", "column", "stack"] {
            if let value = body[key] {
                event[key] = value
            }
        }
        consoleEvents.append(event)
        if consoleEvents.count > consoleEventLimit {
            consoleEvents = Array(consoleEvents.suffix(consoleEventLimit))
        }
    }

    private func waitConditionPayload(condition: String, value: String) async throws -> [String: Any] {
        let conditionLiteral = try Self.javaScriptLiteral(condition)
        let valueLiteral = try Self.javaScriptLiteral(value)
        let script = """
        (() => {
          const condition = \(conditionLiteral);
          const value = \(valueLiteral);
          if (condition === 'selector') {
            const element = document.querySelector(value);
            return { matched: !!element, condition, value, text: element ? (element.innerText || element.value || '').trim().slice(0, 160) : '' };
          }
          if (condition === 'text') {
            const text = document.body ? document.body.innerText : document.documentElement.innerText || '';
            return { matched: text.includes(value), condition, value };
          }
          if (condition === 'url_contains') {
            return { matched: location.href.includes(value), condition, value, url: location.href };
          }
          if (condition === 'title_contains') {
            return { matched: document.title.includes(value), condition, value, title: document.title };
          }
          return { matched: false, condition, value, error: 'Unsupported condition. Use selector, text, url_contains, or title_contains.' };
        })()
        """
        return try await evaluateObject(script)
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

    static func diagnosticsUserScript() -> WKUserScript {
        let handler = diagnosticsMessageHandlerName
        let source = """
        (() => {
          if (window.__willdeepBrowserDiagnosticsInstalled) return;
          window.__willdeepBrowserDiagnosticsInstalled = true;
          const send = (payload) => {
            try {
              window.webkit.messageHandlers.\(handler).postMessage(payload);
            } catch (_) {}
          };
          const stringify = (value) => {
            try {
              if (typeof value === 'string') return value;
              if (value instanceof Error) return value.stack || value.message || String(value);
              return JSON.stringify(value);
            } catch (_) {
              return String(value);
            }
          };
          ['debug', 'log', 'info', 'warn', 'error'].forEach((level) => {
            const original = console[level] ? console[level].bind(console) : console.log.bind(console);
            console[level] = (...args) => {
              send({
                kind: 'console',
                level,
                message: args.map(stringify).join(' '),
                timestamp: new Date().toISOString()
              });
              return original(...args);
            };
          });
          window.addEventListener('error', (event) => {
            send({
              kind: 'error',
              level: 'error',
              message: event.message || '',
              source: event.filename || '',
              line: event.lineno || 0,
              column: event.colno || 0,
              stack: event.error && event.error.stack ? event.error.stack : '',
              timestamp: new Date().toISOString()
            });
          });
          window.addEventListener('unhandledrejection', (event) => {
            send({
              kind: 'unhandledrejection',
              level: 'error',
              message: stringify(event.reason),
              timestamp: new Date().toISOString()
            });
          });
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
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

    static func snapshot(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let maxElements = arguments["max_elements"]?.intValue() ?? 100
        let payload = try await AgentEmbeddedBrowserController.shared.snapshot(maxElements: maxElements)
        return AgentToolResult(summary: "Snapshotted embedded browser elements", payload: prettyJSONString(payload))
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

    static func waitFor(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let condition = try requiredString("condition", arguments: arguments)
        let value = try requiredString("value", arguments: arguments)
        let timeoutMS = arguments["timeout_ms"]?.intValue() ?? 5_000
        let payload = try await AgentEmbeddedBrowserController.shared.waitFor(
            condition: condition,
            value: value,
            timeoutMS: timeoutMS
        )
        return AgentToolResult(summary: "Waited for embedded browser condition", payload: prettyJSONString(payload))
    }

    static func evaluate(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let source = try requiredString("javascript", arguments: arguments)
        let maxChars = arguments["max_chars"]?.intValue().map { max(1_000, min($0, 100_000)) } ?? 20_000
        let payload = try await AgentEmbeddedBrowserController.shared.evaluate(source: source, maxChars: maxChars)
        return AgentToolResult(summary: "Evaluated embedded browser JavaScript", payload: prettyJSONString(payload))
    }

    static func console(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let maxEntries = arguments["max_entries"]?.intValue() ?? 100
        let levels = arguments["levels"]?.stringArrayValue() ?? []
        let payload = AgentEmbeddedBrowserController.shared.consolePayload(maxEntries: maxEntries, levels: levels)
        return AgentToolResult(summary: "Read embedded browser console", payload: prettyJSONString(payload))
    }

    static func network(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let maxEntries = arguments["max_entries"]?.intValue() ?? 150
        let includeDataURLs = arguments["include_data_urls"]?.boolValue() ?? false
        let payload = try await AgentEmbeddedBrowserController.shared.networkPayload(
            maxEntries: maxEntries,
            includeDataURLs: includeDataURLs
        )
        return AgentToolResult(summary: "Read embedded browser network resources", payload: prettyJSONString(payload))
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
        configuration.userContentController.addUserScript(AgentEmbeddedBrowserController.diagnosticsUserScript())
        configuration.userContentController.add(
            controller,
            name: AgentEmbeddedBrowserController.diagnosticsMessageHandlerName
        )
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
        nsView.configuration.userContentController.removeScriptMessageHandler(
            forName: AgentEmbeddedBrowserController.diagnosticsMessageHandlerName
        )
        AgentEmbeddedBrowserController.shared.unbind(nsView)
    }
}
