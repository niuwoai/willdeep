//
//  AgentToolResultImageViews.swift
//  WillDeep
//
//  Thumbnails for images a tool produced. Split out of
//  AgentToolCallViews.swift, which had grown past the repository's hard
//  file-size limit.
//

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Horizontal strip of thumbnails for images a tool produced (today only
/// `capture_screenshot`). Decodes a downsampled thumbnail via ImageIO rather
/// than a full-resolution `NSImage(data:)` so a burst of large captures can't
/// balloon memory — the codebase has been bitten by unbounded image/layout
/// memory before.
///
/// Internal rather than private because `AgentToolCallCard` renders it; it was
/// file-private only because it used to live in the same file.
struct AgentToolResultImageStrip: View {
    let images: [AgentImageAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(images) { image in
                    AgentToolResultThumbnail(image: image)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct AgentToolResultThumbnail: View {
    let image: AgentImageAttachment
    @State private var thumbnail: NSImage?
    private let maxHeight: CGFloat = 120
    private let thumbnailMaxPixel = 300

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .onTapGesture { openFullSize() }
                    .help("点击在预览中打开完整截图")
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 120, height: 80)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: image.id) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard thumbnail == nil else { return }
        let base64 = image.dataBase64
        let maxPixel = thumbnailMaxPixel
        // Downsample off the main actor and hand back a small NSSize +
        // PNG `Data` (both Sendable — NSImage is not, and returning it
        // would warn on pre-macOS 14 deployment targets). Build the
        // NSImage on the main actor from the downsampled bytes.
        let rendered = await Task.detached(priority: .userInitiated) { () -> (Data, Int, Int)? in
            guard let data = Data(base64Encoded: base64),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                out as CFMutableData,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else { return nil }
            CGImageDestinationAddImage(dest, cg, nil)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return (out as Data, cg.width, cg.height)
        }.value
        if let rendered, let nsImage = NSImage(data: rendered.0) {
            nsImage.size = NSSize(width: rendered.1, height: rendered.2)
            thumbnail = nsImage
        }
    }

    private func openFullSize() {
        guard let data = Data(base64Encoded: image.dataBase64) else { return }
        let ext = image.mimeType.lowercased().hasSuffix("png") ? "png" : "jpg"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-capture-\(image.id.uuidString).\(ext)")
        do {
            try data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            // Non-fatal: the thumbnail is still visible inline.
        }
    }
}
