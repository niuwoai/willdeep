//
//  AgentMarkdownNormalizer.swift
//  WillDeep
//
//  Pre-pass for raw model output before it reaches MarkdownPreviewParser.
//  It preserves a small set of HTML block elements by fencing them as html
//  and coalesces hr-style divider lines into a stable markdown divider.
//

import Foundation

enum AgentMarkdownNormalizer {
    static func normalizedForChatRendering(_ source: String) -> String {
        let lines = source.components(separatedBy: .newlines)
        var output: [String] = []
        var index = 0
        var isInFence = false

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                isInFence.toggle()
                output.append(line)
                index += 1
                continue
            }

            if !isInFence, isDividerLine(trimmed) {
                output.append("---")
                index += 1
                continue
            }

            if !isInFence, let endMarker = htmlBlockEndMarker(for: trimmed) {
                output.append("```html")
                output.append(line)
                index += 1
                while index < lines.count {
                    let next = lines[index]
                    output.append(next)
                    if next.range(of: endMarker, options: [.caseInsensitive]) != nil {
                        index += 1
                        break
                    }
                    index += 1
                }
                output.append("```")
                continue
            }

            output.append(line)
            index += 1
        }

        return output.joined(separator: "\n")
    }

    private static func isDividerLine(_ line: String) -> Bool {
        let collapsed = line.replacingOccurrences(of: " ", with: "")
        guard collapsed.count >= 3, let first = collapsed.first, "-_*".contains(first) else {
            return false
        }
        return collapsed.allSatisfy { $0 == first }
    }

    private static func htmlBlockEndMarker(for line: String) -> String? {
        let lower = line.lowercased()
        let pairs: [(String, String)] = [
            ("<details", "</details>"),
            ("<summary", "</summary>"),
            ("<pre", "</pre>"),
            ("<table", "</table>"),
            ("<div", "</div>"),
            ("<section", "</section>"),
            ("<article", "</article>"),
        ]
        for (prefix, suffix) in pairs where lower.hasPrefix(prefix) {
            return suffix
        }
        return nil
    }
}
