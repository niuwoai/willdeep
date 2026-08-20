//
//  AgentRoutineStore.swift
//  WillDeep
//
//  Persists user-defined Agent routines as JSON files under the app's
//  Application Support directory. One file per routine — same shape as
//  AgentSessionStore so corrupt files only take themselves down.
//

import Foundation

/// How one scheduled-routine run ended.
///
/// Before this existed a run record held only `startedAt`, so the Automations
/// page could say a job had fired but never whether it worked — a routine that
/// died on a dead network looked exactly like one that produced a full report.
nonisolated enum AgentRoutineRunOutcome: String, Codable, Equatable, Sendable {
    /// The turn is still in flight.
    case running
    /// The turn finished and the assistant actually said something.
    case succeeded
    /// The turn ended on an error. `failureMessage` carries the banner text.
    case failed
    /// The turn ended without a reply and without an error — a user Stop, or
    /// an app exit that orphaned the run. Recorded at load time for `running`
    /// records left behind by a previous launch: the process that owned them
    /// is gone, so nothing will ever finish them.
    case interrupted
    /// Written before outcomes were recorded. Rendered without a verdict
    /// rather than guessed at.
    case unknown
}

nonisolated struct AgentRoutineRunRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let routineID: UUID
    let routineName: String
    let sessionID: UUID
    let startedAt: Date
    var finishedAt: Date?
    var outcome: AgentRoutineRunOutcome
    /// One-line reason for `.failed`, mirroring the session's error banner.
    var failureMessage: String?

    init(
        id: UUID = UUID(),
        routineID: UUID,
        routineName: String,
        sessionID: UUID,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        outcome: AgentRoutineRunOutcome = .running,
        failureMessage: String? = nil
    ) {
        self.id = id
        self.routineID = routineID
        self.routineName = routineName
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.failureMessage = failureMessage
    }

    enum CodingKeys: String, CodingKey {
        case id, routineID, routineName, sessionID, startedAt
        case finishedAt, outcome, failureMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.routineID = try c.decode(UUID.self, forKey: .routineID)
        self.routineName = try c.decode(String.self, forKey: .routineName)
        self.sessionID = try c.decode(UUID.self, forKey: .sessionID)
        self.startedAt = try c.decode(Date.self, forKey: .startedAt)
        self.finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        // Records written before outcomes existed get `.unknown`, not a
        // flattering guess — history that invents verdicts is worse than
        // history that admits it does not know.
        self.outcome = try c.decodeIfPresent(AgentRoutineRunOutcome.self, forKey: .outcome) ?? .unknown
        self.failureMessage = try c.decodeIfPresent(String.self, forKey: .failureMessage)
    }
}

enum AgentRoutineRunHistory {
    static let maximumStoredRuns = 100
    static let defaultVisibleRuns = 12

    static func recent(
        _ records: [AgentRoutineRunRecord],
        limit: Int = defaultVisibleRuns
    ) -> [AgentRoutineRunRecord] {
        guard limit > 0 else { return [] }
        return Array(records.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }

    /// A run still marked `running` on disk belongs to a process that no
    /// longer exists — this launch will never receive its completion. Settle
    /// it as interrupted so the page stops showing a three-day-old job as
    /// currently working. Called once, on load.
    static func reconcilingRunsOrphanedByPreviousLaunch(
        _ records: [AgentRoutineRunRecord]
    ) -> [AgentRoutineRunRecord] {
        records.map { record in
            guard record.outcome == .running else { return record }
            var settled = record
            settled.outcome = .interrupted
            settled.finishedAt = record.finishedAt ?? record.startedAt
            return settled
        }
    }
}

enum AgentRoutineStore {
    /// Test seam: when set, routine JSON lives here instead of Application
    /// Support. Set it before the store is first touched in a test.
    nonisolated(unsafe) static var directoryOverride: URL?

    /// The shipping location, never redirected.
    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WillDeep", isDirectory: true)
            .appendingPathComponent("agent-routines", isDirectory: true)
    }

    /// Every test process gets a throwaway routine library, for the same
    /// reason `AgentSessionStore` does: tests build `AppState`, which loads
    /// routines and run history and can write both back. Pointed at the real
    /// directory that rewrites the user's actual automations and their run
    /// history. Redirecting the whole process is the only version of this a
    /// newly added test cannot get wrong.
    private static let testSandboxDirectory: URL? = {
        let environment = ProcessInfo.processInfo.environment
        let underTest = NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest") != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        guard underTest else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WillDeepTests-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
            .appendingPathComponent("agent-routines", isDirectory: true)
    }()

    /// Disk location for routine JSON files. Created lazily.
    static var directory: URL {
        directoryOverride ?? testSandboxDirectory ?? applicationSupportDirectory
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

enum AgentRoutineRunStore {
    private static var fileURL: URL {
        AgentRoutineStore.directory
            .appendingPathComponent("run-history", isDirectory: true)
            .appendingPathComponent("recent-runs.json")
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

    static func loadAll() -> [AgentRoutineRunRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? decoder.decode([AgentRoutineRunRecord].self, from: data) else {
            return []
        }
        return AgentRoutineRunHistory.recent(records, limit: AgentRoutineRunHistory.maximumStoredRuns)
    }

    @discardableResult
    static func save(_ records: [AgentRoutineRunRecord]) -> Bool {
        do {
            let retained = AgentRoutineRunHistory.recent(
                records,
                limit: AgentRoutineRunHistory.maximumStoredRuns
            )
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(retained).write(to: fileURL, options: .atomic)
            return true
        } catch {
            print("AgentRoutineRunStore: failed to save run history: \(error)")
            return false
        }
    }
}
