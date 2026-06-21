//
//  SettingsQRCodeView.swift
//  WillDeep
//
//  Shared QR renderer for settings flows such as mobile pairing and
//  collaboration connector authorization.
//

import CoreImage.CIFilterBuiltins
import SwiftUI

struct SettingsQRCodeView: View {
    let text: String
    let accessibilityLabel: String
    let unavailableText: String
    var pointSize: CGFloat = 168

    @State private var renderedKey = ""
    @State private var renderedImage: NSImage?

    private static let context = CIContext()

    var body: some View {
        Group {
            if let image = renderedImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: pointSize, height: pointSize)
                    .accessibilityLabel(Text(accessibilityLabel))
            } else {
                Text(unavailableText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: cacheKey) {
            renderIfNeeded()
        }
    }

    private var cacheKey: String {
        "\(pointSize)|\(text)"
    }

    private func renderIfNeeded() {
        guard renderedKey != cacheKey else { return }
        renderedKey = cacheKey
        renderedImage = Self.makeImage(text: text, pointSize: pointSize)
    }

    private static func makeImage(text: String, pointSize: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        let transform = CGAffineTransform(scaleX: 8, y: 8)
        guard let output = filter.outputImage?.transformed(by: transform),
              let cgImage = context.createCGImage(output, from: output.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: pointSize, height: pointSize))
    }
}
