//
//  AgentTranscriptMedia.swift
//  WillDeep
//
//  Which Markdown lines in an assistant reply are *media* (video / audio the
//  transcript plays inline), where the file lives, and the cheap fingerprint
//  that tells the render caches the file changed.
//
//  Two authoring shapes count, both only when the line stands alone:
//
//      ![演示](/abs/demo.mp4)        — what the send-file skill writes
//      [会议录音](recording.m4a)      — a plain link to a local media file
//
//  Same restrictions as `MarkdownInlineImage`: local files only (a remote URL
//  is never fetched, so a model-authored line cannot become a tracking
//  pixel), and nothing mid-sentence becomes a block.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

nonisolated enum AgentTranscriptMediaKind: String, Codable, Hashable, Sendable {
    case video
    case audio
}

/// Format policy. The kind comes from the system's UTType table first —
/// that is what knows `m4v` is a movie and `caf` is audio — and falls back
/// to our own extension lists when the system has never heard of the
/// extension. Playability is a separate, deliberately short whitelist: an
/// `.avi` is still recognised as a video (so it degrades to "can't play this
/// format" instead of silently vanishing), but AVPlayer is never pointed at it.
/// Pure string / UTType work, so usable from the nonisolated reference type.
nonisolated enum AgentTranscriptMediaFormat {
    static let playableVideoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    static let playableAudioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "aiff", "aif", "caf", "flac",
    ]

    static func kind(forSource source: String) -> AgentTranscriptMediaKind? {
        let ext = pathExtension(ofSource: source)
        guard !ext.isEmpty else { return nil }
        if let type = UTType(filenameExtension: ext), !type.isDynamic {
            // Audio first: `public.audio` and `public.movie` both sit under
            // `public.audiovisual-content`, and an `.m4a` must not read as video.
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .movie) { return .video }
        }
        if playableVideoExtensions.contains(ext) { return .video }
        if playableAudioExtensions.contains(ext) { return .audio }
        return nil
    }

    static func isPlayable(source: String, kind: AgentTranscriptMediaKind) -> Bool {
        let ext = pathExtension(ofSource: source)
        switch kind {
        case .video: return playableVideoExtensions.contains(ext)
        case .audio: return playableAudioExtensions.contains(ext)
        }
    }

    /// Lower-cased extension of the path part of `source`. A query string or
    /// fragment (`clip.mp4?t=30`, `file:///a/b.mp3#x`) never counts as part of
    /// the extension.
    static func pathExtension(ofSource source: String) -> String {
        (pathPart(ofSource: source) as NSString).pathExtension.lowercased()
    }

    static func pathPart(ofSource source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("file://"), let url = URL(string: trimmed) {
            return url.path
        }
        return strippingQueryAndFragment(trimmed)
    }

    static func strippingQueryAndFragment(_ source: String) -> String {
        guard let cut = source.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return source }
        return String(source[..<cut])
    }
}

/// One standalone media line, exactly as the assistant wrote it.
nonisolated struct MarkdownMediaReference: Equatable, Hashable, Sendable {
    enum Syntax: String, Equatable, Hashable, Sendable {
        /// `![alt](path)`
        case image
        /// `[label](path)`
        case link
    }

    let syntax: Syntax
    /// Alt text or link label — may be empty.
    let label: String
    /// The raw source with render-only scalars removed.
    let source: String
    let kind: AgentTranscriptMediaKind
    /// The trimmed line as authored. Copy puts this back in place of the
    /// player, so a copied reply still carries a working reference.
    let markdown: String

    var fileName: String {
        let name = (AgentTranscriptMediaFormat.pathPart(ofSource: source) as NSString).lastPathComponent
        return name.isEmpty ? source : name
    }

    var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? fileName : trimmed
    }
}

enum MarkdownInlineMedia {
    /// A line that is nothing but an image or link reference to a *local*
    /// media file. Remote URLs return nil — an `![](https://…/a.mp4)` keeps the
    /// image fallback and a `[x](https://…/a.mp4)` stays an ordinary link.
    static func parseStandaloneMediaLine(_ line: String) -> MarkdownMediaReference? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let syntax: MarkdownMediaReference.Syntax
        let imageForm: String
        if trimmed.hasPrefix("![") {
            syntax = .image
            imageForm = trimmed
        } else if trimmed.hasPrefix("[") {
            // `[label](src)` has exactly the image grammar minus the bang, so
            // the image parser (title stripping, `<…>` paths, zero-width
            // cleanup) is reused rather than re-derived.
            syntax = .link
            imageForm = "!" + trimmed
        } else {
            return nil
        }
        guard let parsed = MarkdownInlineImage.parseStandaloneImageLine(imageForm),
              !MarkdownInlineImage.isRemoteSource(parsed.source),
              let kind = AgentTranscriptMediaFormat.kind(forSource: parsed.source) else {
            return nil
        }
        return MarkdownMediaReference(
            syntax: syntax,
            label: parsed.alt,
            source: parsed.source,
            kind: kind,
            markdown: trimmed
        )
    }
}

// MARK: - Resolution

enum AgentTranscriptMediaResolver {
    enum Resolution: Equatable {
        case playable(URL)
        /// The file exists but is not on the playable whitelist.
        case unsupported(URL)
        /// Nothing readable at the path. `revealURL` is the closest folder
        /// that does exist, so "Show in Finder" still lands somewhere useful.
        case missing(revealURL: URL?)
    }

    static func resolve(
        _ reference: MarkdownMediaReference,
        relativeTo baseURL: URL?
    ) -> Resolution {
        guard let url = localFileURL(for: reference.source, relativeTo: baseURL) else {
            return .missing(revealURL: nearestExistingFolder(for: reference.source, relativeTo: baseURL))
        }
        return AgentTranscriptMediaFormat.isPlayable(source: url.path, kind: reference.kind)
            ? .playable(url)
            : .unsupported(url)
    }

    /// Existing, non-directory local file for `source`, or nil. A trailing
    /// `?query` / `#fragment` is retried without it, so `clip.mp4?t=3` still
    /// finds `clip.mp4`.
    static func localFileURL(for source: String, relativeTo baseURL: URL?) -> URL? {
        if let url = MarkdownInlineImage.localFileURL(for: source, relativeTo: baseURL) {
            return url
        }
        let stripped = AgentTranscriptMediaFormat.strippingQueryAndFragment(source)
        guard stripped != source, !stripped.isEmpty else { return nil }
        return MarkdownInlineImage.localFileURL(for: stripped, relativeTo: baseURL)
    }

    static func nearestExistingFolder(for source: String, relativeTo baseURL: URL?) -> URL? {
        guard let candidate = candidateURL(for: source, relativeTo: baseURL) else { return nil }
        var folder = candidate.deletingLastPathComponent().standardizedFileURL
        while folder.path != "/" && !folder.path.isEmpty {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return folder
            }
            folder = folder.deletingLastPathComponent().standardizedFileURL
        }
        // Revealing the volume root helps nobody; leave the link off instead.
        return nil
    }

    /// Where `source` would live, without checking that it exists.
    static func candidateURL(for source: String, relativeTo baseURL: URL?) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !MarkdownInlineImage.isRemoteSource(trimmed) else { return nil }
        if trimmed.lowercased().hasPrefix("file://") {
            return URL(string: trimmed)?.standardizedFileURL
        }
        let expanded = (AgentTranscriptMediaFormat.strippingQueryAndFragment(trimmed) as NSString)
            .expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return baseURL?.appendingPathComponent(expanded).standardizedFileURL
    }

    /// The folder relative media paths resolve against. A remote workspace has
    /// none on this Mac — its relative paths name files on another machine.
    static func localBaseURL(
        workspaceLocation: WorkspaceLocation?,
        workspaceRootPath: String?
    ) -> URL? {
        let path: String?
        switch workspaceLocation {
        case .remote:
            return nil
        case .local(let localPath):
            path = localPath
        case nil:
            path = workspaceRootPath
        }
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
    }
}

// MARK: - Cache-key fingerprint

/// Media is resolved from message *content* plus the *file system*, so the
/// content hash alone cannot tell the render caches that a video appeared,
/// vanished, or was re-encoded. Both `AgentChatHistoryRenderer.messageHash`
/// and `AgentChatHistoryNSTextView.inputFingerprint` fold this in — one
/// without the other renders a stale body (the workflow-card lesson).
enum AgentTranscriptMediaFingerprint {
    /// Per-message parse results. `inputFingerprint` runs on every streaming
    /// flush and deliberately never walks content bytes, so the parse happens
    /// once per (message id, content length) — the same identity trade-off
    /// that fingerprint already makes.
    private struct CachedReferences {
        let contentCount: Int
        let references: [MarkdownMediaReference]
    }

    private static let lock = NSLock()
    private static var cache: [UUID: CachedReferences] = [:]
    private static let cacheLimit = 512
    /// Cheap pre-filter: every media line contains a Markdown link target,
    /// or is a bare `</abs/path.wav>` line the normalizer turns into one.
    private static let linkTargetMarker = "]("
    private static let angleBracketPathMarker = "</"

    static func references(in message: AgentMessage) -> [MarkdownMediaReference] {
        guard message.role == .assistant || message.role == .system else { return [] }
        let contentCount = message.content.utf16.count
        lock.lock()
        let cached = cache[message.id]
        lock.unlock()
        if let cached, cached.contentCount == contentCount {
            return cached.references
        }
        let references = parseReferences(in: message.content)
        lock.lock()
        if cache.count >= cacheLimit {
            cache.removeAll(keepingCapacity: true)
        }
        cache[message.id] = CachedReferences(contentCount: contentCount, references: references)
        lock.unlock()
        return references
    }

    static func parseReferences(in content: String) -> [MarkdownMediaReference] {
        guard content.contains(linkTargetMarker) || content.contains(angleBracketPathMarker) else { return [] }
        let normalized = AgentMarkdownNormalizer.normalizedForChatRendering(content)
        return MarkdownPreviewParser.blocks(from: normalized).compactMap(\.media)
    }

    static func combine(message: AgentMessage, baseURL: URL?, into hasher: inout Hasher) {
        let references = references(in: message)
        guard !references.isEmpty else { return }
        hasher.combine(references.count)
        for reference in references {
            hasher.combine(reference)
            switch AgentTranscriptMediaResolver.resolve(reference, relativeTo: baseURL) {
            case .playable(let url), .unsupported(let url):
                hasher.combine(url.path)
                hasher.combine(fileSignature(for: url))
            case .missing(let revealURL):
                hasher.combine("missing")
                hasher.combine(revealURL?.path)
            }
        }
    }

    struct FileSignature: Hashable {
        let byteCount: Int64
        let modifiedAt: TimeInterval
    }

    static func fileSignature(for url: URL) -> FileSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return FileSignature(
            byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? -1,
            modifiedAt: (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        )
    }
}
