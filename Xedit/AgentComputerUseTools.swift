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

    static func requestPermissions(
        arguments: [String: AgentJSONValue],
        sessionPersistenceBarrier: (@MainActor () -> Void)? = nil
    ) async throws -> AgentToolResult {
        if arguments["screen_capture"]?.boolValue() != false {
            try await persistBeforeScreenCapturePermissionIfNeeded(sessionPersistenceBarrier)
        }
        var result = try await AgentComputerUseBridge.shared.invoke(
            action: "request_permissions",
            arguments: arguments
        )
        if result["needs_helper_restart"] as? Bool == true {
            await AgentComputerUseBridge.shared.restart()
            result = try await AgentComputerUseBridge.shared.invoke(action: "permissions")
        }
        return AgentToolResult(summary: "Requested Computer Use permissions", payload: jsonPayload(result))
    }

    static func captureDisplay(
        displayIndex: Int?,
        sessionPersistenceBarrier: (@MainActor () -> Void)? = nil
    ) async throws -> URL {
        var arguments: [String: AgentJSONValue] = [:]
        if let displayIndex {
            arguments["display"] = .number(Double(displayIndex))
        }

        try await persistBeforeScreenCapturePermissionIfNeeded(sessionPersistenceBarrier)
        var result = try await AgentComputerUseBridge.shared.invoke(
            action: "capture_display",
            arguments: arguments
        )
        if result["needs_helper_restart"] as? Bool == true {
            await AgentComputerUseBridge.shared.restart()
            result = try await AgentComputerUseBridge.shared.invoke(
                action: "capture_display",
                arguments: arguments
            )
        }

        guard let screenshot = result["screenshot"] as? [String: Any],
              let path = screenshot["path"] as? String,
              !path.isEmpty else {
            throw AgentToolError.commandFailed(
                1,
                "Screen & System Audio Recording permission is not available to WillDeep Computer Use. Enable it in System Settings; only the helper needs to restart. This is separate from microphone permission."
            )
        }
        return URL(fileURLWithPath: path)
    }

    private static func persistBeforeScreenCapturePermissionIfNeeded(
        _ sessionPersistenceBarrier: (@MainActor () -> Void)?
    ) async throws {
        let status = try await AgentComputerUseBridge.shared.invoke(action: "permissions")
        guard status["screen_capture_granted"] as? Bool != true else { return }
        guard let sessionPersistenceBarrier else {
            throw AgentToolError.commandFailed(
                1,
                "Screen & System Audio Recording permission must be requested from a persisted WillDeep conversation. This is separate from microphone permission."
            )
        }
        sessionPersistenceBarrier()
    }

    static func listApps() async throws -> AgentToolResult {
        let result = try await AgentComputerUseBridge.shared.invoke(action: "list_apps")
        return AgentToolResult(summary: "Listed running macOS apps", payload: jsonPayload(result))
    }

    static func launchApp(
        arguments: [String: AgentJSONValue],
        controlLeaseID: String? = nil
    ) async throws -> AgentToolResult {
        let result = try await AgentComputerUseBridge.shared.invoke(
            action: "launch_app",
            arguments: arguments,
            controlLeaseID: controlLeaseID
        )
        return AgentToolResult(summary: "Launched macOS app", payload: jsonPayload(result))
    }

    static func activateApp(
        arguments: [String: AgentJSONValue],
        controlLeaseID: String? = nil
    ) async throws -> AgentToolResult {
        let result = try await AgentComputerUseBridge.shared.invoke(
            action: "activate_app",
            arguments: arguments,
            controlLeaseID: controlLeaseID
        )
        return AgentToolResult(summary: "Activated macOS app", payload: jsonPayload(result))
    }

    static func getAppState(
        arguments: [String: AgentJSONValue],
        controlLeaseID: String? = nil
    ) async throws -> AgentToolResult {
        let result = try await AgentComputerUseBridge.shared.invoke(
            action: "get_app_state",
            arguments: arguments,
            controlLeaseID: controlLeaseID
        )
        return try stateResult(summary: "Captured macOS app state", result: result)
    }

    static func inspectApp(
        arguments: [String: AgentJSONValue],
        controlLeaseID: String? = nil
    ) async throws -> AgentToolResult {
        var safeArguments = arguments
        safeArguments["include_screenshot"] = .bool(false)
        let result = try await AgentComputerUseBridge.shared.invoke(
            action: "get_app_state",
            arguments: safeArguments,
            controlLeaseID: controlLeaseID
        )
        return try stateResult(summary: "Inspected macOS app Accessibility state", result: result)
    }

    static func waitFor(
        arguments: [String: AgentJSONValue],
        controlLeaseID: String? = nil
    ) async throws -> AgentToolResult {
        let result = try await AgentComputerUseBridge.shared.invoke(
            action: "wait_for",
            arguments: arguments,
            controlLeaseID: controlLeaseID
        )
        return try stateResult(summary: "Waited for macOS app state", result: result)
    }

    static func perform(
        action: String,
        arguments: [String: AgentJSONValue],
        controlLeaseID: String? = nil
    ) async throws -> AgentToolResult {
        try AgentComputerUsePolicy.validateBeforeHelper(
            action: action,
            arguments: arguments
        )
        let result = try await AgentComputerUseBridge.shared.invoke(
            action: action,
            arguments: arguments,
            controlLeaseID: controlLeaseID
        )
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
        payload += "\n\nCoordinate rule: every action must include this state's snapshot_id. Element refs are valid only for this fresh state and must share its snapshot prefix. Pixel x/y values are always relative to the returned target-window screenshot; screen-space coordinates are not accepted. A null screenshot means this was an Accessibility-only inspection and pixel fallback is intentionally unavailable."
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

}
