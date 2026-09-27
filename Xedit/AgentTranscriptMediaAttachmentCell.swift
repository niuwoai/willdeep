//
//  AgentTranscriptMediaAttachmentCell.swift
//  WillDeep
//
//  The placeholder a media line occupies in the TextKit flow, the geometry
//  the overlay uses to cover it, and the small async store that reads a
//  video's size and cover frame.
//

import AppKit
import AVFoundation
import Foundation
import OSLog

extension Notification.Name {
    /// Posted on the main actor when a video's size / cover finished loading.
    /// `userInfo[AgentTranscriptMediaMetadataStore.pathUserInfoKey]` is the path.
    static let agentTranscriptMediaMetadataDidLoad = Notification.Name("AgentTranscriptMediaMetadataDidLoad")
}

// MARK: - Geometry

/// Pure sizing math. Nonisolated because `NSTextAttachmentCell.cellSize()`
/// and friends are nonisolated overrides.
nonisolated enum AgentTranscriptMediaLayout {
    /// Width a player may use inside an assistant bubble: the chat column
    /// minus the assistant indents, capped like pictures.
    @MainActor
    static func widthBudget(layoutWidth: CGFloat) -> CGFloat {
        let resolved = AgentChatHistoryLayoutMetrics.resolvedLayoutWidth(layoutWidth)
        let available = resolved
            - AgentChatHistoryLayoutMetrics.assistantContentHeadIndent
            - AgentChatHistoryLayoutMetrics.assistantContentTailInset
        return max(
            AgentTranscriptMediaMetrics.minimumWidth,
            min(AgentTranscriptMediaMetrics.maxDisplayWidth, available)
        ).rounded(.down)
    }

    /// Placeholder size. Video keeps its aspect ratio inside the picture cap
    /// (a portrait clip is height-limited, not stretched); audio is a
    /// compact full-width bar.
    static func displaySize(
        kind: AgentTranscriptMediaKind,
        presentationSize: CGSize?,
        widthBudget: CGFloat
    ) -> NSSize {
        switch kind {
        case .audio:
            return NSSize(width: widthBudget, height: AgentTranscriptMediaMetrics.audioBarHeight)
        case .video:
            let aspect: CGFloat
            if let presentationSize, presentationSize.width > 0, presentationSize.height > 0 {
                aspect = presentationSize.width / presentationSize.height
            } else {
                aspect = AgentTranscriptMediaMetrics.defaultVideoAspectRatio
            }
            var width = widthBudget
            var height = width / aspect
            if height > AgentTranscriptMediaMetrics.maxVideoHeight {
                height = AgentTranscriptMediaMetrics.maxVideoHeight
                width = height * aspect
            }
            // Very tall clips would leave no room for the controls; the
            // player letterboxes instead.
            width = max(AgentTranscriptMediaMetrics.minimumVideoWidth, min(widthBudget, width))
            return NSSize(width: width.rounded(), height: max(1, height.rounded()))
        }
    }

    /// Where the player view goes, in text-view coordinates. Pure: the
    /// inputs are exactly what `NSLayoutManager` reports for the placeholder
    /// glyph. TextKit's container space is flipped and the glyph location is
    /// the baseline, so an attachment sitting on the baseline spans
    /// `[baseline - height, baseline]`.
    static func playerFrame(
        lineFragmentRect: NSRect,
        glyphLocation: NSPoint,
        attachmentSize: NSSize,
        textContainerOrigin: NSPoint
    ) -> NSRect {
        let baselineY = lineFragmentRect.minY + glyphLocation.y
        return NSRect(
            x: (textContainerOrigin.x + lineFragmentRect.minX + glyphLocation.x).rounded(),
            y: (textContainerOrigin.y + baselineY - attachmentSize.height).rounded(),
            width: attachmentSize.width.rounded(),
            height: attachmentSize.height.rounded()
        )
    }

    /// Frame for the placeholder at `characterIndex`, or nil when that
    /// character is not a laid-out attachment.
    @MainActor
    static func playerFrame(
        forCharacterAt characterIndex: Int,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        textContainerOrigin: NSPoint
    ) -> NSRect? {
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        layoutManager.ensureLayout(forGlyphRange: NSRange(location: glyphIndex, length: 1))
        guard layoutManager.textContainer(forGlyphAt: glyphIndex, effectiveRange: nil) === textContainer else {
            return nil
        }
        let size = layoutManager.attachmentSize(forGlyphAt: glyphIndex)
        guard size.width > 0, size.height > 0 else { return nil }
        return playerFrame(
            lineFragmentRect: layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil),
            glyphLocation: layoutManager.location(forGlyphAt: glyphIndex),
            attachmentSize: size,
            textContainerOrigin: textContainerOrigin
        )
    }
}

// MARK: - Placeholder cell

/// TextKit 1 attachment cell. Draws the cover (or a neutral panel) so the
/// transcript never shows an empty hole where a player is not mounted —
/// offscreen, over the live-player cap, or in a reader window.
final class AgentTranscriptMediaAttachmentCell: NSTextAttachmentCell {
    let payload: AgentTranscriptMediaPayload
    // TextKit asks for the size through nonisolated overrides, so what the
    // size depends on is copied into plain Sendable values.
    private nonisolated let kind: AgentTranscriptMediaKind
    private nonisolated let mediaPath: String
    private nonisolated let widthBudget: CGFloat
    /// Every layout manager that drew this cell; re-laid out when the
    /// video's real aspect ratio arrives. Weak: cells live on in the
    /// renderer cache long after a text view is gone. (The chat transcript's
    /// overlay also re-lays out its own placeholders, drawn or not.)
    private let layoutManagers = NSHashTable<NSLayoutManager>.weakObjects()

    init(payload: AgentTranscriptMediaPayload, widthBudget: CGFloat) {
        self.payload = payload
        self.kind = payload.kind
        self.mediaPath = payload.url.path
        self.widthBudget = widthBudget
        super.init(imageCell: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataDidLoad(_:)),
            name: .agentTranscriptMediaMetadataDidLoad,
            object: nil
        )
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated var displaySize: NSSize {
        AgentTranscriptMediaLayout.displaySize(
            kind: kind,
            presentationSize: AgentTranscriptMediaSizeCache.presentationSize(forPath: mediaPath),
            widthBudget: widthBudget
        )
    }

    nonisolated override func cellSize() -> NSSize {
        displaySize
    }

    nonisolated override func cellBaselineOffset() -> NSPoint {
        .zero
    }

    nonisolated override func cellFrame(
        for textContainer: NSTextContainer,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        NSRect(origin: .zero, size: displaySize)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        AgentTranscriptMediaPlaceholderArtwork.draw(
            kind: payload.kind,
            title: payload.displayName,
            cover: AgentTranscriptMediaMetadataStore.shared.metadata(for: payload.url)?.cover,
            in: cellFrame
        )
    }

    override func draw(
        withFrame cellFrame: NSRect,
        in controlView: NSView?,
        characterIndex charIndex: Int,
        layoutManager: NSLayoutManager
    ) {
        layoutManagers.add(layoutManager)
        draw(withFrame: cellFrame, in: controlView)
    }

    // Clicks fall through to the text view, which routes the `.link` on the
    // placeholder character (open the player window).
    override func wantsToTrackMouse() -> Bool {
        false
    }

    override func wantsToTrackMouse(
        for theEvent: NSEvent,
        in cellFrame: NSRect,
        of controlView: NSView?,
        atCharacterIndex charIndex: Int
    ) -> Bool {
        false
    }

    @objc private func metadataDidLoad(_ notification: Notification) {
        guard (notification.userInfo?[AgentTranscriptMediaMetadataStore.pathUserInfoKey] as? String)
                == payload.url.path,
              let attachment else {
            return
        }
        for layoutManager in layoutManagers.allObjects {
            guard let storage = layoutManager.textStorage,
                  let range = Self.characterRange(of: attachment, in: storage) else {
                continue
            }
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: range)
            for container in layoutManager.textContainers {
                container.textView?.invalidateIntrinsicContentSize()
            }
        }
    }

    private static func characterRange(of attachment: NSTextAttachment, in storage: NSTextStorage) -> NSRange? {
        var found: NSRange?
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            if (value as? NSTextAttachment) === attachment {
                found = range
                stop.pointee = true
            }
        }
        return found
    }
}

enum AgentTranscriptMediaPlaceholderArtwork {
    static func draw(
        kind: AgentTranscriptMediaKind,
        title: String,
        cover: NSImage?,
        in rect: NSRect
    ) {
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = AgentTranscriptMediaMetrics.cornerRadius
        let outline = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        switch kind {
        case .video:
            NSColor.black.withAlphaComponent(AgentTranscriptMediaMetrics.videoPanelOpacity).setFill()
            rect.fill()
            if let cover {
                cover.draw(
                    in: aspectFillRect(for: cover.size, in: rect),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: nil
                )
            }
            drawSymbol(
                "play.circle.fill",
                pointSize: AgentTranscriptMediaMetrics.placeholderSymbolPointSize,
                color: NSColor.white.withAlphaComponent(AgentTranscriptMediaMetrics.videoSymbolOpacity),
                centeredIn: rect
            )
        case .audio:
            NSColor.quaternaryLabelColor.setFill()
            rect.fill()
            let symbolRect = NSRect(
                x: rect.minX + AgentTranscriptMediaMetrics.audioLabelInset,
                y: rect.minY,
                width: AgentTranscriptMediaMetrics.audioSymbolPointSize * 2,
                height: rect.height
            )
            drawSymbol(
                "waveform",
                pointSize: AgentTranscriptMediaMetrics.audioSymbolPointSize,
                color: NSColor.secondaryLabelColor,
                centeredIn: symbolRect
            )
            let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            let textHeight = font.ascender - font.descender
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            (title as NSString).draw(
                in: NSRect(
                    x: symbolRect.maxX,
                    y: rect.midY - textHeight / 2,
                    width: max(0, rect.maxX - symbolRect.maxX - AgentTranscriptMediaMetrics.audioLabelInset),
                    height: textHeight
                ),
                withAttributes: [
                    .font: font,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph,
                ]
            )
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    static func aspectFillRect(for imageSize: NSSize, in rect: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func drawSymbol(
        _ name: String,
        pointSize: CGFloat,
        color: NSColor,
        centeredIn rect: NSRect
    ) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return
        }
        let size = symbol.size
        symbol.draw(
            in: NSRect(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }
}

// MARK: - Metadata

/// The one piece of metadata layout needs, readable from TextKit's
/// nonisolated size callbacks. Written by the store below.
nonisolated enum AgentTranscriptMediaSizeCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sizes: [String: CGSize] = [:]

    static func presentationSize(forPath path: String) -> CGSize? {
        lock.lock()
        defer { lock.unlock() }
        return sizes[path]
    }

    static func store(_ size: CGSize?, forPath path: String) {
        lock.lock()
        defer { lock.unlock() }
        sizes[path] = size
    }
}

/// Video size (preferred transform applied) and a cover frame, read once per
/// file version with AVFoundation's async loaders. Audio needs neither.
@MainActor
final class AgentTranscriptMediaMetadataStore {
    static let shared = AgentTranscriptMediaMetadataStore()
    static let pathUserInfoKey = "path"

    struct Metadata {
        /// Nil when the file has no readable video track.
        let presentationSize: CGSize?
        let cover: NSImage?
    }

    private struct Entry {
        let signature: AgentTranscriptMediaFingerprint.FileSignature?
        let metadata: Metadata
    }

    private static let entryLimit = 64
    private static let logger = Logger(subsystem: "com.willdeep.app", category: "transcript-media")

    private var entries: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    private var inFlight: Set<String> = []

    func metadata(for url: URL) -> Metadata? {
        entries[url.path]?.metadata
    }

    func prefetch(url: URL, kind: AgentTranscriptMediaKind) {
        guard kind == .video else { return }
        let path = url.path
        let signature = AgentTranscriptMediaFingerprint.fileSignature(for: url)
        if let entry = entries[path], entry.signature == signature { return }
        guard !inFlight.contains(path) else { return }
        inFlight.insert(path)
        Task { [weak self] in
            let metadata = await Self.loadMetadata(url: url)
            self?.finish(path: path, signature: signature, metadata: metadata)
        }
    }

    private func finish(
        path: String,
        signature: AgentTranscriptMediaFingerprint.FileSignature?,
        metadata: Metadata
    ) {
        inFlight.remove(path)
        if entries[path] == nil {
            insertionOrder.append(path)
        }
        entries[path] = Entry(signature: signature, metadata: metadata)
        AgentTranscriptMediaSizeCache.store(metadata.presentationSize, forPath: path)
        while insertionOrder.count > Self.entryLimit {
            let evicted = insertionOrder.removeFirst()
            entries.removeValue(forKey: evicted)
            AgentTranscriptMediaSizeCache.store(nil, forPath: evicted)
        }
        NotificationCenter.default.post(
            name: .agentTranscriptMediaMetadataDidLoad,
            object: nil,
            userInfo: [Self.pathUserInfoKey: path]
        )
    }

    private static func loadMetadata(url: URL) async -> Metadata {
        let asset = AVURLAsset(url: url)
        let presentationSize: CGSize?
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return Metadata(presentationSize: nil, cover: nil)
            }
            let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
            let oriented = naturalSize.applying(transform)
            presentationSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        } catch {
            logger.error(
                "Reading video size failed for \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)"
            )
            return Metadata(presentationSize: nil, cover: nil)
        }
        do {
            let duration = try await asset.load(.duration).seconds
            let seconds = duration.isFinite && duration > 0
                ? min(AgentTranscriptMediaMetrics.coverTimeSeconds, duration * AgentTranscriptMediaMetrics.coverTimeFraction)
                : 0
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(
                width: AgentTranscriptMediaMetrics.coverMaxPixelSize,
                height: AgentTranscriptMediaMetrics.coverMaxPixelSize
            )
            let frame = try await generator.image(
                at: CMTime(seconds: seconds, preferredTimescale: AgentTranscriptMediaMetrics.timeScale)
            ).image
            let cover = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
            return Metadata(presentationSize: presentationSize, cover: cover)
        } catch {
            // The size is still worth keeping: the placeholder gets the right
            // shape, it just stays a plain panel under the player.
            logger.error(
                "Extracting a cover frame failed for \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)"
            )
            return Metadata(presentationSize: presentationSize, cover: nil)
        }
    }
}
