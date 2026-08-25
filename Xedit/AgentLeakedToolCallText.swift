//
//  AgentLeakedToolCallText.swift
//  WillDeep
//
//  Recovery for tool-call syntax that arrives as plain text instead of a
//  structured call.
//

import Foundation

/// Finds raw tool-call markup that a model wrote into `content`.
///
/// Providers only switch their tool-call parser on when the request declares
/// tools. A round that declares none but still gets a call back receives the
/// unparsed syntax as ordinary text: DeepSeek's DSML block
/// (`<｜DSML｜tool_calls>…`), the `<tool_call><function=…>` shape several
/// open-weight families use, and so on. Nothing downstream can act on that
/// text — the call is already lost — so the only useful move is to keep
/// whatever prose came before it and discard the fragment instead of
/// rendering it, persisting it, and replaying it as history.
///
/// Kept deliberately narrow: only markup that unambiguously opens a call is
/// treated as a marker, because ordinary prose is allowed to mention these
/// tag names when a model is explaining tool syntax rather than using it.
nonisolated enum AgentLeakedToolCallText {
    nonisolated struct Detection: Equatable, Sendable {
        /// Everything before the first marker, whitespace-trimmed. Empty when
        /// the reply was nothing but markup.
        let cleanedText: String
        /// The discarded tail, kept for logging and test assertions.
        let discardedFragment: String
    }

    /// U+FF5C, the full-width bar DeepSeek's special tokens are built from.
    private static let fullWidthPipe: Character = "\u{FF5C}"

    /// Fixed-shape openers. `<function=` is included only in its `=` form:
    /// a bare `<function>` shows up in ordinary prose about XML far more
    /// often than it does in a leaked call.
    private static let plainMarkers = [
        "<tool_call>",
        "</tool_call>",
        "<tool_calls>",
        "</tool_calls>",
        "<function=",
    ]

    static func detect(in text: String) -> Detection? {
        guard let markerStart = firstMarkerIndex(in: text) else { return nil }
        return Detection(
            cleanedText: String(text[text.startIndex..<markerStart])
                .trimmingCharacters(in: .whitespacesAndNewlines),
            discardedFragment: String(text[markerStart...])
        )
    }

    static func contains(in text: String) -> Bool {
        firstMarkerIndex(in: text) != nil
    }

    private static func firstMarkerIndex(in text: String) -> String.Index? {
        var earliest: String.Index?
        for marker in plainMarkers {
            guard let range = text.range(of: marker) else { continue }
            if earliest == nil || range.lowerBound < earliest! {
                earliest = range.lowerBound
            }
        }
        if let dsml = firstDSMLTagIndex(in: text), earliest == nil || dsml < earliest! {
            earliest = dsml
        }
        return earliest
    }

    /// Locates the first DSML tag, open or close.
    ///
    /// The bar count is matched as a run rather than a fixed literal: the
    /// canonical token carries one `｜` on each side, but a model reproducing
    /// the syntax from memory — which is exactly what happens once the format
    /// is not activated by a tools declaration — routinely doubles them.
    private static func firstDSMLTagIndex(in text: String) -> String.Index? {
        var searchStart = text.startIndex
        while let family = text.range(of: "DSML", range: searchStart..<text.endIndex) {
            if isFollowedByPipe(in: text, at: family.upperBound),
               let opening = tagOpening(in: text, endingAt: family.lowerBound) {
                return opening
            }
            searchStart = family.upperBound
        }
        return nil
    }

    /// Walks back over the leading bar run to the `<` or `</` that opens the
    /// tag, or returns nil when the match was not tag-shaped after all.
    private static func tagOpening(in text: String, endingAt index: String.Index) -> String.Index? {
        var cursor = index
        var pipeCount = 0
        while cursor > text.startIndex, text[text.index(before: cursor)] == fullWidthPipe {
            pipeCount += 1
            cursor = text.index(before: cursor)
        }
        guard pipeCount > 0, cursor > text.startIndex else { return nil }
        var opening = text.index(before: cursor)
        if text[opening] == "/" {
            guard opening > text.startIndex else { return nil }
            opening = text.index(before: opening)
        }
        guard text[opening] == "<" else { return nil }
        return opening
    }

    private static func isFollowedByPipe(in text: String, at index: String.Index) -> Bool {
        index < text.endIndex && text[index] == fullWidthPipe
    }
}
