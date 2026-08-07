//
//  AgentEditFileSupport.swift
//  WillDeep
//
//  Claude-Code-style exact string replacement for the `edit_file` tool.
//  The model supplies (old_string, new_string) against the CURRENT file
//  content; the host locates the match and synthesizes a machine-accurate
//  unified diff that feeds the existing apply_patch pipeline (review card,
//  auto-apply modes, undo, worktree tracking). Hand-written model diffs
//  frequently fail exact hunk matching — a host-generated diff cannot,
//  because its context lines are copied from the real file.
//

import Foundation

enum AgentEditFileError: LocalizedError, Equatable {
    case emptyOldString
    case identicalReplacement(String)
    case oldStringNotFound(String, hint: String?)
    case oldStringNotUnique(String, Int)
    case crlfUnsupported(String)
    case diffRoundTripMismatch(String)

    var errorDescription: String? {
        switch self {
        case .emptyOldString:
            return "old_string must not be empty. Pass the exact text to replace; to create a new file use create_file."
        case .identicalReplacement(let path):
            return "old_string and new_string are identical for \(path). Provide a new_string that differs from old_string."
        case .oldStringNotFound(let path, let hint):
            let base = "old_string was not found in \(path), even with whitespace-tolerant matching. It must match the current file content, and must not include read_file line-number prefixes. Re-read the file and copy the text verbatim."
            if let hint { return base + " Hint: " + hint }
            return base
        case .oldStringNotUnique(let path, let count):
            return "old_string matches \(count) locations in \(path). Include more surrounding lines to make it unique, or pass replace_all=true to replace every occurrence."
        case .crlfUnsupported(let path):
            return "The edit region in \(path) uses CRLF (\\r\\n) line endings, which the diff pipeline does not support. Normalize the file to LF first (e.g. run_command with `perl -pi -e 's/\\r\\n/\\n/'`) and retry the edit."
        case .diffRoundTripMismatch(let path):
            return "Internal error: the synthesized diff for \(path) did not round-trip through the patch applier. Please report this; retry with apply_patch as a fallback."
        }
    }
}

enum AgentEditFileSupport {
    struct Edit: Equatable {
        /// Unified diff consumable by `AgentPatchApplier` — context lines are
        /// copied verbatim from `oldContent`, so hunks always match.
        let diff: String
        /// Full post-edit file content (used by tests and the round-trip check).
        let newContent: String
        /// Number of `old_string` occurrences replaced.
        let occurrences: Int
    }

    static let contextLineCount = 3

    /// Locate `oldString` in `oldContent`, apply the replacement(s), and build
    /// the unified diff. Throws `AgentEditFileError` with model-actionable
    /// messages for the standard failure modes (not found / not unique / no-op).
    static func makeEdit(
        path: String,
        oldContent: String,
        oldString: String,
        newString: String,
        replaceAll: Bool
    ) throws -> Edit {
        guard !oldString.isEmpty else { throw AgentEditFileError.emptyOldString }
        guard oldString != newString else { throw AgentEditFileError.identicalReplacement(path) }

        var ranges: [Range<String.Index>] = []
        var searchStart = oldContent.startIndex
        while searchStart < oldContent.endIndex,
              let found = oldContent.range(of: oldString, range: searchStart..<oldContent.endIndex) {
            ranges.append(found)
            searchStart = found.upperBound
        }

        // The replacement text actually inserted. Exact matches use
        // new_string verbatim; the indentation-tolerant fallback re-indents
        // it to the file's real indentation.
        var replacement = newString

        if ranges.isEmpty {
            // Exact match failed. Models frequently reconstruct old_string
            // with slightly wrong whitespace (mis-stripped read_file line
            // numbers, trailing spaces, shifted indentation). Recover the
            // unambiguous cases instead of failing the tool call; anything
            // still ambiguous or divergent stays a hard error.
            guard !replaceAll, let flexible = flexibleLineMatch(
                oldContent: oldContent,
                oldString: oldString,
                newString: newString
            ) else {
                throw AgentEditFileError.oldStringNotFound(
                    path,
                    hint: notFoundHint(oldContent: oldContent, oldString: oldString)
                )
            }
            if flexible.matches.count > 1 {
                throw AgentEditFileError.oldStringNotUnique(path, flexible.matches.count)
            }
            ranges = [flexible.matches[0]]
            replacement = flexible.replacement
        } else {
            if ranges.count > 1 && !replaceAll {
                throw AgentEditFileError.oldStringNotUnique(path, ranges.count)
            }
            if !replaceAll {
                ranges = [ranges[0]]
            }
        }

        guard oldContent[ranges[0]] != replacement || ranges.count > 1 else {
            // A whitespace-tolerant match that resolves to the identical
            // text is a no-op, same as old_string == new_string.
            throw AgentEditFileError.identicalReplacement(path)
        }

        var newContent = ""
        var cursor = oldContent.startIndex
        for range in ranges {
            newContent += oldContent[cursor..<range.lowerBound]
            newContent += replacement
            cursor = range.upperBound
        }
        newContent += oldContent[cursor...]

        let diff = makeUnifiedDiff(
            path: path,
            oldContent: oldContent,
            replacedRanges: ranges,
            replacement: replacement
        )

        // The generated diff MUST reproduce `newContent` byte-for-byte through
        // the shared applier — this guards the synthesis logic against parser
        // ambiguities (e.g. content lines that resemble diff headers).
        guard let change = try? AgentPatchApplier.parse(diff).first,
              let applied = try? AgentPatchApplier.apply(change, to: oldContent),
              applied == newContent else {
            // The applier parses diffs with a `.newlines` split, so hunk
            // lines carrying a literal "\r" can never round-trip — surface
            // the line-ending problem instead of a generic internal error.
            if oldContent.range(of: "\r", options: .literal) != nil {
                throw AgentEditFileError.crlfUnsupported(path)
            }
            throw AgentEditFileError.diffRoundTripMismatch(path)
        }

        return Edit(diff: diff, newContent: newContent, occurrences: ranges.count)
    }

    // MARK: - Whitespace-tolerant fallback matching

    /// Full-line, whitespace-tolerant fallback used when the exact search
    /// finds nothing. Two tiers, tried in order:
    ///
    /// 1. Ignore trailing whitespace per line (also rescues CRLF files —
    ///    the stray `\r` is trailing whitespace).
    /// 2. Additionally ignore a UNIFORM indentation shift across all
    ///    non-blank lines; `new_string` is re-indented by that same shift
    ///    so the inserted code lands at the file's real indentation.
    ///
    /// Matching is whole-line only: every old_string line must correspond
    /// to one full file line. Returns nil when no window matches (or the
    /// needle is all-blank, where line matching is meaningless).
    static func flexibleLineMatch(
        oldContent: String,
        oldString: String,
        newString: String
    ) -> (matches: [Range<String.Index>], replacement: String)? {
        let needleEndsWithNewline = oldString.hasSuffix("\n")
        var needleLines = oldString.components(separatedBy: "\n")
        if needleEndsWithNewline { needleLines.removeLast() }
        guard !needleLines.isEmpty,
              needleLines.contains(where: { !rstrip($0).isEmpty }) else {
            return nil
        }

        // Lines with their index ranges, scanned via range(of: "\n") — NOT
        // Character iteration or count-based offsets: in a CRLF file "\r\n"
        // is a single Character, so grapheme-based arithmetic misaligns
        // every line start (and can run past endIndex).
        struct FileLine {
            let text: String
            let start: String.Index
            let contentEnd: String.Index
            let next: String.Index
        }
        var fileLines: [FileLine] = []
        var cursor = oldContent.startIndex
        while true {
            if let newline = oldContent.range(of: "\n", options: .literal, range: cursor..<oldContent.endIndex) {
                fileLines.append(FileLine(
                    text: String(oldContent[cursor..<newline.lowerBound]),
                    start: cursor,
                    contentEnd: newline.lowerBound,
                    next: newline.upperBound
                ))
                cursor = newline.upperBound
                if cursor == oldContent.endIndex { break }
            } else {
                fileLines.append(FileLine(
                    text: String(oldContent[cursor...]),
                    start: cursor,
                    contentEnd: oldContent.endIndex,
                    next: oldContent.endIndex
                ))
                break
            }
        }
        guard fileLines.count >= needleLines.count else { return nil }

        func windowRange(start: Int) -> Range<String.Index> {
            let last = fileLines[start + needleLines.count - 1]
            return fileLines[start].start..<(needleEndsWithNewline ? last.next : last.contentEnd)
        }

        // Lines carrying a literal "\r" (CRLF files) can never round-trip
        // through the applier's `.newlines`-split diff parser — refuse to
        // match them so the caller reports the line-ending problem instead
        // of synthesizing a diff that fails downstream.
        let lineHasCarriageReturn = fileLines.map {
            $0.text.range(of: "\r", options: .literal) != nil
        }

        // Tier 1: trailing-whitespace-insensitive.
        let needleRStripped = needleLines.map(rstrip)
        var tier1: [Int] = []
        for start in 0...(fileLines.count - needleLines.count) {
            var matched = true
            for offset in 0..<needleLines.count {
                if lineHasCarriageReturn[start + offset]
                    || rstrip(fileLines[start + offset].text) != needleRStripped[offset] {
                    matched = false
                    break
                }
            }
            if matched { tier1.append(start) }
        }
        if !tier1.isEmpty {
            return (tier1.map { windowRange(start: $0) }, newString)
        }

        // Tier 2: uniform indentation shift.
        let needleTrimmed = needleRStripped.map { stripLeadingWhitespace($0) }
        let needleIndents = needleLines.map { leadingWhitespace(of: $0) }
        var tier2Starts: [Int] = []
        var firstShift: (add: String, remove: String)?
        outer: for start in 0...(fileLines.count - needleLines.count) {
            var shift: (add: String, remove: String)?
            for offset in 0..<needleLines.count {
                if lineHasCarriageReturn[start + offset] { continue outer }
                let fileLine = rstrip(fileLines[start + offset].text)
                guard stripLeadingWhitespace(fileLine) == needleTrimmed[offset] else { continue outer }
                if needleTrimmed[offset].isEmpty { continue } // blank lines don't constrain indent
                let fileIndent = leadingWhitespace(of: fileLine)
                let needleIndent = needleIndents[offset]
                let candidate: (add: String, remove: String)
                if fileIndent.hasSuffix(needleIndent) {
                    candidate = (add: String(fileIndent.dropLast(needleIndent.count)), remove: "")
                } else if needleIndent.hasSuffix(fileIndent) {
                    candidate = (add: "", remove: String(needleIndent.dropFirst(fileIndent.count)))
                } else {
                    continue outer
                }
                if let existing = shift {
                    guard existing == candidate else { continue outer }
                } else {
                    shift = candidate
                }
            }
            tier2Starts.append(start)
            if firstShift == nil { firstShift = shift }
        }
        guard !tier2Starts.isEmpty else { return nil }

        let shift = firstShift ?? (add: "", remove: "")
        let replacement = newString.components(separatedBy: "\n").map { line -> String in
            guard !rstrip(line).isEmpty else { return line }
            if !shift.add.isEmpty { return shift.add + line }
            if !shift.remove.isEmpty, line.hasPrefix(shift.remove) {
                return String(line.dropFirst(shift.remove.count))
            }
            return line
        }.joined(separator: "\n")

        return (tier2Starts.map { windowRange(start: $0) }, replacement)
    }

    /// Best-effort diagnosis for an old_string that failed both exact and
    /// whitespace-tolerant matching, appended to the error so the model
    /// can self-correct instead of blind-retrying.
    static func notFoundHint(oldContent: String, oldString: String) -> String? {
        if oldContent.range(of: "\r\n", options: .literal) != nil {
            return "the file uses CRLF (\\r\\n) line endings, which edit_file cannot patch. Normalize the file to LF first (e.g. run_command with `perl -pi -e 's/\\r\\n/\\n/'`) and retry."
        }

        let needleLines = oldString.components(separatedBy: "\n").filter { !rstrip($0).isEmpty }
        guard !needleLines.isEmpty else { return nil }

        // read_file prefixes every line with a right-aligned line number —
        // a mis-stripped prefix is the most common self-inflicted mismatch.
        let prefixed = needleLines.filter {
            $0.range(of: #"^\s*\d+\s\s"#, options: .regularExpression) != nil
        }
        if prefixed.count * 2 >= needleLines.count {
            return "old_string looks like it still contains read_file line-number prefixes. Strip the leading `<number>  ` from every line and retry."
        }

        let firstNeedle = stripLeadingWhitespace(rstrip(needleLines[0]))
        if !firstNeedle.isEmpty {
            var lineNumber = 0
            for line in oldContent.components(separatedBy: "\n") {
                lineNumber += 1
                if stripLeadingWhitespace(rstrip(line)) == firstNeedle {
                    return "the first line of old_string matches file line \(lineNumber), but later lines diverge from the file. Re-read that region and copy it verbatim."
                }
            }
        }
        return nil
    }

    private static func rstrip(_ line: String) -> String {
        var s = Substring(line)
        while let last = s.last, last == " " || last == "\t" || last == "\r" {
            s.removeLast()
        }
        return String(s)
    }

    private static func stripLeadingWhitespace(_ line: String) -> String {
        String(line.drop(while: { $0 == " " || $0 == "\t" }))
    }

    private static func leadingWhitespace(of line: String) -> String {
        String(line.prefix(while: { $0 == " " || $0 == "\t" }))
    }

    /// Build a unified diff whose removed/context lines are copied verbatim
    /// from `oldContent`. Replacements are grouped into hunks; groups whose
    /// context regions would overlap are merged into one hunk.
    private static func makeUnifiedDiff(
        path: String,
        oldContent: String,
        replacedRanges: [Range<String.Index>],
        replacement: String
    ) -> String {
        let oldLines = oldContent.components(separatedBy: "\n")

        // Start index of each line; lineStarts.count == oldLines.count.
        // Scan with range(of:, options: .literal), not firstIndex(of:
        // Character): in CRLF content "\r\n" is one Character that never
        // equals "\n" (and non-literal search applies canonical equivalence,
        // which also refuses to find "\n" inside "\r\n"), which would leave
        // every line mapped to line 0.
        var lineStarts: [String.Index] = [oldContent.startIndex]
        var scan = oldContent.startIndex
        while let newline = oldContent.range(of: "\n", options: .literal, range: scan..<oldContent.endIndex) {
            lineStarts.append(newline.upperBound)
            scan = newline.upperBound
        }

        func lineIndex(containing index: String.Index) -> Int {
            var low = 0
            var high = lineStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lineStarts[mid] <= index {
                    low = mid
                } else {
                    high = mid - 1
                }
            }
            return low
        }

        struct Span {
            var startLine: Int
            var endLine: Int
            var ranges: [Range<String.Index>]
        }

        // Greatest line whose start is strictly before `index` — the line
        // holding a non-empty range's last character, computed without
        // index(before:), which is unsafe when upperBound sits between the
        // scalars of a CRLF "\r\n" grapheme.
        func lineIndex(endingBefore index: String.Index) -> Int {
            var low = 0
            var high = lineStarts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lineStarts[mid] < index {
                    low = mid
                } else {
                    high = mid - 1
                }
            }
            return low
        }

        var spans: [Span] = []
        for range in replacedRanges {
            let startLine = lineIndex(containing: range.lowerBound)
            // Ranges are non-empty (oldString is non-empty).
            let endLine = lineIndex(endingBefore: range.upperBound)
            if var last = spans.last, startLine <= last.endLine + 1 + contextLineCount * 2 {
                last.endLine = max(last.endLine, endLine)
                last.ranges.append(range)
                spans[spans.count - 1] = last
            } else {
                spans.append(Span(startLine: startLine, endLine: endLine, ranges: [range]))
            }
        }

        // A span covers whole lines INCLUDING the trailing "\n" of its last
        // line — old_string may legitimately consume that terminator (whole-
        // line deletion "line\n" → ""), so the span's char range must reach
        // past every replaced range.
        func spanCharEnd(afterLine endLine: Int) -> String.Index {
            endLine + 1 < lineStarts.count ? lineStarts[endLine + 1] : oldContent.endIndex
        }
        func buildNewSpan(_ span: Span) -> String {
            let end = spanCharEnd(afterLine: span.endLine)
            var text = ""
            var cursor = lineStarts[span.startLine]
            for range in span.ranges {
                text += oldContent[cursor..<range.lowerBound]
                text += replacement
                cursor = range.upperBound
            }
            text += oldContent[cursor..<end]
            return text
        }

        var hunks: [String] = []
        var lineDelta = 0
        for var span in spans {
            var newSpan = buildNewSpan(span)

            // The replacement consumed the span's final line terminator but
            // does not end with a newline itself: the remainder of the edit
            // merges into the FOLLOWING line, so pull that line into the
            // span. (A fully empty newSpan is a clean whole-line deletion —
            // the boundary stays intact, no extension needed.)
            let consumedTerminator = span.ranges.last?.upperBound == spanCharEnd(afterLine: span.endLine)
            if consumedTerminator,
               !newSpan.isEmpty,
               !newSpan.hasSuffix("\n"),
               span.endLine + 1 < lineStarts.count {
                span.endLine += 1
                newSpan = buildNewSpan(span)
            }

            let removedLines = Array(oldLines[span.startLine...span.endLine])
            let addedLines: [String]
            if newSpan.isEmpty {
                addedLines = []
            } else if newSpan.hasSuffix("\n") {
                addedLines = Array(newSpan.components(separatedBy: "\n").dropLast())
            } else {
                addedLines = newSpan.components(separatedBy: "\n")
            }

            let contextStart = max(0, span.startLine - contextLineCount)
            let contextBefore = Array(oldLines[contextStart..<span.startLine])
            let afterStart = span.endLine + 1
            let afterEnd = min(oldLines.count, afterStart + contextLineCount)
            let contextAfter = afterStart < afterEnd ? Array(oldLines[afterStart..<afterEnd]) : []

            let oldCount = contextBefore.count + removedLines.count + contextAfter.count
            let newCount = contextBefore.count + addedLines.count + contextAfter.count
            let oldStart = contextStart + 1
            let newStart = contextStart + 1 + lineDelta
            lineDelta += addedLines.count - removedLines.count

            var body: [String] = ["@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"]
            body += contextBefore.map { " \($0)" }
            body += removedLines.map { "-\($0)" }
            body += addedLines.map { "+\($0)" }
            body += contextAfter.map { " \($0)" }
            hunks.append(body.joined(separator: "\n"))
        }

        return (["--- a/\(path)", "+++ b/\(path)"] + hunks).joined(separator: "\n")
    }
}
