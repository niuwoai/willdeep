import CryptoKit
import Darwin
import Foundation

/// Per-task immutable completion evidence, independent of each window's
/// mutable media history snapshot. Acknowledgement never deletes the payload.
@MainActor
struct AgentMediaCompletionStore {
    struct Delivery: Equatable {
        let task: AgentMediaTask
        let handedOff: Bool
        let settled: Bool
    }

    enum Failure: Error { case unsafeStorage, corrupt, conflictingReceipt, io(Int32) }
    private struct Envelope: Codable { let version: Int; let digest: String; let payload: Data }
    let directory: URL
    private let maximumBytes = 8 * 1024 * 1024

    func prepare(_ task: AgentMediaTask) throws -> Delivery {
        guard !task.isActive, task.runtimeID != nil else { throw Failure.conflictingReceipt }
        if let existing = try delivery(id: task.id) {
            guard existing.task.runtimeID == task.runtimeID,
                  existing.task.ownerTurnID == task.ownerTurnID,
                  existing.task.status == task.status else { throw Failure.conflictingReceipt }
            // The first terminal observation owns this notification. Later
            // polling timestamps cannot create another delivery for the ID.
            return existing
        }
        try publish(task, name: name(task.id, "json"))
        return try requiredDelivery(id: task.id)
    }

    func delivery(id: UUID) throws -> Delivery? {
        guard try exists(name(id, "json")) else { return nil }
        let task: AgentMediaTask = try read(name(id, "json"))
        guard task.id == id, task.runtimeID != nil, !task.isActive else { throw Failure.corrupt }
        return try Delivery(task: task, handedOff: marker(id, "ack"), settled: marker(id, "settled"))
    }

    func outstanding() throws -> [Delivery] {
        let names = try withDirectory { _ in try FileManager.default.contentsOfDirectory(atPath: directory.path) }
        var result: [Delivery] = []
        for filename in names.sorted() where filename.hasSuffix(".json") {
            guard let id = UUID(uuidString: String(filename.dropLast(5))) else { throw Failure.corrupt }
            let value = try requiredDelivery(id: id)
            if !value.settled { result.append(value) }
        }
        return result
    }

    func acknowledge(id: UUID) throws {
        _ = try requiredDelivery(id: id)
        try publish(id, name: name(id, "ack"))
    }

    func settle(id: UUID) throws {
        _ = try requiredDelivery(id: id)
        try publish(id, name: name(id, "settled"))
    }

    private func requiredDelivery(id: UUID) throws -> Delivery {
        guard let value = try delivery(id: id) else { throw Failure.corrupt }
        return value
    }

    private func name(_ id: UUID, _ suffix: String) -> String { "\(id.uuidString).\(suffix)" }

    private func marker(_ id: UUID, _ suffix: String) throws -> Bool {
        guard try exists(name(id, suffix)) else { return false }
        let stored: UUID = try read(name(id, suffix))
        guard stored == id else { throw Failure.corrupt }
        return true
    }

    private func exists(_ name: String) throws -> Bool {
        var info = stat()
        if lstat(directory.appendingPathComponent(name).path, &info) == 0 { return true }
        guard errno == ENOENT else { throw Failure.io(errno) }
        return false
    }

    private func withDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.unsafeStorage }
        defer { Darwin.close(fd) }
        return try body(fd)
    }

    private func read<T: Decodable>(_ name: String) throws -> T {
        try withDirectory { dir in
            let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw Failure.io(errno) }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size > 0, info.st_size <= maximumBytes else { throw Failure.corrupt }
            var data = Data(count: Int(info.st_size))
            try data.withUnsafeMutableBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw Failure.corrupt }
                    offset += count
                }
            }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1, envelope.digest == digest(envelope.payload) else { throw Failure.corrupt }
            return try JSONDecoder().decode(T.self, from: envelope.payload)
        }
    }

    private func publish<T: Codable & Equatable>(_ value: T, name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let payload = try encoder.encode(value)
        let data = try encoder.encode(Envelope(version: 1, digest: digest(payload), payload: payload))
        guard data.count <= maximumBytes else { throw Failure.corrupt }
        try withDirectory { dir in
            let temporary = ".completion-\(UUID().uuidString).tmp"
            let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
            guard fd >= 0 else { throw Failure.io(errno) }
            defer { Darwin.close(fd); unlinkat(dir, temporary, 0) }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw Failure.io(errno) }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else { throw Failure.io(errno) }
            if linkat(dir, temporary, dir, name, 0) != 0 {
                guard errno == EEXIST else { throw Failure.io(errno) }
                let previous: T = try read(name)
                guard previous == value else { throw Failure.conflictingReceipt }
            }
            guard fsync(dir) == 0 else { throw Failure.io(errno) }
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
