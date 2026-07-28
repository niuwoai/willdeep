//
//  AgentComputerUseCoordinator.swift
//  WillDeep
//
//  Global, exclusive presentation state for native macOS Computer Use.
//  Tool execution remains owned by the Agent loop and the helper bridge; this
//  coordinator gives every window one truthful control-session model and a
//  user-intent channel for Pause / Take Over / Resume / Stop.
//

import Combine
import Foundation

nonisolated enum AgentComputerUseOperation: String, Equatable, Sendable {
    case observing
    case controlling
}

nonisolated struct AgentComputerUseOwner: Equatable, Sendable {
    let runtimeID: AgentSession.ID
    let turnID: UUID
    var sessionTitle: String
}

nonisolated struct AgentComputerUseTarget: Equatable, Sendable {
    var pid: Int?
    var applicationName: String
    var bundleIdentifier: String?
    var windowTitle: String?

    func matches(_ other: AgentComputerUseTarget) -> Bool {
        if let pid, let otherPID = other.pid {
            return pid == otherPID
        }

        let bundleIdentifier = Self.normalized(bundleIdentifier)
        let otherBundleIdentifier = Self.normalized(other.bundleIdentifier)
        if let bundleIdentifier, let otherBundleIdentifier {
            return bundleIdentifier == otherBundleIdentifier
        }

        guard let applicationName = Self.normalizedApplicationName(applicationName),
              let otherApplicationName = Self.normalizedApplicationName(
                other.applicationName
              ) else {
            return false
        }
        return applicationName == otherApplicationName
    }

    func mergingKnownIdentity(
        from newerTarget: AgentComputerUseTarget
    ) -> AgentComputerUseTarget {
        AgentComputerUseTarget(
            pid: newerTarget.pid ?? pid,
            applicationName: Self.normalized(newerTarget.applicationName) == nil
                ? applicationName
                : newerTarget.applicationName,
            bundleIdentifier: Self.normalized(newerTarget.bundleIdentifier) == nil
                ? bundleIdentifier
                : newerTarget.bundleIdentifier,
            windowTitle: newerTarget.windowTitle ?? windowTitle
        )
    }

    private static func normalizedApplicationName(_ value: String) -> String? {
        guard var normalizedValue = normalized(value) else { return nil }
        if normalizedValue.hasSuffix(".app") {
            normalizedValue.removeLast(4)
        }
        return normalized(normalizedValue)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalizedValue = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
        return normalizedValue.isEmpty ? nil : normalizedValue
    }
}

nonisolated struct AgentComputerUseLease: Equatable, Identifiable, Sendable {
    let id: UUID
    var owner: AgentComputerUseOwner
    var target: AgentComputerUseTarget
    var operation: AgentComputerUseOperation
    let startedAt: Date
    var updatedAt: Date
    var lastActionName: String?
    var latestActivity: AgentComputerUseActivity?

    init(
        id: UUID = UUID(),
        owner: AgentComputerUseOwner,
        target: AgentComputerUseTarget,
        operation: AgentComputerUseOperation,
        startedAt: Date = Date(),
        updatedAt: Date? = nil,
        lastActionName: String? = nil,
        latestActivity: AgentComputerUseActivity? = nil
    ) {
        self.id = id
        self.owner = owner
        self.target = target
        self.operation = operation
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
        self.lastActionName = lastActionName
        self.latestActivity = latestActivity
    }

    func belongs(to owner: AgentComputerUseOwner) -> Bool {
        self.owner.runtimeID == owner.runtimeID
            && self.owner.turnID == owner.turnID
    }

    func targets(_ target: AgentComputerUseTarget) -> Bool {
        self.target.matches(target)
    }
}

nonisolated enum AgentComputerUseAuthorizationDenial: String, Equatable, Sendable {
    case ownedByAnotherTurn
    case targetMismatch
    case maintenance
    case paused
    case userTakeover
    case stopping
    case revoked
}

nonisolated enum AgentComputerUseAuthorization: Equatable, Sendable {
    case allowed(existingLease: AgentComputerUseLease?)
    case denied(
        reason: AgentComputerUseAuthorizationDenial,
        activeLease: AgentComputerUseLease?
    )

    var isAllowed: Bool {
        guard case .allowed = self else { return false }
        return true
    }
}

nonisolated enum AgentComputerUseControlPhase: String, Equatable, Sendable {
    case idle
    case observing
    case controlling
    case paused
    case userTakeover
    case stopping
    case failed
}

nonisolated enum AgentComputerUseResultPublicationDisposition: Equatable, Sendable {
    case publish
    case userControl
    case staleHandoff
    case cancelled
}

nonisolated enum AgentComputerUseControlState: Equatable, Sendable {
    case idle
    case observing(AgentComputerUseLease)
    case controlling(AgentComputerUseLease)
    case paused(AgentComputerUseLease)
    case userTakeover(AgentComputerUseLease)
    case stopping(AgentComputerUseLease)
    case failed(AgentComputerUseLease?, message: String)

    var phase: AgentComputerUseControlPhase {
        switch self {
        case .idle: return .idle
        case .observing: return .observing
        case .controlling: return .controlling
        case .paused: return .paused
        case .userTakeover: return .userTakeover
        case .stopping: return .stopping
        case .failed: return .failed
        }
    }

    var lease: AgentComputerUseLease? {
        switch self {
        case .idle:
            return nil
        case .observing(let lease),
             .controlling(let lease),
             .paused(let lease),
             .userTakeover(let lease),
             .stopping(let lease):
            return lease
        case .failed(let lease, _):
            return lease
        }
    }

    var failureMessage: String? {
        guard case .failed(_, let message) = self else { return nil }
        return message
    }

    var isPresented: Bool {
        phase != .idle
    }
}

nonisolated enum AgentComputerUseControlIntent: String, Equatable, Sendable {
    case pause
    case takeover
    case resume
    case stop
}

nonisolated struct AgentComputerUseControlIntentEvent: Equatable, Sendable {
    let intent: AgentComputerUseControlIntent
    let lease: AgentComputerUseLease
}

extension Notification.Name {
    static let agentComputerUseControlIntent = Notification.Name(
        "WillDeep.AgentComputerUseControlIntent"
    )
}

@MainActor
final class AgentComputerUseCoordinator: ObservableObject {
    static let shared = AgentComputerUseCoordinator()
    nonisolated private static let controlLeaseIDUserInfoKey = "control_lease_id"

    @Published private(set) var state: AgentComputerUseControlState = .idle
    private(set) var lastRevokedOwner: AgentComputerUseOwner?
    /// Monotonic boundary for anything that could expose screen contents.
    ///
    /// A capture/result that started before Pause / Take Over / Resume must
    /// never become visible afterward, even if the user resumes so quickly
    /// that the phase is operational again by completion time.
    private(set) var privacyEpoch: UInt64 = 0
    /// The newest handoff that requires the helper transport to be torn down.
    private(set) var requiredTransportBarrierEpoch: UInt64 = 0
    private(set) var acknowledgedTransportBarrierEpoch: UInt64 = 0
    private(set) var maintenanceReservationID: UUID?
    private var pendingResumeRequest: (
        leaseID: AgentComputerUseLease.ID,
        emitIntent: Bool
    )?

    private let notificationCenter: NotificationCenter
    private var userInputObserver: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        userInputObserver = notificationCenter.addObserver(
            forName: AgentComputerUseBridge.userInputNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let rawLeaseID = notification.userInfo?[
                Self.controlLeaseIDUserInfoKey
            ] as? String,
            let leaseID = UUID(uuidString: rawLeaseID) else {
                return
            }
            MainActor.assumeIsolated {
                _ = self?.takeover(leaseID: leaseID, emitIntent: true)
            }
        }
    }

    deinit {
        if let userInputObserver {
            notificationCenter.removeObserver(userInputObserver)
        }
    }

    /// Pure read-only gate for helper/tool code before it starts work.
    ///
    /// A target may initially have no pid (for example, before launch). When
    /// both sides have a pid, pid is authoritative; otherwise normalized
    /// bundle identifiers or application names provide the stable identity.
    func authorize(
        owner: AgentComputerUseOwner,
        target: AgentComputerUseTarget
    ) -> AgentComputerUseAuthorization {
        if lastRevokedOwner?.hasSameIdentity(as: owner) == true {
            return .denied(reason: .revoked, activeLease: state.lease)
        }

        guard maintenanceReservationID == nil else {
            return .denied(reason: .maintenance, activeLease: nil)
        }

        guard let current = state.lease else {
            return .allowed(existingLease: nil)
        }
        guard current.belongs(to: owner) else {
            return .denied(
                reason: .ownedByAnotherTurn,
                activeLease: current
            )
        }
        guard current.targets(target) else {
            return .denied(reason: .targetMismatch, activeLease: current)
        }

        switch state.phase {
        case .idle:
            return .allowed(existingLease: nil)
        case .observing, .controlling, .failed:
            return .allowed(existingLease: current)
        case .paused:
            return .denied(reason: .paused, activeLease: current)
        case .userTakeover:
            return .denied(reason: .userTakeover, activeLease: current)
        case .stopping:
            return .denied(reason: .stopping, activeLease: current)
        }
    }

    /// Acquires or refreshes the one global Computer Use lease.
    ///
    /// A different runtime, turn, or target pid cannot replace a live lease.
    /// Paused/takeover/stopping leases must be explicitly resumed or finished;
    /// a new tool call cannot silently reclaim control behind the user's back.
    @discardableResult
    func begin(
        operation: AgentComputerUseOperation,
        owner: AgentComputerUseOwner,
        target: AgentComputerUseTarget,
        actionName: String? = nil,
        activity: AgentComputerUseActivity? = nil,
        now: Date = Date()
    ) -> AgentComputerUseLease? {
        switch authorize(owner: owner, target: target) {
        case .denied:
            return nil

        case .allowed(existingLease: nil):
            advancePrivacyEpoch()
            let lease = AgentComputerUseLease(
                owner: owner,
                target: target,
                operation: operation,
                startedAt: now,
                lastActionName: actionName,
                latestActivity: activity
            )
            state = operationalState(for: lease)
            return lease

        case .allowed(existingLease: .some(let current)):
            var refreshed = current
            refreshed.owner.sessionTitle = owner.sessionTitle
            refreshed.target = current.target.mergingKnownIdentity(from: target)
            if refreshed.operation != .controlling {
                refreshed.operation = operation
            }
            refreshed.updatedAt = now
            if let actionName {
                refreshed.lastActionName = actionName
            }
            if let activity {
                refreshed.latestActivity = activity
            }
            state = operationalState(for: refreshed)
            return refreshed
        }
    }

    /// Records a finished helper action without releasing the turn-wide lease.
    /// Completing a stop request is the exception: it closes the presentation.
    func complete(
        leaseID: AgentComputerUseLease.ID,
        activity: AgentComputerUseActivity? = nil,
        actionName: String? = nil,
        now: Date = Date()
    ) {
        guard var lease = state.lease, lease.id == leaseID else { return }
        lease.updatedAt = now
        if let activity {
            lease.latestActivity = activity
        }
        if let actionName {
            lease.lastActionName = actionName
        }

        switch state {
        case .observing:
            state = .observing(lease)
        case .controlling:
            state = .controlling(lease)
        case .paused:
            state = .paused(lease)
        case .userTakeover:
            state = .userTakeover(lease)
        case .stopping:
            pendingResumeRequest = nil
            state = .idle
        case .failed, .idle:
            break
        }
    }

    func resultPublicationDisposition(
        leaseID: AgentComputerUseLease.ID,
        owner: AgentComputerUseOwner,
        target: AgentComputerUseTarget,
        startedAtPrivacyEpoch: UInt64
    ) -> AgentComputerUseResultPublicationDisposition {
        guard let lease = state.lease,
              lease.id == leaseID,
              lease.belongs(to: owner),
              lease.targets(target) else {
            return .cancelled
        }

        switch state.phase {
        case .paused, .userTakeover:
            return .userControl
        case .idle, .stopping, .failed:
            return .cancelled
        case .observing, .controlling:
            return privacyEpoch == startedAtPrivacyEpoch
                ? .publish
                : .staleHandoff
        }
    }

    /// Returns an epoch only while local observation is allowed. Callers must
    /// validate the same epoch again immediately before publishing any pixels
    /// or text derived from those pixels.
    func beginLocalObservation() -> UInt64? {
        switch state.phase {
        case .paused, .userTakeover, .stopping:
            return nil
        case .idle, .observing, .controlling, .failed:
            return privacyEpoch
        }
    }

    func permitsLocalObservation(startedAt epoch: UInt64) -> Bool {
        guard privacyEpoch == epoch else { return false }
        switch state.phase {
        case .paused, .userTakeover, .stopping:
            return false
        case .idle, .observing, .controlling, .failed:
            return true
        }
    }

    var pendingTransportBarrierEpoch: UInt64? {
        requiredTransportBarrierEpoch > acknowledgedTransportBarrierEpoch
            ? requiredTransportBarrierEpoch
            : nil
    }

    func acknowledgeTransportBarrier(epoch: UInt64) {
        acknowledgedTransportBarrierEpoch = max(
            acknowledgedTransportBarrierEpoch,
            min(epoch, requiredTransportBarrierEpoch)
        )
        guard pendingTransportBarrierEpoch == nil,
              let request = pendingResumeRequest,
              let lease = matchingLease(request.leaseID),
              state.phase == .paused || state.phase == .userTakeover else {
            return
        }
        pendingResumeRequest = nil
        performResume(lease: lease, emitIntent: request.emitIntent)
    }

    func beginIdleMaintenanceReservation() -> UUID? {
        guard state.lease == nil, maintenanceReservationID == nil else {
            return nil
        }
        let reservationID = UUID()
        maintenanceReservationID = reservationID
        return reservationID
    }

    func endIdleMaintenanceReservation(_ reservationID: UUID) {
        guard maintenanceReservationID == reservationID else { return }
        maintenanceReservationID = nil
    }

    func fail(
        leaseID: AgentComputerUseLease.ID? = nil,
        message: String,
        now: Date = Date()
    ) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        if var lease = state.lease {
            guard leaseID == nil || lease.id == leaseID else { return }
            pendingResumeRequest = nil
            lease.updatedAt = now
            state = .failed(lease, message: message)
        } else if leaseID == nil {
            pendingResumeRequest = nil
            state = .failed(nil, message: message)
        }
    }

    /// Ends only the matching owner turn. A late callback from an older turn
    /// cannot dismiss a newer session's control indicator.
    func finishTurn(runtimeID: AgentSession.ID, turnID: UUID) {
        if let owner = state.lease?.owner,
           owner.runtimeID == runtimeID,
           owner.turnID == turnID {
            pendingResumeRequest = nil
            state = .idle
        }
        if let revokedOwner = lastRevokedOwner,
           revokedOwner.runtimeID == runtimeID,
           revokedOwner.turnID == turnID {
            lastRevokedOwner = nil
        }
    }

    @discardableResult
    func pause(
        leaseID: AgentComputerUseLease.ID? = nil,
        emitIntent: Bool = true
    ) -> Bool {
        guard let lease = matchingLease(leaseID),
              state.phase == .observing || state.phase == .controlling else {
            return false
        }
        advancePrivacyEpoch(requiresTransportBarrier: true)
        state = .paused(lease)
        if emitIntent {
            post(intent: .pause, lease: lease)
        }
        return true
    }

    @discardableResult
    func takeover(
        leaseID: AgentComputerUseLease.ID? = nil,
        emitIntent: Bool = true
    ) -> Bool {
        guard let lease = matchingLease(leaseID),
              state.phase == .observing
                || state.phase == .controlling
                || state.phase == .paused else {
            return false
        }
        pendingResumeRequest = nil
        advancePrivacyEpoch(requiresTransportBarrier: true)
        state = .userTakeover(lease)
        if emitIntent {
            post(intent: .takeover, lease: lease)
        }
        return true
    }

    @discardableResult
    func resume(
        leaseID: AgentComputerUseLease.ID? = nil,
        emitIntent: Bool = true
    ) -> Bool {
        guard let lease = matchingLease(leaseID),
              state.phase == .paused || state.phase == .userTakeover else {
            return false
        }
        if pendingTransportBarrierEpoch != nil {
            // Keep the presentation in a truthful user-control phase until
            // the old helper generation has actually been torn down. The
            // user's click is queued and completed by the matching barrier
            // acknowledgement instead of briefly showing "controlling"
            // while stale helper work may still be alive.
            pendingResumeRequest = (lease.id, emitIntent)
            return true
        }
        performResume(lease: lease, emitIntent: emitIntent)
        return true
    }

    @discardableResult
    func stop(
        leaseID: AgentComputerUseLease.ID? = nil,
        emitIntent: Bool = true
    ) -> Bool {
        guard let lease = matchingLease(leaseID),
              state.phase != .idle,
              state.phase != .stopping else {
            if case .failed(nil, _) = state, leaseID == nil {
                pendingResumeRequest = nil
                state = .idle
                return true
            }
            return false
        }
        pendingResumeRequest = nil
        lastRevokedOwner = lease.owner
        advancePrivacyEpoch(requiresTransportBarrier: true)
        state = .stopping(lease)
        if emitIntent {
            post(intent: .stop, lease: lease)
        }
        return true
    }

    private func matchingLease(
        _ requestedID: AgentComputerUseLease.ID?
    ) -> AgentComputerUseLease? {
        guard let lease = state.lease,
              requestedID == nil || requestedID == lease.id else {
            return nil
        }
        return lease
    }

    private func operationalState(
        for lease: AgentComputerUseLease
    ) -> AgentComputerUseControlState {
        switch lease.operation {
        case .observing: return .observing(lease)
        case .controlling: return .controlling(lease)
        }
    }

    private func performResume(
        lease: AgentComputerUseLease,
        emitIntent: Bool
    ) {
        advancePrivacyEpoch()
        state = operationalState(for: lease)
        if emitIntent {
            post(intent: .resume, lease: lease)
        }
    }

    private func advancePrivacyEpoch(
        requiresTransportBarrier: Bool = false
    ) {
        privacyEpoch &+= 1
        if requiresTransportBarrier {
            requiredTransportBarrierEpoch = privacyEpoch
        }
    }

    private func post(
        intent: AgentComputerUseControlIntent,
        lease: AgentComputerUseLease
    ) {
        notificationCenter.post(
            name: .agentComputerUseControlIntent,
            object: AgentComputerUseControlIntentEvent(intent: intent, lease: lease)
        )
    }
}

private extension AgentComputerUseOwner {
    func hasSameIdentity(as other: AgentComputerUseOwner) -> Bool {
        runtimeID == other.runtimeID && turnID == other.turnID
    }
}
