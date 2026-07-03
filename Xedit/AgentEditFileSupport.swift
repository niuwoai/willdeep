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
    case oldStringNotFound(String)
    case oldStringNotUnique(String, Int)
    case diffRoundTripMismatch(String)

    var errorDescription: String? {
        switch self {
        case .emptyOldString:
            return "old_string must not be empty. Pass the exact text to replace; to create a new file use create_file."
        case .identicalReplacement(let path):
            return "old_string and new_string are identical for \(path). Provide a new_string that differs from old_string."
        case .oldStringNotFound(let path):
            return "old_string was not found in \(path). It must match the current file content EXACTLY, including whitespace and indentation, and must not include read_file line-number prefixes. Re-read the file and copy the text verbatim."
        case .oldStringNotUnique(let path, let count):
            return "old_string matches \(count) locations in \(path). Include more surrounding lines to make it unique, or pass replace_all=true to replace every occurrence."
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

        guard !ranges.isEmpty else { throw AgentEditFileError.oldStringNotFound(path) }
        if ranges.count > 1 && !replaceAll {
            throw AgentEditFileError.oldStringNotUnique(path, ranges.count)
        }
        if !replaceAll {
            ranges = [ranges[0]]
        }

        var newContent = ""
        var cursor = oldContent.startIndex
        for range in ranges {
            newContent += oldContent[cursor..<range.lowerBound]
            newContent += newString
            cursor = range.upperBound
        }
        newContent += oldContent[cursor...]

        let diff = makeUnifiedDiff(
            path: path,
            oldContent: oldContent,
            replacedRanges: ranges,
            replacement: newString
        )

        // The generated diff MUST reproduce `newContent` byte-for-byte through
        // the shared applier — this guards the synthesis logic against parser
        // ambiguities (e.g. content lines that resemble diff headers).
        guard let change = try? AgentPatchApplier.parse(diff).first,
              let applied = try? AgentPatchApplier.apply(change, to: oldContent),
              applied == newContent else {
            throw AgentEditFileError.diffRoundTripMismatch(path)
        }

        return Edit(diff: diff, newContent: newContent, occurrences: ranges.count)
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
        var lineStarts: [String.Index] = [oldContent.startIndex]
        var scan = oldContent.startIndex
        while let newline = oldContent[scan...].firstIndex(of: "\n") {
            let next = oldContent.index(after: newline)
            lineStarts.append(next)
            scan = next
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

        var spans: [Span] = []
        for range in replacedRanges {
            let startLine = lineIndex(containing: range.lowerBound)
            // Ranges are non-empty (oldString is non-empty), so the last
            // character is upperBound - 1.
            let endLine = lineIndex(containing: oldContent.index(before: range.upperBound))
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
