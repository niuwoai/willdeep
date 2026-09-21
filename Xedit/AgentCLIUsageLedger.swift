//
//  AgentCLIUsageLedger.swift
//  WillDeep
//
//  Read-only consumer of the willdeep-rs usage ledger
//  (`willdeep.usage-ledger.v1`, see docs/USAGE_LEDGER_DESIGN.md).
//

import Foundation

/// Which client produced a model call. The desktop side is everything the app
/// records in its own sessions; the CLI side is the rs ledger.
nonisolated enum AgentUsageSource: String, Codable, CaseIterable, Hashable, Sendable {
    case desktop
    case cli
}

/// The heatmap's 全部 / 桌面 / CLI switch.
nonisolated enum AgentUsageSourceFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case desktop
    case cli

    var id: String { rawValue }

    func includes(_ source: AgentUsageSource) -> Bool {
        switch self {
        case .all: return true
        case .desktop: return source == .desktop
        case .cli: return source == .cli
        }
    }
}

/// One model call recorded by the CLI. Only counts and identifiers — the
/// ledger carries no prompt, reply or tool content by contract (§7).
nonisolated struct AgentCLIUsageRecord: Equatable, Identifiable, Sendable {
    static let schema = "willdeep.usage-ledger.v1"

    let id: UUID
    let timestamp: Date
    let client: String
    let kind: String
    let sessionID: String?
    let providerID: String?
    let modelID: String?
    let isLocal: Bool
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let latencySeconds: Double?
    let succeeded: Bool

    /// Tokens this call counts toward the dashboards: the provider's total
    /// when reported, otherwise input + output. Never estimated — a call the
    /// provider reported no usage for still counts as a request, with zero
    /// tokens.
    var countedTokens: Int {
        if let totalTokens, totalTokens > 0 { return totalTokens }
        return max(0, inputTokens ?? 0) + max(0, outputTokens ?? 0)
    }

    /// Decodes one ledger line. Returns nil for anything that is not a
    /// complete, recognizable v1 record, so a corrupt or future-format line
    /// is skipped instead of poisoning the whole file.
    static func decode(line: Data) -> AgentCLIUsageRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["schema"] as? String == schema,
              let idString = object["id"] as? String,
              let id = UUID(uuidString: idString),
              let tsString = object["ts"] as? String,
              let timestamp = parseTimestamp(tsString) else {
            return nil
        }
        func string(_ key: String) -> String? {
            guard let value = object[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func integer(_ key: String) -> Int? {
            (object[key] as? NSNumber).map { max(0, $0.intValue) }
        }
        let latencySeconds = (object["latency_ms"] as? NSNumber).map { $0.doubleValue / 1_000 }
        return AgentCLIUsageRecord(
            id: id,
            timestamp: timestamp,
            client: string("client") ?? "unknown",
            kind: string("kind") ?? "main",
            sessionID: string("session_id"),
            providerID: string("provider"),
            modelID: string("model"),
            isLocal: (object["local"] as? Bool) ?? false,
            inputTokens: integer("input_tokens"),
            cachedInputTokens: integer("cache_read_tokens"),
            outputTokens: integer("output_tokens"),
            totalTokens: integer("total_tokens"),
            latencySeconds: latencySeconds.flatMap { $0 > 0 ? $0 : nil },
            succeeded: (string("outcome") ?? "ok") == "ok"
        )
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

/// Incremental reader for `$WILLDEEP_HOME/usage/*.jsonl`.
///
/// Keeps, per file, the inode and how many bytes it has consumed, so a
/// refresh only parses what the CLI appended since. A trailing line without
/// its `\n` is left for the next pass — the writer may still be mid-line.
/// Records are deduplicated by `id`: a rotated or rewritten file (new inode)
/// is re-read from the start without double counting.
///
/// Read-only by contract (§7 invariant 3): it only ever opens files for
/// reading and never creates, renames or deletes anything under the CLI home.
nonisolated struct AgentCLIUsageLedgerReader: Sendable {
    private struct Cursor: Sendable {
        var inode: UInt64
        var offset: UInt64
    }

    let directory: URL
    private var cursors: [String: Cursor] = [:]
    private var seenIDs: Set<UUID> = []
    private(set) var skippedLineCount = 0

    init(directory: URL) {
        self.directory = directory
    }

    /// `$WILLDEEP_HOME/usage`, else `~/.willdeep/usage` — the same home
    /// resolution the CLI uses.
    static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let custom = environment["WILLDEEP_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
                .appendingPathComponent("usage", isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".willdeep", isDirectory: true)
            .appendingPathComponent("usage", isDirectory: true)
    }

    /// Parses everything appended since the previous call.
    mutating func readNewRecords() -> [AgentCLIUsageRecord] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var records: [AgentCLIUsageRecord] = []
        for name in names.sorted() where name.hasSuffix(".jsonl") && !name.hasPrefix(".") {
            let path = directory.appendingPathComponent(name).path
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let size = (attributes[.size] as? NSNumber)?.uint64Value else {
                continue
            }
            var cursor = cursors[path] ?? Cursor(inode: inode, offset: 0)
            if cursor.inode != inode || size < cursor.offset {
                cursor = Cursor(inode: inode, offset: 0)
            }
            guard size > cursor.offset,
                  let handle = FileHandle(forReadingAtPath: path) else {
                cursors[path] = cursor
                continue
            }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: cursor.offset)
                let chunk = try handle.readToEnd() ?? Data()
                guard let lastNewline = chunk.lastIndex(of: 0x0A) else {
                    cursors[path] = cursor
                    continue
                }
                let complete = chunk[chunk.startIndex...lastNewline]
                for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    guard let record = AgentCLIUsageRecord.decode(line: Data(line)) else {
                        skippedLineCount += 1
                        continue
                    }
                    if seenIDs.insert(record.id).inserted {
                        records.append(record)
                    }
                }
                cursor.offset += UInt64(complete.count)
                cursors[path] = cursor
            } catch {
                cursors[path] = cursor
            }
        }
        return records
    }
}

/// Watches the ledger directory while the stats dashboard is on screen.
///
/// Directory events cover a new monthly file; file events cover appends to
/// the current one. Bursts are throttled so a busy CLI turn (one line per
/// model call) triggers at most one refresh per interval.
@MainActor
final class AgentCLIUsageLedgerWatcher {
    static let throttleInterval: Duration = .seconds(2)

    private let directory: URL
    private let onChange: @MainActor () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pendingRefresh: Task<Void, Never>?

    init(directory: URL, onChange: @escaping @MainActor () -> Void) {
        self.directory = directory
        self.onChange = onChange
    }

    func start() {
        stop()
        watch(path: directory.path, mask: [.write, .extend, .rename, .delete])
        if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in names where name.hasSuffix(".jsonl") {
                watch(path: directory.appendingPathComponent(name).path, mask: [.write, .extend, .rename, .delete])
            }
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    private func watch(path: String, mask: DispatchSource.FileSystemEvent) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: mask,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sources.append(source)
    }

    private func scheduleRefresh() {
        guard pendingRefresh == nil else { return }
        pendingRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.throttleInterval)
            guard let self, !Task.isCancelled else { return }
            self.pendingRefresh = nil
            // A new monthly file may have appeared; re-arm file watches.
            self.start()
            self.onChange()
        }
    }
}
