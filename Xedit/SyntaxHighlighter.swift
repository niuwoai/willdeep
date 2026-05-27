//
//  SyntaxHighlighter.swift
//  VeilWriter
//
//  Regex-based multi-language syntax highlighting engine.
//  Produces NSAttributedString with color attributes for
//  keywords, strings, comments, numbers, and type names.
//

import Foundation
import AppKit

// MARK: - Language Enum

enum Language: String, CaseIterable {
    case swift
    case python
    case ruby
    case php
    case java
    case javascript
    case typescript
    case go
    case html
    case css
    case json
    case markdown
    case shell

    /// Maps a file extension (including the dot) to a language.
    /// Returns `nil` if the extension is not recognized.
    static func fromExtension(_ ext: String) -> Language? {
        let lower = ext.lowercased()
        switch lower {
        case ".swift":  return .swift
        case ".py":     return .python
        case ".rb", ".rake", ".gemspec": return .ruby
        case ".php", ".phtml", ".php3", ".php4", ".php5": return .php
        case ".java":   return .java
        case ".js", ".mjs", ".cjs", ".jsx": return .javascript
        case ".ts", ".mts", ".cts", ".tsx": return .typescript
        case ".go":     return .go
        case ".html", ".htm", ".xhtml": return .html
        case ".css", ".scss", ".sass", ".less": return .css
        case ".json", ".jsonc", ".jsonl": return .json
        case ".md", ".markdown": return .markdown
        case ".sh", ".bash", ".zsh": return .shell
        default:        return nil
        }
    }

    /// Convenience: detect language from a file URL.
    static func fromURL(_ url: URL) -> Language? {
        fromExtension(url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)")
    }
}

// MARK: - Highlight Rule

/// A single regex-based highlighting rule.
struct HighlightRule {
    let pattern: String
    let attributes: [NSAttributedString.Key: Any]
}

// MARK: - Syntax Highlighter

enum SyntaxHighlighter {

    // MARK: Language Definitions

    private static func keywordPattern(for keywords: [String]) -> String {
        "\\b(?:"
            + keywords.sorted(by: { $0.count > $1.count })
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
            + ")\\b"
    }

    /// Returns the ordered list of highlight rules for a given language.
    /// Rules are applied in order; earlier matches take precedence.
    static func rules(for language: Language, theme: EditorTheme, font: NSFont) -> [HighlightRule] {
        switch language {
        case .swift:       return swiftRules(theme: theme)
        case .python:      return pythonRules(theme: theme)
        case .ruby:        return rubyRules(theme: theme)
        case .php:         return phpRules(theme: theme)
        case .java:        return javaRules(theme: theme)
        case .javascript:  return javascriptRules(theme: theme)
        case .typescript:  return typescriptRules(theme: theme)
        case .go:          return goRules(theme: theme)
        case .html:        return htmlRules(theme: theme)
        case .css:         return cssRules(theme: theme)
        case .json:        return jsonRules(theme: theme)
        case .markdown:    return markdownRules(theme: theme, font: font)
        case .shell:       return shellRules(theme: theme)
        }
    }

    // MARK: - Swift Rules

    private static func swiftRules(theme: EditorTheme) -> [HighlightRule] {
        let keywords = [
            "class", "struct", "enum", "protocol", "extension",
            "func", "var", "let", "if", "else", "guard",
            "switch", "case", "default", "for", "while", "repeat",
            "return", "break", "continue", "throw", "throws", "try", "catch",
            "import", "as", "is", "in", "where", "self", "super",
            "public", "private", "internal", "fileprivate", "open",
            "static", "final", "override", "mutating", "nonmutating",
            "convenience", "required", "optional",
            "nil", "true", "false",
            "defer", "do", "init", "deinit", "subscript",
            "associatedtype", "typealias", "precedencegroup",
            "some", "any", "async", "await", "actor", "nonisolated",
            "macro", "borrowing", "consuming", "transferring"
        ]
        let keywordPattern = "\\b(?:" + keywords.sorted(by: { $0.count > $1.count }).map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\b"

        return [
            // Line comments  //  ...
            HighlightRule(pattern: "//.*", attributes: [.foregroundColor: theme.commentColor]),
            // Block comments  /* ... */
            HighlightRule(pattern: "/\\*[\\s\\S]*?\\*/", attributes: [.foregroundColor: theme.commentColor]),
            // Multi-line strings  """ ... """
            HighlightRule(pattern: "\"\"\"[\\s\\S]*?\"\"\"", attributes: [.foregroundColor: theme.stringColor]),
            // Single-line strings  "..." (with escape handling)
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            // Numbers
            HighlightRule(pattern: "\\b-?(?:0b[01]+|0o[0-7]+|0x[0-9a-fA-F]+|(?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][+-]?\\d+)?)\\b", attributes: [.foregroundColor: theme.numberColor]),
            // Keywords
            HighlightRule(pattern: keywordPattern, attributes: [.foregroundColor: theme.keywordColor]),
            // Type names (Capitalized identifiers after certain keywords)
            HighlightRule(pattern: "\\b(?:class|struct|enum|protocol|extension|typealias|actor)\\s+([A-Z][a-zA-Z0-9_]*)", attributes: [.foregroundColor: theme.typeNameColor]),
            // Capitalized identifiers (likely types/protocols)
            HighlightRule(pattern: "\\b[A-Z][a-zA-Z0-9_]*\\b", attributes: [.foregroundColor: theme.typeNameColor]),
        ]
    }

    // MARK: - Python Rules

    private static func pythonRules(theme: EditorTheme) -> [HighlightRule] {
        let keywords = [
            "False", "None", "True", "and", "as", "assert", "async",
            "await", "break", "class", "continue", "def", "del", "elif",
            "else", "except", "finally", "for", "from", "global", "if",
            "import", "in", "is", "lambda", "nonlocal", "not", "or",
            "pass", "raise", "return", "try", "while", "with", "yield"
        ]
        let keywordPattern = "\\b(?:" + keywords.sorted(by: { $0.count > $1.count }).map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\b"

        return [
            HighlightRule(pattern: "#.*", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "\"\"\"[\\s\\S]*?\"\"\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'''[\\s\\S]*?'''", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'(?:\\\\.|[^'\\\\])*'", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "\\b-?(?:0b[01]+|0o[0-7]+|0x[0-9a-fA-F]+|(?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][+-]?\\d+)?)\\b", attributes: [.foregroundColor: theme.numberColor]),
            HighlightRule(pattern: keywordPattern, attributes: [.foregroundColor: theme.keywordColor]),
        ]
    }

    // MARK: - Ruby Rules

    private static func rubyRules(theme: EditorTheme) -> [HighlightRule] {
        let keywords = [
            "BEGIN", "END", "alias", "and", "begin", "break", "case",
            "class", "def", "defined?", "do", "else", "elsif", "end",
            "ensure", "false", "for", "if", "in", "module", "next",
            "nil", "not", "or", "redo", "rescue", "retry", "return",
            "self", "super", "then", "true", "undef", "unless", "until",
            "when", "while", "yield", "require", "include", "extend"
        ]

        return [
            HighlightRule(pattern: "#.*", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "=begin[\\s\\S]*?=end", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "%[qQ]?\\{[\\s\\S]*?\\}", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'(?:\\\\.|[^'\\\\])*'", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: ":[a-zA-Z_][a-zA-Z0-9_]*[!?=]?", attributes: [.foregroundColor: theme.typeNameColor]),
            HighlightRule(pattern: "[@$]{1,2}[a-zA-Z_][a-zA-Z0-9_]*", attributes: [.foregroundColor: theme.numberColor]),
            HighlightRule(pattern: "\\b-?(?:0b[01_]+|0o[0-7_]+|0x[0-9a-fA-F_]+|(?:\\d[\\d_]*\\.?[\\d_]*|\\.\\d[\\d_]*)(?:[eE][+-]?\\d+)?)\\b", attributes: [.foregroundColor: theme.numberColor]),
            HighlightRule(pattern: keywordPattern(for: keywords), attributes: [.foregroundColor: theme.keywordColor]),
            HighlightRule(pattern: "\\b[A-Z][a-zA-Z0-9_]*\\b", attributes: [.foregroundColor: theme.typeNameColor]),
        ]
    }

    // MARK: - PHP Rules

    private static func phpRules(theme: EditorTheme) -> [HighlightRule] {
        let keywords = [
            "__halt_compiler", "abstract", "and", "array", "as", "break",
            "callable", "case", "catch", "class", "clone", "const",
            "continue", "declare", "default", "die", "do", "echo", "else",
            "elseif", "empty", "enddeclare", "endfor", "endforeach",
            "endif", "endswitch", "endwhile", "enum", "eval", "exit",
            "extends", "false", "final", "finally", "fn", "for", "foreach",
            "function", "global", "goto", "if", "implements", "include",
            "include_once", "instanceof", "insteadof", "interface", "isset",
            "list", "match", "namespace", "new", "null", "or", "print",
            "private", "protected", "public", "readonly", "require",
            "require_once", "return", "static", "switch", "throw", "trait",
            "true", "try", "unset", "use", "var", "while", "xor", "yield"
        ]

        return [
            HighlightRule(pattern: "//.*", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "#.*", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "/\\*[\\s\\S]*?\\*/", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "<\\?(?:php)?|\\?>", attributes: [.foregroundColor: theme.keywordColor]),
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'(?:\\\\.|[^'\\\\])*'", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "\\$[a-zA-Z_][a-zA-Z0-9_]*", attributes: [.foregroundColor: theme.numberColor]),
            HighlightRule(pattern: "\\b-?(?:0b[01_]+|0o[0-7_]+|0x[0-9a-fA-F_]+|(?:\\d[\\d_]*\\.?[\\d_]*|\\.\\d[\\d_]*)(?:[eE][+-]?\\d+)?)\\b", attributes: [.foregroundColor: theme.numberColor]),
            HighlightRule(pattern: keywordPattern(for: keywords), attributes: [.foregroundColor: theme.keywordColor]),
            HighlightRule(pattern: "\\b[A-Z][a-zA-Z0-9_]*\\b", attributes: [.foregroundColor: theme.typeNameColor]),
        ]
    }

    // MARK: - Java Rules

    private static func javaRules(theme: EditorTheme) -> [HighlightRule] {
        let keywords = [
            "abstract", "assert", "boolean", "break", "byte", "case",
            "catch", "char", "class", "const", "continue", "default",
            "do", "double", "else", "enum", "exports", "extends", "false",
            "final", "finally", "float", "for", "goto", "if", "implements",
            "import", "instanceof", "int", "interface", "long", "module",
            "native", "new", "non-sealed", "null", "open", "opens",
            "package", "permits", "private", "protected", "provides",
            "public", "record", "requires", "return", "sealed", "short",
            "static", "strictfp", "super", "switch", "synchronized",
            "this", "throw", "throws", "to", "transient", "transitive",
            "true", "try", "uses", "var", "void", "volatile", "while",
            "with", "yield"
        ]

        return [
            HighlightRule(pattern: "//.*", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "/\\*[\\s\\S]*?\\*/", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'(?:\\\\.|[^'\\\\])'", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "\\b-?(?:0b[01_]+|0x[0-9a-fA-F_]+|(?:\\d[\\d_]*\\.?[\\d_]*|\\.\\d[\\d_]*)(?:[eE][+-]?\\d+)?)[fFdDlL]?\\b", attributes: [.foregroundColor: theme.numberColor]),
            HighlightRule(pattern: keywordPattern(for: keywords), attributes: [.foregroundColor: theme.keywordColor]),
            HighlightRule(pattern: "\\b[A-Z][a-zA-Z0-9_]*\\b", attributes: [.foregroundColor: theme.typeNameColor]),
        ]
    }

    // MARK: - JavaScript Rules

    private static func javascriptRules(theme: EditorTheme) -> [HighlightRule] {
        let keywords = [
            "async", "await", "break", "case", "catch", "class", "const",
            "continue", "debugger", "default", "delete", "do", "else",
            "enum", "export", "extends", "false", "finally", "for",
            "function", "if", "import", "in", "instanceof", "let",
            "new", "null", "of", "return", "super", "switch", "this",
            "throw", "true", "try", "typeof", "var", "void", "while",
            "with", "yield",
        ]
        let keywordPattern = "\\b(?:" + keywords.sorted(by: { $0.count > $1.count }).map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\b"

        return [
            HighlightRule(pattern: "//.*", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "/\\*[\\s\\S]*?\\*/", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "`(?:\\\\.|[^`\\\\])*`", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'(?:\\\\.|[^'\\\\])*'", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "\\b-?(?:0b[01]+|0o[0-7]+|0x[0-9a-fA-F]+|(?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][+-]?\\d+)?)n?\\b", attributes: [.foregroundColor: theme.numberColor]),
            HighlightRule(pattern: keywordPattern, attributes: [.foregroundColor: theme.keywordColor]),
        ]
    }

    // MARK: - TypeScript Rules

    private static func typescriptRules(theme: EditorTheme) -> [HighlightRule] {
        let keywords = [
            "abstract", "as", "async", "await", "break", "case", "catch",
            "class", "const", "continue", "debugger", "declare", "default",
            "delete", "do", "else", "enum", "export", "extends", "false",
            "finally", "for", "function", "if", "implements", "import",
            "in", "infer", "instanceof", "interface", "is", "keyof",
            "let", "namespace", "new", "null", "of", "private", "protected",
            "public", "readonly", "return", "super", "switch", "this",
            "throw", "true", "try", "type", "typeof", "var", "void",
            "while", "with", "yield",
        ]
        let keywordPattern = "\\b(?:" + keywords.sorted(by: { $0.count > $1.count }).map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\b"

        return [
            HighlightRule(pattern: "//.*", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "/\\*[\\s\\S]*?\\*/", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "`(?:\\\\.|[^`\\\\])*`", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'(?:\\\\.|[^'\\\\])*'", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "\\b-?(?:0b[01]+|0o[0-7]+|0x[0-9a-fA-F]+|(?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][+-]?\\d+)?)n?\\b", attributes: [.foregroundColor: theme.numberColor]),
            HighlightRule(pattern: keywordPattern, attributes: [.foregroundColor: theme.keywordColor]),
        ]
    }

    // MARK: - Go Rules

    private static func goRules(theme: EditorTheme) -> [HighlightRule] {
        let keywords = [
            "break", "case", "chan", "const", "continue", "default",
            "defer", "else", "fallthrough", "for", "func", "go", "goto",
            "if", "import", "interface", "map", "nil", "package", "range",
            "return", "select", "struct", "switch", "type", "var",
            "true", "false", "iota"
        ]

        return [
            HighlightRule(pattern: "//.*", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "/\\*[\\s\\S]*?\\*/", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "`[\\s\\S]*?`", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'(?:\\\\.|[^'\\\\])'", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "\\b-?(?:0b[01_]+|0o[0-7_]+|0x[0-9a-fA-F_]+|(?:\\d[\\d_]*\\.?[\\d_]*|\\.\\d[\\d_]*)(?:[eE][+-]?\\d+)?)i?\\b", attributes: [.foregroundColor: theme.numberColor]),
            HighlightRule(pattern: keywordPattern(for: keywords), attributes: [.foregroundColor: theme.keywordColor]),
            HighlightRule(pattern: "\\b[A-Z][a-zA-Z0-9_]*\\b", attributes: [.foregroundColor: theme.typeNameColor]),
        ]
    }

    // MARK: - HTML/CSS Rules

    private static func htmlRules(theme: EditorTheme) -> [HighlightRule] {
        return [
            // HTML comments
            HighlightRule(pattern: "<!--[\\s\\S]*?-->", attributes: [.foregroundColor: theme.commentColor]),
            // Tags
            HighlightRule(pattern: "</?[a-zA-Z][a-zA-Z0-9_-]*", attributes: [.foregroundColor: theme.keywordColor]),
            // Attributes
            HighlightRule(pattern: "\\b[a-zA-Z-]+(?=\\s*=)", attributes: [.foregroundColor: theme.typeNameColor]),
            // Strings in attributes
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'(?:\\\\.|[^'\\\\])*'", attributes: [.foregroundColor: theme.stringColor]),
        ]
    }

    private static func cssRules(theme: EditorTheme) -> [HighlightRule] {
        return [
            // CSS comments
            HighlightRule(pattern: "/\\*[\\s\\S]*?\\*/", attributes: [.foregroundColor: theme.commentColor]),
            // Selectors (class, id, element, pseudo)
            HighlightRule(pattern: "[.#][a-zA-Z][a-zA-Z0-9_-]*", attributes: [.foregroundColor: theme.typeNameColor]),
            // Properties
            HighlightRule(pattern: "\\b[a-z-]+(?=\\s*:)", attributes: [.foregroundColor: theme.keywordColor]),
            // Color hex values
            HighlightRule(pattern: "#[0-9a-fA-F]{3,8}\\b", attributes: [.foregroundColor: theme.numberColor]),
            // Numbers with units
            HighlightRule(pattern: "\\b-?\\d+\\.?\\d*(?:px|em|rem|%|vh|vw|vmin|vmax|ch|ex|cm|mm|in|pt|pc|deg|rad|grad|turn|s|ms|Hz|kHz|dpi|dpcm|dppx)?\\b", attributes: [.foregroundColor: theme.numberColor]),
            // Strings
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'(?:\\\\.|[^'\\\\])*'", attributes: [.foregroundColor: theme.stringColor]),
        ]
    }

    // MARK: - JSON Rules

    private static func jsonRules(theme: EditorTheme) -> [HighlightRule] {
        return [
            // Keys
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"(?=\\s*:)", attributes: [.foregroundColor: theme.keywordColor]),
            // String values
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            // Numbers
            HighlightRule(pattern: "\\b-?(?:0|[1-9]\\d*)(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b", attributes: [.foregroundColor: theme.numberColor]),
            // Boolean and null
            HighlightRule(pattern: "\\b(?:true|false|null)\\b", attributes: [.foregroundColor: theme.typeNameColor]),
        ]
    }

    // MARK: - Markdown Rules

    private static func markdownRules(theme: EditorTheme, font: NSFont) -> [HighlightRule] {
        let bold: [NSAttributedString.Key: Any] = [.font: font.bold()]
        let italic: [NSAttributedString.Key: Any] = [.font: font.italic()]

        return [
            // ATX headers (# through ######)
            HighlightRule(pattern: "(?m)^#{1,6}\\s.*$", attributes: [.foregroundColor: theme.headerColor, .font: font.bold()]),
            // Bold **text** or __text__
            HighlightRule(pattern: "\\*\\*[^*]+\\*\\*", attributes: bold),
            HighlightRule(pattern: "__[^_]+__", attributes: bold),
            // Italic *text* or _text_ (single)
            HighlightRule(pattern: "\\*[^*]+\\*", attributes: italic),
            HighlightRule(pattern: "_[^_]+_", attributes: italic),
            // Inline code `code`
            HighlightRule(pattern: "`[^`]+`", attributes: [.foregroundColor: theme.numberColor]),
            // Links [text](url)
            HighlightRule(pattern: "\\[.*?\\]\\(.*?\\)", attributes: [.foregroundColor: theme.keywordColor]),
        ]
    }

    // MARK: - Shell Rules

    private static func shellRules(theme: EditorTheme) -> [HighlightRule] {
        let keywords = [
            "if", "then", "else", "elif", "fi",
            "for", "while", "until", "do", "done",
            "case", "esac", "in",
            "function",
            "return", "exit",
            "export", "local", "readonly",
            "source", "alias", "unalias",
            "break", "continue",
            "echo", "printf", "shift", "test"
        ]
        let keywordPattern = "\\b(?:" + keywords.sorted(by: { $0.count > $1.count }).map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\b"

        return [
            // Line comments
            HighlightRule(pattern: "#.*", attributes: [.foregroundColor: theme.commentColor]),
            // Double-quoted strings
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            // Single-quoted strings
            HighlightRule(pattern: "'[^']*'", attributes: [.foregroundColor: theme.stringColor]),
            // Variable expansions ${VAR} or $VAR
            HighlightRule(pattern: "\\$\\{[^}]+\\}", attributes: [.foregroundColor: theme.numberColor]),
            HighlightRule(pattern: "\\$[a-zA-Z_][a-zA-Z0-9_]*", attributes: [.foregroundColor: theme.numberColor]),
            // Numbers
            HighlightRule(pattern: "\\b-?(?:0|[1-9]\\d*)(?:\\.\\d+)?\\b", attributes: [.foregroundColor: theme.numberColor]),
            // Keywords
            HighlightRule(pattern: keywordPattern, attributes: [.foregroundColor: theme.keywordColor]),
        ]
    }

    // MARK: - Highlighting Engine

    /// Highlights `source` for the given `language` on a background queue,
    /// delivering the result asynchronously on the main thread.
    static func highlight(
        _ source: String,
        language: Language,
        theme: EditorTheme,
        font: NSFont,
        completion: @escaping (NSAttributedString) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = highlightSync(source, language: language, theme: theme, font: font)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// Synchronous highlight — safe to call on a background queue.
    /// Returns an attributed string with all applicable rules applied.
    static func highlightSync(
        _ source: String,
        language: Language,
        theme: EditorTheme,
        font: NSFont
    ) -> NSAttributedString {
        let base = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: font,
                .foregroundColor: theme.foregroundColor,
            ]
        )

        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let allRules = rules(for: language, theme: theme, font: font)

        // Track ranges already claimed by higher-priority rules so they aren't overwritten.
        var claimed = IndexSet()

        for rule in allRules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: []) else { continue }
            let matches = regex.matches(in: source, options: [], range: fullRange)

            for match in matches {
                // Only apply if no higher-priority rule already claimed this range.
                let matchRange = match.range.location..<(match.range.location + match.range.length)
                let matchIdxSet = IndexSet(integersIn: matchRange)

                // Check if any part of this range is already claimed.
                // If so, skip (higher-priority rule already won).
                if match.range.length > 0 && !claimed.intersection(matchIdxSet).isEmpty {
                    continue
                }

                base.addAttributes(rule.attributes, range: match.range)
                claimed.insert(integersIn: matchRange)
            }
        }

        return base
    }
}

// MARK: - NSFont Italic Helper

private extension NSFont {
    func bold() -> NSFont {
        let desc = fontDescriptor.withSymbolicTraits(.bold)
        return NSFont(descriptor: desc, size: pointSize) ?? self
    }

    func italic() -> NSFont {
        let desc = fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: desc, size: pointSize) ?? self
    }
}
