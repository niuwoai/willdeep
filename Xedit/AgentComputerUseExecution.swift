//
//  AgentComputerUseExecution.swift
//  WillDeep
//
//  Binds individual tool calls to the global Computer Use control lease.
//  This is the execution-side counterpart to AgentComputerUseCoordinator's
//  presentation state: one owner, one target, cancellation-aware handoff.
//

import AppKit
import Darwin
import Foundation

nonisolated struct AgentComputerUsePreparedControl: Sendable {
    let leaseID: AgentComputerUseLease.ID
    let owner: AgentComputerUseOwner
    let target: AgentComputerUseTarget
    let operation: AgentComputerUseOperation
    let toolName: String
    let privacyEpoch: UInt64
}

nonisolated struct AgentComputerUseLocalObservationGuard: Sendable {
    let privacyEpoch: UInt64
}

nonisolated struct AgentComputerUseMaintenanceReservation: Sendable {
    let id: UUID
}

nonisolated struct AgentComputerUseStaleResultError: LocalizedError, Sendable {
    let errorDescription: String? =
        "Computer Use discarded a result that crossed a user-control handoff. Capture fresh state before continuing."
}

nonisolated enum AgentComputerUseSessionStartFailureDisposition: Equatable {
    case waitForUserControl
    case cancel
    case fail
}

nonisolated enum AgentComputerUseExecution {
    private static let observingToolNames: Set<String> = [
        "computer_use_get_app_state",
        "computer_use_inspect_app",
        "computer_use_wait_for",
    ]

    private static let controllingToolNames: Set<String> = [
        "computer_use_launch_app",
        "computer_use_activate_app",
        "computer_use_click",
        "computer_use_secondary_action",
        "computer_use_scroll",
        "computer_use_drag",
        "computer_use_type_text",
        "computer_use_press_key",
        "computer_use_set_value",
        "computer_use_focus",
        "computer_use_hover",
        "computer_use_select_text",
    ]

    private static let takeoverEmbargoedToolNames: Set<String> = [
        "capture_screenshot",
        "visual_qa_screenshot",
        "terminal_snapshot",
        "terminal_send_command",
        "terminal_send_control",
        "terminal_list_tabs",
        "terminal_select_tab",
        "run_command",
        "claude_code",
        "codex_cli",
        "hermes_cli",
        "cursor_agent",
        "cline_cli",
        "opencode_cli",
        "call_mcp_tool",
    ]

    private static let idleLeaseMaintenanceToolNames: Set<String> = [
        "computer_use_request_permissions",
        "computer_use_restart_helper",
    ]

    static func prepare(
        toolName: String,
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentComputerUsePreparedControl? {
        if requiresIdleControlLease(toolName: toolName) {
            let activeTitle = await MainActor.run {
                AgentComputerUseCoordinator.shared.state.lease?
                    .owner.sessionTitle
            }
            if let activeTitle {
                throw AgentToolError.commandFailed(
                    1,
                    "Computer Use is active in \(activeTitle). Permission prompts and helper restarts are disabled until that control session ends."
                )
            }
            return nil
        }

        let operation: AgentComputerUseOperation
        if observingToolNames.contains(toolName) {
            operation = .observing
        } else if controllingToolNames.contains(toolName) {
            operation = .controlling
        } else {
            return nil
        }

        guard let runtimeID = context.runtimeID,
              let turnID = context.turnID else {
            throw AgentToolError.invalidArgument(
                "Computer Use control is available only inside an active WillDeep conversation turn."
            )
        }
        let owner = AgentComputerUseOwner(
            runtimeID: runtimeID,
            turnID: turnID,
            sessionTitle: context.computerUseSessionTitle ?? "WillDeep"
        )

        let target: AgentComputerUseTarget = try await MainActor.run {
            try resolveTarget(
                arguments: arguments,
                owner: owner,
                coordinator: AgentComputerUseCoordinator.shared
            )
        }

        let authorization = await MainActor.run {
            AgentComputerUseCoordinator.shared.authorize(
                owner: owner,
                target: target
            )
        }
        switch authorization {
        case .allowed:
            break
        case .denied(let reason, let activeLease):
            switch reason {
            case .paused, .userTakeover:
                guard let activeLease else {
                    throw AgentToolError.commandFailed(
                        1,
                        "Computer Use is paused without an active control lease."
                    )
                }
                try await waitUntilControlReturns(
                    leaseID: activeLease.id,
                    owner: owner
                )
                throw AgentToolError.commandFailed(
                    1,
                    "The user returned Computer Use control. The prior UI state is intentionally stale; call computer_use_get_app_state and reconsider the action instead of replaying it."
                )
            case .ownedByAnotherTurn:
                let title = activeLease?.owner.sessionTitle ?? "another task"
                throw AgentToolError.commandFailed(
                    1,
                    "Computer Use is busy in \(title). Only one WillDeep task may control the Mac at a time."
                )
            case .maintenance:
                throw AgentToolError.commandFailed(
                    1,
                    "Computer Use helper maintenance is in progress. Retry after the permission or restart operation finishes."
                )
            case .targetMismatch:
                throw AgentToolError.commandFailed(
                    1,
                    "The active Computer Use lease belongs to another app. Stop it before controlling a different target."
                )
            case .stopping, .revoked:
                throw CancellationError()
            }
        }

        try await satisfyPendingTransportBarrier()

        guard let preparedLease = await MainActor.run(body: {
            () -> (AgentComputerUseLease, UInt64)? in
            let coordinator = AgentComputerUseCoordinator.shared
            guard let lease = coordinator.begin(
                operation: operation,
                owner: owner,
                target: target,
                actionName: toolName
            ) else {
                return nil
            }
            return (lease, coordinator.privacyEpoch)
        }) else {
            throw AgentToolError.commandFailed(
                1,
                "Computer Use could not acquire its exclusive control lease."
            )
        }
        let (lease, privacyEpoch) = preparedLease
        try await satisfyPendingTransportBarrier()
        try await ensureLeaseReadyForHelperStart(
            lease: lease,
            owner: owner,
            target: target,
            privacyEpoch: privacyEpoch
        )

        let helperSession: [String: Any]
        do {
            do {
                helperSession = try await startBridgeControlSession(
                    leaseID: lease.id,
                    target: target
                )
            } catch {
                // A just-finished turn may have cleared the main-process
                // coordinator a few milliseconds before its async helper
                // end-session request ran. The global coordinator proves no
                // other live owner exists, so a helper-only "busy" lease is
                // stale and can be recovered by one clean generation restart.
                let message = error.localizedDescription.lowercased()
                guard message.contains("active lease")
                    || message.contains("already controlled")
                    || message.contains("control lease is busy") else {
                    throw error
                }
                await AgentComputerUseBridge.shared.restart()
                helperSession = try await startBridgeControlSession(
                    leaseID: lease.id,
                    target: target
                )
            }
        } catch {
            try await handleSessionStartFailure(
                error,
                lease: lease,
                owner: owner
            )
        }

        if helperSession["paused"] as? Bool == true {
            await MainActor.run {
                _ = AgentComputerUseCoordinator.shared.takeover(
                    leaseID: lease.id
                )
            }
            try await waitUntilControlReturns(
                leaseID: lease.id,
                owner: owner
            )
            // The user may resume faster than the first interrupt Task reaches
            // the Bridge actor. A final reset here is the transport barrier:
            // no subsequent model call can race the old paused generation.
            await restartAndAcknowledgeTransportBarrier()
            throw AgentToolError.commandFailed(
                1,
                "Computer Use yielded to real user input while establishing control. Capture a fresh app state before deciding what to do next."
            )
        }

        let prepared = AgentComputerUsePreparedControl(
            leaseID: lease.id,
            owner: owner,
            target: target,
            operation: operation,
            toolName: toolName,
            privacyEpoch: privacyEpoch
        )

        if AgentComputerUsePolicy.requiresUserTakeover(arguments) {
            await MainActor.run {
                _ = AgentComputerUseCoordinator.shared.takeover(
                    leaseID: lease.id
                )
            }
            try await waitUntilControlReturns(leaseID: lease.id, owner: owner)
            await restartAndAcknowledgeTransportBarrier()
            throw AgentToolError.commandFailed(
                1,
                "Private user takeover completed. Do not repeat the sensitive action or inspect what the user entered; call computer_use_get_app_state to continue from a fresh visual and Accessibility state."
            )
        }

        return prepared
    }

    static func complete(
        _ prepared: AgentComputerUsePreparedControl?,
        result: AgentToolResult
    ) async throws {
        guard let prepared else { return }
        let activity = result.images.first.map {
            AgentComputerUseActivity(
                image: $0,
                toolName: prepared.toolName,
                capturedAt: $0.createdAt ?? Date()
            )
        }
        let updatedTarget = targetFromPayload(result.payload)
            .map { prepared.target.mergingKnownIdentity(from: $0) }
            ?? prepared.target

        do {
            try await MainActor.run {
                let coordinator = AgentComputerUseCoordinator.shared
                switch coordinator.resultPublicationDisposition(
                    leaseID: prepared.leaseID,
                    owner: prepared.owner,
                    target: prepared.target,
                    startedAtPrivacyEpoch: prepared.privacyEpoch
                ) {
                case .publish:
                    break
                case .userControl, .staleHandoff:
                    throw AgentComputerUseStaleResultError()
                case .cancelled:
                    throw CancellationError()
                }
                _ = coordinator.begin(
                    operation: prepared.operation,
                    owner: prepared.owner,
                    target: updatedTarget,
                    actionName: prepared.toolName,
                    activity: activity
                )
                coordinator.complete(
                    leaseID: prepared.leaseID,
                    activity: activity,
                    actionName: prepared.toolName
                )
            }
        } catch {
            // Computer Use screenshots are written into AgentAttachments
            // before this publication gate runs. A handoff/revocation must
            // erase those discarded pixels as well as keeping them out of
            // the transcript and model context.
            result.images.forEach { $0.removeStoredFileIfNeeded() }
            throw error
        }
    }

    static func prepareLocalObservation(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) async throws -> AgentComputerUseLocalObservationGuard? {
        guard requiresTakeoverEmbargo(
            toolName: toolName,
            arguments: arguments
        ) else {
            return nil
        }
        return try await MainActor.run {
            guard let epoch = AgentComputerUseCoordinator.shared
                .beginLocalObservation() else {
                throw AgentToolError.commandFailed(
                    1,
                    "Local screen, browser, terminal, and clipboard observation is disabled while the user has private control."
                )
            }
            return AgentComputerUseLocalObservationGuard(privacyEpoch: epoch)
        }
    }

    static func prepareMaintenanceReservation(
        toolName: String
    ) async throws -> AgentComputerUseMaintenanceReservation? {
        guard requiresIdleControlLease(toolName: toolName) else { return nil }
        return try await MainActor.run {
            guard let reservationID = AgentComputerUseCoordinator.shared
                .beginIdleMaintenanceReservation() else {
                let title = AgentComputerUseCoordinator.shared.state.lease?
                    .owner.sessionTitle ?? "another Computer Use operation"
                throw AgentToolError.commandFailed(
                    1,
                    "Computer Use is active in \(title). Permission prompts and helper restarts are disabled until that operation ends."
                )
            }
            return AgentComputerUseMaintenanceReservation(id: reservationID)
        }
    }

    static func finishMaintenanceReservation(
        _ reservation: AgentComputerUseMaintenanceReservation?
    ) async {
        guard let reservation else { return }
        await MainActor.run {
            AgentComputerUseCoordinator.shared.endIdleMaintenanceReservation(
                reservation.id
            )
        }
    }

    static func validateLocalObservation(
        _ guardToken: AgentComputerUseLocalObservationGuard?
    ) async throws {
        guard let guardToken else { return }
        try await MainActor.run {
            guard AgentComputerUseCoordinator.shared.permitsLocalObservation(
                startedAt: guardToken.privacyEpoch
            ) else {
                throw AgentToolError.commandFailed(
                    1,
                    "Local observation was discarded because user control began before the result was published."
                )
            }
        }
    }

    static func requiresTakeoverEmbargo(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> Bool {
        if toolName.hasPrefix("chrome_")
            || toolName.hasPrefix("embedded_browser_") {
            return true
        }
        guard takeoverEmbargoedToolNames.contains(toolName) else {
            return false
        }
        if toolName == "capture_screenshot" {
            let target = arguments["target"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? "mac_screen"
            return ["mac_screen", "mac", "screen", "desktop"].contains(target)
        }
        return true
    }

    static func requiresIdleControlLease(toolName: String) -> Bool {
        idleLeaseMaintenanceToolNames.contains(toolName)
    }

    static func handleFailure(
        _ error: Error,
        prepared: AgentComputerUsePreparedControl?
    ) async throws -> Never {
        guard let prepared else { throw error }
        if error is AgentComputerUseUserInputInterruptionError {
            await MainActor.run {
                _ = AgentComputerUseCoordinator.shared.takeover(
                    leaseID: prepared.leaseID
                )
            }
        }
        let phase = await MainActor.run {
            let coordinator = AgentComputerUseCoordinator.shared
            guard coordinator.state.lease?.id == prepared.leaseID else {
                return AgentComputerUseControlPhase.idle
            }
            return coordinator.state.phase
        }

        if phase == .paused || phase == .userTakeover {
            try await waitUntilControlReturns(
                leaseID: prepared.leaseID,
                owner: prepared.owner
            )
            await restartAndAcknowledgeTransportBarrier()
            throw AgentToolError.commandFailed(
                1,
                "Computer Use resumed after user control. The interrupted action was not replayed; capture a fresh app state before deciding what to do next."
            )
        }
        if error is AgentComputerUseStaleResultError {
            throw AgentToolError.commandFailed(
                1,
                "Computer Use discarded a stale result after a user-control handoff. Capture a fresh app state before deciding what to do next."
            )
        }
        if error is CancellationError {
            throw error
        }

        await MainActor.run {
            AgentComputerUseCoordinator.shared.fail(
                leaseID: prepared.leaseID,
                message: error.localizedDescription
            )
        }
        throw error
    }

    static func finishTurn(runtimeID: AgentSession.ID, turnID: UUID) async {
        let leaseID = await MainActor.run { () -> AgentComputerUseLease.ID? in
            let coordinator = AgentComputerUseCoordinator.shared
            guard let lease = coordinator.state.lease,
                  lease.owner.runtimeID == runtimeID,
                  lease.owner.turnID == turnID else {
                coordinator.finishTurn(runtimeID: runtimeID, turnID: turnID)
                return nil
            }
            return lease.id
        }
        if let leaseID {
            _ = try? await AgentComputerUseBridge.shared.endControlSession(
                controlLeaseID: leaseID.uuidString.lowercased()
            )
        }
        await MainActor.run {
            AgentComputerUseCoordinator.shared.finishTurn(
                runtimeID: runtimeID,
                turnID: turnID
            )
        }
    }

    private static func waitUntilControlReturns(
        leaseID: AgentComputerUseLease.ID,
        owner: AgentComputerUseOwner
    ) async throws {
        while true {
            try Task.checkCancellation()
            let phase = await MainActor.run {
                let state = AgentComputerUseCoordinator.shared.state
                guard let lease = state.lease,
                      lease.id == leaseID,
                      lease.belongs(to: owner) else {
                    return AgentComputerUseControlPhase.idle
                }
                return state.phase
            }
            switch phase {
            case .paused, .userTakeover:
                try await Task.sleep(nanoseconds: 150_000_000)
            case .observing, .controlling:
                return
            case .idle, .stopping:
                throw CancellationError()
            case .failed:
                throw AgentToolError.commandFailed(
                    1,
                    "Computer Use could not resume its control session."
                )
            }
        }
    }

    private static func handleSessionStartFailure(
        _ error: Error,
        lease: AgentComputerUseLease,
        owner: AgentComputerUseOwner
    ) async throws -> Never {
        if error is AgentComputerUseUserInputInterruptionError {
            await MainActor.run {
                _ = AgentComputerUseCoordinator.shared.takeover(
                    leaseID: lease.id
                )
            }
        }
        let phase = await MainActor.run {
            let state = AgentComputerUseCoordinator.shared.state
            guard state.lease?.id == lease.id else {
                return AgentComputerUseControlPhase.idle
            }
            return state.phase
        }
        switch sessionStartFailureDisposition(
            phase: phase,
            isCancellation: error is CancellationError
        ) {
        case .waitForUserControl:
            try await waitUntilControlReturns(
                leaseID: lease.id,
                owner: owner
            )
            await restartAndAcknowledgeTransportBarrier()
            throw AgentToolError.commandFailed(
                1,
                "Computer Use resumed after user control interrupted session setup. Capture a fresh app state before deciding what to do next."
            )
        case .cancel:
            throw CancellationError()
        case .fail:
            await MainActor.run {
                AgentComputerUseCoordinator.shared.fail(
                    leaseID: lease.id,
                    message: error.localizedDescription
                )
            }
            throw error
        }
    }

    static func sessionStartFailureDisposition(
        phase: AgentComputerUseControlPhase,
        isCancellation: Bool
    ) -> AgentComputerUseSessionStartFailureDisposition {
        if isCancellation {
            return .cancel
        }
        switch phase {
        case .paused, .userTakeover:
            return .waitForUserControl
        case .idle, .stopping:
            return .cancel
        case .observing, .controlling, .failed:
            return .fail
        }
    }

    private static func startBridgeControlSession(
        leaseID: AgentComputerUseLease.ID,
        target: AgentComputerUseTarget
    ) async throws -> [String: Any] {
        try await AgentComputerUseBridge.shared.startControlSession(
            controlLeaseID: leaseID.uuidString.lowercased(),
            targetPID: target.pid,
            targetApp: target.pid == nil
                ? (target.bundleIdentifier ?? target.applicationName)
                : nil
        )
    }

    private static func satisfyPendingTransportBarrier() async throws {
        while true {
            let pendingEpoch = await MainActor.run {
                AgentComputerUseCoordinator.shared.pendingTransportBarrierEpoch
            }
            guard let pendingEpoch else { return }
            await AgentComputerUseBridge.shared.restart()
            await MainActor.run {
                AgentComputerUseCoordinator.shared.acknowledgeTransportBarrier(
                    epoch: pendingEpoch
                )
            }
            try Task.checkCancellation()
        }
    }

    private static func ensureLeaseReadyForHelperStart(
        lease: AgentComputerUseLease,
        owner: AgentComputerUseOwner,
        target: AgentComputerUseTarget,
        privacyEpoch: UInt64
    ) async throws {
        let disposition = await MainActor.run {
            AgentComputerUseCoordinator.shared.resultPublicationDisposition(
                leaseID: lease.id,
                owner: owner,
                target: target,
                startedAtPrivacyEpoch: privacyEpoch
            )
        }
        switch disposition {
        case .publish:
            return
        case .userControl:
            try await waitUntilControlReturns(
                leaseID: lease.id,
                owner: owner
            )
            await restartAndAcknowledgeTransportBarrier()
            throw AgentToolError.commandFailed(
                1,
                "Computer Use resumed before helper setup completed. Capture a fresh app state instead of replaying the interrupted action."
            )
        case .staleHandoff:
            throw AgentToolError.commandFailed(
                1,
                "Computer Use changed hands before helper setup completed. Capture a fresh app state before continuing."
            )
        case .cancelled:
            throw CancellationError()
        }
    }

    private static func restartAndAcknowledgeTransportBarrier() async {
        let barrierEpoch = await MainActor.run {
            AgentComputerUseCoordinator.shared.requiredTransportBarrierEpoch
        }
        await AgentComputerUseBridge.shared.restart()
        await MainActor.run {
            AgentComputerUseCoordinator.shared.acknowledgeTransportBarrier(
                epoch: barrierEpoch
            )
        }
    }

    @MainActor
    private static func resolveTarget(
        arguments: [String: AgentJSONValue],
        owner: AgentComputerUseOwner,
        coordinator: AgentComputerUseCoordinator
    ) throws -> AgentComputerUseTarget {
        let pid = arguments["pid"]?.intValue()
        let app = arguments["app"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if pid != nil || !(app ?? "").isEmpty {
            let value = app ?? "macOS app"
            return try validatedTarget(AgentComputerUseTarget(
                pid: pid,
                applicationName: value,
                bundleIdentifier: value.contains(".") ? value : nil,
                windowTitle: nil
            ))
        }
        if let lease = coordinator.state.lease,
           lease.belongs(to: owner) {
            return try validatedTarget(lease.target)
        }
        throw AgentToolError.invalidArgument(
            "Computer Use needs an app or pid for the first state capture. Later ref-only actions may reuse the active target lease."
        )
    }

    @MainActor
    private static func validatedTarget(
        _ target: AgentComputerUseTarget
    ) throws -> AgentComputerUseTarget {
        let runningApplication = target.pid.flatMap { rawPID -> NSRunningApplication? in
            guard rawPID > 0, rawPID <= Int(Int32.max) else { return nil }
            return NSRunningApplication(processIdentifier: pid_t(rawPID))
        }
        if let reason = AgentComputerUseHostTargetBoundary.denialReason(
            pid: target.pid,
            requestedApplication: target.applicationName,
            requestedBundleIdentifier: target.bundleIdentifier,
            resolvedApplicationName: runningApplication?.localizedName,
            resolvedBundleIdentifier: runningApplication?.bundleIdentifier,
            hostPID: Int(ProcessInfo.processInfo.processIdentifier),
            parentPID: Int(getppid())
        ) {
            throw AgentToolError.invalidArgument(reason)
        }
        return AgentComputerUseTarget(
            pid: target.pid,
            applicationName: runningApplication?.localizedName
                ?? target.applicationName,
            bundleIdentifier: runningApplication?.bundleIdentifier
                ?? target.bundleIdentifier,
            windowTitle: target.windowTitle
        )
    }

    private static func targetFromPayload(
        _ payload: String
    ) -> AgentComputerUseTarget? {
        let jsonText = payload.components(
            separatedBy: "\n\nCoordinate rule:"
        ).first ?? payload
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let app = root["app"] as? [String: Any] ?? root
        let pid = integer(app["pid"]) ?? integer(root["target_pid"])
        let name = app["name"] as? String
        let bundleID = app["bundle_id"] as? String
        guard pid != nil || name != nil || bundleID != nil else { return nil }
        return AgentComputerUseTarget(
            pid: pid,
            applicationName: name ?? bundleID ?? "macOS app",
            bundleIdentifier: bundleID,
            windowTitle: windowTitle(in: root["tree"])
        )
    }

    private static func windowTitle(in value: Any?) -> String? {
        guard let node = value as? [String: Any] else { return nil }
        if node["role"] as? String == "AXWindow",
           let title = node["title"] as? String,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        guard let children = node["children"] as? [[String: Any]] else {
            return nil
        }
        for child in children {
            if let title = windowTitle(in: child) {
                return title
            }
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

nonisolated enum AgentComputerUseHostTargetBoundary {
    // Keep terminal control open while Computer Use is under active
    // development. The Helper mirrors this switch and still blocks WillDeep
    // itself plus protected or credential-like input fields.
    private static let terminalApplicationRestrictionsEnabled = false
    private static let forbiddenBundlePrefixes = [
        "com.willdeep.",
    ]
    private static let terminalBundlePrefixes = [
        "com.apple.terminal",
        "com.googlecode.iterm",
        "dev.warp.",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.",
        "com.mitchellh.ghostty",
        "com.electron.hyper",
        "co.zeit.hyper",
        "io.tabby",
        "com.raphaelamorim.rio",
    ]

    private static let forbiddenApplicationNames: Set<String> = [
        "willdeep",
        "willdeep computer use helper",
    ]
    private static let terminalApplicationNames: Set<String> = [
        "terminal",
        "iterm",
        "iterm2",
        "warp",
        "warp terminal",
        "alacritty",
        "kitty",
        "wezterm",
        "ghostty",
        "hyper",
        "tabby",
        "rio",
    ]

    static func denialReason(
        pid: Int?,
        requestedApplication: String?,
        requestedBundleIdentifier: String?,
        resolvedApplicationName: String?,
        resolvedBundleIdentifier: String?,
        hostPID: Int,
        parentPID: Int
    ) -> String? {
        if let pid, pid == hostPID || pid == parentPID {
            return "Computer Use cannot target WillDeep or its parent process. This prevents an agent from operating its own approval and control UI."
        }

        let bundleIdentifiers = [
            requestedBundleIdentifier,
            requestedApplication,
            resolvedBundleIdentifier,
        ].compactMap(normalizedIdentifier)
        if bundleIdentifiers.contains(where: { identifier in
            forbiddenBundlePrefixes.contains { prefix in
                identifier.hasPrefix(prefix)
            }
        }) {
            return "Computer Use cannot target WillDeep or its helper. This prevents an agent from operating its own approval and control UI."
        }
        if terminalApplicationRestrictionsEnabled,
           bundleIdentifiers.contains(where: { identifier in
               terminalBundlePrefixes.contains { prefix in
                   identifier.hasPrefix(prefix)
               }
           }) {
            return "Computer Use cannot target a terminal application. Use the audited command and terminal tools instead."
        }

        let applicationNames = [
            requestedApplication,
            resolvedApplicationName,
        ].compactMap(normalizedApplicationName)
        if applicationNames.contains(where: forbiddenApplicationNames.contains) {
            return "Computer Use cannot target WillDeep or its helper. This prevents an agent from operating its own approval and control UI."
        }
        if terminalApplicationRestrictionsEnabled,
           applicationNames.contains(where: terminalApplicationNames.contains) {
            return "Computer Use cannot target a terminal application. Use the audited command and terminal tools instead."
        }
        return nil
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedApplicationName(_ value: String?) -> String? {
        guard let value else { return nil }
        var name = URL(fileURLWithPath: value).lastPathComponent
        if name.lowercased().hasSuffix(".app") {
            name.removeLast(4)
        }
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
