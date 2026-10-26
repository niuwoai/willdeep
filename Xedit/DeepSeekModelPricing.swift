import Foundation

/// Public API reference prices, USD per million tokens. Gateway invoices may
/// differ. Preserve the previous table for records before the pricing change.
/// Sources: api-docs.deepseek.com/quick_start/pricing/ and /updates/.
enum DeepSeekModelPricing {
    private static let effectiveAt = Date(timeIntervalSince1970: 1_786_896_000) // 2026-08-16 16:00 UTC
    private static let flashModels: Set<String> = ["deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp", "deepseek-v4.1-flash", "deepseek-v4.1-flash-1017"]

    static func price(model: String, at date: Date?) -> AgentModelPrice? {
        let isFlash = flashModels.contains(model)
        guard isFlash || model == "deepseek-v4-pro" || model == "deepseek-v4-pro-0813" else { return nil }
        if let date, date < effectiveAt { return nil }
        // Missing timestamps cannot establish a discount. Use the peak rate
        // as a conservative reference estimate for legacy aggregate usage.
        let multiplier = date.map { isOffPeak($0) ? 0.5 : 1.0 } ?? 1.0
        return AgentModelPrice(
            providerIDs: ["deepseek"], modelHints: [model],
            inputPerMillion: (isFlash ? 0.30 : 1.32) * multiplier,
            cachedInputPerMillion: (isFlash ? 0.006 : 0.044) * multiplier,
            cacheWritePerMillion: nil,
            outputPerMillion: (isFlash ? 1.20 : 3.96) * multiplier
        )
    }

    static func isOffPeak(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let weekday = calendar.component(.weekday, from: date)
        let hour = calendar.component(.hour, from: date)
        if weekday == 1 || weekday == 7 { return true }
        if !(1..<4).contains(hour) && !(6..<10).contains(hour) { return true }
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.year == 2026, let month = components.month, let day = components.day else { return false }
        // State Council 2026 holiday calendar; weekend make-up work days
        // remain off-peak under DeepSeek's explicit Monday-Friday rule.
        // www.gov.cn/zhengce/content/202511/content_7047090.htm
        let holidays: [Int: ClosedRange<Int>] = [1: 1...3, 2: 15...23, 4: 4...6,
                                               5: 1...5, 6: 19...21, 9: 25...27, 10: 1...7]
        return holidays[month]?.contains(day) ?? false
    }
}
