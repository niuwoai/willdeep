//
//  AgentSessionStore.swift
//  VeilWriter
//
//  Persists Agent-mode chat sessions as JSON files under the app's
//  Application Support directory. One file per session.
//

import Foundation

enum AgentSessionStore {
    /// Disk location for session JSON files. Created lazily.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("VeilWriter", isDirectory: true)
            .appendingPathComponent("agent-sessions", isDirectory: true)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Loads every session on disk, newest-updated first. Files that fail
    /// to decode are skipped (and logged via `print`) so a single corrupt
    /// file doesn't take down the whole list.
    static func loadAll() -> [AgentSession] {
        let dir = directory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var sessions: [AgentSession] = []
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                sessions.append(try decoder.decode(AgentSession.self, from: data))
            } catch {
                print("AgentSessionStore: skipping unreadable session at \(url.lastPathComponent): \(error)")
            }
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    static func save(_ session: AgentSession) -> Bool {
        do {
            try ensureDirectory()
            let url = directory.appendingPathComponent("\(session.id.uuidString).json")
            let data = try encoder.encode(session)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            print("AgentSessionStore: failed to save session \(session.id): \(error)")
            return false
        }
    }

    @discardableResult
    static func delete(id: UUID) -> Bool {
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return true
        } catch {
            print("AgentSessionStore: failed to delete session \(id): \(error)")
            return false
        }
    }

    private static func ensureDirectory() throws {
        let dir = directory
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Derive a short, human-readable title from the first user message.
    static func deriveTitle(from messages: [AgentMessage]) -> String {
        guard let firstUser = messages.first(where: { $0.role == .user }) else {
            return "New Chat"
        }
        let text = firstUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, let firstAttachment = firstUser.textAttachments.first {
            return firstAttachment.displayName
        }
        guard !text.isEmpty else { return "New Chat" }
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        if oneLine.count <= 40 { return oneLine }
        return String(oneLine.prefix(40)) + "…"
    }
}
