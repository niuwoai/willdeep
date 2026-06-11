//
//  EditorInspector.swift
//  WillDeep
//
//  Created by rocky on 2026/5/27.
//

import Foundation

struct EditorNavigationRequest: Equatable {
    let line: Int
    let revision: Int
}

enum EditorInspectorMode: String, CaseIterable, Codable, Identifiable {
    case minimap
    case structure

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimap:
            return "Minimap"
        case .structure:
            return "Structure"
        }
    }
}

enum EditorInspectorPanelOrder: String, CaseIterable, Codable, Identifiable {
    case minimapFirst
    case structureFirst

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimapFirst:
            return "Minimap First"
        case .structureFirst:
            return "Structure First"
        }
    }

    var modes: [EditorInspectorMode] {
        switch self {
        case .minimapFirst:
            return [.minimap, .structure]
        case .structureFirst:
            return [.structure, .minimap]
        }
    }
}

struct EditorOutlineItem: Identifiable, Equatable {
    enum Kind: String {
        case type
        case function
        case property
        case section
        case key
    }

    let id = UUID()
    let title: String
    let kind: Kind
    let line: Int
    let level: Int
}

enum EditorOutlineExtractor {
    static func outline(for source: String, language: Language?) -> [EditorOutlineItem] {
        guard !source.isEmpty else { return [] }

        switch language {
        case .swift:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*(?:public\\s+|private\\s+|internal\\s+|fileprivate\\s+|open\\s+|final\\s+)*\\b(?:class|struct|enum|protocol|actor|extension)\\s+([A-Za-z_][A-Za-z0-9_]*)", kind: .type),
                OutlineSpec(pattern: "^\\s*(?:public\\s+|private\\s+|internal\\s+|fileprivate\\s+|open\\s+|static\\s+|override\\s+|mutating\\s+)*\\bfunc\\s+([A-Za-z_][A-Za-z0-9_]*)", kind: .function),
                OutlineSpec(pattern: "^\\s*(?:public\\s+|private\\s+|internal\\s+|fileprivate\\s+|open\\s+|static\\s+)*\\b(?:let|var)\\s+([A-Za-z_][A-Za-z0-9_]*)", kind: .property),
            ])
        case .javascript, .typescript:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*(?:export\\s+default\\s+|export\\s+)?class\\s+([A-Za-z_$][A-Za-z0-9_$]*)", kind: .type),
                OutlineSpec(pattern: "^\\s*(?:export\\s+)?interface\\s+([A-Za-z_$][A-Za-z0-9_$]*)", kind: .type),
                OutlineSpec(pattern: "^\\s*(?:export\\s+)?type\\s+([A-Za-z_$][A-Za-z0-9_$]*)", kind: .type),
                OutlineSpec(pattern: "^\\s*(?:export\\s+)?(?:async\\s+)?function\\s+([A-Za-z_$][A-Za-z0-9_$]*)", kind: .function),
                OutlineSpec(pattern: "^\\s*(?:export\\s+)?(?:const|let|var)\\s+([A-Za-z_$][A-Za-z0-9_$]*)\\s*=\\s*(?:async\\s*)?\\(?", kind: .function),
            ])
        case .ruby:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*(?:class|module)\\s+([A-Za-z_][A-Za-z0-9_:]*)", kind: .type),
                OutlineSpec(pattern: "^\\s*def\\s+(?:self\\.)?([A-Za-z_][A-Za-z0-9_!?=]*)", kind: .function),
            ])
        case .php:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*(?:final\\s+|abstract\\s+)?(?:class|interface|trait|enum)\\s+([A-Za-z_][A-Za-z0-9_]*)", kind: .type),
                OutlineSpec(pattern: "^\\s*(?:public\\s+|private\\s+|protected\\s+|static\\s+)*function\\s+([A-Za-z_][A-Za-z0-9_]*)", kind: .function),
            ])
        case .java:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*(?:public\\s+|private\\s+|protected\\s+|abstract\\s+|final\\s+|sealed\\s+)*\\b(?:class|interface|enum|record)\\s+([A-Za-z_][A-Za-z0-9_]*)", kind: .type),
                OutlineSpec(pattern: "^\\s*(?:public\\s+|private\\s+|protected\\s+|static\\s+|final\\s+|synchronized\\s+)*[A-Za-z_][A-Za-z0-9_<>, ?\\[\\]]+\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\(", kind: .function),
            ])
        case .go:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*func\\s+(?:\\([^)]*\\)\\s*)?([A-Za-z_][A-Za-z0-9_]*)", kind: .function),
                OutlineSpec(pattern: "^\\s*type\\s+([A-Za-z_][A-Za-z0-9_]*)\\s+(?:struct|interface)", kind: .type),
            ])
        case .html:
            return htmlOutline(source)
        case .css:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*([^@{}][^{]+)\\s*\\{", kind: .section),
            ])
        case .json:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*\"([^\"]+)\"\\s*:", kind: .key),
            ])
        case .markdown:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^(#{1,6})\\s+(.+)$", kind: .section, levelGroup: 1, titleGroup: 2),
            ])
        case .python:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*class\\s+([A-Za-z_][A-Za-z0-9_]*)", kind: .type),
                OutlineSpec(pattern: "^\\s*(?:async\\s+)?def\\s+([A-Za-z_][A-Za-z0-9_]*)", kind: .function),
            ])
        case .shell:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*(?:function\\s+)?([A-Za-z_][A-Za-z0-9_]*)\\s*\\(\\)\\s*\\{", kind: .function),
            ])
        case .rust:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*(?:pub\\s+)?(?:struct|enum|trait|impl)\\s+([A-Za-z_][A-Za-z0-9_]*)", kind: .type),
                OutlineSpec(pattern: "^\\s*(?:pub\\s+)?(?:async\\s+)?fn\\s+([A-Za-z_][A-Za-z0-9_]*)", kind: .function),
            ])
        case .c, .cpp, .csharp:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*(?:public\\s+|private\\s+|protected\\s+)?(?:class|struct|enum|interface)\\s+([A-Za-z_][A-Za-z0-9_]*)", kind: .type),
                OutlineSpec(pattern: "^\\s*(?:public\\s+|private\\s+|protected\\s+|static\\s+|virtual\\s+|override\\s+)*[A-Za-z_][A-Za-z0-9_<>,:*&?\\[\\] ]+\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\(", kind: .function),
            ])
        case .yaml:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*([A-Za-z0-9_.-]+)\\s*:", kind: .key),
            ])
        case .toml, .ini, .env:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*\\[([^\\]]+)\\]", kind: .section),
                OutlineSpec(pattern: "^\\s*([A-Za-z_][A-Za-z0-9_.-]*)(?=\\s*[=:])", kind: .key),
            ])
        case .xml:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "<([A-Za-z_][A-Za-z0-9_.:-]*)\\b", kind: .section),
            ])
        case .sql:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*(?:create\\s+(?:table|view|index)|alter\\s+table|drop\\s+table)\\s+([A-Za-z_][A-Za-z0-9_.]*)", kind: .section),
            ])
        case .dockerfile:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*(FROM|RUN|CMD|ENTRYPOINT|COPY|ADD|ENV|ARG|WORKDIR|EXPOSE)\\b", kind: .section),
            ])
        case .makefile:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*([A-Za-z0-9_./%-]+)\\s*:(?!=)", kind: .section),
            ])
        case .diff:
            return []
        case .none:
            return []
        }
    }

    private struct OutlineSpec {
        let pattern: String
        let kind: EditorOutlineItem.Kind
        let levelGroup: Int?
        let titleGroup: Int

        init(
            pattern: String,
            kind: EditorOutlineItem.Kind,
            levelGroup: Int? = nil,
            titleGroup: Int = 1
        ) {
            self.pattern = pattern
            self.kind = kind
            self.levelGroup = levelGroup
            self.titleGroup = titleGroup
        }
    }

    private static func regexOutline(
        _ source: String,
        specs: [OutlineSpec],
        stripsHTML: Bool = false
    ) -> [EditorOutlineItem] {
        let lines = source.components(separatedBy: .newlines)
        var items: [EditorOutlineItem] = []

        for (index, line) in lines.enumerated() {
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)

            for spec in specs {
                guard let regex = try? NSRegularExpression(pattern: spec.pattern, options: []) else { continue }
                guard let match = regex.firstMatch(in: line, range: fullRange) else { continue }

                let titleRange = match.range(at: spec.titleGroup)
                guard titleRange.location != NSNotFound else { continue }

                var title = nsLine.substring(with: titleRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if stripsHTML {
                    title = title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                }
                guard !title.isEmpty else { continue }

                let level: Int
                if let levelGroup = spec.levelGroup {
                    let levelValue = nsLine.substring(with: match.range(at: levelGroup))
                    level = max(0, levelValue.count - 1)
                } else {
                    level = indentationLevel(for: line)
                }

                items.append(EditorOutlineItem(title: title, kind: spec.kind, line: index + 1, level: level))
                break
            }
        }

        return items
    }

    private static func indentationLevel(for line: String) -> Int {
        let prefix = line.prefix { $0 == " " || $0 == "\t" }
        let spaces = prefix.reduce(0) { total, character in
            total + (character == "\t" ? 4 : 1)
        }
        return spaces / 4
    }

    private static func htmlOutline(_ source: String) -> [EditorOutlineItem] {
        let targetTags: Set<String> = [
            "title", "h1", "h2", "h3", "h4", "h5",
            "main", "header", "footer", "nav", "section", "article",
            "div", "ul", "ol", "li"
        ]
        let voidTags: Set<String> = [
            "area", "base", "br", "col", "embed", "hr", "img",
            "input", "link", "meta", "param", "source", "track", "wbr"
        ]
        let maxDepth = 4
        let maxItems = 200
        let nsSource = source as NSString
        let sourceRange = NSRange(location: 0, length: nsSource.length)
        let lineStarts = lineStartOffsets(in: source)
        let pattern = #"<\s*(/?)\s*([A-Za-z][A-Za-z0-9:-]*)([^>]*)>"#
        guard let tagRegex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        var stack: [String] = []
        var items: [EditorOutlineItem] = []
        let matches = tagRegex.matches(in: source, range: sourceRange)

        for match in matches {
            guard match.numberOfRanges >= 4 else { continue }
            let closingMarker = nsSource.substring(with: match.range(at: 1))
            let tagName = nsSource.substring(with: match.range(at: 2)).lowercased()
            let attributes = nsSource.substring(with: match.range(at: 3))
            let isClosingTag = !closingMarker.isEmpty
            let isSelfClosing = attributes.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
                || voidTags.contains(tagName)

            if isClosingTag {
                if let index = stack.lastIndex(of: tagName) {
                    stack.removeSubrange(index...)
                }
                continue
            }

            let outlineDepth = stack.filter { !["html", "head", "body"].contains($0) }.count
            if targetTags.contains(tagName), outlineDepth <= maxDepth, let title = htmlOutlineTitle(
                tagName: tagName,
                attributes: attributes,
                source: nsSource,
                tagMatch: match
            ) {
                let line = lineNumber(for: match.range.location, lineStarts: lineStarts)
                let kind: EditorOutlineItem.Kind = tagName == "title" ? .key : .section
                items.append(EditorOutlineItem(title: title, kind: kind, line: line, level: min(outlineDepth, maxDepth)))

                if items.count >= maxItems {
                    return items
                }
            }

            if !isSelfClosing {
                stack.append(tagName)
            }
        }

        return items
    }

    private static func htmlOutlineTitle(
        tagName: String,
        attributes: String,
        source: NSString,
        tagMatch: NSTextCheckingResult
    ) -> String? {
        if let headingLevel = htmlHeadingLevel(tagName), headingLevel <= 5 {
            return htmlInnerText(tagName: tagName, source: source, after: tagMatch.range.upperBound)
                .map { "\(tagName.uppercased()) \($0)" }
        }

        if tagName == "title" {
            return htmlInnerText(tagName: tagName, source: source, after: tagMatch.range.upperBound)
        }

        if let label = htmlAttribute("aria-label", in: attributes) ?? htmlAttribute("title", in: attributes) {
            return "\(tagName) \(label)"
        }

        let id = htmlAttribute("id", in: attributes)
        let className = htmlAttribute("class", in: attributes)?
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .prefix(2)
            .joined(separator: ".")

        if let id, !id.isEmpty {
            return "\(tagName)#\(id)"
        }

        if let className, !className.isEmpty {
            return "\(tagName).\(className)"
        }

        if tagName == "ul" || tagName == "ol" {
            return tagName
        }

        guard tagName == "li" else { return nil }
        return htmlInnerText(tagName: tagName, source: source, after: tagMatch.range.upperBound)
            .map { "\(tagName) \($0)" }
    }

    private static func htmlHeadingLevel(_ tagName: String) -> Int? {
        guard tagName.count == 2, tagName.first == "h", let level = tagName.last?.wholeNumberValue else {
            return nil
        }
        return level
    }

    private static func htmlInnerText(tagName: String, source: NSString, after start: Int) -> String? {
        let remainingLength = source.length - start
        guard remainingLength > 0 else { return nil }

        let closingPattern = "</\\s*\(NSRegularExpression.escapedPattern(for: tagName))\\s*>"
        guard let closingRegex = try? NSRegularExpression(pattern: closingPattern, options: [.caseInsensitive]) else {
            return nil
        }

        let searchRange = NSRange(location: start, length: min(remainingLength, 4_000))
        guard let closing = closingRegex.firstMatch(in: source as String, range: searchRange) else {
            return nil
        }

        let textRange = NSRange(location: start, length: closing.range.location - start)
        guard textRange.length > 0 else { return nil }

        let raw = source.substring(with: textRange)
        let stripped = raw
            .replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return normalizedHTMLText(stripped)
    }

    private static func htmlAttribute(_ name: String, in attributes: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?i)\b\#(escaped)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsAttributes = attributes as NSString
        let range = NSRange(location: 0, length: nsAttributes.length)
        guard let match = regex.firstMatch(in: attributes, range: range) else { return nil }

        for group in 1..<match.numberOfRanges {
            let valueRange = match.range(at: group)
            if valueRange.location != NSNotFound {
                return normalizedHTMLText(nsAttributes.substring(with: valueRange))
            }
        }
        return nil
    }

    private static func normalizedHTMLText(_ text: String) -> String? {
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
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 72 ? "\(collapsed.prefix(69))..." : collapsed
    }

    private static func lineStartOffsets(in source: String) -> [Int] {
        var offsets = [0]
        var currentOffset = 0

        for scalar in source.unicodeScalars {
            currentOffset += String(scalar).utf16.count
            if scalar == "\n" {
                offsets.append(currentOffset)
            }
        }

        return offsets
    }

    private static func lineNumber(for offset: Int, lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count - 1

        while low <= high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= offset {
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return max(1, high + 1)
    }
}
