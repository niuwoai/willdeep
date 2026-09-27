//
//  AgentGoalSleepInhibitionTests.swift
//  WillDeepTests
//
//  The in-process half of a Goal wait: one process-wide idle-sleep activity
//  that is taken once and given back once, cancellable timers that fire only
//  for the wait that is still current, and the Settings ceiling for a segment.
//

import AppKit
import Foundation
import Testing

@testable import WillDeep

/// Sleeper that parks until the test hands out a permit, recording what it
/// was asked to wait for. Never sleeps for real; a permit given before the
/// sleeper arrives is kept, so tests never have to poll for "is it asleep".
actor AgentGoalTestSleepGate {
    private(set) var requested: [TimeInterval] = []
    private var permits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep(_ seconds: TimeInterval) async {
        requested.append(seconds)
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release(_ count: Int = 1) {
        for _ in 0..<count {
            if waiters.isEmpty {
                permits += 1
            } else {
                waiters.removeFirst().resume()
            }
        }
    }
}

@MainActor
final class AgentGoalActivityCounter {
    var begins = 0
    var ends = 0
    var options: [ProcessInfo.ActivityOptions] = []

    func makeInhibitor() -> AgentSleepInhibitor {
        AgentSleepInhibitor(
            begin: { [self] options, _ in
                begins += 1
                self.options.append(options)
                return NSObject()
            },
            end: { [self] _ in ends += 1 }
        )
    }
}

@Suite("Goal 防睡眠与等待计时器")
@MainActor
struct AgentGoalSleepInhibitionTests {
    // MARK: - Ledger

    @Test("台账：第一个持有者拿活动，最后一个离开才还；重复持有与重复释放都是空操作")
    func ledgerAcquiresOnceAndReleasesOnce() {
        var ledger = AgentSleepInhibitionLedger()
        let a = UUID(), b = UUID()
        #expect(ledger.setHolding(true, for: a) == .acquire)
        #expect(ledger.setHolding(true, for: a) == .none)
        #expect(ledger.setHolding(true, for: b) == .none)
        #expect(ledger.setHolding(false, for: a) == .none)
        #expect(ledger.setHolding(false, for: UUID()) == .none)
        #expect(ledger.setHolding(false, for: b) == .release)
        #expect(ledger.setHolding(false, for: b) == .none)
        #expect(!ledger.isHeld)
        #expect(ledger.setHolding(true, for: b) == .acquire)
    }

    @Test("只禁止闲置睡眠：不禁止显示器睡眠，也不阻止合盖")
    func activityOptionsAreIdleSystemSleepOnly() {
        #expect(AgentSleepInhibitor.activityOptions == [.idleSystemSleepDisabled])
        #expect(!AgentSleepInhibitor.activityOptions.contains(.idleDisplaySleepDisabled))
        #expect(!AgentSleepInhibitor.activityOptions.contains(.userInitiated))
    }

    @Test("多个 Goal 同时执行只开一个活动；全部停下才结束")
    func inhibitorHoldsOneActivityForManyGoals() {
        let counter = AgentGoalActivityCounter()
        let inhibitor = counter.makeInhibitor()
        let a = UUID(), b = UUID()
        inhibitor.setHolding(true, for: a)
        inhibitor.setHolding(true, for: b)
        inhibitor.setHolding(true, for: a)
        #expect(counter.begins == 1)
        #expect(counter.options == [[.idleSystemSleepDisabled]])
        inhibitor.setHolding(false, for: a)
        #expect(counter.ends == 0)
        #expect(inhibitor.isInhibiting)
        inhibitor.setHolding(false, for: b)
        inhibitor.setHolding(false, for: b)
        #expect(counter.ends == 1)
        #expect(!inhibitor.isInhibiting)
    }

    @Test("协调器按全集同步：重复同步是空操作，最后一个 Goal 停下才释放；换抑制器时持有一起搬走")
    func coordinatorSyncsTheWholeSet() {
        let counter = AgentGoalActivityCounter()
        let coordinator = AgentGoalWakeCoordinator()
        coordinator.sleepInhibitor = counter.makeInhibitor()
        let a = UUID(), b = UUID()
        coordinator.syncSleepInhibition(holders: [a])
        coordinator.syncSleepInhibition(holders: [a, b])
        coordinator.syncSleepInhibition(holders: [a, b])
        #expect(counter.begins == 1)
        #expect(coordinator.inhibitingRuntimeIDs == [a, b])
        coordinator.syncSleepInhibition(holders: [b])
        #expect(counter.ends == 0)
        let replacement = AgentGoalActivityCounter()
        coordinator.sleepInhibitor = replacement.makeInhibitor()
        #expect(counter.ends == 1)
        #expect(replacement.begins == 1)
        coordinator.syncSleepInhibition(holders: [])
        coordinator.syncSleepInhibition(holders: [])
        #expect(replacement.ends == 1)
        #expect(coordinator.inhibitingRuntimeIDs.isEmpty)
    }

    @Test("两个窗口各自持有同一个会话也互不释放对方")
    func twoCoordinatorsNeverReleaseEachOther() {
        let counter = AgentGoalActivityCounter()
        let inhibitor = counter.makeInhibitor()
        let first = AgentGoalWakeCoordinator(), second = AgentGoalWakeCoordinator()
        first.sleepInhibitor = inhibitor
        second.sleepInhibitor = inhibitor
        let shared = UUID()
        first.syncSleepInhibition(holders: [shared])
        second.syncSleepInhibition(holders: [shared])
        first.syncSleepInhibition(holders: [])
        #expect(inhibitor.isInhibiting)
        #expect(counter.ends == 0)
        second.syncSleepInhibition(holders: [])
        #expect(!inhibitor.isInhibiting)
        #expect(counter.begins == 1 && counter.ends == 1)
    }

    // MARK: - Timers

    @Test("计时器按请求的时长挂起，到期回调带着正确的会话与等待 ID")
    func timerFiresWithItsIDs() async throws {
        let gate = AgentGoalTestSleepGate()
        let coordinator = AgentGoalWakeCoordinator()
        coordinator.sleeper = { await gate.sleep($0) }
        let runtimeID = UUID(), wakeID = UUID()
        var fired: [(UUID, UUID)] = []
        coordinator.arm(runtimeID: runtimeID, wakeID: wakeID, after: 300) { fired.append(($0, $1)) }
        let task = try #require(coordinator.timerTask(for: runtimeID))
        #expect(coordinator.armedWakeID(for: runtimeID) == wakeID)
        await gate.release()
        await task.value
        #expect(await gate.requested == [300])
        #expect(fired.count == 1)
        #expect(fired.first?.0 == runtimeID && fired.first?.1 == wakeID)
        #expect(coordinator.armedWakeID(for: runtimeID) == nil)
    }

    @Test("撤销后的计时器即使睡醒也不触发；重新挂起只有新的那个触发")
    func disarmedAndReplacedTimersNeverFire() async throws {
        let gate = AgentGoalTestSleepGate()
        let coordinator = AgentGoalWakeCoordinator()
        coordinator.sleeper = { await gate.sleep($0) }
        let runtimeID = UUID()
        var fired: [UUID] = []
        let first = UUID(), second = UUID(), third = UUID()

        coordinator.arm(runtimeID: runtimeID, wakeID: first, after: 60) { fired.append($1) }
        let firstTask = try #require(coordinator.timerTask(for: runtimeID))
        coordinator.disarm(runtimeID: runtimeID)
        coordinator.arm(runtimeID: runtimeID, wakeID: second, after: 60) { fired.append($1) }
        let secondTask = try #require(coordinator.timerTask(for: runtimeID))
        coordinator.arm(runtimeID: runtimeID, wakeID: third, after: 60) { fired.append($1) }
        let thirdTask = try #require(coordinator.timerTask(for: runtimeID))

        await gate.release(3)
        await firstTask.value
        await secondTask.value
        await thirdTask.value
        #expect(fired == [third])
    }

    @Test("系统唤醒通知走注入的通知中心，回调只在唤醒时触发")
    func systemWakeObserverCallsBack() {
        let center = NotificationCenter()
        let coordinator = AgentGoalWakeCoordinator()
        var wakes = 0
        coordinator.observeSystemWake(center: center) { wakes += 1 }
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(wakes == 0)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(wakes == 1)
    }

    // MARK: - Settings (A4)

    @Test("单段时长上限：默认 4 小时，只接受给定档位，非法值回落默认")
    func segmentLimitSettingIsValidated() throws {
        let name = "com.willdeep.agent.test.defaults.goal-run-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: name) }

        #expect(AgentGoalRunSettings.allowedHours == [1, 2, 4, 8, 12, 24])
        #expect(AgentGoalRunSettings.loadHours(defaults: defaults) == 4)
        #expect(AgentGoalRunSettings.configuredWallClockLimit(defaults: defaults) == AgentGoalContinuationPolicy.defaultWallClockLimit)

        AgentGoalRunSettings.saveHours(12, defaults: defaults)
        #expect(AgentGoalRunSettings.loadHours(defaults: defaults) == 12)
        #expect(AgentGoalRunSettings.configuredWallClockLimit(defaults: defaults) == 12 * 60 * 60)

        AgentGoalRunSettings.saveHours(5, defaults: defaults)
        #expect(AgentGoalRunSettings.loadHours(defaults: defaults) == 12)

        defaults.set(7, forKey: AgentGoalRunSettings.storageKey)
        #expect(AgentGoalRunSettings.loadHours(defaults: defaults) == 4)
    }

    @Test("新预算与按继续开新段都取设置里的上限；运行中的段保持原上限")
    func newSegmentsTakeTheConfiguredLimit() throws {
        let name = "com.willdeep.agent.test.defaults.goal-run-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: name) }
        AgentGoalRunSettings.saveHours(24, defaults: defaults)

        let fresh = AppDefaults._withTestDefaults(defaults) { AgentGoalContinuationBudget.standard }
        let day: TimeInterval = 24 * AgentGoalRunSettings.secondsPerHour
        #expect(fresh.wallClockLimit == day)

        let running = AgentGoalContinuationBudget(wallClockLimit: 3_600, segmentStartedAt: Date(), continuationsUsed: 3)
        let resumed = running.restarted(
            wallClockLimit: AgentGoalRunSettings.configuredWallClockLimit(defaults: defaults)
        )
        #expect(running.wallClockLimit == 3_600)
        #expect(resumed.wallClockLimit == day)
        #expect(resumed.continuationsUsed == 0)
        #expect(resumed.segmentStartedAt == nil)
    }
}
