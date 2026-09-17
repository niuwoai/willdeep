//
//  AgentDetachedJob.swift
//  WillDeep
//
//  `lifetime: persistent` local shell jobs that survive quitting the app
//  (docs/BACKGROUND_TASK_CONTRACT.md「C·三」).
//
//  A `Process` + pipe child dies with its reader: once the app exits the pipe
//  closes, the output is lost and nobody can tell success from failure. So a
//  detached job does three things at launch, and all three are needed:
//
//   1. Own process group (`POSIX_SPAWN_SETPGROUP`) — kill targets the group,
//      and nothing aimed at the app's group reaches it.
//   2. Output goes straight into `output.log` (a file, not a pipe), so it keeps
//      growing while no app is running.
//   3. A thin `/bin/sh` wrapper publishes the exit code as `exit.pending` →
//      rename → `exit`. **`exit` present = there is a verdict**; that is the
//      only evidence that survives the process.
//
//  Next to them: `meta.json` (the job record, including the process start
//  time so a recycled pid is never mistaken for the job), `disposition` (the
//  host asked for killed / timed_out before signaling) and `delivered` (the
//  create-new claim that makes the completion notice fire exactly once across
//  launches — same rule as the CLI's `DetachedJobStore`).
//

import Darwin
import Foundation

/// `meta.json`. Display fields only — the command is the redacted display
/// form; the runnable command line never lands on disk.
nonisolated struct AgentDetachedJobRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var id: UUID
    var handle: String
    var pid: Int32
    var processStartSeconds: UInt64
    var processStartMicroseconds: UInt64
    var ownerRuntimeID: UUID
    var label: String?
    var command: String
    var workingDirectory: String?
    var lifetime: AgentBackgroundJobLifetime
    var goalPhaseID: String?
    var survivesTurnStop: Bool
    var deadline: Date?
    var createdAt: Date
}

/// What the host asked for before signaling. Lets a later launch tell a kill
/// or a timeout apart from a crash when the wrapper died without `exit`.
nonisolated enum AgentDetachedJobDisposition: String, Sendable {
    case killed
    case timedOut = "timed_out"
}

nonisolated enum AgentDetachedJobFiles {
    static let metaFileName = "meta.json"
    static let exitFileName = "exit"
    static let exitPendingFileName = "exit.pending"
    static let dispositionFileName = "disposition"
    static let deliveredFileName = "delivered"
    private static let filePermissions: mode_t = 0o600

    static func readRecord(directory: URL) -> AgentDetachedJobRecord? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(metaFileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let record = try? decoder.decode(AgentDetachedJobRecord.self, from: data),
              record.version == AgentDetachedJobRecord.currentVersion,
              record.handle == directory.lastPathComponent else { return nil }
        return record
    }

    static func writeRecord(_ record: AgentDetachedJobRecord, directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writePrivateAtomically(try encoder.encode(record), to: directory.appendingPathComponent(metaFileName))
    }

    static func exitCode(directory: URL) -> Int32? {
        guard let raw = try? String(contentsOf: directory.appendingPathComponent(exitFileName), encoding: .utf8) else {
            return nil
        }
        return Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func disposition(directory: URL) -> AgentDetachedJobDisposition? {
        guard let raw = try? String(contentsOf: directory.appendingPathComponent(dispositionFileName), encoding: .utf8)
        else { return nil }
        return AgentDetachedJobDisposition(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isDelivered(directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(deliveredFileName).path)
    }

    /// Create-new claim. `true` exactly once per job directory, across every
    /// registry and every launch.
    static func claimDelivery(directory: URL) -> Bool {
        let path = directory.appendingPathComponent(deliveredFileName).path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, filePermissions)
        guard descriptor >= 0 else {
            if errno != EEXIST {
                NSLog("Detached job delivery claim failed at %@: errno %d", path, errno)
            }
            return false
        }
        close(descriptor)
        return true
    }

    /// Host-side verdict for a wrapper that was SIGKILLed before it could
    /// publish one. Never overwrites a real `exit`.
    static func publishExitIfMissing(_ code: Int32, directory: URL) {
        let url = directory.appendingPathComponent(exitFileName)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? writePrivateAtomically(Data("\(code)\n".utf8), to: url)
    }

    static func writeDisposition(_ disposition: AgentDetachedJobDisposition, directory: URL) {
        let url = directory.appendingPathComponent(dispositionFileName)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try writePrivateAtomically(Data("\(disposition.rawValue)\n".utf8), to: url)
        } catch {
            NSLog("Detached job disposition write failed at %@: %@", url.path, error.localizedDescription)
        }
    }

    static func writePrivateAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: Int(filePermissions)]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// A job directory whose recorded process is still the same live process.
    /// Retention must never delete it, whichever registry or launch owns it.
    static func recordedProcessIsAlive(directory: URL) -> Bool {
        guard let record = readRecord(directory: directory),
              exitCode(directory: directory) == nil else { return false }
        return AgentDetachedProcessProbe.isAlive(
            pid: record.pid,
            startSeconds: record.processStartSeconds,
            startMicroseconds: record.processStartMicroseconds
        )
    }

    // MARK: - In-process ownership

    /// One registry per job directory inside this process. Several windows can
    /// each own a registry; without this, every one of them would adopt and
    /// tail the same job. Released when the owning monitor goes away.
    private static let ownershipLock = NSLock()
    nonisolated(unsafe) private static var ownedDirectoryNames: Set<String> = []

    static func claimOwnership(handle: String) -> Bool {
        ownershipLock.lock(); defer { ownershipLock.unlock() }
        return ownedDirectoryNames.insert(handle).inserted
    }

    static func releaseOwnership(handle: String) {
        ownershipLock.lock(); defer { ownershipLock.unlock() }
        ownedDirectoryNames.remove(handle)
    }
}

/// pid + start time identity, with zombies counted as gone.
nonisolated enum AgentDetachedProcessProbe {
    private static let zombieStatus: UInt32 = 5 // SZOMB

    static func startMarker(pid: Int32) -> (seconds: UInt64, microseconds: UInt64)? {
        guard let info = info(for: pid) else { return nil }
        return (info.pbi_start_tvsec, info.pbi_start_tvusec)
    }

    static func isAlive(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) -> Bool {
        guard pid > 0, let info = info(for: pid) else { return false }
        guard info.pbi_start_tvsec == startSeconds, info.pbi_start_tvusec == startMicroseconds else {
            return false
        }
        if info.pbi_status == zombieStatus {
            // Our own child from this launch: reap it so the pid can go.
            // For anyone else's process this is a harmless ECHILD.
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)
            return false
        }
        return true
    }

    private static func info(for pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let count = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size) }
        return count == size ? info : nil
    }
}

nonisolated enum AgentDetachedJobLauncher {
    /// `$1` is the job directory, the rest is the (sandbox-wrapped) command
    /// argv. A TERM/HUP/INT to the group is trapped here only so the wrapper
    /// outlives its command long enough to publish `exit`; trapped signals are
    /// reset to default in the command itself.
    static let wrapperScript = """
    d=$1; shift
    trap 'wd_signaled=1' TERM HUP INT
    "$@"
    wd_code=$?
    printf '%s\\n' "$wd_code" > "$d/exit.pending" && mv -f "$d/exit.pending" "$d/exit"
    """

    /// Spawns the wrapper in its own process group with stdin `/dev/null`,
    /// stdout+stderr appended to `logURL`, and no app descriptors inherited.
    static func spawn(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        jobDirectory: URL,
        logURL: URL
    ) throws -> Int32 {
        var attributes: posix_spawnattr_t?
        var fileActions: posix_spawn_file_actions_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            | POSIX_SPAWN_CLOEXEC_DEFAULT
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        // The app ignores SIGPIPE; an ignored disposition would survive exec.
        var defaults = sigset_t()
        sigfillset(&defaults)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigmask(&attributes, &mask))

        try check(posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_addopen(
            &fileActions, 1, logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600))
        try check(posix_spawn_file_actions_adddup2(&fileActions, 1, 2))
        if let workingDirectory {
            try check(posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory.path))
        }

        let argv = ["/bin/sh", "-c", wrapperScript, "willdeep-detached-job", jobDirectory.path, executableURL.path]
            + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnvironment: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) } + [nil]
        defer {
            cArguments.forEach { free($0) }
            cEnvironment.forEach { free($0) }
        }
        var pid: pid_t = 0
        try check(posix_spawn(&pid, "/bin/sh", &fileActions, &attributes, &cArguments, &cEnvironment))
        return pid
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    }
}

/// Tails `output.log` into the in-memory collector and watches for `exit`
/// instead of a termination handler. Owned by one registry; dropping it stops
/// watching but never touches the process.
nonisolated final class AgentDetachedJobMonitor: @unchecked Sendable {
    enum Outcome: Sendable {
        /// `exit` was published (by the wrapper, or by the host after a kill).
        case exited(Int32)
        /// Process gone, no `exit`, no host disposition.
        case vanished
    }

    static let pollInterval: DispatchTimeInterval = .milliseconds(200)
    static let gracePeriod: TimeInterval = 2
    private static let queue = DispatchQueue(label: "com.willdeep.agent-detached-jobs", qos: .userInitiated)

    let record: AgentDetachedJobRecord
    let directory: URL
    let logURL: URL
    let collector: AgentJobOutputCollector
    private let collectorLimit: Int
    private let lock = NSLock()
    private var readOffset: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var timeoutWork: DispatchWorkItem?
    private var finished = false
    private var _disposition: AgentDetachedJobDisposition?
    private var onFinish: (@Sendable (Outcome) -> Void)?

    init(record: AgentDetachedJobRecord, directory: URL, collectorLimit: Int, startFromTail: Bool) {
        self.record = record
        self.directory = directory
        logURL = directory.appendingPathComponent(AgentJobOutputLogSink.logFileName)
        self.collectorLimit = collectorLimit
        collector = AgentJobOutputCollector(limit: collectorLimit)
        _disposition = AgentDetachedJobFiles.disposition(directory: directory)
        if startFromTail, let size = Self.fileSize(logURL) {
            // One byte past the limit so the collector marks the tail truncated.
            readOffset = size > UInt64(collectorLimit + 1) ? size - UInt64(collectorLimit + 1) : 0
        }
        AgentJobOutputLogSink.retainActiveDirectory(record.handle)
    }

    deinit {
        timer?.setEventHandler {}
        timer?.cancel()
        timeoutWork?.cancel()
        AgentJobOutputLogSink.releaseActiveDirectory(record.handle)
        AgentDetachedJobFiles.releaseOwnership(handle: record.handle)
    }

    var disposition: AgentDetachedJobDisposition? {
        lock.lock(); defer { lock.unlock() }
        return _disposition
    }

    var isAlive: Bool {
        AgentDetachedProcessProbe.isAlive(
            pid: record.pid,
            startSeconds: record.processStartSeconds,
            startMicroseconds: record.processStartMicroseconds
        )
    }

    func start(onFinish: @escaping @Sendable (Outcome) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.poll() }
        lock.lock()
        self.onFinish = onFinish
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    /// Checks once, synchronously. Used on adoption before any timer runs.
    func currentOutcome() -> Outcome? {
        drainLog()
        if let code = AgentDetachedJobFiles.exitCode(directory: directory) { return .exited(code) }
        guard !isAlive else { return nil }
        // The wrapper publishes `exit` right before it exits; look again.
        if let code = AgentDetachedJobFiles.exitCode(directory: directory) { return .exited(code) }
        drainLog()
        if let disposition {
            let code = disposition == .killed ? 128 + SIGKILL : 128 + SIGTERM
            AgentDetachedJobFiles.publishExitIfMissing(code, directory: directory)
            return .exited(AgentDetachedJobFiles.exitCode(directory: directory) ?? code)
        }
        return .vanished
    }

    func scheduleTimeout(after seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.requestKill(.timedOut) }
        lock.lock()
        timeoutWork?.cancel()
        timeoutWork = work
        lock.unlock()
        Self.queue.asyncAfter(deadline: .now() + max(0, seconds), execute: work)
    }

    /// SIGTERM to the process group, SIGKILL after the grace period for
    /// whatever is still in it. The disposition lands on disk first so a
    /// launch that only finds the aftermath still knows what happened.
    @discardableResult
    func requestKill(_ disposition: AgentDetachedJobDisposition) -> Bool {
        lock.lock()
        let alreadyFinished = finished
        if _disposition == nil { _disposition = disposition }
        lock.unlock()
        guard !alreadyFinished else { return false }
        AgentDetachedJobFiles.writeDisposition(disposition, directory: directory)
        let group = record.pid
        guard group > 0 else { return false }
        _ = killpg(group, SIGTERM)
        Self.queue.asyncAfter(deadline: .now() + Self.gracePeriod) {
            if killpg(group, 0) == 0 { _ = killpg(group, SIGKILL) }
        }
        return true
    }

    private func poll() {
        guard let outcome = currentOutcome() else { return }
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let callback = onFinish
        onFinish = nil
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        lock.unlock()
        callback?(outcome)
    }

    /// Reads what was appended since the last call. A burst larger than the
    /// in-memory tail is skipped to its last `limit + 1` bytes.
    private func drainLog() {
        lock.lock(); defer { lock.unlock() }
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        if size < readOffset { readOffset = 0 }
        guard size > readOffset else { return }
        let window = UInt64(collectorLimit + 1)
        if size - readOffset > window { readOffset = size - window }
        do {
            try handle.seek(toOffset: readOffset)
            guard let data = try handle.read(upToCount: Int(size - readOffset)), !data.isEmpty else { return }
            readOffset += UInt64(data.count)
            collector.append(data, stream: .combined)
        } catch {
            return
        }
    }

    private static func fileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }
}
