//
//  AgentRipgrepSearch.swift
//  WillDeep
//
//  Fast local search backend for AgentFileTools. The public file tools keep
//  their Swift scanner as a compatibility fallback when rg is unavailable or
//  cannot parse an ICU-compatible regular expression.
//

import Foundation

nonisolated enum AgentRipgrepSearch {
    enum SearchPattern: Sendable {
        case literal(String)
        case regularExpression(String)
    }

    private static let knownExecutablePaths = [
        "/opt/homebrew/bin/rg",
        "/usr/local/bin/rg",
        "/usr/bin/rg"
    ]

    static func search(
        root: URL,
        searchRoot: URL,
        pattern: SearchPattern,
        caseSensitive: Bool,
        includeGlob: String?,
        limit: Int
    ) -> [String]? {
        guard let executableURL = locateExecutable() else { return nil }
        return search(
            executableURL: executableURL,
            root: root,
            searchRoot: searchRoot,
            pattern: pattern,
            caseSensitive: caseSensitive,
            includeGlob: includeGlob,
            limit: limit
        )
    }

    static func locateExecutable() -> URL? {
        locateExecutable(
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"],
            knownPaths: knownExecutablePaths
        )
    }

    static func locateExecutable(
        pathEnvironment: String?,
        knownPaths: [String]
    ) -> URL? {
        let pathCandidates = (pathEnvironment ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("rg").path }
        for path in pathCandidates + knownPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func search(
        executableURL: URL,
        root: URL,
        searchRoot: URL,
        pattern: SearchPattern,
        caseSensitive: Bool,
        includeGlob: String?,
        limit: Int
    ) -> [String]? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.currentDirectoryURL = root
        process.arguments = arguments(
            root: root,
            searchRoot: searchRoot,
            pattern: pattern,
            caseSensitive: caseSensitive,
            includeGlob: includeGlob
        )
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let matches = readMatches(
            from: outputPipe.fileHandleForReading,
            process: process,
            limit: limit
        )
        process.waitUntilExit()
        if matches.count >= limit {
            return Array(matches.prefix(limit))
        }
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 || process.terminationStatus == 1 else {
            return nil
        }
        return matches
    }

    private static func arguments(
        root: URL,
        searchRoot: URL,
        pattern: SearchPattern,
        caseSensitive: Bool,
        includeGlob: String?
    ) -> [String] {
        var result = [
            "--json",
            "--no-config",
            "--no-messages",
            "--no-ignore",
            "--max-filesize", "512K",
            "--color", "never"
        ]
        if !caseSensitive {
            result.append("--ignore-case")
        }
        switch pattern {
        case .literal:
            result.append("--fixed-strings")
        case .regularExpression:
            result.append(contentsOf: ["--engine", "auto"])
        }
        if let includeGlob, !includeGlob.isEmpty {
            let basenameGlob = includeGlob.split(separator: "/").last.map(String.init) ?? includeGlob
            result.append(contentsOf: ["--glob", basenameGlob])
        }
        for name in ProjectDirectoryExclusions.names.sorted() {
            result.append(contentsOf: ["--glob", "!**/\(name)/**"])
        }
        result.append(contentsOf: ["--glob", "!**/bazel-*/**"])
        result.append("--")
        switch pattern {
        case .literal(let value), .regularExpression(let value):
            result.append(value)
        }
        result.append(relativeSearchPath(searchRoot, root: root))
        return result
    }

    private static func readMatches(
        from handle: FileHandle,
        process: Process,
        limit: Int
    ) -> [String] {
        var matches: [String] = []
        var buffer = Data()
        var didTerminate = false

        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            consumeCompleteLines(from: &buffer, matches: &matches, limit: limit)
            if matches.count >= limit, !didTerminate {
                didTerminate = true
                process.terminate()
            }
        }
        if matches.count < limit, !buffer.isEmpty {
            appendMatch(from: buffer, to: &matches, limit: limit)
        }
        return matches
    }

    private static func consumeCompleteLines(
        from buffer: inout Data,
        matches: inout [String],
        limit: Int
    ) {
        while matches.count < limit, let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            appendMatch(from: line, to: &matches, limit: limit)
        }
    }

    private static func appendMatch(
        from line: Data,
        to matches: inout [String],
        limit: Int
    ) {
        guard matches.count < limit,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "match",
              let data = object["data"] as? [String: Any],
              let path = (data["path"] as? [String: Any])?["text"] as? String,
              let lineNumber = data["line_number"] as? Int,
              let text = (data["lines"] as? [String: Any])?["text"] as? String else {
            return
        }
        let snippet = text.trimmingCharacters(in: .newlines).prefix(200)
        matches.append("\(path):\(lineNumber): \(snippet)")
    }

    private static func relativeSearchPath(_ searchRoot: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let searchPath = searchRoot.standardizedFileURL.path
        guard searchPath != rootPath, searchPath.hasPrefix(rootPath + "/") else {
            return "."
        }
        return String(searchPath.dropFirst(rootPath.count + 1))
    }
}
