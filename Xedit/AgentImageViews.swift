//
//  AgentImageViews.swift
//  WillDeep
//
//  Shared SwiftUI views for rendering Agent image attachments (composer
//  thumbnails with a remove affordance, plus the read-only thumbnails
//  shown inside sent message bubbles).
//

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

nonisolated enum AgentThumbnailImageCache {
    private nonisolated final class ImageStore: @unchecked Sendable {
        private let cache = NSCache<NSString, NSImage>()

        func image(for key: NSString) -> NSImage? {
            cache.object(forKey: key)
        }

        func store(_ image: NSImage, for key: NSString) {
            cache.setObject(image, forKey: key)
        }
    }

    private nonisolated final class ImageBox: @unchecked Sendable {
        let image: NSImage

        init(_ image: NSImage) {
            self.image = image
        }
    }

    private static let store = ImageStore()

    static func image(forFileURL url: URL, targetPixels: CGFloat) async -> NSImage? {
        let targetPixels = max(1, Int(targetPixels.rounded(.up)))
        let modificationTime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let key = "\(url.standardizedFileURL.path)|\(modificationTime)|\(targetPixels)" as NSString
        if let cached = store.image(for: key) {
            return cached
        }

        return await Task.detached(priority: .utility) { () -> ImageBox? in
            guard let image = downsampledImage(from: url as CFURL, targetPixels: targetPixels) else {
                return nil
            }
            store.store(image, for: key)
            return ImageBox(image)
        }.value?.image
    }

    static func image(forBase64 base64: String, cacheKey: String, targetPixels: CGFloat) async -> NSImage? {
        let targetPixels = max(1, Int(targetPixels.rounded(.up)))
        let key = "base64|\(cacheKey)|\(base64.count)|\(targetPixels)" as NSString
        if let cached = store.image(for: key) {
            return cached
        }

        return await Task.detached(priority: .utility) { () -> ImageBox? in
            guard let data = Data(base64Encoded: base64),
                  let image = downsampledImage(from: data as CFData, targetPixels: targetPixels) else {
                return nil
            }
            store.store(image, for: key)
            return ImageBox(image)
        }.value?.image
    }

    private static func downsampledImage(from url: CFURL, targetPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        return downsampledImage(from: source, targetPixels: targetPixels)
    }

    private static func downsampledImage(from data: CFData, targetPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data, nil) else { return nil }
        return downsampledImage(from: source, targetPixels: targetPixels)
    }

    private static func downsampledImage(from source: CGImageSource, targetPixels: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: targetPixels
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

enum AgentGeneratedImageAttachmentFactory {
    private static let previewLongEdge: CGFloat = 768
    private static let previewQuality: CGFloat = 0.86

    static func attachment(
        fileURL: URL,
        model: String,
        prompt: String?,
        createdAt: Date = Date()
    ) throws -> AgentImageAttachment {
        let info = try ImageWorkflowSupport.loadImage(path: fileURL.path)
        let preview = downscaledPreview(info.image)
        guard let jpegData = jpegData(from: preview) else {
            throw AgentToolError.invalidArgument("Could not encode generated image preview.")
        }
        return AgentImageAttachment(
            mimeType: "image/jpeg",
            dataBase64: jpegData.base64EncodedString(),
            source: .generated,
            filePath: fileURL.standardizedFileURL.path,
            model: model,
            prompt: prompt,
            createdAt: createdAt
        )
    }

    static func attachments(
        from artifacts: [AgentMediaArtifact],
        model: String?,
        prompt: String?
    ) -> [AgentImageAttachment] {
        artifacts.compactMap { artifact in
            guard isImageArtifact(artifact) else { return nil }
            let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedModel = trimmedModel?.isEmpty == false
                ? trimmedModel ?? SomeIMIntegrationSettings.defaultImageModel
                : SomeIMIntegrationSettings.defaultImageModel
            return try? attachment(
                fileURL: URL(fileURLWithPath: artifact.filePath),
                model: resolvedModel,
                prompt: prompt
            )
        }
    }

    private static func isImageArtifact(_ artifact: AgentMediaArtifact) -> Bool {
        if let mimeType = artifact.mimeType?.lowercased(), mimeType.hasPrefix("image/") {
            return true
        }
        return AgentImagePasteboardHelper.mimeType(forPath: artifact.filePath) != nil
    }

    private static func downscaledPreview(_ image: CGImage) -> CGImage {
        let longEdge = CGFloat(max(image.width, image.height))
        guard longEdge > previewLongEdge else { return image }
        let scale = previewLongEdge / longEdge
        let target = CGSize(
            width: max(1, (CGFloat(image.width) * scale).rounded()),
            height: max(1, (CGFloat(image.height) * scale).rounded())
        )
        return ImageWorkflowSupport.fit(image, within: target)
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let flattened = ImageWorkflowSupport.flatten(image, background: .white)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, flattened, [
            kCGImageDestinationLossyCompressionQuality: previewQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

struct AgentImageThumbnail: View {
    let image: AgentImageAttachment
    let size: CGFloat
    let allowsRemoval: Bool
    let onRemove: (() -> Void)?
    var onPreview: (() -> Void)? = nil
    @State private var decodedImage: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let nsImage = decodedImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .task(id: "\(image.thumbnailCacheKey)-\(Int(size.rounded(.up)))") {
                if let fileURL = image.fileURL {
                    decodedImage = await AgentThumbnailImageCache.image(
                        forFileURL: fileURL,
                        targetPixels: size * 2
                    )
                } else {
                    decodedImage = await AgentThumbnailImageCache.image(
                        forBase64: image.dataBase64,
                        cacheKey: image.thumbnailCacheKey,
                        targetPixels: size * 2
                    )
                }
            }

            if allowsRemoval, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .padding(3)
                .help("Remove image")
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
            onPreview?()
        }
        .help(onPreview == nil ? "" : L10n.ImagePreview.openButton)
    }
}

struct AgentUserImageStrip: View {
    let images: [AgentImageAttachment]
    var thumbnailSize: CGFloat = 96

    var body: some View {
        ViewThatFits(in: .horizontal) {
            thumbnails
                .fixedSize(horizontal: true, vertical: false)

            ScrollView(.horizontal, showsIndicators: false) {
                thumbnails
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var thumbnails: some View {
        HStack(spacing: 6) {
            ForEach(images) { image in
                AgentImageThumbnail(
                    image: image,
                    size: thumbnailSize,
                    allowsRemoval: false,
                    onRemove: nil,
                    onPreview: { AgentImagePreviewWindowRegistry.shared.open(image: image) }
                )
            }
        }
    }
}

@MainActor
final class AgentImagePreviewWindowRegistry {
    static let shared = AgentImagePreviewWindowRegistry()

    private var windows: [UUID: AgentImagePreviewWindowController] = [:]

    func open(image: AgentImageAttachment) {
        if let existing = windows[image.id] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = AgentImagePreviewWindowController(image: image)
        controller.onClose = { [weak self] imageID in
            self?.windows.removeValue(forKey: imageID)
        }
        windows[image.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class AgentImagePreviewWindowController: NSWindowController, NSWindowDelegate {
    var onClose: ((UUID) -> Void)?

    private let imageID: UUID
    private var keyMonitor: Any?

    init(image attachment: AgentImageAttachment) {
        imageID = attachment.id
        let image = Self.previewImage(for: attachment)
        let title = Self.windowTitle(for: attachment)
        let content = AgentImagePreviewWindowContent(image: image, title: title)
        let hostingView = NSHostingView(rootView: content)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320)

        super.init(window: window)
        window.delegate = self
        keyMonitor = AuxiliaryWindowCloseShortcut.install(on: window, closesOnEscape: true)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        onClose?(imageID)
    }

    private static func previewImage(for attachment: AgentImageAttachment) -> NSImage? {
        if let fileURL = attachment.fileURL,
           let image = NSImage(contentsOf: fileURL) {
            return image
        }
        guard !attachment.dataBase64.isEmpty,
              let data = Data(base64Encoded: attachment.dataBase64) else {
            return nil
        }
        return NSImage(data: data)
    }

    private static func windowTitle(for attachment: AgentImageAttachment) -> String {
        if let fileURL = attachment.fileURL, !fileURL.lastPathComponent.isEmpty {
            return fileURL.lastPathComponent
        }
        return L10n.ImagePreview.windowTitle
    }
}

private struct AgentImagePreviewWindowContent: View {
    private enum Metrics {
        static let minimumZoom: CGFloat = 0.25
        static let maximumZoom: CGFloat = 4
        static let zoomStep: CGFloat = 0.25
        static let imagePadding: CGFloat = 24
    }

    let image: NSImage?
    let title: String
    @State private var zoom: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            preview
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if let image {
                Text("\(Int(image.size.width.rounded())) × \(Int(image.size.height.rounded()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            zoomButton(systemName: "minus.magnifyingglass", label: L10n.ImagePreview.zoomOut) {
                zoom = max(Metrics.minimumZoom, zoom - Metrics.zoomStep)
            }
            Text("\(Int((zoom * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48)
            zoomButton(systemName: "plus.magnifyingglass", label: L10n.ImagePreview.zoomIn) {
                zoom = min(Metrics.maximumZoom, zoom + Metrics.zoomStep)
            }
            Button(L10n.ImagePreview.fitButton) {
                zoom = 1
            }
            .buttonStyle(.borderless)
            .help(L10n.ImagePreview.fitButton)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var preview: some View {
        if let image {
            GeometryReader { geometry in
                let fittedSize = fitSize(image.size, in: geometry.size)
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(
                            width: fittedSize.width * zoom,
                            height: fittedSize.height * zoom
                        )
                        .padding(Metrics.imagePadding)
                        .frame(
                            minWidth: geometry.size.width,
                            minHeight: geometry.size.height
                        )
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            zoom = zoom > 1 ? 1 : 2
                        }
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                Text(L10n.ImagePreview.cannotPreview)
                    .font(.headline)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func zoomButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private func fitSize(_ imageSize: NSSize, in viewport: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let availableWidth = max(1, viewport.width - Metrics.imagePadding * 2)
        let availableHeight = max(1, viewport.height - Metrics.imagePadding * 2)
        let scale = min(availableWidth / imageSize.width, availableHeight / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}

/// Horizontal strip of staged composer images with remove buttons.
struct AgentComposerImageStrip: View {
    let images: [AgentImageAttachment]
    let onRemove: (AgentImageAttachment.ID) -> Void

    var body: some View {
        if images.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(images) { image in
                        AgentImageThumbnail(image: image, size: 64, allowsRemoval: true) {
                            onRemove(image.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// Helpers to lift NSPasteboard / drag-and-drop image data into the format
/// our `AgentImageAttachment` expects. Used by the composer.
enum AgentImagePasteboardHelper {
    /// Read images out of the general pasteboard. Returns a list of
    /// (data, mime-type) pairs; empty if there's nothing image-shaped.
    ///
    /// We try the explicit types first (`.png`, `.tiff`, file URL) so
    /// that lossless source data passes through untouched. When none of
    /// those match — which happens a lot in practice because many apps
    /// (Notes, Sketch, Figma, web browsers, Cmd+Shift+Ctrl+4 screen
    /// captures) put the image on the pasteboard under types we don't
    /// enumerate (`public.image`, `com.apple.icns`, raw `NSImage`
    /// archive, etc.) — we fall back to `NSImage(pasteboard:)`. That's
    /// AppKit's "I don't care what flavor, give me an NSImage" entry
    /// point and is what Apple's own docs recommend for paste handlers.
    /// The NSImage is then flattened to PNG.
    static func readImages(from pasteboard: NSPasteboard) -> [(data: Data, mimeType: String)] {
        var results: [(Data, String)] = []
        var fingerprints = Set<String>()
        for item in pasteboard.pasteboardItems ?? [] {
            if let pngData = item.data(forType: .png) {
                appendUnique(data: pngData, mimeType: "image/png", to: &results, fingerprints: &fingerprints)
                continue
            }
            if let tiffData = item.data(forType: .tiff),
               let rep = NSBitmapImageRep(data: tiffData),
               let png = rep.representation(using: .png, properties: [:]) {
                appendUnique(data: png, mimeType: "image/png", to: &results, fingerprints: &fingerprints)
                continue
            }
            if let fileURLString = item.string(forType: .fileURL),
               let url = URL(string: fileURLString),
               let data = try? Data(contentsOf: url),
               let mime = mimeType(forPath: url.path) {
                appendUnique(data: data, mimeType: mime, to: &results, fingerprints: &fingerprints)
                continue
            }
            if let imageData = imageData(from: item) {
                appendUnique(
                    data: imageData.0,
                    mimeType: imageData.1,
                    to: &results,
                    fingerprints: &fingerprints
                )
            }
        }
        if results.isEmpty,
           let image = NSImage(pasteboard: pasteboard),
           let png = pngData(from: image) {
            appendUnique(data: png, mimeType: "image/png", to: &results, fingerprints: &fingerprints)
        }
        return results
    }

    /// Whether the given pasteboard advertises *any* image content we
    /// can ingest. Used by `ComposerNSTextView.paste(_:)` to decide
    /// whether to forward the event into the image-attach pipeline.
    /// Broader than `pasteboardItems.contains { png || tiff }` — covers
    /// `public.image`, NSImage-archive, and the various screenshot
    /// flavors that don't expose `.png`/`.tiff` directly.
    static func pasteboardHasImage(_ pasteboard: NSPasteboard) -> Bool {
        if NSImage.canInit(with: pasteboard) { return true }
        guard let items = pasteboard.pasteboardItems else { return false }
        return items.contains { item in
            if item.data(forType: .png) != nil { return true }
            if item.data(forType: .tiff) != nil { return true }
            if item.types.contains(where: isImagePasteboardType) { return true }
            if let urlString = item.string(forType: .fileURL),
               let url = URL(string: urlString),
               mimeType(forPath: url.path) != nil {
                return true
            }
            return false
        }
    }

    private static func imageData(from item: NSPasteboardItem) -> (Data, String)? {
        for type in item.types where isImagePasteboardType(type) {
            guard let data = item.data(forType: type) else { continue }
            if type.rawValue.lowercased().contains("heic") {
                return (data, "image/heic")
            }
            if let image = NSImage(data: data), let png = pngData(from: image) {
                return (png, "image/png")
            }
        }
        return nil
    }

    private nonisolated static func isImagePasteboardType(_ type: NSPasteboard.PasteboardType) -> Bool {
        UTType(type.rawValue)?.conforms(to: .image) == true
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func appendUnique(
        data: Data,
        mimeType: String,
        to results: inout [(Data, String)],
        fingerprints: inout Set<String>
    ) {
        let fingerprint = imageFingerprint(data)
        guard fingerprints.insert(fingerprint).inserted else { return }
        results.append((data, mimeType))
    }

    private static func imageFingerprint(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(data.count)-\(String(hash, radix: 16))"
    }

    static func mimeType(forPath path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        default: return nil
        }
    }
}
