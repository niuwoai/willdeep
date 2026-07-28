import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let protocolVersion = "willdeep-computer-use.v6"
private let maximumElementCount = 500
private let maximumDepth = 12
private let maximumTextLength = 500
private let maximumWindowCaptureLongEdge = 1_568
private let maximumProcessPathBytes = 4 * 1_024
private let snapshotLifetime: TimeInterval = 60
private let axMessagingTimeoutSeconds: Float = 2
private let syntheticEventUserDataTag: Int64 = 0x5744_4355_5636
private let axWindowNumberAttribute = "AXWindowNumber"
private let forbiddenControlBundleIdentifiers: Set<String> = [
    "com.willdeep.app",
    "com.apple.terminal",
    "com.googlecode.iterm2",
    "dev.warp.warp",
    "dev.warp.warp-stable",
    "org.alacritty",
    "io.alacritty",
    "net.kovidgoyal.kitty",
    "com.github.wez.wezterm",
    "org.wezfurlong.wezterm",
    "com.mitchellh.ghostty",
    "co.zeit.hyper"
]
private let forbiddenControlApplicationNames: Set<String> = [
    "willdeep",
    "terminal",
    "iterm",
    "iterm2",
    "warp",
    "alacritty",
    "kitty",
    "wezterm",
    "ghostty",
    "hyper"
]

private final class ProtocolWriter {
    static let shared = ProtocolWriter()

    private let lock = NSLock()

    func write(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else {
            return
        }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}

private final class PhysicalInputMonitor {
    private let onUserInput: (String, CGPoint?) -> Void
    private let stateLock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoop: CFRunLoop?

    init(onUserInput: @escaping (String, CGPoint?) -> Void) {
        self.onUserInput = onUserInput
    }

    func start() {
        Thread.detachNewThread { [self] in
            autoreleasepool {
                run()
            }
        }
    }

    func stop() {
        stateLock.lock()
        let eventTap = eventTap
        let runLoop = runLoop
        self.eventTap = nil
        self.runLoop = nil
        stateLock.unlock()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }

    private func run() {
        let observedTypes: [CGEventType] = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .keyDown,
            .scrollWheel
        ]
        let mask = observedTypes.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                return Unmanaged<PhysicalInputMonitor>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }
        let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        )
        let runLoop = CFRunLoopGetCurrent()
        stateLock.lock()
        self.eventTap = eventTap
        self.runLoop = runLoop
        stateLock.unlock()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        CFRunLoopRun()
        CGEvent.tapEnable(tap: eventTap, enable: false)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
    }

    private func handle(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stateLock.lock()
            let eventTap = eventTap
            stateLock.unlock()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData)
                != syntheticEventUserDataTag else {
            return Unmanaged.passUnretained(event)
        }
        let kind: String
        switch type {
        case .keyDown:
            kind = "key_down"
        case .scrollWheel:
            kind = "scroll"
        default:
            kind = "mouse_down"
        }
        onUserInput(kind, kind == "key_down" ? nil : event.location)
        return Unmanaged.passUnretained(event)
    }
}

private enum HelperFailure: LocalizedError {
    case invalidRequest(String)
    case appNotFound(String)
    case accessibilityNotGranted
    case elementNotFound(String)
    case controlLeaseRequired
    case controlLeaseBusy
    case controlLeaseMismatch
    case controlSessionPaused
    case controlTargetMismatch
    case forbiddenControlTarget(String)
    case controlEpochChanged
    case displayCaptureBlocked
    case actionDeclarationMismatch(String)
    case clipboardAccessRejected
    case terminalSurfaceRejected
    case secureInputRejected
    case staleSnapshot(String)
    case unsupportedAction(String)
    case screenCaptureNotGranted
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): return message
        case .appNotFound(let app): return "App not found: \(app)"
        case .accessibilityNotGranted: return "Accessibility permission is not granted to WillDeep Computer Use."
        case .elementNotFound(let ref): return "The accessibility element is stale or missing: \(ref)"
        case .controlLeaseRequired: return "A non-empty control_lease_id is required for this Computer Use action."
        case .controlLeaseBusy: return "Computer Use is already controlled by another active lease."
        case .controlLeaseMismatch: return "The Computer Use control lease is missing, stale, or owned by another session."
        case .controlSessionPaused: return "The Computer Use control session is paused; resume it before inspecting or acting."
        case .controlTargetMismatch: return "The requested app or PID does not match the active Computer Use control target."
        case .forbiddenControlTarget(let target): return "Computer Use is not allowed to control WillDeep or terminal surfaces: \(target)."
        case .controlEpochChanged: return "Computer Use yielded to physical user input; discard this result and refresh after resuming."
        case .displayCaptureBlocked: return "Display capture is disabled while a Computer Use control session exists."
        case .actionDeclarationMismatch(let reason): return "Computer Use rejected a high-impact AX target because the declared consequence or target_label does not match: \(reason). Refresh, declare the real impact, and request per-action confirmation."
        case .clipboardAccessRejected: return "Computer Use cannot read or mutate the system clipboard. Type non-sensitive text explicitly or ask the user to take over."
        case .terminalSurfaceRejected: return "Computer Use cannot inspect or type into terminal, shell, or console surfaces. Use the governed command tools instead."
        case .secureInputRejected: return "Computer Use cannot inspect or mutate a secure text input."
        case .staleSnapshot(let reason): return "stale_snapshot: \(reason). Refresh with get_app_state before acting."
        case .unsupportedAction(let action): return "Unsupported computer-use action: \(action)"
        case .screenCaptureNotGranted: return "Screen & System Audio Recording permission is not granted to WillDeep Computer Use."
        case .captureFailed: return "Could not capture the target window."
        }
    }
}

private final class ComputerUseController {
    private struct ControlSession {
        let leaseID: String
        let targetIdentifier: String?
        var pid: pid_t?
        var bundleID: String?
        var launchDate: Date?
        var windowID: CGWindowID?
        var windowFrame: CGRect?
        var isPaused: Bool
        var epoch: UInt64
    }

    private struct ControlEpoch: Equatable {
        let leaseID: String
        let sessionEpoch: UInt64
        let physicalInputEpoch: UInt64
    }

    private struct VisibleWindow {
        let id: CGWindowID
        let ownerPID: pid_t
        let frame: CGRect
    }

    private struct ElementReference {
        let element: AXUIElement
        let windowID: CGWindowID
        let redactsContent: Bool
    }

    private struct ActiveMutation {
        let id: UInt64
        let controlEpoch: ControlEpoch
    }

    private struct Snapshot {
        let id: String
        let pid: pid_t
        let bundleID: String?
        let appLaunchDate: Date?
        let windowID: CGWindowID
        let windowFrame: CGRect
        let coordinateImageSize: CGSize?
        let capturedAt: Date
        let controlEpoch: ControlEpoch
    }

    private(set) var shouldExit = false
    private let controlSessionLock = NSLock()
    private let physicalInputEpochLock = NSLock()
    private var controlSession: ControlSession?
    private var nextControlSessionEpoch: UInt64 = 0
    private var physicalInputEpoch: UInt64 = 0
    private var nextMutationID: UInt64 = 0
    private var activeMutation: ActiveMutation?
    private var elements: [String: ElementReference] = [:]
    private var activeSnapshot: Snapshot?
    private var pendingResponseEpoch: ControlEpoch?

    func handlePhysicalUserInput(
        _ kind: String,
        location: CGPoint?
    ) {
        controlSessionLock.lock()
        let observedSession = controlSession
        controlSessionLock.unlock()
        guard let observedSession, !observedSession.isPaused else {
            return
        }
        let targetIsFrontmost = observedSession.pid.map {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == $0
        } ?? false
        let shouldPause: Bool
        if kind == "mouse_down" || kind == "scroll" {
            shouldPause = location.flatMap {
                topmostVisibleWindow(at: $0)
            }.map {
                $0.ownerPID == observedSession.pid
                    && !isForbiddenProcessID($0.ownerPID)
            } ?? false
        } else {
            shouldPause = targetIsFrontmost
                && observedSession.pid.map {
                    !isForbiddenProcessID($0)
                } == true
        }
        guard shouldPause else { return }

        physicalInputEpochLock.lock()
        controlSessionLock.lock()
        guard var session = controlSession,
              session.leaseID == observedSession.leaseID,
              session.epoch == observedSession.epoch,
              !session.isPaused else {
            controlSessionLock.unlock()
            physicalInputEpochLock.unlock()
            return
        }
        physicalInputEpoch &+= 1
        let observedPhysicalInputEpoch = physicalInputEpoch
        session.isPaused = true
        session.windowID = nil
        session.windowFrame = nil
        session.epoch = nextSessionEpochLocked()
        controlSession = session
        controlSessionLock.unlock()
        physicalInputEpochLock.unlock()

        var event: [String: Any] = [
            "event": "user_input",
            "protocol_version": protocolVersion,
            "control_lease_id": session.leaseID,
            "input_kind": kind,
            "paused": true,
            "control_epoch": Int(session.epoch),
            "physical_input_epoch": Int(observedPhysicalInputEpoch)
        ]
        if let location {
            event["input_x"] = location.x
            event["input_y"] = location.y
        }
        ProtocolWriter.shared.write(event)
    }

    func handle(_ request: [String: Any]) throws -> [String: Any] {
        pendingResponseEpoch = nil
        guard let action = request["action"] as? String else {
            throw HelperFailure.invalidRequest("Missing action.")
        }
        let arguments = request["arguments"] as? [String: Any] ?? [:]
        let leaseID = normalizedLeaseID(request["control_lease_id"])
        switch action {
        case "permissions":
            return permissionStatus()
        case "request_permissions":
            return requestPermissions(arguments)
        case "capture_display":
            return try captureDisplay(arguments)
        case "list_apps":
            return listApps()
        case "start_control_session":
            return try startControlSession(arguments, leaseID: leaseID)
        case "pause_control_session":
            return try pauseControlSession(leaseID: leaseID)
        case "resume_control_session":
            return try resumeControlSession(leaseID: leaseID)
        case "end_control_session":
            return try endControlSession(leaseID: leaseID)
        case "launch_app":
            return try launchApp(arguments, leaseID: leaseID)
        case "activate_app":
            return try activateApp(arguments, leaseID: leaseID)
        case "get_app_state":
            return try getAppState(arguments, leaseID: leaseID)
        case "wait_for":
            return try waitFor(arguments, leaseID: leaseID)
        case "click", "secondary_action", "scroll", "drag", "type_text", "press_key", "set_value", "focus", "hover", "select_text":
            return try perform(action: action, arguments: arguments, leaseID: leaseID)
        case "shutdown":
            shouldExit = true
            return ["shutdown": true]
        default:
            throw HelperFailure.unsupportedAction(action)
        }
    }

    func writeSuccessResponse(
        requestID: String,
        result: [String: Any]
    ) throws {
        defer { pendingResponseEpoch = nil }
        guard let epoch = pendingResponseEpoch else {
            ProtocolWriter.shared.write([
                "id": requestID,
                "ok": true,
                "result": result
            ])
            return
        }

        physicalInputEpochLock.lock()
        defer { physicalInputEpochLock.unlock() }
        controlSessionLock.lock()
        defer { controlSessionLock.unlock() }
        try validateControlEpochLocked(epoch)
        ProtocolWriter.shared.write([
            "id": requestID,
            "ok": true,
            "result": result
        ])
    }

    func clearPendingResponseEpoch() {
        pendingResponseEpoch = nil
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

    private func startControlSession(
        _ arguments: [String: Any],
        leaseID: String?
    ) throws -> [String: Any] {
        let leaseID = try requiredLeaseID(leaseID)
        discardDeadControlSessionIfNeeded()

        let requestedPID = arguments["pid"] as? Int
        let requestedIdentifier = (arguments["app"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard requestedPID != nil || !(requestedIdentifier ?? "").isEmpty else {
            throw HelperFailure.invalidRequest(
                "start_control_session requires pid or app."
            )
        }
        if let requestedPID {
            try ensureAllowedControlPID(pid_t(requestedPID))
        }
        if let requestedIdentifier, !requestedIdentifier.isEmpty {
            try ensureAllowedControlIdentifier(requestedIdentifier)
        }

        controlSessionLock.lock()
        defer { controlSessionLock.unlock() }
        if let existing = controlSession {
            guard existing.leaseID == leaseID else {
                throw HelperFailure.controlLeaseBusy
            }
            if let requestedPID, existing.pid != pid_t(requestedPID) {
                throw HelperFailure.controlTargetMismatch
            }
            if let requestedIdentifier,
               !requestedIdentifier.isEmpty,
               !sessionMatchesIdentifier(existing, requestedIdentifier) {
                throw HelperFailure.controlTargetMismatch
            }
            return controlSessionDictionary(existing)
        }

        let runningApp: NSRunningApplication?
        if let requestedPID {
            guard let app = NSRunningApplication(
                processIdentifier: pid_t(requestedPID)
            ), !app.isTerminated else {
                throw HelperFailure.appNotFound(String(requestedPID))
            }
            try ensureAllowedControlApplication(app)
            runningApp = app
        } else if let requestedIdentifier {
            runningApp = resolveRunningApplication(requestedIdentifier)
            if let runningApp {
                try ensureAllowedControlApplication(runningApp)
            }
        } else {
            runningApp = nil
        }

        let session = ControlSession(
            leaseID: leaseID,
            targetIdentifier: requestedIdentifier,
            pid: runningApp?.processIdentifier,
            bundleID: runningApp?.bundleIdentifier,
            launchDate: runningApp?.launchDate,
            windowID: nil,
            windowFrame: nil,
            isPaused: false,
            epoch: nextSessionEpochLocked()
        )
        controlSession = session
        invalidateSnapshot()
        return controlSessionDictionary(session)
    }

    private func pauseControlSession(leaseID: String?) throws -> [String: Any] {
        let leaseID = try requiredLeaseID(leaseID)
        controlSessionLock.lock()
        defer { controlSessionLock.unlock() }
        guard var session = controlSession, session.leaseID == leaseID else {
            throw HelperFailure.controlLeaseMismatch
        }
        session.isPaused = true
        session.windowID = nil
        session.windowFrame = nil
        session.epoch = nextSessionEpochLocked()
        controlSession = session
        invalidateSnapshot()
        return controlSessionDictionary(session)
    }

    private func resumeControlSession(leaseID: String?) throws -> [String: Any] {
        let leaseID = try requiredLeaseID(leaseID)
        controlSessionLock.lock()
        defer { controlSessionLock.unlock() }
        guard var session = controlSession, session.leaseID == leaseID else {
            throw HelperFailure.controlLeaseMismatch
        }
        session.isPaused = false
        session.windowID = nil
        session.windowFrame = nil
        session.epoch = nextSessionEpochLocked()
        controlSession = session
        invalidateSnapshot()
        return controlSessionDictionary(session)
    }

    private func endControlSession(leaseID: String?) throws -> [String: Any] {
        let leaseID = try requiredLeaseID(leaseID)
        controlSessionLock.lock()
        defer { controlSessionLock.unlock() }
        guard let session = controlSession, session.leaseID == leaseID else {
            throw HelperFailure.controlLeaseMismatch
        }
        _ = nextSessionEpochLocked()
        controlSession = nil
        invalidateSnapshot()
        return [
            "control_lease_id": session.leaseID,
            "ended": true
        ]
    }

    private func launchApp(
        _ arguments: [String: Any],
        leaseID: String?
    ) throws -> [String: Any] {
        let leaseID = try requiredLeaseID(leaseID)
        _ = try requireControlSession(leaseID: leaseID)
        let identifier = try requiredString(arguments, "app")
        try ensureAllowedControlIdentifier(identifier)
        try requireControlTarget(identifier: identifier, leaseID: leaseID)
        if let running = resolveRunningApplication(identifier) {
            try bindControlSession(to: running, leaseID: leaseID)
            pendingResponseEpoch = try captureControlEpoch(
                leaseID: leaseID
            )
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
        case .success(let app):
            try bindControlSession(to: app, leaseID: leaseID)
            pendingResponseEpoch = try captureControlEpoch(
                leaseID: leaseID
            )
            return appDictionary(app, launched: true)
        case .failure(let error): throw error
        case .none: throw HelperFailure.appNotFound(identifier)
        }
    }

    private func activateApp(
        _ arguments: [String: Any],
        leaseID: String?
    ) throws -> [String: Any] {
        let leaseID = try requiredLeaseID(leaseID)
        let app = try controlledApplication(arguments, leaseID: leaseID)
        let controlEpoch = try captureControlEpoch(leaseID: leaseID)
        let activated = try withControlMutation(controlEpoch) {
            app.activate(
                options: [
                    .activateAllWindows,
                    .activateIgnoringOtherApps
                ]
            )
        }
        guard activated else {
            throw HelperFailure.invalidRequest("Could not activate \(app.localizedName ?? "the target app").")
        }
        pendingResponseEpoch = controlEpoch
        return appDictionary(app, launched: false).merging(["activated": true]) { _, new in new }
    }

    private func getAppState(
        _ arguments: [String: Any],
        leaseID: String?
    ) throws -> [String: Any] {
        try requireAccessibility()
        let leaseID = try requiredLeaseID(leaseID)
        let app = try controlledApplication(arguments, leaseID: leaseID)
        let controlEpoch = try captureControlEpoch(leaseID: leaseID)
        let includeScreenshot = bool(arguments, "include_screenshot", default: true)
        if includeScreenshot,
           !CGPreflightScreenCaptureAccess() {
            throw HelperFailure.screenCaptureNotGranted
        }
        guard let currentWindow = visibleWindow(for: app.processIdentifier) else {
            throw HelperFailure.captureFailed
        }
        try updateControlWindow(
            currentWindow,
            leaseID: leaseID
        )
        let axWindow = try accessibilityWindow(
            for: app,
            matching: currentWindow
        )
        invalidateSnapshot()
        let snapshotID = UUID().uuidString.lowercased()
        let counter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        counter.initialize(to: 0)
        let tree = buildTree(
            element: axWindow,
            snapshotID: snapshotID,
            windowID: currentWindow.id,
            ancestorRedacted: false,
            depth: 0,
            counter: counter
        )
        var result: [String: Any] = [
            "app": appDictionary(app, launched: false),
            "snapshot_id": snapshotID,
            "snapshot_ttl_ms": Int(snapshotLifetime * 1_000),
            "control_lease_id": leaseID,
            "tree": tree
        ]
        let capture: WindowCapture?
        if includeScreenshot {
            switch SensitiveAccessibilityScanner.scan(root: axWindow) {
            case .complete(let sensitiveFrames):
                let capturedWindow = try captureWindow(
                    currentWindow,
                    sensitiveFrames: sensitiveFrames
                )
                capture = capturedWindow
                result["screenshot"] = capturedWindow.dictionary.merging([
                    "snapshot_id": snapshotID
                ]) { _, new in new }
            case .incomplete:
                capture = nil
                result["screenshot"] = NSNull()
                result["screenshot_omitted_reason"] =
                    "sensitive_accessibility_scan_incomplete"
            }
        } else {
            capture = nil
            result["screenshot"] = NSNull()
        }
        try validateVisibleWindow(
            currentWindow,
            pid: app.processIdentifier
        )
        try validateControlEpoch(controlEpoch)
        result["window"] = [
            "id": Int(currentWindow.id),
            "frame": frameDictionary(currentWindow.frame)
        ]
        activeSnapshot = Snapshot(
            id: snapshotID,
            pid: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            appLaunchDate: app.launchDate,
            windowID: currentWindow.id,
            windowFrame: currentWindow.frame,
            coordinateImageSize: capture?.imageSize,
            capturedAt: Date(),
            controlEpoch: controlEpoch
        )
        try updateControlWindow(
            currentWindow,
            leaseID: leaseID
        )
        pendingResponseEpoch = controlEpoch
        return result
    }

    private func waitFor(
        _ arguments: [String: Any],
        leaseID: String?
    ) throws -> [String: Any] {
        try requireAccessibility()
        let leaseID = try requiredLeaseID(leaseID)
        let condition = try requiredString(arguments, "condition")
        let timeoutMilliseconds = max(100, min(int(arguments, "timeout_ms", default: 5_000), 15_000))
        let pollMilliseconds = max(50, min(int(arguments, "poll_ms", default: 100), 1_000))
        let expected = arguments["expected"] as? String ?? ""
        let ref = arguments["ref"] as? String
        let app = try controlledApplication(arguments, leaseID: leaseID)
        let pid = app.processIdentifier
        let controlEpoch = try captureControlEpoch(leaseID: leaseID)
        if ref != nil {
            _ = try validateActiveSnapshot(
                arguments,
                leaseID: leaseID,
                requireCoordinateImage: false
            )
        }
        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)

        repeat {
            try validateControlEpoch(controlEpoch)
            let matchedValue: String?
            switch condition {
            case "ref_exists":
                guard let ref else { throw HelperFailure.invalidRequest("ref_exists requires ref.") }
                matchedValue = elements[ref]
                    .flatMap {
                        attributeValue(
                            $0.element,
                            kAXRoleAttribute
                        )
                    }
                    .map { _ in "true" }
            case "value_contains":
                guard let ref else { throw HelperFailure.invalidRequest("value_contains requires ref.") }
                guard !expected.isEmpty else { throw HelperFailure.invalidRequest("value_contains requires expected.") }
                guard let elementReference = elements[ref] else {
                    throw HelperFailure.elementNotFound(ref)
                }
                guard !elementReference.redactsContent else {
                    throw HelperFailure.secureInputRejected
                }
                let element = elementReference.element
                matchedValue = attributeValue(element, kAXValueAttribute)
                    .map { String(describing: printable($0)) }
                    .flatMap { $0.localizedCaseInsensitiveContains(expected) ? $0 : nil }
            case "title_contains":
                guard !expected.isEmpty else { throw HelperFailure.invalidRequest("title_contains requires expected.") }
                let axApplication = AXUIElementCreateApplication(pid)
                _ = AXUIElementSetMessagingTimeout(
                    axApplication,
                    axMessagingTimeoutSeconds
                )
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
                return try getAppState(
                    [
                        "pid": Int(pid),
                        "include_screenshot": bool(arguments, "include_screenshot", default: false)
                    ],
                    leaseID: leaseID
                ).merging([
                    "waited_condition": condition,
                    "matched_value": matchedValue,
                    "timeout_ms": timeoutMilliseconds
                ]) { _, new in new }
            }
            Thread.sleep(forTimeInterval: Double(pollMilliseconds) / 1_000)
        } while Date() < deadline

        throw HelperFailure.invalidRequest("Timed out waiting for \(condition) after \(timeoutMilliseconds) ms.")
    }

    private func perform(
        action: String,
        arguments: [String: Any],
        leaseID: String?
    ) throws -> [String: Any] {
        try requireAccessibility()
        let leaseID = try requiredLeaseID(leaseID)
        let requiresCoordinateImage: Bool
        switch action {
        case "drag":
            requiresCoordinateImage = true
        case "click", "secondary_action", "hover":
            requiresCoordinateImage = arguments["ref"] == nil
        default:
            requiresCoordinateImage = false
        }
        if requiresCoordinateImage,
           !CGPreflightScreenCaptureAccess() {
            throw HelperFailure.screenCaptureNotGranted
        }
        let snapshot = try validateActiveSnapshot(
            arguments,
            leaseID: leaseID,
            requireCoordinateImage: requiresCoordinateImage
        )
        try validateHighImpactActionDeclaration(
            action: action,
            arguments: arguments
        )
        let pid = snapshot.pid
        switch action {
        case "click":
            try click(
                arguments,
                pid: pid,
                epoch: snapshot.controlEpoch
            )
        case "secondary_action":
            try secondaryAction(
                arguments,
                pid: pid,
                epoch: snapshot.controlEpoch
            )
        case "scroll":
            try scroll(
                arguments,
                pid: pid,
                epoch: snapshot.controlEpoch
            )
        case "drag":
            try drag(
                arguments,
                pid: pid,
                epoch: snapshot.controlEpoch
            )
        case "type_text":
            try typeText(
                arguments,
                pid: pid,
                epoch: snapshot.controlEpoch
            )
        case "press_key":
            try pressKey(
                arguments,
                pid: pid,
                epoch: snapshot.controlEpoch
            )
        case "set_value":
            try setValue(arguments, epoch: snapshot.controlEpoch)
        case "focus":
            try focus(arguments, epoch: snapshot.controlEpoch)
        case "hover":
            try hover(
                arguments,
                pid: pid,
                epoch: snapshot.controlEpoch
            )
        case "select_text":
            try selectText(arguments, epoch: snapshot.controlEpoch)
        default: throw HelperFailure.unsupportedAction(action)
        }
        let app = try controlledApplication(["pid": Int(pid)], leaseID: leaseID)
        return try getAppState(
            [
                "pid": Int(app.processIdentifier),
                "include_screenshot":
                    snapshot.coordinateImageSize != nil
                        && CGPreflightScreenCaptureAccess()
            ],
            leaseID: leaseID
        ).merging([
            "performed_action": action,
            "target_pid": Int(pid)
        ]) { _, new in new }
    }

    private func buildTree(
        element: AXUIElement,
        snapshotID: String,
        windowID: CGWindowID,
        ancestorRedacted: Bool,
        depth: Int,
        counter: UnsafeMutablePointer<Int>
    ) -> [String: Any] {
        defer {
            if depth == 0 { counter.deallocate() }
        }
        counter.pointee += 1
        let ref = "\(snapshotID):e\(counter.pointee)"
        let isSensitiveContent = ancestorRedacted
            || isSecureInputElement(element)
            || isTerminalSurfaceElement(element)
        elements[ref] = ElementReference(
            element: element,
            windowID: windowID,
            redactsContent: isSensitiveContent
        )
        var result: [String: Any] = ["ref": ref]
        let redactedContentAttributes: Set<String> = [
            kAXIdentifierAttribute,
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
            kAXValueAttribute
        ]
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
            if isSensitiveContent,
               redactedContentAttributes.contains(attribute) {
                continue
            }
            if let value = attributeValue(element, attribute) {
                result[normalizedAttributeName(attribute)] = printable(value)
            }
        }
        if isSensitiveContent {
            result["value_redacted"] = true
            result["screenshot_redacted"] = true
            result["content_redacted"] = true
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
            buildTree(
                element: child,
                snapshotID: snapshotID,
                windowID: windowID,
                ancestorRedacted: isSensitiveContent,
                depth: depth + 1,
                counter: counter
            )
        }
        if !entries.isEmpty { result["children"] = entries }
        return result
    }

    private func isSecureInputElement(_ element: AXUIElement) -> Bool {
        SensitiveAccessibilityScanner.isSecureInputElement(element)
    }

    private func isTerminalSurfaceElement(
        _ element: AXUIElement
    ) -> Bool {
        SensitiveAccessibilityScanner.isTerminalSurfaceElement(element)
    }

    private func isWithinTerminalSurface(
        _ element: AXUIElement
    ) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let candidate = current else { break }
            if isTerminalSurfaceElement(candidate) {
                return true
            }
            guard let parent = attributeValue(
                candidate,
                kAXParentAttribute
            ),
            CFGetTypeID(parent as CFTypeRef) == AXUIElementGetTypeID() else {
                break
            }
            let parentElement = parent as! AXUIElement
            if CFEqual(candidate, parentElement) {
                break
            }
            current = parentElement
        }
        return false
    }

    private enum HighImpactAXCategory: String {
        case send
        case delete
        case purchase
        case permissionChange = "permission_change"
        case accountChange = "account_change"

        var acceptedConsequences: Set<String> {
            switch self {
            case .send:
                return ["send", "sensitive_data_transfer"]
            case .delete:
                return ["delete", "account_change"]
            case .purchase:
                return ["purchase", "financial_transaction"]
            case .permissionChange:
                return ["permission_change"]
            case .accountChange:
                return ["account_change", "authentication"]
            }
        }

        var keywords: [String] {
            switch self {
            case .send:
                return [
                    "send", "submit", "publish", "post", "reply",
                    "发送", "提交", "发布", "回复"
                ]
            case .delete:
                return [
                    "delete", "remove", "erase", "trash", "destroy",
                    "删除", "移除", "清空", "抹掉"
                ]
            case .purchase:
                return [
                    "pay", "buy", "purchase", "checkout", "place order",
                    "subscribe", "transfer", "donate",
                    "支付", "付款", "购买", "下单", "结账", "订阅", "转账"
                ]
            case .permissionChange:
                return [
                    "authorize", "approve", "allow", "grant", "permission",
                    "consent", "oauth", "授权", "批准", "允许", "授予", "权限", "同意"
                ]
            case .accountChange:
                return [
                    "account", "sign in", "sign up", "login", "log in",
                    "register", "账户", "账号", "登录", "注册", "注销"
                ]
            }
        }
    }

    private func validateHighImpactActionDeclaration(
        action: String,
        arguments: [String: Any]
    ) throws {
        guard action == "click" || action == "secondary_action" else {
            return
        }
        guard let ref = arguments["ref"] as? String,
              let element = elements[ref]?.element else {
            return
        }
        let metadataValues = [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXIdentifierAttribute,
            kAXHelpAttribute,
            kAXRoleAttribute,
            kAXSubroleAttribute
        ]
        .compactMap { attributeValue(element, $0) }
        .map { String(describing: printable($0)).lowercased() }
            + copyActionNames(element).map { $0.lowercased() }
        let actualMetadata = metadataValues.joined(separator: " ")

        let clipboardKeywords = [
            "copy", "cut", "paste", "clipboard",
            "复制", "拷贝", "剪切", "粘贴", "剪贴板"
        ]
        if clipboardKeywords.contains(where: actualMetadata.contains) {
            throw HelperFailure.clipboardAccessRejected
        }

        guard let category = [
            HighImpactAXCategory.delete,
            .purchase,
            .permissionChange,
            .send,
            .accountChange
        ].first(where: { category in
            category.keywords.contains(where: actualMetadata.contains)
        }) else {
            return
        }

        let consequence = (arguments["consequence"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let targetLabel = (arguments["target_label"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard category.acceptedConsequences.contains(consequence) else {
            throw HelperFailure.actionDeclarationMismatch(
                "actual AX category=\(category.rawValue), consequence=\(consequence.isEmpty ? "missing" : consequence)"
            )
        }
        guard !targetLabel.isEmpty,
              category.keywords.contains(where: targetLabel.contains) else {
            throw HelperFailure.actionDeclarationMismatch(
                "actual AX category=\(category.rawValue), target_label does not name that impact"
            )
        }
    }

    private func focusedElement(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(
            application,
            axMessagingTimeoutSeconds
        )
        guard let raw = attributeValue(
            application,
            kAXFocusedUIElementAttribute
        ),
        CFGetTypeID(raw as CFTypeRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return (raw as! AXUIElement)
    }

    private func rejectSecureFocusedElement(pid: pid_t) throws {
        if let element = focusedElement(pid: pid),
           isSecureInputElement(element) {
            throw HelperFailure.secureInputRejected
        }
    }

    private func rejectTerminalFocusedElement(pid: pid_t) throws {
        if let element = focusedElement(pid: pid),
           isWithinTerminalSurface(element) {
            throw HelperFailure.terminalSurfaceRejected
        }
    }

    private func click(
        _ arguments: [String: Any],
        pid: pid_t,
        epoch: ControlEpoch
    ) throws {
        if let ref = arguments["ref"] as? String,
           let element = elements[ref]?.element {
            let clicks = max(
                1,
                min(3, int(arguments, "click_count", default: 1))
            )
            if clicks == 1 {
                let status = try withControlMutation(epoch) {
                    AXUIElementPerformAction(element, kAXPressAction as CFString)
                }
                if status == .success { return }
            }
            if let frame = elementFrame(element) {
                let center = CGPoint(x: frame.midX, y: frame.midY)
                try validatePointWithinSnapshot(center, pid: pid)
                try withControlMutation(epoch) {
                    for clickState in 1...clicks {
                        try validateMutationProgress(epoch)
                        postMouse(
                            .leftMouseDown,
                            point: center,
                            pid: pid,
                            clickState: clickState
                        )
                        do {
                            try validateMutationProgress(epoch)
                        } catch {
                            postMouse(
                                .leftMouseUp,
                                point: center,
                                pid: pid,
                                clickState: clickState
                            )
                            throw error
                        }
                        postMouse(
                            .leftMouseUp,
                            point: center,
                            pid: pid,
                            clickState: clickState
                        )
                    }
                }
                return
            }
            throw HelperFailure.elementNotFound(ref)
        }
        let point = try point(arguments, pid: pid)
        let clicks = max(1, min(3, int(arguments, "click_count", default: 1)))
        try withControlMutation(epoch) {
            for clickState in 1...clicks {
                try validateMutationProgress(epoch)
                postMouse(
                    .leftMouseDown,
                    point: point,
                    pid: pid,
                    clickState: clickState
                )
                do {
                    try validateMutationProgress(epoch)
                } catch {
                    postMouse(
                        .leftMouseUp,
                        point: point,
                        pid: pid,
                        clickState: clickState
                    )
                    throw error
                }
                postMouse(
                    .leftMouseUp,
                    point: point,
                    pid: pid,
                    clickState: clickState
                )
            }
        }
    }

    private func secondaryAction(
        _ arguments: [String: Any],
        pid: pid_t,
        epoch: ControlEpoch
    ) throws {
        if let ref = arguments["ref"] as? String,
           let element = elements[ref]?.element {
            let status = try withControlMutation(epoch) {
                AXUIElementPerformAction(
                    element,
                    kAXShowMenuAction as CFString
                )
            }
            if status == .success { return }
            if let frame = elementFrame(element) {
                let center = CGPoint(x: frame.midX, y: frame.midY)
                try validatePointWithinSnapshot(center, pid: pid)
                try withControlMutation(epoch) {
                    try validateMutationProgress(epoch)
                    postMouse(.rightMouseDown, point: center, pid: pid)
                    do {
                        try validateMutationProgress(epoch)
                    } catch {
                        postMouse(.rightMouseUp, point: center, pid: pid)
                        throw error
                    }
                    postMouse(.rightMouseUp, point: center, pid: pid)
                }
                return
            }
            throw HelperFailure.elementNotFound(ref)
        }
        let point = try point(arguments, pid: pid)
        try withControlMutation(epoch) {
            try validateMutationProgress(epoch)
            postMouse(.rightMouseDown, point: point, pid: pid)
            do {
                try validateMutationProgress(epoch)
            } catch {
                postMouse(.rightMouseUp, point: point, pid: pid)
                throw error
            }
            postMouse(.rightMouseUp, point: point, pid: pid)
        }
    }

    private func scroll(
        _ arguments: [String: Any],
        pid: pid_t,
        epoch: ControlEpoch
    ) throws {
        let direction = (arguments["direction"] as? String ?? "down").lowercased()
        let pages = max(1, min(8, int(arguments, "pages", default: 1)))
        let delta = (direction == "up" || direction == "left") ? 8 : -8
        let vertical = direction == "up" || direction == "down"
        try withControlMutation(epoch) {
            for _ in 0..<pages {
                try validateMutationProgress(epoch)
                let event = taggedSyntheticEvent(
                    CGEvent(
                        scrollWheelEvent2Source: nil,
                        units: .line,
                        wheelCount: 2,
                        wheel1: vertical ? Int32(delta) : 0,
                        wheel2: vertical ? 0 : Int32(delta),
                        wheel3: 0
                    )
                )
                event?.postToPid(pid)
            }
        }
    }

    private func drag(
        _ arguments: [String: Any],
        pid: pid_t,
        epoch: ControlEpoch
    ) throws {
        let from = try point(arguments, prefix: "from_", pid: pid)
        let to = try point(arguments, prefix: "to_", pid: pid)
        try withControlMutation(epoch) {
            try validateMutationProgress(epoch)
            postMouse(.leftMouseDown, point: from, pid: pid)
            do {
                try validateMutationProgress(epoch)
                postMouse(.leftMouseDragged, point: to, pid: pid)
                try validateMutationProgress(epoch)
            } catch {
                postMouse(.leftMouseUp, point: from, pid: pid)
                throw error
            }
            postMouse(.leftMouseUp, point: to, pid: pid)
        }
    }

    private func typeText(
        _ arguments: [String: Any],
        pid: pid_t,
        epoch: ControlEpoch
    ) throws {
        try rejectSecureFocusedElement(pid: pid)
        try rejectTerminalFocusedElement(pid: pid)
        let text = try requiredString(arguments, "text")
        try withControlMutation(epoch) {
            let event = taggedSyntheticEvent(
                CGEvent(
                    keyboardEventSource: nil,
                    virtualKey: 0,
                    keyDown: true
                )
            )
            event?.keyboardSetUnicodeString(
                stringLength: text.utf16.count,
                unicodeString: Array(text.utf16)
            )
            try validateMutationProgress(epoch)
            event?.postToPid(pid)
            let keyUp = taggedSyntheticEvent(
                CGEvent(
                    keyboardEventSource: nil,
                    virtualKey: 0,
                    keyDown: false
                )
            )
            keyUp?.keyboardSetUnicodeString(
                stringLength: text.utf16.count,
                unicodeString: Array(text.utf16)
            )
            do {
                try validateMutationProgress(epoch)
            } catch {
                keyUp?.postToPid(pid)
                throw error
            }
            keyUp?.postToPid(pid)
        }
    }

    private func pressKey(
        _ arguments: [String: Any],
        pid: pid_t,
        epoch: ControlEpoch
    ) throws {
        try rejectSecureFocusedElement(pid: pid)
        try rejectTerminalFocusedElement(pid: pid)
        let raw = try requiredString(arguments, "key")
        let parsed = try KeyStroke.parse(raw)
        guard !parsed.isClipboardShortcut else {
            throw HelperFailure.clipboardAccessRejected
        }
        try withControlMutation(epoch) {
            let down = taggedSyntheticEvent(
                CGEvent(
                    keyboardEventSource: nil,
                    virtualKey: parsed.keyCode,
                    keyDown: true
                )
            )
            down?.flags = parsed.flags
            try validateMutationProgress(epoch)
            down?.postToPid(pid)
            let up = taggedSyntheticEvent(
                CGEvent(
                    keyboardEventSource: nil,
                    virtualKey: parsed.keyCode,
                    keyDown: false
                )
            )
            up?.flags = parsed.flags
            do {
                try validateMutationProgress(epoch)
            } catch {
                up?.postToPid(pid)
                throw error
            }
            up?.postToPid(pid)
        }
    }

    private func setValue(
        _ arguments: [String: Any],
        epoch: ControlEpoch
    ) throws {
        let ref = try requiredString(arguments, "ref")
        let value = try requiredString(arguments, "value")
        guard let element = elements[ref]?.element else {
            throw HelperFailure.elementNotFound(ref)
        }
        guard !isSecureInputElement(element) else {
            throw HelperFailure.secureInputRejected
        }
        guard !isWithinTerminalSurface(element) else {
            throw HelperFailure.terminalSurfaceRejected
        }
        let status = try withControlMutation(epoch) {
            AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                value as CFTypeRef
            )
        }
        guard status == .success else { throw HelperFailure.elementNotFound(ref) }
    }

    private func focus(
        _ arguments: [String: Any],
        epoch: ControlEpoch
    ) throws {
        let ref = try requiredString(arguments, "ref")
        guard let element = elements[ref]?.element else {
            throw HelperFailure.elementNotFound(ref)
        }
        guard !isSecureInputElement(element) else {
            throw HelperFailure.secureInputRejected
        }
        guard !isWithinTerminalSurface(element) else {
            throw HelperFailure.terminalSurfaceRejected
        }
        let succeeded = try withControlMutation(epoch) {
            let status = AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                true as CFTypeRef
            )
            if status == .success {
                return true
            }
            try validateMutationProgress(epoch)
            return AXUIElementPerformAction(
                element,
                kAXRaiseAction as CFString
            ) == .success
        }
        guard succeeded else { throw HelperFailure.elementNotFound(ref) }
    }

    private func hover(
        _ arguments: [String: Any],
        pid: pid_t,
        epoch: ControlEpoch
    ) throws {
        let target: CGPoint
        if let ref = arguments["ref"] as? String,
           let element = elements[ref]?.element,
           let frame = elementFrame(element) {
            target = CGPoint(x: frame.midX, y: frame.midY)
            try validatePointWithinSnapshot(target, pid: pid)
        } else {
            target = try point(arguments, pid: pid)
        }
        try withControlMutation(epoch) {
            postMouse(.mouseMoved, point: target, pid: pid)
        }
    }

    private func selectText(
        _ arguments: [String: Any],
        epoch: ControlEpoch
    ) throws {
        let ref = try requiredString(arguments, "ref")
        let text = try requiredString(arguments, "text")
        guard let element = elements[ref]?.element else {
            throw HelperFailure.elementNotFound(ref)
        }
        guard !isSecureInputElement(element) else {
            throw HelperFailure.secureInputRejected
        }
        guard !isWithinTerminalSurface(element) else {
            throw HelperFailure.terminalSurfaceRejected
        }
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
        let status = try withControlMutation(epoch) {
            AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            )
        }
        guard status == .success else { throw HelperFailure.elementNotFound(ref) }
    }

    private func accessibilityWindow(
        for app: NSRunningApplication,
        matching window: VisibleWindow
    ) throws -> AXUIElement {
        let application = AXUIElementCreateApplication(
            app.processIdentifier
        )
        _ = AXUIElementSetMessagingTimeout(
            application,
            axMessagingTimeoutSeconds
        )
        var candidates = attributeValue(
            application,
            kAXWindowsAttribute
        ) as? [AXUIElement] ?? []
        if let focused = attributeValue(
            application,
            kAXFocusedWindowAttribute
        ),
        CFGetTypeID(focused as CFTypeRef) == AXUIElementGetTypeID() {
            candidates.insert(focused as! AXUIElement, at: 0)
        }
        if let exact = candidates.first(where: {
            accessibilityWindowID($0) == window.id
        }) {
            return exact
        }
        if let frameMatch = candidates.first(where: {
            elementFrame($0).map {
                framesMatch($0, window.frame)
            } == true
        }) {
            return frameMatch
        }
        throw HelperFailure.staleSnapshot(
            "the topmost CGWindow is not bound to a matching AX window"
        )
    }

    private func accessibilityWindowID(
        _ window: AXUIElement
    ) -> CGWindowID? {
        if let number = attributeValue(
            window,
            axWindowNumberAttribute
        ) as? NSNumber {
            return CGWindowID(number.uint32Value)
        }
        if let number = attributeValue(
            window,
            axWindowNumberAttribute
        ) as? Int {
            return CGWindowID(number)
        }
        return nil
    }

    private func validateVisibleWindow(
        _ expectedWindow: VisibleWindow,
        pid: pid_t
    ) throws {
        guard let currentWindow = visibleWindow(for: pid) else {
            throw HelperFailure.staleSnapshot(
                "target window visibility changed"
            )
        }
        guard currentWindow.ownerPID == expectedWindow.ownerPID,
              currentWindow.id == expectedWindow.id,
              framesMatch(
                  currentWindow.frame,
                  expectedWindow.frame
              ) else {
            throw HelperFailure.staleSnapshot(
                "target window moved, resized, or changed"
            )
        }
    }

    private func captureWindow(
        _ window: VisibleWindow,
        sensitiveFrames: [CGRect]
    ) throws -> WindowCapture {
        guard CGPreflightScreenCaptureAccess() else { throw HelperFailure.screenCaptureNotGranted }
        guard let rawImage = CGWindowListCreateImage(
                  .null,
                  .optionIncludingWindow,
                  window.id,
                  [.bestResolution, .boundsIgnoreFraming]
              ) else {
            throw HelperFailure.captureFailed
        }
        let redactedImage = redactedWindowCapture(
            rawImage,
            windowFrame: window.frame,
            sensitiveFrames: sensitiveFrames
        )
        let image = downscaledWindowCapture(redactedImage)
        let url = try saveCapture(image, prefix: "window")
        return WindowCapture(
            path: url.path,
            windowID: window.id,
            frame: window.frame,
            imageSize: CGSize(width: image.width, height: image.height)
        )
    }

    private func captureDisplay(_ arguments: [String: Any]) throws -> [String: Any] {
        controlSessionLock.lock()
        let hasControlSession = controlSession != nil
        controlSessionLock.unlock()
        guard !hasControlSession else {
            throw HelperFailure.displayCaptureBlocked
        }
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
            windowID: nil,
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

    private func redactedWindowCapture(
        _ image: CGImage,
        windowFrame: CGRect,
        sensitiveFrames: [CGRect]
    ) -> CGImage {
        guard !sensitiveFrames.isEmpty,
              windowFrame.width > 0,
              windowFrame.height > 0,
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: image.height
        )
        context.draw(image, in: imageBounds)
        context.setFillColor(
            CGColor(
                red: 0.06,
                green: 0.06,
                blue: 0.06,
                alpha: 1
            )
        )
        let horizontalScale = CGFloat(image.width) / windowFrame.width
        let verticalScale = CGFloat(image.height) / windowFrame.height
        for frame in sensitiveFrames {
            let clipped = frame.intersection(windowFrame)
            guard !clipped.isNull, !clipped.isEmpty else { continue }
            let expanded = clipped.insetBy(dx: -4, dy: -4)
                .intersection(windowFrame)
            let x = (expanded.minX - windowFrame.minX) * horizontalScale
            let yFromTop =
                (expanded.minY - windowFrame.minY) * verticalScale
            let width = expanded.width * horizontalScale
            let height = expanded.height * verticalScale
            let y = CGFloat(image.height) - yFromTop - height
            context.fill(
                CGRect(x: x, y: y, width: width, height: height)
                    .intersection(imageBounds)
            )
        }
        return context.makeImage() ?? image
    }

    private func downscaledWindowCapture(_ image: CGImage) -> CGImage {
        let longEdge = max(image.width, image.height)
        guard longEdge > maximumWindowCaptureLongEdge else { return image }
        let scale = CGFloat(maximumWindowCaptureLongEdge) / CGFloat(longEdge)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return context.makeImage() ?? image
    }

    private func visibleWindow(for pid: pid_t) -> VisibleWindow? {
        visibleWindows().first { $0.ownerPID == pid }
    }

    private func topmostVisibleWindow(
        at point: CGPoint
    ) -> VisibleWindow? {
        physicalHitTestWindows().first { $0.frame.contains(point) }
    }

    private func visibleWindows() -> [VisibleWindow] {
        decodedVisibleWindows(requireLayerZero: true)
    }

    private func physicalHitTestWindows() -> [VisibleWindow] {
        // CGWindowList ordering is front-to-back. Unlike snapshot selection,
        // physical takeover hit testing must include menus, popovers and
        // sheets above layer 0 so a real click on any target-owned surface
        // wins immediately. A WillDeep panel remains the first owner and is
        // therefore not mistaken for the target behind it.
        decodedVisibleWindows(requireLayerZero: false)
    }

    private func decodedVisibleWindows(
        requireLayerZero: Bool
    ) -> [VisibleWindow] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return windows.compactMap { window in
            guard let layer = window[
                kCGWindowLayer as String
            ] as? Int,
                  !requireLayerZero || layer == 0,
                  let owner = window[
                      kCGWindowOwnerPID as String
                  ] as? Int,
                  owner > 0,
                  let number = window[kCGWindowNumber as String] as? Int,
                  let bounds = window[
                      kCGWindowBounds as String
                  ] as? [String: CGFloat] else {
                return nil
            }
            let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?
                .doubleValue ?? 1
            guard alpha > 0 else { return nil }
            let frame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            let minimumEdge: CGFloat = requireLayerZero ? 20 : 1
            guard frame.width > minimumEdge,
                  frame.height > minimumEdge else {
                return nil
            }
            return VisibleWindow(
                id: CGWindowID(number),
                ownerPID: pid_t(owner),
                frame: frame
            )
        }
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

    private func resolveRunningApplication(_ identifier: String) -> NSRunningApplication? {
        let normalized = identifier.lowercased()
        return NSWorkspace.shared.runningApplications.first { app in
            app.bundleIdentifier?.lowercased() == normalized || app.localizedName?.lowercased() == normalized
        }
    }

    private func appDictionary(_ app: NSRunningApplication, launched: Bool) -> [String: Any] {
        ["pid": Int(app.processIdentifier), "bundle_id": app.bundleIdentifier ?? "", "name": app.localizedName ?? "Unknown", "launched": launched]
    }

    private func ensureAllowedControlPID(_ pid: pid_t) throws {
        guard !isForbiddenProcessID(pid) else {
            throw HelperFailure.forbiddenControlTarget(String(pid))
        }
    }

    private func ensureAllowedControlIdentifier(
        _ identifier: String
    ) throws {
        let normalized = normalizedApplicationIdentifier(identifier)
        guard !normalized.isEmpty else {
            throw HelperFailure.invalidRequest("Control target is empty.")
        }
        let isWillDeep = normalized == "com.willdeep.app"
            || normalized.hasPrefix("com.willdeep.")
        guard !isWillDeep,
              !forbiddenControlBundleIdentifiers.contains(normalized),
              !forbiddenControlApplicationNames.contains(normalized) else {
            throw HelperFailure.forbiddenControlTarget(identifier)
        }
    }

    private func ensureAllowedControlApplication(
        _ app: NSRunningApplication
    ) throws {
        try ensureAllowedControlPID(app.processIdentifier)
        if let bundleID = app.bundleIdentifier {
            try ensureAllowedControlIdentifier(bundleID)
        }
        if let name = app.localizedName {
            try ensureAllowedControlIdentifier(name)
        }
        if let executableName = app.executableURL?
            .deletingPathExtension()
            .lastPathComponent {
            try ensureAllowedControlIdentifier(executableName)
        }
    }

    private func isForbiddenProcessID(_ pid: pid_t) -> Bool {
        if pid <= 0 || pid == getpid() || pid == getppid() {
            return true
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return false
        }
        let identifiers = [
            app.bundleIdentifier,
            app.localizedName,
            app.executableURL?.deletingPathExtension().lastPathComponent
        ]
        .compactMap { $0 }
        .map(normalizedApplicationIdentifier)
        return identifiers.contains { identifier in
            identifier == "com.willdeep.app"
                || identifier.hasPrefix("com.willdeep.")
                || forbiddenControlBundleIdentifiers.contains(identifier)
                || forbiddenControlApplicationNames.contains(identifier)
        }
    }

    private func normalizedApplicationIdentifier(
        _ rawValue: String
    ) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(
                of: #"\.app$"#,
                with: "",
                options: .regularExpression
            )
    }

    private func controlledApplication(
        _ arguments: [String: Any],
        leaseID: String
    ) throws -> NSRunningApplication {
        let session = try requireControlSession(leaseID: leaseID)
        let app: NSRunningApplication?
        if let requestedPID = arguments["pid"] as? Int {
            guard session.pid == nil || session.pid == pid_t(requestedPID) else {
                throw HelperFailure.controlTargetMismatch
            }
            app = NSRunningApplication(processIdentifier: pid_t(requestedPID))
        } else if let requestedIdentifier = arguments["app"] as? String {
            guard sessionMatchesIdentifier(session, requestedIdentifier) else {
                throw HelperFailure.controlTargetMismatch
            }
            app = resolveRunningApplication(requestedIdentifier)
        } else if let pid = session.pid {
            app = NSRunningApplication(processIdentifier: pid)
        } else if let identifier = session.targetIdentifier {
            app = resolveRunningApplication(identifier)
        } else {
            app = nil
        }
        guard let app, !app.isTerminated else {
            throw HelperFailure.appNotFound(
                session.targetIdentifier ?? session.pid.map(String.init) ?? "control target"
            )
        }
        try ensureAllowedControlApplication(app)
        try bindControlSession(to: app, leaseID: leaseID)
        return app
    }

    private func requireControlSession(
        leaseID: String,
        allowPaused: Bool = false
    ) throws -> ControlSession {
        controlSessionLock.lock()
        defer { controlSessionLock.unlock() }
        guard let session = controlSession else {
            throw HelperFailure.controlLeaseMismatch
        }
        guard session.leaseID == leaseID else {
            throw HelperFailure.controlLeaseMismatch
        }
        guard allowPaused || !session.isPaused else {
            throw HelperFailure.controlSessionPaused
        }
        return session
    }

    private func nextSessionEpochLocked() -> UInt64 {
        nextControlSessionEpoch &+= 1
        return nextControlSessionEpoch
    }

    private func captureControlEpoch(
        leaseID: String
    ) throws -> ControlEpoch {
        physicalInputEpochLock.lock()
        defer { physicalInputEpochLock.unlock() }
        controlSessionLock.lock()
        defer { controlSessionLock.unlock() }
        guard let session = controlSession,
              session.leaseID == leaseID else {
            throw HelperFailure.controlLeaseMismatch
        }
        guard !session.isPaused else {
            throw HelperFailure.controlSessionPaused
        }
        return ControlEpoch(
            leaseID: leaseID,
            sessionEpoch: session.epoch,
            physicalInputEpoch: physicalInputEpoch
        )
    }

    private func validateControlEpoch(
        _ epoch: ControlEpoch
    ) throws {
        physicalInputEpochLock.lock()
        defer { physicalInputEpochLock.unlock() }
        controlSessionLock.lock()
        defer { controlSessionLock.unlock() }
        try validateControlEpochLocked(epoch)
    }

    private func validateControlEpochLocked(
        _ epoch: ControlEpoch
    ) throws {
        guard let session = controlSession,
              session.leaseID == epoch.leaseID else {
            throw HelperFailure.controlLeaseMismatch
        }
        guard !session.isPaused else {
            throw HelperFailure.controlSessionPaused
        }
        guard session.epoch == epoch.sessionEpoch,
              physicalInputEpoch == epoch.physicalInputEpoch else {
            throw HelperFailure.controlEpochChanged
        }
    }

    private func withControlMutation<T>(
        _ epoch: ControlEpoch,
        _ mutation: () throws -> T
    ) throws -> T {
        let mutationID = try beginControlMutation(epoch)
        let outcome: Result<T, Error>
        do {
            // This second check closes the registration-to-call gap as far
            // as a synchronous AX/CG API permits without blocking the input
            // callback. A real input can still arrive during the API call;
            // it immediately pauses the session and the post-check rejects
            // the result (or the Host kills this Helper generation).
            try validateRegisteredMutation(
                mutationID,
                epoch: epoch
            )
            outcome = .success(try mutation())
        } catch {
            outcome = .failure(error)
        }
        if let invalidationError = closeControlMutation(
            mutationID,
            epoch: epoch
        ) {
            throw invalidationError
        }
        return try outcome.get()
    }

    private func beginControlMutation(
        _ epoch: ControlEpoch
    ) throws -> UInt64 {
        physicalInputEpochLock.lock()
        defer { physicalInputEpochLock.unlock() }
        controlSessionLock.lock()
        defer { controlSessionLock.unlock() }
        try validateControlEpochLocked(epoch)
        guard activeMutation == nil else {
            throw HelperFailure.controlEpochChanged
        }
        nextMutationID &+= 1
        let mutationID = nextMutationID
        activeMutation = ActiveMutation(
            id: mutationID,
            controlEpoch: epoch
        )
        return mutationID
    }

    private func validateRegisteredMutation(
        _ mutationID: UInt64,
        epoch: ControlEpoch
    ) throws {
        physicalInputEpochLock.lock()
        defer { physicalInputEpochLock.unlock() }
        controlSessionLock.lock()
        defer { controlSessionLock.unlock() }
        guard activeMutation?.id == mutationID,
              activeMutation?.controlEpoch == epoch else {
            throw HelperFailure.controlEpochChanged
        }
        try validateControlEpochLocked(epoch)
    }

    private func validateMutationProgress(
        _ epoch: ControlEpoch
    ) throws {
        try validateControlEpoch(epoch)
    }

    private func closeControlMutation(
        _ mutationID: UInt64,
        epoch: ControlEpoch
    ) -> Error? {
        physicalInputEpochLock.lock()
        defer { physicalInputEpochLock.unlock() }
        controlSessionLock.lock()
        defer { controlSessionLock.unlock() }
        guard activeMutation?.id == mutationID,
              activeMutation?.controlEpoch == epoch else {
            return HelperFailure.controlEpochChanged
        }
        activeMutation = nil
        do {
            try validateControlEpochLocked(epoch)
            return nil
        } catch {
            return error
        }
    }

    private func bindControlSession(
        to app: NSRunningApplication,
        leaseID: String
    ) throws {
        try ensureAllowedControlApplication(app)
        controlSessionLock.lock()
        defer { controlSessionLock.unlock() }
        guard var session = controlSession, session.leaseID == leaseID else {
            throw HelperFailure.controlLeaseMismatch
        }
        guard !app.isTerminated else {
            throw HelperFailure.appNotFound(
                app.bundleIdentifier ?? app.localizedName ?? String(app.processIdentifier)
            )
        }
        if let pid = session.pid, pid != app.processIdentifier {
            throw HelperFailure.controlTargetMismatch
        }
        if let bundleID = session.bundleID,
           !bundleID.isEmpty,
           app.bundleIdentifier?.caseInsensitiveCompare(bundleID) != .orderedSame {
            throw HelperFailure.controlTargetMismatch
        }
        if let identifier = session.targetIdentifier,
           !sessionMatchesIdentifier(session, identifier, candidate: app) {
            throw HelperFailure.controlTargetMismatch
        }
        if let launchDate = session.launchDate,
           !datesMatch(launchDate, app.launchDate) {
            throw HelperFailure.controlTargetMismatch
        }
        let targetChanged = session.pid != app.processIdentifier
            || session.bundleID != app.bundleIdentifier
            || !datesMatch(session.launchDate, app.launchDate)
        session.pid = app.processIdentifier
        session.bundleID = app.bundleIdentifier
        session.launchDate = app.launchDate
        if targetChanged {
            session.windowID = nil
            session.windowFrame = nil
            session.epoch = nextSessionEpochLocked()
        }
        controlSession = session
    }

    private func requireControlTarget(
        identifier: String,
        leaseID: String
    ) throws {
        let session = try requireControlSession(leaseID: leaseID)
        guard sessionMatchesIdentifier(session, identifier) else {
            throw HelperFailure.controlTargetMismatch
        }
    }

    private func sessionMatchesIdentifier(
        _ session: ControlSession,
        _ identifier: String,
        candidate: NSRunningApplication? = nil
    ) -> Bool {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        if session.targetIdentifier?.lowercased() == normalized
            || session.bundleID?.lowercased() == normalized {
            return true
        }
        let app = candidate ?? session.pid.flatMap {
            NSRunningApplication(processIdentifier: $0)
        }
        return app?.bundleIdentifier?.lowercased() == normalized
            || app?.localizedName?.lowercased() == normalized
    }

    private func controlSessionDictionary(
        _ session: ControlSession
    ) -> [String: Any] {
        var result: [String: Any] = [
            "control_lease_id": session.leaseID,
            "paused": session.isPaused
        ]
        if let targetIdentifier = session.targetIdentifier {
            result["target_app"] = targetIdentifier
        }
        if let pid = session.pid {
            result["target_pid"] = Int(pid)
        }
        if let bundleID = session.bundleID {
            result["target_bundle_id"] = bundleID
        }
        return result
    }

    private func discardDeadControlSessionIfNeeded() {
        controlSessionLock.lock()
        defer { controlSessionLock.unlock() }
        guard let session = controlSession, let pid = session.pid else { return }
        guard let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated,
              datesMatch(session.launchDate, app.launchDate) else {
            _ = nextSessionEpochLocked()
            controlSession = nil
            invalidateSnapshot()
            return
        }
    }

    private func invalidateSnapshot(controlLeaseID leaseID: String? = nil) {
        activeSnapshot = nil
        elements.removeAll(keepingCapacity: true)
        guard let leaseID else { return }
        controlSessionLock.lock()
        defer { controlSessionLock.unlock() }
        guard var session = controlSession, session.leaseID == leaseID else {
            return
        }
        session.windowID = nil
        session.windowFrame = nil
        controlSession = session
    }

    private func updateControlWindow(
        _ window: VisibleWindow,
        leaseID: String
    ) throws {
        controlSessionLock.lock()
        defer { controlSessionLock.unlock() }
        guard var session = controlSession, session.leaseID == leaseID else {
            throw HelperFailure.controlLeaseMismatch
        }
        guard session.pid == window.ownerPID else {
            throw HelperFailure.controlTargetMismatch
        }
        session.windowID = window.id
        session.windowFrame = window.frame
        controlSession = session
    }

    private func validateActiveSnapshot(
        _ arguments: [String: Any],
        leaseID: String,
        requireCoordinateImage: Bool
    ) throws -> Snapshot {
        let session = try requireControlSession(leaseID: leaseID)
        guard let snapshot = activeSnapshot else {
            throw HelperFailure.staleSnapshot("no active snapshot")
        }
        try validateControlEpoch(snapshot.controlEpoch)
        guard let requestedSnapshotID = arguments["snapshot_id"] as? String,
              requestedSnapshotID == snapshot.id else {
            throw HelperFailure.staleSnapshot("snapshot_id is missing or no longer current")
        }
        guard Date().timeIntervalSince(snapshot.capturedAt) <= snapshotLifetime else {
            invalidateSnapshot(controlLeaseID: leaseID)
            throw HelperFailure.staleSnapshot("snapshot expired")
        }
        guard session.pid == snapshot.pid else {
            invalidateSnapshot(controlLeaseID: leaseID)
            throw HelperFailure.staleSnapshot("control target changed")
        }
        if let requestedPID = arguments["pid"] as? Int,
           pid_t(requestedPID) != snapshot.pid {
            throw HelperFailure.controlTargetMismatch
        }
        let app = try controlledApplication(
            ["pid": Int(snapshot.pid)],
            leaseID: leaseID
        )
        guard app.bundleIdentifier == snapshot.bundleID,
              datesMatch(app.launchDate, snapshot.appLaunchDate) else {
            invalidateSnapshot(controlLeaseID: leaseID)
            throw HelperFailure.staleSnapshot("target app restarted")
        }
        if let ref = arguments["ref"] as? String {
            guard ref.hasPrefix("\(snapshot.id):"),
                  let elementReference = elements[ref],
                  elementReference.windowID == snapshot.windowID else {
                throw HelperFailure.staleSnapshot("element ref does not belong to the active snapshot")
            }
            var elementPID: pid_t = 0
            guard AXUIElementGetPid(
                elementReference.element,
                &elementPID
            ) == .success,
                  elementPID == snapshot.pid else {
                throw HelperFailure.controlTargetMismatch
            }
            if let frame = elementFrame(elementReference.element) {
                let center = CGPoint(x: frame.midX, y: frame.midY)
                guard snapshot.windowFrame.contains(center) else {
                    throw HelperFailure.staleSnapshot(
                        "element ref is outside the bound target window"
                    )
                }
            }
        }

        do {
            try validateVisibleWindow(
                VisibleWindow(
                    id: snapshot.windowID,
                    ownerPID: snapshot.pid,
                    frame: snapshot.windowFrame
                ),
                pid: snapshot.pid
            )
        } catch {
            invalidateSnapshot(controlLeaseID: leaseID)
            throw error
        }

        if requireCoordinateImage {
            guard snapshot.coordinateImageSize != nil else {
                throw HelperFailure.staleSnapshot(
                    "snapshot has no screenshot coordinate space"
                )
            }
        }
        return snapshot
    }

    private func point(
        _ arguments: [String: Any],
        prefix: String = "",
        pid: pid_t
    ) throws -> CGPoint {
        let x = number(arguments, "\(prefix)x")
        let y = number(arguments, "\(prefix)y")
        guard let x, let y else { throw HelperFailure.invalidRequest("Missing \(prefix)x/\(prefix)y coordinates.") }
        let coordinateSpace = arguments["coordinate_space"] as? String ?? "screenshot"
        guard x.isFinite, y.isFinite else {
            throw HelperFailure.invalidRequest("Coordinates must be finite.")
        }
        guard coordinateSpace == "screenshot" else {
            throw HelperFailure.invalidRequest(
                "coordinate_space must be screenshot; arbitrary screen coordinates are forbidden."
            )
        }
        guard let snapshot = activeSnapshot,
                  snapshot.pid == pid,
                  let imageSize = snapshot.coordinateImageSize,
                  imageSize.width > 0,
                  imageSize.height > 0 else {
            throw HelperFailure.staleSnapshot(
                "screenshot coordinates require the current captured window"
            )
        }
        guard x >= 0, y >= 0,
              x <= imageSize.width,
              y <= imageSize.height else {
            throw HelperFailure.invalidRequest(
                "Screenshot coordinates are outside the active snapshot."
            )
        }
        let point = CGPoint(
            x: snapshot.windowFrame.minX
                + x * snapshot.windowFrame.width / imageSize.width,
            y: snapshot.windowFrame.minY
                + y * snapshot.windowFrame.height / imageSize.height
        )
        try validatePointWithinSnapshot(point, pid: pid)
        return point
    }

    private func validatePointWithinSnapshot(
        _ point: CGPoint,
        pid: pid_t
    ) throws {
        guard let snapshot = activeSnapshot,
              snapshot.pid == pid,
              snapshot.windowFrame.contains(point) else {
            throw HelperFailure.staleSnapshot(
                "target point is outside the bound target window"
            )
        }
    }

    private func postMouse(
        _ type: CGEventType,
        point: CGPoint,
        pid: pid_t,
        clickState: Int = 1
    ) {
        let event = taggedSyntheticEvent(
            CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: type == .rightMouseDown || type == .rightMouseUp
                    ? .right
                    : .left
            )
        )
        event?.setIntegerValueField(
            .mouseEventClickState,
            value: Int64(max(1, clickState))
        )
        event?.postToPid(pid)
    }

    private func taggedSyntheticEvent(_ event: CGEvent?) -> CGEvent? {
        event?.setIntegerValueField(
            .eventSourceUserData,
            value: syntheticEventUserDataTag
        )
        return event
    }

    private func requireAccessibility() throws {
        guard AXIsProcessTrusted() else { throw HelperFailure.accessibilityNotGranted }
    }

    private func datesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return abs(lhs.timeIntervalSince(rhs)) < 0.5
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 1
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

private struct WindowCapture {
    let path: String
    let windowID: CGWindowID?
    let frame: CGRect
    let imageSize: CGSize

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "path": path,
            "pixel_width": Int(imageSize.width),
            "pixel_height": Int(imageSize.height),
            "coordinate_space": "screenshot",
            "frame": [
                "x": frame.origin.x,
                "y": frame.origin.y,
                "width": frame.width,
                "height": frame.height
            ]
        ]
        if let windowID {
            result["window_id"] = Int(windowID)
        }
        return result
    }
}

private struct KeyStroke {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    var isClipboardShortcut: Bool {
        flags.contains(.maskCommand)
            && [CGKeyCode(7), CGKeyCode(8), CGKeyCode(9)]
                .contains(keyCode)
    }

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

private func normalizedLeaseID(_ value: Any?) -> String? {
    guard let rawValue = value as? String else { return nil }
    let normalized = rawValue.trimmingCharacters(
        in: .whitespacesAndNewlines
    )
    return normalized.isEmpty ? nil : normalized
}

private func requiredLeaseID(_ value: String?) throws -> String {
    guard let value else {
        throw HelperFailure.controlLeaseRequired
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

#if WILLDEEP_COMPUTER_USE_CONTRACT_TEST
private func verifyTrustedParentProcess() -> Bool {
    true
}
#else
private func verifyTrustedParentProcess() -> Bool {
    let helperBundleURL = Bundle.main.bundleURL
        .resolvingSymlinksInPath()
        .standardizedFileURL
    let hostBundleURL = helperBundleURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .resolvingSymlinksInPath()
        .standardizedFileURL
    guard let hostBundle = Bundle(url: hostBundleURL),
          hostBundle.bundleIdentifier == "com.willdeep.app",
          let expectedExecutableURL = hostBundle.executableURL?
            .resolvingSymlinksInPath()
            .standardizedFileURL,
          let parentExecutableURL = executableURL(
            for: getppid()
          ) else {
        return false
    }
    return expectedExecutableURL.path == parentExecutableURL.path
}

private func executableURL(for pid: pid_t) -> URL? {
    guard pid > 1 else { return nil }
    var buffer = [UInt8](
        repeating: 0,
        count: maximumProcessPathBytes
    )
    let byteCount = buffer.withUnsafeMutableBytes { bytes in
        proc_pidpath(
            pid,
            bytes.baseAddress,
            UInt32(bytes.count)
        )
    }
    guard byteCount > 0 else { return nil }
    return URL(
        fileURLWithPath: String(cString: buffer)
    )
    .resolvingSymlinksInPath()
    .standardizedFileURL
}
#endif

guard verifyTrustedParentProcess() else {
    exit(EX_NOPERM)
}

private let controller = ComputerUseController()
private let physicalInputMonitor = PhysicalInputMonitor { kind, location in
    controller.handlePhysicalUserInput(kind, location: location)
}
physicalInputMonitor.start()
while let line = readLine() {
    var requestID = ""
    var response: [String: Any]?
    do {
        guard let data = line.data(using: .utf8),
              let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HelperFailure.invalidRequest("Request must be a JSON object.")
        }
        requestID = request["id"] as? String ?? ""
        let result = try controller.handle(request)
        try controller.writeSuccessResponse(
            requestID: requestID,
            result: result
        )
        response = nil
    } catch {
        controller.clearPendingResponseEpoch()
        response = [
            "id": requestID,
            "ok": false,
            "error": error.localizedDescription
        ]
    }
    if let response {
        ProtocolWriter.shared.write(response)
    }
    if controller.shouldExit {
        break
    }
}
physicalInputMonitor.stop()
