//
//  L10nModelUsageSummary.swift
//  WillDeep
//
//  Dashboard-only model usage copy, kept separate from the core catalogue
//  so L10n.swift stays below the repository hard line-count limit.
//

import Foundation

extension L10n.ModelUsage {
    static let summaryEstimatedCost = String(
        localized: "model-usage.summary.estimated-cost",
        defaultValue: "Estimated cost"
    )
    static let summaryHighestCache = String(
        localized: "model-usage.summary.highest-cache",
        defaultValue: "Highest cache"
    )
    static let summaryInputTokens = String(
        localized: "model-usage.summary.input-tokens",
        defaultValue: "Input tokens"
    )
    static let summaryOutputTokens = String(
        localized: "model-usage.summary.output-tokens",
        defaultValue: "Output tokens"
    )
    static let title = String(
        localized: "model-usage.title",
        defaultValue: "Model usage"
    )

    static func summaryCount(_ modelCount: String, _ providerCount: String) -> String {
        let template = String(
            localized: "model-usage.summary.count",
            defaultValue: "%1$@ models · %2$@ providers"
        )
        return String(format: template, modelCount, providerCount)
    }
}
