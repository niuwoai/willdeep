//
//  AgentAttachmentContentStore.swift
//  WillDeep
//
//  Content-addressed disk storage for the full extracted text of parsed
//  document attachments. Session JSON keeps only lightweight per-section
//  metadata plus a path/hash reference into this store, so a knowledge
//  folder with hundreds of large documents no longer keeps every extracted
//  character resident in memory or re-encodes it on every session persist.
//

import CryptoKit
import Foundation

nonisolated enum AgentAttachmentContentStore {
    /// Test seam: when set, content files live under this directory instead
    /// of Application Support. Set once before exercising the store.
    nonisolated(unsafe) static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WillDeep", isDirectory: true)
            .appendingPathComponent("agent-attachment-content", isDirectory: true)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Writes the sections to a content-addressed file. Identical content
    /// (same document parsed again, same folder attached in another session)
    /// maps to the same file, so re-indexing an unchanged document and
    /// sharing a folder across sessions never duplicates bytes on disk.
    static func store(sections: [AgentAttachmentSection]) throws -> (filePath: String, sha256: String) {
        let data = try encoder.encode(sections)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let url = directory.appendingPathComponent("\(digest).json", isDirectory: false)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        }
        return (url.standardizedFileURL.path, digest)
    }

    static func loadSections(atPath path: String) -> [AgentAttachmentSection]? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: trimmed)
        guard let data = try? Data(contentsOf: url) else {
            print("AgentAttachmentContentStore: missing content file at \(trimmed)")
            return nil
        }
        do {
            return try JSONDecoder().decode([AgentAttachmentSection].self, from: data)
        } catch {
            print("AgentAttachmentContentStore: failed to decode content file at \(trimmed): \(error)")
            return nil
        }
    }

    /// Deletes content files no session references anymore. Only files older
    /// than `minimumAge` are considered: a file written moments ago by a
    /// concurrent index run may not be referenced by any *persisted* session
    /// yet, and the age guard keeps it safe until its session JSON lands.
    @discardableResult
    static func removeUnreferencedFiles(
        referencedPaths: Set<String>,
        minimumAge: TimeInterval = 14 * 24 * 3600,
        now: Date = Date()
    ) -> Int {
        let normalizedReferences = Set(
            referencedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        )
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var removed = 0
        for url in entries where url.pathExtension == "json" {
            let standardized = url.standardizedFileURL
            guard !normalizedReferences.contains(standardized.path) else { continue }
            let modifiedAt = (try? standardized.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            guard now.timeIntervalSince(modifiedAt) >= minimumAge else { continue }
            do {
                try FileManager.default.removeItem(at: standardized)
                removed += 1
            } catch {
                print("AgentAttachmentContentStore: failed to remove unreferenced \(standardized.lastPathComponent): \(error)")
            }
        }
        return removed
    }
}
