//
//  AppStateEditorTextUtilities.swift
//  WillDeep
//
//  Extracted from AppState.swift in v1.52.1-rc42 (stage-3 code-health
//  pass). Pure nonisolated text-processing helpers used by the editor:
//
//    - findRanges / replacingRanges (find-bar engine)
//    - changedLineNumbers (gutter / change-bar)
//    - contentForSave / trimTrailingWhitespace (save pipeline)
//    - duplicateLine / moveLine (editor commands)
//    - textFileURLs / quickOpenFileURLs (file-listing helpers)
//
//  No instance state, no MainActor isolation — moved here purely to
//  let AppState.swift drop under the CLAUDE.md §10 size budget.
//

import AppKit
import Foundation

extension AppState {
    nonisolated private static let maxTextFileTraversalNodes = 50_000
    nonisolated private static let maxTextFilesForFolderOperations = 4_000

    nonisolated static func findRanges(in text: String, query: String) -> [NSRange] {
        guard !query.isEmpty, !text.isEmpty else { return [] }

        let nsText = text as NSString
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: nsText.length)

        while searchRange.length > 0 {
            let found = nsText.range(
                of: query,
                options: [.caseInsensitive],
                range: searchRange
            )
            guard found.location != NSNotFound, found.length > 0 else {
                break
            }

            ranges.append(found)
            let nextLocation = found.location + found.length
            searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
        }

        return ranges
    }

    nonisolated static func replacingRanges(_ ranges: [NSRange], in text: String, with replacement: String) -> String {
        let mutable = NSMutableString(string: text)
        for range in ranges.reversed() {
            mutable.replaceCharacters(in: range, with: replacement)
        }
        return mutable as String
    }

    nonisolated static func changedLineNumbers(current: String, saved: String) -> Set<Int> {
        let currentLines = current.components(separatedBy: .newlines)
        let savedLines = saved.components(separatedBy: .newlines)
        let maxCount = max(currentLines.count, savedLines.count)
        guard maxCount > 0 else { return [] }

        var changed: Set<Int> = []
        for index in 0..<maxCount {
            let currentLine = index < currentLines.count ? currentLines[index] : ""
            let savedLine = index < savedLines.count ? savedLines[index] : ""
            if currentLine != savedLine {
                changed.insert(index + 1)
            }
        }
        return changed
    }

    nonisolated static func contentForSave(_ content: String, settings: EditorSettings) -> String {
        var result = content
        if settings.trimsTrailingWhitespaceOnSave {
            result = trimTrailingWhitespace(in: result)
        }
        if settings.ensuresFinalNewlineOnSave, !result.isEmpty, !result.hasSuffix("\n") {
            result += "\n"
        }
        return result
    }

    nonisolated static func trimTrailingWhitespace(in content: String) -> String {
        let endsWithNewline = content.hasSuffix("\n")
        var lines = content.components(separatedBy: "\n")
        if endsWithNewline {
            lines.removeLast()
        }

        let trimmed = lines
            .map { line in
                String(line.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
            }
            .joined(separator: "\n")
        return endsWithNewline ? "\(trimmed)\n" : trimmed
    }

    nonisolated static func duplicateLine(at line: Int, in content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard !lines.isEmpty else { return content }
        let index = min(max(0, line - 1), lines.count - 1)
        lines.insert(lines[index], at: index + 1)
        return lines.joined(separator: "\n")
    }

    nonisolated static func moveLine(at line: Int, direction: Int, in content: String) -> (text: String, line: Int) {
        var lines = content.components(separatedBy: "\n")
        guard lines.count > 1 else { return (content, line) }

        let index = min(max(0, line - 1), lines.count - 1)
        let target = index + direction
        guard target >= 0, target < lines.count else {
            return (content, line)
        }

        lines.swapAt(index, target)
        return (lines.joined(separator: "\n"), target + 1)
    }

    nonisolated static func textFileURLs(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var urls: [URL] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > maxTextFileTraversalNodes { break }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]) else {
                continue
            }
            if values.isDirectory == true {
                if ProjectDirectoryExclusions.shouldSkip(url) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            if shouldRequireLargeFileConfirmation(at: url) || isBinaryFile(at: url) {
                continue
            }
            urls.append(url)
            if urls.count >= maxTextFilesForFolderOperations { break }
        }
        return urls
    }

    nonisolated static let quickOpenFileLimit = 1_500

    nonisolated static func quickOpenFileURLs(in folder: URL, limit: Int = quickOpenFileLimit) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var urls: [URL] = []
        let candidateLimit = max(limit * 4, limit)
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > ProjectFileListCache.maxTraversalNodes { break }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
                continue
            }
            if values.isDirectory == true {
                if ProjectDirectoryExclusions.shouldSkip(url) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }

            urls.append(url)
            if urls.count >= candidateLimit { break }
        }

        return urls
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }
}
