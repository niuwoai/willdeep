import Foundation
import CryptoKit
import AppKit

@MainActor
enum AgentPluginProductionDelivery {
    static func save(_ selection: Selection) async throws {
        let file = try await open(selection)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        try await Task.detached {
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".willdeep-\(UUID().uuidString).download")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let output = try FileHandle(forWritingTo: temporary)
            do {
                var remaining = file.bytes
                while remaining > 0 {
                    try Task.checkCancellation()
                    guard let data = try file.handle.read(upToCount: Int(min(remaining, 64 * 1024))), !data.isEmpty else {
                        throw AgentToolError.invalidArgument("production_delivery_truncated")
                    }
                    try output.write(contentsOf: data)
                    remaining -= UInt64(data.count)
                }
                try output.synchronize()
                try output.close()
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
            } catch {
                try? output.close()
                throw error
            }
        }.value
    }
    nonisolated static func byteRange(_ header: String?, bytes: UInt64) throws -> ClosedRange<UInt64> {
        guard bytes > 0 else { throw AgentToolError.invalidArgument("production_delivery_empty") }
        guard let header else { return 0...(bytes - 1) }
        guard header.hasPrefix("bytes="), !header.contains(",") else {
            throw AgentToolError.invalidArgument("production_delivery_range_invalid")
        }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw AgentToolError.invalidArgument("production_delivery_range_invalid") }
        if parts[0].isEmpty, let suffix = UInt64(parts[1]), suffix > 0 {
            return (bytes - min(bytes, suffix))...(bytes - 1)
        }
        guard let start = UInt64(parts[0]), start < bytes,
              let end = parts[1].isEmpty ? bytes - 1 : UInt64(parts[1]), end >= start else {
            throw AgentToolError.invalidArgument("production_delivery_range_invalid")
        }
        return start...min(end, bytes - 1)
    }
    nonisolated struct Selection: Sendable {
        let workflow: String
        let selector: String
    }

    nonisolated static func selection(_ url: URL) -> Selection? {
        let parts = url.path.split(separator: "/")
        guard parts.count == 3, parts[0] == "plugin-production",
              let id = UUID(uuidString: String(parts[1])) else { return nil }
        let selector = String(parts[2])
        let episode = selector.hasPrefix("episode-") ? Int(selector.dropFirst(8)) : nil
        guard ["manifest", "records"].contains(selector)
                || episode.map({ (1...80).contains($0) && selector == "episode-\($0)" }) == true else { return nil }
        return Selection(workflow: id.uuidString.lowercased(), selector: selector)
    }

    nonisolated final class VerifiedFile: @unchecked Sendable {
        let handle: FileHandle
        let name: String
        let mime: String
        let bytes: UInt64
        init(handle: FileHandle, name: String, mime: String, bytes: UInt64) {
            self.handle = handle; self.name = name; self.mime = mime; self.bytes = bytes
        }
        deinit { try? handle.close() }
    }

    static func open(_ selection: Selection) async throws -> VerifiedFile {
        let raw = try await AgentPluginRuntimeWorkflow.call(tool: "production.file", arguments: [
            "id": selection.workflow, "selector": selection.selector
        ])
        guard let data = raw.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = result["content"] as? [[String: Any]],
              let text = blocks.compactMap({ $0["text"] as? String }).first,
              let payload = text.data(using: .utf8),
              let proof = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              proof["ok"] as? Bool == true,
              let path = proof["filePath"] as? String,
              let name = proof["filename"] as? String,
              let sha = proof["sha256"] as? String,
              let bytes = (proof["bytes"] as? NSNumber)?.uint64Value,
              let mime = proof["mimeType"] as? String else {
            throw AgentToolError.invalidArgument("production_delivery_invalid")
        }
        let directory = WillDeepRuntimeDiscovery.runtimeDirectory().deletingLastPathComponent()
            .appendingPathComponent("plugin-data/willdeep-video-studio/production-exports")
            .appendingPathComponent(selection.workflow).resolvingSymlinksInPath()
        return try await Task.detached {
            let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard file.deletingLastPathComponent() == directory,
                  file.lastPathComponent == name, !name.contains("/"), bytes > 0,
                  ["video/mp4", "application/json"].contains(mime) else {
                throw AgentToolError.invalidArgument("production_delivery_path_invalid")
            }
            let handle = try FileHandle(forReadingFrom: file)
            do {
                var hash = SHA256()
                var count: UInt64 = 0
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    count += UInt64(chunk.count)
                    guard count <= bytes else { throw AgentToolError.invalidArgument("production_delivery_size_changed") }
                    hash.update(data: chunk)
                }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                guard count == bytes, digest == sha else { throw AgentToolError.invalidArgument("production_delivery_digest_changed") }
                try handle.seek(toOffset: 0)
                return VerifiedFile(handle: handle, name: name, mime: mime, bytes: bytes)
            } catch {
                try? handle.close()
                throw error
            }
        }.value
    }
}
