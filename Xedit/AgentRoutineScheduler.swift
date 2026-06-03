//
//  AgentRoutineScheduler.swift
//  VeilWriter
//
//  Polls user-defined routines on a 30-second cadence and fires the ones
//  whose next-run moment has passed. macOS suspends Timers while the app
//  sleeps; on wake we catch up any routine whose target time slipped past
//  while we were paused. Optional UserNotifications surface "Routine X
//  started" when the user has granted permission.
//

import Foundation
import UserNotifications

@MainActor
final class AgentRoutineScheduler {
    /// How often we check the routine list. 30s is precise enough for
    /// human-scheduled tasks ("daily 09:00", "every 30 min") and keeps
    /// the Timer cheap.
    static let tickInterval: TimeInterval = 30

    /// Called when a routine should fire. The caller (AppState) is
    /// responsible for actually starting a session and dispatching the
    /// prompt — the scheduler just decides "now is the moment". Return
    /// `true` if the routine actually ran; `false` to ask the scheduler
    /// to try again on the next tick (e.g. the user's current session
    /// is mid-turn and we don't want to interrupt them).
    typealias Trigger = (_ routineID: UUID) -> Bool

    private weak var timer: Timer?
    private var trigger: Trigger?
    /// Routines we've already fired during the current run, tracked by
    /// (routineID, fireTime). Prevents the same minute boundary from
    /// double-firing if the tick lands twice inside one minute.
    private var lastDispatchedAt: [UUID: Date] = [:]
    /// Cached so we don't re-walk the routine list when nothing changed.
    /// Updated whenever the AppState calls `routinesChanged(_:)`.
    private var snapshot: [AgentRoutine] = []
    private var hasRequestedNotificationAuth = false

    func start(initialRoutines: [AgentRoutine], trigger: @escaping Trigger) {
        self.trigger = trigger
        self.snapshot = initialRoutines
        scheduleTimer()
        // Catch up on routines whose target time fell during a previous
        // app session — runs once at startup.
        evaluate(catchUp: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        trigger = nil
    }

    /// Notify the scheduler that the user edited / added / removed a
    /// routine. Cheap — just refreshes the cached snapshot. The next
    /// tick (or `evaluateNow()`) picks up the change.
    func routinesChanged(_ routines: [AgentRoutine]) {
        snapshot = routines
        // If a routine got disabled or deleted, drop its dispatch marker
        // so re-enabling later doesn't think it just fired.
        let liveIDs = Set(routines.filter { $0.isEnabled }.map(\.id))
        lastDispatchedAt = lastDispatchedAt.filter { liveIDs.contains($0.key) }
    }

    /// Force an evaluation pass — used by "Run now" so the user gets
    /// immediate feedback rather than waiting for the next tick.
    func evaluateNow() {
        evaluate(catchUp: false)
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            // Timer callback hops onto the main actor explicitly so we
            // can touch @MainActor state without a warning.
            Task { @MainActor [weak self] in
                self?.evaluate(catchUp: false)
            }
        }
        // Let the timer fire during scroll / menu tracking so a sheet
        // being open doesn't delay routines.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Walk the snapshot, fire any routine whose next-run moment is
    /// in the past. `catchUp` is true only on startup — when an
    /// already-due routine should run immediately. During normal ticks
    /// the same logic applies; the flag mostly exists for clarity in
    /// notification copy ("scheduled run" vs "catching up after wake").
    private func evaluate(catchUp: Bool) {
        guard let trigger else { return }
        let now = Date()
        for routine in snapshot where routine.isEnabled {
            guard let next = routine.nextFireDate(now: now) else { continue }
            guard next <= now else { continue }
            // Coalesce so a tick landing twice in the same minute can't
            // double-fire one routine.
            if let last = lastDispatchedAt[routine.id], now.timeIntervalSince(last) < Self.tickInterval {
                continue
            }
            let didRun = trigger(routine.id)
            if didRun {
                lastDispatchedAt[routine.id] = now
                postNotificationIfAuthorized(routine: routine, catchUp: catchUp)
            }
            // If didRun was false, leave lastDispatchedAt untouched so
            // the next tick re-evaluates and tries again.
        }
    }

    // MARK: - Optional macOS notifications

    /// Ask the user for notification permission the first time any
    /// routine fires. If they say no, we silently keep going — routines
    /// still run, just without the system banner.
    func requestNotificationAuthorizationIfNeeded() {
        guard !hasRequestedNotificationAuth else { return }
        hasRequestedNotificationAuth = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotificationIfAuthorized(routine: AgentRoutine, catchUp: Bool) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Routine 已启动"
            content.body = catchUp
                ? "「\(routine.name)」补跑（睡眠唤醒后）"
                : "「\(routine.name)」开始运行"
            let request = UNNotificationRequest(
                identifier: "veilwriter.routine.\(routine.id.uuidString).\(Int(Date().timeIntervalSince1970))",
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }
}
