//
//  AgentFileTools.swift
//  WillDeep
//
//  Workspace read-only file and git tools used by the Agent.
//

import Foundation

enum AgentFileTools {
    private static let maxFileSizeForSearch: Int = 512 * 1024
    private static let maxSearchResults = 200
    private static let maxScannedFiles = 4_000
    private static let maxToolTraversalNodes = 50_000
    private static let defaultMaxReadBytes = 64 * 1024
    private static let absoluteMaxReadBytes = 256 * 1024
    private static let maxDirectoryEntries = 400

    static func searchFiles(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        if let backend = context.remoteBackend {
            return try await backend.searchFiles(arguments: arguments)
        }
        guard let root = context.rootDirectory else { throw AgentToolError.noWorkspace }
        guard let query = arguments["query"]?.stringValue(),
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.missingArgument("query")
        }
        let limit = min(max(arguments["max_results"]?.intValue() ?? 60, 1), maxSearchResults)

        let rootPath = root.standardizedFileURL.path
        let needle = query.lowercased()

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw AgentToolError.notFound(rootPath)
        }

        var matches: [String] = []
        var scanned = 0
        var visited = 0

        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited > maxToolTraversalNodes { break }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else {
                continue
            }
            if values.isDirectory == true {
                if ProjectDirectoryExclusions.shouldSkip(url) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            scanned += 1
            if scanned > maxScannedFiles { break }
            if let size = values.fileSize, size > maxFileSizeForSearch { continue }
            if AppState.isBinaryFile(at: url) { continue }

            guard let data = try? Data(contentsOf: url),
                  let content = String(data: data, encoding: .utf8) else {
                continue
            }

            let relativePath = relativePath(of: url, root: root)
            var lineNumber = 0
            for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
                lineNumber += 1
                if line.lowercased().contains(needle) {
                    let snippet = line.prefix(200)
                    matches.append("\(relativePath):\(lineNumber): \(snippet)")
                    if matches.count >= limit { break }
                }
            }
            if matches.count >= limit { break }
        }

        let summary = "\(matches.count) match\(matches.count == 1 ? "" : "es") for \"\(query)\""
        let payload = matches.isEmpty
            ? "No matches found for \"\(query)\"."
            : matches.joined(separator: "\n")
        return AgentToolResult(summary: summary, payload: payload)
    }

    static func grepFiles(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        if let backend = context.remoteBackend {
            return try await backend.grepFiles(arguments: arguments)
        }
        guard let root = context.rootDirectory else { throw AgentToolError.noWorkspace }
        guard let pattern = arguments["pattern"]?.stringValue(),
              !pattern.isEmpty else {
            throw AgentToolError.missingArgument("pattern")
        }

        var options: NSRegularExpression.Options = []
        if arguments["case_sensitive"]?.rawAny as? Bool != true {
            options.insert(.caseInsensitive)
        }

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw AgentToolError.invalidRegex(error.localizedDescription)
        }

        let searchRoot: URL
        if let raw = arguments["path"]?.stringValue(), !raw.isEmpty {
            searchRoot = try resolveWorkspaceURL(raw, root: root)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: searchRoot.path, isDirectory: &isDirectory) else {
                throw AgentToolError.notFound(raw)
            }
            guard isDirectory.boolValue else {
                throw AgentToolError.notRegular(raw)
            }
        } else {
            searchRoot = root
        }

        let limit = min(max(arguments["max_results"]?.intValue() ?? 60, 1), maxSearchResults)
        let includeGlob = arguments["include"]?.stringValue().flatMap { $0.isEmpty ? nil : $0 }

        guard let enumerator = FileManager.default.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw AgentToolError.notFound(searchRoot.path)
        }

        var matches: [String] = []
        var scanned = 0
        var visited = 0

        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited > maxToolTraversalNodes { break }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else {
                continue
            }
            if values.isDirectory == true {
                if ProjectDirectoryExclusions.shouldSkip(url) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            scanned += 1
            if scanned > maxScannedFiles { break }
            if let size = values.fileSize, size > maxFileSizeForSearch { continue }
            if let includeGlob, !globMatches(includeGlob, name: url.lastPathComponent) { continue }
            if AppState.isBinaryFile(at: url) { continue }

            guard let data = try? Data(contentsOf: url),
                  let content = String(data: data, encoding: .utf8) else {
                continue
            }

            let relativePath = relativePath(of: url, root: root)
            var lineNumber = 0
            for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
                lineNumber += 1
                let lineString = String(line)
                let range = NSRange(lineString.startIndex..<lineString.endIndex, in: lineString)
                if regex.firstMatch(in: lineString, options: [], range: range) != nil {
                    let snippet = lineString.prefix(200)
                    matches.append("\(relativePath):\(lineNumber): \(snippet)")
                    if matches.count >= limit { break }
                }
            }
            if matches.count >= limit { break }
        }

        let summary = "\(matches.count) match\(matches.count == 1 ? "" : "es") for /\(pattern)/"
        let payload = matches.isEmpty
            ? "No matches found for /\(pattern)/."
            : matches.joined(separator: "\n")
        return AgentToolResult(summary: summary, payload: payload)
    }

    static func readFile(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        if let backend = context.remoteBackend {
            return try await backend.readFile(arguments: arguments)
        }
        guard let root = context.rootDirectory else { throw AgentToolError.noWorkspace }
        guard let path = arguments["path"]?.stringValue(),
              !path.isEmpty else {
            throw AgentToolError.missingArgument("path")
        }

        let resolved = try resolveWorkspaceURL(path, root: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            throw AgentToolError.notFound(path)
        }
        guard !isDirectory.boolValue else {
            throw AgentToolError.notRegular(path)
        }
        if AppState.isBinaryFile(at: resolved) {
            throw AgentToolError.binaryFile(path)
        }

        let requested = arguments["max_bytes"]?.intValue() ?? defaultMaxReadBytes
        let limit = max(1, min(requested, absoluteMaxReadBytes))

        let handle = try FileHandle(forReadingFrom: resolved)
        defer { try? handle.close() }
        let data = handle.readData(ofLength: limit + 1)
        let truncated = data.count > limit
        let usable = truncated ? data.prefix(limit) : data
        let text = String(data: usable, encoding: .utf8) ?? AppState.decodeText(from: Data(usable))

        var numbered: [String] = []
        var lineNumber = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            numbered.append(String(format: "%5d  %@", lineNumber, String(line)))
        }
        if truncated {
            numbered.append("...[truncated, read \(limit) bytes]")
        }

        let summary = "\(path) (\(lineNumber) line\(lineNumber == 1 ? "" : "s"))"
        return AgentToolResult(summary: summary, payload: numbered.joined(separator: "\n"))
    }

    static func listDirectory(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        if let backend = context.remoteBackend {
            return try await backend.listDirectory(arguments: arguments)
        }
        guard let root = context.rootDirectory else { throw AgentToolError.noWorkspace }
        let rawPath = arguments["path"]?.stringValue() ?? ""
        let target: URL
        if rawPath.isEmpty {
            target = root
        } else {
            target = try resolveWorkspaceURL(rawPath, root: root)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            throw AgentToolError.notFound(rawPath.isEmpty ? "." : rawPath)
        }
        guard isDirectory.boolValue else {
            throw AgentToolError.notRegular(rawPath)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: target,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw AgentToolError.notFound(target.path)
        }

        var entries: [URL] = []
        var truncated = false
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                enumerator.skipDescendants()
                if ProjectDirectoryExclusions.shouldSkip(url) {
                    continue
                }
            }
            if entries.count >= maxDirectoryEntries {
                truncated = true
                break
            }
            entries.append(url)
        }

        let sorted = entries.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        var lines: [String] = []
        for url in sorted {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDir = values?.isDirectory ?? false
            let label = isDir ? "[dir]" : "[file]"
            let size = values?.fileSize.map { " \($0)B" } ?? ""
            lines.append("\(label) \(url.lastPathComponent)\(isDir ? "/" : size)")
        }
        if truncated {
            lines.append("...[truncated, more entries omitted]")
        }

        let countLabel = truncated ? "\(sorted.count)+" : "\(sorted.count)"
        let summary = "\(rawPath.isEmpty ? "." : rawPath) (\(countLabel) entr\(sorted.count == 1 && !truncated ? "y" : "ies"))"
        return AgentToolResult(summary: summary, payload: lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n"))
    }

    /// Compatibility alias for a `glob` tool some models hallucinate — they've
    /// seen `Glob` in other agent frameworks and call it even though WillDeep
    /// never advertises it. WillDeep's real search is `grep_files` /
    /// `list_directory` (ripgrep underneath). Rather than let a hallucinated
    /// `glob` fall through to the unknown-tool path — which the risk classifier
    /// flags as `.danger`, popping a typed "destructive command" confirm that
    /// would only `throw unknownTool` if confirmed — route it to a real,
    /// READ-ONLY workspace scan. Returns workspace files whose name matches the
    /// glob `pattern` (`*`/`**`, `?`, `[...]`, `{a,b}` via `globMatches`); the
    /// pattern's last path segment is used as the filename matcher, so
    /// `**/*.swift`, `src/**/*.ts`, and `*.swift` all behave as expected.
    static func glob(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let pattern = arguments["pattern"]?.stringValue(),
              !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.missingArgument("pattern")
        }
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)

        // No remote glob backend — steer to tools that do support remote.
        if context.remoteBackend != nil {
            return AgentToolResult(
                summary: "glob: use grep_files on remote",
                payload: "`glob` runs only against a local workspace. On this remote session use `grep_files` (its `include` argument is a glob filter) or `list_directory`. Pattern was: \(trimmed)"
            )
        }
        guard let root = context.rootDirectory else { throw AgentToolError.noWorkspace }
        let rootPath = root.standardizedFileURL.path

        // Absolute pattern pointing outside the workspace: don't open a hole in
        // the boundary every other file tool enforces. Skill files have their
        // own read-only tools, so route the common ~/.willdeep/skills case there.
        if (trimmed as NSString).isAbsolutePath {
            let prefix = URL(fileURLWithPath: globStaticPrefix(trimmed)).standardizedFileURL.path
            let inside = prefix == rootPath || prefix.hasPrefix(rootPath + "/") || rootPath.hasPrefix(prefix + "/")
            if !inside {
                let hint = trimmed.contains("/.willdeep/skills/")
                    ? " For skill files use `list_skills` / `read_skill`."
                    : ""
                return AgentToolResult(
                    summary: "glob: outside workspace",
                    payload: "`glob` only matches inside the current workspace (\(rootPath)); this pattern points outside it.\(hint) Pattern was: \(trimmed)"
                )
            }
        }

        // Match each workspace file's basename against the pattern's last
        // segment — covers the common `**/*.ext` / `*.ext` intent across all
        // depths. `globMatches` handles braces, char classes, `*` and `?`.
        let nameGlob = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        let limit = min(max(arguments["max_results"]?.intValue() ?? 200, 1), maxDirectoryEntries)

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw AgentToolError.notFound(rootPath)
        }

        var matches: [String] = []
        var visited = 0
        var truncated = false
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited > maxToolTraversalNodes { break }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if ProjectDirectoryExclusions.shouldSkip(url) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if globMatches(nameGlob, name: url.lastPathComponent) {
                matches.append(relativePath(of: url, root: root))
                if matches.count >= limit { truncated = true; break }
            }
        }
        matches.sort()

        let summary = "\(matches.count)\(truncated ? "+" : "") file\(matches.count == 1 && !truncated ? "" : "s") matching `\(nameGlob)`"
        let payload = matches.isEmpty
            ? "No files match `\(pattern)` in the workspace. (WillDeep has no native `glob`; this is a read-only alias over a workspace scan — `grep_files` / `list_directory` are the first-class tools.)"
            : matches.joined(separator: "\n") + (truncated ? "\n...[truncated, refine the pattern]" : "")
        return AgentToolResult(summary: summary, payload: payload)
    }

    /// The literal directory prefix of a glob pattern, up to the path segment
    /// that first contains a wildcard. `/a/b/**/*.swift` → `/a/b`.
    private static func globStaticPrefix(_ pattern: String) -> String {
        let wildcards: Set<Character> = ["*", "?", "[", "{"]
        var prefix = ""
        for ch in pattern {
            if wildcards.contains(ch) { break }
            prefix.append(ch)
        }
        if let slash = prefix.lastIndex(of: "/") { return String(prefix[..<slash]) }
        return prefix
    }

    static func gitStatus(context: AgentToolContext) async throws -> AgentToolResult {
        if let backend = context.remoteBackend {
            return try await backend.gitStatus()
        }
        guard let root = context.rootDirectory else { throw AgentToolError.noWorkspace }
        let status = AppState.loadGitStatus(for: root.standardizedFileURL)
        guard status.isRepository else {
            return AgentToolResult(summary: "not a git repository", payload: "The workspace is not inside a git repository.")
        }

        let branch = status.branchName ?? "detached"
        if status.entries.isEmpty {
            return AgentToolResult(
                summary: "branch \(branch), clean",
                payload: "Branch: \(branch)\nWorking tree clean."
            )
        }

        let lines = status.entries
            .sorted { $0.key < $1.key }
            .map { "\($0.value.rawValue) \($0.key)" }

        return AgentToolResult(
            summary: "branch \(branch), \(status.entries.count) change\(status.entries.count == 1 ? "" : "s")",
            payload: "Branch: \(branch)\n\(lines.joined(separator: "\n"))"
        )
    }

    /// Minimal shell-style glob matching against a single filename. Supports
    /// `*`, `?`, `[...]` character classes, and brace expansion (`{a,b}`).
    /// Used by `grep_files`'s `include` filter -- intentionally narrow.
    private static func globMatches(_ pattern: String, name: String) -> Bool {
        for expanded in expandBraces(pattern) {
            if fnmatch(expanded, name) { return true }
        }
        return false
    }

    private static func expandBraces(_ pattern: String) -> [String] {
        guard let openIndex = pattern.firstIndex(of: "{") else { return [pattern] }
        var depth = 0
        var closeIndex: String.Index?
        var index = openIndex
        while index < pattern.endIndex {
            let ch = pattern[index]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { closeIndex = index; break }
            }
            index = pattern.index(after: index)
        }
        guard let closeIndex else { return [pattern] }
        let prefix = String(pattern[..<openIndex])
        let suffix = String(pattern[pattern.index(after: closeIndex)...])
        let body = pattern[pattern.index(after: openIndex)..<closeIndex]
        let parts = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        var results: [String] = []
        for part in parts {
            for nested in expandBraces(prefix + part + suffix) {
                results.append(nested)
            }
        }
        return results
    }

    private static func fnmatch(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern)
        let s = Array(name)
        return fnmatchRecursive(p, 0, s, 0)
    }

    private static func fnmatchRecursive(_ p: [Character], _ pi: Int, _ s: [Character], _ si: Int) -> Bool {
        var pi = pi
        var si = si
        while pi < p.count {
            let pc = p[pi]
            if pc == "*" {
                while pi + 1 < p.count, p[pi + 1] == "*" { pi += 1 }
                if pi == p.count - 1 { return true }
                for k in si...s.count where fnmatchRecursive(p, pi + 1, s, k) { return true }
                return false
            }
            if si >= s.count { return false }
            if pc == "?" {
                pi += 1; si += 1; continue
            }
            if pc == "[" {
                guard let end = p[pi...].firstIndex(of: "]") else { return false }
                let group = Array(p[(pi + 1)..<end])
                var matched = false
                var negated = false
                var i = 0
                if !group.isEmpty, group[0] == "!" { negated = true; i = 1 }
                while i < group.count {
                    if i + 2 < group.count, group[i + 1] == "-" {
                        if s[si] >= group[i], s[si] <= group[i + 2] { matched = true }
                        i += 3
                    } else {
                        if s[si] == group[i] { matched = true }
                        i += 1
                    }
                }
                if matched == negated { return false }
                pi = end + 1; si += 1; continue
            }
            if pc != s[si] { return false }
            pi += 1; si += 1
        }
        return si == s.count
    }

    private static func resolveWorkspaceURL(_ path: String, root: URL) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let url: URL
        if (trimmed as NSString).isAbsolutePath {
            url = URL(fileURLWithPath: trimmed).standardizedFileURL
        } else {
            url = root.appendingPathComponent(trimmed).standardizedFileURL
        }
        let rootPath = root.standardizedFileURL.path
        let candidatePath = url.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw AgentToolError.pathOutsideWorkspace(path)
        }
        return url
    }

    private static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
