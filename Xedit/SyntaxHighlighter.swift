//
//  SyntaxHighlighter.swift
//  WillDeep
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
    case yaml
    case toml
    case xml
    case sql
    case dockerfile
    case makefile
    case ini
    case env
    case rust
    case c
    case cpp
    case csharp
    case diff

    /// Maps a file extension (including the dot) to a language.
    /// Returns `nil` if the extension is not recognized.
    nonisolated static func fromExtension(_ ext: String) -> Language? {
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
        case ".sh", ".bash", ".zsh", ".ksh": return .shell
        case ".yml", ".yaml": return .yaml
        case ".toml": return .toml
        case ".xml", ".plist", ".svg", ".xib", ".storyboard": return .xml
        case ".sql": return .sql
        case ".ini", ".cfg", ".conf", ".editorconfig": return .ini
        case ".env": return .env
        case ".rs": return .rust
        case ".c", ".h": return .c
        case ".cc", ".cpp", ".cxx", ".hpp", ".hh", ".hxx": return .cpp
        case ".cs": return .csharp
        case ".diff", ".patch": return .diff
        default:        return nil
        }
    }

    /// Convenience: detect language from a file URL.
    nonisolated static func fromURL(_ url: URL) -> Language? {
        let filename = url.lastPathComponent.lowercased()
        switch filename {
        case "dockerfile", "containerfile":
            return .dockerfile
        case "makefile", "gnumakefile":
            return .makefile
        case ".bashrc", ".bash_profile", ".bash_aliases", ".zshrc", ".profile":
            return .shell
        case ".env":
            return .env
        default:
            return fromExtension(url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)")
        }
    }
}

extension Language {
    var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .python: return "Python"
        case .ruby: return "Ruby"
        case .php: return "PHP"
        case .java: return "Java"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .go: return "Go"
        case .html: return "HTML"
        case .css: return "CSS"
        case .json: return "JSON"
        case .markdown: return "Markdown"
        case .shell: return "Shell"
        case .yaml: return "YAML"
        case .toml: return "TOML"
        case .xml: return "XML"
        case .sql: return "SQL"
        case .dockerfile: return "Dockerfile"
        case .makefile: return "Makefile"
        case .ini: return "INI"
        case .env: return "env"
        case .rust: return "Rust"
        case .c: return "C"
        case .cpp: return "C++"
        case .csharp: return "C#"
        case .diff: return "Diff"
        }
    }
}

enum SyntaxHighlightingSelection: Equatable {
    case automatic
    case plainText
    case language(Language)
}

// MARK: - Highlight Rule

/// A single regex-based highlighting rule.
struct HighlightRule {
    let pattern: String
    let attributes: [NSAttributedString.Key: Any]
}

// MARK: - Syntax Highlighter

enum SyntaxHighlighter {

    // MARK: Regex cache
    //
    // Pre-rc38 every call to `highlightSync` / `computeSpans` re-compiled
    // every rule's NSRegularExpression — for a 20-rule grammar over N
    // visible viewport updates that's O(N × 20) regex compilations. Now we
    // compile once per unique pattern string and stash them behind a lock
    // so background threads (viewport recompute) and the main thread
    // (full re-highlight) can share. Patterns are static literals so the
    // cache size is bounded by the rule count across all languages.

    private static let regexCacheLock = NSLock()
    private static var regexCache: [String: NSRegularExpression] = [:]

    static func cachedRegex(pattern: String) -> NSRegularExpression? {
        regexCacheLock.lock()
        if let hit = regexCache[pattern] {
            regexCacheLock.unlock()
            return hit
        }
        regexCacheLock.unlock()
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        regexCacheLock.lock()
        regexCache[pattern] = compiled
        regexCacheLock.unlock()
        return compiled
    }

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
        case .yaml:        return yamlRules(theme: theme)
        case .toml:        return tomlRules(theme: theme)
        case .xml:         return xmlRules(theme: theme)
        case .sql:         return sqlRules(theme: theme)
        case .dockerfile:  return dockerfileRules(theme: theme)
        case .makefile:    return makefileRules(theme: theme)
        case .ini:         return iniRules(theme: theme)
        case .env:         return envRules(theme: theme)
        case .rust:        return rustRules(theme: theme)
        case .c:           return cRules(theme: theme)
        case .cpp:         return cppRules(theme: theme)
        case .csharp:      return csharpRules(theme: theme)
        case .diff:        return diffRules(theme: theme)
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
            HighlightRule(pattern: "(?i)" + keywordPattern(for: keywords), attributes: [.foregroundColor: theme.keywordColor]),
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
            "select", "function", "time",
            "return", "exit", "exec",
            "export", "local", "readonly", "declare", "typeset",
            "source", "alias", "unalias", "trap", "set", "unset",
            "break", "continue", "eval",
            "echo", "printf", "shift", "test", "read", "cd", "pwd",
            "pushd", "popd", "dirs", "getopts", "jobs", "fg", "bg",
            "wait", "kill", "true", "false"
        ]
        let keywordPattern = keywordPattern(for: keywords)

        return [
            // Shebang
            HighlightRule(pattern: "^#!.*", attributes: [.foregroundColor: theme.commentColor]),
            // Line comments
            HighlightRule(pattern: "#.*", attributes: [.foregroundColor: theme.commentColor]),
            // Here-doc operators
            HighlightRule(pattern: "<<-?\\s*['\"]?[A-Za-z_][A-Za-z0-9_]*['\"]?", attributes: [.foregroundColor: theme.stringColor]),
            // Double-quoted strings
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            // Single-quoted strings
            HighlightRule(pattern: "'[^']*'", attributes: [.foregroundColor: theme.stringColor]),
            // Variable expansions ${VAR} or $VAR
            HighlightRule(pattern: "\\$\\([^)]*\\)", attributes: [.foregroundColor: theme.typeNameColor]),
            HighlightRule(pattern: "`[^`]*`", attributes: [.foregroundColor: theme.typeNameColor]),
            HighlightRule(pattern: "\\$\\{[^}]+\\}", attributes: [.foregroundColor: theme.numberColor]),
            HighlightRule(pattern: "\\$(?:[a-zA-Z_][a-zA-Z0-9_]*|[0-9#?*!@$-])", attributes: [.foregroundColor: theme.numberColor]),
            // Assignments and flags
            HighlightRule(pattern: "\\b[A-Za-z_][A-Za-z0-9_]*(?=\\=)", attributes: [.foregroundColor: theme.typeNameColor]),
            HighlightRule(pattern: "(?<=\\s)-{1,2}[A-Za-z0-9][A-Za-z0-9_-]*(?:=[^\\s]+)?", attributes: [.foregroundColor: theme.typeNameColor]),
            // Numbers
            HighlightRule(pattern: "\\b-?(?:0|[1-9]\\d*)(?:\\.\\d+)?\\b", attributes: [.foregroundColor: theme.numberColor]),
            // Keywords
            HighlightRule(pattern: keywordPattern, attributes: [.foregroundColor: theme.keywordColor]),
            // Function definitions and common command position.
            HighlightRule(pattern: "^\\s*(?:function\\s+)?[A-Za-z_][A-Za-z0-9_-]*(?=\\s*\\(\\)|\\s*\\{)", attributes: [.foregroundColor: theme.headerColor]),
            HighlightRule(pattern: "(?m)^\\s*[A-Za-z_][A-Za-z0-9_.-]*(?=\\s|$)", attributes: [.foregroundColor: theme.headerColor]),
        ]
    }

    // MARK: - Data and Config Rules

    private static func yamlRules(theme: EditorTheme) -> [HighlightRule] {
        [
            HighlightRule(pattern: "#.*", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'[^']*'", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "(?m)^\\s*-", attributes: [.foregroundColor: theme.keywordColor]),
            HighlightRule(pattern: "(?m)^\\s*[A-Za-z0-9_.-]+(?=\\s*:)", attributes: [.foregroundColor: theme.keywordColor]),
            HighlightRule(pattern: "\\b(?:true|false|null|yes|no|on|off)\\b", attributes: [.foregroundColor: theme.typeNameColor]),
            HighlightRule(pattern: "\\b-?(?:0|[1-9]\\d*)(?:\\.\\d+)?\\b", attributes: [.foregroundColor: theme.numberColor]),
        ]
    }

    private static func tomlRules(theme: EditorTheme) -> [HighlightRule] {
        [
            HighlightRule(pattern: "#.*", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "(?m)^\\s*\\[\\[?[^\\]]+\\]\\]?", attributes: [.foregroundColor: theme.headerColor]),
            HighlightRule(pattern: "\"\"\"[\\s\\S]*?\"\"\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'''[\\s\\S]*?'''", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'[^']*'", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "(?m)^\\s*[A-Za-z0-9_.-]+(?=\\s*=)", attributes: [.foregroundColor: theme.keywordColor]),
            HighlightRule(pattern: "\\b(?:true|false)\\b", attributes: [.foregroundColor: theme.typeNameColor]),
            HighlightRule(pattern: "\\b\\d{4}-\\d{2}-\\d{2}(?:[Tt ]\\d{2}:\\d{2}:\\d{2}(?:Z|[+-]\\d{2}:\\d{2})?)?\\b", attributes: [.foregroundColor: theme.numberColor]),
            HighlightRule(pattern: "\\b-?(?:0|[1-9]\\d*)(?:\\.\\d+)?\\b", attributes: [.foregroundColor: theme.numberColor]),
        ]
    }

    private static func xmlRules(theme: EditorTheme) -> [HighlightRule] {
        [
            HighlightRule(pattern: "<!--[\\s\\S]*?-->", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "<\\?[^>]+\\?>", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "</?[A-Za-z_][A-Za-z0-9_.:-]*", attributes: [.foregroundColor: theme.keywordColor]),
            HighlightRule(pattern: "\\b[A-Za-z_:][A-Za-z0-9_.:-]*(?=\\s*=)", attributes: [.foregroundColor: theme.typeNameColor]),
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'(?:\\\\.|[^'\\\\])*'", attributes: [.foregroundColor: theme.stringColor]),
        ]
    }

    private static func iniRules(theme: EditorTheme) -> [HighlightRule] {
        [
            HighlightRule(pattern: "[#;].*", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "(?m)^\\s*\\[[^\\]]+\\]", attributes: [.foregroundColor: theme.headerColor]),
            HighlightRule(pattern: "(?m)^\\s*[A-Za-z0-9_.-]+(?=\\s*[=:])", attributes: [.foregroundColor: theme.keywordColor]),
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'[^']*'", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "\\b(?:true|false|yes|no|on|off)\\b", attributes: [.foregroundColor: theme.typeNameColor]),
            HighlightRule(pattern: "\\b-?(?:0|[1-9]\\d*)(?:\\.\\d+)?\\b", attributes: [.foregroundColor: theme.numberColor]),
        ]
    }

    private static func envRules(theme: EditorTheme) -> [HighlightRule] {
        [
            HighlightRule(pattern: "#.*", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "(?m)^\\s*(?:export\\s+)?[A-Za-z_][A-Za-z0-9_]*(?=\\=)", attributes: [.foregroundColor: theme.keywordColor]),
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'[^']*'", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "\\$\\{[^}]+\\}", attributes: [.foregroundColor: theme.numberColor]),
            HighlightRule(pattern: "\\$[A-Za-z_][A-Za-z0-9_]*", attributes: [.foregroundColor: theme.numberColor]),
        ]
    }

    // MARK: - Systems and Database Rules

    private static func sqlRules(theme: EditorTheme) -> [HighlightRule] {
        let keywords = [
            "select", "from", "where", "join", "inner", "left", "right",
            "full", "outer", "on", "as", "and", "or", "not", "null",
            "insert", "into", "values", "update", "set", "delete",
            "create", "alter", "drop", "table", "view", "index",
            "primary", "key", "foreign", "references", "constraint",
            "group", "by", "having", "order", "limit", "offset",
            "union", "all", "distinct", "case", "when", "then", "else", "end",
            "true", "false", "like", "in", "exists", "between"
        ]

        return [
            HighlightRule(pattern: "--.*", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "/\\*[\\s\\S]*?\\*/", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'(?:''|[^'])*'", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "\\b-?(?:0|[1-9]\\d*)(?:\\.\\d+)?\\b", attributes: [.foregroundColor: theme.numberColor]),
            HighlightRule(pattern: keywordPattern(for: keywords), attributes: [.foregroundColor: theme.keywordColor]),
            HighlightRule(pattern: "\\b[A-Z_][A-Z0-9_]*\\b", attributes: [.foregroundColor: theme.typeNameColor]),
        ]
    }

    private static func dockerfileRules(theme: EditorTheme) -> [HighlightRule] {
        let keywords = [
            "FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE",
            "ENV", "ADD", "COPY", "ENTRYPOINT", "VOLUME", "USER",
            "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL", "HEALTHCHECK", "SHELL"
        ]

        return [
            HighlightRule(pattern: "#.*", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'[^']*'", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "\\$\\{[^}]+\\}", attributes: [.foregroundColor: theme.numberColor]),
            HighlightRule(pattern: "\\$[A-Za-z_][A-Za-z0-9_]*", attributes: [.foregroundColor: theme.numberColor]),
            HighlightRule(pattern: "(?m)^\\s*(?:" + keywords.joined(separator: "|") + ")\\b", attributes: [.foregroundColor: theme.keywordColor]),
            HighlightRule(pattern: "--[A-Za-z0-9_-]+(?:=[^\\s]+)?", attributes: [.foregroundColor: theme.typeNameColor]),
        ]
    }

    private static func makefileRules(theme: EditorTheme) -> [HighlightRule] {
        let keywords = [
            "include", "-include", "define", "endef", "ifeq", "ifneq",
            "ifdef", "ifndef", "else", "endif", "export", "unexport", "override"
        ]

        return [
            HighlightRule(pattern: "#.*", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "(?m)^\\s*[A-Za-z0-9_./%-]+\\s*:(?!=)", attributes: [.foregroundColor: theme.headerColor]),
            HighlightRule(pattern: "(?m)^\\s*[A-Za-z_][A-Za-z0-9_]*(?=\\s*[:+?]?=)", attributes: [.foregroundColor: theme.keywordColor]),
            HighlightRule(pattern: "\\$\\([^)]*\\)", attributes: [.foregroundColor: theme.numberColor]),
            HighlightRule(pattern: "\\$\\{[^}]*\\}", attributes: [.foregroundColor: theme.numberColor]),
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'[^']*'", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: keywordPattern(for: keywords), attributes: [.foregroundColor: theme.keywordColor]),
        ]
    }

    // MARK: - Additional Code Rules

    private static func rustRules(theme: EditorTheme) -> [HighlightRule] {
        let keywords = [
            "as", "async", "await", "break", "const", "continue", "crate",
            "dyn", "else", "enum", "extern", "false", "fn", "for", "if",
            "impl", "in", "let", "loop", "match", "mod", "move", "mut",
            "pub", "ref", "return", "self", "Self", "static", "struct",
            "super", "trait", "true", "type", "unsafe", "use", "where", "while"
        ]
        return cFamilyRules(theme: theme, keywords: keywords)
    }

    private static func cRules(theme: EditorTheme) -> [HighlightRule] {
        let keywords = [
            "auto", "break", "case", "char", "const", "continue", "default",
            "do", "double", "else", "enum", "extern", "float", "for",
            "goto", "if", "inline", "int", "long", "register", "restrict",
            "return", "short", "signed", "sizeof", "static", "struct",
            "switch", "typedef", "union", "unsigned", "void", "volatile", "while"
        ]
        return cFamilyRules(theme: theme, keywords: keywords)
    }

    private static func cppRules(theme: EditorTheme) -> [HighlightRule] {
        let keywords = [
            "alignas", "alignof", "auto", "bool", "break", "case", "catch",
            "class", "const", "constexpr", "continue", "decltype", "default",
            "delete", "do", "double", "else", "enum", "explicit", "export",
            "extern", "false", "final", "float", "for", "friend", "if",
            "inline", "int", "long", "mutable", "namespace", "new", "noexcept",
            "nullptr", "operator", "override", "private", "protected", "public",
            "return", "short", "signed", "sizeof", "static", "struct",
            "switch", "template", "this", "throw", "true", "try", "typedef",
            "typename", "union", "unsigned", "using", "virtual", "void",
            "volatile", "while"
        ]
        return cFamilyRules(theme: theme, keywords: keywords)
    }

    private static func csharpRules(theme: EditorTheme) -> [HighlightRule] {
        let keywords = [
            "abstract", "as", "async", "await", "base", "bool", "break",
            "case", "catch", "class", "const", "continue", "default",
            "delegate", "do", "double", "else", "enum", "event", "false",
            "finally", "fixed", "float", "for", "foreach", "if", "implicit",
            "in", "int", "interface", "internal", "is", "lock", "namespace",
            "new", "null", "object", "operator", "out", "override", "params",
            "private", "protected", "public", "readonly", "record", "ref",
            "return", "sealed", "static", "string", "struct", "switch",
            "this", "throw", "true", "try", "typeof", "using", "var",
            "virtual", "void", "while", "yield"
        ]
        return cFamilyRules(theme: theme, keywords: keywords)
    }

    private static func cFamilyRules(theme: EditorTheme, keywords: [String]) -> [HighlightRule] {
        [
            HighlightRule(pattern: "//.*", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "/\\*[\\s\\S]*?\\*/", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "#\\s*[A-Za-z_][A-Za-z0-9_]*.*", attributes: [.foregroundColor: theme.commentColor]),
            HighlightRule(pattern: "\"(?:\\\\.|[^\"\\\\])*\"", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "'(?:\\\\.|[^'\\\\])+'", attributes: [.foregroundColor: theme.stringColor]),
            HighlightRule(pattern: "\\b-?(?:0b[01_]+|0x[0-9a-fA-F_]+|(?:\\d[\\d_]*\\.?[\\d_]*|\\.\\d[\\d_]*)(?:[eE][+-]?\\d+)?)[uUlLfFdDmM]*\\b", attributes: [.foregroundColor: theme.numberColor]),
            HighlightRule(pattern: keywordPattern(for: keywords), attributes: [.foregroundColor: theme.keywordColor]),
            HighlightRule(pattern: "\\b[A-Z][A-Za-z0-9_]*\\b", attributes: [.foregroundColor: theme.typeNameColor]),
        ]
    }

    // MARK: - Diff Rules

    private static func diffRules(theme: EditorTheme) -> [HighlightRule] {
        [
            // git 元信息行（diff --git / index / mode 变化等）
            HighlightRule(pattern: "(?m)^(?:diff --git.*|index [0-9a-f]+\\.\\..*|new file mode.*|deleted file mode.*|old mode.*|new mode.*|similarity index.*|rename (?:from|to).*|Binary files.*)$", attributes: [.foregroundColor: theme.commentColor]),
            // 文件头 +++/---（必须排在 +/- 行级规则之前，否则会被当成增删行）
            HighlightRule(pattern: "(?m)^(?:\\+\\+\\+|---) .*$", attributes: [.foregroundColor: theme.headerColor]),
            // hunk 头 @@ -13,6 +13,7 @@
            HighlightRule(pattern: "(?m)^@@[^\\n]*$", attributes: [.foregroundColor: theme.keywordColor]),
            // 新增行（绿）
            HighlightRule(pattern: "(?m)^\\+[^\\n]*$", attributes: [.foregroundColor: theme.diffAddedColor]),
            // 删除行（红）
            HighlightRule(pattern: "(?m)^-[^\\n]*$", attributes: [.foregroundColor: theme.diffRemovedColor]),
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
            guard let regex = Self.cachedRegex(pattern: rule.pattern) else { continue }
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

    // MARK: - Viewport (range-limited) highlighting

    /// One computed highlight span: an attribute set over a character range,
    /// expressed in offsets relative to the *whole* document. Computed on a
    /// background queue, then applied to the live text storage on the main queue.
    struct HighlightSpan {
        let range: NSRange
        let attributes: [NSAttributedString.Key: Any]
    }

    /// Compute highlight spans for a sub-range of `source`.
    ///
    /// Safe to call on a background queue. The regex pass runs over the given
    /// `range` only — for very large files this is what keeps highlighting cheap
    /// (we highlight the viewport plus a margin instead of the whole file). The
    /// caller is responsible for expanding `range` to line boundaries and adding
    /// an overscan margin so multi-line tokens within the window resolve
    /// correctly; tokens that span far beyond the window may be approximate.
    static func computeSpans(
        in source: String,
        range: NSRange,
        language: Language,
        theme: EditorTheme,
        font: NSFont
    ) -> [HighlightSpan] {
        let nsSource = source as NSString
        let safeRange = NSIntersectionRange(range, NSRange(location: 0, length: nsSource.length))
        guard safeRange.length > 0 else { return [] }

        let allRules = rules(for: language, theme: theme, font: font)
        var claimed = IndexSet()
        var spans: [HighlightSpan] = []

        for rule in allRules {
            guard let regex = Self.cachedRegex(pattern: rule.pattern) else { continue }
            let matches = regex.matches(in: source, options: [], range: safeRange)

            for match in matches {
                let matchRange = match.range.location..<(match.range.location + match.range.length)
                let matchIdxSet = IndexSet(integersIn: matchRange)
                if match.range.length > 0 && !claimed.intersection(matchIdxSet).isEmpty {
                    continue
                }
                spans.append(HighlightSpan(range: match.range, attributes: rule.attributes))
                claimed.insert(integersIn: matchRange)
            }
        }

        return spans
    }

    /// Apply computed spans to a live text storage, resetting the range to the
    /// default foreground color first so stale highlighting is cleared. Must run
    /// on the main queue. Uses in-place `addAttributes` (no full-storage swap) so
    /// layout and scroll position are preserved.
    @MainActor
    static func applySpans(
        _ spans: [HighlightSpan],
        to textStorage: NSTextStorage,
        clearing range: NSRange,
        theme: EditorTheme
    ) {
        let safeRange = NSIntersectionRange(range, NSRange(location: 0, length: textStorage.length))
        guard safeRange.length > 0 else { return }

        textStorage.beginEditing()
        textStorage.addAttribute(.foregroundColor, value: theme.foregroundColor, range: safeRange)
        for span in spans {
            let r = NSIntersectionRange(span.range, NSRange(location: 0, length: textStorage.length))
            if r.length > 0 {
                textStorage.addAttributes(span.attributes, range: r)
            }
        }
        textStorage.endEditing()
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
