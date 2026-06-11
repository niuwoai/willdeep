//
//  AgentUsageStats.swift
//  WillDeep
//
//  Pure analytics over the persisted Agent sessions. Powers the
//  Claude-Code-style stats dashboard shown in place of the empty-chat
//  hero. Nothing here touches disk or talks to a provider — feed it
//  the in-memory `[AgentSession]` and it computes everything else.
//

import Foundation

/// Aggregate metrics for the Agent-mode stats dashboard.
struct AgentUsageOverview: Equatable {
    var sessionCount: Int
    var messageCount: Int
    /// Sum of `AgentMessage.usageTokens` where reported; for messages
    /// without a real usage number we fall back to chars/4 + per-image
    /// budget so old sessions still contribute something.
    var totalTokens: Int
    /// True when at least one message had a real usage number — the UI
    /// labels the total "≈" otherwise.
    var hasAnyRealUsage: Bool
    /// Distinct calendar days (user's current timezone) that saw at
    /// least one message.
    var activeDays: Int
    /// Length of the most recent run of consecutive active days that
    /// includes today (or 0 if today is empty).
    var currentStreak: Int
    /// Length of the longest run of consecutive active days ever.
    var longestStreak: Int
    /// Hour-of-day (0-23) with the most messages. Nil if no messages.
    var peakHour: Int?
    /// Model ID with the most messages routed through it.
    var favoriteModel: String?
}

/// One cell of the GitHub-style heatmap: a calendar day plus its
/// message count.
struct AgentHeatmapCell: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let count: Int
}

enum AgentUsageStats {
    /// Build an overview snapshot for the given sessions. Pure function
    /// — same input always produces the same output, no side effects.
    static func overview(for sessions: [AgentSession], now: Date = Date()) -> AgentUsageOverview {
        let allMessages = sessions.flatMap(\.messages)
        let messageCount = allMessages.count
        let sessionCount = sessions.count

        var totalTokens = 0
        var hasAnyRealUsage = false
        for message in allMessages {
            if let usage = message.usageTokens, usage > 0 {
                totalTokens += usage
                hasAnyRealUsage = true
            } else {
                totalTokens += estimateTokens(for: message)
            }
        }

        let calendar = Calendar.current
        let dayKeys: [Date] = allMessages.map { calendar.startOfDay(for: $0.createdAt) }
        let uniqueDays = Set(dayKeys)
        let activeDays = uniqueDays.count

        let streaks = computeStreaks(
            uniqueDays: uniqueDays,
            now: now,
            calendar: calendar
        )

        var hourCounts: [Int: Int] = [:]
        for message in allMessages {
            let hour = calendar.component(.hour, from: message.createdAt)
            hourCounts[hour, default: 0] += 1
        }
        let peakHour = hourCounts.max { $0.value < $1.value }?.key

        var modelCounts: [String: Int] = [:]
        for session in sessions {
            guard let model = session.modelID, !model.isEmpty else { continue }
            modelCounts[model, default: 0] += session.messages.count
        }
        let favoriteModel = modelCounts.max { $0.value < $1.value }?.key

        return AgentUsageOverview(
            sessionCount: sessionCount,
            messageCount: messageCount,
            totalTokens: totalTokens,
            hasAnyRealUsage: hasAnyRealUsage,
            activeDays: activeDays,
            currentStreak: streaks.current,
            longestStreak: streaks.longest,
            peakHour: peakHour,
            favoriteModel: favoriteModel
        )
    }

    /// Produce a GitHub-style heatmap: `weekCount` columns of 7 rows
    /// each (Mon..Sun), counting messages per day in the user's local
    /// timezone. Defaults to 12 weeks. Returned in column-major order
    /// (oldest column first); the caller renders left → right.
    static func heatmap(
        for sessions: [AgentSession],
        weekCount: Int = 12,
        now: Date = Date()
    ) -> [[AgentHeatmapCell]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let earliestStart = calendar.date(byAdding: .day, value: -(weekCount * 7 - 1), to: today) else {
            return []
        }

        let messages = sessions.flatMap(\.messages)
        var perDay: [Date: Int] = [:]
        for message in messages {
            let day = calendar.startOfDay(for: message.createdAt)
            if day < earliestStart { continue }
            perDay[day, default: 0] += 1
        }

        var columns: [[AgentHeatmapCell]] = []
        for week in 0..<weekCount {
            var column: [AgentHeatmapCell] = []
            for day in 0..<7 {
                let offset = week * 7 + day
                guard let date = calendar.date(byAdding: .day, value: offset, to: earliestStart) else { continue }
                let count = perDay[date] ?? 0
                column.append(AgentHeatmapCell(date: date, count: count))
            }
            columns.append(column)
        }
        return columns
    }

    /// Number of "War and Peace"s the user has burned through, for the
    /// fun-fact line in the dashboard footer. War and Peace ≈ 587k words ≈ 783k
    /// tokens at our chars/4 heuristic. We just call it 780k for round numbers.
    static func warAndPeaceEquivalents(tokenTotal: Int) -> Double {
        guard tokenTotal > 0 else { return 0 }
        return Double(tokenTotal) / 780_000.0
    }

    // MARK: - Internals

    private static func estimateTokens(for message: AgentMessage) -> Int {
        var total = max(0, message.modelContent.count / 4)
        // Reasoning content costs tokens too even when the provider
        // doesn't split it out.
        if let reasoning = message.reasoningContent {
            total += reasoning.count / 4
        }
        // Tool-call argument bodies are part of the wire payload.
        for call in message.toolCalls {
            total += call.argumentsJSON.count / 4
        }
        // Per-image flat budget aligning with AppState.estimatedAgentTokens.
        total += message.images.count * 600
        return total
    }

    private static func computeStreaks(
        uniqueDays: Set<Date>,
        now: Date,
        calendar: Calendar
    ) -> (current: Int, longest: Int) {
        guard !uniqueDays.isEmpty else { return (0, 0) }

        let sortedDays = uniqueDays.sorted()
        var longest = 1
        var run = 1
        for index in 1..<sortedDays.count {
            let prev = sortedDays[index - 1]
            let curr = sortedDays[index]
            if let next = calendar.date(byAdding: .day, value: 1, to: prev), next == curr {
                run += 1
                longest = max(longest, run)
            } else {
                run = 1
            }
        }

        // Current streak only counts if today is active (and walks
        // backward day-by-day from today).
        let today = calendar.startOfDay(for: now)
        var current = 0
        var cursor = today
        while uniqueDays.contains(cursor) {
            current += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }

        return (current, longest)
    }
}
