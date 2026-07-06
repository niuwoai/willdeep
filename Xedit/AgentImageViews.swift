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

struct AgentImageThumbnail: View {
    let image: AgentImageAttachment
    let size: CGFloat
    let allowsRemoval: Bool
    let onRemove: (() -> Void)?
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
            .task(id: "\(image.id)-\(image.dataBase64.count)-\(Int(size.rounded(.up)))") {
                decodedImage = await AgentThumbnailImageCache.image(
                    forBase64: image.dataBase64,
                    cacheKey: image.id.uuidString,
                    targetPixels: size * 2
                )
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
