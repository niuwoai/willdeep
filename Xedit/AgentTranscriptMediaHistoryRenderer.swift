//
//  AgentTranscriptMediaHistoryRenderer.swift
//  WillDeep
//
//  TextKit side of inline media. The settled transcript is one baked
//  NSAttributedString on a TextKit 1 stack, which cannot host views inside the
//  text flow (`NSTextAttachmentViewProvider` is TextKit 2 only). So the
//  formatter emits a fixed-size placeholder attachment tagged with a media id,
//  and `AgentTranscriptMediaOverlayController` lays a real `AVPlayerView` over
//  the placeholder's rect after every layout.
//
//  Player state must never hang off the NSTextAttachment: hover, search and
//  expand all swap the whole attributed string, and the renderer keeps a
//  32-entry cache of old ones. The only stable handle is the media id
//  (message id + ordinal inside that message), which the overlay composes.
//

import AppKit
import Foundation

extension NSAttributedString.Key {
    /// Per-message ordinal of a playable media placeholder ("media-0", …).
    /// The overlay prefixes it with the message id to get a transcript-wide id.
    static let agentChatHistoryMediaID = NSAttributedString.Key("AgentChatHistoryMediaID")
    /// `AgentTranscriptMediaPayload` for the placeholder character.
    static let agentChatHistoryMedia = NSAttributedString.Key("AgentChatHistoryMedia")
    /// File or folder the "Show in Finder" link of a degraded media line reveals.
    static let agentChatHistoryMediaRevealPath = NSAttributedString.Key("AgentChatHistoryMediaRevealPath")
    /// `AgentTranscriptCopySubstitute`: the text copy puts back for a rendered
    /// range that is not itself copyable text (a player, a fallback line).
    static let agentChatHistoryCopySubstitute = NSAttributedString.Key("AgentChatHistoryCopySubstitute")
}

enum AgentTranscriptMediaLink {
    static let playValue = "agent-chat-history-media"
    static let revealValue = "agent-chat-history-media-reveal"
}

/// Plain constants, nonisolated because TextKit asks the attachment cell for
/// its size from nonisolated overrides.
nonisolated enum AgentTranscriptMediaMetrics {
    /// Same column cap as pictures (`MarkdownInlineImage.maxDisplayWidth` /
    /// `maxDisplayHeight`), so a video and a screenshot line up. Literals
    /// because those live on a main-actor type; a test keeps them equal.
    static let maxDisplayWidth: CGFloat = 560
    static let maxVideoHeight: CGFloat = 420
    /// Below this the inline scrubber and volume control stop fitting.
    static let minimumWidth: CGFloat = 240
    static let minimumVideoWidth: CGFloat = 160
    /// Used until the video's real dimensions have been read.
    static let defaultVideoAspectRatio: CGFloat = 16.0 / 9.0
    static let cornerRadius: CGFloat = 6
    /// Letterbox panel behind a video cover, and the play glyph on top of it.
    static let videoPanelOpacity: CGFloat = 0.85
    static let videoSymbolOpacity: CGFloat = 0.9
    static let captionFontSizeDelta: CGFloat = 2
    static let captionMinimumFontSize: CGFloat = 10
    static let placeholderSymbolPointSize: CGFloat = 34
    static let audioSymbolPointSize: CGFloat = 15
    static let audioLabelInset: CGFloat = 12
    static let coverMaxPixelSize: CGFloat = 1120
    /// Cover frame: a second in, or 10% into a shorter clip — frame zero is
    /// often a black fade-in.
    static let coverTimeSeconds: Double = 1
    static let coverTimeFraction: Double = 0.1
    /// CMTime timescale for seeks and cover requests (divisible by 24/25/30 fps).
    static let timeScale: Int32 = 600
    /// Live AVPlayer + AVPlayerView pairs per transcript. Placeholders beyond
    /// this still draw their cover; clicking one opens the player window.
    static let maxLivePlayers = 6
    /// Players are created this far above / below the viewport so scrolling
    /// onto one does not show a bare cover first.
    static let nearVisibleMargin: CGFloat = 480
    /// Evicted players remember position + volume for this many ids.
    static let resumeStateLimit = 64
}

/// What the placeholder character carries: everything the overlay and the
/// standalone player window need, and nothing stateful.
final class AgentTranscriptMediaPayload: NSObject {
    let localID: String
    let url: URL
    let kind: AgentTranscriptMediaKind
    let displayName: String

    init(localID: String, url: URL, kind: AgentTranscriptMediaKind, displayName: String) {
        self.localID = localID
        self.url = url
        self.kind = kind
        self.displayName = displayName
    }
}

// MARK: - Copy restoration

final class AgentTranscriptCopySubstitute: NSObject {
    let text: String

    init(text: String) {
        self.text = text
    }
}

/// A copied selection that crosses a player gets the Markdown line back
/// instead of U+FFFC (plain text) or a cover image (RTFD). Any part of a
/// substituted range copies the *whole* substitute, once.
enum AgentTranscriptCopySubstitution {
    static func restoring(_ attributed: NSAttributedString) -> NSAttributedString {
        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0 else { return attributed }
        var hasSubstitute = false
        attributed.enumerateAttribute(.agentChatHistoryCopySubstitute, in: fullRange) { value, _, stop in
            if value is AgentTranscriptCopySubstitute {
                hasSubstitute = true
                stop.pointee = true
            }
        }
        guard hasSubstitute else { return attributed }

        let restored = NSMutableAttributedString()
        var previous: AgentTranscriptCopySubstitute?
        attributed.enumerateAttribute(.agentChatHistoryCopySubstitute, in: fullRange) { value, range, _ in
            guard let substitute = value as? AgentTranscriptCopySubstitute else {
                restored.append(attributed.attributedSubstring(from: range))
                previous = nil
                return
            }
            guard substitute !== previous else { return }
            previous = substitute
            var attributes: [NSAttributedString.Key: Any] = [:]
            let source = attributed.attributes(at: range.location, effectiveRange: nil)
            attributes[.font] = source[.font]
            attributes[.foregroundColor] = source[.foregroundColor]
            attributes[.paragraphStyle] = source[.paragraphStyle]
            restored.append(NSAttributedString(string: substitute.text, attributes: attributes))
        }
        return restored
    }

    static func plainText(of attributed: NSAttributedString) -> String {
        restoring(attributed).string
    }
}

// MARK: - Formatter entry point

enum AgentTranscriptMediaHistoryRenderer {
    /// Appends one `.media` block. A playable file becomes a placeholder
    /// attachment plus a caption line; a missing or unplayable one becomes a
    /// single explanatory line with a "Show in Finder" link — never an empty
    /// frame. Either way the whole block copies back as its Markdown line.
    static func appendMediaBlock(
        _ reference: MarkdownMediaReference?,
        ordinal: Int,
        to result: NSMutableAttributedString,
        bodyFont: NSFont,
        secondaryColor: NSColor,
        layoutWidth: CGFloat,
        baseURL: URL?
    ) {
        guard let reference else { return }
        let blockStart = result.length
        switch AgentTranscriptMediaResolver.resolve(reference, relativeTo: baseURL) {
        case .playable(let url):
            appendPlaceholder(
                reference: reference,
                url: url,
                ordinal: ordinal,
                to: result,
                bodyFont: bodyFont,
                secondaryColor: secondaryColor,
                layoutWidth: layoutWidth
            )
        case .unsupported(let url):
            appendFallbackLine(
                fileName: reference.fileName,
                reason: L10n.TranscriptMedia.unsupportedFormat,
                revealURL: url,
                to: result,
                bodyFont: bodyFont,
                secondaryColor: secondaryColor
            )
        case .missing(let revealURL):
            appendFallbackLine(
                fileName: reference.fileName,
                reason: L10n.TranscriptMedia.fileNotFound,
                revealURL: revealURL,
                to: result,
                bodyFont: bodyFont,
                secondaryColor: secondaryColor
            )
        }
        guard result.length > blockStart else { return }
        result.addAttribute(
            .agentChatHistoryCopySubstitute,
            value: AgentTranscriptCopySubstitute(text: reference.markdown),
            range: NSRange(location: blockStart, length: result.length - blockStart)
        )
    }

    /// The streaming bubble is one SwiftUI `Text`; it never hosts a player
    /// (rich SwiftUI content during streaming is what ran memory away
    /// before). A file-name line stands in until the turn settles.
    static func streamingPlaceholderLabel(for reference: MarkdownMediaReference?) -> String {
        guard let reference else { return "" }
        switch reference.kind {
        case .video:
            return "▶︎ " + L10n.TranscriptMedia.streamingVideo(reference.displayName)
        case .audio:
            return "♪ " + L10n.TranscriptMedia.streamingAudio(reference.displayName)
        }
    }

    private static func appendPlaceholder(
        reference: MarkdownMediaReference,
        url: URL,
        ordinal: Int,
        to result: NSMutableAttributedString,
        bodyFont: NSFont,
        secondaryColor: NSColor,
        layoutWidth: CGFloat
    ) {
        let payload = AgentTranscriptMediaPayload(
            localID: "media-\(ordinal)",
            url: url,
            kind: reference.kind,
            displayName: reference.displayName
        )
        let attachment = NSTextAttachment()
        attachment.attachmentCell = AgentTranscriptMediaAttachmentCell(
            payload: payload,
            widthBudget: AgentTranscriptMediaLayout.widthBudget(layoutWidth: layoutWidth)
        )
        let placeholderStart = result.length
        result.append(NSAttributedString(attachment: attachment))
        result.addAttributes([
            .agentChatHistoryMediaID: payload.localID,
            .agentChatHistoryMedia: payload,
            .link: AgentTranscriptMediaLink.playValue,
            .cursor: NSCursor.arrow,
            .toolTip: url.path,
        ], range: NSRange(location: placeholderStart, length: result.length - placeholderStart))
        // The caption keeps the file findable with ⌘F and names an audio
        // bar, which has no picture of its own.
        result.append(NSAttributedString(
            string: "\n\(reference.displayName)",
            attributes: [
                .font: NSFont.systemFont(ofSize: max(
                    AgentTranscriptMediaMetrics.captionMinimumFontSize,
                    bodyFont.pointSize - AgentTranscriptMediaMetrics.captionFontSizeDelta
                )),
                .foregroundColor: secondaryColor,
            ]
        ))
        AgentTranscriptMediaMetadataStore.shared.prefetch(url: url, kind: reference.kind)
    }

    private static func appendFallbackLine(
        fileName: String,
        reason: String,
        revealURL: URL?,
        to result: NSMutableAttributedString,
        bodyFont: NSFont,
        secondaryColor: NSColor
    ) {
        let font = NSFont.systemFont(ofSize: bodyFont.pointSize, weight: .medium)
        result.append(NSAttributedString(
            string: "⚠︎ \(fileName) — \(reason)",
            attributes: [
                .font: font,
                .foregroundColor: secondaryColor,
            ]
        ))
        guard let revealURL else { return }
        result.append(NSAttributedString(string: "  ", attributes: [.font: font]))
        result.append(NSAttributedString(
            string: L10n.TranscriptMedia.showInFinder,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.linkColor,
                .link: AgentTranscriptMediaLink.revealValue,
                .agentChatHistoryMediaRevealPath: revealURL.path,
                .cursor: NSCursor.pointingHand,
                .toolTip: revealURL.path,
            ]
        ))
    }
}

// MARK: - Click routing

/// Shared by the chat transcript and the reader windows (plain NSTextViews
/// that reuse the renderer but never get an overlay).
enum AgentTranscriptMediaLinkRouter {
    /// Returns true when the click landed on a media placeholder or a
    /// "Show in Finder" link and was handled.
    static func handleClick(in textView: NSTextView, at characterIndex: Int) -> Bool {
        guard let storage = textView.textStorage,
              characterIndex >= 0,
              characterIndex < storage.length else {
            return false
        }
        if let path = storage.attribute(
            .agentChatHistoryMediaRevealPath,
            at: characterIndex,
            effectiveRange: nil
        ) as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return true
        }
        if let payload = storage.attribute(
            .agentChatHistoryMedia,
            at: characterIndex,
            effectiveRange: nil
        ) as? AgentTranscriptMediaPayload {
            AgentTranscriptMediaPlayerWindowRegistry.shared.open(payload: payload)
            return true
        }
        return false
    }

    static func isMediaLink(_ link: Any) -> Bool {
        let value = (link as? String) ?? (link as? NSString).map { $0 as String }
        return value == AgentTranscriptMediaLink.playValue || value == AgentTranscriptMediaLink.revealValue
    }
}
