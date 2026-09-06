//
//  AgentNetworkSupport.swift
//  WillDeep
//
//  Protocol-agnostic helpers shared by every provider adapter
//  (OpenAI Chat / OpenAI Responses / Anthropic Messages / Gemini).
//  Lives outside `AgentClient.swift` so the facade stays slim and so
//  newly added adapters can reuse these without dragging in the OpenAI
//  Chat dialect.
//

import Foundation

/// Per-request some.im context carried on `some-im` provider calls. The
/// session id is the Agent runtime UUID; the optional workspace id is a
/// local-only random UUID from the workspace identity store (never a path).
/// Values originate from the session — this type only ferries them to the
/// adapter's header injection point.
struct SomeIMRequestContext: Equatable {
    let sessionID: String
    let workspaceID: String?

    init(sessionID: String, workspaceID: String? = nil) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
    }
}

enum AgentNetworkSupport {
    static func someIMRequestID(from response: HTTPURLResponse, providerID: String) -> String? {
        guard providerID == AgentProviderPreset.someIMID,
              let requestID = response.value(forHTTPHeaderField: "X-Request-Id")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !requestID.isEmpty else { return nil }
        return requestID
    }

    /// The one name this client answers to, everywhere it identifies itself:
    /// `X-Client-Name`, the handshakes that carry their own `version` field
    /// (MCP / ACP / Codex app-server `clientInfo`), OpenRouter's `X-Title`,
    /// and the head of the `User-Agent`. Spaces and parentheses, no hyphen —
    /// the earlier `some.im/WillDeep-{version}` form split the identity across
    /// a slash and a hyphen, so server-side dashboards kept inventing their
    /// own spellings.
    ///
    /// The name alone, no version: every surface that sends it has a separate
    /// field for the build (`X-Client-Version`, `clientInfo.version`), and the
    /// `User-Agent` appends its own.
    static let clientNameHeaderValue = "WillDeep Desktop (some.im)"

    /// "No bytes seen for this long" — not a total budget. Reasoning
    /// models (Qwen3, QwQ, DeepSeek-R1, o-series, Claude extended
    /// thinking) can spend well over two minutes before the first visible
    /// delta hits the SSE pipe; 180s covers that long tail without turning
    /// the request into an unbounded wait.
    static let requestTimeout: TimeInterval = 180
    static let resourceTimeout: TimeInterval = 10 * 60

    /// Tag every outgoing request with our marketing version so the
    /// backend (or any reverse-proxy logs we run through) can bucket
    /// reports / repro a bug against a specific client build.
    /// Matches CLAUDE.md §6.
    static let appVersionHeaderValue: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }()

    /// Unified client identity sent on every outgoing HTTP request (the
    /// `User-Agent`). Form: `WillDeep Desktop (some.im) {version} (macOS)` —
    /// e.g. `WillDeep Desktop (some.im) 1.315.0-rc5 (macOS)`. It opens with
    /// `X-Client-Name` verbatim, so a log line and a client-name dashboard
    /// spell the client the same way; the version trails the name because a
    /// UA has nowhere else to carry the build. Every request that goes through
    /// `applyStandardHeaders` (all some.im login/customer/balance/model
    /// requests included) picks this up. Keep this the single source of truth
    /// — `AppUpdateChecker` and the attention webhook reuse it rather than
    /// re-deriving their own UA.
    static let userAgentHeaderValue: String = userAgent(forVersion: appVersionHeaderValue)

    /// Version is a parameter because the attention webhook stamps the version
    /// captured with the event rather than whatever the bundle reports now.
    static func userAgent(forVersion version: String) -> String {
        "\(clientNameHeaderValue) \(version) (macOS)"
    }

    /// some.im managed-routing context header names. Values come from the
    /// Agent session (see `SomeIMRequestContext`) and are only attached to
    /// `some-im` requests — never generated in this helper.
    static let willDeepSessionHeaderName = "x-willdeep-session-id"
    /// The relay bills and logs against this header specifically: its usage
    /// ledger reads `X-Playground-Session-ID` and ignores our own session
    /// header, so sending only the latter leaves `usage_records.session_id`
    /// empty and makes worker traffic impossible to attribute to the chat
    /// that spawned it. Same opaque UUID, sent alongside.
    static let relaySessionHeaderName = "X-Playground-Session-ID"
    static let willDeepWorkspaceHeaderName = "x-willdeep-workspace-id"
    static let willDeepResponsesStateHeaderName = "x-willdeep-responses-state"
    static let willDeepResponsesStateProtocol = "v1"

    static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// Session for talking to a process on this Mac's loopback interface
    /// (the local Mobile Gateway). Forces proxies OFF: a configured system
    /// HTTP/HTTPS/SOCKS proxy (Clash, Surge, a corporate PAC…) must never
    /// intercept 127.0.0.1 traffic — otherwise the gateway health probe is
    /// routed into the proxy, never completes, and the settings UI is
    /// stranded on "Starting…" (command-line curl bypasses proxies for
    /// localhost, which is why the gateway looked healthy from a shell but
    /// not from the app). Short timeouts so a dead gateway fails fast.
    static func loopbackSession(
        requestTimeout: TimeInterval = 5,
        resourceTimeout: TimeInterval = 10
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        // Documented CFProxySupport dictionary keys; setting the *Enable
        // flags to 0 disables each proxy type for this session only.
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 0,
        ]
        return URLSession(configuration: configuration)
    }

    /// Stamp every outgoing adapter request with shared metadata
    /// (`X-App-Version`, `X-Client-Name`, `X-Client-Version` + `User-Agent`).
    /// Auth headers and Content-Type
    /// are per-adapter — see each adapter's `applyAuthenticationHeaders`.
    static func applyStandardHeaders(to request: inout URLRequest) {
        request.setValue(appVersionHeaderValue, forHTTPHeaderField: "X-App-Version")
        request.setValue(clientNameHeaderValue, forHTTPHeaderField: "X-Client-Name")
        request.setValue(appVersionHeaderValue, forHTTPHeaderField: "X-Client-Version")
        request.setValue(userAgentHeaderValue, forHTTPHeaderField: "User-Agent")
    }

    static func moveDownloadedFile(from temporaryURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            try fileManager.copyItem(at: temporaryURL, to: destinationURL)
            try? fileManager.removeItem(at: temporaryURL)
        }
    }

    /// Join `baseURL + suffix` while tolerating "user already pasted the
    /// full path" / "user left a trailing slash" / "user pasted a query
    /// string by accident". The OpenAI Chat adapter has always done this;
    /// pulling it out so Responses / Anthropic / Gemini can share.
    static func endpoint(from baseURL: String, suffix: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t"))
        guard var components = URLComponents(string: trimmed) else {
            throw AgentClientError.invalidBaseURL
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(suffix) {
            guard let url = components.url else { throw AgentClientError.invalidBaseURL }
            return url
        }

        let separator = path.isEmpty ? "" : "/"
        components.path = "/\(path)\(separator)\(suffix)"
        guard let url = components.url else {
            throw AgentClientError.invalidBaseURL
        }
        return url
    }

    /// Drain the body of a failed response into a UTF-8 string, capped
    /// so a 5 MB HTML error page doesn't blow up our logs.
    static func collectBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        let limit = 64 * 1024
        for try await byte in bytes {
            if data.count < limit {
                data.append(byte)
            } else {
                break
            }
        }
        let text = String(data: data, encoding: .utf8) ?? "<non-UTF8 response body>"
        return data.count >= limit ? "\(text)\n\n[truncated]" : text
    }

    /// Render the chat history as a numbered preview for HTTP error
    /// reports. Per-message text is capped at 240 chars and stripped of
    /// newlines so the resulting blob stays grep-friendly.
    static func requestSummary(for messages: [AgentMessage]) -> String {
        guard !messages.isEmpty else { return "(no chat messages)" }
        return messages.enumerated().map { index, message in
            let text = message.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = text.isEmpty ? "(empty)" : String(text.prefix(240))
            let imageText = message.images.isEmpty ? "" : " + \(message.images.count) image\(message.images.count == 1 ? "" : "s")"
            let toolCallText = message.toolCalls.isEmpty
                ? ""
                : " [\(message.toolCalls.count) tool_call\(message.toolCalls.count == 1 ? "" : "s"): \(message.toolCalls.map(\.toolName).joined(separator: ", "))]"
            return "\(index + 1). \(message.role.rawValue): \(preview)\(text.count > 240 ? "..." : "")\(imageText)\(toolCallText)"
        }.joined(separator: "\n")
    }

    /// Pretty-print a request body for the HTTP error report while
    /// redacting `data:image/...` URLs (a 4 MB base64 PNG in an error
    /// log helps nobody) and any `?key=...` query string (Gemini puts
    /// API keys in URLs — we never want those echoed back).
    static func redactedJSONString(from data: Data?) -> String {
        guard let data else { return "(no request body)" }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return limitDebugText(String(data: data, encoding: .utf8) ?? "<non-UTF8 request body>")
        }
        let redacted = redactImages(in: object)
        guard let pretty = try? JSONSerialization.data(withJSONObject: redacted, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else {
            return limitDebugText(String(data: data, encoding: .utf8) ?? "<non-UTF8 request body>")
        }
        return limitDebugText(text)
    }

    private static func redactImages(in value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, raw) in dict {
                if key == "url",
                   let string = raw as? String,
                   string.hasPrefix("data:image/") {
                    result[key] = "[redacted image data URL]"
                } else {
                    result[key] = redactImages(in: raw)
                }
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { redactImages(in: $0) }
        }
        return value
    }

    /// Strip query-string secrets (Gemini's `?key=...`) before a URL is
    /// embedded in an error report or surfaced to a user-visible banner.
    static func redactedURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.map { item in
                let lower = item.name.lowercased()
                if lower == "key" || lower.contains("api") || lower.contains("token") {
                    return URLQueryItem(name: item.name, value: "[redacted]")
                }
                return item
            }
        }
        return components.url?.absoluteString ?? url.absoluteString
    }

    static func limitDebugText(_ text: String) -> String {
        let limit = 32_000
        guard text.count > limit else { return text }
        return "\(text.prefix(limit))\n\n[truncated]"
    }
}
