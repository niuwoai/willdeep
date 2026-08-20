//
//  MarkdownInlineImage.swift
//  Xedit
//
//  Markdown image support for the chat transcript. Three renderers share
//  this file — the settled TextKit history (`AgentChatHistoryFormatter`),
//  the streaming SwiftUI body (`AgentMessageView`), and the editor's
//  preview pane (`MarkdownPreviewBlockView`) — so a `![alt](path)` line
//  looks the same wherever it lands.
//
//  Two deliberate restrictions:
//
//  1. **Local files only.** Assistant prose is model-controlled text. A
//     renderer that fetched `![](https://…)` would turn every reply into
//     a potential tracking pixel and leak "the user read this message"
//     to whoever authored the URL. Remote sources keep their existing
//     alt-text rendering; nothing goes out over the network.
//  2. **Standalone lines only.** Only a line that is *entirely* an image
//     becomes a picture. An image reference in the middle of a sentence
//     stays inline alt text, because a block-level attachment mid-
//     paragraph wrecks line layout.
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI

enum MarkdownInlineImage {
    struct Parsed: Equatable {
        var alt: String
        var source: String
    }

    /// Largest edge we decode to. Chat columns top out near 700pt, so a
    /// 2× budget covers Retina without holding a full 8K screenshot in
    /// memory for every rendered message.
    static let decodeMaxPixelSize: CGFloat = 1600

    /// Display cap. Width tracks the chat column; height is bounded so a
    /// tall full-page screenshot scrolls with the conversation instead of
    /// becoming the conversation.
    static let maxDisplayWidth: CGFloat = 560
    static let maxDisplayHeight: CGFloat = 420

    /// Small inline thumbnail used where an image is metadata rather than
    /// content (user-uploaded attachments echoed back in their own bubble).
    static let thumbnailMaxSide: CGFloat = 96

    // MARK: - Parsing

    /// Matches a line that is nothing but an image reference:
    /// `![alt](path)`, `![](path "title")`, `![alt](<path with spaces>)`.
    private static let standaloneImageRegex = try? NSRegularExpression(
        pattern: #"^!\[([^\]]*)\]\(\s*(<[^>]*>|[^\s)]+)(?:\s+(?:"[^"]*"|'[^']*'|\([^)]*\)))?\s*\)$"#
    )

    /// Returns the alt text and raw source for a line that is entirely an
    /// image reference, or nil for anything else (including a line that
    /// merely *contains* an image).
    static func parseStandaloneImageLine(_ line: String) -> Parsed? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")") else { return nil }
        guard let regex = standaloneImageRegex else { return nil }
        let ns = trimmed as NSString
        guard let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 3 else {
            return nil
        }
        let alt = ns.substring(with: match.range(at: 1))
        var source = ns.substring(with: match.range(at: 2))
        if source.hasPrefix("<") && source.hasSuffix(">") {
            source = String(source.dropFirst().dropLast())
        }
        let cleanedSource = strippingRenderOnlyScalars(source)
            .trimmingCharacters(in: .whitespaces)
        guard !cleanedSource.isEmpty else { return nil }
        return Parsed(alt: alt, source: cleanedSource)
    }

    /// `AgentLongTokenBreaker` injects U+200B breakpoints before the
    /// parser runs. Paths are dense in `/`, `.` and `-` (all natural
    /// breakers) so this rarely fires, but a zero-width scalar inside a
    /// path would otherwise turn a valid file into a silent miss.
    private static func strippingRenderOnlyScalars(_ raw: String) -> String {
        let renderOnly: Set<UInt32> = [0x200B, 0x2060, 0xFEFF, 0x00AD]
        guard raw.unicodeScalars.contains(where: { renderOnly.contains($0.value) }) else {
            return raw
        }
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars where !renderOnly.contains(scalar.value) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    // MARK: - Source resolution

    /// True for sources we refuse to fetch. Anything with a non-`file`
    /// scheme counts, so `http`, `https`, `data`, and any scheme added to
    /// the web platform later all fall through to alt text.
    static func isRemoteSource(_ source: String) -> Bool {
        guard let schemeEnd = source.range(of: "://") else {
            // `data:image/png;base64,…` has no `//`.
            if let colon = source.firstIndex(of: ":") {
                let scheme = source[source.startIndex..<colon].lowercased()
                return !scheme.isEmpty
                    && scheme != "file"
                    && scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
                    && scheme.count > 1 // keep Windows-style `C:` out of this branch
            }
            return false
        }
        let scheme = source[source.startIndex..<schemeEnd.lowerBound].lowercased()
        return scheme != "file"
    }

    /// Resolves a markdown image source to a readable local file, or nil
    /// when the source is remote, missing, or outside `baseURL` for a
    /// relative path. Never performs network access.
    static func localFileURL(for source: String, relativeTo baseURL: URL? = nil) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isRemoteSource(trimmed) else { return nil }

        let candidate: URL
        if trimmed.lowercased().hasPrefix("file://") {
            guard let url = URL(string: trimmed) else { return nil }
            candidate = url
        } else {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                candidate = URL(fileURLWithPath: expanded)
            } else if let baseURL {
                candidate = baseURL.appendingPathComponent(expanded)
            } else {
                // A relative path with no base to resolve against. Degrade
                // to alt text rather than guessing at the CWD.
                return nil
            }
        }

        let standardized = candidate.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return standardized
    }

    // MARK: - Loading and sizing

    /// Decodes a display-sized image. Uses `CGImageSource` thumbnailing so
    /// a large screenshot never fully decodes into memory — the same
    /// approach `AgentChatHistoryChromeRenderer` uses for attachments.
    static func loadImage(at url: URL, maxPixelSize: CGFloat = decodeMaxPixelSize) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let pixelSize = NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: pixelSize)
    }

    /// Fits `pixelSize` into the chat column. Screenshots arrive at Retina
    /// pixel dimensions, so this scales down aggressively; it never scales
    /// a small image *up*, which would just render it blurry.
    static func displaySize(
        pixelSize: NSSize,
        contentWidth: CGFloat,
        maxWidth: CGFloat = maxDisplayWidth,
        maxHeight: CGFloat = maxDisplayHeight
    ) -> NSSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            return NSSize(width: 0, height: 0)
        }
        // A Retina capture reports 2× the points it was taken at. Treat
        // the backing scale as the starting point so a 2560×1600 window
        // grab starts life as 1280×800 rather than filling the column at
        // half resolution.
        let backingScale = max(1, NSScreen.main?.backingScaleFactor ?? 2)
        let nativeSize = NSSize(
            width: pixelSize.width / backingScale,
            height: pixelSize.height / backingScale
        )
        let widthBudget = max(1, min(contentWidth, maxWidth))
        let scale = min(
            1,
            min(widthBudget / nativeSize.width, maxHeight / nativeSize.height)
        )
        return NSSize(
            width: max(1, (nativeSize.width * scale).rounded()),
            height: max(1, (nativeSize.height * scale).rounded())
        )
    }

    /// Shared fallback label for a source we will not render — a remote
    /// URL, a missing file, or bytes that fail to decode. Keeps the alt
    /// text readable instead of dropping the line silently.
    static func fallbackLabel(alt: String, source: String) -> String {
        let trimmedAlt = alt.trimmingCharacters(in: .whitespaces)
        if !trimmedAlt.isEmpty {
            return "▧ \(trimmedAlt)"
        }
        let trimmedSource = source.trimmingCharacters(in: .whitespaces)
        return trimmedSource.isEmpty ? "▧ Image" : "▧ \(trimmedSource)"
    }
}

/// SwiftUI rendering for a `.image` block. Used by the editor's preview
/// pane and the streaming assistant body; the settled transcript renders
/// the same block through TextKit instead.
struct MarkdownImageBlockView: View {
    let alt: String
    let source: String
    var typography: MarkdownPreviewTypography = .editorDefault
    var baseURL: URL? = nil
    var maxWidth: CGFloat = MarkdownInlineImage.maxDisplayWidth

    var body: some View {
        if let resolved {
            VStack(alignment: .leading, spacing: 4) {
                Image(nsImage: resolved.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: resolved.displaySize.width, maxHeight: resolved.displaySize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .onTapGesture { NSWorkspace.shared.open(resolved.url) }
                    .help(resolved.url.path)
                if !alt.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(alt)
                        .font(.system(size: max(10, typography.baseFontSize - 2)))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        } else {
            Text(MarkdownInlineImage.fallbackLabel(alt: alt, source: source))
                .font(.system(size: typography.baseFontSize))
                .foregroundColor(.secondary)
        }
    }

    private var resolved: (image: NSImage, url: URL, displaySize: NSSize)? {
        guard let url = MarkdownInlineImage.localFileURL(for: source, relativeTo: baseURL),
              let image = MarkdownInlineImage.loadImage(at: url) else {
            return nil
        }
        let size = MarkdownInlineImage.displaySize(
            pixelSize: image.size,
            contentWidth: maxWidth,
            maxWidth: maxWidth
        )
        return (image, url, size)
    }
}
