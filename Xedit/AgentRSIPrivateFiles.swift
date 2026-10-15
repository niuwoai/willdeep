import Foundation
import Darwin

nonisolated enum AgentRSIPrivateFiles {
    static func writeImmutable(_ data: Data, to target: URL) throws {
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".pending-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AgentAssetError.server }
        defer { _ = Darwin.unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
            guard Darwin.link(temporary.path, target.path) == 0 else { throw AgentAssetError.immutableVersion }
        } catch { try? handle.close(); throw error }
    }
}
