//
//  AgentSubagentSpeechMarkdown.swift
//  WillDeep
//
//  Bakes a Worker's round text into one AttributedString for the delegation
//  card.
//
//  Why not just render Markdown the way the transcript does: the card is a
//  live surface that repaints on every heartbeat, and building a SwiftUI
//  view tree per Markdown block on a repainting surface is the exact shape
//  that once pinned the main thread in layout. So the rule here is one
//  `Text`, always — blocks become runs inside a single attributed string,
//  never nested views. Combined with the limits the card already enforces
//  (published once per completed round, 600 characters, six utterances) the
//  cost stays bounded no matter what the Worker says.
//
//  The parsing is not a second Markdown implementation: block structure
//  comes from `MarkdownPreviewParser` and table layout from
//  `AgentMarkdownTableFormatter`, the same two the chat transcript uses, so
//  a table reads the same in both places.
//

import SwiftUI

enum AgentSubagentSpeechMarkdown {
    /// Renders `raw` for a card body at `baseSize`.
    ///
    /// Falls back to the plain string whenever the parser finds nothing to
    /// structure, so a Worker that just talks costs no more than it did
    /// when this text was rendered verbatim.
    static func attributed(from raw: String, baseSize: CGFloat) -> AttributedString {
        let blocks = MarkdownPreviewParser.blocks(from: raw)
        guard !blocks.isEmpty else { return AttributedString(raw) }

        var output = AttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                output.append(plain(separator(before: block, after: blocks[index - 1]), size: baseSize))
            }
            output.append(rendered(block, baseSize: baseSize))
        }
        return output
    }

    /// One newline between lines of the same thought, two around a block
    /// that is its own object on the page. `Text` ignores paragraph spacing
    /// carried on an AttributedString, so the blank line is the only lever
    /// left — and without it a conclusion sentence butts straight against
    /// the last row of the table it is concluding.
    private static func separator(
        before current: MarkdownPreviewBlock,
        after previous: MarkdownPreviewBlock
    ) -> String {
        func standsAlone(_ block: MarkdownPreviewBlock) -> Bool {
            switch block.kind {
            case .table, .code, .quote, .divider: return true
            default: return false
            }
        }
        return standsAlone(current) || standsAlone(previous) ? "\n\n" : "\n"
    }

    // MARK: Blocks

    private static func rendered(
        _ block: MarkdownPreviewBlock,
        baseSize: CGFloat
    ) -> AttributedString {
        switch block.kind {
        case .heading(let level):
            // Two steps of emphasis, not six: the card is 10pt tall text in
            // a transcript cell, and an `#` heading rendered at document
            // scale would shout louder than the chat around it.
            let size = baseSize + (level <= 2 ? 1.5 : 0.5)
            var rendered = inline(block.text, size: size, weight: .semibold)
            rendered.font = .system(size: size, weight: .semibold)
            return rendered

        case .code:
            return monospaced(block.text, size: baseSize - 0.5)

        case .table:
            let layout = AgentMarkdownTableFormatter.formattedWithSpans(
                headers: block.tableHeaders ?? [],
                rows: block.tableRows ?? []
            )
            guard !layout.text.isEmpty else { return plain(block.text, size: baseSize) }
            return table(layout, size: baseSize - 0.5)

        case .unorderedList:
            return listItem(marker: "•  ", block: block, baseSize: baseSize)

        case .orderedList:
            let number = block.orderedListNumber ?? 1
            return listItem(marker: "\(number).  ", block: block, baseSize: baseSize)

        case .quote:
            var rendered = inline(block.text, size: baseSize, weight: .regular)
            rendered.foregroundColor = .secondary
            return plain("▏ ", size: baseSize) + rendered

        case .divider:
            return plain("───", size: baseSize)

        case .image:
            // The card never loads images — a Worker's round text is a
            // status line, not a document. The alt text is what it meant.
            return plain(block.text.isEmpty ? (block.imageSource ?? "") : block.text, size: baseSize)

        case .paragraph:
            return inline(block.text, size: baseSize, weight: .regular)
        }
    }

    private static func listItem(
        marker: String,
        block: MarkdownPreviewBlock,
        baseSize: CGFloat
    ) -> AttributedString {
        // Leading spaces rather than a paragraph indent: SwiftUI's `Text`
        // ignores paragraph styles carried on an AttributedString, and a
        // nested bullet that silently loses its indent reads as a flat list.
        let indent = String(repeating: " ", count: max(0, block.indent) * 2)
        return plain(indent + marker, size: baseSize)
            + inline(block.text, size: baseSize, weight: .regular)
    }

    private static func table(
        _ layout: (text: String, spans: [AgentMarkdownTableFormatter.StyledSpan]),
        size: CGFloat
    ) -> AttributedString {
        var rendered = AttributedString(layout.text)
        rendered.font = .system(size: size, design: .monospaced)
        // Spans are Character offsets into `layout.text`; bounds-check them
        // against the same view before converting, because `offsetByCharacters`
        // traps rather than returning nil when it runs off the end.
        let characterCount = rendered.characters.count
        for span in layout.spans {
            guard span.range.lowerBound >= 0,
                  span.range.lowerBound < span.range.upperBound,
                  span.range.upperBound <= characterCount else { continue }
            let lower = rendered.index(
                rendered.startIndex,
                offsetByCharacters: span.range.lowerBound
            )
            let upper = rendered.index(lower, offsetByCharacters: span.range.count)
            switch span.style {
            case .bold:
                rendered[lower..<upper].font = .system(size: size, weight: .semibold, design: .monospaced)
            case .italic:
                rendered[lower..<upper].font = .system(size: size, design: .monospaced).italic()
            case .code:
                rendered[lower..<upper].backgroundColor = Color.primary.opacity(0.07)
            }
        }
        return rendered
    }

    // MARK: Inline

    /// Inline Markdown only — `**bold**`, `*italic*`, `` `code` `` and
    /// links. Block syntax has already been taken off by the parser above,
    /// so `.inlineOnlyPreservingWhitespace` is what keeps a lone `#` or a
    /// stray `-` inside a sentence from being eaten as structure.
    private static func inline(
        _ raw: String,
        size: CGFloat,
        weight: Font.Weight
    ) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard var parsed = try? AttributedString(markdown: raw, options: options) else {
            return plain(raw, size: size)
        }
        parsed.font = .system(size: size, weight: weight)
        for run in parsed.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.code) {
                parsed[run.range].font = .system(size: size - 0.5, design: .monospaced)
                parsed[run.range].backgroundColor = Color.primary.opacity(0.07)
            } else if intent.contains(.stronglyEmphasized) {
                parsed[run.range].font = .system(size: size, weight: .semibold)
            } else if intent.contains(.emphasized) {
                parsed[run.range].font = .system(size: size, weight: weight).italic()
            }
        }
        return parsed
    }

    private static func plain(_ raw: String, size: CGFloat) -> AttributedString {
        var rendered = AttributedString(raw)
        rendered.font = .system(size: size)
        return rendered
    }

    private static func monospaced(_ raw: String, size: CGFloat) -> AttributedString {
        var rendered = AttributedString(raw)
        rendered.font = .system(size: size, design: .monospaced)
        return rendered
    }
}
