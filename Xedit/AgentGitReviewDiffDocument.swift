//
//  AgentGitReviewDiffDocument.swift
//  WillDeep
//
//  Parses a bounded unified diff into file-first review rows. The parser
//  intentionally drops Git transport metadata and preserves only the
//  information needed by the Codex-style review surface.
//

import Foundation

nonisolated struct AgentGitReviewDiffDocument {
    let files: [AgentGitReviewDiffFile]

    static func parse(
        _ diff: String,
        changes: AgentWorktreeChangeSummary
    ) -> AgentGitReviewDiffDocument {
        let sections = splitFileSections(diff)
        let files = sections.compactMap { section -> AgentGitReviewDiffFile? in
            guard let path = filePath(in: section),
                  let change = changes.change(for: path) else {
                return nil
            }
            return AgentGitReviewDiffFile(
                path: path,
                change: change,
                rows: parseRows(in: section)
            )
        }
        return AgentGitReviewDiffDocument(files: files)
    }

    private static func splitFileSections(_ diff: String) -> [[String]] {
        var sections: [[String]] = []
        var current: [String] = []

        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") {
                if !current.isEmpty {
                    sections.append(current)
                }
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        if !current.isEmpty {
            sections.append(current)
        }
        return sections
    }

    private static func filePath(in lines: [String]) -> String? {
        if let destination = lines.first(where: { $0.hasPrefix("+++ ") }) {
            let rawPath = String(destination.dropFirst(4))
            if rawPath != "/dev/null" {
                return normalizedPath(rawPath)
            }
        }
        if let source = lines.first(where: { $0.hasPrefix("--- ") }) {
            let rawPath = String(source.dropFirst(4))
            if rawPath != "/dev/null" {
                return normalizedPath(rawPath)
            }
        }
        return nil
    }

    private static func normalizedPath(_ rawPath: String) -> String {
        let unquoted = AppState.unquoteGitPath(rawPath)
        if unquoted.hasPrefix("a/") || unquoted.hasPrefix("b/") {
            return String(unquoted.dropFirst(2))
        }
        return unquoted
    }

    private static func parseRows(in lines: [String]) -> [AgentGitReviewDiffRow] {
        var rows: [AgentGitReviewDiffRow] = []
        var oldLine = 1
        var newLine = 1
        var isInsideHunk = false

        for line in lines {
            if let hunk = parseHunkHeader(line) {
                let hiddenCount = max(hunk.oldStart - oldLine, hunk.newStart - newLine)
                if hiddenCount > 0 {
                    rows.append(.collapsed(count: hiddenCount))
                }
                oldLine = hunk.oldStart
                newLine = hunk.newStart
                isInsideHunk = true
                continue
            }

            guard isInsideHunk else { continue }
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                rows.append(.addition(newLine: newLine, text: String(line.dropFirst())))
                newLine += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                rows.append(.deletion(oldLine: oldLine, text: String(line.dropFirst())))
                oldLine += 1
            } else if line.hasPrefix(" ") {
                rows.append(.context(oldLine: oldLine, newLine: newLine, text: String(line.dropFirst())))
                oldLine += 1
                newLine += 1
            } else if line.hasPrefix("\\") {
                rows.append(.meta(text: line))
            }
        }
        return rows
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
        guard line.hasPrefix("@@ "),
              let oldToken = line.split(separator: " ").first(where: { $0.hasPrefix("-") }),
              let newToken = line.split(separator: " ").first(where: { $0.hasPrefix("+") }),
              let oldStart = lineStart(in: oldToken),
              let newStart = lineStart(in: newToken) else {
            return nil
        }
        return (oldStart, newStart)
    }

    private static func lineStart(in token: Substring) -> Int? {
        let range = token.dropFirst().split(separator: ",", maxSplits: 1)
        return range.first.flatMap { Int($0) }
    }
}

nonisolated struct AgentGitReviewDiffFile: Identifiable {
    let path: String
    let change: AgentFileChangeSummary
    let rows: [AgentGitReviewDiffRow]

    var id: String { path }
}

nonisolated enum AgentGitReviewDiffRow: Equatable {
    case collapsed(count: Int)
    case context(oldLine: Int, newLine: Int, text: String)
    case addition(newLine: Int, text: String)
    case deletion(oldLine: Int, text: String)
    case meta(text: String)
}
