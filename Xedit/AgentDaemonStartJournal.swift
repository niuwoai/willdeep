import CryptoKit
import Darwin
import Foundation

/// Recovery identities only: never argv, stdin, environment, endpoint URL or credentials.
nonisolated struct AgentDaemonStartReceipt: Codable, Equatable, Sendable {
    let id: UUID
    let runtimeID: UUID
    let turnID: UUID?
    let remoteRuntimeID: UUID
    let endpointFingerprint: String
    let workspaceFingerprint: String
    let instanceID: String
    let requestID: String
    let executor: AgentExecutionAgent?
    let createdAt: Date
    let deadline: Date
    let publishesCompletion: Bool
    var isCommand: Bool? = nil
    var lifetime: AgentBackgroundJobLifetime? = nil
    var goalPhaseID: String? = nil
    var survivesTurnStop: Bool? = nil
    var serverDeadlineElapsedMilliseconds: Int64? = nil

    var jobID: String { "job-\(instanceID)-request-\(requestID)" }
    var isValid: Bool {
        instanceID.utf8.count == 32 && instanceID.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && UUID(uuidString: requestID) != nil && requestID == requestID.lowercased()
            && endpointFingerprint.count == 64 && workspaceFingerprint.count == 64
            && deadline > createdAt && deadline.timeIntervalSince(createdAt) <= 6 * 3600
            && (survivesTurnStop != true || lifetime == .persistent)
            && (executor == nil ? isCommand == true : isCommand != true)
            && (serverDeadlineElapsedMilliseconds.map { $0 > 0 && $0 <= AgentDaemonRunDeadline.maximumMilliseconds } ?? true)
    }
    func matches(_ descriptor: RuntimeDescriptor) -> Bool {
        remoteRuntimeID == descriptor.id
            && endpointFingerprint == Self.fingerprint(descriptor.daemonEndpointURL?.absoluteString ?? "")
            && workspaceFingerprint == Self.fingerprint(descriptor.defaultWorkspacePath)
    }
    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum AgentDaemonStartJournalError: Error, LocalizedError {
    case unsafeStorage, corrupt, conflictingReceipt
    case io(Int32)
    var errorDescription: String? {
        "Daemon recovery receipt could not be safely persisted or loaded. Existing evidence was retained; do not repeat the execution."
    }
}

/// Immutable prepare/stop/terminal receipts. Atomic exclusive publication,
/// fsync and directory-relative NOFOLLOW I/O keep interrupted writes and stale
/// callbacks from turning an unknown external side effect into a fresh start.
nonisolated struct AgentDaemonStartJournal: Sendable {
    let directory: URL
    private let maximumBytes = 16 * 1024
    private let maximumReceipts = 10_000

    struct Terminal: Codable, Equatable, Sendable {
        let id: UUID
        /// Nil means the server sealed this request without starting it.
        let exitCode: Int32?
        var disposition: String? = nil
        var finishedAt: Date? = nil
        var publishesCompletion: Bool? = nil
    }
    struct Delivery: Equatable, Sendable {
        let receipt: AgentDaemonStartReceipt
        let terminal: Terminal
    }
    struct Pending: Equatable, Sendable {
        let receipt: AgentDaemonStartReceipt
        let cancellationRequested: Bool
    }
    private struct Envelope: Codable { let version: Int; let digest: String; let payload: Data }

    func prepare(_ receipt: AgentDaemonStartReceipt) throws {
        guard receipt.isValid else { throw AgentDaemonStartJournalError.corrupt }
        _ = try pending(runtimeID: receipt.runtimeID)
        try publish(receipt, name: "\(receipt.id.uuidString).json")
    }

    func requestCancellation(_ receipt: AgentDaemonStartReceipt) throws {
        try requirePrepared(receipt)
        try publish(receipt.id, name: "\(receipt.id.uuidString).stop")
    }

    func finish(_ receipt: AgentDaemonStartReceipt, exitCode: Int32?, disposition: String? = nil,
        finishedAt: Date? = nil, publishesCompletion: Bool? = nil) throws {
        try requirePrepared(receipt)
        let terminal = Terminal(id: receipt.id, exitCode: exitCode, disposition: disposition,
            finishedAt: finishedAt, publishesCompletion: publishesCompletion)
        let name = "\(receipt.id.uuidString).terminal"
        if try exists(name) {
            let previous: Terminal = try read(name)
            guard previous.id == terminal.id, previous.exitCode == terminal.exitCode,
                  previous.disposition == terminal.disposition,
                  previous.publishesCompletion == terminal.publishesCompletion else {
                throw AgentDaemonStartJournalError.conflictingReceipt
            }
            // Keep the first observation time on idempotent completion retries.
            try publish(previous, name: name)
            return
        }
        try publish(terminal, name: name)
    }

    func pending(runtimeID: UUID? = nil) throws -> [Pending] {
        try records(runtimeID: runtimeID).compactMap { record in
            guard record.terminal == nil else { return nil }
            return Pending(receipt: record.receipt, cancellationRequested: record.stopped)
        }
    }

    /// A terminal receipt is not an ACK from the host event journal.
    /// Legacy terminal records lack a reliable host disposition and are not
    /// promoted into a newly inferred completion/timeout notification.
    func deliveries(runtimeID: UUID? = nil) throws -> [Delivery] {
        try records(runtimeID: runtimeID).compactMap { record in
            guard let terminal = record.terminal, terminal.disposition != nil,
                  !record.acknowledged else { return nil }
            return Delivery(receipt: record.receipt, terminal: terminal)
        }
    }

    func delivery(id: UUID) throws -> Delivery? {
        let name = "\(id.uuidString).json"
        guard try exists(name), let record = try record(name: name, runtimeID: nil),
              let terminal = record.terminal, terminal.disposition != nil,
              !record.acknowledged else { return nil }
        return Delivery(receipt: record.receipt, terminal: terminal)
    }

    func acknowledge(_ delivery: Delivery) throws {
        try requirePrepared(delivery.receipt)
        let terminal: Terminal = try read("\(delivery.receipt.id.uuidString).terminal")
        guard terminal == delivery.terminal else { throw AgentDaemonStartJournalError.conflictingReceipt }
        try publish(delivery.receipt.id, name: "\(delivery.receipt.id.uuidString).delivered")
    }

    private struct Record {
        let receipt: AgentDaemonStartReceipt
        let terminal: Terminal?
        let stopped: Bool
        let acknowledged: Bool
    }

    private func records(runtimeID: UUID?) throws -> [Record] {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw AgentDaemonStartJournalError.io(errno) }
            return []
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw AgentDaemonStartJournalError.unsafeStorage }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }
        guard names.count <= maximumReceipts else { throw AgentDaemonStartJournalError.corrupt }
        return try names.sorted().compactMap { try record(name: $0, runtimeID: runtimeID) }
    }

    private func record(name: String, runtimeID: UUID?) throws -> Record? {
            guard let id = UUID(uuidString: String(name.dropLast(5))) else { throw AgentDaemonStartJournalError.corrupt }
            let receipt: AgentDaemonStartReceipt = try read(name)
            guard receipt.id == id, receipt.isValid else { throw AgentDaemonStartJournalError.corrupt }
            if let runtimeID, receipt.runtimeID != runtimeID { return nil }
            var terminal: Terminal?
            if try exists("\(id.uuidString).terminal") {
                terminal = try read("\(id.uuidString).terminal")
                guard let terminal, terminal.id == id else { throw AgentDaemonStartJournalError.corrupt }
                if let disposition = terminal.disposition {
                    guard ["completed", "failed", "killed", "timedOut", "launchFailed"].contains(disposition),
                          let finishedAt = terminal.finishedAt, finishedAt.timeIntervalSince1970.isFinite,
                          let publishes = terminal.publishesCompletion,
                          !publishes || receipt.publishesCompletion,
                          (terminal.exitCode != nil || disposition == "launchFailed" || disposition == "killed" || disposition == "timedOut"),
                          disposition != "completed" || terminal.exitCode == 0 else {
                        throw AgentDaemonStartJournalError.corrupt
                    }
                }
            }
            let stopped = try exists("\(id.uuidString).stop")
            if stopped {
                let stopID: UUID = try read("\(id.uuidString).stop")
                guard stopID == id else { throw AgentDaemonStartJournalError.corrupt }
            }
            let acknowledged = try exists("\(id.uuidString).delivered")
            if acknowledged {
                let acknowledgedID: UUID = try read("\(id.uuidString).delivered")
                guard acknowledgedID == id, terminal != nil else { throw AgentDaemonStartJournalError.corrupt }
            }
            return Record(receipt: receipt, terminal: terminal, stopped: stopped, acknowledged: acknowledged)
    }

    private func requirePrepared(_ receipt: AgentDaemonStartReceipt) throws {
        let previous: AgentDaemonStartReceipt = try read("\(receipt.id.uuidString).json")
        guard previous == receipt else { throw AgentDaemonStartJournalError.conflictingReceipt }
    }

    private func exists(_ name: String) throws -> Bool {
        // A dangling symlink must be inspected and rejected, never treated as absence.
        var info = stat()
        if lstat(directory.appendingPathComponent(name).path, &info) == 0 { return true }
        guard errno == ENOENT else { throw AgentDaemonStartJournalError.io(errno) }
        return false
    }

    private func withDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw AgentDaemonStartJournalError.unsafeStorage }
        defer { Darwin.close(fd) }
        return try body(fd)
    }

    private func read<T: Decodable>(_ name: String) throws -> T {
        try withDirectory { dir in
            let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw AgentDaemonStartJournalError.io(errno) }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size > 0, info.st_size <= maximumBytes else { throw AgentDaemonStartJournalError.corrupt }
            var data = Data(count: Int(info.st_size))
            try data.withUnsafeMutableBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw AgentDaemonStartJournalError.corrupt }
                    offset += count
                }
            }
            do {
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard envelope.version == 1, envelope.digest == digest(envelope.payload) else { throw AgentDaemonStartJournalError.corrupt }
                return try JSONDecoder().decode(T.self, from: envelope.payload)
            } catch { throw AgentDaemonStartJournalError.corrupt }
        }
    }

    private func publish<T: Codable & Equatable>(_ value: T, name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let payload = try encoder.encode(value)
        let data = try encoder.encode(Envelope(version: 1, digest: digest(payload), payload: payload))
        guard data.count <= maximumBytes else { throw AgentDaemonStartJournalError.corrupt }
        try withDirectory { dir in
            let temporary = ".receipt-\(UUID().uuidString).tmp"
            let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
            guard fd >= 0 else { throw AgentDaemonStartJournalError.io(errno) }
            defer { Darwin.close(fd); unlinkat(dir, temporary, 0) }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw AgentDaemonStartJournalError.io(errno) }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else { throw AgentDaemonStartJournalError.io(errno) }
            if linkat(dir, temporary, dir, name, 0) != 0 {
                guard errno == EEXIST else { throw AgentDaemonStartJournalError.io(errno) }
                let previous: T = try read(name)
                guard previous == value else { throw AgentDaemonStartJournalError.conflictingReceipt }
            }
            guard fsync(dir) == 0 else { throw AgentDaemonStartJournalError.io(errno) }
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class AgentDaemonStartPreparation {
    var receipt: AgentDaemonStartReceipt?
    let journal: AgentDaemonStartJournal
    init(journal: AgentDaemonStartJournal) { self.journal = journal }
    func prepare(_ receipt: AgentDaemonStartReceipt) async throws {
        let journal = self.journal
        try await Task.detached(priority: .utility) { try journal.prepare(receipt) }.value
        self.receipt = receipt
    }
}
