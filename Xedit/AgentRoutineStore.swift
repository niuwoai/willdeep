//
//  AgentRoutineStore.swift
//  WillDeep
//
//  Persists user-defined Agent routines as JSON files under the app's
//  Application Support directory. One file per routine — same shape as
//  AgentSessionStore so corrupt files only take themselves down.
//

import Foundation

enum AgentRoutineStore {
    /// Disk location for routine JSON files. Created lazily.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WillDeep", isDirectory: true)
            .appendingPathComponent("agent-routines", isDirectory: true)
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

    /// Load every routine on disk, most-recently-updated first. Unreadable
    /// files are skipped (and logged) so one bad file doesn't take down
    /// the whole list.
    static func loadAll() -> [AgentRoutine] {
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

        var routines: [AgentRoutine] = []
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                routines.append(try decoder.decode(AgentRoutine.self, from: data))
            } catch {
                print("AgentRoutineStore: skipping unreadable routine at \(url.lastPathComponent): \(error)")
            }
        }
        return routines.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    static func save(_ routine: AgentRoutine) -> Bool {
        do {
            try ensureDirectory()
            let url = directory.appendingPathComponent("\(routine.id.uuidString).json")
            let data = try encoder.encode(routine)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            print("AgentRoutineStore: failed to save routine \(routine.id): \(error)")
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
            print("AgentRoutineStore: failed to delete routine \(id): \(error)")
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
}
