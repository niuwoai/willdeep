//
//  AgentChromeTools.swift
//  WillDeep
//
//  Tool adapters for the default Chrome profile bridge. The actual browser
//  privileges live in the user-installed MV3 extension; this file only talks
//  to the localhost native-host bridge.
//

import Foundation

enum AgentChromeTools {
    private static let defaultEndpoint = "http://127.0.0.1:8797"
    private static let requestTimeout: TimeInterval = 10
    /// Must match `ChromeBridgeTokenHeader` in willdeep-agent's
    /// chrome_native_host.go. The native host writes a fresh token to
    /// `bridgeTokenURL` (0600) each time it binds the bridge port.
    static let bridgeTokenHeader = "X-WillDeep-Bridge-Token"

    static var bridgeTokenURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WillDeep/ChromeNativeHost", isDirectory: true)
            .appendingPathComponent("bridge-token", isDirectory: false)
    }

    /// Read on every request: the host rotates the token whenever Chrome
    /// relaunches it, so a cached copy would go stale.
    static func bridgeToken(at url: URL = bridgeTokenURL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private static func applyBridgeToken(to request: inout URLRequest) throws {
        guard let token = bridgeToken() else {
            throw AgentToolError.invalidArgument(
                "Chrome bridge is not running (no bridge token at \(bridgeTokenURL.path)). Open Chrome with the WillDeep Browser extension enabled, click the extension icon once to connect, then retry."
            )
        }
        request.setValue(token, forHTTPHeaderField: bridgeTokenHeader)
    }

    static func status(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let envelope = try await get(path: "/chrome/health")
        return AgentToolResult(
            summary: "Chrome bridge status",
            payload: prettyJSONString(envelope)
        )
    }

    static func readPage(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let maxChars = arguments["max_chars"]?.intValue().map { max(1_000, min($0, 100_000)) } ?? 20_000
        let data = try await bridgeRequest(
            type: "page.read",
            payload: ["maxChars": maxChars]
        )
        guard var page = data as? [String: Any] else {
            return AgentToolResult(summary: "Read active Chrome tab", payload: prettyJSONString(data))
        }
        AgentEmbeddedBrowserController.flagBlockedPage(&page, httpStatus: nil)
        return AgentToolResult(summary: "Read active Chrome tab", payload: prettyJSONString(page))
    }

    static func readSelection(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let data = try await bridgeRequest(type: "page.selection", payload: [:])
        return AgentToolResult(summary: "Read Chrome selection", payload: prettyJSONString(data))
    }

    static func snapshot(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let maxElements = arguments["max_elements"]?.intValue().map { max(1, min($0, 600)) } ?? 240
        let data = try await bridgeRequest(type: "page.snapshot", payload: ["maxElements": maxElements])
        return AgentToolResult(summary: "Captured structured Chrome DOM snapshot", payload: prettyJSONString(data))
    }

    static func listTabs(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let data = try await bridgeRequest(type: "tab.list", payload: [:])
        return AgentToolResult(summary: "Listed Chrome tabs", payload: prettyJSONString(data))
    }

    static func activateTab(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        guard let tabID = arguments["tab_id"]?.intValue() else { throw AgentToolError.missingArgument("tab_id") }
        let data = try await bridgeRequest(type: "tab.activate", payload: ["tabId": tabID])
        return AgentToolResult(summary: "Activated Chrome tab", payload: prettyJSONString(data))
    }

    static func navigate(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let url = try requiredString("url", arguments: arguments)
        let data = try await bridgeRequest(type: "tab.navigate", payload: ["url": url])
        return AgentToolResult(summary: "Navigated active Chrome tab", payload: prettyJSONString(data))
    }

    static func history(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let direction = try requiredString("direction", arguments: arguments).lowercased()
        guard ["back", "forward", "reload"].contains(direction) else {
            throw AgentToolError.invalidArgument("direction must be back, forward, or reload.")
        }
        let data = try await bridgeRequest(
            type: "tab.history",
            payload: ["direction": direction, "bypassCache": arguments["bypass_cache"]?.boolValue() ?? false]
        )
        return AgentToolResult(summary: "Changed Chrome navigation history", payload: prettyJSONString(data))
    }

    static func click(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let target = try elementTargetPayload(arguments)
        let data = try await bridgeRequest(
            type: "page.click",
            payload: target
        )
        return AgentToolResult(summary: "Clicked Chrome element", payload: prettyJSONString(data))
    }

    static func typeText(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let text = try requiredString("text", arguments: arguments)
        var payload = try elementTargetPayload(arguments)
        payload["text"] = text
        let data = try await bridgeRequest(
            type: "page.type",
            payload: payload
        )
        return AgentToolResult(summary: "Typed into Chrome element", payload: prettyJSONString(data))
    }

    static func hover(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let target = try elementTargetPayload(arguments)
        let data = try await bridgeRequest(type: "page.hover", payload: target)
        return AgentToolResult(summary: "Hovered over Chrome element", payload: prettyJSONString(data))
    }

    static func selectOption(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        var payload = try elementTargetPayload(arguments)
        let value = arguments["value"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = arguments["label"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value.isEmpty || label.isEmpty else {
            throw AgentToolError.invalidArgument("Provide option value or label, not both.")
        }
        guard !value.isEmpty || !label.isEmpty else {
            throw AgentToolError.invalidArgument("Provide option value or label.")
        }
        if !value.isEmpty { payload["value"] = value }
        if !label.isEmpty { payload["label"] = label }
        let data = try await bridgeRequest(type: "page.select_option", payload: payload)
        return AgentToolResult(summary: "Selected Chrome option", payload: prettyJSONString(data))
    }

    static func pressKey(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let key = try requiredString("key", arguments: arguments)
        var payload = try optionalElementTargetPayload(arguments)
        payload["key"] = key
        for (source, destination) in [
            ("code", "code"), ("alt_key", "alt_key"), ("ctrl_key", "ctrl_key"),
            ("meta_key", "meta_key"), ("shift_key", "shift_key")
        ] {
            if let value = arguments[source] { payload[destination] = value.rawAny }
        }
        let data = try await bridgeRequest(type: "page.key", payload: payload)
        return AgentToolResult(summary: "Pressed a key in Chrome", payload: prettyJSONString(data))
    }

    static func scroll(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let direction = try requiredString("direction", arguments: arguments).lowercased()
        guard ["up", "down", "left", "right"].contains(direction) else {
            throw AgentToolError.invalidArgument("direction must be up, down, left, or right.")
        }
        var payload = try optionalElementTargetPayload(arguments)
        payload["direction"] = direction
        if let pages = arguments["pages"]?.intValue() { payload["pages"] = max(1, min(pages, 8)) }
        let data = try await bridgeRequest(type: "page.scroll", payload: payload)
        return AgentToolResult(summary: "Scrolled Chrome page", payload: prettyJSONString(data))
    }

    static func waitFor(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let condition = try requiredString("condition", arguments: arguments).lowercased()
        guard ["selector", "text", "url_contains", "title_contains"].contains(condition) else {
            throw AgentToolError.invalidArgument("Unsupported wait condition.")
        }
        let value = try requiredString("value", arguments: arguments)
        let timeoutMS = max(100, min(arguments["timeout_ms"]?.intValue() ?? 8_000, 8_000))
        let data = try await bridgeRequest(
            type: "page.wait",
            payload: ["condition": condition, "value": value, "timeoutMs": timeoutMS]
        )
        return AgentToolResult(summary: "Waited for Chrome page condition", payload: prettyJSONString(data))
    }

    static func captureTab(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let data = try await bridgeRequest(type: "tab.capture", payload: [:])
        guard var object = data as? [String: Any],
              let dataURL = object.removeValue(forKey: "image_data_url") as? String,
              let comma = dataURL.firstIndex(of: ","),
              dataURL[..<comma].contains(";base64"),
              let imageData = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else {
            throw AgentToolError.invalidArgument("Chrome bridge returned an invalid screenshot.")
        }
        let image = try AgentImageAttachment.fileBacked(data: imageData, mimeType: "image/png")
        object["image_byte_count"] = imageData.count
        object["path"] = image.filePath
        return AgentToolResult(summary: "Captured visible Chrome tab", payload: prettyJSONString(object), images: [image])
    }

    static func debuggerCommand(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let method = try requiredString("method", arguments: arguments)
        let paramsValue: AgentJSONValue
        if let raw = arguments["params_json"]?.stringValue(),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let decoded = AgentJSONValue.decode(from: raw)
            guard case .object = decoded else {
                throw AgentToolError.invalidArgument("params_json must be a JSON object string.")
            }
            paramsValue = decoded
        } else {
            paramsValue = .object([:])
        }
        let data = try await bridgeRequest(
            type: "debugger.command",
            payload: [
                "method": method,
                "params": paramsValue.rawAny,
                "protocolVersion": "1.3",
            ]
        )
        return AgentToolResult(summary: "Ran Chrome debugger command", payload: prettyJSONString(data))
    }

    private static func bridgeRequest(type: String, payload: [String: Any]) async throws -> Any {
        let body: [String: Any] = [
            "type": type,
            "payload": payload,
            "timeout_ms": Int(requestTimeout * 1_000),
        ]
        let envelope = try await post(path: "/chrome/request", body: body)
        guard let ok = envelope["ok"] as? Bool else {
            throw AgentToolError.invalidArgument("Chrome bridge returned an invalid response.")
        }
        if !ok {
            let message = envelope["error"] as? String ?? "Chrome bridge request failed."
            throw AgentToolError.invalidArgument(message)
        }
        return envelope["data"] ?? NSNull()
    }

    private static func get(path: String) async throws -> [String: Any] {
        var request = URLRequest(url: try endpoint(path: path))
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        try applyBridgeToken(to: &request)
        return try await send(request)
    }

    private static func post(path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: try endpoint(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        try applyBridgeToken(to: &request)
        return try await send(request)
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AgentToolError.invalidArgument("Chrome bridge returned a non-HTTP response.")
            }
            let parsed = try parseJSONObject(data)
            guard (200..<300).contains(http.statusCode) else {
                let message = parsed["error"] as? String
                    ?? String(data: data.prefix(400), encoding: .utf8)
                    ?? "Chrome bridge request failed."
                throw AgentToolError.httpFailed(http.statusCode, message)
            }
            return parsed
        } catch let error as AgentToolError {
            throw error
        } catch {
            throw AgentToolError.invalidArgument(
                "Chrome bridge is not reachable at \(defaultEndpoint). Install/load the WillDeep Browser extension and Native Messaging host, then retry. Underneath: \(error.localizedDescription)"
            )
        }
    }

    private static func parseJSONObject(_ data: Data) throws -> [String: Any] {
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        guard let object = raw as? [String: Any] else {
            throw AgentToolError.invalidArgument("Expected a JSON object from Chrome bridge.")
        }
        return object
    }

    private static func prettyJSONString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return string
    }

    private static func endpoint(path: String) throws -> URL {
        guard let url = URL(string: defaultEndpoint + path) else {
            throw AgentToolError.invalidArgument("Invalid Chrome bridge endpoint.")
        }
        return url
    }

    private static func requiredString(_ name: String, arguments: [String: AgentJSONValue]) throws -> String {
        guard let value = arguments[name]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            throw AgentToolError.missingArgument(name)
        }
        return value
    }

    private static func elementTargetPayload(_ arguments: [String: AgentJSONValue]) throws -> [String: Any] {
        let payload = try optionalElementTargetPayload(arguments)
        guard !payload.isEmpty else {
            throw AgentToolError.invalidArgument("Provide a fresh DOM ref or a unique CSS selector.")
        }
        return payload
    }

    private static func optionalElementTargetPayload(_ arguments: [String: AgentJSONValue]) throws -> [String: Any] {
        let ref = arguments["ref"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selector = arguments["selector"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard ref.isEmpty || selector.isEmpty else {
            throw AgentToolError.invalidArgument("Provide ref or selector, not both.")
        }
        if !ref.isEmpty { return ["ref": ref] }
        if !selector.isEmpty { return ["selector": selector] }
        return [:]
    }
}
