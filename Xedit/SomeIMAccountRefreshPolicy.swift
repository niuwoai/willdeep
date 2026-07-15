//
//  SomeIMAccountRefreshPolicy.swift
//  WillDeep
//
//  Low-frequency fallback refresh for the sidebar account snapshot. AI response
//  headers are the fast path; this jittered loop heals stale state when the user
//  stays idle or an older edge node does not yet emit versioned credits headers.
//

import Foundation

enum SomeIMAccountRefreshPolicy {
    nonisolated static let staleAfter: TimeInterval = 120
    nonisolated static let minimumDelay: TimeInterval = 240
    nonisolated static let maximumDelay: TimeInterval = 420

    nonisolated static func shouldRefresh(_ account: SomeIMAccount?, now: Date = Date()) -> Bool {
        guard let account else { return false }
        return now.timeIntervalSince(account.lastUpdatedAt) >= staleAfter
    }

    nonisolated static func nextDelay(randomUnit: Double = Double.random(in: 0...1)) -> TimeInterval {
        let unit = min(1, max(0, randomUnit))
        return minimumDelay + ((maximumDelay - minimumDelay) * unit)
    }
}
