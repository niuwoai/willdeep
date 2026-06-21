//
//  EditorDefinitionResolver.swift
//  WillDeep
//
//  Lightweight project-local "go to definition" support for common code and
//  configuration files. This is intentionally dependency-free; language server
//  integrations can plug in ahead of this resolver later.
//

import Foundation

struct EditorDefinitionLocation: Equatable, Sendable {
    let url: URL
    let line: Int
    let title: String
}

nonisolated enum EditorDefinitionResolver {
    private static let maxIndexedFiles = 4_000
    private static let maxFileBytes = 1_048_576

    private static let skippedDirectoryNames: Set<String> = [
        ".build", ".git", ".gradle", ".idea", ".next", ".svn", ".turbo",
        ".venv", ".vscode", "build", "coverage", "DerivedData", "dist",
        "node_modules", "out", "target", "vendor"
    ]

    private static let supportedExtensions: Set<String> = [
        "go", "java", "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts",
        "env", "ini", "properties", "conf", "cfg", "yaml", "yml"
    ]

    static func definition(
        for rawSymbol: String,
        from currentFileURL: URL?,
        rootDirectory: URL?
    ) -> EditorDefinitionLocation? {
        let candidates = symbolCandidates(from: rawSymbol)
        guard !candidates.isEmpty else { return nil }

        let roots = searchRoots(currentFileURL: currentFileURL, rootDirectory: rootDirectory)
        var scanned = 0
        for root in roots {
            for url in sourceFiles(under: root) {
                scanned += 1
                if scanned > maxIndexedFiles { return nil }
                guard let content = readSmallTextFile(url) else { continue }
                if let match = definition(in: content, url: url, candidates: candidates) {
                    return match
                }
            }
        }
        return nil
    }

    static func symbolCandidates(from rawSymbol: String) -> [String] {
        let trimmed = rawSymbol.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\r`'\"()[]{}<>:,;"))
        guard !trimmed.isEmpty else { return [] }

        var result: [String] = []
        func append(_ value: String) {
            let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\r`'\"()[]{}<>:,;"))
            guard !cleaned.isEmpty, !result.contains(cleaned) else { return }
            result.append(cleaned)
        }

        append(trimmed)

        if trimmed.contains(".") {
            append(String(trimmed.split(separator: ".").last ?? ""))
        }
        if trimmed.contains("-") {
            append(trimmed.replacingOccurrences(of: "-", with: "_"))
            append(trimmed.replacingOccurrences(of: "-", with: "."))
        }
        if trimmed.contains("_") {
            append(trimmed.replacingOccurrences(of: "_", with: ".").lowercased())
            append(trimmed.replacingOccurrences(of: "_", with: "-").lowercased())
        }

        append(trimmed.uppercased())
        append(trimmed.lowercased())
        return result
    }

    private static func searchRoots(currentFileURL: URL?, rootDirectory: URL?) -> [URL] {
        var roots: [URL] = []
        if let rootDirectory {
            roots.append(rootDirectory.standardizedFileURL)
        }
        if let currentFileURL {
            let parent = currentFileURL.deletingLastPathComponent().standardizedFileURL
            if !roots.contains(parent) {
                roots.append(parent)
            }
        }
        return roots
    }

    private static func sourceFiles(under root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if skippedDirectoryNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { continue }
            guard (values.fileSize ?? 0) <= maxFileBytes else { continue }
            guard supports(url) else { continue }
            urls.append(url)
        }
        return urls.sorted { $0.path < $1.path }
    }

    private static func supports(_ url: URL) -> Bool {
        let filename = url.lastPathComponent.lowercased()
        if filename == ".env" || filename.hasPrefix(".env.") { return true }
        if filename.hasPrefix("application.") { return true }
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private static func readSmallTextFile(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue <= maxFileBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func definition(
        in content: String,
        url: URL,
        candidates: [String]
    ) -> EditorDefinitionLocation? {
        let lowerExtension = url.pathExtension.lowercased()
        let filename = url.lastPathComponent.lowercased()

        if lowerExtension == "go",
           let match = codeDefinition(in: content, url: url, candidates: candidates, patterns: goPatterns) {
            return match
        }
        if lowerExtension == "java",
           let match = codeDefinition(in: content, url: url, candidates: candidates, patterns: javaPatterns) {
            return match
        }
        if ["js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts"].contains(lowerExtension),
           let match = codeDefinition(in: content, url: url, candidates: candidates, patterns: typeScriptPatterns) {
            return match
        }
        if filename == ".env" || filename.hasPrefix(".env."),
           let match = keyValueDefinition(in: content, url: url, candidates: candidates) {
            return match
        }
        if filename.hasPrefix("application.") || ["env", "ini", "properties", "conf", "cfg"].contains(lowerExtension),
           let match = keyValueDefinition(in: content, url: url, candidates: candidates) {
            return match
        }
        if ["yaml", "yml"].contains(lowerExtension),
           let match = yamlDefinition(in: content, url: url, candidates: candidates) {
            return match
        }
        return nil
    }

    private static let goPatterns = [
        #"^\s*func\s+(?:\([^)]*\)\s*)?%@\s*\("#,
        #"^\s*type\s+%@\s+(?:struct|interface|func|\w+)"#,
        #"^\s*(?:const|var)\s+%@\b"#
    ]

    private static let javaPatterns = [
        #"^\s*(?:public|private|protected|abstract|final|sealed|static|\s)*\s*(?:class|interface|enum|record|@interface)\s+%@\b"#,
        #"^\s*(?:public|private|protected|static|final|synchronized|native|abstract|\s)+[\w<>\[\], ?]+\s+%@\s*\("#,
        #"^\s*(?:public|private|protected|static|final|volatile|transient|\s)+[\w<>\[\], ?]+\s+%@\s*(?:=|;)"#
    ]

    private static let typeScriptPatterns = [
        #"^\s*(?:export\s+default\s+|export\s+)?(?:abstract\s+)?class\s+%@\b"#,
        #"^\s*(?:export\s+)?(?:interface|type|enum|namespace)\s+%@\b"#,
        #"^\s*(?:export\s+)?(?:async\s+)?function\s+%@\s*\("#,
        #"^\s*(?:export\s+)?(?:const|let|var)\s+%@\b"#,
        #"^\s*(?:public|private|protected|static|readonly|async|\s)*%@\s*\([^)]*\)\s*(?::|=>|\{)"#
    ]

    private static func codeDefinition(
        in content: String,
        url: URL,
        candidates: [String],
        patterns: [String]
    ) -> EditorDefinitionLocation? {
        for candidate in candidates where isIdentifierLike(candidate) {
            for patternTemplate in patterns {
                let escaped = NSRegularExpression.escapedPattern(for: candidate)
                let pattern = patternTemplate.replacingOccurrences(of: "%@", with: escaped)
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
                let ns = content as NSString
                let fullRange = NSRange(location: 0, length: ns.length)
                guard let match = regex.firstMatch(in: content, range: fullRange) else { continue }
                return EditorDefinitionLocation(
                    url: url,
                    line: lineNumber(for: match.range.location, in: ns),
                    title: candidate
                )
            }
        }
        return nil
    }

    private static func keyValueDefinition(
        in content: String,
        url: URL,
        candidates: [String]
    ) -> EditorDefinitionLocation? {
        let lines = content.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";") else { continue }
            guard let separator = trimmed.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            if keyMatches(key, candidates: candidates) {
                return EditorDefinitionLocation(url: url, line: index + 1, title: key)
            }
        }
        return nil
    }

    private static func yamlDefinition(
        in content: String,
        url: URL,
        candidates: [String]
    ) -> EditorDefinitionLocation? {
        var stack: [(indent: Int, key: String)] = []
        let lines = content.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }

            let key = String(trimmed[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            guard !key.isEmpty, !key.hasPrefix("-") else { continue }
            let indent = leadingSpaces(in: line)
            while let last = stack.last, last.indent >= indent {
                stack.removeLast()
            }
            stack.append((indent, key))

            let dotted = stack.map(\.key).joined(separator: ".")
            if keyMatches(key, candidates: candidates) || keyMatches(dotted, candidates: candidates) {
                return EditorDefinitionLocation(url: url, line: index + 1, title: dotted)
            }
        }
        return nil
    }

    private static func keyMatches(_ key: String, candidates: [String]) -> Bool {
        candidates.contains { candidate in
            key == candidate
                || key.caseInsensitiveCompare(candidate) == .orderedSame
                || key.normalizedConfigKey == candidate.normalizedConfigKey
        }
    }

    private static func isIdentifierLike(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first else { return false }
        let allowedStart = CharacterSet(charactersIn: "_$").union(.letters)
        let allowedBody = CharacterSet(charactersIn: "_$").union(.letters).union(.decimalDigits)
        return allowedStart.contains(first) && value.unicodeScalars.allSatisfy { allowedBody.contains($0) }
    }

    private static func leadingSpaces(in line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { total, character in
            total + (character == "\t" ? 4 : 1)
        }
    }

    private static func lineNumber(for location: Int, in text: NSString) -> Int {
        let prefix = text.substring(with: NSRange(location: 0, length: max(0, min(location, text.length))))
        return prefix.components(separatedBy: .newlines).count
    }
}

private extension String {
    nonisolated var normalizedConfigKey: String {
        lowercased()
            .replacingOccurrences(of: "_", with: ".")
            .replacingOccurrences(of: "-", with: ".")
    }
}
