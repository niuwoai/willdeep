//
//  AgentSecretSearch.swift
//  WillDeep
//
//  Search and pagination for the saved-secret list. Kept as pure functions
//  so the matching rules (including Mandarin pinyin) are unit-testable
//  without a view.
//

import Foundation

nonisolated enum AgentSecretSearch {
    /// Rows per page in the secret manager. Small on purpose: the list sits
    /// inside a sheet and a settings pane, both of which are height-bound.
    static let pageSize = 20

    /// Case/diacritic/width-insensitive, whitespace-free form. Both sides of
    /// every comparison go through this, so "API Key" matches "apikey".
    static func normalized(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .lowercased()
    }

    /// Mandarin romanization of a label, as full syllables and as initials.
    ///
    /// Returns empty strings for labels with no Han characters: an ASCII
    /// label is already matched verbatim, and running the transform on it
    /// would only produce a second identical haystack.
    static func pinyinTerms(for text: String) -> (full: String, initials: String) {
        guard text.unicodeScalars.contains(where: isHan) else { return ("", "") }
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let syllables = (mutable as String)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return (
            syllables.joined(),
            syllables.compactMap { $0.first.map(String.init) }.joined()
        )
    }

    static func matches(_ secret: AgentSavedSecret, normalizedQuery query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if normalized(secret.label).contains(query) { return true }
        if normalized(secret.identifier).contains(query) { return true }
        let pinyin = pinyinTerms(for: secret.label)
        if !pinyin.full.isEmpty, pinyin.full.contains(query) { return true }
        if !pinyin.initials.isEmpty, pinyin.initials.contains(query) { return true }
        return false
    }

    static func filter(_ secrets: [AgentSavedSecret], query: String) -> [AgentSavedSecret] {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return secrets }
        return secrets.filter { matches($0, normalizedQuery: normalizedQuery) }
    }

    /// Always at least 1: an empty list still shows "page 1 of 1" rather than
    /// a paginator that reads 1/0.
    static func pageCount(itemCount: Int, pageSize: Int = pageSize) -> Int {
        guard pageSize > 0, itemCount > 0 else { return 1 }
        return (itemCount + pageSize - 1) / pageSize
    }

    /// Keeps the current page inside the range a (possibly just-filtered or
    /// just-shortened) list can serve.
    static func clampedPageIndex(_ index: Int, itemCount: Int, pageSize: Int = pageSize) -> Int {
        min(max(0, index), pageCount(itemCount: itemCount, pageSize: pageSize) - 1)
    }

    static func page<Element>(
        _ items: [Element],
        pageIndex: Int,
        pageSize: Int = pageSize
    ) -> [Element] {
        guard pageSize > 0, !items.isEmpty else { return [] }
        let clamped = clampedPageIndex(pageIndex, itemCount: items.count, pageSize: pageSize)
        let start = clamped * pageSize
        guard start < items.count else { return [] }
        return Array(items[start..<min(start + pageSize, items.count)])
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}
