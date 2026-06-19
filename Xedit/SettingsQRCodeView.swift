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

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        if let image = makeImage() {
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

    private func makeImage() -> NSImage? {
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
