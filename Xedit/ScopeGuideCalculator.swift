//
//  ScopeGuideCalculator.swift
//  WillDeep
//
//  Lightweight block extraction for editor folding.
//

import Foundation

struct ScopeGuide: Equatable, Hashable, Sendable {
    let startLine: Int
    let endLine: Int
    let column: Int
    let depth: Int

    nonisolated static func == (lhs: ScopeGuide, rhs: ScopeGuide) -> Bool {
        lhs.startLine == rhs.startLine
            && lhs.endLine == rhs.endLine
            && lhs.column == rhs.column
            && lhs.depth == rhs.depth
    }
}

nonisolated enum EditorLanguageServiceFoldingStatus: Equatable {
    case unavailable
    case loading(uri: String)
    case available(uri: String)
    case failed(uri: String)
}

enum ScopeGuideCalculator {
    nonisolated static func guides(in source: String, language: Language?) -> [ScopeGuide] {
        guard let language, !source.isEmpty else { return [] }

        switch language {
        case .python, .yaml:
            return indentationGuides(in: source, language: language)
        case .ruby, .lua, .elixir:
            return explicitEndGuides(
                in: source,
                openers: language == .ruby ? rubyOpeners : endDelimitedOpeners,
                closers: ["end"],
                lineCommentPrefixes: language == .lua ? ["--"] : ["#"]
            )
        case .shell:
            return shellGuides(in: source)
        case .makefile:
            return explicitEndGuides(
                in: source,
                openers: ["define", "ifeq", "ifneq", "ifdef", "ifndef"],
                closers: ["endef", "endif"],
                lineCommentPrefixes: ["#"]
            )
        case .sql:
            return explicitEndGuides(
                in: source,
                openers: ["case", "begin"],
                closers: ["end"],
                lineCommentPrefixes: ["--"]
            )
        case .html, .xml:
            return markupGuides(in: source)
        case .markdown:
            return markdownGuides(in: source)
        case .toml, .ini, .terraform, .nix:
            return sectionGuides(in: source)
        case .env, .dockerfile, .diff, .nginx, .apache, .assembly:
            return []
        default:
            return braceGuides(in: source, language: language)
        }
    }

    nonisolated static func guideContaining(line: Int, in guides: [ScopeGuide]) -> ScopeGuide? {
        guides
            .filter { $0.startLine <= line && line <= $0.endLine }
            .sorted { lhs, rhs in
                if lhs.depth == rhs.depth {
                    return (lhs.endLine - lhs.startLine) < (rhs.endLine - rhs.startLine)
                }
                return lhs.depth > rhs.depth
            }
            .first
    }

    private nonisolated static let rubyOpeners: Set<String> = [
        "begin", "case", "class", "def", "do", "for", "if", "module", "unless", "until", "while"
    ]

    private nonisolated static let endDelimitedOpeners: Set<String> = [
        "case", "class", "def", "defmodule", "defp", "do", "for", "function", "if", "unless", "while"
    ]

    private struct Line {
        let number: Int
        let text: String
        let trimmed: String
        let indent: Int
    }

    private struct StackItem {
        let token: String
        let line: Int
        let column: Int
        let depth: Int
        let indent: Int
    }

    private nonisolated static func makeLines(_ source: String) -> [Line] {
        source.components(separatedBy: "\n").enumerated().map { index, text in
            Line(
                number: index + 1,
                text: text,
                trimmed: text.trimmingCharacters(in: .whitespaces),
                indent: leadingColumnCount(in: text)
            )
        }
    }

    private nonisolated static func indentationGuides(in source: String, language: Language) -> [ScopeGuide] {
        let lines = makeLines(source)
        let openers = language == .python
            ? ["async def", "async for", "async with", "class", "def", "elif", "else", "except", "finally", "for", "if", "try", "while", "with"]
            : []
        var stack: [StackItem] = []
        var guides: [ScopeGuide] = []
        var lastMeaningfulLine = 1

        for line in lines {
            guard line.trimmed.isEmpty == false, line.trimmed.hasPrefix("#") == false else {
                continue
            }

            while let current = stack.last, line.indent <= current.indent, line.number > current.line {
                stack.removeLast()
                appendGuide(start: current.line, end: max(current.line, lastMeaningfulLine), column: current.column, depth: current.depth, to: &guides)
            }

            if language == .yaml {
                if line.trimmed.hasSuffix(":") {
                    stack.append(StackItem(token: ":", line: line.number, column: line.indent, depth: stack.count, indent: line.indent))
                }
            } else if line.trimmed.hasSuffix(":"),
                      openers.contains(where: { startsWithKeyword($0, in: line.trimmed) }) {
                stack.append(StackItem(token: ":", line: line.number, column: line.indent, depth: stack.count, indent: line.indent))
            }

            lastMeaningfulLine = line.number
        }

        while let current = stack.popLast() {
            appendGuide(start: current.line, end: max(current.line, lastMeaningfulLine), column: current.column, depth: current.depth, to: &guides)
        }

        return guides.sorted(by: sortGuides)
    }

    private nonisolated static func explicitEndGuides(
        in source: String,
        openers: Set<String>,
        closers: Set<String>,
        lineCommentPrefixes: [String]
    ) -> [ScopeGuide] {
        var stack: [StackItem] = []
        var guides: [ScopeGuide] = []

        for line in makeLines(source) {
            let sanitized = sanitizeLine(line.text, lineCommentPrefixes: lineCommentPrefixes)
            let tokens = wordTokens(in: sanitized)
            guard tokens.isEmpty == false else { continue }

            for token in tokens {
                let value = token.value.lowercased()
                if closers.contains(value), let current = stack.popLast() {
                    appendGuide(start: current.line, end: line.number, column: current.column, depth: current.depth, to: &guides)
                    continue
                }

                if openers.contains(value), shouldOpenExplicitBlock(token: value, in: sanitized) {
                    let column = token.column >= 0 ? token.column : line.indent
                    stack.append(StackItem(token: value, line: line.number, column: column, depth: stack.count, indent: line.indent))
                }
            }
        }

        return guides.sorted(by: sortGuides)
    }

    private nonisolated static func shellGuides(in source: String) -> [ScopeGuide] {
        let openers: Set<String> = ["case", "do", "function", "if", "select", "until", "while"]
        let closers: Set<String> = ["done", "esac", "fi"]
        return explicitEndGuides(in: source, openers: openers, closers: closers, lineCommentPrefixes: ["#"])
    }

    private nonisolated static func braceGuides(in source: String, language: Language) -> [ScopeGuide] {
        let lines = makeLines(source)
        var stack: [StackItem] = []
        var guides: [ScopeGuide] = []
        var inBlockComment = false

        for line in lines {
            let text = removeStringsAndComments(from: line.text, language: language, inBlockComment: &inBlockComment)
            for (column, character) in text.enumerated() {
                if character == "{" {
                    stack.append(StackItem(token: "{", line: line.number, column: column, depth: stack.count, indent: line.indent))
                } else if character == "}", let current = stack.popLast() {
                    appendGuide(start: current.line, end: line.number, column: current.column, depth: current.depth, to: &guides)
                }
            }
        }

        return guides.sorted(by: sortGuides)
    }

    private nonisolated static func markupGuides(in source: String) -> [ScopeGuide] {
        let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
        let pattern = #"</?([A-Za-z_][A-Za-z0-9_.:-]*)(?:\s+[^>]*)?>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var stack: [StackItem] = []
        var guides: [ScopeGuide] = []
        let nsSource = source as NSString
        let lines = makeLines(source)

        for line in lines {
            let range = NSRange(location: lineStartOffset(for: line.number, in: lines), length: (line.text as NSString).length)
            for match in regex.matches(in: source, range: range) {
                let full = nsSource.substring(with: match.range)
                let tag = nsSource.substring(with: match.range(at: 1)).lowercased()
                guard voidTags.contains(tag) == false, full.hasPrefix("<?") == false, full.hasPrefix("<!") == false else { continue }

                if full.hasPrefix("</") {
                    if let index = stack.lastIndex(where: { $0.token == tag }) {
                        let current = stack.remove(at: index)
                        appendGuide(start: current.line, end: line.number, column: current.column, depth: current.depth, to: &guides)
                    }
                } else if full.hasSuffix("/>") == false {
                    let localColumn = max(0, match.range.location - range.location)
                    stack.append(StackItem(token: tag, line: line.number, column: localColumn, depth: stack.count, indent: line.indent))
                }
            }
        }

        return guides.sorted(by: sortGuides)
    }

    private nonisolated static func markdownGuides(in source: String) -> [ScopeGuide] {
        let lines = makeLines(source)
        var stack: [StackItem] = []
        var guides: [ScopeGuide] = []
        var lastMeaningfulLine = 1

        for line in lines {
            guard line.trimmed.isEmpty == false else { continue }
            if let level = markdownHeadingLevel(line.trimmed) {
                while let current = stack.last, current.indent >= level {
                    stack.removeLast()
                    appendGuide(start: current.line, end: max(current.line, lastMeaningfulLine), column: 0, depth: current.depth, to: &guides)
                }
                stack.append(StackItem(token: "#", line: line.number, column: 0, depth: stack.count, indent: level))
            }
            lastMeaningfulLine = line.number
        }

        while let current = stack.popLast() {
            appendGuide(start: current.line, end: max(current.line, lastMeaningfulLine), column: 0, depth: current.depth, to: &guides)
        }

        return guides.sorted(by: sortGuides)
    }

    private nonisolated static func sectionGuides(in source: String) -> [ScopeGuide] {
        let lines = makeLines(source)
        var starts: [Line] = []
        for line in lines where line.trimmed.hasPrefix("[") && line.trimmed.contains("]") {
            starts.append(line)
        }

        guard starts.count > 1 || starts.first != nil else { return [] }
        let lastLine = lines.last(where: { $0.trimmed.isEmpty == false })?.number ?? 1
        return starts.enumerated().compactMap { index, line in
            let end = index + 1 < starts.count ? starts[index + 1].number - 1 : lastLine
            guard end > line.number else { return nil }
            return ScopeGuide(startLine: line.number, endLine: end, column: line.indent, depth: 0)
        }
    }

    private nonisolated static func appendGuide(start: Int, end: Int, column: Int, depth: Int, to guides: inout [ScopeGuide]) {
        guard end > start else { return }
        guides.append(ScopeGuide(startLine: start, endLine: end, column: max(0, column), depth: max(0, depth)))
    }

    private nonisolated static func sortGuides(_ lhs: ScopeGuide, _ rhs: ScopeGuide) -> Bool {
        if lhs.startLine == rhs.startLine {
            return lhs.depth < rhs.depth
        }
        return lhs.startLine < rhs.startLine
    }

    private nonisolated static func leadingColumnCount(in text: String) -> Int {
        var count = 0
        for character in text {
            if character == " " {
                count += 1
            } else if character == "\t" {
                count += 4
            } else {
                break
            }
        }
        return count
    }

    private nonisolated static func startsWithKeyword(_ keyword: String, in text: String) -> Bool {
        if keyword.contains(" ") {
            return text.lowercased().hasPrefix(keyword)
        }
        guard text.lowercased().hasPrefix(keyword) else { return false }
        let endIndex = text.index(text.startIndex, offsetBy: keyword.count)
        return endIndex == text.endIndex || text[endIndex].isLetter == false
    }

    private nonisolated static func shouldOpenExplicitBlock(token: String, in line: String) -> Bool {
        if token == "do" {
            return line.range(of: #"\bdo\b"#, options: .regularExpression) != nil
        }
        return true
    }

    private nonisolated static func sanitizeLine(_ text: String, lineCommentPrefixes: [String]) -> String {
        var output = ""
        var quote: Character?
        var escaped = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                output.append(" ")
                index = text.index(after: index)
                continue
            }

            if character == "\"" || character == "'" || character == "`" {
                quote = character
                output.append(" ")
                index = text.index(after: index)
                continue
            }

            if lineCommentPrefixes.contains(where: { text[index...].hasPrefix($0) }) {
                break
            }

            output.append(character)
            index = text.index(after: index)
        }

        return output
    }

    private nonisolated static func wordTokens(in text: String) -> [(value: String, column: Int)] {
        let nsText = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_?]*"#) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map { match in
            (nsText.substring(with: match.range), match.range.location)
        }
    }

    private nonisolated static func removeStringsAndComments(from text: String, language: Language, inBlockComment: inout Bool) -> String {
        var output = ""
        var quote: Character?
        var escaped = false
        var index = text.startIndex
        let supportsLineComment = language != .css && language != .json

        while index < text.endIndex {
            if inBlockComment {
                if text[index...].hasPrefix("*/") {
                    inBlockComment = false
                    output.append("  ")
                    index = text.index(index, offsetBy: 2)
                } else {
                    output.append(" ")
                    index = text.index(after: index)
                }
                continue
            }

            let character = text[index]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                output.append(" ")
                index = text.index(after: index)
                continue
            }

            if text[index...].hasPrefix("/*") {
                inBlockComment = true
                output.append("  ")
                index = text.index(index, offsetBy: 2)
                continue
            }

            if supportsLineComment, text[index...].hasPrefix("//") {
                output.append(String(repeating: " ", count: text.distance(from: index, to: text.endIndex)))
                break
            }

            if character == "\"" || character == "'" || character == "`" {
                quote = character
                output.append(" ")
                index = text.index(after: index)
                continue
            }

            output.append(character)
            index = text.index(after: index)
        }

        return output
    }

    private nonisolated static func lineStartOffset(for lineNumber: Int, in lines: [Line]) -> Int {
        guard lineNumber > 1 else { return 0 }
        return lines.prefix(lineNumber - 1).reduce(0) { partial, line in
            partial + (line.text as NSString).length + 1
        }
    }

    private nonisolated static func markdownHeadingLevel(_ text: String) -> Int? {
        guard text.hasPrefix("#") else { return nil }
        let level = text.prefix { $0 == "#" }.count
        guard (1...6).contains(level), text.dropFirst(level).first == " " else { return nil }
        return level
    }
}
