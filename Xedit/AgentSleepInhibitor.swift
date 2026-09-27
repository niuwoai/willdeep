//
//  AgentSleepInhibitor.swift
//  WillDeep
//
//  Keeps the Mac from idle-sleeping while any Goal is executing, including a
//  Goal that is only waiting to retry. docs/LONG_HORIZON_AUTONOMY.md §5 and
//  §7 assumption 5: `idleSystemSleepDisabled` only — closing the lid is an
//  explicit choice and still sleeps the machine, and the display may still
//  sleep on its own schedule.
//

import Foundation
import os

/// Pure bookkeeping: who wants the Mac awake, and whether the one process-wide
/// activity has to be taken or given back. Keyed by runtime id so a second
/// "I am executing" from the same Goal is a no-op instead of a second
/// activity, and releasing a key nobody holds cannot underflow a counter.
nonisolated struct AgentSleepInhibitionLedger: Equatable {
    enum Transition: Equatable {
        case acquire
        case release
        case none
    }

    private(set) var holders: Set<UUID> = []

    var isHeld: Bool { !holders.isEmpty }

    mutating func setHolding(_ holding: Bool, for key: UUID) -> Transition {
        let wasHeld = isHeld
        if holding {
            holders.insert(key)
        } else {
            holders.remove(key)
        }
        switch (wasHeld, isHeld) {
        case (false, true): return .acquire
        case (true, false): return .release
        default: return .none
        }
    }
}

/// The process-wide owner of the `ProcessInfo` activity. One activity for the
/// whole process no matter how many Goals run; begin and end are injected so
/// tests can count them without touching the real power assertions.
@MainActor
final class AgentSleepInhibitor {
    static let shared = AgentSleepInhibitor()

    /// Exactly what §5 asks for — no `.idleDisplaySleepDisabled`, and not the
    /// broader `.userInitiated` bundle, which also disables sudden and
    /// automatic termination.
    nonisolated static let activityOptions: ProcessInfo.ActivityOptions = [.idleSystemSleepDisabled]
    /// Shows up in `pmset -g assertions`; an operator-facing diagnostic, not UI.
    nonisolated static let activityReason = "WillDeep Goal execution"

    typealias Begin = @MainActor (_ options: ProcessInfo.ActivityOptions, _ reason: String) -> NSObjectProtocol
    typealias End = @MainActor (NSObjectProtocol) -> Void

    private static let log = Logger(subsystem: "com.willdeep.app", category: "goal-sleep-inhibitor")

    private var ledger = AgentSleepInhibitionLedger()
    private var activity: NSObjectProtocol?
    private let begin: Begin
    private let end: End

    init(
        begin: @escaping Begin = { ProcessInfo.processInfo.beginActivity(options: $0, reason: $1) },
        end: @escaping End = { ProcessInfo.processInfo.endActivity($0) }
    ) {
        self.begin = begin
        self.end = end
    }

    var isInhibiting: Bool { activity != nil }
    var holders: Set<UUID> { ledger.holders }

    func setHolding(_ holding: Bool, for key: UUID) {
        switch ledger.setHolding(holding, for: key) {
        case .acquire:
            guard activity == nil else { return }
            activity = begin(Self.activityOptions, Self.activityReason)
            Self.log.notice("idle system sleep disabled holders=\(self.ledger.holders.count)")
        case .release:
            guard let activity else { return }
            end(activity)
            self.activity = nil
            Self.log.notice("idle system sleep re-enabled")
        case .none:
            break
        }
    }
}
