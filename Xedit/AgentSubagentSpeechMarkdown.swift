//
//  AgentSubagentSpeechMarkdown.swift
//  WillDeep
//
//  Bakes a Worker's round text into one attributed string for the delegation
//  card.
//
//  Why not render Markdown the way the transcript does: the card is a live
//  surface that repaints on every heartbeat, and building a view tree per
//  Markdown block on a repainting surface is the exact shape that once pinned
//  the main thread in layout. So the rule here is one attributed string, one
//  text view — blocks become runs, never nested views. Combined with the
//  limits the card already enforces (published once per completed round, 600
//  characters, six utterances) the cost stays bounded no matter what the
//  Worker says.
//
//  The parsing is not a second Markdown implementation: block structure comes
//  from `MarkdownPreviewParser` and table layout from
//  `AgentMarkdownTableFormatter`, the same two the chat transcript uses, so a
//  table reads the same in both places.
//
//  AppKit rather than SwiftUI attributes: the result is displayed by a
//  read-only `NSTextView` (`AgentSubagentSpeechSelectableText`), because a
//  Worker's words get the same selection bubble the settled transcript gets
//  and SwiftUI's `.textSelection` hands back no way to read the selection.
//

import WillDeepCore
import AppKit

enum AgentSubagentSpeechMarkdown {
    /// Renders `raw` for a card body at `baseSize`.
    ///
    /// Falls back to the plain string whenever the parser finds nothing to
    /// structure, so a Worker that just talks costs no more than it did when
    /// this text was rendered verbatim.
    static func attributedString(from raw: String, baseSize: CGFloat) -> NSAttributedString {
        let blocks = MarkdownPreviewParser.blocks(from: raw)
        let output = NSMutableAttributedString()
        if blocks.isEmpty {
            output.append(plain(raw, size: baseSize))
        } else {
            for (index, block) in blocks.enumerated() {
                if index > 0 {
                    output.append(plain(
                        separator(before: block, after: blocks[index - 1]),
                        size: baseSize
                    ))
                }
                output.append(rendered(block, baseSize: baseSize))
            }
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        output.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: output.length)
        )

        // An explicit monospaced run does not synthesize a CJK fallback, and
        // a Worker's tables are routinely 中文表头 — without this pass every
        // one of those characters draws as a box. Same repair the transcript
        // applies to its own code and table runs.
        _ = SyntaxHighlighter.applyEditorCJKFallbackFonts(
            to: output,
            source: output.string,
            defaultFont: NSFont.systemFont(ofSize: baseSize)
        )
        return output
    }

    /// One newline between lines of the same thought, two around a block that
    /// is its own object on the page — without the blank line a conclusion
    /// sentence butts straight against the last row of the table it concludes.
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
    ) -> NSAttributedString {
        switch block.kind {
        case .heading(let level):
            // Two steps of emphasis, not six: the card is 10pt text in a
            // transcript cell, and an `#` heading at document scale would
            // shout louder than the chat around it.
            let size = baseSize + (level <= 2 ? 1.5 : 0.5)
            return inline(block.text, size: size, weight: .semibold)

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
            let rendered = NSMutableAttributedString(
                attributedString: plain("▏ ", size: baseSize)
            )
            rendered.append(inline(block.text, size: baseSize, weight: .regular))
            rendered.addAttribute(
                .foregroundColor,
                value: NSColor.tertiaryLabelColor,
                range: NSRange(location: 0, length: rendered.length)
            )
            return rendered

        case .divider:
            return plain("───", size: baseSize)

        case .image:
            // The card never loads images — a Worker's round text is a status
            // line, not a document. The alt text is what it meant.
            return plain(
                block.text.isEmpty ? (block.imageSource ?? "") : block.text,
                size: baseSize
            )

        case .paragraph:
            return inline(block.text, size: baseSize, weight: .regular)
        }
    }

    private static func listItem(
        marker: String,
        block: MarkdownPreviewBlock,
        baseSize: CGFloat
    ) -> NSAttributedString {
        // Leading spaces rather than a paragraph indent: the card's rows are
        // measured by their own text view, and a nested bullet that silently
        // loses its indent reads as a flat list.
        let indent = String(repeating: " ", count: max(0, block.indent) * 2)
        let rendered = NSMutableAttributedString(
            attributedString: plain(indent + marker, size: baseSize)
        )
        rendered.append(inline(block.text, size: baseSize, weight: .regular))
        return rendered
    }

    private static func table(
        _ layout: (text: String, spans: [AgentMarkdownTableFormatter.StyledSpan]),
        size: CGFloat
    ) -> NSAttributedString {
        let rendered = NSMutableAttributedString(
            attributedString: monospaced(layout.text, size: size)
        )
        // Spans are Character offsets into `layout.text`; NSRange wants UTF-16.
        let characters = Array(layout.text)
        for span in layout.spans {
            guard span.range.lowerBound >= 0,
                  span.range.lowerBound < span.range.upperBound,
                  span.range.upperBound <= characters.count else { continue }
            let prefix = String(characters[0..<span.range.lowerBound])
            let body = String(characters[span.range.lowerBound..<span.range.upperBound])
            let range = NSRange(location: prefix.utf16.count, length: body.utf16.count)
            guard NSMaxRange(range) <= rendered.length else { continue }
            switch span.style {
            case .bold:
                rendered.addAttribute(
                    .font,
                    value: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold),
                    range: range
                )
            case .italic:
                rendered.addAttribute(
                    .font,
                    value: NSFontManager.shared.convert(
                        NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
                        toHaveTrait: .italicFontMask
                    ),
                    range: range
                )
            case .code:
                rendered.addAttribute(
                    .backgroundColor,
                    value: NSColor.labelColor.withAlphaComponent(0.07),
                    range: range
                )
            }
        }
        return rendered
    }

    // MARK: Inline

    /// Inline Markdown only — `**bold**`, `*italic*`, `` `code` `` and links.
    /// Block syntax is already off by the time this runs, so
    /// `.inlineOnlyPreservingWhitespace` is what keeps a lone `#` or a stray
    /// `-` inside a sentence from being eaten as structure.
    private static func inline(
        _ raw: String,
        size: CGFloat,
        weight: NSFont.Weight
    ) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard let parsed = try? AttributedString(markdown: raw, options: options) else {
            return NSAttributedString(string: raw, attributes: base)
        }

        let visible = String(parsed.characters)
        let rendered = NSMutableAttributedString(string: visible, attributes: base)
        var characterOffset = 0
        for run in parsed.runs {
            let count = parsed.characters[run.range].count
            defer { characterOffset += count }
            guard count > 0, let intent = run.inlinePresentationIntent else { continue }
            let lower = visible.index(visible.startIndex, offsetBy: characterOffset)
            let upper = visible.index(lower, offsetBy: count)
            let range = NSRange(lower..<upper, in: visible)
            if intent.contains(.code) {
                rendered.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: size - 0.5, weight: .regular),
                    .backgroundColor: NSColor.labelColor.withAlphaComponent(0.07),
                ], range: range)
            } else if intent.contains(.stronglyEmphasized) {
                rendered.addAttribute(
                    .font,
                    value: NSFont.systemFont(ofSize: size, weight: .semibold),
                    range: range
                )
            } else if intent.contains(.emphasized) {
                rendered.addAttribute(
                    .font,
                    value: NSFontManager.shared.convert(
                        NSFont.systemFont(ofSize: size, weight: weight),
                        toHaveTrait: .italicFontMask
                    ),
                    range: range
                )
            }
        }
        return rendered
    }

    private static func plain(_ raw: String, size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: raw, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    private static func monospaced(_ raw: String, size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: raw, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }
}
