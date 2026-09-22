//
//  AgentEmbeddedBrowser.swift
//  WillDeep
//
//  In-app browser workbench for the Agent side panel. It intentionally
//  owns a runtime-scoped WKWebView that can keep working before the right
//  rail is opened; the Chrome bridge remains the path for the user's real
//  Chrome profile.
//

import AppKit
import Combine
import Foundation
import SwiftUI
import WebKit

@MainActor
final class AgentEmbeddedBrowserController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let shared = AgentEmbeddedBrowserController()
    static let diagnosticsMessageHandlerName = "willdeepBrowserDiagnostics"
    private static var runtimeControllers: [UUID: [UUID: AgentEmbeddedBrowserController]] = [:]
    private static var activeTabIDs: [UUID: UUID] = [:]
    private static let legacyTabID = UUID(uuidString: "444EF006-70D0-498C-A796-6F41BE10D2F0")!

    @Published var address: String = "https://example.com"
    @Published private(set) var currentURL: String = ""
    @Published private(set) var title: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastScreenshotPath: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// HTTP status of the last main-frame response; nil for non-HTTP pages.
    @Published private(set) var lastHTTPStatus: Int?

    private var webView: WKWebView?
    /// Which data store the web view uses; change it with `switchProfile`.
    @Published private(set) var profile: AgentEmbeddedBrowserProfile = .personal
    /// Profile new tabs of a session start with: the last one chosen there.
    private static var runtimeProfiles: [UUID: AgentEmbeddedBrowserProfile] = [:]
    private var consoleEvents: [[String: Any]] = []
    private let consoleEventLimit = 300
    private var requestEvents: [[String: Any]] = []
    private let requestEventLimit = 500
    private var failedResourceEvents: [[String: Any]] = []
    private let failedResourceEventLimit = 300

    /// Appended to WebKit's user agent so sites see a Safari, not a bare
    /// `AppleWebKit … (KHTML, like Gecko)` embedder. Without the token Baidu
    /// serves its https page as a script that downgrades to http, while
    /// WebKit upgrades known HTTPS hosts back to https — the page bounced
    /// between the two forever.
    static let safariUserAgentSuffix = "Version/\(installedSafariVersion) Safari/605.1.15"
    private static let fallbackSafariVersion = "26.0"
    /// Upper bound for `embedded_browser_navigate` to wait for the page to
    /// settle before returning, so the Agent does not need a separate wait.
    static let navigationSettleTimeout: Duration = .seconds(10)
    private static let navigationSettlePollInterval: Duration = .milliseconds(100)
    /// How long `read_page` / `snapshot` wait for a document that is still
    /// being parsed before reading it anyway.
    static let documentContentWaitTimeout: Duration = .seconds(3)
    /// DOM probes run `innerText`, so they poll slower than `isLoading`.
    private static let documentProbeInterval: Duration = .milliseconds(250)
    /// Longest a click waits for the page to start navigating before it
    /// decides the click did not change pages.
    static let clickNavigationStartWindow: Duration = .milliseconds(600)
    /// Upper bound for any single page script (read, click, eval). A page
    /// with a hung main thread or an eval that awaits forever used to hang
    /// the whole turn, and the user's Stop could not interrupt it.
    static let scriptTimeout: Duration = .seconds(30)
    /// Per-field cap for console messages and dialog text. Pages that log a
    /// whole Redux store produced multi-megabyte console payloads.
    static let consoleFieldCharacterLimit = 2_000
    /// Page-script helpers shared by every read. `wdSafeValue` never returns
    /// the value of password / secret / hidden fields — `embedded_browser_type`
    /// resolves secret placeholders, so the next read would otherwise hand the
    /// real secret back to the model. Mirrors `isSensitiveInput` in the Chrome
    /// extension's content.js, plus hidden inputs (CSRF tokens).
    static let sensitiveValueScript = """
    const wdIsSensitiveInput = (el) => {
      if (!el || el.tagName !== 'INPUT') return false;
      const type = String(el.getAttribute('type') || '').toLowerCase();
      if (type === 'password' || type === 'hidden') return true;
      const name = `${el.getAttribute('name') || ''} ${el.id || ''} ${el.getAttribute('autocomplete') || ''}`.toLowerCase();
      return /(password|passwd|secret|token|otp|one.?time|credit.?card|cvv)/.test(name);
    };
    const wdSafeValue = (el) => (el && !wdIsSensitiveInput(el) && 'value' in el) ? String(el.value || '') : '';
    """

    /// Set by `navigate(to:)` until the new document commits, so readiness
    /// probes never mistake the previous page's DOM for the new one.
    private var awaitingCommit = false
    /// The navigation `navigate(to:)` started. Callbacks for any other
    /// navigation — the initial example.com load, a request it superseded —
    /// must not clear `awaitingCommit` or report their errors as this one's.
    private var pendingNavigation: WKNavigation?
    /// Main-frame navigation counters, so `click` can tell that it triggered
    /// a page change (link, form submit, JS location change, popup).
    private(set) var provisionalNavigationCount = 0
    private(set) var committedNavigationCount = 0
    /// Files `embedded_browser_upload_file` staged for the next file chooser
    /// the page opens (sites that hide the input behind a custom button).
    /// Consumed once; ignored after `pendingOpenPanelDeadline`.
    var pendingOpenPanelFiles: [URL] = []
    var pendingOpenPanelDeadline: Date?
    /// JavaScript dialogs and file choosers the page opened. The Agent has
    /// no way to answer them, so they are dismissed (confirm → Cancel) and
    /// reported instead of silently swallowed.
    private(set) var recentDialogs: [[String: Any]] = []
    private let dialogLimit = 20
    private static var installedSafariVersion: String {
        let version = Bundle(path: "/Applications/Safari.app")?
            .infoDictionary?["CFBundleShortVersionString"] as? String
        guard let version, !version.isEmpty else { return fallbackSafariVersion }
        return version
    }

    private override init() {
        super.init()
    }

    static func controller(for runtimeID: UUID?, tabID: UUID? = nil) -> AgentEmbeddedBrowserController {
        guard let runtimeID else { return shared }
        let resolvedTabID = tabID ?? activeTabIDs[runtimeID] ?? legacyTabID
        activeTabIDs[runtimeID] = resolvedTabID
        if let existing = runtimeControllers[runtimeID]?[resolvedTabID] {
            return existing
        }
        let controller = AgentEmbeddedBrowserController()
        controller.profile = runtimeProfiles[runtimeID] ?? .personal
        runtimeControllers[runtimeID, default: [:]][resolvedTabID] = controller
        return controller
    }

    static func activeTabID(for runtimeID: UUID) -> UUID? {
        activeTabIDs[runtimeID]
    }

    static func activate(tabID: UUID, for runtimeID: UUID) {
        activeTabIDs[runtimeID] = tabID
    }

    static func release(for runtimeID: UUID) {
        if let controllers = runtimeControllers.removeValue(forKey: runtimeID) {
            controllers.values.forEach { $0.resetForResourceReaper() }
        }
        activeTabIDs.removeValue(forKey: runtimeID)
        runtimeProfiles.removeValue(forKey: runtimeID)
    }

    static func release(tabID: UUID, for runtimeID: UUID) {
        guard let controller = runtimeControllers[runtimeID]?.removeValue(forKey: tabID) else { return }
        controller.resetForResourceReaper()
        if runtimeControllers[runtimeID]?.isEmpty == true {
            runtimeControllers.removeValue(forKey: runtimeID)
        }
        if activeTabIDs[runtimeID] == tabID {
            activeTabIDs[runtimeID] = runtimeControllers[runtimeID]?.keys.first
        }
    }

    static func hasController(for runtimeID: UUID) -> Bool {
        runtimeControllers[runtimeID]?.isEmpty == false
    }

    /// URL of the page the session's browser shows, without creating a
    /// controller as a side effect. The @browser mention used to read the
    /// unused `shared` controller and so always reported "no page".
    static func currentURL(for runtimeID: UUID?) -> String {
        existingController(for: runtimeID)?.currentURL ?? ""
    }

    /// The session's active browser controller, if one exists; never creates one.
    static func existingController(for runtimeID: UUID?) -> AgentEmbeddedBrowserController? {
        guard let runtimeID else { return shared }
        guard let controllers = runtimeControllers[runtimeID] else { return nil }
        let tabID = activeTabIDs[runtimeID] ?? legacyTabID
        return controllers[tabID] ?? controllers.values.first
    }

    @discardableResult
    func ensureWebView(loadInitialPage: Bool = true) -> WKWebView {
        if let webView {
            return webView
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = AgentEmbeddedBrowserDataStores.store(for: profile)
        configuration.userContentController.addUserScript(Self.diagnosticsUserScript())
        configuration.userContentController.add(
            self,
            name: Self.diagnosticsMessageHandlerName
        )
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        configuration.applicationNameForUserAgent = Self.safariUserAgentSuffix
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        updateState(from: webView)
        if loadInitialPage, let url = normalizedURL(address) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    /// The session's current profile, without creating a controller.
    static func profile(for runtimeID: UUID?) -> AgentEmbeddedBrowserProfile {
        if let controller = existingController(for: runtimeID) { return controller.profile }
        return runtimeID.flatMap { runtimeProfiles[$0] } ?? .personal
    }

    /// Rebuilds the web view on the other data store and reopens the page
    /// that was showing, so sign-ins never leak between the two.
    func switchProfile(to newProfile: AgentEmbeddedBrowserProfile, runtimeID: UUID?) {
        if let runtimeID { Self.runtimeProfiles[runtimeID] = newProfile }
        guard newProfile != profile else { return }
        let reopen = currentURL
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.diagnosticsMessageHandlerName
        )
        webView?.removeFromSuperview()
        webView = nil
        profile = newProfile
        let fresh = ensureWebView(loadInitialPage: false)
        if let url = URL(string: reopen), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            fresh.load(URLRequest(url: url))
        }
    }

    func resetForResourceReaper() {
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.diagnosticsMessageHandlerName
        )
        webView?.removeFromSuperview()
        webView = nil
        address = "https://example.com"
        currentURL = ""
        title = ""
        isLoading = false
        awaitingCommit = false
        lastError = nil
        lastScreenshotPath = nil
        lastHTTPStatus = nil
        pendingNavigation = nil
        provisionalNavigationCount = 0
        committedNavigationCount = 0
        recentDialogs.removeAll()
        canGoBack = false
        canGoForward = false
        consoleEvents.removeAll()
        requestEvents.removeAll()
        failedResourceEvents.removeAll()
    }

    var isReady: Bool {
        webView != nil
    }

    func navigate(to rawValue: String) throws {
        guard let url = normalizedURL(rawValue) else {
            throw AgentToolError.invalidArgument("Invalid browser URL: \(rawValue)")
        }
        let webView = ensureWebView(loadInitialPage: false)
        address = rawValue
        lastError = nil
        awaitingCommit = true
        if url.isFileURL {
            // Grant read access to the page's folder only, so relative
            // CSS/JS/images load without exposing the rest of the disk.
            pendingNavigation = webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            pendingNavigation = webView.load(URLRequest(url: url))
        }
        updateState(from: webView)
    }

    /// Wait until the page is usable, bounded by `timeout`, and return
    /// whether it got there. Usable means WebKit stopped loading, or the new
    /// document committed, left `readyState == "loading"` and its text held
    /// steady across two probes. The second path matters: pages such as
    /// Baidu search keep a subresource pending forever, so `isLoading` never
    /// drops even though the results are readable within two seconds.
    func waitForNavigationToSettle(timeout: Duration = navigationSettleTimeout) async -> Bool {
        guard let webView else { return false }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var nextProbe = clock.now
        var previousTextLength: Int?
        while webView.isLoading {
            guard clock.now < deadline, !Task.isCancelled else { return false }
            if !awaitingCommit, clock.now >= nextProbe {
                nextProbe = clock.now + Self.documentProbeInterval
                let probe = try? await documentProbe()
                if let probe, AgentEmbeddedBrowserReadiness.isParsed(readyState: probe.readyState) {
                    // An empty body "holding steady" is a JS redirect or a
                    // skeleton still rendering, not a usable page.
                    if previousTextLength == probe.textLength,
                       probe.textLength > 0 || probe.readyState == "complete" {
                        break
                    }
                    previousTextLength = probe.textLength
                } else {
                    previousTextLength = nil
                }
            }
            try? await Task.sleep(for: Self.navigationSettlePollInterval)
        }
        updateState(from: webView)
        return true
    }

    /// Give a document that is still being parsed a short grace period so a
    /// read right after navigation or a click does not return an empty body.
    func waitForDocumentContent(timeout: Duration = documentContentWaitTimeout) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline, !Task.isCancelled {
            if !awaitingCommit,
               let probe = try? await documentProbe(),
               AgentEmbeddedBrowserReadiness.isParsed(readyState: probe.readyState) {
                return
            }
            try? await Task.sleep(for: Self.documentProbeInterval)
        }
    }

    private func documentProbe() async throws -> (readyState: String, textLength: Int) {
        let payload = try await evaluateObject("""
        (() => ({
          ready_state: document.readyState,
          text_length: (document.body ? document.body.innerText : '').length
        }))()
        """)
        return (
            payload["ready_state"] as? String ?? "",
            (payload["text_length"] as? NSNumber)?.intValue ?? 0
        )
    }

    func reload() {
        webView?.reload()
    }

    /// 从一个 Chrome profile 导入 cookie。解密的重活（钥匙串、SQLite、AES）放
    /// 后台线程，注入 WKWebView 的 cookie store 回到主线程。钥匙串读取会触发
    /// macOS 授权框——那是用户的同意闸，如实等它。
    @MainActor
    func importChromeCookies(from profile: ChromeProfile) async -> Result<ChromeCookieImportSummary, ChromeCookieImportError> {
        let loaded: Result<(cookies: [HTTPCookie], skipped: Int), ChromeCookieImportError> = await Task.detached(priority: .userInitiated) {
            do {
                let safeStorageKey = try ChromeCookieImporter.fetchSafeStorageKey()
                let aesKey = ChromeCookieImporter.deriveKey(fromSafeStorageKey: safeStorageKey)
                return .success(try ChromeCookieImporter.loadCookies(from: profile, key: aesKey))
            } catch let error as ChromeCookieImportError {
                return .failure(error)
            } catch {
                return .failure(.databaseUnreadable(error.localizedDescription))
            }
        }.value

        switch loaded {
        case .failure(let error):
            return .failure(error)
        case .success(let payload):
            let store = ensureWebView(loadInitialPage: false).configuration.websiteDataStore.httpCookieStore
            for cookie in payload.cookies {
                await store.setCookie(cookie)
            }
            return .success(ChromeCookieImportSummary(imported: payload.cookies.count, skipped: payload.skipped))
        }
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
            "http_status": lastHTTPStatus ?? NSNull(),
            "last_dialog": recentDialogs.last ?? NSNull(),
            "profile": profile.rawValue,
        ]
    }

    func readPage(maxChars: Int) async throws -> [String: Any] {
        let script = """
        (() => {
          \(Self.sensitiveValueScript)
          const text = (document.body ? document.body.innerText : document.documentElement.innerText || '').slice(0, \(maxChars));
          const links = Array.from(document.querySelectorAll('a[href]')).slice(0, 50).map((a) => ({
            text: (a.innerText || a.getAttribute('aria-label') || '').trim().slice(0, 120),
            href: a.href
          }));
          const forms = Array.from(document.querySelectorAll('input, textarea, select, button'))
            .filter((el) => String(el.getAttribute('type') || '').toLowerCase() !== 'hidden')
            .slice(0, 80).map((el) => ({
            tag: el.tagName.toLowerCase(),
            type: el.getAttribute('type') || '',
            name: el.getAttribute('name') || '',
            id: el.id || '',
            placeholder: el.getAttribute('placeholder') || '',
            text: (el.innerText || wdSafeValue(el)).slice(0, 80),
            ...(wdIsSensitiveInput(el) ? { has_value: !!el.value } : {})
          }));
          return { title: document.title || '', url: location.href, ready_state: document.readyState, text, links, forms };
        })()
        """
        await waitForDocumentContent()
        var payload = try await evaluateObject(script)
        payload["is_loading"] = webView?.isLoading ?? false
        payload["http_status"] = lastHTTPStatus ?? NSNull()
        if let note = AgentEmbeddedBrowserReadiness.emptyContentNote(
            readyState: payload["ready_state"] as? String ?? "",
            isEmpty: (payload["text"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ) {
            payload["note"] = note
        }
        Self.flagBlockedPage(&payload, httpStatus: lastHTTPStatus)
        return payload
    }

    /// Marks a read result whose page is a captcha / security check.
    static func flagBlockedPage(_ payload: inout [String: Any], httpStatus: Int?) {
        guard let reason = AgentBlockedPageDetector.reason(
            title: payload["title"] as? String ?? "",
            url: payload["url"] as? String ?? "",
            text: payload["text"] as? String ?? "",
            httpStatus: httpStatus
        ) else { return }
        payload["blocked_by_site"] = true
        payload["note"] = AgentBlockedPageDetector.stopNote(reason: reason)
    }

    /// Cheap title/url/text probe used by navigate so a block page is
    /// reported without a separate read round.
    func blockedPageReason() async -> String? {
        guard let probe = try? await evaluateObject("""
        (() => ({
          title: document.title || '',
          url: location.href,
          text: (document.body ? document.body.innerText : '').slice(0, \(AgentBlockedPageDetector.shortPageTextLimit + 1))
        }))()
        """) else { return nil }
        return AgentBlockedPageDetector.reason(
            title: probe["title"] as? String ?? "",
            url: probe["url"] as? String ?? "",
            text: probe["text"] as? String ?? "",
            httpStatus: lastHTTPStatus
        )
    }

    func snapshot(maxElements: Int) async throws -> [String: Any] {
        let limit = max(10, min(maxElements, 300))
        let script = """
        (() => {
          \(Self.sensitiveValueScript)
          // Refs from an earlier snapshot must not survive: after the DOM
          // changes, a stale `wd3` on another element would win
          // querySelector and the click would land on the wrong target.
          document.querySelectorAll('[data-wd-browser-ref]').forEach((el) => el.removeAttribute('data-wd-browser-ref'));
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
              text: (el.innerText || wdSafeValue(el) || el.getAttribute('aria-label') || el.getAttribute('placeholder') || '').trim().slice(0, 160),
              href: el.href || '',
              editable,
              clickable,
              bounds: { x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height) }
            };
          });
          return { title: document.title || '', url: location.href, ready_state: document.readyState, count: elements.length, elements };
        })()
        """
        await waitForDocumentContent()
        var payload = try await evaluateObject(script)
        if let note = AgentEmbeddedBrowserReadiness.emptyContentNote(
            readyState: payload["ready_state"] as? String ?? "",
            isEmpty: (payload["count"] as? NSNumber)?.intValue == 0
        ) {
            payload["note"] = note
        }
        return payload
    }

    func click(selector: String) async throws -> [String: Any] {
        let selectorLiteral = try Self.javaScriptLiteral(selector)
        let script = """
        (() => {
          \(Self.sensitiveValueScript)
          const selector = \(selectorLiteral);
          const element = document.querySelector(selector);
          if (!element) return { ok: false, error: `No element matched selector: ${selector}` };
          if (element.disabled || element.getAttribute('aria-disabled') === 'true') {
            return { ok: false, error: `Element is disabled: ${selector}` };
          }
          element.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
          const rect = element.getBoundingClientRect();
          const x = rect.left + rect.width / 2;
          const y = rect.top + rect.height / 2;
          const topmost = document.elementFromPoint(x, y);
          const coveredBy = topmost && topmost !== element && !element.contains(topmost) && !topmost.contains(element)
            ? `${topmost.tagName.toLowerCase()}${topmost.id ? '#' + topmost.id : ''}${topmost.className && typeof topmost.className === 'string' ? '.' + topmost.className.trim().split(/\\s+/).slice(0, 2).join('.') : ''}`
            : null;
          // Menus and comboboxes (Radix, MUI, headless UI) open on
          // pointerdown/mousedown, which element.click() alone never fires.
          const init = { bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, button: 0 };
          if (window.PointerEvent) element.dispatchEvent(new PointerEvent('pointerdown', { ...init, pointerType: 'mouse', isPrimary: true, buttons: 1 }));
          element.dispatchEvent(new MouseEvent('mousedown', { ...init, buttons: 1 }));
          if (typeof element.focus === 'function') element.focus({ preventScroll: true });
          if (window.PointerEvent) element.dispatchEvent(new PointerEvent('pointerup', { ...init, pointerType: 'mouse', isPrimary: true }));
          element.dispatchEvent(new MouseEvent('mouseup', init));
          element.click();
          return {
            ok: true,
            selector,
            tag: element.tagName.toLowerCase(),
            id: element.id || '',
            text: (element.innerText || wdSafeValue(element) || element.getAttribute('aria-label') || '').trim().slice(0, 160),
            covered_by: coveredBy
          };
        })()
        """
        let marker = interactionMarker()
        var payload = try await evaluateObject(script)
        guard payload["ok"] as? Bool == true else { return payload }
        if payload["covered_by"] is NSNull { payload["covered_by"] = nil }
        return await finishInteraction(payload, since: marker)
    }

    struct InteractionMarker {
        let provisional: Int
        let committed: Int
        let dialogs: Int
    }

    /// Snapshot taken before an action that may open a page or a dialog.
    func interactionMarker() -> InteractionMarker {
        InteractionMarker(
            provisional: provisionalNavigationCount,
            committed: committedNavigationCount,
            dialogs: recentDialogs.count
        )
    }

    /// Shared tail of click / press_key / upload: wait for a page the action
    /// opened, flag a block page, and list dialogs it triggered.
    func finishInteraction(_ input: [String: Any], since marker: InteractionMarker) async -> [String: Any] {
        var payload = input
        let provisionalBefore = marker.provisional
        let committedBefore = marker.committed
        let dialogsBefore = marker.dialogs
        if await waitForClickNavigation(provisionalBefore: provisionalBefore, committedBefore: committedBefore) {
            let settled = await waitForNavigationToSettle()
            payload["navigated"] = true
            payload["settled"] = settled
            payload["url"] = currentURL
            payload["title"] = title
            payload["http_status"] = lastHTTPStatus ?? NSNull()
            if let reason = await blockedPageReason() {
                payload["blocked_by_site"] = true
                payload["note"] = AgentBlockedPageDetector.stopNote(reason: reason)
            }
        }
        if recentDialogs.count > dialogsBefore {
            payload["dialogs"] = Array(recentDialogs.suffix(recentDialogs.count - dialogsBefore))
        }
        return payload
    }

    /// After a click, give the page a short window to start a main-frame
    /// navigation (link, form submit, JS location change, popup opened in
    /// place). If one starts, wait for its commit so the next read sees the
    /// new document instead of the old one that is already `complete`.
    func waitForClickNavigation(provisionalBefore: Int, committedBefore: Int) async -> Bool {
        let clock = ContinuousClock()
        let startDeadline = clock.now + Self.clickNavigationStartWindow
        while provisionalNavigationCount == provisionalBefore,
              committedNavigationCount == committedBefore {
            guard clock.now < startDeadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let commitDeadline = clock.now + Self.navigationSettleTimeout
        while committedNavigationCount == committedBefore, webView?.isLoading == true {
            guard clock.now < commitDeadline, !Task.isCancelled else { break }
            try? await Task.sleep(for: Self.navigationSettlePollInterval)
        }
        return true
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
          const inputType = element instanceof HTMLInputElement ? String(element.type || 'text').toLowerCase() : '';
          if (['checkbox', 'radio'].includes(inputType)) {
            return { ok: false, error: `This is a ${inputType}; use embedded_browser_click to toggle it.` };
          }
          if (inputType === 'file') {
            return { ok: false, error: 'File inputs cannot be filled by the Agent; ask the user to choose the file.' };
          }
          element.focus();
          if (element instanceof HTMLSelectElement) {
            const option = Array.from(element.options).find((o) => o.value === text)
              || Array.from(element.options).find((o) => o.label.trim() === text.trim());
            if (!option) return { ok: false, error: `No option with value or label "${text}".` };
            element.value = option.value;
            element.dispatchEvent(new Event('input', { bubbles: true }));
            element.dispatchEvent(new Event('change', { bubbles: true }));
          } else if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) {
            // Use the prototype setter: React/Vue controlled inputs track the
            // value through it, and an instance assignment leaves their state
            // empty so the typed text vanishes on the next render.
            const proto = element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
            setter.call(element, text);
            element.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText', data: text }));
            element.dispatchEvent(new Event('change', { bubbles: true }));
          } else if (element.isContentEditable) {
            // Rich editors (ProseMirror, Lexical, Draft) keep their own model
            // and only follow edits that arrive as input events.
            const selection = window.getSelection();
            const range = document.createRange();
            range.selectNodeContents(element);
            selection.removeAllRanges();
            selection.addRange(range);
            if (!document.execCommand('insertText', false, text)) {
              element.textContent = text;
              element.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
            }
          } else {
            return { ok: false, error: 'Matched element is not text-editable.' };
          }
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

    /// Runs through `callAsyncJavaScript`: the wrapper awaits the user's
    /// async body, and `evaluateJavaScript` cannot return a Promise — it
    /// failed every call with "JavaScript execution returned a result of an
    /// unsupported type".
    func evaluate(source: String, maxChars: Int) async throws -> [String: Any] {
        let body = """
        try {
          const result = await (new Function(`return (async () => {\\n${source}\\n})()`))();
          const type = result === null ? 'null' : Array.isArray(result) ? 'array' : typeof result;
          let value;
          try {
            value = type === 'undefined' ? 'undefined' : JSON.stringify(result);
          } catch (error) {
            value = String(result);
          }
          if (value && value.length > maxChars) value = value.slice(0, maxChars) + '\\n[truncated]';
          return { ok: true, type, value };
        } catch (error) {
          // JavaScriptCore's `stack` omits the message, so lead with it.
          const stack = error && error.stack ? `\\n${error.stack}` : '';
          return { ok: false, error: `${String(error)}${stack}` };
        }
        """
        let webView = ensureWebView()
        let value = try await awaitWebKitCallback(timeout: Self.scriptTimeout, what: "embedded_browser_eval script") { finish in
            webView.callAsyncJavaScript(
                body,
                arguments: ["source": source, "maxChars": maxChars],
                in: nil,
                in: .page
            ) { result in
                finish(result.map { $0 as Any }.mapError { Self.describedScriptError($0) })
            }
        }
        guard let object = value as? [String: Any] else {
            throw AgentToolError.invalidArgument("Embedded browser script returned an invalid response.")
        }
        return object
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

    func requestsPayload(maxEntries: Int, includeHeaders: Bool) -> [String: Any] {
        let events = Array(requestEvents.suffix(max(1, min(maxEntries, requestEventLimit)))).map { event in
            includeHeaders ? event : Self.withoutHeaderValues(event)
        }
        let failedCount = requestEvents.filter { event in
            if let ok = event["ok"] as? Bool, ok == false { return true }
            return (event["status"] as? Int ?? 0) >= 400
        }.count
        return [
            "url": currentURL,
            "title": title,
            "count": events.count,
            "total_captured": requestEvents.count,
            "failed_count": failedCount,
            "requests": events,
        ]
    }

    func storagePayload(includeValues: Bool, maxEntries: Int, maxValueChars: Int) async throws -> [String: Any] {
        let script = """
        (() => {
          const includeValues = \(includeValues ? "true" : "false");
          const maxEntries = \(max(1, min(maxEntries, 500)));
          const maxValueChars = \(max(16, min(maxValueChars, 2_000)));
          const sensitiveName = (name) => /cookie|session|token|auth|secret|password|credential|jwt|bearer/i.test(String(name || ''));
          const clipped = (name, value) => {
            const text = String(value ?? '');
            if (!includeValues) return { length: text.length };
            return {
              length: text.length,
              value: sensitiveName(name) ? '[redacted]' : text.slice(0, maxValueChars)
            };
          };
          const readStorage = (storage) => {
            const entries = [];
            try {
              for (let index = 0; index < storage.length && entries.length < maxEntries; index += 1) {
                const key = storage.key(index);
                entries.push({ key, ...clipped(key, storage.getItem(key)) });
              }
            } catch (error) {
              return { ok: false, error: String(error), entries };
            }
            return { ok: true, count: entries.length, entries };
          };
          const cookies = [];
          try {
            const raw = document.cookie || '';
            raw.split(';').map((part) => part.trim()).filter(Boolean).slice(0, maxEntries).forEach((part) => {
              const splitAt = part.indexOf('=');
              const name = splitAt >= 0 ? part.slice(0, splitAt) : part;
              const value = splitAt >= 0 ? part.slice(splitAt + 1) : '';
              cookies.push({ name, ...clipped(name, value) });
            });
          } catch (_) {}
          return Promise.resolve(typeof indexedDB !== 'undefined' && indexedDB.databases ? indexedDB.databases() : [])
            .then((databases) => ({
              url: location.href,
              origin: location.origin,
              cookies: { count: cookies.length, entries: cookies },
              local_storage: readStorage(localStorage),
              session_storage: readStorage(sessionStorage),
              indexed_db: {
                supported: typeof indexedDB !== 'undefined',
                databases: Array.isArray(databases) ? databases.slice(0, maxEntries).map((db) => ({ name: db.name || '', version: db.version || 0 })) : []
              }
            }))
            .catch((error) => ({
              url: location.href,
              origin: location.origin,
              cookies: { count: cookies.length, entries: cookies },
              local_storage: readStorage(localStorage),
              session_storage: readStorage(sessionStorage),
              indexed_db: { supported: typeof indexedDB !== 'undefined', error: String(error), databases: [] }
            }));
        })()
        """
        return try await evaluateObject(script)
    }

    func performancePayload(maxEntries: Int) async throws -> [String: Any] {
        let script = """
        (() => {
          const maxEntries = \(max(1, min(maxEntries, 500)));
          const round = (value) => Number.isFinite(value) ? Math.round(value * 100) / 100 : 0;
          const state = window.__willdeepBrowserDiagnostics || {};
          const navigationEntry = performance.getEntriesByType('navigation').slice(-1)[0];
          const navigation = navigationEntry ? {
            type: navigationEntry.type || '',
            redirect_count: navigationEntry.redirectCount || 0,
            start_time_ms: round(navigationEntry.startTime || 0),
            duration_ms: round(navigationEntry.duration || 0),
            unload_ms: round((navigationEntry.unloadEventEnd || 0) - (navigationEntry.unloadEventStart || 0)),
            redirect_ms: round((navigationEntry.redirectEnd || 0) - (navigationEntry.redirectStart || 0)),
            dns_ms: round((navigationEntry.domainLookupEnd || 0) - (navigationEntry.domainLookupStart || 0)),
            connect_ms: round((navigationEntry.connectEnd || 0) - (navigationEntry.connectStart || 0)),
            tls_ms: round((navigationEntry.connectEnd || 0) - (navigationEntry.secureConnectionStart || 0)),
            request_to_response_ms: round((navigationEntry.responseStart || 0) - (navigationEntry.requestStart || 0)),
            download_ms: round((navigationEntry.responseEnd || 0) - (navigationEntry.responseStart || 0)),
            dom_interactive_ms: round((navigationEntry.domInteractive || 0) - (navigationEntry.startTime || 0)),
            dom_content_loaded_ms: round((navigationEntry.domContentLoadedEventEnd || 0) - (navigationEntry.startTime || 0)),
            load_event_ms: round((navigationEntry.loadEventEnd || 0) - (navigationEntry.startTime || 0)),
            transfer_size_bytes: Number(navigationEntry.transferSize || 0),
            encoded_body_size_bytes: Number(navigationEntry.encodedBodySize || 0),
            decoded_body_size_bytes: Number(navigationEntry.decodedBodySize || 0)
          } : null;
          const paints = performance.getEntriesByType('paint').map((entry) => ({
            name: entry.name,
            start_time_ms: round(entry.startTime || 0),
            duration_ms: round(entry.duration || 0)
          }));
          const resources = performance.getEntriesByType('resource').slice(-maxEntries).map((entry) => ({
            name: entry.name || '',
            initiator_type: entry.initiatorType || '',
            duration_ms: round(entry.duration || 0),
            transfer_size_bytes: Number(entry.transferSize || 0),
            encoded_body_size_bytes: Number(entry.encodedBodySize || 0),
            decoded_body_size_bytes: Number(entry.decodedBodySize || 0)
          }));
          const byInitiator = resources.reduce((acc, entry) => {
            const key = entry.initiator_type || 'other';
            acc[key] ||= { count: 0, duration_ms: 0, transfer_size_bytes: 0, encoded_body_size_bytes: 0, decoded_body_size_bytes: 0 };
            acc[key].count += 1;
            acc[key].duration_ms = round(acc[key].duration_ms + entry.duration_ms);
            acc[key].transfer_size_bytes += entry.transfer_size_bytes;
            acc[key].encoded_body_size_bytes += entry.encoded_body_size_bytes;
            acc[key].decoded_body_size_bytes += entry.decoded_body_size_bytes;
            return acc;
          }, {});
          return {
            url: location.href,
            title: document.title || '',
            time_origin: performance.timeOrigin || 0,
            navigation,
            paints,
            web_vitals: state.webVitals || {},
            long_tasks: (state.longTasks || []).slice(-20),
            memory: performance.memory ? {
              js_heap_size_limit: performance.memory.jsHeapSizeLimit || 0,
              total_js_heap_size: performance.memory.totalJSHeapSize || 0,
              used_js_heap_size: performance.memory.usedJSHeapSize || 0
            } : null,
            resource_summary: {
              count: resources.length,
              by_initiator: byInitiator,
              slowest: resources.slice().sort((a, b) => b.duration_ms - a.duration_ms).slice(0, 10),
              largest: resources.slice().sort((a, b) => (b.transfer_size_bytes || b.encoded_body_size_bytes || b.decoded_body_size_bytes) - (a.transfer_size_bytes || a.encoded_body_size_bytes || a.decoded_body_size_bytes)).slice(0, 10)
            }
          };
        })()
        """
        return try await evaluateObject(script)
    }

    func failedResourcesPayload(maxEntries: Int) async throws -> [String: Any] {
        let script = """
        (() => {
          const maxEntries = \(max(1, min(maxEntries, 500)));
          const state = window.__willdeepBrowserDiagnostics || {};
          const round = (value) => Number.isFinite(value) ? Math.round(value * 100) / 100 : 0;
          const resourceStatusFailures = performance.getEntriesByType('resource')
            .filter((entry) => Number(entry.responseStatus || 0) >= 400)
            .map((entry) => ({
              kind: 'resource_status',
              url: entry.name || '',
              initiator_type: entry.initiatorType || '',
              status: Number(entry.responseStatus || 0),
              duration_ms: round(entry.duration || 0),
              transfer_size_bytes: Number(entry.transferSize || 0)
            }));
          return {
            url: location.href,
            title: document.title || '',
            captured_resource_errors: (state.failures || []).slice(-maxEntries),
            captured_http_failures: (state.requests || []).filter((entry) => entry.error || Number(entry.status || 0) >= 400).slice(-maxEntries),
            resource_status_failures: resourceStatusFailures.slice(-maxEntries)
          };
        })()
        """
        var payload = try await evaluateObject(script)
        let nativeFailures = Array(failedResourceEvents.suffix(max(1, min(maxEntries, failedResourceEventLimit))))
        payload["native_resource_errors"] = nativeFailures
        return payload
    }

    func exportHAR(maxEntries: Int, includeResourceTimings: Bool, includeHARJSON: Bool) async throws -> [String: Any] {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let appVersionLiteral = try Self.javaScriptLiteral(appVersion)
        let script = """
        (() => {
          const maxEntries = \(max(1, min(maxEntries, 1_000)));
          const includeResourceTimings = \(includeResourceTimings ? "true" : "false");
          const appVersion = \(appVersionLiteral);
          const state = window.__willdeepBrowserDiagnostics || {};
          const round = (value) => Number.isFinite(value) ? Math.round(value * 100) / 100 : 0;
          const headersArray = (headers) => Object.entries(headers || {}).map(([name, value]) => ({ name, value: String(value) }));
          const queryString = (url) => {
            try {
              return Array.from(new URL(url, location.href).searchParams.entries()).map(([name, value]) => ({ name, value }));
            } catch (_) {
              return [];
            }
          };
          const requestEntry = (entry) => ({
            startedDateTime: entry.started_at || new Date().toISOString(),
            time: round(entry.duration_ms || 0),
            request: {
              method: entry.method || 'GET',
              url: entry.url || '',
              httpVersion: 'HTTP/2',
              cookies: [],
              headers: headersArray(entry.request_headers),
              queryString: queryString(entry.url || ''),
              headersSize: -1,
              bodySize: -1
            },
            response: {
              status: Number(entry.status || 0),
              statusText: entry.status_text || '',
              httpVersion: 'HTTP/2',
              cookies: [],
              headers: headersArray(entry.response_headers),
              content: { size: Number(entry.response_bytes || -1), mimeType: entry.mime_type || '' },
              redirectURL: '',
              headersSize: -1,
              bodySize: Number(entry.response_bytes || -1)
            },
            cache: {},
            timings: { blocked: -1, dns: -1, connect: -1, send: 0, wait: round(entry.duration_ms || 0), receive: 0, ssl: -1 },
            _willdeep_transport: entry.transport || 'unknown',
            _willdeep_error: entry.error || ''
          });
          const resourceEntry = (entry) => ({
            startedDateTime: new Date((performance.timeOrigin || Date.now()) + (entry.startTime || 0)).toISOString(),
            time: round(entry.duration || 0),
            request: {
              method: 'GET',
              url: entry.name || '',
              httpVersion: entry.nextHopProtocol || '',
              cookies: [],
              headers: [],
              queryString: queryString(entry.name || ''),
              headersSize: -1,
              bodySize: -1
            },
            response: {
              status: Number(entry.responseStatus || 0),
              statusText: '',
              httpVersion: entry.nextHopProtocol || '',
              cookies: [],
              headers: [],
              content: { size: Number(entry.decodedBodySize || entry.encodedBodySize || -1), mimeType: '' },
              redirectURL: '',
              headersSize: -1,
              bodySize: Number(entry.encodedBodySize || -1)
            },
            cache: {},
            timings: {
              blocked: 0,
              dns: round((entry.domainLookupEnd || 0) - (entry.domainLookupStart || 0)),
              connect: round((entry.connectEnd || 0) - (entry.connectStart || 0)),
              send: 0,
              wait: round((entry.responseStart || 0) - (entry.requestStart || 0)),
              receive: round((entry.responseEnd || 0) - (entry.responseStart || 0)),
              ssl: entry.secureConnectionStart > 0 ? round((entry.connectEnd || 0) - entry.secureConnectionStart) : -1
            },
            _willdeep_initiator_type: entry.initiatorType || ''
          });
          const capturedEntries = (state.requests || []).slice(-maxEntries).map(requestEntry);
          const resources = includeResourceTimings
            ? performance.getEntriesByType('resource').slice(-maxEntries).map(resourceEntry)
            : [];
          const har = {
            log: {
              version: '1.2',
              creator: { name: 'WillDeep Browser Ops', version: appVersion },
              pages: [{
                startedDateTime: new Date(performance.timeOrigin || Date.now()).toISOString(),
                id: 'page_1',
                title: document.title || '',
                pageTimings: {}
              }],
              entries: capturedEntries.concat(resources)
            }
          };
          return {
            url: location.href,
            title: document.title || '',
            captured_request_count: capturedEntries.length,
            resource_timing_count: resources.length,
            har
          };
        })()
        """
        let payload = try await evaluateObject(script)
        guard let har = payload["har"] as? [String: Any] else {
            throw AgentToolError.invalidArgument("Embedded browser did not return a HAR payload.")
        }
        let path = try writeHAR(har)
        var result: [String: Any] = [
            "path": path,
            "url": payload["url"] ?? currentURL,
            "title": payload["title"] ?? title,
            "captured_request_count": payload["captured_request_count"] ?? 0,
            "resource_timing_count": payload["resource_timing_count"] ?? 0,
        ]
        if includeHARJSON {
            result["har"] = har
        }
        return result
    }

    func captureScreenshot() async throws -> String {
        let webView = ensureWebView()
        let captured = try await awaitWebKitCallback(timeout: Self.scriptTimeout, what: "screenshot") { finish in
            webView.takeSnapshot(with: nil) { image, error in
                if let error {
                    finish(.failure(error))
                } else if let image {
                    finish(.success(image))
                } else {
                    finish(.failure(AgentToolError.invalidArgument("WKWebView did not return a screenshot.")))
                }
            }
        }
        guard let image = captured as? NSImage else {
            throw AgentToolError.invalidArgument("WKWebView did not return a screenshot.")
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
        provisionalNavigationCount += 1
        updateState(from: webView)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame {
            lastHTTPStatus = (navigationResponse.response as? HTTPURLResponse)?.statusCode
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Any commit means a new document replaced the old one, including a
        // redirect chain that started from the pending navigation.
        awaitingCommit = false
        committedNavigationCount += 1
        updateState(from: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = webView.isLoading
        if navigation === pendingNavigation {
            awaitingCommit = false
            pendingNavigation = nil
        }
        updateState(from: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(navigation, error: error, in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(navigation, error: error, in: webView)
    }

    /// A failure only speaks for the navigation it belongs to. Earlier every
    /// failure — including the -999 "cancelled" that a newer load delivers to
    /// the one it replaces — cleared `awaitingCommit`, so a navigate issued
    /// while example.com was still loading could settle on example.com's DOM
    /// (seen as url=baidu, title="Example Domain").
    private func handleNavigationFailure(_ navigation: WKNavigation?, error: Error, in webView: WKWebView) {
        isLoading = webView.isLoading
        let nsError = error as NSError
        let superseded = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        let isPending = navigation != nil && navigation === pendingNavigation
        if isPending, !superseded || !webView.isLoading {
            awaitingCommit = false
            pendingNavigation = nil
        }
        if !superseded, isPending || pendingNavigation == nil {
            lastError = error.localizedDescription
        }
        updateState(from: webView)
    }

    // MARK: - WKUIDelegate

    /// `target=_blank` links and `window.open` have no second window to go
    /// to; without this they silently did nothing while `click` reported
    /// success. The embedded browser is single-tab, so they open in place.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.request.url != nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        recordDialog(kind: "alert", message: message, answer: "dismissed")
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        // Cancel is the safe default: a confirm usually guards a deletion
        // or a purchase, and nobody is there to read it.
        recordDialog(kind: "confirm", message: message, answer: "cancelled")
        return false
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        recordDialog(kind: "prompt", message: prompt, answer: "cancelled")
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        let staged = pendingOpenPanelFiles
        let deadline = pendingOpenPanelDeadline
        pendingOpenPanelFiles = []
        pendingOpenPanelDeadline = nil
        if !staged.isEmpty, let deadline, deadline > Date() {
            let files = parameters.allowsMultipleSelection ? staged : Array(staged.prefix(1))
            recordDialog(
                kind: "file_chooser",
                message: "The page asked for a file upload.",
                answer: "provided " + files.map(\.lastPathComponent).joined(separator: ", ")
            )
            return files
        }
        recordDialog(kind: "file_chooser", message: "The page asked for a file upload.", answer: "cancelled")
        return nil
    }

    private func recordDialog(kind: String, message: String, answer: String) {
        recentDialogs.append([
            "kind": kind,
            "message": String(message.prefix(Self.consoleFieldCharacterLimit)),
            "answer": answer,
            "at": ISO8601DateFormatter().string(from: Date()),
        ])
        if recentDialogs.count > dialogLimit {
            recentDialogs = Array(recentDialogs.suffix(dialogLimit))
        }
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
        for key in [
            "kind",
            "level",
            "message",
            "timestamp",
            "source",
            "line",
            "column",
            "stack",
            "transport",
            "id",
            "method",
            "request_url",
            "status",
            "status_text",
            "ok",
            "duration_ms",
            "request_headers",
            "response_headers",
            "error",
            "tag",
            "initiator_type",
        ] {
            if let value = body[key] {
                if let text = value as? String, text.count > Self.consoleFieldCharacterLimit {
                    event[key] = String(text.prefix(Self.consoleFieldCharacterLimit)) + "…[truncated \(text.count - Self.consoleFieldCharacterLimit) chars]"
                } else {
                    event[key] = value
                }
            }
        }
        switch event["kind"] as? String {
        case "http_request":
            requestEvents.append(event)
            if requestEvents.count > requestEventLimit {
                requestEvents = Array(requestEvents.suffix(requestEventLimit))
            }
        case "resource_error":
            failedResourceEvents.append(event)
            if failedResourceEvents.count > failedResourceEventLimit {
                failedResourceEvents = Array(failedResourceEvents.suffix(failedResourceEventLimit))
            }
        default:
            consoleEvents.append(event)
            if consoleEvents.count > consoleEventLimit {
                consoleEvents = Array(consoleEvents.suffix(consoleEventLimit))
            }
        }
    }

    private func waitConditionPayload(condition: String, value: String) async throws -> [String: Any] {
        let conditionLiteral = try Self.javaScriptLiteral(condition)
        let valueLiteral = try Self.javaScriptLiteral(value)
        let script = """
        (() => {
          \(Self.sensitiveValueScript)
          const condition = \(conditionLiteral);
          const value = \(valueLiteral);
          if (condition === 'selector') {
            const element = document.querySelector(value);
            return { matched: !!element, condition, value, text: element ? (element.innerText || wdSafeValue(element) || '').trim().slice(0, 160) : '' };
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

    func evaluateObject(_ script: String) async throws -> [String: Any] {
        let webView = ensureWebView()
        let value = try await awaitWebKitCallback(timeout: Self.scriptTimeout, what: "page script") { finish in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    finish(.failure(Self.describedScriptError(error)))
                } else {
                    finish(.success(value ?? NSNull()))
                }
            }
        }
        guard let object = value as? [String: Any] else {
            throw AgentToolError.invalidArgument("Embedded browser script returned an invalid response.")
        }
        return object
    }

    /// Bridges a WebKit completion handler to async/await with a deadline
    /// and cooperative cancellation. The continuation resumes exactly once:
    /// whichever of completion, timeout or the user's Stop arrives first.
    func awaitWebKitCallback(
        timeout: Duration,
        what: String,
        start: (@escaping @MainActor (Result<Any, any Error>) -> Void) -> Void
    ) async throws -> Any {
        try Task.checkCancellation()
        let gate = WebKitCallbackGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, any Error>) in
                gate.continuation = continuation
                start { result in gate.finish(result) }
                Task { @MainActor in
                    try? await Task.sleep(for: timeout)
                    gate.finish(.failure(AgentToolError.invalidArgument(
                        "Embedded browser \(what) did not finish within \(timeout). The page may be hung or the script awaits forever; read the page or take a screenshot before retrying."
                    )))
                }
            }
        } onCancel: {
            Task { @MainActor in gate.finish(.failure(CancellationError())) }
        }
    }

    /// WebKit reports a thrown page exception as "A JavaScript exception
    /// occurred" and keeps the real message (e.g. an invalid selector's
    /// SyntaxError) in userInfo; surface it so the model can fix the call.
    nonisolated static func describedScriptError(_ error: any Error) -> any Error {
        let nsError = error as NSError
        guard let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String, !message.isEmpty else {
            return error
        }
        return AgentToolError.invalidArgument("JavaScript exception in the page: \(message)")
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

    private func harDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base
            .appendingPathComponent("WillDeep", isDirectory: true)
            .appendingPathComponent("embedded-browser-har", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeHAR(_ har: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(har) else {
            throw AgentToolError.invalidArgument("HAR payload is not valid JSON.")
        }
        let data = try JSONSerialization.data(withJSONObject: har, options: [.prettyPrinted, .sortedKeys])
        let directory = try harDirectory()
        let path = directory.appendingPathComponent("embedded-browser-\(Self.timestamp()).har")
        try data.write(to: path, options: Data.WritingOptions.atomic)
        return path.path
    }

    private static func withoutHeaderValues(_ event: [String: Any]) -> [String: Any] {
        var stripped = event
        for key in ["request_headers", "response_headers"] {
            guard let headers = event[key] as? [String: Any] else { continue }
            stripped[key] = headers.mapValues { value -> Any in
                let text = String(describing: value)
                return ["length": text.count]
            }
        }
        return stripped
    }

    static func javaScriptLiteral(_ value: String) throws -> String {
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
          const state = window.__willdeepBrowserDiagnostics = {
            requests: [],
            failures: [],
            webVitals: { cls: 0, lcp: null, first_input: null },
            longTasks: []
          };
          const pushLimited = (items, value, limit) => {
            items.push(value);
            if (items.length > limit) items.splice(0, items.length - limit);
          };
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
          const sensitiveHeader = (name) => /authorization|cookie|set-cookie|token|api[-_]?key|secret|password|credential|jwt|bearer/i.test(String(name || ''));
          const headerObject = (headers) => {
            const out = {};
            if (!headers) return out;
            try {
              if (headers instanceof Headers) {
                headers.forEach((value, name) => {
                  out[name] = sensitiveHeader(name) ? '[redacted]' : String(value).slice(0, 1000);
                });
                return out;
              }
              if (Array.isArray(headers)) {
                headers.forEach(([name, value]) => {
                  out[name] = sensitiveHeader(name) ? '[redacted]' : String(value).slice(0, 1000);
                });
                return out;
              }
              Object.entries(headers).forEach(([name, value]) => {
                out[name] = sensitiveHeader(name) ? '[redacted]' : String(value).slice(0, 1000);
              });
            } catch (_) {}
            return out;
          };
          const parseXHRHeaders = (raw) => {
            const out = {};
            String(raw || '').trim().split(/\\r?\\n/).filter(Boolean).forEach((line) => {
              const index = line.indexOf(':');
              if (index <= 0) return;
              const name = line.slice(0, index).trim();
              const value = line.slice(index + 1).trim();
              out[name] = sensitiveHeader(name) ? '[redacted]' : value.slice(0, 1000);
            });
            return out;
          };
          const recordRequest = (entry) => {
            const item = {
              kind: 'http_request',
              id: entry.id || `${Date.now()}-${Math.random().toString(16).slice(2)}`,
              transport: entry.transport || 'unknown',
              method: entry.method || 'GET',
              request_url: entry.url || '',
              url: entry.url || '',
              started_at: entry.started_at || new Date().toISOString(),
              completed_at: entry.completed_at || new Date().toISOString(),
              duration_ms: Math.round((entry.duration_ms || 0) * 100) / 100,
              status: Number(entry.status || 0),
              status_text: entry.status_text || '',
              ok: !!entry.ok,
              request_headers: entry.request_headers || {},
              response_headers: entry.response_headers || {},
              response_url: entry.response_url || entry.url || '',
              mime_type: entry.mime_type || '',
              response_bytes: Number(entry.response_bytes || 0),
              error: entry.error || ''
            };
            pushLimited(state.requests, item, 500);
            send(item);
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
            const target = event.target;
            if (target && target !== window && target.tagName) {
              const failure = {
                kind: 'resource_error',
                tag: String(target.tagName || '').toLowerCase(),
                request_url: target.currentSrc || target.src || target.href || '',
                url: target.currentSrc || target.src || target.href || '',
                message: `Failed to load ${String(target.tagName || '').toLowerCase()}`,
                timestamp: new Date().toISOString()
              };
              pushLimited(state.failures, failure, 300);
              send(failure);
              return;
            }
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
          }, true);
          window.addEventListener('unhandledrejection', (event) => {
            send({
              kind: 'unhandledrejection',
              level: 'error',
              message: stringify(event.reason),
              timestamp: new Date().toISOString()
            });
          });
          if (window.fetch) {
            const originalFetch = window.fetch.bind(window);
            window.fetch = async (input, init = {}) => {
              const startedAt = new Date().toISOString();
              const started = performance.now();
              const request = input instanceof Request ? input : null;
              const url = request ? request.url : String(input);
              const method = (init && init.method) || (request && request.method) || 'GET';
              const requestHeaders = {
                ...headerObject(request && request.headers),
                ...headerObject(init && init.headers)
              };
              try {
                const response = await originalFetch(input, init);
                recordRequest({
                  transport: 'fetch',
                  method,
                  url,
                  started_at: startedAt,
                  completed_at: new Date().toISOString(),
                  duration_ms: performance.now() - started,
                  status: response.status,
                  status_text: response.statusText || '',
                  ok: response.ok,
                  request_headers: requestHeaders,
                  response_headers: headerObject(response.headers),
                  response_url: response.url || url,
                  mime_type: response.headers ? response.headers.get('content-type') || '' : ''
                });
                return response;
              } catch (error) {
                recordRequest({
                  transport: 'fetch',
                  method,
                  url,
                  started_at: startedAt,
                  completed_at: new Date().toISOString(),
                  duration_ms: performance.now() - started,
                  ok: false,
                  request_headers: requestHeaders,
                  error: stringify(error)
                });
                throw error;
              }
            };
          }
          if (window.XMLHttpRequest) {
            const originalOpen = XMLHttpRequest.prototype.open;
            const originalSend = XMLHttpRequest.prototype.send;
            const originalSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;
            XMLHttpRequest.prototype.open = function(method, url, async, user, password) {
              this.__willdeepRequest = {
                transport: 'xhr',
                method: method || 'GET',
                url: String(url || ''),
                request_headers: {},
                started_at: '',
                started_ms: 0
              };
              return originalOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
              if (this.__willdeepRequest) {
                this.__willdeepRequest.request_headers[name] = sensitiveHeader(name) ? '[redacted]' : String(value).slice(0, 1000);
              }
              return originalSetRequestHeader.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function() {
              const meta = this.__willdeepRequest || { transport: 'xhr', method: 'GET', url: '', request_headers: {} };
              meta.started_at = new Date().toISOString();
              meta.started_ms = performance.now();
              meta.finished = false;
              const finish = (error) => {
                if (meta.finished) return;
                meta.finished = true;
                recordRequest({
                  transport: 'xhr',
                  method: meta.method,
                  url: meta.url,
                  started_at: meta.started_at,
                  completed_at: new Date().toISOString(),
                  duration_ms: performance.now() - meta.started_ms,
                  status: this.status || 0,
                  status_text: this.statusText || '',
                  ok: this.status >= 200 && this.status < 400,
                  request_headers: meta.request_headers,
                  response_headers: parseXHRHeaders(this.getAllResponseHeaders ? this.getAllResponseHeaders() : ''),
                  response_url: this.responseURL || meta.url,
                  mime_type: this.getResponseHeader ? this.getResponseHeader('content-type') || '' : '',
                  response_bytes: typeof this.responseText === 'string' ? this.responseText.length : 0,
                  error: error || ''
                });
              };
              this.addEventListener('loadend', () => finish(''), { once: true });
              this.addEventListener('error', () => finish('xhr error'), { once: true });
              this.addEventListener('timeout', () => finish('xhr timeout'), { once: true });
              this.addEventListener('abort', () => finish('xhr abort'), { once: true });
              return originalSend.apply(this, arguments);
            };
          }
          const observe = (type, callback) => {
            try {
              if (!window.PerformanceObserver) return;
              const observer = new PerformanceObserver((list) => callback(list.getEntries()));
              observer.observe({ type, buffered: true });
            } catch (_) {}
          };
          observe('largest-contentful-paint', (entries) => {
            const entry = entries[entries.length - 1];
            if (!entry) return;
            state.webVitals.lcp = {
              start_time_ms: Math.round((entry.startTime || 0) * 100) / 100,
              size: entry.size || 0,
              element: entry.element ? String(entry.element.tagName || '').toLowerCase() : ''
            };
          });
          observe('layout-shift', (entries) => {
            entries.forEach((entry) => {
              if (!entry.hadRecentInput) {
                state.webVitals.cls = Math.round(((state.webVitals.cls || 0) + (entry.value || 0)) * 10000) / 10000;
              }
            });
          });
          observe('first-input', (entries) => {
            const entry = entries[0];
            if (!entry) return;
            state.webVitals.first_input = {
              start_time_ms: Math.round((entry.startTime || 0) * 100) / 100,
              delay_ms: Math.round(((entry.processingStart || 0) - (entry.startTime || 0)) * 100) / 100,
              duration_ms: Math.round((entry.duration || 0) * 100) / 100
            };
          });
          observe('longtask', (entries) => {
            entries.forEach((entry) => {
              pushLimited(state.longTasks, {
                name: entry.name || '',
                start_time_ms: Math.round((entry.startTime || 0) * 100) / 100,
                duration_ms: Math.round((entry.duration || 0) * 100) / 100
              }, 100);
            });
          });
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}

enum AgentEmbeddedBrowserTools {
    static func status(arguments: [String: AgentJSONValue], runtimeID: UUID? = nil) async throws -> AgentToolResult {
        let payload = controller(for: runtimeID).statusPayload()
        return AgentToolResult(summary: "Embedded browser status", payload: prettyJSONString(payload))
    }

    static func navigate(
        arguments: [String: AgentJSONValue],
        runtimeID: UUID? = nil,
        allowedFileRoots: [URL] = []
    ) async throws -> AgentToolResult {
        let rawURL = try requiredString("url", arguments: arguments)
        let url: URL
        switch AgentEmbeddedBrowserNavigationPolicy.evaluate(rawURL: rawURL, allowedFileRoots: allowedFileRoots) {
        case .allow(let allowed):
            url = allowed
        case .reject(let reason):
            throw AgentToolError.invalidArgument(reason)
        }
        let controller = controller(for: runtimeID, loadInitialPage: false)
        try controller.navigate(to: url.absoluteString)
        let settled = await controller.waitForNavigationToSettle()
        var payload = controller.statusPayload()
        payload["settled"] = settled
        // `settled` can be true while a subresource is still pending; say so
        // instead of letting the model wait on `is_loading`.
        payload["still_loading_resources"] = settled && controller.isLoading
        if let reason = await controller.blockedPageReason() {
            payload["blocked_by_site"] = true
            payload["note"] = AgentBlockedPageDetector.stopNote(reason: reason)
        }
        return AgentToolResult(summary: "Navigated embedded browser", payload: prettyJSONString(payload))
    }

    static func readPage(arguments: [String: AgentJSONValue], runtimeID: UUID? = nil) async throws -> AgentToolResult {
        let maxChars = arguments["max_chars"]?.intValue().map { max(1_000, min($0, 100_000)) } ?? 20_000
        let payload = try await controller(for: runtimeID).readPage(maxChars: maxChars)
        return AgentToolResult(summary: "Read embedded browser page", payload: prettyJSONString(payload))
    }

    static func snapshot(arguments: [String: AgentJSONValue], runtimeID: UUID? = nil) async throws -> AgentToolResult {
        let maxElements = arguments["max_elements"]?.intValue() ?? 100
        let payload = try await controller(for: runtimeID).snapshot(maxElements: maxElements)
        return AgentToolResult(summary: "Snapshotted embedded browser elements", payload: prettyJSONString(payload))
    }

    static func click(arguments: [String: AgentJSONValue], runtimeID: UUID? = nil) async throws -> AgentToolResult {
        let selector = try requiredString("selector", arguments: arguments)
        let payload = try await controller(for: runtimeID).click(selector: selector)
        return AgentToolResult(summary: "Clicked embedded browser element", payload: prettyJSONString(payload))
    }

    static func typeText(arguments: [String: AgentJSONValue], runtimeID: UUID? = nil) async throws -> AgentToolResult {
        let selector = try requiredString("selector", arguments: arguments)
        let text = try requiredString("text", arguments: arguments)
        let payload = try await controller(for: runtimeID).typeText(selector: selector, text: text)
        return AgentToolResult(summary: "Typed into embedded browser element", payload: prettyJSONString(payload))
    }

    static func waitFor(arguments: [String: AgentJSONValue], runtimeID: UUID? = nil) async throws -> AgentToolResult {
        let condition = try requiredString("condition", arguments: arguments)
        let value = try requiredString("value", arguments: arguments)
        let timeoutMS = arguments["timeout_ms"]?.intValue() ?? 5_000
        let payload = try await controller(for: runtimeID).waitFor(
            condition: condition,
            value: value,
            timeoutMS: timeoutMS
        )
        return AgentToolResult(summary: "Waited for embedded browser condition", payload: prettyJSONString(payload))
    }

    static func evaluate(arguments: [String: AgentJSONValue], runtimeID: UUID? = nil) async throws -> AgentToolResult {
        let source = try requiredString("javascript", arguments: arguments)
        let maxChars = arguments["max_chars"]?.intValue().map { max(1_000, min($0, 100_000)) } ?? 20_000
        let payload = try await controller(for: runtimeID).evaluate(source: source, maxChars: maxChars)
        return AgentToolResult(summary: "Evaluated embedded browser JavaScript", payload: prettyJSONString(payload))
    }

    static func console(arguments: [String: AgentJSONValue], runtimeID: UUID? = nil) async throws -> AgentToolResult {
        let maxEntries = arguments["max_entries"]?.intValue() ?? 100
        let levels = arguments["levels"]?.stringArrayValue() ?? []
        let payload = controller(for: runtimeID).consolePayload(maxEntries: maxEntries, levels: levels)
        return AgentToolResult(summary: "Read embedded browser console", payload: prettyJSONString(payload))
    }

    static func network(arguments: [String: AgentJSONValue], runtimeID: UUID? = nil) async throws -> AgentToolResult {
        let maxEntries = arguments["max_entries"]?.intValue() ?? 150
        let includeDataURLs = arguments["include_data_urls"]?.boolValue() ?? false
        let payload = try await controller(for: runtimeID).networkPayload(
            maxEntries: maxEntries,
            includeDataURLs: includeDataURLs
        )
        return AgentToolResult(summary: "Read embedded browser network resources", payload: prettyJSONString(payload))
    }

    static func requests(arguments: [String: AgentJSONValue], runtimeID: UUID? = nil) async throws -> AgentToolResult {
        let maxEntries = arguments["max_entries"]?.intValue() ?? 100
        let includeHeaders = arguments["include_headers"]?.boolValue() ?? true
        let payload = controller(for: runtimeID).requestsPayload(
            maxEntries: maxEntries,
            includeHeaders: includeHeaders
        )
        return AgentToolResult(summary: "Read embedded browser AJAX/API requests", payload: prettyJSONString(payload))
    }

    static func exportHAR(arguments: [String: AgentJSONValue], runtimeID: UUID? = nil) async throws -> AgentToolResult {
        let maxEntries = arguments["max_entries"]?.intValue() ?? 500
        let includeResourceTimings = arguments["include_resource_timings"]?.boolValue() ?? true
        let includeHARJSON = arguments["include_har_json"]?.boolValue() ?? false
        let payload = try await controller(for: runtimeID).exportHAR(
            maxEntries: maxEntries,
            includeResourceTimings: includeResourceTimings,
            includeHARJSON: includeHARJSON
        )
        return AgentToolResult(summary: "Exported embedded browser HAR", payload: prettyJSONString(payload))
    }

    static func storage(arguments: [String: AgentJSONValue], runtimeID: UUID? = nil) async throws -> AgentToolResult {
        let includeValues = arguments["include_values"]?.boolValue() ?? false
        let maxEntries = arguments["max_entries"]?.intValue() ?? 100
        let maxValueChars = arguments["max_value_chars"]?.intValue() ?? 500
        let payload = try await controller(for: runtimeID).storagePayload(
            includeValues: includeValues,
            maxEntries: maxEntries,
            maxValueChars: maxValueChars
        )
        return AgentToolResult(summary: "Read embedded browser storage", payload: prettyJSONString(payload))
    }

    static func performance(arguments: [String: AgentJSONValue], runtimeID: UUID? = nil) async throws -> AgentToolResult {
        let maxEntries = arguments["max_entries"]?.intValue() ?? 150
        let payload = try await controller(for: runtimeID).performancePayload(maxEntries: maxEntries)
        return AgentToolResult(summary: "Read embedded browser page performance", payload: prettyJSONString(payload))
    }

    static func failedResources(arguments: [String: AgentJSONValue], runtimeID: UUID? = nil) async throws -> AgentToolResult {
        let maxEntries = arguments["max_entries"]?.intValue() ?? 100
        let payload = try await controller(for: runtimeID).failedResourcesPayload(maxEntries: maxEntries)
        return AgentToolResult(summary: "Read embedded browser failed resources", payload: prettyJSONString(payload))
    }

    static func captureScreenshot(arguments: [String: AgentJSONValue], runtimeID: UUID? = nil) async throws -> AgentToolResult {
        let path = try await controller(for: runtimeID).captureScreenshot()
        // Hand the image itself to vision-capable models. With only a path,
        // the Baidu turn wrote its own Swift OCR program to read the page.
        let image = screenshotAttachment(atPath: path)
        return AgentToolResult(
            summary: "Captured embedded browser screenshot",
            payload: prettyJSONString([
                "path": path,
                "image_attached": image != nil,
            ]),
            images: image.map { [$0] } ?? []
        )
    }

    /// Longest edge of the screenshot sent to the model; the full PNG stays
    /// on disk at `path`.
    static let screenshotAttachmentMaxDimension: CGFloat = 1_280

    static func screenshotAttachment(atPath path: String) -> AgentImageAttachment? {
        guard let source = NSImage(contentsOfFile: path),
              let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let scale = min(1, screenshotAttachmentMaxDimension / max(width, height, 1))
        let targetSize = NSSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
            .draw(in: NSRect(origin: .zero, size: targetSize))
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else {
            return nil
        }
        var attachment = try? AgentImageAttachment.fileBacked(data: jpeg, mimeType: "image/jpeg")
        attachment?.originToolName = "embedded_browser_capture_screenshot"
        return attachment
    }

    private static func controller(
        for runtimeID: UUID?,
        loadInitialPage: Bool = true
    ) -> AgentEmbeddedBrowserController {
        let controller = AgentEmbeddedBrowserController.controller(for: runtimeID)
        controller.ensureWebView(loadInitialPage: loadInitialPage)
        return controller
    }

    static func prettyJSONString(_ value: Any) -> String {
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

/// Resume-once box for `awaitWebKitCallback`. MainActor-confined; marked
/// `@unchecked Sendable` only so the cancellation handler can hop back to
/// the main actor with it.
@MainActor
private final class WebKitCallbackGate: @unchecked Sendable {
    var continuation: CheckedContinuation<Any, any Error>?

    func finish(_ result: Result<Any, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
