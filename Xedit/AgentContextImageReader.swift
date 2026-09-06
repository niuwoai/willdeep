import Foundation
import CryptoKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

/// Restores only an already-attached image. Never hands a lazy file path to a
/// provider: the returned attachment owns the exact bytes validated here.
nonisolated enum AgentContextImageReader {
    static let maximumBytes = 8 * 1_024 * 1_024
    static let maximumPixels: Double = 40_000_000
    static let maximumFrames = 256

    static func read(_ image: AgentImageAttachment, workspaceRoots: [URL]) throws -> AgentImageAttachment {
        try Task.checkCancellation()
        let data: Data
        if let file = image.fileURL {
            guard let expected = image.sha256, expected.count == 64,
                  expected.allSatisfy({ $0.isHexDigit }) else { throw AgentContextReadSnapshot.Failure.unavailable }
            var roots = workspaceRoots
            if image.isInOwnedAttachmentStorage { roots.append(file.deletingLastPathComponent()) }
            guard let root = roots.first(where: { isDescendant(file, of: $0) }) else {
                throw AgentContextReadSnapshot.Failure.unavailable
            }
            data = try readFile(file, within: root, allowRootAlias: !image.isInOwnedAttachmentStorage)
            guard digest(data) == expected.lowercased() else { throw AgentContextReadSnapshot.Failure.attachmentChanged }
        } else {
            guard image.inlineImageEncodedByteCount <= ((maximumBytes + 2) / 3) * 4,
                  let inline = image.inlineImageData, !inline.isEmpty, inline.count <= maximumBytes else {
                throw AgentContextReadSnapshot.Failure.unavailable
            }
            data = inline
            if let expected = image.sha256, digest(data) != expected.lowercased() {
                throw AgentContextReadSnapshot.Failure.attachmentChanged
            }
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              (1...maximumFrames).contains(CGImageSourceGetCount(source)),
              let type = CGImageSourceGetType(source),
              let mime = UTType(type as String)?.preferredMIMEType, mime.hasPrefix("image/") else {
            throw AgentContextReadSnapshot.Failure.unavailable
        }
        var pixels: Double = 0
        for index in 0..<CGImageSourceGetCount(source) {
            try Task.checkCancellation()
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
                  width > 0, height > 0 else { throw AgentContextReadSnapshot.Failure.unavailable }
            pixels += width * height
            guard pixels <= maximumPixels else { throw AgentContextReadSnapshot.Failure.unavailable }
        }
        return AgentImageAttachment(id: image.id, mimeType: mime, dataBase64: data.base64EncodedString(),
                                    createdAt: image.createdAt, originToolName: AgentContextReadTool.name)
    }

    private static func isDescendant(_ file: URL, of root: URL) -> Bool {
        let prefix = root.standardizedFileURL.path
        return file.standardizedFileURL.path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func readFile(_ file: URL, within root: URL, allowRootAlias: Bool) throws -> Data {
        let rootPath = root.standardizedFileURL.path
        let components = file.standardizedFileURL.path.dropFirst(rootPath.count)
            .split(separator: "/").map(String.init)
        guard let filename = components.last, !components.contains("..") else { throw AgentContextReadSnapshot.Failure.unavailable }
        // A user-selected workspace root can itself be an alias; descendants
        // cannot escape it through symlinks. openat keeps each traversal bound
        // to the directory descriptor, rather than checking then reopening.
        let directoryPath = allowRootAlias ? root.resolvingSymlinksInPath().path : root.standardizedFileURL.path
        var directory = Darwin.open(directoryPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw AgentContextReadSnapshot.Failure.unavailable }
        defer { Darwin.close(directory) }
        for component in components.dropLast() {
            try Task.checkCancellation()
            let next = Darwin.openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else { throw AgentContextReadSnapshot.Failure.unavailable }
            Darwin.close(directory)
            directory = next
        }
        let descriptor = Darwin.openat(directory, filename, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AgentContextReadSnapshot.Failure.unavailable }
        defer { Darwin.close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= maximumBytes else { throw AgentContextReadSnapshot.Failure.unavailable }
        var data = Data()
        while data.count <= maximumBytes {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes, data.count == info.st_size else { throw AgentContextReadSnapshot.Failure.attachmentChanged }
        return data
    }
}
