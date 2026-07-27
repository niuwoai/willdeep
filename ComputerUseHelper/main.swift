import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let protocolVersion = "willdeep-computer-use.v5"
private let maximumElementCount = 500
private let maximumDepth = 12
private let maximumTextLength = 500

private enum HelperFailure: LocalizedError {
    case invalidRequest(String)
    case appNotFound(String)
    case accessibilityNotGranted
    case elementNotFound(String)
    case unsupportedAction(String)
    case screenCaptureNotGranted
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): return message
        case .appNotFound(let app): return "App not found: \(app)"
        case .accessibilityNotGranted: return "Accessibility permission is not granted to WillDeep Computer Use."
        case .elementNotFound(let ref): return "The accessibility element is stale or missing: \(ref)"
        case .unsupportedAction(let action): return "Unsupported computer-use action: \(action)"
        case .screenCaptureNotGranted: return "Screen & System Audio Recording permission is not granted to WillDeep Computer Use."
        case .captureFailed: return "Could not capture the target window."
        }
    }
}

private final class ComputerUseController {
    private struct Snapshot {
        let pid: pid_t
        let windowFrame: CGRect
        let imageSize: CGSize
    }

    private var elements: [String: AXUIElement] = [:]
    private var snapshots: [pid_t: Snapshot] = [:]

    func handle(_ request: [String: Any]) throws -> [String: Any] {
        guard let action = request["action"] as? String else {
            throw HelperFailure.invalidRequest("Missing action.")
        }
        let arguments = request["arguments"] as? [String: Any] ?? [:]
        switch action {
        case "permissions":
            return permissionStatus()
        case "request_permissions":
            return requestPermissions(arguments)
        case "capture_display":
            return try captureDisplay(arguments)
        case "list_apps":
            return listApps()
        case "launch_app":
            return try launchApp(arguments)
        case "activate_app":
            return try activateApp(arguments)
        case "get_app_state":
            return try getAppState(arguments)
        case "wait_for":
            return try waitFor(arguments)
        case "click", "secondary_action", "scroll", "drag", "type_text", "press_key", "set_value", "focus", "hover", "select_text":
            return try perform(action: action, arguments: arguments)
        case "shutdown":
            return ["shutdown": true]
        default:
            throw HelperFailure.unsupportedAction(action)
        }
    }

    private func permissionStatus() -> [String: Any] {
        [
            "protocol_version": protocolVersion,
            "accessibility_granted": AXIsProcessTrusted(),
            "screen_capture_granted": CGPreflightScreenCaptureAccess()
        ]
    }

    private func requestPermissions(_ arguments: [String: Any]) -> [String: Any] {
        var needsHelperRestart = false
        if bool(arguments, "accessibility", default: true) {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        if bool(arguments, "screen_capture", default: true), !CGPreflightScreenCaptureAccess() {
            needsHelperRestart = CGRequestScreenCaptureAccess()
        }
        var status = permissionStatus()
        status["needs_helper_restart"] = needsHelperRestart
        return status
    }

    private func listApps() -> [String: Any] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier > 0 && !$0.isTerminated }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
            .map { app in
                [
                    "pid": Int(app.processIdentifier),
                    "bundle_id": app.bundleIdentifier ?? "",
                    "name": app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "Unknown",
                    "active": app.isActive,
                    "hidden": app.isHidden
                ]
            }
        return ["apps": apps]
    }

    private func launchApp(_ arguments: [String: Any]) throws -> [String: Any] {
        let identifier = try requiredString(arguments, "app")
        if let running = resolveRunningApplication(identifier) {
            return appDictionary(running, launched: false)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            throw HelperFailure.appNotFound(identifier)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<NSRunningApplication, Error>?
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            if let app {
                result = .success(app)
            } else {
                result = .failure(error ?? HelperFailure.appNotFound(identifier))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw HelperFailure.invalidRequest("Timed out launching \(identifier).")
        }
        switch result {
        case .success(let app): return appDictionary(app, launched: true)
        case .failure(let error): throw error
        case .none: throw HelperFailure.appNotFound(identifier)
        }
    }

    private func activateApp(_ arguments: [String: Any]) throws -> [String: Any] {
        let app = try resolveApplication(arguments)
        guard app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) else {
            throw HelperFailure.invalidRequest("Could not activate \(app.localizedName ?? "the target app").")
        }
        return appDictionary(app, launched: false).merging(["activated": true]) { _, new in new }
    }

    private func getAppState(_ arguments: [String: Any]) throws -> [String: Any] {
        try requireAccessibility()
        let app = try resolveApplication(arguments)
        let includeScreenshot = bool(arguments, "include_screenshot", default: true)
        let axApplication = AXUIElementCreateApplication(app.processIdentifier)
        elements.removeAll(keepingCapacity: true)
        let snapshotID = UUID().uuidString.lowercased()
        let counter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        counter.initialize(to: 0)
        let tree = buildTree(
            element: axApplication,
            snapshotID: snapshotID,
            depth: 0,
            counter: counter
        )
        var result: [String: Any] = [
            "app": appDictionary(app, launched: false),
            "snapshot_id": snapshotID,
            "tree": tree
        ]
        if includeScreenshot {
            let capture = try captureWindow(for: app)
            snapshots[app.processIdentifier] = Snapshot(
                pid: app.processIdentifier,
                windowFrame: capture.frame,
                imageSize: capture.imageSize
            )
            result["screenshot"] = capture.dictionary
        } else {
            snapshots.removeValue(forKey: app.processIdentifier)
            result["screenshot"] = NSNull()
        }
        return result
    }

    private func waitFor(_ arguments: [String: Any]) throws -> [String: Any] {
        try requireAccessibility()
        let condition = try requiredString(arguments, "condition")
        let timeoutMilliseconds = max(100, min(int(arguments, "timeout_ms", default: 5_000), 15_000))
        let pollMilliseconds = max(50, min(int(arguments, "poll_ms", default: 100), 1_000))
        let expected = arguments["expected"] as? String ?? ""
        let ref = arguments["ref"] as? String
        let pid = try targetPID(arguments)
        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)

        repeat {
            let matchedValue: String?
            switch condition {
            case "ref_exists":
                guard let ref else { throw HelperFailure.invalidRequest("ref_exists requires ref.") }
                matchedValue = elements[ref].flatMap { attributeValue($0, kAXRoleAttribute) }.map { _ in "true" }
            case "value_contains":
                guard let ref else { throw HelperFailure.invalidRequest("value_contains requires ref.") }
                guard !expected.isEmpty else { throw HelperFailure.invalidRequest("value_contains requires expected.") }
                matchedValue = elements[ref]
                    .flatMap { attributeValue($0, kAXValueAttribute) }
                    .map { String(describing: printable($0)) }
                    .flatMap { $0.localizedCaseInsensitiveContains(expected) ? $0 : nil }
            case "title_contains":
                guard !expected.isEmpty else { throw HelperFailure.invalidRequest("title_contains requires expected.") }
                let axApplication = AXUIElementCreateApplication(pid)
                let focusedWindow: AXUIElement? = {
                    guard let raw = attributeValue(axApplication, kAXFocusedWindowAttribute),
                          CFGetTypeID(raw as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
                    return (raw as! AXUIElement)
                }()
                let titleSource = focusedWindow ?? axApplication
                let title = attributeValue(titleSource, kAXTitleAttribute).map { String(describing: printable($0)) } ?? ""
                matchedValue = title.localizedCaseInsensitiveContains(expected) ? title : nil
            default:
                throw HelperFailure.invalidRequest("Unsupported wait condition: \(condition).")
            }

            if let matchedValue {
                return try getAppState([
                    "pid": Int(pid),
                    "include_screenshot": bool(arguments, "include_screenshot", default: false)
                ]).merging([
                    "waited_condition": condition,
                    "matched_value": matchedValue,
                    "timeout_ms": timeoutMilliseconds
                ]) { _, new in new }
            }
            Thread.sleep(forTimeInterval: Double(pollMilliseconds) / 1_000)
        } while Date() < deadline

        throw HelperFailure.invalidRequest("Timed out waiting for \(condition) after \(timeoutMilliseconds) ms.")
    }

    private func perform(action: String, arguments: [String: Any]) throws -> [String: Any] {
        try requireAccessibility()
        guard CGPreflightScreenCaptureAccess() else { throw HelperFailure.screenCaptureNotGranted }
        let pid = try targetPID(arguments)
        switch action {
        case "click": try click(arguments, pid: pid)
        case "secondary_action": try secondaryAction(arguments, pid: pid)
        case "scroll": try scroll(arguments, pid: pid)
        case "drag": try drag(arguments, pid: pid)
        case "type_text": try typeText(arguments, pid: pid)
        case "press_key": try pressKey(arguments, pid: pid)
        case "set_value": try setValue(arguments)
        case "focus": try focus(arguments)
        case "hover": try hover(arguments, pid: pid)
        case "select_text": try selectText(arguments)
        default: throw HelperFailure.unsupportedAction(action)
        }
        let app = try resolveApplication(["pid": Int(pid)])
        return try getAppState(["pid": Int(app.processIdentifier)]).merging([
            "performed_action": action,
            "target_pid": Int(pid)
        ]) { _, new in new }
    }

    private func buildTree(
        element: AXUIElement,
        snapshotID: String,
        depth: Int,
        counter: UnsafeMutablePointer<Int>
    ) -> [String: Any] {
        defer {
            if depth == 0 { counter.deallocate() }
        }
        counter.pointee += 1
        let ref = "\(snapshotID):e\(counter.pointee)"
        elements[ref] = element
        var result: [String: Any] = ["ref": ref]
        for attribute in [
            kAXRoleAttribute,
            kAXSubroleAttribute,
            kAXIdentifierAttribute,
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
            kAXValueAttribute,
            kAXEnabledAttribute,
            kAXFocusedAttribute,
            kAXSelectedAttribute,
            kAXExpandedAttribute
        ] {
            if let value = attributeValue(element, attribute) {
                result[normalizedAttributeName(attribute)] = printable(value)
            }
        }
        if let frame = elementFrame(element) {
            result["frame"] = frameDictionary(frame)
            result["center"] = ["x": frame.midX, "y": frame.midY]
        }
        let actions = copyActionNames(element)
        if !actions.isEmpty { result["actions"] = actions }
        guard depth < maximumDepth, counter.pointee < maximumElementCount,
              let children = attributeValue(element, kAXChildrenAttribute) as? [AXUIElement] else {
            return result
        }
        let remaining = maximumElementCount - counter.pointee
        let entries = children.prefix(max(0, remaining)).map { child in
            buildTree(element: child, snapshotID: snapshotID, depth: depth + 1, counter: counter)
        }
        if !entries.isEmpty { result["children"] = entries }
        return result
    }

    private func click(_ arguments: [String: Any], pid: pid_t) throws {
        if let ref = arguments["ref"] as? String, let element = elements[ref] {
            let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if status == .success { return }
            if let frame = elementFrame(element) {
                let clicks = max(1, min(3, int(arguments, "click_count", default: 1)))
                let center = CGPoint(x: frame.midX, y: frame.midY)
                for _ in 0..<clicks {
                    postMouse(.leftMouseDown, point: center, pid: pid)
                    postMouse(.leftMouseUp, point: center, pid: pid)
                }
                return
            }
            throw HelperFailure.elementNotFound(ref)
        }
        let point = try point(arguments, pid: pid)
        let clicks = max(1, min(3, int(arguments, "click_count", default: 1)))
        for _ in 0..<clicks { postMouse(.leftMouseDown, point: point, pid: pid); postMouse(.leftMouseUp, point: point, pid: pid) }
    }

    private func secondaryAction(_ arguments: [String: Any], pid: pid_t) throws {
        if let ref = arguments["ref"] as? String, let element = elements[ref] {
            let status = AXUIElementPerformAction(element, kAXShowMenuAction as CFString)
            if status == .success { return }
        }
        let point = try point(arguments, pid: pid)
        postMouse(.rightMouseDown, point: point, pid: pid)
        postMouse(.rightMouseUp, point: point, pid: pid)
    }

    private func scroll(_ arguments: [String: Any], pid: pid_t) throws {
        let direction = (arguments["direction"] as? String ?? "down").lowercased()
        let pages = max(1, min(8, int(arguments, "pages", default: 1)))
        let delta = (direction == "up" || direction == "left") ? 8 : -8
        let vertical = direction == "up" || direction == "down"
        for _ in 0..<pages {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: vertical ? Int32(delta) : 0, wheel2: vertical ? 0 : Int32(delta), wheel3: 0)
            event?.postToPid(pid)
        }
    }

    private func drag(_ arguments: [String: Any], pid: pid_t) throws {
        let from = try point(arguments, prefix: "from_", pid: pid)
        let to = try point(arguments, prefix: "to_", pid: pid)
        postMouse(.leftMouseDown, point: from, pid: pid)
        postMouse(.leftMouseDragged, point: to, pid: pid)
        postMouse(.leftMouseUp, point: to, pid: pid)
    }

    private func typeText(_ arguments: [String: Any], pid: pid_t) throws {
        let text = try requiredString(arguments, "text")
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        event?.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16))
        event?.postToPid(pid)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        keyUp?.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16))
        keyUp?.postToPid(pid)
    }

    private func pressKey(_ arguments: [String: Any], pid: pid_t) throws {
        let raw = try requiredString(arguments, "key")
        let parsed = try KeyStroke.parse(raw)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: true)
        down?.flags = parsed.flags
        down?.postToPid(pid)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: false)
        up?.flags = parsed.flags
        up?.postToPid(pid)
    }

    private func setValue(_ arguments: [String: Any]) throws {
        let ref = try requiredString(arguments, "ref")
        let value = try requiredString(arguments, "value")
        guard let element = elements[ref] else { throw HelperFailure.elementNotFound(ref) }
        let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        guard status == .success else { throw HelperFailure.elementNotFound(ref) }
    }

    private func focus(_ arguments: [String: Any]) throws {
        let ref = try requiredString(arguments, "ref")
        guard let element = elements[ref] else { throw HelperFailure.elementNotFound(ref) }
        let status = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)
        if status == .success { return }
        let raiseStatus = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        guard raiseStatus == .success else { throw HelperFailure.elementNotFound(ref) }
    }

    private func hover(_ arguments: [String: Any], pid: pid_t) throws {
        let target: CGPoint
        if let ref = arguments["ref"] as? String,
           let element = elements[ref],
           let frame = elementFrame(element) {
            target = CGPoint(x: frame.midX, y: frame.midY)
        } else {
            target = try point(arguments, pid: pid)
        }
        postMouse(.mouseMoved, point: target, pid: pid)
    }

    private func selectText(_ arguments: [String: Any]) throws {
        let ref = try requiredString(arguments, "ref")
        let text = try requiredString(arguments, "text")
        guard let element = elements[ref] else { throw HelperFailure.elementNotFound(ref) }
        guard let value = attributeValue(element, kAXValueAttribute) as? String,
              let range = value.range(of: text),
              let lowerBound = range.lowerBound.samePosition(in: value.utf16),
              let upperBound = range.upperBound.samePosition(in: value.utf16) else {
            throw HelperFailure.invalidRequest("Text was not found in the target element.")
        }
        let location = value.utf16.distance(from: value.utf16.startIndex, to: lowerBound)
        let length = value.utf16.distance(from: lowerBound, to: upperBound)
        let selectionType = (arguments["selection_type"] as? String ?? "text").lowercased()
        let selectedRange: CFRange
        switch selectionType {
        case "cursor_before": selectedRange = CFRange(location: location, length: 0)
        case "cursor_after": selectedRange = CFRange(location: location + length, length: 0)
        case "text": selectedRange = CFRange(location: location, length: length)
        default: throw HelperFailure.invalidRequest("selection_type must be text, cursor_before, or cursor_after.")
        }
        var mutableRange = selectedRange
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
            throw HelperFailure.invalidRequest("Could not create an Accessibility text range.")
        }
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
        guard status == .success else { throw HelperFailure.elementNotFound(ref) }
    }

    private func captureWindow(for app: NSRunningApplication) throws -> WindowCapture {
        guard CGPreflightScreenCaptureAccess() else { throw HelperFailure.screenCaptureNotGranted }
        guard let window = visibleWindow(for: app.processIdentifier),
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, window.id, [.bestResolution]) else {
            throw HelperFailure.captureFailed
        }
        let url = try saveCapture(image, prefix: "window")
        return WindowCapture(path: url.path, frame: window.frame, imageSize: CGSize(width: image.width, height: image.height))
    }

    private func captureDisplay(_ arguments: [String: Any]) throws -> [String: Any] {
        if !CGPreflightScreenCaptureAccess() {
            let granted = CGRequestScreenCaptureAccess()
            return [
                "screen_capture_granted": granted,
                "needs_helper_restart": granted
            ]
        }

        let displays = activeDisplays()
        let requestedIndex = int(arguments, "display", default: 1)
        guard requestedIndex > 0, requestedIndex <= displays.count else {
            throw HelperFailure.invalidRequest(
                "Display index \(requestedIndex) is unavailable; active display count is \(displays.count)."
            )
        }
        let displayID = displays[requestedIndex - 1]
        guard let image = CGDisplayCreateImage(displayID) else {
            throw HelperFailure.captureFailed
        }
        let frame = CGDisplayBounds(displayID)
        let url = try saveCapture(image, prefix: "display-\(requestedIndex)")
        let capture = WindowCapture(
            path: url.path,
            frame: frame,
            imageSize: CGSize(width: image.width, height: image.height)
        )
        return [
            "display": requestedIndex,
            "display_count": displays.count,
            "screenshot": capture.dictionary
        ]
    }

    private func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return [CGMainDisplayID()]
        }
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return [CGMainDisplayID()]
        }
        return Array(displays.prefix(Int(count)))
    }

    private func visibleWindow(for pid: pid_t) -> (id: CGWindowID, frame: CGRect)? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? Int, owner == Int(pid),
                  let number = window[kCGWindowNumber as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            if frame.width > 20, frame.height > 20 { return (CGWindowID(number), frame) }
        }
        return nil
    }

    private func saveCapture(_ image: CGImage, prefix: String) throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".willdeep/tmp/computer-use-captures", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        purgeOldCaptures(in: root)
        let url = root.appendingPathComponent("\(prefix)-\(UUID().uuidString.lowercased()).jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw HelperFailure.captureFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw HelperFailure.captureFailed }
        return url
    }

    private func purgeOldCaptures(in directory: URL) {
        let threshold = Date().addingTimeInterval(-15 * 60)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in entries where (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantFuture < threshold {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func resolveApplication(_ arguments: [String: Any]) throws -> NSRunningApplication {
        if let pid = arguments["pid"] as? Int, let app = NSRunningApplication(processIdentifier: pid_t(pid)) { return app }
        let identifier = try requiredString(arguments, "app")
        guard let app = resolveRunningApplication(identifier) else { throw HelperFailure.appNotFound(identifier) }
        return app
    }

    private func resolveRunningApplication(_ identifier: String) -> NSRunningApplication? {
        let normalized = identifier.lowercased()
        return NSWorkspace.shared.runningApplications.first { app in
            app.bundleIdentifier?.lowercased() == normalized || app.localizedName?.lowercased() == normalized
        }
    }

    private func appDictionary(_ app: NSRunningApplication, launched: Bool) -> [String: Any] {
        ["pid": Int(app.processIdentifier), "bundle_id": app.bundleIdentifier ?? "", "name": app.localizedName ?? "Unknown", "launched": launched]
    }

    private func targetPID(_ arguments: [String: Any]) throws -> pid_t {
        if let pid = arguments["pid"] as? Int { return pid_t(pid) }
        if let identifier = arguments["app"] as? String,
           let app = resolveRunningApplication(identifier) {
            return app.processIdentifier
        }
        if let ref = arguments["ref"] as? String, let element = elements[ref] {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            if pid > 0 { return pid }
        }
        throw HelperFailure.invalidRequest("A pid or current snapshot ref is required.")
    }

    private func point(_ arguments: [String: Any], prefix: String = "", pid: pid_t) throws -> CGPoint {
        let x = number(arguments, "\(prefix)x")
        let y = number(arguments, "\(prefix)y")
        guard let x, let y else { throw HelperFailure.invalidRequest("Missing \(prefix)x/\(prefix)y coordinates.") }
        let coordinateSpace = arguments["coordinate_space"] as? String ?? "screenshot"
        guard coordinateSpace == "screenshot", let snapshot = snapshots[pid] else { return CGPoint(x: x, y: y) }
        return CGPoint(x: snapshot.windowFrame.minX + x * snapshot.windowFrame.width / snapshot.imageSize.width, y: snapshot.windowFrame.minY + y * snapshot.windowFrame.height / snapshot.imageSize.height)
    }

    private func postMouse(_ type: CGEventType, point: CGPoint, pid: pid_t) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: type == .rightMouseDown || type == .rightMouseUp ? .right : .left)?.postToPid(pid)
    }

    private func requireAccessibility() throws {
        guard AXIsProcessTrusted() else { throw HelperFailure.accessibilityNotGranted }
    }
}

private struct WindowCapture {
    let path: String
    let frame: CGRect
    let imageSize: CGSize

    var dictionary: [String: Any] {
        ["path": path, "pixel_width": Int(imageSize.width), "pixel_height": Int(imageSize.height), "frame": ["x": frame.origin.x, "y": frame.origin.y, "width": frame.width, "height": frame.height]]
    }
}

private struct KeyStroke {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    static func parse(_ raw: String) throws -> KeyStroke {
        let tokens = raw.lowercased().split(separator: "+").map(String.init)
        guard let key = tokens.last, !key.isEmpty else { throw HelperFailure.invalidRequest("Invalid key: \(raw)") }
        var flags: CGEventFlags = []
        for modifier in tokens.dropLast() {
            switch modifier {
            case "cmd", "command", "super": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            default: throw HelperFailure.invalidRequest("Unknown key modifier: \(modifier)")
            }
        }
        guard let code = keyCodes[key] else { throw HelperFailure.invalidRequest("Unsupported key: \(key)") }
        return KeyStroke(keyCode: code, flags: flags)
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20,
        "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "return": 36,
        "enter": 36, "escape": 53, "backspace": 51, "delete": 51, "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "f1": 122, "f2": 120, "f3": 99, "f4": 118
    ]
}

private func attributeValue(_ element: AXUIElement, _ attribute: String) -> Any? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
}

private func elementFrame(_ element: AXUIElement) -> CGRect? {
    guard let rawPositionValue = attributeValue(element, kAXPositionAttribute),
          CFGetTypeID(rawPositionValue as CFTypeRef) == AXValueGetTypeID(),
          let rawSizeValue = attributeValue(element, kAXSizeAttribute),
          CFGetTypeID(rawSizeValue as CFTypeRef) == AXValueGetTypeID() else {
        return nil
    }
    let positionValue = rawPositionValue as! AXValue
    let sizeValue = rawSizeValue as! AXValue
    guard AXValueGetType(positionValue) == .cgPoint,
          AXValueGetType(sizeValue) == .cgSize else {
        return nil
    }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue, .cgPoint, &origin),
          AXValueGetValue(sizeValue, .cgSize, &size),
          origin.x.isFinite, origin.y.isFinite,
          size.width.isFinite, size.height.isFinite else {
        return nil
    }
    return CGRect(origin: origin, size: size)
}

private func frameDictionary(_ frame: CGRect) -> [String: CGFloat] {
    ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
}

private func copyActionNames(_ element: AXUIElement) -> [String] {
    var actions: CFArray?
    return AXUIElementCopyActionNames(element, &actions) == .success ? (actions as? [String] ?? []) : []
}

private func printable(_ value: Any) -> Any {
    if let text = value as? String { return String(text.prefix(maximumTextLength)) }
    if let number = value as? NSNumber { return number }
    return String(describing: value).prefix(maximumTextLength).description
}

private func normalizedAttributeName(_ attribute: String) -> String {
    attribute.replacingOccurrences(of: "AX", with: "").replacingOccurrences(of: " ", with: "_").lowercased()
}

private func requiredString(_ dictionary: [String: Any], _ key: String) throws -> String {
    guard let value = dictionary[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw HelperFailure.invalidRequest("Missing \(key).")
    }
    return value
}

private func bool(_ dictionary: [String: Any], _ key: String, default fallback: Bool) -> Bool { dictionary[key] as? Bool ?? fallback }
private func int(_ dictionary: [String: Any], _ key: String, default fallback: Int) -> Int { dictionary[key] as? Int ?? fallback }
private func number(_ dictionary: [String: Any], _ key: String) -> CGFloat? {
    if let value = dictionary[key] as? Double { return value }
    if let value = dictionary[key] as? Int { return CGFloat(value) }
    return nil
}

private let controller = ComputerUseController()
while let line = readLine() {
    var requestID = ""
    let response: [String: Any]
    do {
        guard let data = line.data(using: .utf8),
              let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HelperFailure.invalidRequest("Request must be a JSON object.")
        }
        requestID = request["id"] as? String ?? ""
        response = ["id": requestID, "ok": true, "result": try controller.handle(request)]
    } catch {
        response = ["id": requestID, "ok": false, "error": error.localizedDescription]
    }
    if let data = try? JSONSerialization.data(withJSONObject: response), let text = String(data: data, encoding: .utf8) {
        print(text)
        fflush(stdout)
    }
}
