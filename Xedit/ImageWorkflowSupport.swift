//
//  ImageWorkflowSupport.swift
//  WillDeep
//
//  Shared deterministic image helpers for built-in image workflows.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum ImageWorkflowSupport {
    private static let maxCompressedImageBytes = 64 * 1_024 * 1_024
    private static let maxDecodedPixels = 40_000_000
    private static let maxImageDimension = 16_384

    enum Failure: Error, LocalizedError {
        case missingImage(path: String)
        case unreadableImage(path: String)
        case invalidArguments(String)
        case unsupportedFormat(String)
        case writeFailed(path: String)

        var errorDescription: String? {
            switch self {
            case .missingImage(let path):
                return "Image file not found: `\(path)`."
            case .unreadableImage(let path):
                return "Could not decode image: `\(path)`."
            case .invalidArguments(let message):
                return message
            case .unsupportedFormat(let format):
                return "Unsupported image format: `\(format)`. Use png, jpeg, webp, tiff, or heic."
            case .writeFailed(let path):
                return "Could not write image output: `\(path)`."
            }
        }
    }

    struct ParsedArgs {
        let positional: [String]
        let options: [String: String]
    }

    struct ImageInfo {
        let url: URL
        let image: CGImage

        var width: Int { image.width }
        var height: Int { image.height }
    }

    struct RGBAColor: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8

        static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
        static let white = RGBAColor(red: 255, green: 255, blue: 255, alpha: 255)
        static let black = RGBAColor(red: 0, green: 0, blue: 0, alpha: 255)

        var nsColor: NSColor {
            NSColor(
                calibratedRed: CGFloat(red) / 255.0,
                green: CGFloat(green) / 255.0,
                blue: CGFloat(blue) / 255.0,
                alpha: CGFloat(alpha) / 255.0
            )
        }
    }

    struct OCRLine {
        let text: String
        let confidence: Float
        let rect: CGRect
    }

    static func parse(_ raw: String) -> ParsedArgs {
        var positional: [String] = []
        var options: [String: String] = [:]
        for token in tokenize(raw) {
            if let idx = token.firstIndex(of: "="), idx != token.startIndex {
                let key = String(token[..<idx]).lowercased()
                let value = String(token[token.index(after: idx)...])
                options[key] = value
            } else {
                positional.append(token)
            }
        }
        return ParsedArgs(positional: positional, options: options)
    }

    static func tokenize(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false

        for ch in raw {
            if isEscaping {
                current.append(ch)
                isEscaping = false
                continue
            }
            if ch == "\\" {
                isEscaping = true
                continue
            }
            if let active = quote {
                if ch == active {
                    quote = nil
                } else {
                    current.append(ch)
                }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                continue
            }
            if ch.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    static func loadImage(path: String) throws -> ImageInfo {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.missingImage(path: path)
        }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize <= maxCompressedImageBytes else {
            throw Failure.invalidArguments("Image exceeds the 64 MiB compressed-file safety limit: `\(path)`.")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw Failure.unreadableImage(path: path)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else {
            throw Failure.unreadableImage(path: path)
        }
        guard width <= maxImageDimension,
              height <= maxImageDimension,
              width <= maxDecodedPixels / height else {
            throw Failure.invalidArguments("Image dimensions \(width)×\(height) exceed the decoded-pixel safety budget: `\(path)`.")
        }
        guard
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCache: true
              ] as CFDictionary) else {
            throw Failure.unreadableImage(path: path)
        }
        return ImageInfo(url: url, image: image)
    }

    static func outputURL(for input: URL, suffix: String, ext: String? = nil) -> URL {
        let cleanExt = normalizedExtension(ext ?? input.pathExtension)
        let stem = input.deletingPathExtension().lastPathComponent
        let stamp = Int(Date().timeIntervalSince1970)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("\(stem)-\(suffix)-\(stamp).\(cleanExt)")
    }

    static func outputDirectory(prefix: String) -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let url = downloads.appendingPathComponent("\(prefix)-\(stamp)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func save(_ image: CGImage, to url: URL, format rawFormat: String? = nil, quality: CGFloat = 0.92) throws {
        let ext = normalizedExtension(rawFormat ?? url.pathExtension)
        let type: UTType
        switch ext {
        case "png":
            type = .png
        case "jpg", "jpeg":
            type = .jpeg
        case "webp":
            type = .webP
        case "tif", "tiff":
            type = .tiff
        case "heic":
            type = .heic
        default:
            throw Failure.unsupportedFormat(ext)
        }

        let imageToWrite: CGImage
        if type == .jpeg || type == .heic {
            imageToWrite = flatten(image, background: .white)
        } else {
            imageToWrite = image
        }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure.writeFailed(path: url.path)
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: max(0.01, min(1.0, quality))
        ]
        CGImageDestinationAddImage(destination, imageToWrite, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure.writeFailed(path: url.path)
        }
    }

    static func normalizedExtension(_ raw: String) -> String {
        let clean = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if clean == "jpeg" { return "jpg" }
        if clean.isEmpty { return "png" }
        return clean
    }

    static func parseSize(_ raw: String) throws -> CGSize {
        let parts = raw.lowercased().replacingOccurrences(of: "×", with: "x").split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else {
            throw Failure.invalidArguments("Size must be `WIDTHxHEIGHT`, for example `1200x800`.")
        }
        return CGSize(width: w, height: h)
    }

    static func parseRect(_ raw: String) throws -> CGRect {
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              let w = Double(parts[2]),
              let h = Double(parts[3]),
              w > 0, h > 0 else {
            throw Failure.invalidArguments("Crop must be `x,y,width,height` in source pixels.")
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func parsePadding(_ raw: String) throws -> NSEdgeInsets {
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 1, let all = CGFloatNumber(parts[0]), all >= 0 {
            return NSEdgeInsets(top: all, left: all, bottom: all, right: all)
        }
        guard parts.count == 4,
              let left = CGFloatNumber(parts[0]),
              let top = CGFloatNumber(parts[1]),
              let right = CGFloatNumber(parts[2]),
              let bottom = CGFloatNumber(parts[3]),
              min(left, top, right, bottom) >= 0 else {
            throw Failure.invalidArguments("Padding must be `N` or `left,top,right,bottom`.")
        }
        return NSEdgeInsets(top: top, left: left, bottom: bottom, right: right)
    }

    static func parseColor(_ raw: String, defaultAlpha: UInt8 = 255) throws -> RGBAColor {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased() == "transparent" {
            return .clear
        }
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6 || value.count == 8 else {
            throw Failure.invalidArguments("Color must be `#RRGGBB`, `#RRGGBBAA`, or `transparent`.")
        }
        func byte(_ start: String.Index) throws -> UInt8 {
            let end = value.index(start, offsetBy: 2)
            guard let n = UInt8(value[start..<end], radix: 16) else {
                throw Failure.invalidArguments("Invalid color value: `#\(value)`.")
            }
            return n
        }
        let r = try byte(value.startIndex)
        let g = try byte(value.index(value.startIndex, offsetBy: 2))
        let b = try byte(value.index(value.startIndex, offsetBy: 4))
        let a = value.count == 8 ? try byte(value.index(value.startIndex, offsetBy: 6)) : defaultAlpha
        return RGBAColor(red: r, green: g, blue: b, alpha: a)
    }

    static func resize(_ image: CGImage, to size: CGSize) -> CGImage {
        render(width: Int(size.width.rounded()), height: Int(size.height.rounded()), background: .clear) { context in
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: size))
        }
    }

    static func fit(_ image: CGImage, within bounds: CGSize) -> CGImage {
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(
            width: max(1, CGFloat(image.width) * scale),
            height: max(1, CGFloat(image.height) * scale)
        )
        return resize(image, to: size)
    }

    static func crop(_ image: CGImage, rect: CGRect) -> CGImage {
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard !clamped.isNull, let cropped = image.cropping(to: clamped) else { return image }
        return cropped
    }

    static func centerCrop(_ image: CGImage, aspectRatio: CGFloat) -> CGImage {
        let current = CGFloat(image.width) / CGFloat(image.height)
        let rect: CGRect
        if current > aspectRatio {
            let width = CGFloat(image.height) * aspectRatio
            rect = CGRect(x: (CGFloat(image.width) - width) / 2, y: 0, width: width, height: CGFloat(image.height))
        } else {
            let height = CGFloat(image.width) / aspectRatio
            rect = CGRect(x: 0, y: (CGFloat(image.height) - height) / 2, width: CGFloat(image.width), height: height)
        }
        return crop(image, rect: rect)
    }

    static func pad(_ image: CGImage, insets: NSEdgeInsets, color: RGBAColor) -> CGImage {
        let width = image.width + Int(insets.left + insets.right)
        let height = image.height + Int(insets.top + insets.bottom)
        return render(width: width, height: height, background: color) { context in
            context.draw(
                image,
                in: CGRect(x: insets.left, y: insets.bottom, width: CGFloat(image.width), height: CGFloat(image.height))
            )
        }
    }

    static func flatten(_ image: CGImage, background: RGBAColor) -> CGImage {
        render(width: image.width, height: image.height, background: background) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
    }

    static func removeSolidBackground(_ image: CGImage, target: RGBAColor, tolerance: Int) -> CGImage {
        var buffer = rgbaBytes(from: image)
        let limit = max(0, min(255, tolerance))
        for i in stride(from: 0, to: buffer.count, by: 4) {
            let dr = abs(Int(buffer[i]) - Int(target.red))
            let dg = abs(Int(buffer[i + 1]) - Int(target.green))
            let db = abs(Int(buffer[i + 2]) - Int(target.blue))
            if dr <= limit && dg <= limit && db <= limit {
                buffer[i + 3] = 0
            }
        }
        return makeImage(width: image.width, height: image.height, rgba: buffer)
    }

    static func trimTransparent(_ image: CGImage) -> CGImage {
        let buffer = rgbaBytes(from: image)
        var minX = image.width
        var minY = image.height
        var maxX = -1
        var maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let alpha = buffer[(y * image.width + x) * 4 + 3]
                if alpha > 0 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }
        return crop(
            image,
            rect: CGRect(
                x: CGFloat(minX),
                y: CGFloat(minY),
                width: CGFloat(maxX - minX + 1),
                height: CGFloat(maxY - minY + 1)
            )
        )
    }

    static func watermark(_ image: CGImage, text: String, position: String, opacity: CGFloat) -> CGImage {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height)))
        let canvas = NSImage(size: nsImage.size)
        canvas.lockFocus()
        nsImage.draw(in: NSRect(origin: .zero, size: nsImage.size))

        let fontSize = max(16, min(nsImage.size.width, nsImage.size.height) / 24)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(opacity),
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let textSize = attributed.size()
        let padding = fontSize * 0.55
        let origin = watermarkOrigin(
            canvas: nsImage.size,
            text: textSize,
            padding: padding,
            position: position
        )
        let box = NSRect(
            x: origin.x - padding,
            y: origin.y - padding * 0.65,
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 1.3
        )
        NSColor.black.withAlphaComponent(opacity * 0.55).setFill()
        NSBezierPath(roundedRect: box, xRadius: padding * 0.45, yRadius: padding * 0.45).fill()
        attributed.draw(at: origin)
        canvas.unlockFocus()

        guard let cg = canvas.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        return cg
    }

    static func redact(_ image: CGImage, rectangles: [CGRect], fill: RGBAColor = .black) -> CGImage {
        render(width: image.width, height: image.height, background: .clear) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
            context.setFillColor(fill.nsColor.cgColor)
            for rect in rectangles {
                context.fill(rect)
            }
        }
    }

    static func recognizeText(in image: CGImage) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(
                text: candidate.string,
                confidence: candidate.confidence,
                rect: denormalized(observation.boundingBox, width: image.width, height: image.height)
            )
        }
        .sorted {
            if abs($0.rect.minY - $1.rect.minY) > 8 {
                return $0.rect.minY > $1.rect.minY
            }
            return $0.rect.minX < $1.rect.minX
        }
    }

    static func detectFaces(in image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).map {
            denormalized($0.boundingBox, width: image.width, height: image.height).insetBy(dx: -8, dy: -8)
        }
    }

    static func contactSheet(images: [CGImage], columns: Int, tileSize: Int, background: RGBAColor = .white) -> CGImage {
        let cols = max(1, columns)
        let rows = max(1, (images.count + cols - 1) / cols)
        let gap = max(4, tileSize / 35)
        let width = cols * tileSize + (cols + 1) * gap
        let height = rows * tileSize + (rows + 1) * gap
        return render(width: width, height: height, background: background) { context in
            context.interpolationQuality = .high
            for (idx, image) in images.enumerated() {
                let col = idx % cols
                let row = idx / cols
                let x = gap + col * (tileSize + gap)
                let y = height - gap - (row + 1) * tileSize - row * gap
                let fitted = fitRect(
                    imageSize: CGSize(width: CGFloat(image.width), height: CGFloat(image.height)),
                    bounds: CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(tileSize), height: CGFloat(tileSize))
                )
                context.setFillColor(NSColor(calibratedWhite: 0.94, alpha: 1).cgColor)
                context.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(tileSize), height: CGFloat(tileSize)))
                context.draw(image, in: fitted)
            }
        }
    }

    static func palette(from image: CGImage, count: Int) -> [(color: RGBAColor, pixels: Int)] {
        let resized = fit(image, within: CGSize(width: 240, height: 240))
        let buffer = rgbaBytes(from: resized)
        var buckets: [Int: (r: Int, g: Int, b: Int, n: Int)] = [:]
        for i in stride(from: 0, to: buffer.count, by: 16) {
            let a = buffer[i + 3]
            guard a > 16 else { continue }
            let r = Int(buffer[i])
            let g = Int(buffer[i + 1])
            let b = Int(buffer[i + 2])
            let key = (r / 32) << 16 | (g / 32) << 8 | (b / 32)
            let old = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (old.r + r, old.g + g, old.b + b, old.n + 1)
        }
        return buckets.values
            .sorted { $0.n > $1.n }
            .prefix(max(1, count))
            .map { bucket in
                (
                    RGBAColor(
                        red: UInt8(bucket.r / max(1, bucket.n)),
                        green: UInt8(bucket.g / max(1, bucket.n)),
                        blue: UInt8(bucket.b / max(1, bucket.n)),
                        alpha: 255
                    ),
                    bucket.n
                )
            }
    }

    static func hex(_ color: RGBAColor) -> String {
        String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
    }

    static func compare(_ lhs: CGImage, _ rhs: CGImage) -> (diff: CGImage, changedPercent: Double, meanAbsoluteError: Double) {
        let left = lhs
        let right = (lhs.width == rhs.width && lhs.height == rhs.height)
            ? rhs
            : resize(rhs, to: CGSize(width: lhs.width, height: lhs.height))
        let a = rgbaBytes(from: left)
        let b = rgbaBytes(from: right)
        var diff = Array(repeating: UInt8(255), count: lhs.width * lhs.height * 4)
        var changed = 0
        var totalDelta = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            let dr = abs(Int(a[i]) - Int(b[i]))
            let dg = abs(Int(a[i + 1]) - Int(b[i + 1]))
            let db = abs(Int(a[i + 2]) - Int(b[i + 2]))
            let delta = max(dr, dg, db)
            totalDelta += dr + dg + db
            if delta > 4 {
                changed += 1
                diff[i] = 255
                diff[i + 1] = UInt8(max(0, 255 - delta))
                diff[i + 2] = UInt8(max(0, 255 - delta))
                diff[i + 3] = 255
            } else {
                let gray = UInt8((Int(a[i]) + Int(a[i + 1]) + Int(a[i + 2])) / 3)
                diff[i] = gray
                diff[i + 1] = gray
                diff[i + 2] = gray
                diff[i + 3] = 120
            }
        }
        let pixels = max(1, lhs.width * lhs.height)
        return (
            makeImage(width: lhs.width, height: lhs.height, rgba: diff),
            Double(changed) / Double(pixels) * 100.0,
            Double(totalDelta) / Double(pixels * 3)
        )
    }

    static func render(width: Int, height: Int, background: RGBAColor, draw: (CGContext) -> Void) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: max(1, width),
            height: max(1, height),
            bitsPerComponent: 8,
            bytesPerRow: max(1, width) * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(background.nsColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        draw(context)
        return context.makeImage()!
    }

    static func rgbaBytes(from image: CGImage) -> [UInt8] {
        var buffer = Array(repeating: UInt8(0), count: image.width * image.height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        buffer.withUnsafeMutableBytes { ptr in
            let context = CGContext(
                data: ptr.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return buffer
    }

    static func makeImage(width: Int, height: Int, rgba: [UInt8]) -> CGImage {
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
    }

    private static func CGFloatNumber(_ raw: String) -> CGFloat? {
        guard let value = Double(raw) else { return nil }
        return CGFloat(value)
    }

    private static func denormalized(_ rect: CGRect, width: Int, height: Int) -> CGRect {
        CGRect(
            x: rect.minX * CGFloat(width),
            y: rect.minY * CGFloat(height),
            width: rect.width * CGFloat(width),
            height: rect.height * CGFloat(height)
        )
    }

    private static func watermarkOrigin(canvas: NSSize, text: NSSize, padding: CGFloat, position: String) -> NSPoint {
        switch position.lowercased() {
        case "tl":
            return NSPoint(x: padding * 1.8, y: canvas.height - text.height - padding * 1.8)
        case "tr":
            return NSPoint(x: canvas.width - text.width - padding * 1.8, y: canvas.height - text.height - padding * 1.8)
        case "bl":
            return NSPoint(x: padding * 1.8, y: padding * 1.8)
        case "center":
            return NSPoint(x: (canvas.width - text.width) / 2, y: (canvas.height - text.height) / 2)
        default:
            return NSPoint(x: canvas.width - text.width - padding * 1.8, y: padding * 1.8)
        }
    }

    private static func fitRect(imageSize: CGSize, bounds: CGRect) -> CGRect {
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }
}
