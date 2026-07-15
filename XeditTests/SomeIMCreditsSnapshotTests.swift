import Foundation
import Testing
@testable import WillDeep

struct SomeIMCreditsSnapshotTests {
    @Test("versioned credits headers decode only as a complete snapshot")
    func responseHeaderSnapshotRequiresTimestamp() throws {
        let url = try #require(URL(string: "https://some.im/v1/chat/completions"))
        let complete = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: [
                SomeIMCreditsSnapshot.remainingHeader: "96870000",
                SomeIMCreditsSnapshot.updatedAtHeader: "1784100000123456",
                SomeIMCreditsSnapshot.creditsPerUSDHeader: "100000",
                SomeIMCreditsSnapshot.sourceHeader: "edge-snapshot",
            ]
        ))
        let decoded = try #require(SomeIMCreditsSnapshot.responseSnapshot(from: complete))
        #expect(decoded.credits == "96870000")
        #expect(decoded.updatedAtMicros == 1_784_100_000_123_456)
        #expect(decoded.creditsPerUSD == 100_000)
        #expect(decoded.source == "edge-snapshot")

        let missingTimestamp = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: [SomeIMCreditsSnapshot.remainingHeader: "1"]
        ))
        #expect(SomeIMCreditsSnapshot.responseSnapshot(from: missingTimestamp) == nil)
    }

    @Test("older or equal credits snapshots never overwrite newer account state")
    func snapshotOrderingIsStrictlyIncreasing() throws {
        let account = SomeIMAccount(
            email: "user@example.invalid",
            tenantID: nil,
            balanceUSD: "968.70",
            credits: "96870000",
            creditsPerUSD: 100_000,
            defaultModel: "someim-auto-flash",
            lastUpdatedAt: Date(timeIntervalSince1970: 1_784_100_000),
            creditsUpdatedAtMicros: 200
        )

        let older = SomeIMCreditsSnapshot(credits: "100", updatedAtMicros: 199, creditsPerUSD: 100_000, source: "edge-snapshot")
        let equal = SomeIMCreditsSnapshot(credits: "200", updatedAtMicros: 200, creditsPerUSD: 100_000, source: "origin")
        let newer = SomeIMCreditsSnapshot(credits: "300", updatedAtMicros: 201, creditsPerUSD: 100_000, source: "origin")

        #expect(older.applying(to: account) == nil)
        #expect(equal.applying(to: account) == nil)
        let applied = try #require(newer.applying(to: account))
        #expect(applied.credits == "300")
        #expect(applied.balanceUSD == "0.003")
        #expect(applied.creditsUpdatedAtMicros == 201)
    }

    @Test("slower balance refresh may update identity but never versioned credits")
    func slowerAccountRefreshPreservesNewerCredits() {
        let current = SomeIMAccount(
            email: "user@example.invalid",
            nickname: "旧昵称",
            tenantID: nil,
            balanceUSD: "9",
            credits: "900000",
            creditsPerUSD: 100_000,
            defaultModel: "someim-auto-flash",
            lastUpdatedAt: Date(timeIntervalSince1970: 2),
            creditsUpdatedAtMicros: 200
        )
        let slowerRefresh = SomeIMAccount(
            email: "user@example.invalid",
            nickname: "新昵称",
            tenantID: nil,
            balanceUSD: "1",
            credits: "100000",
            creditsPerUSD: 100_000,
            defaultModel: "someim-auto-flash",
            lastUpdatedAt: Date(timeIntervalSince1970: 3),
            creditsUpdatedAtMicros: 199
        )

        let merged = SomeIMIntegrationStore.mergedRefreshedAccount(slowerRefresh, current: current)
        #expect(merged.nickname == "新昵称")
        #expect(merged.credits == "900000")
        #expect(merged.balanceUSD == "9")
        #expect(merged.creditsUpdatedAtMicros == 200)
    }

    @Test("automatic balance refresh uses a bounded jitter window")
    func fallbackRefreshPolicy() {
        let now = Date(timeIntervalSince1970: 1_000)
        var account = SomeIMAccount(
            email: "user@example.invalid",
            tenantID: nil,
            balanceUSD: "1",
            credits: "100000",
            creditsPerUSD: 100_000,
            defaultModel: "someim-auto-flash",
            lastUpdatedAt: now.addingTimeInterval(-119)
        )
        #expect(!SomeIMAccountRefreshPolicy.shouldRefresh(account, now: now))
        account.lastUpdatedAt = now.addingTimeInterval(-120)
        #expect(SomeIMAccountRefreshPolicy.shouldRefresh(account, now: now))
        #expect(SomeIMAccountRefreshPolicy.nextDelay(randomUnit: 0) == 240)
        #expect(SomeIMAccountRefreshPolicy.nextDelay(randomUnit: 1) == 420)
    }
}
