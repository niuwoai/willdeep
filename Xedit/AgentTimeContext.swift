//
//  AgentTimeContext.swift
//  WillDeep
//
//  Tells the model what time it is, and where the user is.
//
//  Without this the model has no clock at all. It then reports whatever
//  timestamps it finds in tool output — and remote hosts, containers and CI
//  runners almost universally run on UTC — so a user in UTC+8 gets told
//  "08:06:47, about 3 minutes left" while their own clock reads 16:06.
//  Relative arithmetic ("how much longer?") is worse: mixing a UTC log line
//  with an assumed local now is off by the whole offset.
//
//  This block belongs to the per-turn context, never the stable system
//  prompt: the time changes every turn, and the stable prefix is what the
//  provider prompt cache keys on (currently ~99% hit rate).
//

import Foundation

nonisolated enum AgentTimeContext {
    /// Fixed format rather than a localized one: this is read by a model,
    /// not a person, and a stable shape keeps it unambiguous across locales.
    /// Includes the numeric offset so the model can convert without knowing
    /// the IANA database.
    static func block(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        let stamp = formatter.string(from: now)

        return """
        Current time and timezone:
        - User local time at the start of this turn: \(stamp)
        - Timezone: \(timeZone.identifier) (\(offsetDescription(for: timeZone, at: now)))
        Rules:
        - Report times to the user in their local timezone above. The user reads their own clock, not the server's.
        - Remote hosts, containers, CI runners and most server logs run on UTC. When you quote a raw timestamp from tool output, keep the original value but say which zone it is in, and convert to the user's local time when the user is meant to act on it.
        - Before computing an elapsed or remaining duration, put both timestamps in the same zone. Mixing a UTC log line with local "now" is wrong by the full offset.
        - This stamp is from the start of the turn, so it drifts as the turn runs. When you need the exact current time (deadlines, countdowns), read the clock yourself instead of extrapolating.
        """
    }

    /// Human-readable UTC offset, e.g. "UTC+8", "UTC-3:30", "UTC+0".
    /// Written out rather than abbreviated because zone abbreviations are
    /// ambiguous (CST is both China and US Central).
    static func offsetDescription(for timeZone: TimeZone, at date: Date = Date()) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        if seconds == 0 { return "UTC+0" }
        let sign = seconds < 0 ? "-" : "+"
        let total = abs(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return minutes == 0
            ? "UTC\(sign)\(hours)"
            : "UTC\(sign)\(hours):\(String(format: "%02d", minutes))"
    }
}
