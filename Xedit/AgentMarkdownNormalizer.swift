//
//  AgentMarkdownNormalizer.swift
//  WillDeep
//
//  Pre-pass for raw model output before it reaches MarkdownPreviewParser.
//  It preserves a small set of HTML block elements by fencing them as html
//  and coalesces hr-style divider lines into a stable markdown divider.
//  A standalone `</abs/path.png>` line — the angle-bracket half of
//  `![](</path with spaces.png>)` that models sometimes write on its own —
//  becomes that image line, so local images, audio and video render inline
//  instead of showing the raw path.
//

import Foundation
import UniformTypeIdentifiers

enum AgentMarkdownNormalizer {
    // Bounded LRU keyed by source hash. During streaming this function is
    // called on every SwiftUI body evaluation of the live bubble (≥ once per
    // 100ms flush, plus extra layout/measure passes). Without a cache each of
    // those passes re-scans the whole growing string — O(n) per pass, O(n²)
    // across the stream. Repeated passes at the *same* content now hand back
    // the prior result; only a genuinely new content value pays the scan.
    private static var cache: [Int: String] = [:]
    private static var cacheOrder: [Int] = []
    private static let cacheLock = NSLock()
    private static let cacheLimit = 128

    static func normalizedForChatRendering(_ source: String) -> String {
        let key = source.hashValue
        cacheLock.lock()
        let hit = cache[key]
        cacheLock.unlock()
        if let hit { return hit }

        let result = computeNormalized(source)

        cacheLock.lock()
        cache[key] = result
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit {
            let evict = cacheOrder.removeFirst()
            cache.removeValue(forKey: evict)
        }
        cacheLock.unlock()
        return result
    }

    private static func computeNormalized(_ source: String) -> String {
        // Providers commonly frame short messages as `\n\ntext\n\n`. Those
        // transport-level outer blank lines used to stack with transcript and
        // Markdown paragraph spacing, producing conspicuous empty bands.
        // Preserve all whitespace inside the body while trimming only its
        // outer edge at the rendering boundary.
        let displaySource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = displaySource.components(separatedBy: .newlines)
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

            if !isInFence, let mediaLine = standaloneAngleBracketMediaLine(trimmed) {
                let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
                output.append(indent + mediaLine)
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

    /// `</Users/me/Application Support/a.png>` → `![](</Users/me/Application Support/a.png>)`.
    /// Only a whole line, only an absolute local path (`/`, `~/`, `file://`),
    /// and only when the extension is an image or transcript media, so an
    /// ordinary `<https://…>` autolink or an HTML tag is never touched.
    static func standaloneAngleBracketMediaLine(_ trimmed: String) -> String? {
        guard trimmed.count > 2, trimmed.hasPrefix("<"), trimmed.hasSuffix(">") else { return nil }
        let inner = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty,
              !inner.contains(where: { $0 == "<" || $0 == ">" || $0.isNewline }),
              inner.hasPrefix("/") || inner.hasPrefix("~/") || inner.lowercased().hasPrefix("file://") else {
            return nil
        }
        guard isImageSource(inner) || AgentTranscriptMediaFormat.kind(forSource: inner) != nil else {
            return nil
        }
        return "![](<\(inner)>)"
    }

    private static func isImageSource(_ source: String) -> Bool {
        let ext = AgentTranscriptMediaFormat.pathExtension(ofSource: source)
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
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
