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

struct AgentImageThumbnail: View {
    let image: AgentImageAttachment
    let size: CGFloat
    let allowsRemoval: Bool
    let onRemove: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let nsImage = Self.decode(image) {
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

    private static func decode(_ image: AgentImageAttachment) -> NSImage? {
        guard let data = Data(base64Encoded: image.dataBase64) else { return nil }
        return NSImage(data: data)
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
        guard let items = pasteboard.pasteboardItems else { return results }
        for item in items {
            if let pngData = item.data(forType: .png) {
                results.append((pngData, "image/png"))
                continue
            }
            if let tiffData = item.data(forType: .tiff),
               let rep = NSBitmapImageRep(data: tiffData),
               let png = rep.representation(using: .png, properties: [:]) {
                results.append((png, "image/png"))
                continue
            }
            if let fileURLString = item.string(forType: .fileURL),
               let url = URL(string: fileURLString),
               let data = try? Data(contentsOf: url),
               let mime = mimeType(forPath: url.path) {
                results.append((data, mime))
            }
        }
        if results.isEmpty,
           let image = NSImage(pasteboard: pasteboard),
           let png = pngData(from: image) {
            results.append((png, "image/png"))
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
            if let urlString = item.string(forType: .fileURL),
               let url = URL(string: urlString),
               mimeType(forPath: url.path) != nil {
                return true
            }
            return false
        }
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
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
