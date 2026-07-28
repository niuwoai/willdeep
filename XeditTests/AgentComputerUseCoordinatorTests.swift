import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentComputerUseCoordinatorTests {
    @Test("operational lease approval stays bound to runtime and target")
    func operationalLeaseApprovalRequiresMatchingRuntimeAndTarget() throws {
        let runtimeID = UUID()
        let owner = makeOwner(runtimeID: runtimeID)
        let target = makeTarget(pid: 741, name: "GitWise")
        let lease = AgentComputerUseLease(
            owner: owner,
            target: target,
            operation: .controlling
        )
        let arguments: [String: AgentJSONValue] = [
            "pid": .number(741),
            "snapshot_id": .string("snapshot"),
            "direction": .string("down"),
        ]

        #expect(
            AgentComputerUsePolicy.canAutoApproveInOperationalLease(
                toolName: "computer_use_scroll",
                arguments: arguments,
                owner: owner,
                controlState: .controlling(lease)
            )
        )
        #expect(
            !AgentComputerUsePolicy.canAutoApproveInOperationalLease(
                toolName: "computer_use_scroll",
                arguments: arguments,
                owner: owner,
                controlState: .observing(lease)
            )
        )
        #expect(
            !AgentComputerUsePolicy.canAutoApproveInOperationalLease(
                toolName: "computer_use_scroll",
                arguments: arguments,
                owner: makeOwner(
                    runtimeID: UUID(),
                    turnID: owner.turnID
                ),
                controlState: .controlling(lease)
            )
        )
        #expect(
            !AgentComputerUsePolicy.canAutoApproveInOperationalLease(
                toolName: "computer_use_scroll",
                arguments: arguments,
                owner: makeOwner(
                    runtimeID: owner.runtimeID,
                    turnID: UUID()
                ),
                controlState: .controlling(lease)
            )
        )
        #expect(
            !AgentComputerUsePolicy.canAutoApproveInOperationalLease(
                toolName: "computer_use_scroll",
                arguments: [
                    "pid": .number(999),
                    "snapshot_id": .string("snapshot"),
                    "direction": .string("down"),
                ],
                owner: owner,
                controlState: .controlling(lease)
            )
        )
    }

    @Test("non-operational lease phases never auto-approve control")
    func nonOperationalLeasePhasesDoNotAutoApprove() throws {
        let runtimeID = UUID()
        let owner = makeOwner(runtimeID: runtimeID)
        let lease = AgentComputerUseLease(
            owner: owner,
            target: makeTarget(pid: 741, name: "GitWise"),
            operation: .controlling
        )
        let arguments: [String: AgentJSONValue] = [
            "pid": .number(741),
            "snapshot_id": .string("snapshot"),
            "direction": .string("down"),
        ]

        for state in [
            AgentComputerUseControlState.paused(lease),
            AgentComputerUseControlState.userTakeover(lease),
            AgentComputerUseControlState.stopping(lease),
            AgentComputerUseControlState.failed(lease, message: "helper unavailable"),
            AgentComputerUseControlState.idle,
        ] {
            #expect(
                !AgentComputerUsePolicy.canAutoApproveInOperationalLease(
                    toolName: "computer_use_scroll",
                    arguments: arguments,
                    owner: owner,
                    controlState: state
                )
            )
        }
    }

    @Test("session-start failures preserve explicit user control states")
    func sessionStartFailurePreservesUserControl() {
        #expect(
            AgentComputerUseExecution.sessionStartFailureDisposition(
                phase: .paused,
                isCancellation: false
            ) == .waitForUserControl
        )
        #expect(
            AgentComputerUseExecution.sessionStartFailureDisposition(
                phase: .userTakeover,
                isCancellation: false
            ) == .waitForUserControl
        )
        #expect(
            AgentComputerUseExecution.sessionStartFailureDisposition(
                phase: .stopping,
                isCancellation: false
            ) == .cancel
        )
        #expect(
            AgentComputerUseExecution.sessionStartFailureDisposition(
                phase: .controlling,
                isCancellation: false
            ) == .fail
        )
        #expect(
            AgentComputerUseExecution.sessionStartFailureDisposition(
                phase: .paused,
                isCancellation: true
            ) == .cancel
        )
    }

    @Test("begin binds the global lease to its runtime, turn, target, and task")
    func beginBindsCompleteOwnership() throws {
        let coordinator = AgentComputerUseCoordinator()
        let owner = makeOwner(title: "Review GitWise")
        let target = makeTarget(pid: 741, name: "GitWise")

        let lease = try #require(
            coordinator.begin(
                operation: .controlling,
                owner: owner,
                target: target,
                actionName: "computer_use_click",
                now: Date(timeIntervalSince1970: 100)
            )
        )

        #expect(coordinator.state.phase == .controlling)
        #expect(lease.owner == owner)
        #expect(lease.target == target)
        #expect(lease.operation == .controlling)
        #expect(lease.lastActionName == "computer_use_click")
        #expect(lease.startedAt == Date(timeIntervalSince1970: 100))
    }

    @Test("a live lease is globally exclusive across runtimes and targets")
    func leaseIsGloballyExclusive() throws {
        let coordinator = AgentComputerUseCoordinator()
        let firstOwner = makeOwner(title: "First task")
        let firstTarget = makeTarget(pid: 101, name: "First App")
        let firstLease = try #require(
            coordinator.begin(
                operation: .controlling,
                owner: firstOwner,
                target: firstTarget
            )
        )

        let secondOwner = makeOwner(title: "Second task")
        let secondTarget = makeTarget(pid: 202, name: "Second App")
        #expect(
            coordinator.begin(
                operation: .observing,
                owner: secondOwner,
                target: secondTarget
            ) == nil
        )
        #expect(coordinator.state.lease?.id == firstLease.id)

        coordinator.finishTurn(
            runtimeID: firstOwner.runtimeID,
            turnID: firstOwner.turnID
        )
        #expect(coordinator.state.phase == .idle)
        #expect(
            coordinator.begin(
                operation: .observing,
                owner: secondOwner,
                target: secondTarget
            ) != nil
        )
    }

    @Test("the same owner may refresh its operation without changing lease identity")
    func sameOwnerRefreshesLease() throws {
        let coordinator = AgentComputerUseCoordinator()
        var owner = makeOwner(title: "Original title")
        let target = makeTarget(pid: 303, name: "Editor")
        let original = try #require(
            coordinator.begin(
                operation: .observing,
                owner: owner,
                target: target
            )
        )

        owner.sessionTitle = "Renamed task"
        let refreshed = try #require(
            coordinator.begin(
                operation: .controlling,
                owner: owner,
                target: target,
                actionName: "computer_use_type_text"
            )
        )

        #expect(refreshed.id == original.id)
        #expect(refreshed.owner.sessionTitle == "Renamed task")
        #expect(refreshed.operation == .controlling)
        #expect(coordinator.state.phase == .controlling)
    }

    @Test("an established controlling lease cannot be downgraded by observation")
    func observingDoesNotDowngradeControl() throws {
        let coordinator = AgentComputerUseCoordinator()
        let owner = makeOwner()
        let target = makeTarget()
        let original = try #require(
            coordinator.begin(
                operation: .controlling,
                owner: owner,
                target: target
            )
        )

        let refreshed = try #require(
            coordinator.begin(
                operation: .observing,
                owner: owner,
                target: target
            )
        )

        #expect(refreshed.id == original.id)
        #expect(refreshed.operation == .controlling)
        #expect(coordinator.state.phase == .controlling)
    }

    @Test("target identity uses pid when both exist and normalized app identity otherwise")
    func targetIdentitySupportsMissingPID() throws {
        let owner = makeOwner()
        let coordinator = AgentComputerUseCoordinator()
        let targetWithoutPID = AgentComputerUseTarget(
            pid: nil,
            applicationName: "  Café.app ",
            bundleIdentifier: nil,
            windowTitle: nil
        )
        let original = try #require(
            coordinator.begin(
                operation: .observing,
                owner: owner,
                target: targetWithoutPID
            )
        )
        let resolvedTarget = AgentComputerUseTarget(
            pid: 412,
            applicationName: "CAFE",
            bundleIdentifier: "com.example.cafe",
            windowTitle: "Main"
        )

        let refreshed = try #require(
            coordinator.begin(
                operation: .controlling,
                owner: owner,
                target: resolvedTarget
            )
        )
        #expect(refreshed.id == original.id)
        #expect(refreshed.target.pid == 412)

        let sameNameDifferentPID = AgentComputerUseTarget(
            pid: 413,
            applicationName: "Cafe",
            bundleIdentifier: "com.example.cafe",
            windowTitle: nil
        )
        #expect(
            coordinator.authorize(
                owner: owner,
                target: sameNameDifferentPID
            ) == .denied(
                reason: .targetMismatch,
                activeLease: refreshed
            )
        )
    }

    @Test("authorization reports conflicts without mutating the active lease")
    func authorizationIsReadOnly() throws {
        let coordinator = AgentComputerUseCoordinator()
        let owner = makeOwner()
        let target = makeTarget()
        let lease = try #require(
            coordinator.begin(
                operation: .controlling,
                owner: owner,
                target: target
            )
        )
        let otherOwner = makeOwner()

        let authorization = coordinator.authorize(
            owner: otherOwner,
            target: target
        )

        #expect(
            authorization == .denied(
                reason: .ownedByAnotherTurn,
                activeLease: lease
            )
        )
        #expect(coordinator.state == .controlling(lease))
    }

    @Test("pause, takeover, resume, and stop form an explicit user-control path")
    func userControlTransitions() throws {
        let coordinator = AgentComputerUseCoordinator()
        let lease = try #require(
            coordinator.begin(
                operation: .controlling,
                owner: makeOwner(),
                target: makeTarget()
            )
        )

        #expect(coordinator.pause(leaseID: lease.id, emitIntent: false))
        #expect(coordinator.state.phase == .paused)
        let pauseBarrier = try #require(
            coordinator.pendingTransportBarrierEpoch
        )
        #expect(coordinator.resume(leaseID: lease.id, emitIntent: false))
        #expect(coordinator.state.phase == .paused)
        coordinator.acknowledgeTransportBarrier(epoch: pauseBarrier)
        #expect(coordinator.state.phase == .controlling)
        #expect(coordinator.takeover(leaseID: lease.id, emitIntent: false))
        #expect(coordinator.state.phase == .userTakeover)
        let takeoverBarrier = try #require(
            coordinator.pendingTransportBarrierEpoch
        )
        #expect(coordinator.resume(leaseID: lease.id, emitIntent: false))
        #expect(coordinator.state.phase == .userTakeover)
        coordinator.acknowledgeTransportBarrier(epoch: takeoverBarrier)
        #expect(coordinator.state.phase == .controlling)
        #expect(coordinator.stop(leaseID: lease.id, emitIntent: false))
        #expect(coordinator.state.phase == .stopping)

        coordinator.complete(leaseID: lease.id)
        #expect(coordinator.state.phase == .idle)
    }

    @Test("real user input takes over only the matching helper lease")
    func helperUserInputTriggersTakeover() throws {
        let notificationCenter = NotificationCenter()
        let coordinator = AgentComputerUseCoordinator(
            notificationCenter: notificationCenter
        )
        let lease = try #require(
            coordinator.begin(
                operation: .controlling,
                owner: makeOwner(),
                target: makeTarget()
            )
        )

        notificationCenter.post(
            name: AgentComputerUseBridge.userInputNotification,
            object: nil,
            userInfo: ["control_lease_id": UUID().uuidString]
        )
        #expect(coordinator.state.phase == .controlling)

        notificationCenter.post(
            name: AgentComputerUseBridge.userInputNotification,
            object: nil,
            userInfo: ["control_lease_id": lease.id.uuidString]
        )
        #expect(coordinator.state.phase == .userTakeover)
    }

    @Test("stop revokes reacquisition for the rest of the owning turn")
    func stopRevokesOwningTurn() throws {
        let coordinator = AgentComputerUseCoordinator()
        let owner = makeOwner()
        let target = makeTarget()
        let lease = try #require(
            coordinator.begin(
                operation: .controlling,
                owner: owner,
                target: target
            )
        )

        #expect(coordinator.stop(leaseID: lease.id, emitIntent: false))
        coordinator.complete(leaseID: lease.id)
        #expect(coordinator.state.phase == .idle)
        #expect(
            coordinator.authorize(owner: owner, target: target)
                == .denied(reason: .revoked, activeLease: nil)
        )
        #expect(
            coordinator.begin(
                operation: .controlling,
                owner: owner,
                target: target
            ) == nil
        )

        let nextTurnOwner = makeOwner(runtimeID: owner.runtimeID)
        #expect(
            coordinator.begin(
                operation: .observing,
                owner: nextTurnOwner,
                target: target
            ) != nil
        )
    }

    @Test("finishing a stopped turn clears its revocation marker")
    func finishTurnClearsRevocation() throws {
        let coordinator = AgentComputerUseCoordinator()
        let owner = makeOwner()
        let target = makeTarget()
        let lease = try #require(
            coordinator.begin(
                operation: .controlling,
                owner: owner,
                target: target
            )
        )

        #expect(coordinator.stop(leaseID: lease.id, emitIntent: false))
        coordinator.complete(leaseID: lease.id)
        coordinator.finishTurn(
            runtimeID: owner.runtimeID,
            turnID: owner.turnID
        )

        #expect(coordinator.lastRevokedOwner == nil)
        #expect(
            coordinator.authorize(owner: owner, target: target)
                == .allowed(existingLease: nil)
        )
    }

    @Test("resume restores an observing lease to observing")
    func resumePreservesOperationKind() throws {
        let coordinator = AgentComputerUseCoordinator()
        let lease = try #require(
            coordinator.begin(
                operation: .observing,
                owner: makeOwner(),
                target: makeTarget()
            )
        )

        #expect(coordinator.takeover(leaseID: lease.id, emitIntent: false))
        let barrierEpoch = try #require(
            coordinator.pendingTransportBarrierEpoch
        )
        #expect(coordinator.resume(leaseID: lease.id, emitIntent: false))
        #expect(coordinator.state.phase == .userTakeover)
        coordinator.acknowledgeTransportBarrier(epoch: barrierEpoch)
        #expect(coordinator.state.phase == .observing)
    }

    @Test("paused and takeover states reject silent tool reacquisition")
    func userYieldStatesRejectBegin() throws {
        let coordinator = AgentComputerUseCoordinator()
        let owner = makeOwner()
        let target = makeTarget()
        let lease = try #require(
            coordinator.begin(
                operation: .controlling,
                owner: owner,
                target: target
            )
        )

        #expect(coordinator.pause(leaseID: lease.id, emitIntent: false))
        #expect(
            coordinator.begin(
                operation: .controlling,
                owner: owner,
                target: target
            ) == nil
        )
        #expect(coordinator.takeover(leaseID: lease.id, emitIntent: false))
        #expect(
            coordinator.begin(
                operation: .controlling,
                owner: owner,
                target: target
            ) == nil
        )
    }

    @Test("only the owning turn can close the global presentation")
    func finishTurnIsOwnerScoped() throws {
        let coordinator = AgentComputerUseCoordinator()
        let owner = makeOwner()
        _ = try #require(
            coordinator.begin(
                operation: .controlling,
                owner: owner,
                target: makeTarget()
            )
        )

        coordinator.finishTurn(runtimeID: UUID(), turnID: owner.turnID)
        #expect(coordinator.state.phase == .controlling)
        coordinator.finishTurn(runtimeID: owner.runtimeID, turnID: UUID())
        #expect(coordinator.state.phase == .controlling)
        coordinator.finishTurn(
            runtimeID: owner.runtimeID,
            turnID: owner.turnID
        )
        #expect(coordinator.state.phase == .idle)
    }

    @Test("stale callbacks cannot mutate a newer lease")
    func staleCallbacksAreIgnored() throws {
        let coordinator = AgentComputerUseCoordinator()
        let firstOwner = makeOwner()
        let firstLease = try #require(
            coordinator.begin(
                operation: .controlling,
                owner: firstOwner,
                target: makeTarget(pid: 1)
            )
        )
        coordinator.finishTurn(
            runtimeID: firstOwner.runtimeID,
            turnID: firstOwner.turnID
        )

        let secondLease = try #require(
            coordinator.begin(
                operation: .observing,
                owner: makeOwner(),
                target: makeTarget(pid: 2)
            )
        )
        coordinator.complete(
            leaseID: firstLease.id,
            actionName: "stale-action"
        )
        coordinator.fail(
            leaseID: firstLease.id,
            message: "stale failure"
        )

        #expect(coordinator.state.lease?.id == secondLease.id)
        #expect(coordinator.state.phase == .observing)
        #expect(coordinator.state.failureMessage == nil)
    }

    @Test("failure remains attributed and the matching turn can dismiss it")
    func failureKeepsOwnershipUntilTurnEnds() throws {
        let coordinator = AgentComputerUseCoordinator()
        let owner = makeOwner()
        let lease = try #require(
            coordinator.begin(
                operation: .controlling,
                owner: owner,
                target: makeTarget()
            )
        )

        coordinator.fail(leaseID: lease.id, message: "Permission revoked")
        #expect(coordinator.state.phase == .failed)
        #expect(coordinator.state.failureMessage == "Permission revoked")
        #expect(coordinator.state.lease?.owner == owner)

        coordinator.finishTurn(
            runtimeID: owner.runtimeID,
            turnID: owner.turnID
        )
        #expect(coordinator.state.phase == .idle)
    }

    @Test("private takeover invalidates observations and keeps a restart barrier through fast resume")
    func takeoverInvalidatesObservationAndRequiresBarrier() throws {
        let coordinator = AgentComputerUseCoordinator()
        let lease = try #require(
            coordinator.begin(
                operation: .controlling,
                owner: makeOwner(),
                target: makeTarget()
            )
        )
        let observationEpoch = try #require(coordinator.beginLocalObservation())
        #expect(coordinator.permitsLocalObservation(startedAt: observationEpoch))

        #expect(coordinator.takeover(leaseID: lease.id, emitIntent: false))
        let barrierEpoch = try #require(coordinator.pendingTransportBarrierEpoch)
        #expect(coordinator.beginLocalObservation() == nil)
        #expect(!coordinator.permitsLocalObservation(startedAt: observationEpoch))

        #expect(coordinator.resume(leaseID: lease.id, emitIntent: false))
        #expect(coordinator.state.phase == .userTakeover)
        #expect(coordinator.pendingTransportBarrierEpoch == barrierEpoch)
        #expect(!coordinator.permitsLocalObservation(startedAt: observationEpoch))

        coordinator.acknowledgeTransportBarrier(epoch: barrierEpoch)
        #expect(coordinator.state.phase == .controlling)
        #expect(coordinator.pendingTransportBarrierEpoch == nil)
        let resumedEpoch = try #require(coordinator.beginLocalObservation())
        #expect(coordinator.permitsLocalObservation(startedAt: resumedEpoch))
    }

    @Test("tool results cannot publish across pause and resume")
    func resultPublicationRequiresMatchingLeasePhaseAndEpoch() throws {
        let coordinator = AgentComputerUseCoordinator()
        let owner = makeOwner()
        let target = makeTarget()
        let lease = try #require(
            coordinator.begin(
                operation: .controlling,
                owner: owner,
                target: target
            )
        )
        let startedEpoch = coordinator.privacyEpoch
        #expect(
            coordinator.resultPublicationDisposition(
                leaseID: lease.id,
                owner: owner,
                target: target,
                startedAtPrivacyEpoch: startedEpoch
            ) == .publish
        )

        #expect(coordinator.pause(leaseID: lease.id, emitIntent: false))
        #expect(
            coordinator.resultPublicationDisposition(
                leaseID: lease.id,
                owner: owner,
                target: target,
                startedAtPrivacyEpoch: startedEpoch
            ) == .userControl
        )

        let barrierEpoch = try #require(
            coordinator.pendingTransportBarrierEpoch
        )
        #expect(coordinator.resume(leaseID: lease.id, emitIntent: false))
        #expect(coordinator.state.phase == .paused)
        #expect(
            coordinator.resultPublicationDisposition(
                leaseID: lease.id,
                owner: owner,
                target: target,
                startedAtPrivacyEpoch: startedEpoch
            ) == .userControl
        )
        coordinator.acknowledgeTransportBarrier(epoch: barrierEpoch)
        #expect(
            coordinator.resultPublicationDisposition(
                leaseID: lease.id,
                owner: owner,
                target: target,
                startedAtPrivacyEpoch: startedEpoch
            ) == .staleHandoff
        )
        #expect(
            coordinator.resultPublicationDisposition(
                leaseID: UUID(),
                owner: owner,
                target: target,
                startedAtPrivacyEpoch: coordinator.privacyEpoch
            ) == .cancelled
        )
    }

    @Test("helper maintenance and control leases are mutually exclusive")
    func maintenanceReservationExcludesControl() throws {
        let coordinator = AgentComputerUseCoordinator()
        let reservationID = try #require(
            coordinator.beginIdleMaintenanceReservation()
        )
        #expect(
            coordinator.begin(
                operation: .controlling,
                owner: makeOwner(),
                target: makeTarget()
            ) == nil
        )
        #expect(coordinator.beginIdleMaintenanceReservation() == nil)

        coordinator.endIdleMaintenanceReservation(reservationID)
        let lease = try #require(
            coordinator.begin(
                operation: .controlling,
                owner: makeOwner(),
                target: makeTarget()
            )
        )
        #expect(coordinator.beginIdleMaintenanceReservation() == nil)
        #expect(coordinator.state.lease?.id == lease.id)
    }

    @Test("takeover embargo covers local visual, browser, shell, and clipboard-capable routes")
    func takeoverEmbargoClassification() {
        #expect(
            AgentComputerUseExecution.requiresTakeoverEmbargo(
                toolName: "capture_screenshot",
                arguments: [:]
            )
        )
        #expect(
            !AgentComputerUseExecution.requiresTakeoverEmbargo(
                toolName: "capture_screenshot",
                arguments: ["target": .string("android")]
            )
        )
        for toolName in [
            "visual_qa_screenshot",
            "chrome_read_page",
            "chrome_capture_tab",
            "embedded_browser_capture_screenshot",
            "run_command",
            "terminal_send_command",
            "call_mcp_tool",
        ] {
            #expect(
                AgentComputerUseExecution.requiresTakeoverEmbargo(
                    toolName: toolName,
                    arguments: [:]
                )
            )
        }
        #expect(
            !AgentComputerUseExecution.requiresTakeoverEmbargo(
                toolName: "read_file",
                arguments: [:]
            )
        )
        #expect(
            AgentComputerUseExecution.requiresIdleControlLease(
                toolName: "computer_use_restart_helper"
            )
        )
        #expect(
            AgentComputerUseExecution.requiresIdleControlLease(
                toolName: "computer_use_request_permissions"
            )
        )
        #expect(
            !AgentComputerUseExecution.requiresIdleControlLease(
                toolName: "computer_use_permissions"
            )
        )
    }

    @Test("host boundary rejects WillDeep and terminal targets")
    func hostTargetBoundaryRejectsSelfAndTerminals() {
        #expect(
            AgentComputerUseHostTargetBoundary.denialReason(
                pid: 500,
                requestedApplication: "Finder",
                requestedBundleIdentifier: "com.apple.finder",
                resolvedApplicationName: "Finder",
                resolvedBundleIdentifier: "com.apple.finder",
                hostPID: 500,
                parentPID: 400
            ) != nil
        )
        #expect(
            AgentComputerUseHostTargetBoundary.denialReason(
                pid: 401,
                requestedApplication: "Terminal.app",
                requestedBundleIdentifier: nil,
                resolvedApplicationName: "Terminal",
                resolvedBundleIdentifier: "com.apple.Terminal",
                hostPID: 500,
                parentPID: 400
            ) != nil
        )
        #expect(
            AgentComputerUseHostTargetBoundary.denialReason(
                pid: 402,
                requestedApplication: "Warp",
                requestedBundleIdentifier: "dev.warp.Warp-Stable",
                resolvedApplicationName: "Warp",
                resolvedBundleIdentifier: "dev.warp.Warp-Stable",
                hostPID: 500,
                parentPID: 400
            ) != nil
        )
        #expect(
            AgentComputerUseHostTargetBoundary.denialReason(
                pid: 403,
                requestedApplication: "Finder",
                requestedBundleIdentifier: "com.apple.finder",
                resolvedApplicationName: "Finder",
                resolvedBundleIdentifier: "com.apple.finder",
                hostPID: 500,
                parentPID: 400
            ) == nil
        )
    }

    @Test("runtime exposes a stable Computer Use owner only during a turn")
    func runtimeOwnerContextTracksActiveTurn() throws {
        let runtime = AgentRuntime(session: AgentSession(title: "UI review"))
        #expect(runtime.computerUseOwner == nil)

        let turnID = UUID()
        runtime.activeTurnID = turnID
        let owner = try #require(runtime.computerUseOwner)
        #expect(owner.runtimeID == runtime.id)
        #expect(owner.turnID == turnID)
        #expect(owner.sessionTitle == "UI review")
    }

    private func makeOwner(
        runtimeID: UUID = UUID(),
        turnID: UUID = UUID(),
        title: String = "Computer Use task"
    ) -> AgentComputerUseOwner {
        AgentComputerUseOwner(
            runtimeID: runtimeID,
            turnID: turnID,
            sessionTitle: title
        )
    }

    private func makeTarget(
        pid: Int = 909,
        name: String = "Target App"
    ) -> AgentComputerUseTarget {
        AgentComputerUseTarget(
            pid: pid,
            applicationName: name,
            bundleIdentifier: "com.example.target",
            windowTitle: "Main Window"
        )
    }
}
