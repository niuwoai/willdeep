//
//  AgentComposerAttachmentSupport.swift
//  WillDeep
//
//  Shared allow-list and validation for files attached from the Agent
//  composer. Images keep their native multimodal path; readable documents
//  are staged as AgentFileAttachment values and converted to model context
//  locally when the turn is sent.
//

import Foundation
import UniformTypeIdentifiers

nonisolated enum AgentAttachedPromptProtocol {
    static let preludeHeader = "The user attached the following context for this turn — treat it as task setup, not verbatim user text:"
    static let userTextBoundary = "<<<willdeep:user-message:v1>>>"
    static let escapedUserTextBoundary = "&lt;&lt;&lt;willdeep:user-message:v1&gt;&gt;&gt;"
}

nonisolated enum AgentComposerAttachmentSupport {
    static let maxDocumentBytes = 50 * 1_024 * 1_024

    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "go", "rb", "ruby", "py", "python",
        "php", "csv", "tsv", "json", "jsonl", "yaml", "yml", "xml",
        "html", "htm", "css", "js", "jsx", "ts", "tsx", "swift",
        "java", "kt", "kts", "c", "h", "m", "mm", "cc", "cpp",
        "hpp", "rs", "sh", "bash", "zsh", "fish", "sql", "toml",
        "ini", "conf", "log", "diff", "patch"
    ]

    static let locallyParsedDocumentExtensions: Set<String> = [
        "pdf", "docx", "xlsx"
    ]

    static let supportedDocumentExtensions = textExtensions
        .union(locallyParsedDocumentExtensions)

    static var allowedContentTypes: [UTType] {
        let documentTypes = supportedDocumentExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        var seen = Set<String>()
        return ([.image] + documentTypes).filter { seen.insert($0.identifier).inserted }
    }

    static func isSupportedDocument(_ url: URL) -> Bool {
        supportedDocumentExtensions.contains(url.pathExtension.lowercased())
    }

    static func documentExceedsSizeLimit(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize else {
            return false
        }
        return fileSize > maxDocumentBytes
    }
}
