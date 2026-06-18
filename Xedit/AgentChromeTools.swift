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
        return AgentToolResult(summary: "Read active Chrome tab", payload: prettyJSONString(data))
    }

    static func readSelection(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let data = try await bridgeRequest(type: "page.selection", payload: [:])
        return AgentToolResult(summary: "Read Chrome selection", payload: prettyJSONString(data))
    }

    static func click(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let selector = try requiredString("selector", arguments: arguments)
        let data = try await bridgeRequest(
            type: "page.click",
            payload: ["selector": selector]
        )
        return AgentToolResult(summary: "Clicked Chrome element", payload: prettyJSONString(data))
    }

    static func typeText(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let selector = try requiredString("selector", arguments: arguments)
        let text = try requiredString("text", arguments: arguments)
        let data = try await bridgeRequest(
            type: "page.type",
            payload: ["selector": selector, "text": text]
        )
        return AgentToolResult(summary: "Typed into Chrome element", payload: prettyJSONString(data))
    }

    static func captureTab(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let data = try await bridgeRequest(type: "tab.capture", payload: [:])
        return AgentToolResult(summary: "Captured visible Chrome tab", payload: prettyJSONString(data))
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
}
