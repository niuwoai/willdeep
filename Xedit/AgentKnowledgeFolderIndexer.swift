//
//  AgentKnowledgeFolderIndexer.swift
//  WillDeep
//
//  Safe, bounded local indexing for session-scoped knowledge folders.
//

import Foundation

nonisolated struct AgentKnowledgeFolderIndexResult: Sendable {
    let documents: [AgentFileAttachment]
    let skippedFileCount: Int
}

nonisolated enum AgentKnowledgeFolderIndexer {
    private static let maximumDocumentCount = 250
    private static let maximumTotalBytes: Int64 = 80 * 1_024 * 1_024
    private static let maximumTraversalNodes = 50_000
    private static let excludedDirectoryNames: Set<String> = [
        ".git", ".svn", ".hg", ".build", ".swiftpm", "build", "dist",
        "deriveddata", "node_modules", "pods", "vendor", "target", "coverage"
    ]
    private static let sensitiveFileNames: Set<String> = [
        "id_rsa", "id_ed25519", "credentials", "credentials.json",
        "secrets.json", "service-account.json"
    ]
    private static let sensitiveExtensions: Set<String> = [
        "key", "pem", "p12", "pfx", "mobileprovision", "keystore"
    ]

    static func index(
        folderURL: URL,
        existingDocuments: [AgentFileAttachment],
        excludedPatterns: [String]
    ) async -> AgentKnowledgeFolderIndexResult {
        let scan = await Task.detached(priority: .utility) {
            scanCandidates(folderURL: folderURL, excludedPatterns: excludedPatterns)
        }.value
        let existingByPath = Dictionary(uniqueKeysWithValues: existingDocuments.map { ($0.url.standardizedFileURL.path, $0) })
        var documents: [AgentFileAttachment] = []
        var skipped = scan.skippedFileCount

        for candidate in scan.candidates {
            guard !Task.isCancelled else { break }
            if let existing = existingByPath[candidate.url.path],
               existing.parseStatus == .ready,
               existing.sourceFileSize == candidate.size,
               existing.sourceModifiedAt == candidate.modifiedAt {
                documents.append(existing)
                continue
            }

            var attachment = AgentFileAttachment(
                url: candidate.url,
                relativePath: folderURL.lastPathComponent + "/" + candidate.relativePath
            )
            attachment.sourceFileSize = candidate.size
            attachment.sourceModifiedAt = candidate.modifiedAt
            do {
                attachment.analysis = try await AgentDocumentAttachmentParser.analyze(url: candidate.url)
                attachment.parseStatus = .ready
            } catch {
                attachment.parseStatus = .failed
                attachment.parseError = error.localizedDescription
                skipped += 1
            }
            documents.append(attachment)
        }

        return AgentKnowledgeFolderIndexResult(
            documents: documents,
            skippedFileCount: skipped
        )
    }

    static func shouldExclude(relativePath: String, customPatterns: [String], gitIgnoreText: String) -> Bool {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        var excluded = false
        let patterns = parsedPatterns(gitIgnoreText) + customPatterns
        for rawPattern in patterns {
            var pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty, !pattern.hasPrefix("#") else { continue }
            let isNegated = pattern.hasPrefix("!")
            if isNegated { pattern.removeFirst() }
            guard !pattern.isEmpty else { continue }
            if matches(normalized, pattern: pattern) {
                excluded = !isNegated
            }
        }
        return excluded
    }

    private static func scanCandidates(
        folderURL: URL,
        excludedPatterns: [String]
    ) -> (candidates: [Candidate], skippedFileCount: Int) {
        let root = folderURL.standardizedFileURL
        let gitIgnoreURL = root.appendingPathComponent(".gitignore")
        let gitIgnoreText = (try? String(contentsOf: gitIgnoreURL, encoding: .utf8)) ?? ""
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return ([], 0)
        }

        var candidates: [Candidate] = []
        var skipped = 0
        var totalBytes: Int64 = 0
        var visitedNodes = 0
        let rootPath = root.path

        while let url = enumerator.nextObject() as? URL {
            visitedNodes += 1
            if visitedNodes > maximumTraversalNodes || Task.isCancelled {
                skipped += 1
                break
            }
            let values = try? url.resourceValues(forKeys: resourceKeys)
            let relativePath = String(url.standardizedFileURL.path.dropFirst(rootPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let lowerName = url.lastPathComponent.lowercased()

            if values?.isDirectory == true {
                if excludedDirectoryNames.contains(lowerName)
                    || shouldExclude(relativePath: relativePath + "/", customPatterns: excludedPatterns, gitIgnoreText: gitIgnoreText) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true else { continue }
            guard !isSensitiveFile(url) else {
                skipped += 1
                continue
            }
            guard !shouldExclude(relativePath: relativePath, customPatterns: excludedPatterns, gitIgnoreText: gitIgnoreText) else {
                skipped += 1
                continue
            }
            guard AgentComposerAttachmentSupport.isSupportedDocument(url) else { continue }

            let size = Int64(values?.fileSize ?? 0)
            guard size <= Int64(AgentComposerAttachmentSupport.maxDocumentBytes),
                  candidates.count < maximumDocumentCount,
                  totalBytes + size <= maximumTotalBytes else {
                skipped += 1
                continue
            }
            totalBytes += size
            candidates.append(
                Candidate(
                    url: url.standardizedFileURL,
                    relativePath: relativePath,
                    size: size,
                    modifiedAt: values?.contentModificationDate
                )
            )
            if candidates.count >= maximumDocumentCount { break }
        }

        return (
            candidates.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending },
            skipped
        )
    }

    private static func isSensitiveFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name == ".env" || name.hasPrefix(".env.") || sensitiveFileNames.contains(name) {
            return true
        }
        return sensitiveExtensions.contains(url.pathExtension.lowercased())
    }

    private static func parsedPatterns(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
    }

    private static func matches(_ path: String, pattern rawPattern: String) -> Bool {
        var pattern = rawPattern.replacingOccurrences(of: "\\", with: "/")
        let anchored = pattern.hasPrefix("/")
        if anchored { pattern.removeFirst() }
        let directoryPattern = pattern.hasSuffix("/")
        if directoryPattern { pattern.removeLast() }

        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*\\*", with: ".*")
            .replacingOccurrences(of: "\\*", with: "[^/]*")
            .replacingOccurrences(of: "\\?", with: "[^/]")
        let prefix = anchored ? "^" : "(?:^|.*/)"
        let suffix = directoryPattern ? "(?:/.*)?$" : "$"
        guard let regex = try? NSRegularExpression(pattern: prefix + escaped + suffix) else { return false }
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return regex.firstMatch(in: path, range: range) != nil
    }

    private struct Candidate: Sendable {
        let url: URL
        let relativePath: String
        let size: Int64
        let modifiedAt: Date?
    }
}
