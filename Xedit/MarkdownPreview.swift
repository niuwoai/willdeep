//
//  MarkdownPreview.swift
//  Xedit
//
//  Markdown rendering pipeline split out of ContentView.swift in rc39.
//  Used by both the editor's side preview pane and (indirectly, via
//  AgentMarkdownTableFormatter) the Agent chat history. Five public
//  surfaces:
//
//    - `MarkdownPreviewBlock` / `MarkdownPreviewParser` — turn a
//      markdown string into a list of block descriptors (paragraph /
//      heading / quote / list / code / divider / table). The parser
//      handles streaming-safe partial fences (assistant turns flush an
//      unterminated ``` block at EOF), GFM-style pipe tables (header +
//      alignment row + body rows), and 2/4-space-indent nested lists.
//    - `HTMLPreviewParser` — quick-and-dirty HTML → block-list reduction
//      for HTML files in the preview pane (a real DOM parser would be
//      overkill).
//    - `MarkdownPreviewBlockView` — one SwiftUI view that switches on
//      block kind. Heading sizes, list bullet glyphs, and list
//      indentation are local helpers.
//    - `MarkdownInline` — wraps `AttributedString(markdown:)` to give
//      inline-code spans a pill background (Apple's renderer drops the
//      visual treatment).
//    - `MarkdownTableBlockView` / `MarkdownCodeBlockView` — the two
//      block kinds that need their own SwiftUI sub-views (everything
//      else is one-or-two-Text). Code blocks reuse the editor's
//      `SyntaxHighlighter` so language colors match the editor.
//

import SwiftUI
import AppKit

struct MarkdownPreviewBlock: Equatable {
    enum Kind: Equatable {
        case heading(level: Int)
        case paragraph
        case quote
        case unorderedList
        case orderedList
        case code
        case divider
        case table
    }

    let kind: Kind
    let text: String
    /// Optional info string — currently only used for fenced code blocks
    /// to carry the language hint after the opening ``` (e.g. "tsx",
    /// "swift", "bash"). Nil for every other block kind.
    var info: String? = nil
    /// Header cells for `.table` blocks. Nil for every other kind.
    var tableHeaders: [String]? = nil
    /// Body rows for `.table` blocks. Each row is a flat array of cell
    /// strings, already trimmed and inline-Markdown-ready. Nil for
    /// every other kind.
    var tableRows: [[String]]? = nil
    /// Indentation level for list blocks (0 = top-level). 2-space and
    /// 4-space leading indentation both count as one level. Always 0
    /// for non-list blocks.
    var indent: Int = 0
}

enum MarkdownPreviewParser {
    static func blocks(from source: String) -> [MarkdownPreviewBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownPreviewBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var codeLanguage: String? = nil
        var isInCodeBlock = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(MarkdownPreviewBlock(kind: .paragraph, text: paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        func flushCode() {
            // Don't emit a card for a completely empty fenced block — it
            // would just be a stray rectangle. A block with only the
            // language hint and no body yet (streaming case before the
            // first content line arrives) is still emitted below by
            // checking `isInCodeBlock` at EOF.
            guard !code.isEmpty || codeLanguage != nil else {
                code.removeAll()
                codeLanguage = nil
                return
            }
            blocks.append(MarkdownPreviewBlock(
                kind: .code,
                text: code.joined(separator: "\n"),
                info: codeLanguage
            ))
            code.removeAll()
            codeLanguage = nil
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") {
                if isInCodeBlock {
                    flushCode()
                    isInCodeBlock = false
                } else {
                    flushParagraph()
                    isInCodeBlock = true
                    // Everything after the opening ``` (e.g. ```tsx) is
                    // the language hint. Strip any extra whitespace.
                    let hint = String(trimmedLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLanguage = hint.isEmpty ? nil : hint
                }
                i += 1; continue
            }

            if isInCodeBlock {
                code.append(line)
                i += 1; continue
            }

            if trimmedLine.isEmpty {
                flushParagraph()
                i += 1; continue
            }

            if trimmedLine == "---" || trimmedLine == "***" || trimmedLine == "___" {
                flushParagraph()
                blocks.append(MarkdownPreviewBlock(kind: .divider, text: ""))
                i += 1; continue
            }

            if let heading = headingBlock(from: trimmedLine) {
                flushParagraph()
                blocks.append(heading)
                i += 1; continue
            }

            if trimmedLine.hasPrefix(">") {
                flushParagraph()
                let quote = trimmedLine.dropFirst().trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownPreviewBlock(kind: .quote, text: quote))
                i += 1; continue
            }

            // GFM table — header row + alignment row + zero or more
            // body rows. Header has to be a pipe-delimited line; the
            // immediately following line must match the alignment row
            // pattern (cells of `:?---+:?`). Without the alignment row
            // we treat the pipe-delimited line as paragraph text so
            // accidental single `|`-laden prose doesn't get hijacked.
            if isPipeRow(trimmedLine),
               i + 1 < lines.count,
               isAlignmentRow(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                let headers = parseRow(trimmedLine)
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count {
                    let nextTrim = lines[j].trimmingCharacters(in: .whitespaces)
                    guard isPipeRow(nextTrim) else { break }
                    rows.append(parseRow(nextTrim))
                    j += 1
                }
                blocks.append(MarkdownPreviewBlock(
                    kind: .table,
                    text: "",
                    tableHeaders: headers,
                    tableRows: rows
                ))
                i = j
                continue
            }

            if let (indent, body) = listItem(from: line, unordered: true) {
                flushParagraph()
                blocks.append(MarkdownPreviewBlock(kind: .unorderedList, text: body, indent: indent))
                i += 1; continue
            }

            if let (indent, body) = listItem(from: line, unordered: false) {
                flushParagraph()
                blocks.append(MarkdownPreviewBlock(kind: .orderedList, text: body, indent: indent))
                i += 1; continue
            }

            paragraph.append(trimmedLine)
            i += 1
        }

        if isInCodeBlock {
            flushCode()
        }
        flushParagraph()
        return blocks
    }

    /// A pipe-delimited row: starts with `|`, ends with `|`, and has at
    /// least two cells. Models often forget the leading `|` — allow
    /// "cell | cell | cell" as long as there's at least one internal
    /// `|` and the line doesn't look like a list item.
    private static func isPipeRow(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        // Avoid eating list items like "- some | thing".
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return false }
        // Strict form: leading and trailing pipe.
        if line.hasPrefix("|") && line.hasSuffix("|") && line.count >= 3 {
            return true
        }
        // Looser form: at least one internal `|` (so there are at least
        // two cells). Conservative — we still require the alignment
        // row immediately after to actually commit to table parsing,
        // so an offhand pipe in prose won't hijack the parser.
        return line.components(separatedBy: "|").count >= 2
    }

    /// Alignment row: cells of optional `:`, `---+`, optional `:`,
    /// separated by `|`. e.g. `|---|:---:|---:|`. Lenient about extra
    /// outer pipes / whitespace.
    private static func isAlignmentRow(_ line: String) -> Bool {
        guard line.contains("|"), line.contains("-") else { return false }
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
        let cells = trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            guard !cell.isEmpty else { return false }
            var c = cell
            if c.hasPrefix(":") { c = String(c.dropFirst()) }
            if c.hasSuffix(":") { c = String(c.dropLast()) }
            return !c.isEmpty && c.allSatisfy { $0 == "-" }
        }
    }

    /// Split a pipe-delimited row into trimmed cell strings, dropping
    /// the leading/trailing empty cells caused by `|` at either end.
    private static func parseRow(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func headingBlock(from line: String) -> MarkdownPreviewBlock? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6, line.dropFirst(hashes.count).hasPrefix(" ") else {
            return nil
        }
        let text = line.dropFirst(hashes.count + 1).trimmingCharacters(in: .whitespaces)
        return MarkdownPreviewBlock(kind: .heading(level: hashes.count), text: text)
    }

    private static func orderedListText(from line: String) -> String? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let number = line[..<dotIndex]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        let afterDot = line[line.index(after: dotIndex)...]
        guard afterDot.hasPrefix(" ") else { return nil }
        return String(afterDot.dropFirst())
    }

    /// Detect a list item line. Reads the raw (un-trimmed) line so we
    /// can count leading spaces / tabs as indentation. Returns
    /// `(indent, body)` on match; `indent` is the nesting level
    /// (`leadingSpaces / 2`, tabs count as 4 spaces). `unordered`
    /// selects bullet (`- ` / `* `) vs ordered (`N. `).
    private static func listItem(from rawLine: String, unordered: Bool) -> (Int, String)? {
        var spaces = 0
        var i = rawLine.startIndex
        while i < rawLine.endIndex {
            let ch = rawLine[i]
            if ch == " " { spaces += 1 }
            else if ch == "\t" { spaces += 4 }
            else { break }
            i = rawLine.index(after: i)
        }
        guard i < rawLine.endIndex else { return nil }
        let rest = rawLine[i...]
        if unordered {
            if rest.hasPrefix("- ") || rest.hasPrefix("* ") {
                let body = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                return (spaces / 2, body)
            }
        } else {
            if let dotIndex = rest.firstIndex(of: ".") {
                let number = rest[..<dotIndex]
                if !number.isEmpty, number.allSatisfy(\.isNumber) {
                    let afterDot = rest[rest.index(after: dotIndex)...]
                    if afterDot.hasPrefix(" ") {
                        let body = String(afterDot.dropFirst()).trimmingCharacters(in: .whitespaces)
                        return (spaces / 2, body)
                    }
                }
            }
        }
        return nil
    }
}

enum HTMLPreviewParser {
    static func blocks(from source: String) -> [MarkdownPreviewBlock] {
        let nsSource = source as NSString
        let range = NSRange(location: 0, length: nsSource.length)
        let pattern = #"<\s*(title|h[1-5]|p|li|blockquote|pre|code|hr|div)\b([^>]*)>"#
        guard let tagRegex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        var blocks: [MarkdownPreviewBlock] = []
        let matches = tagRegex.matches(in: source, range: range)

        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let tagName = nsSource.substring(with: match.range(at: 1)).lowercased()

            if tagName == "hr" {
                blocks.append(MarkdownPreviewBlock(kind: .divider, text: ""))
                continue
            }

            guard let text = innerText(tagName: tagName, source: nsSource, after: match.range.upperBound) else {
                continue
            }

            switch tagName {
            case "title":
                blocks.append(MarkdownPreviewBlock(kind: .heading(level: 1), text: text))
            case "h1", "h2", "h3", "h4", "h5":
                let level = tagName.last?.wholeNumberValue ?? 1
                blocks.append(MarkdownPreviewBlock(kind: .heading(level: level), text: text))
            case "li":
                blocks.append(MarkdownPreviewBlock(kind: .unorderedList, text: text))
            case "blockquote":
                blocks.append(MarkdownPreviewBlock(kind: .quote, text: text))
            case "pre", "code":
                blocks.append(MarkdownPreviewBlock(kind: .code, text: text))
            default:
                blocks.append(MarkdownPreviewBlock(kind: .paragraph, text: text))
            }

            if blocks.count >= 200 {
                return blocks
            }
        }

        return blocks
    }

    private static func innerText(tagName: String, source: NSString, after start: Int) -> String? {
        let remainingLength = source.length - start
        guard remainingLength > 0 else { return nil }

        let closingPattern = "</\\s*\(NSRegularExpression.escapedPattern(for: tagName))\\s*>"
        guard let closingRegex = try? NSRegularExpression(pattern: closingPattern, options: [.caseInsensitive]) else {
            return nil
        }

        let searchRange = NSRange(location: start, length: min(remainingLength, 8_000))
        guard let closing = closingRegex.firstMatch(in: source as String, range: searchRange) else {
            return nil
        }

        let textRange = NSRange(location: start, length: closing.range.location - start)
        guard textRange.length > 0 else { return nil }

        let raw = source.substring(with: textRange)
        let withoutHiddenContent = raw
            .replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: [.regularExpression, .caseInsensitive])
        let stripped = withoutHiddenContent.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return normalizedText(stripped)
    }

    private static func normalizedText(_ text: String) -> String? {
        let decoded = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        let collapsed = decoded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed
    }
}

struct MarkdownPreviewBlockView: View {
    let block: MarkdownPreviewBlock

    var body: some View {
        switch block.kind {
        case .heading(let level):
            Text(inlineText(block.text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundColor(.primary)
                .padding(.top, level <= 2 ? 8 : 2)
        case .paragraph:
            Text(inlineText(block.text))
                .font(.body)
                .lineSpacing(3)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.45))
                    .frame(width: 3)
                Text(inlineText(block.text))
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        case .unorderedList:
            HStack(alignment: .top, spacing: 8) {
                Text(bulletGlyph(for: block.indent))
                    .foregroundColor(.secondary)
                Text(inlineText(block.text))
            }
            .font(.body)
            .padding(.leading, listIndentPadding(block.indent))
        case .orderedList:
            HStack(alignment: .top, spacing: 8) {
                Text("1.")
                    .foregroundColor(.secondary)
                Text(inlineText(block.text))
            }
            .font(.body)
            .padding(.leading, listIndentPadding(block.indent))
        case .code:
            MarkdownCodeBlockView(text: block.text, languageHint: block.info)
        case .divider:
            Divider()
                .padding(.vertical, 8)
        case .table:
            MarkdownTableBlockView(
                headers: block.tableHeaders ?? [],
                rows: block.tableRows ?? []
            )
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 26
        case 2: return 21
        case 3: return 18
        default: return 15
        }
    }

    private func inlineText(_ text: String) -> AttributedString {
        MarkdownInline.attributedString(from: text)
    }

    /// Bullet glyph cycles by nesting level so the eye can pick out
    /// sub-lists at a glance. Caps at level 2 (▪).
    private func bulletGlyph(for indent: Int) -> String {
        switch indent {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪"
        }
    }

    /// 18pt of left padding per nesting level — enough to read as
    /// "child of the previous item" without pushing the text off the
    /// chat column.
    private func listIndentPadding(_ indent: Int) -> CGFloat {
        CGFloat(min(indent, 4)) * 18
    }
}

/// Inline-Markdown helper used by every block renderer. Wraps
/// `AttributedString(markdown:)` and then walks the runs to give
/// `inlineCode` spans the monospace-with-tinted-background treatment
/// that Apple's built-in renderer skips. Centralised here so headings,
/// paragraphs, quotes, list items, and table cells stay visually
/// consistent.
enum MarkdownInline {
    static func attributedString(from raw: String) -> AttributedString {
        guard var attributed = try? AttributedString(markdown: raw) else {
            return AttributedString(raw)
        }
        // SwiftUI's parsed AttributedString tags inline code runs with
        // .code; we re-style those runs to look like a real code chip:
        // monospaced font + light grey pill background.
        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent,
                  intent.contains(.code) else { continue }
            attributed[run.range].font = .system(.body, design: .monospaced)
            attributed[run.range].backgroundColor = Color.primary.opacity(0.08)
            attributed[run.range].foregroundColor = Color(nsColor: .labelColor)
        }
        return attributed
    }
}

// MARK: - Table block view

/// Renders a GFM-style pipe table. Header row bold + lightly tinted;
/// body rows alternating background for legibility. The whole table sits
/// in a horizontal ScrollView so wide tables don't squeeze the chat
/// column. Inline Markdown (e.g. `code`, **bold**) inside cells is
/// rendered via `AttributedString(markdown:)` just like paragraph text.
struct MarkdownTableBlockView: View {
    let headers: [String]
    let rows: [[String]]

    private var columnCount: Int {
        max(headers.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if !headers.isEmpty {
                    headerRow
                    Divider()
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    bodyRow(row, isOdd: index % 2 == 1)
                    if index < rows.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { col in
                cell(text: col < headers.count ? headers[col] : "", isHeader: true)
            }
        }
        .background(Color.primary.opacity(0.05))
    }

    @ViewBuilder
    private func bodyRow(_ row: [String], isOdd: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { col in
                cell(text: col < row.count ? row[col] : "", isHeader: false)
            }
        }
        .background(isOdd ? Color.primary.opacity(0.025) : Color.clear)
    }

    @ViewBuilder
    private func cell(text: String, isHeader: Bool) -> some View {
        Text(MarkdownInline.attributedString(from: text))
            .font(.system(size: 12, weight: isHeader ? .semibold : .regular))
            .foregroundStyle(isHeader ? .primary : .primary)
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 80, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .trailing) {
                Divider()
                    .opacity(0.25)
            }
    }
}

// MARK: - Fenced code block view

/// Renders a fenced code block with a small header (language label + copy
/// button) and a syntax-highlighted body. Used by Agent-mode assistant
/// messages and the Markdown preview pane. When `languageHint` maps to a
/// known `Language`, `SyntaxHighlighter` colors the body via the shared
/// editor pipeline; unknown languages fall through to monospaced plain
/// text. The body is selectable and horizontally scrollable so long lines
/// don't force the whole chat column wider.
struct MarkdownCodeBlockView: View {
    let text: String
    let languageHint: String?

    @Environment(\.colorScheme) private var colorScheme

    private var resolvedLanguage: Language? {
        MarkdownCodeBlockView.language(forHint: languageHint)
    }

    private var theme: EditorTheme {
        // Stay readable on both light and dark window backgrounds. The
        // user's editor theme isn't threaded through here — code blocks
        // in the chat use a fixed palette so they look the same across
        // every Agent message.
        colorScheme == .dark ? .graphite : .paper
    }

    private var displayLanguageLabel: String {
        if let hint = languageHint?.trimmingCharacters(in: .whitespaces), !hint.isEmpty {
            return hint
        }
        return "code"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(displayLanguageLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textCase(.lowercase)
                Spacer(minLength: 0)
                MarkdownCodeBlockCopyButton(text: text)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.04))

            Divider()
                .opacity(0.4)

            ScrollView(.horizontal, showsIndicators: false) {
                bodyText
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: theme.backgroundColor).opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var bodyText: some View {
        if let lang = resolvedLanguage {
            // SyntaxHighlighter returns NSAttributedString — convert to
            // SwiftUI's AttributedString for native rendering with
            // selectable text. This runs synchronously per body pass,
            // which is fine because chat code blocks are small.
            let monoFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let ns = SyntaxHighlighter.highlightSync(text, language: lang, theme: theme, font: monoFont)
            Text(AttributedString(ns))
                .textSelection(.enabled)
        } else {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    /// Maps a fenced-block info string to a `Language` value. Common
    /// aliases (`sh`/`bash` → shell, `py` → python, `tsx`/`jsx` → ts/js,
    /// etc.) are resolved here so model output can use whatever tag it
    /// prefers without losing highlighting.
    static func language(forHint hint: String?) -> Language? {
        guard let raw = hint?.trimmingCharacters(in: .whitespaces).lowercased(),
              !raw.isEmpty else { return nil }
        switch raw {
        case "swift": return .swift
        case "py", "python", "python3": return .python
        case "rb", "ruby": return .ruby
        case "php": return .php
        case "java": return .java
        case "js", "javascript", "jsx", "mjs", "cjs", "node": return .javascript
        case "ts", "typescript", "tsx": return .typescript
        case "go", "golang": return .go
        case "html", "htm": return .html
        case "css", "scss", "sass", "less": return .css
        case "json", "json5": return .json
        case "md", "markdown": return .markdown
        case "sh", "bash", "zsh", "shell", "console", "shellsession": return .shell
        case "yml", "yaml": return .yaml
        case "toml": return .toml
        case "xml", "svg", "plist": return .xml
        case "sql": return .sql
        case "dockerfile", "docker": return .dockerfile
        case "makefile", "make", "mk": return .makefile
        case "ini", "conf", "config": return .ini
        case "env", "dotenv": return .env
        case "rs", "rust": return .rust
        case "c", "h": return .c
        case "cpp", "c++", "cxx", "cc", "hpp", "hxx": return .cpp
        case "cs", "csharp", "c#": return .csharp
        case "diff", "patch", "udiff": return .diff
        default: return nil
        }
    }
}

struct MarkdownCodeBlockCopyButton: View {
    let text: String
    @State private var didCopy = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.easeOut(duration: 0.15)) { didCopy = true }
            // Reset the affordance after a short beat so back-to-back
            // copies still visibly confirm.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                Text(didCopy ? "Copied" : "Copy")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(didCopy ? Color.green : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy code")
    }
}
