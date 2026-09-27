//
//  AgentGoalRunSettings.swift
//  WillDeep
//
//  The operator's ceiling for one Goal execution segment. It used to be a
//  hard-coded four hours (`AgentGoalContinuationPolicy.defaultWallClockLimit`,
//  whose comment promised "the operator can widen it" with nowhere to do so);
//  a Goal left running overnight needs more than that.
//

import Foundation

nonisolated enum AgentGoalRunSettings {
    static let storageKey = "com.willdeep.agentSettings.goalSegmentWallClockHours.v1"
    /// The choices the settings page offers. A persisted value outside this
    /// list (hand-edited defaults, a removed option) falls back to the default.
    static let allowedHours: [Int] = [1, 2, 4, 8, 12, 24]
    static let defaultHours = 4
    static let secondsPerHour: TimeInterval = 60 * 60

    static func loadHours(defaults: UserDefaults = AppDefaults.standard) -> Int {
        guard defaults.object(forKey: storageKey) != nil else { return defaultHours }
        let stored = defaults.integer(forKey: storageKey)
        return allowedHours.contains(stored) ? stored : defaultHours
    }

    static func saveHours(_ hours: Int, defaults: UserDefaults = AppDefaults.standard) {
        guard allowedHours.contains(hours) else { return }
        defaults.set(hours, forKey: storageKey)
    }

    /// The limit a new segment starts with: a new Goal, or Play after a stop.
    /// A segment that is already running keeps the limit it started with.
    static func configuredWallClockLimit(defaults: UserDefaults = AppDefaults.standard) -> TimeInterval {
        TimeInterval(loadHours(defaults: defaults)) * secondsPerHour
    }
}
