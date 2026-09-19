//
//  AppStartupTimingLog.swift
//  WillDeep
//
//  Where a cold launch spends its time, measured from the moment the kernel
//  started the process. 2026-09-19 a user reported "the new-chat area took
//  30 seconds right after installing"; three later cold starts came in under
//  4 s and the unified log from the slow launch was redacted, so there was
//  nothing left to tell which stage had waited. Each milestone below lands
//  twice: an `os.Logger` line with public numbers (for `/usr/bin/log show`
//  around the incident) and a JSONL line next to worker-timing.jsonl under
//  AgentAudit (for reading back days later).
//
//  Each milestone is recorded at most once per process. No session content
//  is recorded — milestone names, timings, counts and the app version only.
//

import Darwin
import Foundation
import os

nonisolated enum AppStartupTimingLog {
    static let fileName = "startup-timing.jsonl"
    static let rotatedFileName = "startup-timing.1.jsonl"
    /// A handful of short lines per launch; 1 MB is months of launches.
    static let rotationThresholdBytes: UInt64 = 1024 * 1024
    /// A milestone later than this after process start is logged at error
    /// level so it stands out in `log show`. Normal cold starts finish every
    /// milestone within ~4 s.
    static let slowThresholdSeconds: Double = 10

    enum Milestone: String, Codable, CaseIterable, Sendable {
        /// `applicationDidFinishLaunching` entered.
        case didFinishLaunching
        /// The Agent window's root view appeared.
        case agentWindowAppeared
        /// The session list finished loading from disk.
        case sessionCatalogLoaded
        /// The new-chat stats panel asked for usage data.
        case usageDashboardRequested
        /// The new-chat stats panel has its data and stops spinning.
        case usageDashboardReady
    }

    struct Entry: Codable, Equatable, Sendable {
        var kind = "startup"
        let recordedAt: Date
        let launchID: UUID
        let milestone: Milestone
        /// Seconds from kernel process start to this milestone.
        let secondsSinceProcessStart: Double
        /// Length of the stage that ended here, when it has its own start
        /// (e.g. the usage load itself, separate from how long it queued).
        let durationSeconds: Double?
        /// Items the stage handled (sessions loaded, usage snapshots).
        let count: Int?
        let appVersion: String?
        let build: String?
    }

    static let shared = AppStartupTimingRecorder(
        launchID: UUID(),
        processStartedAt: processStartDate() ?? Date(),
        appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
        sink: { entry in
            log(entry)
            guard let line = AgentWorkerTimingLog.encodeLine(entry) else { return }
            Task.detached(priority: .utility) {
                await writer.append(line)
            }
        }
    )

    static func record(
        _ milestone: Milestone,
        durationSeconds: Double? = nil,
        count: Int? = nil
    ) {
        shared.record(milestone, durationSeconds: durationSeconds, count: count)
    }

    /// Same test/production split as worker-timing.jsonl: tests write to a
    /// per-process temp file, never the user's AgentAudit.
    static func defaultURL(underTests: Bool = AgentWorkerTimingLog.isRunningUnderTests) -> URL {
        AgentWorkerTimingLog.defaultURL(underTests: underTests)
            .deletingLastPathComponent()
            .appendingPathComponent(
                underTests ? "\(ProcessInfo.processInfo.processIdentifier)-\(fileName)" : fileName
            )
    }

    private static let writer = AgentWorkerTimingLogWriter(
        url: defaultURL(),
        rotatedFileName: rotatedFileName,
        rotationThresholdBytes: rotationThresholdBytes
    )

    private static let logger = Logger(subsystem: "com.willdeep.app", category: "startup")

    private static func log(_ entry: Entry) {
        let seconds = entry.secondsSinceProcessStart
        let duration = entry.durationSeconds ?? -1
        let count = entry.count ?? -1
        if seconds >= slowThresholdSeconds {
            logger.error(
                "slow startup milestone \(entry.milestone.rawValue, privacy: .public) at \(seconds, format: .fixed(precision: 3), privacy: .public)s duration=\(duration, format: .fixed(precision: 3), privacy: .public)s count=\(count, privacy: .public)"
            )
        } else {
            logger.notice(
                "startup milestone \(entry.milestone.rawValue, privacy: .public) at \(seconds, format: .fixed(precision: 3), privacy: .public)s duration=\(duration, format: .fixed(precision: 3), privacy: .public)s count=\(count, privacy: .public)"
            )
        }
    }

    /// When the kernel started this process. `Date()` at first use would
    /// miss dyld, static initializers and everything before the first
    /// milestone — exactly the part a slow first launch after install hides in.
    static func processStartDate(pid: pid_t = getpid()) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}

/// Keeps the once-per-process bookkeeping apart from where entries go, so
/// tests can drive it with a fixed start time and a capturing sink.
nonisolated final class AppStartupTimingRecorder: @unchecked Sendable {
    let launchID: UUID
    let processStartedAt: Date
    private let appVersion: String?
    private let build: String?
    private let sink: @Sendable (AppStartupTimingLog.Entry) -> Void
    private let recorded = OSAllocatedUnfairLock(initialState: Set<AppStartupTimingLog.Milestone>())

    init(
        launchID: UUID,
        processStartedAt: Date,
        appVersion: String?,
        build: String?,
        sink: @escaping @Sendable (AppStartupTimingLog.Entry) -> Void
    ) {
        self.launchID = launchID
        self.processStartedAt = processStartedAt
        self.appVersion = appVersion
        self.build = build
        self.sink = sink
    }

    /// Returns the entry, or nil when this milestone was already recorded in
    /// this process (a second window, the stats panel reappearing).
    @discardableResult
    func record(
        _ milestone: AppStartupTimingLog.Milestone,
        at date: Date = Date(),
        durationSeconds: Double? = nil,
        count: Int? = nil
    ) -> AppStartupTimingLog.Entry? {
        let isFirst = recorded.withLock { $0.insert(milestone).inserted }
        guard isFirst else { return nil }
        let entry = AppStartupTimingLog.Entry(
            recordedAt: date,
            launchID: launchID,
            milestone: milestone,
            secondsSinceProcessStart: date.timeIntervalSince(processStartedAt),
            durationSeconds: durationSeconds,
            count: count,
            appVersion: appVersion,
            build: build
        )
        sink(entry)
        return entry
    }
}
