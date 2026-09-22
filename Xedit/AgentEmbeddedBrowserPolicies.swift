//
//  AgentEmbeddedBrowserPolicies.swift
//  WillDeep
//
//  Pure, WebKit-free decisions used by the embedded browser tools: when the
//  side panel must be shown, where Agent navigation may go, how to spot a
//  site that blocks automation, and when a document is readable. Split out
//  of AgentEmbeddedBrowser.swift, which had grown past 2,000 lines.
//

import Foundation

nonisolated enum AgentEmbeddedBrowserAutomationPolicy {
    static let toolNamePrefix = "embedded_browser_"

    /// Every embedded-browser tool acts on the side-panel browser, so the
    /// panel is shown before the tool runs: the user watches what the Agent
    /// browses, and the web view is in a window instead of loading offscreen.
    static func requiresVisiblePanel(toolName: String) -> Bool {
        toolName.hasPrefix(toolNamePrefix)
    }
}

/// Where `embedded_browser_navigate` may take the Agent. The user's own
/// address bar is not restricted; this only bounds model-chosen URLs, which a
/// prompt-injected page can steer.
nonisolated enum AgentEmbeddedBrowserNavigationPolicy {
    enum Decision: Equatable {
        case allow(URL)
        case reject(String)
    }

    static func evaluate(rawURL: String, allowedFileRoots: [URL]) -> Decision {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .reject("Invalid browser URL: empty.") }
        let candidate: URL?
        if let parsed = URL(string: trimmed), parsed.scheme != nil {
            candidate = parsed
        } else {
            candidate = URL(string: "https://\(trimmed)")
        }
        guard let url = candidate, let scheme = url.scheme?.lowercased() else {
            return .reject("Invalid browser URL: \(trimmed)")
        }
        switch scheme {
        case "http", "https":
            guard let host = url.host, !host.isEmpty else {
                return .reject("Invalid browser URL: \(trimmed)")
            }
            if isLoopback(host) {
                // Local dev servers are the main reason to render in-app.
                return .allow(url)
            }
            if AgentWebTools.isBlockedHost(host) {
                return .reject(
                    "embedded_browser_navigate does not open private-network hosts (\(host)): routers, NAS and internal services are off limits to the Agent. Ask the user to open it themselves if it is really needed."
                )
            }
            return .allow(url)
        case "about":
            return url.absoluteString.lowercased() == "about:blank"
                ? .allow(url)
                : .reject("Only about:blank is allowed among about: URLs.")
        case "file":
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let inside = allowedFileRoots.contains { root in
                let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
                return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
            }
            return inside
                ? .allow(url)
                : .reject("file:// URLs may only point inside the session workspace. Serve the file from the workspace or a local dev server instead.")
        default:
            return .reject("embedded_browser_navigate only opens http(s) URLs, about:blank, or file:// URLs inside the workspace; \(scheme): is not allowed.")
        }
    }

    static func isLoopback(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" { return true }
        let octets = host.split(separator: ".")
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy { UInt8($0) != nil }
    }
}

/// Recognizes pages where a site is refusing automation. The 2026-09-22
/// Baidu turn hit "百度安全验证" and, with nothing telling it to stop, spent
/// ten minutes on spoofed curl, OCR, proxies and scraping relays.
nonisolated enum AgentBlockedPageDetector {
    /// Body text is only trusted as a signal on short pages: a real article
    /// may mention "captcha" or "验证码" without being a block page.
    static let shortPageTextLimit = 2_000

    /// Phrases that only appear on interstitials; a title match is enough.
    private static let strongTitleMarkers = [
        "安全验证", "人机验证", "请完成验证", "访问验证",
        "verify you are human", "are you a robot", "attention required",
        "just a moment", "access denied",
    ]
    /// Words an ordinary article can use ("How CAPTCHAs work"); they count
    /// only on a short page.
    private static let weakMarkers = [
        "captcha", "验证码", "访问频繁", "请求过于频繁", "unusual traffic", "too many requests",
        "checking your browser", "enable javascript and cookies", "拖动滑块", "点击完成验证",
    ]
    private static let hostMarkers = ["wappass.baidu.com", "captcha."]
    private static let pathMarkers = ["/captcha", "/challenge", "/sorry/"]
    private static let blockingStatuses: Set<Int> = [403, 429, 503]

    static func reason(title: String, url: String, text: String, httpStatus: Int?) -> String? {
        let lowerTitle = title.lowercased()
        if let marker = strongTitleMarkers.first(where: { lowerTitle.contains($0) }) {
            return "page title looks like a block page (\"\(title)\", matched \"\(marker)\")"
        }
        if let components = URLComponents(string: url) {
            let host = components.host?.lowercased() ?? ""
            let path = components.path.lowercased()
            if hostMarkers.contains(where: { host.contains($0) }) || pathMarkers.contains(where: { path.contains($0) }) {
                return "URL is a verification or challenge page (\(url))"
            }
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isShort = trimmedText.count <= shortPageTextLimit
        if let status = httpStatus, blockingStatuses.contains(status), isShort {
            return "site answered HTTP \(status) with a short page"
        }
        if isShort {
            let haystack = lowerTitle + "\n" + trimmedText.lowercased()
            if let marker = (strongTitleMarkers + weakMarkers).first(where: { haystack.contains($0) }) {
                return "short page asks for verification (matched \"\(marker)\")"
            }
        }
        return nil
    }

    static func stopNote(reason: String) -> String {
        "The site is blocking automated access: \(reason). Stop here and tell the user what you saw; let them take over in the browser panel or choose another source. Do not try to get around it with spoofed user agents, proxies, scraping relays, curl replays or OCR."
    }
}

nonisolated enum AgentEmbeddedBrowserReadiness {
    /// `interactive` means the HTML is parsed and the DOM is readable even
    /// while subresources are still pending.
    static func isParsed(readyState: String) -> Bool {
        readyState == "interactive" || readyState == "complete"
    }

    /// Model-facing hint attached when a read comes back empty, so an empty
    /// body is treated as "not rendered yet" instead of "this page is blank".
    static func emptyContentNote(readyState: String, isEmpty: Bool) -> String? {
        guard isEmpty else { return nil }
        let state = readyState.isEmpty ? "unknown" : readyState
        return "The page has no readable content yet (ready_state=\(state)). It may still be rendering, "
            + "redirecting, or showing an interstitial. Do not conclude the page is empty: call "
            + "embedded_browser_wait_for (e.g. condition=text) and read again, or use "
            + "embedded_browser_capture_screenshot to see what the user sees."
    }
}
