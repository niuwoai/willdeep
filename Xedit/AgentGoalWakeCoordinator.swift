//
//  AgentGoalWakeCoordinator.swift
//  WillDeep
//
//  Per-AppState owner of the in-process side of Goal waits: one cancellable
//  timer per runtime, the sleep-inhibition keys this AppState holds on the
//  process-wide inhibitor, and the system-wake observer. The persisted truth
//  (what is due, and when) lives on `AgentGoal.scheduledWake`; a timer here is
//  only the prompt to go and look at it.
//

import AppKit
import Foundation
import os

@MainActor
final class AgentGoalWakeCoordinator {
    typealias Sleeper = @Sendable (_ seconds: TimeInterval) async throws -> Void
    typealias Fire = @MainActor (_ runtimeID: UUID, _ wakeID: UUID) -> Void

    /// Sleeps on the continuous clock, which keeps counting while the Mac is
    /// asleep. The system-wake catch-up still re-derives every wait from its
    /// persisted wall-clock due date; this only keeps the timer honest when
    /// the notification arrives late or not at all.
    static let continuousSleeper: Sleeper = { seconds in
        try await Task.sleep(
            until: ContinuousClock.now.advanced(by: .seconds(max(0, seconds))),
            clock: .continuous
        )
    }

    private static let log = Logger(subsystem: "com.willdeep.app", category: "goal-wake")

    private struct ArmedTimer {
        let wakeID: UUID
        let token: UUID
        let task: Task<Void, Never>
    }

    /// Injected by tests so a fifteen-minute wait costs nothing.
    var sleeper: Sleeper = AgentGoalWakeCoordinator.continuousSleeper
    /// Swapping moves this AppState's hold along, so a test can install a
    /// counting inhibitor without leaking a real activity.
    var sleepInhibitor: AgentSleepInhibitor = .shared {
        didSet {
            guard oldValue !== sleepInhibitor, !inhibitingRuntimeIDs.isEmpty else { return }
            oldValue.setHolding(false, for: inhibitionKey)
            sleepInhibitor.setHolding(true, for: inhibitionKey)
        }
    }

    private var timers: [UUID: ArmedTimer] = [:]
    /// This AppState's single key on the process-wide inhibitor. Per-runtime
    /// bookkeeping stays here, so two windows that happen to hold the same
    /// session can never release each other's hold.
    private let inhibitionKey = UUID()
    /// Runtimes of this AppState whose Goal is executing right now.
    private(set) var inhibitingRuntimeIDs: Set<UUID> = []
    private var systemWakeObserver: AgentSystemWakeObserver?
    /// The turn whose provider failure was just parked on a wait, per runtime.
    /// That turn's own finish must not reset the failure counter the wait was
    /// built on — even if a queued message already superseded the wait.
    private var deferredOutageTurnIDs: [UUID: UUID] = [:]

    var armedRuntimeIDs: Set<UUID> { Set(timers.keys) }

    func armedWakeID(for runtimeID: UUID) -> UUID? { timers[runtimeID]?.wakeID }

    /// Exposed so tests can await the timer instead of polling for its effect.
    func timerTask(for runtimeID: UUID) -> Task<Void, Never>? { timers[runtimeID]?.task }

    func arm(runtimeID: UUID, wakeID: UUID, after delay: TimeInterval, fire: @escaping Fire) {
        timers.removeValue(forKey: runtimeID)?.task.cancel()
        let token = UUID()
        let sleeper = self.sleeper
        let task = Task { @MainActor [weak self] in
            do {
                try await sleeper(delay)
            } catch is CancellationError {
                return
            } catch {
                // The default sleeper only throws on cancellation; anything
                // else is a broken injected sleeper. Fall through and fire
                // rather than strand the Goal on a wait nobody will end.
                Self.log.error("goal wake sleeper failed: \(String(describing: error), privacy: .public)")
            }
            guard !Task.isCancelled,
                  let self,
                  self.timers[runtimeID]?.token == token else { return }
            self.timers.removeValue(forKey: runtimeID)
            fire(runtimeID, wakeID)
        }
        timers[runtimeID] = ArmedTimer(wakeID: wakeID, token: token, task: task)
    }

    func disarm(runtimeID: UUID) {
        timers.removeValue(forKey: runtimeID)?.task.cancel()
    }

    func noteDeferredOutage(runtimeID: UUID, turnID: UUID?) {
        deferredOutageTurnIDs[runtimeID] = turnID
    }

    /// True (once) when `turnID` is the turn that was just parked on an
    /// outage wait.
    func consumeDeferredOutage(runtimeID: UUID, turnID: UUID) -> Bool {
        guard deferredOutageTurnIDs[runtimeID] == turnID else { return false }
        deferredOutageTurnIDs.removeValue(forKey: runtimeID)
        return true
    }

    /// `holders` is the complete set of this AppState's executing Goals, not a
    /// delta, so a runtime that stopped — or vanished without saying so —
    /// simply drops out on the next sync. Repeating a sync is a no-op.
    func syncSleepInhibition(holders: Set<UUID>) {
        inhibitingRuntimeIDs = holders
        sleepInhibitor.setHolding(!holders.isEmpty, for: inhibitionKey)
    }

    func observeSystemWake(center: NotificationCenter, handler: @escaping @MainActor () -> Void) {
        systemWakeObserver = AgentSystemWakeObserver(center: center, handler: handler)
    }

    /// A window's AppState going away must not leave the Mac awake.
    deinit {
        for timer in timers.values { timer.task.cancel() }
        guard !inhibitingRuntimeIDs.isEmpty else { return }
        let key = inhibitionKey
        let inhibitor = sleepInhibitor
        Task { @MainActor in inhibitor.setHolding(false, for: key) }
    }
}

/// `NSWorkspace.didWakeNotification` → handler. Selector-based so the center
/// drops the registration by itself when the observer goes away.
@MainActor
final class AgentSystemWakeObserver: NSObject {
    private let handler: @MainActor () -> Void

    init(center: NotificationCenter, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init()
        center.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    /// NSWorkspace posts this on the main thread.
    @objc private func systemDidWake(_ notification: Notification) {
        handler()
    }
}
