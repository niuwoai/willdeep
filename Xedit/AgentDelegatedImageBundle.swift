//
//  AgentDelegatedImageBundle.swift
//  WillDeep
//
//  Creates short-lived, permission-scoped copies of Composer image
//  attachments for local Claude Code and Codex CLI delegation.
//

import Foundation

nonisolated struct AgentDelegatedImageBundle: Sendable {
    static let directoryPrefix = "willdeep-delegated-images-"

    let directoryURL: URL
    let fileURLs: [URL]

    static func create(
        images: [AgentImageAttachment],
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        token: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        fileManager: FileManager = .default
    ) throws -> AgentDelegatedImageBundle {
        let directory = temporaryDirectory.appendingPathComponent(
            "\(directoryPrefix)\(token)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            let fileURLs = try images.enumerated().map { offset, image in
                guard let data = imageData(image), !data.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let url = directory.appendingPathComponent(
                    "image-\(offset + 1).\(fileExtension(for: image.mimeType))",
                    isDirectory: false
                )
                try data.write(to: url, options: [.atomic])
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
                return url
            }
            return AgentDelegatedImageBundle(directoryURL: directory, fileURLs: fileURLs)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    func removeAll(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directoryURL)
    }

    private static func imageData(_ image: AgentImageAttachment) -> Data? {
        if let fileURL = image.fileURL,
           let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) {
            return data
        }
        return Data(base64Encoded: image.dataBase64)
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic", "image/heif": return "heic"
        default: return "png"
        }
    }
}
