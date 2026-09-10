import Foundation

/// Packs the evidence for "why was it slow" into one zip the user can look at
/// before sending it anywhere.
///
/// The shape of this feature is set by one fact about the logs: the file that
/// actually answers the question carries no user content. `worker-timing.jsonl`
/// records, per turn, how long the host spent before the first request, how
/// long until the first token, and how long until the first tool boundary —
/// identifiers, timestamps and counts, no prompt or output text. So the
/// default bundle is provably content-free, and a customer can hand it over
/// without having to trust a redaction pass.
///
/// The other two logs are the opposite. `sandbox.jsonl` stores the command
/// string itself and `judge.jsonl` its first 400 characters, and neither
/// records a session id — only a timestamp — so they can be narrowed to a
/// time window but never cut cleanly along a conversation. They ride along
/// only in the full level, which the user has to ask for.
nonisolated enum AgentDiagnosticsBundle {
    /// How much of the user's own material goes in the zip.
    enum Level: String, CaseIterable, Identifiable, Sendable {
        /// Manifest plus the timing lines for the selected sessions. No
        /// conversation, no command text.
        case timingOnly
        /// Adds the session records themselves and the sandbox/judge lines
        /// that fall inside the selected sessions' time window.
        case full

        var id: String { rawValue }
        var includesUserContent: Bool { self == .full }
    }

    /// Everything the picker shows before a single byte is written. The
    /// export screen states the counts rather than packing quietly: a person
    /// deciding whether to send logs to a vendor is entitled to know what is
    /// in the envelope.
    struct Preview: Equatable, Sendable {
        var sessionCount = 0
        var timingLineCount = 0
        var sandboxLineCount = 0
        var judgeLineCount = 0
        var sessionByteCount = 0
        var windowStart: Date?
        var windowEnd: Date?
        var includesUserContent = false
    }

    struct Manifest: Codable, Equatable, Sendable {
        var generatedAt: Date
        var appVersion: String
        var appBuild: String
        var systemVersion: String
        var level: String
        var includesUserContent: Bool
        var sessionIDs: [String]
        var windowStart: Date?
        var windowEnd: Date?
        var timingLineCount: Int
        var sandboxLineCount: Int
        var judgeLineCount: Int
        /// Spelled out in the manifest so whoever opens the zip does not have
        /// to infer the privacy story from the file list.
        var contents: [String]
    }

    // MARK: - Pure filtering

    private struct SessionKeyed: Decodable { let sessionID: UUID }
    private struct Stamped: Decodable { let timestamp: Date }

    private static var lineDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Timing lines belonging to any of `sessionIDs`. Both entry kinds in
    /// that log carry `sessionID`, so this cut is exact — unlike the window
    /// cut below.
    static func timingLines(in lines: [String], sessionIDs: Set<UUID>) -> [String] {
        let decoder = lineDecoder
        return lines.filter { line in
            guard let data = line.data(using: .utf8),
                  let keyed = try? decoder.decode(SessionKeyed.self, from: data) else { return false }
            return sessionIDs.contains(keyed.sessionID)
        }
    }

    /// Lines whose `timestamp` falls inside `window`. Used for the two logs
    /// that record no session id. Deliberately inclusive at both ends: a tool
    /// call that started on the boundary is part of the story.
    static func windowedLines(in lines: [String], window: ClosedRange<Date>) -> [String] {
        let decoder = lineDecoder
        return lines.filter { line in
            guard let data = line.data(using: .utf8),
                  let stamped = try? decoder.decode(Stamped.self, from: data) else { return false }
            return window.contains(stamped.timestamp)
        }
    }

    /// The span the selected sessions cover, padded by a minute on each side
    /// so a tool call that outlived its turn is not clipped off. Nil when no
    /// session carries usable timestamps.
    static func window(createdAt: [Date], updatedAt: [Date], padding: TimeInterval = 60) -> ClosedRange<Date>? {
        let all = createdAt + updatedAt
        guard let low = all.min(), let high = all.max() else { return nil }
        return low.addingTimeInterval(-padding)...high.addingTimeInterval(padding)
    }

    /// Split a `.jsonl` file into lines, dropping the blank tail. Kept here
    /// rather than at each call site so an empty or missing log reads as
    /// "no lines" instead of throwing.
    static func lines(ofFileAt url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

// MARK: - Building the bundle

extension AgentDiagnosticsBundle {
    /// One selected conversation, reduced to what the bundle needs. Kept
    /// separate from `AgentSession` so the builder and its tests never have
    /// to construct a whole session.
    struct SessionRef: Equatable, Sendable {
        let id: UUID
        let createdAt: Date
        let updatedAt: Date

        init(id: UUID, createdAt: Date, updatedAt: Date) {
            self.id = id
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    struct Input: Sendable {
        var sessions: [SessionRef]
        var level: Level
        var auditDirectory: URL
        var sessionsDirectory: URL
        var appVersion: String
        var appBuild: String
        var systemVersion: String
    }

    static let timingLogName = "worker-timing.jsonl"
    static let rotatedTimingLogName = "worker-timing.1.jsonl"
    static let sandboxLogName = "sandbox.jsonl"
    static let judgeLogName = "judge.jsonl"

    /// Timing lines from both the live log and the rotated one. A slow turn
    /// from this morning can easily sit on the far side of a rotation, and a
    /// bundle that silently missed it would be worse than an empty one.
    private static func allTimingLines(in directory: URL) -> [String] {
        lines(ofFileAt: directory.appendingPathComponent(rotatedTimingLogName))
            + lines(ofFileAt: directory.appendingPathComponent(timingLogName))
    }

    private static func sessionFileURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// What the export screen states before anything is written.
    static func preview(for input: Input) -> Preview {
        var preview = Preview()
        preview.sessionCount = input.sessions.count
        preview.includesUserContent = input.level.includesUserContent
        let ids = Set(input.sessions.map(\.id))
        preview.timingLineCount = timingLines(
            in: allTimingLines(in: input.auditDirectory), sessionIDs: ids
        ).count

        let span = window(
            createdAt: input.sessions.map(\.createdAt),
            updatedAt: input.sessions.map(\.updatedAt)
        )
        preview.windowStart = span?.lowerBound
        preview.windowEnd = span?.upperBound

        guard input.level == .full else { return preview }
        if let span {
            preview.sandboxLineCount = windowedLines(
                in: lines(ofFileAt: input.auditDirectory.appendingPathComponent(sandboxLogName)),
                window: span
            ).count
            preview.judgeLineCount = windowedLines(
                in: lines(ofFileAt: input.auditDirectory.appendingPathComponent(judgeLogName)),
                window: span
            ).count
        }
        preview.sessionByteCount = input.sessions.reduce(0) { total, session in
            let url = sessionFileURL(session.id, in: input.sessionsDirectory)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
            return total + (size ?? 0)
        }
        return preview
    }

    /// Stage the bundle into `stagingDirectory` and return the files written,
    /// relative to it. Split out from the zip step so tests can inspect the
    /// contents without shelling out.
    @discardableResult
    static func stage(_ input: Input, into stagingDirectory: URL) throws -> [String] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        var written: [String] = []
        let ids = Set(input.sessions.map(\.id))
        let span = window(
            createdAt: input.sessions.map(\.createdAt),
            updatedAt: input.sessions.map(\.updatedAt)
        )

        let timing = timingLines(in: allTimingLines(in: input.auditDirectory), sessionIDs: ids)
        if !timing.isEmpty {
            try (timing.joined(separator: "\n") + "\n")
                .write(to: stagingDirectory.appendingPathComponent(timingLogName), atomically: true, encoding: .utf8)
            written.append(timingLogName)
        }

        var sandboxCount = 0
        var judgeCount = 0
        if input.level == .full {
            if let span {
                for name in [sandboxLogName, judgeLogName] {
                    let selected = windowedLines(
                        in: lines(ofFileAt: input.auditDirectory.appendingPathComponent(name)),
                        window: span
                    )
                    guard !selected.isEmpty else { continue }
                    try (selected.joined(separator: "\n") + "\n")
                        .write(to: stagingDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
                    written.append(name)
                    if name == sandboxLogName { sandboxCount = selected.count } else { judgeCount = selected.count }
                }
            }
            let sessionsOut = stagingDirectory.appendingPathComponent("sessions", isDirectory: true)
            var copiedAny = false
            for session in input.sessions {
                let source = sessionFileURL(session.id, in: input.sessionsDirectory)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                if !copiedAny {
                    try fileManager.createDirectory(at: sessionsOut, withIntermediateDirectories: true)
                    copiedAny = true
                }
                let destination = sessionsOut.appendingPathComponent(source.lastPathComponent)
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: source, to: destination)
                written.append("sessions/\(source.lastPathComponent)")
            }
        }

        let manifest = Manifest(
            generatedAt: Date(),
            appVersion: input.appVersion,
            appBuild: input.appBuild,
            systemVersion: input.systemVersion,
            level: input.level.rawValue,
            includesUserContent: input.level.includesUserContent,
            sessionIDs: input.sessions.map { $0.id.uuidString },
            windowStart: span?.lowerBound,
            windowEnd: span?.upperBound,
            timingLineCount: timing.count,
            sandboxLineCount: sandboxCount,
            judgeLineCount: judgeCount,
            contents: written
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest)
            .write(to: stagingDirectory.appendingPathComponent("manifest.json"))
        written.append("manifest.json")
        return written
    }

    /// Suggested file name. Dated and level-tagged so two exports from the
    /// same machine never collide in a mailbox.
    static func suggestedFileName(level: Level, at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = level == .timingOnly ? "timing" : "full"
        return "willdeep-diagnostics-\(suffix)-\(formatter.string(from: date)).zip"
    }
}
