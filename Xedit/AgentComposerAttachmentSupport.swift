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
    static let maxUnknownAttachmentBytes = 8 * 1_024

    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "go", "rb", "ruby", "py", "python",
        "php", "csv", "tsv", "json", "jsonl", "yaml", "yml", "xml",
        "html", "htm", "css", "js", "jsx", "ts", "tsx", "swift",
        "java", "kt", "kts", "c", "h", "m", "mm", "cc", "cpp",
        "hpp", "rs", "sh", "bash", "zsh", "fish", "sql", "toml",
        "ini", "conf", "cfg", "config", "properties", "env", "log",
        "diff", "patch", "lock", "gradle", "groovy", "scala", "cs",
        "fs", "fsx", "vb", "r", "lua", "pl", "pm", "ex", "exs",
        "erl", "hrl", "clj", "cljs", "edn", "vue", "svelte", "astro",
        "graphql", "gql", "proto", "tex", "rst", "adoc", "org"
    ]

    /// Common text-based build and repository files intentionally have no
    /// extension. UTType cannot classify them reliably, so recognize their
    /// conventional basenames before falling back to the unknown-file flow.
    static let extensionlessTextFilenames: Set<String> = [
        "procfile", "dockerfile", "makefile", "gemfile", "rakefile",
        "guardfile", "vagrantfile", "podfile", "cartfile", "brewfile",
        "justfile", "taskfile", "fastfile", "appfile", "deliverfile",
        "matchfile", "pluginfile", "dangerfile", "readme", "license",
        "notice", "changelog", "authors", ".gitignore", ".gitattributes",
        ".gitmodules", ".dockerignore", ".editorconfig", ".npmrc",
        ".yarnrc", ".swiftlint"
    ]

    static let locallyParsedDocumentExtensions: Set<String> = [
        "pdf", "docx", "xlsx"
    ]

    static let supportedDocumentExtensions = textExtensions
        .union(locallyParsedDocumentExtensions)

    static var allowedContentTypes: [UTType] {
        // Unknown files must remain selectable so Composer can apply the
        // 8 KB confirmation/blocking policy itself. `.item` also admits
        // extensionless text files such as Procfile.
        [.item]
    }

    static func isSupportedDocument(_ url: URL) -> Bool {
        isKnownTextDocument(url)
            || locallyParsedDocumentExtensions.contains(url.pathExtension.lowercased())
    }

    static func isKnownTextDocument(_ url: URL) -> Bool {
        let filename = url.lastPathComponent.lowercased()
        if textExtensions.contains(url.pathExtension.lowercased()) { return true }
        if extensionlessTextFilenames.contains(filename) { return true }
        return filename.hasPrefix("procfile.")
            || filename.hasPrefix("dockerfile.")
            || filename.hasPrefix(".env.")
    }

    static func selectionPolicy(for url: URL) -> AgentComposerAttachmentSelectionPolicy {
        if isSupportedDocument(url) { return .supported }
        guard let byteCount = fileByteCount(url) else { return .unknownUnreadable }
        if byteCount > maxUnknownAttachmentBytes {
            return .unknownTooLarge(byteCount: byteCount)
        }
        return .unknownNeedsConfirmation(byteCount: byteCount)
    }

    static func documentExceedsSizeLimit(_ url: URL) -> Bool {
        guard let fileSize = fileByteCount(url) else { return false }
        return fileSize > maxDocumentBytes
    }

    private static func fileByteCount(_ url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else {
            return nil
        }
        return values.fileSize
    }
}

nonisolated enum AgentComposerAttachmentSelectionPolicy: Equatable {
    case supported
    case unknownNeedsConfirmation(byteCount: Int)
    case unknownTooLarge(byteCount: Int)
    case unknownUnreadable
}
