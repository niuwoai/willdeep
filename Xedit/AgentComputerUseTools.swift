//
//  AgentComputerUseTools.swift
//  WillDeep
//
//  Native Agent tool surface for the standalone Computer Use helper.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AgentComputerUseTools {
    private static let maxLongEdge: CGFloat = 1568

    static func permissions() async throws -> AgentToolResult {
        let result = try await AgentComputerUseBridge.shared.invoke(action: "permissions")
        return AgentToolResult(summary: "Computer Use permission status", payload: jsonPayload(result))
    }

    static func requestPermissions(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let result = try await AgentComputerUseBridge.shared.invoke(action: "request_permissions", arguments: arguments)
        return AgentToolResult(summary: "Requested Computer Use permissions", payload: jsonPayload(result))
    }

    static func listApps() async throws -> AgentToolResult {
        let result = try await AgentComputerUseBridge.shared.invoke(action: "list_apps")
        return AgentToolResult(summary: "Listed running macOS apps", payload: jsonPayload(result))
    }

    static func launchApp(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let result = try await AgentComputerUseBridge.shared.invoke(action: "launch_app", arguments: arguments)
        return AgentToolResult(summary: "Launched macOS app", payload: jsonPayload(result))
    }

    static func activateApp(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let result = try await AgentComputerUseBridge.shared.invoke(action: "activate_app", arguments: arguments)
        return AgentToolResult(summary: "Activated macOS app", payload: jsonPayload(result))
    }

    static func getAppState(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let result = try await AgentComputerUseBridge.shared.invoke(action: "get_app_state", arguments: arguments)
        return try stateResult(summary: "Captured macOS app state", result: result)
    }

    static func inspectApp(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        var safeArguments = arguments
        safeArguments["include_screenshot"] = .bool(false)
        let result = try await AgentComputerUseBridge.shared.invoke(action: "get_app_state", arguments: safeArguments)
        return try stateResult(summary: "Inspected macOS app Accessibility state", result: result)
    }

    static func waitFor(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        let result = try await AgentComputerUseBridge.shared.invoke(action: "wait_for", arguments: arguments)
        return try stateResult(summary: "Waited for macOS app state", result: result)
    }

    static func perform(action: String, arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        if action == "type_text" || action == "set_value" || action == "select_text" {
            try rejectSensitiveText(arguments)
        }
        let result = try await AgentComputerUseBridge.shared.invoke(action: action, arguments: arguments)
        return try stateResult(summary: "Performed computer-use \(action)", result: result)
    }

    static func restartHelper() async throws -> AgentToolResult {
        await AgentComputerUseBridge.shared.restart()
        let result = try await AgentComputerUseBridge.shared.invoke(action: "permissions")
        return AgentToolResult(summary: "Restarted Computer Use helper", payload: jsonPayload(result))
    }

    @MainActor
    private static func stateResult(summary: String, result: [String: Any]) throws -> AgentToolResult {
        let image = try result["screenshot"].flatMap { $0 as? [String: Any] }.flatMap(attachment)
        var payload = jsonPayload(result)
        payload += "\n\nCoordinate rule: element refs are valid only for this fresh state. Pixel x/y values are relative to the returned screenshot unless coordinate_space is explicitly `screen`. A null screenshot means this was an Accessibility-only inspection and pixel fallback is intentionally unavailable."
        return AgentToolResult(summary: summary, payload: payload, images: image.map { [$0] } ?? [])
    }

    private static func attachment(_ screenshot: [String: Any]) throws -> AgentImageAttachment? {
        guard let path = screenshot["path"] as? String else { return nil }
        let url = URL(fileURLWithPath: path)
        let info = try ImageWorkflowSupport.loadImage(path: url.path)
        let image = downscaled(info.image)
        let data = try jpegData(image)
        return try AgentImageAttachment.fileBacked(data: data, mimeType: "image/jpeg")
    }

    private static func downscaled(_ image: CGImage) -> CGImage {
        let longEdge = CGFloat(max(image.width, image.height))
        guard longEdge > maxLongEdge else { return image }
        let ratio = maxLongEdge / longEdge
        return ImageWorkflowSupport.fit(image, within: CGSize(width: CGFloat(image.width) * ratio, height: CGFloat(image.height) * ratio))
    }

    private static func jpegData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AgentToolError.commandFailed(1, "Could not encode Computer Use screenshot.")
        }
        CGImageDestinationAddImage(destination, ImageWorkflowSupport.flatten(image, background: .white), [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AgentToolError.commandFailed(1, "Could not finalize Computer Use screenshot.") }
        return data as Data
    }

    private static func jsonPayload(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func rejectSensitiveText(_ arguments: [String: AgentJSONValue]) throws {
        let candidate = (arguments["text"] ?? arguments["value"])?.stringValue() ?? ""
        let lowered = candidate.lowercased()
        let prefixes = ["sk-", "ghp_", "github_pat_", "akia", "bearer ", "xoxb-", "xoxp-", "-----begin"]
        let looksLikeOneTimeCode = candidate.range(of: "^\\d{6,8}$", options: .regularExpression) != nil
        if prefixes.contains(where: lowered.hasPrefix) || looksLikeOneTimeCode {
            throw AgentToolError.invalidArgument("Computer Use refuses to type a likely secret or one-time code. Ask the user to take over.")
        }
    }
}
