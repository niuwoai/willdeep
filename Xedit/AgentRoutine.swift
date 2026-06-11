//
//  AgentRoutine.swift
//  WillDeep
//
//  Compatibility model for user-facing Automations. The persisted
//  JSON still uses the historical "routine" type names/paths so
//  existing scheduled prompts keep loading without migration.
//

import Foundation

/// How often / when an automation should fire. Persisted as a tagged enum
/// so existing JSON survives adding new schedule kinds later.
enum AgentRoutineSchedule: Codable, Equatable {
    /// Every N minutes from the last run (or from `createdAt` if never run).
    case interval(minutes: Int)
    /// Every day at HH:MM (24h, local time).
    case dailyAt(hour: Int, minute: Int)
    /// Monday–Friday at HH:MM (24h, local time).
    case weekdaysAt(hour: Int, minute: Int)
    /// A specific weekday at HH:MM. `weekday` follows Foundation:
    /// 1 = Sunday … 7 = Saturday.
    case weeklyAt(weekday: Int, hour: Int, minute: Int)

    /// One-line human summary shown next to the automation name in the sidebar.
    var summary: String {
        switch self {
        case .interval(let minutes):
            if minutes % 60 == 0 {
                let hours = minutes / 60
                return hours == 1
                    ? L10n.Automation.intervalOneHour
                    : L10n.Automation.intervalHours("\(hours)")
            }
            return L10n.Automation.intervalMinutes("\(minutes)")
        case .dailyAt(let h, let m):
            return L10n.Automation.scheduleDailySummary(Self.formatTime(h, m))
        case .weekdaysAt(let h, let m):
            return L10n.Automation.scheduleWeekdaysSummary(Self.formatTime(h, m))
        case .weeklyAt(let weekday, let h, let m):
            return L10n.Automation.scheduleWeekdaySummary(Self.weekdayName(weekday), Self.formatTime(h, m))
        }
    }

    private static func formatTime(_ h: Int, _ m: Int) -> String {
        String(format: "%02d:%02d", h, m)
    }

    private static func weekdayName(_ weekday: Int) -> String {
        switch weekday {
        case 1: return L10n.Automation.weekdaySunday
        case 2: return L10n.Automation.weekdayMonday
        case 3: return L10n.Automation.weekdayTuesday
        case 4: return L10n.Automation.weekdayWednesday
        case 5: return L10n.Automation.weekdayThursday
        case 6: return L10n.Automation.weekdayFriday
        case 7: return L10n.Automation.weekdaySaturday
        default: return "?"
        }
    }

    // MARK: Codable

    private enum Kind: String, Codable {
        case interval, dailyAt, weekdaysAt, weeklyAt
    }

    private enum CodingKeys: String, CodingKey {
        case kind, minutes, hour, minute, weekday
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .interval:
            let minutes = try c.decode(Int.self, forKey: .minutes)
            self = .interval(minutes: max(1, minutes))
        case .dailyAt:
            let h = try c.decode(Int.self, forKey: .hour)
            let m = try c.decode(Int.self, forKey: .minute)
            self = .dailyAt(hour: h, minute: m)
        case .weekdaysAt:
            let h = try c.decode(Int.self, forKey: .hour)
            let m = try c.decode(Int.self, forKey: .minute)
            self = .weekdaysAt(hour: h, minute: m)
        case .weeklyAt:
            let w = try c.decode(Int.self, forKey: .weekday)
            let h = try c.decode(Int.self, forKey: .hour)
            let m = try c.decode(Int.self, forKey: .minute)
            self = .weeklyAt(weekday: w, hour: h, minute: m)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .interval(let minutes):
            try c.encode(Kind.interval, forKey: .kind)
            try c.encode(minutes, forKey: .minutes)
        case .dailyAt(let h, let m):
            try c.encode(Kind.dailyAt, forKey: .kind)
            try c.encode(h, forKey: .hour)
            try c.encode(m, forKey: .minute)
        case .weekdaysAt(let h, let m):
            try c.encode(Kind.weekdaysAt, forKey: .kind)
            try c.encode(h, forKey: .hour)
            try c.encode(m, forKey: .minute)
        case .weeklyAt(let weekday, let h, let m):
            try c.encode(Kind.weeklyAt, forKey: .kind)
            try c.encode(weekday, forKey: .weekday)
            try c.encode(h, forKey: .hour)
            try c.encode(m, forKey: .minute)
        }
    }

    /// Compute the next moment (>= `after`) this schedule should fire.
    /// Returns nil only when the schedule is degenerate (e.g. interval 0).
    func nextFireDate(after reference: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .interval(let minutes):
            guard minutes > 0 else { return nil }
            return reference.addingTimeInterval(TimeInterval(minutes * 60))

        case .dailyAt(let h, let m):
            return Self.nextDate(matching: nil, hour: h, minute: m, after: reference, calendar: calendar)

        case .weekdaysAt(let h, let m):
            var probe = Self.nextDate(matching: nil, hour: h, minute: m, after: reference, calendar: calendar)
            for _ in 0..<8 {
                guard let candidate = probe else { return nil }
                let weekday = calendar.component(.weekday, from: candidate)
                if weekday >= 2 && weekday <= 6 { return candidate }
                probe = candidate.addingTimeInterval(60) // bump one minute past, then re-find
                probe = Self.nextDate(matching: nil, hour: h, minute: m, after: probe!, calendar: calendar)
            }
            return nil

        case .weeklyAt(let weekday, let h, let m):
            return Self.nextDate(matching: weekday, hour: h, minute: m, after: reference, calendar: calendar)
        }
    }

    private static func nextDate(matching weekday: Int?, hour: Int, minute: Int, after reference: Date, calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        if let weekday { components.weekday = weekday }
        return calendar.nextDate(
            after: reference,
            matching: components,
            matchingPolicy: .nextTime
        )
    }
}

/// A user-defined automation. The `prompt` is sent as the first user
/// message of a brand-new session every time the schedule fires.
struct AgentRoutine: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var prompt: String
    /// Workspace the spawned session should be bound to. Nil = no workspace.
    var workspaceRootPath: String?
    /// Concrete model override. Nil = follow current Flash/Pro route.
    var modelID: String?
    var schedule: AgentRoutineSchedule
    var isEnabled: Bool
    /// When the routine last fired (regardless of success). Used by the
    /// scheduler to decide the next fire time and to render "上次运行 X 分钟前".
    var lastRunAt: Date?
    /// The session id produced by the most recent run, so the sidebar can
    /// offer a "跳到上次结果" affordance.
    var lastSessionID: UUID?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String = L10n.Automation.defaultName,
        prompt: String = "",
        workspaceRootPath: String? = nil,
        modelID: String? = nil,
        schedule: AgentRoutineSchedule = .dailyAt(hour: 9, minute: 0),
        isEnabled: Bool = true,
        lastRunAt: Date? = nil,
        lastSessionID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.workspaceRootPath = workspaceRootPath
        self.modelID = modelID
        self.schedule = schedule
        self.isEnabled = isEnabled
        self.lastRunAt = lastRunAt
        self.lastSessionID = lastSessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Workspace folder name (or "No workspace"), mirroring AgentSession.
    var workspaceDisplayName: String {
        guard let path = workspaceRootPath, !path.isEmpty else { return L10n.Automation.noWorkspace }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// The next moment this routine wants to fire, given the current
    /// `lastRunAt` (or `createdAt` if it never ran). Returns nil if the
    /// schedule is degenerate or the routine is disabled.
    func nextFireDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard isEnabled else { return nil }
        let reference = lastRunAt ?? createdAt
        return schedule.nextFireDate(after: reference, calendar: calendar)
    }

    // MARK: Codable — decodeIfPresent on every field added after launch
    // so older routine JSON keeps loading cleanly.
    enum CodingKeys: String, CodingKey {
        case id, name, prompt, workspaceRootPath, modelID, schedule
        case isEnabled, lastRunAt, lastSessionID, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.prompt = try c.decode(String.self, forKey: .prompt)
        self.workspaceRootPath = try c.decodeIfPresent(String.self, forKey: .workspaceRootPath)
        self.modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        self.schedule = try c.decode(AgentRoutineSchedule.self, forKey: .schedule)
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        self.lastSessionID = try c.decodeIfPresent(UUID.self, forKey: .lastSessionID)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}
