//
//  ImageWorkflows.swift
//  WillDeep
//
//  Built-in deterministic image workflow set.
//

import AppKit
import Foundation

private typealias IWS = ImageWorkflowSupport

struct ImageConvertWorkflow: WorkflowDefinition {
    var name: String { "image-convert" }
    var displayTitle: String { "Image Convert" }
    var slashCommand: String { "/image-convert" }
    var shortDescription: String { "Convert an image to png, jpeg, webp, tiff, or heic" }
    var argsPlaceholder: String { "<path> [format=png|jpeg|webp|tiff|heic] [quality=92]" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let parsed = IWS.parse(args)
        guard let path = parsed.positional.first else {
            return "Usage: `/image-convert <path> [format=png|jpeg|webp|tiff|heic] [quality=92]`."
        }
        let info = try IWS.loadImage(path: path)
        let format = parsed.options["format"].map(IWS.normalizedExtension) ?? "png"
        let quality = qualityValue(parsed.options["quality"], fallback: 92)
        let output = IWS.outputURL(for: info.url, suffix: "converted", ext: format)
        try IWS.save(info.image, to: output, format: format, quality: quality)
        return imageResult("Image converted", source: info.url.path, output: output.path, details: [
            "Input": "\(info.width)x\(info.height)",
            "Format": format,
            "Quality": "\(Int(quality * 100))"
        ])
    }
}

struct ImageResizeWorkflow: WorkflowDefinition {
    var name: String { "image-resize" }
    var displayTitle: String { "Image Resize" }
    var slashCommand: String { "/image-resize" }
    var shortDescription: String { "Resize an image exactly or fit within bounds without stretching" }
    var argsPlaceholder: String { "<path> [size=1200x800|max=1200x1200|width=1200|height=800] [format=png]" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let parsed = IWS.parse(args)
        guard let path = parsed.positional.first else {
            return "Usage: `/image-resize <path> [size=1200x800|max=1200x1200|width=1200|height=800] [format=png]`."
        }
        let info = try IWS.loadImage(path: path)
        let resized: CGImage
        if let raw = parsed.options["size"] {
            resized = try IWS.resize(info.image, to: IWS.parseSize(raw))
        } else if let raw = parsed.options["max"] {
            resized = try IWS.fit(info.image, within: IWS.parseSize(raw))
        } else if let widthRaw = parsed.options["width"], let width = Double(widthRaw), width > 0 {
            let height = width / Double(info.width) * Double(info.height)
            resized = IWS.resize(info.image, to: CGSize(width: width, height: height))
        } else if let heightRaw = parsed.options["height"], let height = Double(heightRaw), height > 0 {
            let width = height / Double(info.height) * Double(info.width)
            resized = IWS.resize(info.image, to: CGSize(width: width, height: height))
        } else {
            return "Pass one of `size=WIDTHxHEIGHT`, `max=WIDTHxHEIGHT`, `width=N`, or `height=N`."
        }
        let format = parsed.options["format"].map(IWS.normalizedExtension) ?? IWS.normalizedExtension(info.url.pathExtension)
        let output = IWS.outputURL(for: info.url, suffix: "resized", ext: format)
        try IWS.save(resized, to: output, format: format)
        return imageResult("Image resized", source: info.url.path, output: output.path, details: [
            "Before": "\(info.width)x\(info.height)",
            "After": "\(resized.width)x\(resized.height)"
        ])
    }
}

struct ImageCropWorkflow: WorkflowDefinition {
    var name: String { "image-crop" }
    var displayTitle: String { "Image Crop" }
    var slashCommand: String { "/image-crop" }
    var shortDescription: String { "Crop by pixel rectangle or center-crop to common aspect ratios" }
    var argsPlaceholder: String { "<path> [crop=x,y,w,h|preset=square|16:9|9:16|4:3]" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let parsed = IWS.parse(args)
        guard let path = parsed.positional.first else {
            return "Usage: `/image-crop <path> [crop=x,y,w,h|preset=square|16:9|9:16|4:3]`."
        }
        let info = try IWS.loadImage(path: path)
        let cropped: CGImage
        let mode: String
        if let raw = parsed.options["crop"] ?? parsed.positional.dropFirst().first {
            cropped = try IWS.crop(info.image, rect: IWS.parseRect(raw))
            mode = raw
        } else {
            let preset = (parsed.options["preset"] ?? "square").lowercased()
            let ratio: CGFloat
            switch preset {
            case "square", "1:1":
                ratio = 1
            case "16:9":
                ratio = 16.0 / 9.0
            case "9:16":
                ratio = 9.0 / 16.0
            case "4:3":
                ratio = 4.0 / 3.0
            default:
                return "Unsupported preset `\(preset)`. Use square, 16:9, 9:16, or 4:3."
            }
            cropped = IWS.centerCrop(info.image, aspectRatio: ratio)
            mode = preset
        }
        let output = IWS.outputURL(for: info.url, suffix: "cropped")
        try IWS.save(cropped, to: output)
        return imageResult("Image cropped", source: info.url.path, output: output.path, details: [
            "Mode": mode,
            "Before": "\(info.width)x\(info.height)",
            "After": "\(cropped.width)x\(cropped.height)"
        ])
    }
}

struct ImageCompressWorkflow: WorkflowDefinition {
    var name: String { "image-compress" }
    var displayTitle: String { "Image Compress" }
    var slashCommand: String { "/image-compress" }
    var shortDescription: String { "Compress an image as JPEG or WebP with optional target file size" }
    var argsPlaceholder: String { "<path> [target-kb=512] [format=jpeg|webp] [quality=82]" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let parsed = IWS.parse(args)
        guard let path = parsed.positional.first else {
            return "Usage: `/image-compress <path> [target-kb=512] [format=jpeg|webp] [quality=82]`."
        }
        let info = try IWS.loadImage(path: path)
        let format = parsed.options["format"].map(IWS.normalizedExtension) ?? "jpg"
        var quality = qualityValue(parsed.options["quality"], fallback: 82)
        let targetKB = parsed.options["target-kb"].flatMap(Double.init)
        let output = IWS.outputURL(for: info.url, suffix: "compressed", ext: format)
        repeat {
            try? FileManager.default.removeItem(at: output)
            try IWS.save(info.image, to: output, format: format, quality: quality)
            guard let targetKB else { break }
            let bytes = fileSize(output)
            if Double(bytes) <= targetKB * 1024 || quality <= 0.32 { break }
            quality -= 0.08
        } while true
        return imageResult("Image compressed", source: info.url.path, output: output.path, details: [
            "Format": format,
            "Quality": "\(Int(quality * 100))",
            "Size": humanBytes(fileSize(output))
        ])
    }
}

struct ImageBackgroundRemoveWorkflow: WorkflowDefinition {
    var name: String { "image-bg-remove" }
    var displayTitle: String { "Image Background Remove" }
    var slashCommand: String { "/image-bg-remove" }
    var shortDescription: String { "Remove a solid or near-solid background color into transparency" }
    var argsPlaceholder: String { "<path> [color=#ffffff] [tolerance=18]" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let parsed = IWS.parse(args)
        guard let path = parsed.positional.first else {
            return "Usage: `/image-bg-remove <path> [color=#ffffff] [tolerance=18]`."
        }
        let info = try IWS.loadImage(path: path)
        let color = try IWS.parseColor(parsed.options["color"] ?? "#ffffff")
        let tolerance = Int(parsed.options["tolerance"] ?? "18") ?? 18
        let outputImage = IWS.removeSolidBackground(info.image, target: color, tolerance: tolerance)
        let output = IWS.outputURL(for: info.url, suffix: "transparent", ext: "png")
        try IWS.save(outputImage, to: output, format: "png")
        return imageResult("Background removed", source: info.url.path, output: output.path, details: [
            "Color": IWS.hex(color),
            "Tolerance": "\(tolerance)",
            "Format": "png"
        ])
    }
}

struct ImageTrimPadWorkflow: WorkflowDefinition {
    var name: String { "image-trim-pad" }
    var displayTitle: String { "Image Trim / Pad" }
    var slashCommand: String { "/image-trim-pad" }
    var shortDescription: String { "Trim transparent edges and/or add canvas padding" }
    var argsPlaceholder: String { "<path> [trim=true] [pad=24|l,t,r,b] [color=transparent]" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let parsed = IWS.parse(args)
        guard let path = parsed.positional.first else {
            return "Usage: `/image-trim-pad <path> [trim=true] [pad=24|left,top,right,bottom] [color=transparent]`."
        }
        let info = try IWS.loadImage(path: path)
        var image = info.image
        if parsed.options["trim"]?.lowercased() != "false" {
            image = IWS.trimTransparent(image)
        }
        if let rawPad = parsed.options["pad"] {
            let color = try IWS.parseColor(parsed.options["color"] ?? "transparent", defaultAlpha: 0)
            image = try IWS.pad(image, insets: IWS.parsePadding(rawPad), color: color)
        }
        let output = IWS.outputURL(for: info.url, suffix: "trim-pad", ext: "png")
        try IWS.save(image, to: output, format: "png")
        return imageResult("Image trimmed/padded", source: info.url.path, output: output.path, details: [
            "Before": "\(info.width)x\(info.height)",
            "After": "\(image.width)x\(image.height)"
        ])
    }
}

struct ImageWatermarkWorkflow: WorkflowDefinition {
    var name: String { "image-watermark" }
    var displayTitle: String { "Image Watermark" }
    var slashCommand: String { "/image-watermark" }
    var shortDescription: String { "Add a text watermark to an image" }
    var argsPlaceholder: String { "<path> \"text\" [position=br|tr|bl|tl|center] [opacity=0.55]" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let parsed = IWS.parse(args)
        guard parsed.positional.count >= 2 else {
            return "Usage: `/image-watermark <path> \"text\" [position=br|tr|bl|tl|center] [opacity=0.55]`."
        }
        let info = try IWS.loadImage(path: parsed.positional[0])
        let text = parsed.positional[1]
        let position = parsed.options["position"] ?? "br"
        let opacity = CGFloat(Double(parsed.options["opacity"] ?? "0.55") ?? 0.55)
        let watermarked = IWS.watermark(info.image, text: text, position: position, opacity: max(0.05, min(1, opacity)))
        let output = IWS.outputURL(for: info.url, suffix: "watermarked")
        try IWS.save(watermarked, to: output)
        return imageResult("Watermark added", source: info.url.path, output: output.path, details: [
            "Text": text,
            "Position": position
        ])
    }
}

struct ImageOCRWorkflow: WorkflowDefinition {
    var name: String { "image-ocr" }
    var displayTitle: String { "Image OCR" }
    var slashCommand: String { "/image-ocr" }
    var shortDescription: String { "Extract visible text from a screenshot or image with macOS Vision" }
    var argsPlaceholder: String { "<path>" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let parsed = IWS.parse(args)
        guard let path = parsed.positional.first else {
            return "Usage: `/image-ocr <path>`."
        }
        let info = try IWS.loadImage(path: path)
        let lines = try IWS.recognizeText(in: info.image)
        let body = lines.isEmpty
            ? "_No text recognized._"
            : lines.map { "- \(escapeMarkdown($0.text)) (`\(String(format: "%.0f", $0.confidence * 100))%`)" }.joined(separator: "\n")
        return """
        # Image OCR

        - **Source**: `\(info.url.path)`
        - **Size**: \(info.width)x\(info.height)
        - **Lines**: \(lines.count)

        \(body)
        """
    }
}

struct ImageRedactWorkflow: WorkflowDefinition {
    var name: String { "image-redact" }
    var displayTitle: String { "Image Redact" }
    var slashCommand: String { "/image-redact" }
    var shortDescription: String { "Redact faces and sensitive OCR text such as emails, phones, and tokens" }
    var argsPlaceholder: String { "<path> [faces=true] [text=true] [patterns=email,phone,token]" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let parsed = IWS.parse(args)
        guard let path = parsed.positional.first else {
            return "Usage: `/image-redact <path> [faces=true] [text=true] [patterns=email,phone,token]`."
        }
        let info = try IWS.loadImage(path: path)
        var rects: [CGRect] = []
        var notes: [String] = []
        if parsed.options["faces"]?.lowercased() != "false" {
            let faces = try IWS.detectFaces(in: info.image)
            rects.append(contentsOf: faces)
            notes.append("\(faces.count) face(s)")
        }
        if parsed.options["text"]?.lowercased() != "false" {
            let patterns = Set((parsed.options["patterns"] ?? "email,phone,token").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            let lines = try IWS.recognizeText(in: info.image)
            let sensitive = lines.filter { line in
                isSensitive(line.text, patterns: patterns)
            }
            rects.append(contentsOf: sensitive.map { $0.rect.insetBy(dx: -4, dy: -4) })
            notes.append("\(sensitive.count) sensitive text line(s)")
        }
        let redacted = IWS.redact(info.image, rectangles: rects)
        let output = IWS.outputURL(for: info.url, suffix: "redacted", ext: "png")
        try IWS.save(redacted, to: output, format: "png")
        return imageResult("Image redacted", source: info.url.path, output: output.path, details: [
            "Redactions": "\(rects.count)",
            "Detected": notes.joined(separator: ", ")
        ])
    }
}

struct ImageContactSheetWorkflow: WorkflowDefinition {
    var name: String { "image-contact-sheet" }
    var displayTitle: String { "Image Contact Sheet" }
    var slashCommand: String { "/image-contact-sheet" }
    var shortDescription: String { "Combine multiple images into a single review contact sheet" }
    var argsPlaceholder: String { "<path1> <path2> ... [cols=4] [tile=260]" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let parsed = IWS.parse(args)
        guard parsed.positional.count >= 2 else {
            return "Usage: `/image-contact-sheet <path1> <path2> ... [cols=4] [tile=260]`."
        }
        let infos = try parsed.positional.map { try IWS.loadImage(path: $0) }
        let cols = Int(parsed.options["cols"] ?? "4") ?? 4
        let tile = Int(parsed.options["tile"] ?? "260") ?? 260
        let sheet = IWS.contactSheet(images: infos.map(\.image), columns: cols, tileSize: max(80, min(800, tile)))
        let output = IWS.outputDirectory(prefix: "WillDeep-Images").appendingPathComponent("contact-sheet.jpg")
        try IWS.save(sheet, to: output, format: "jpg", quality: 0.92)
        return imageResult("Contact sheet created", source: "\(infos.count) images", output: output.path, details: [
            "Grid": "\(cols) columns",
            "Sheet": "\(sheet.width)x\(sheet.height)"
        ])
    }
}

struct ImagePaletteWorkflow: WorkflowDefinition {
    var name: String { "image-palette" }
    var displayTitle: String { "Image Palette" }
    var slashCommand: String { "/image-palette" }
    var shortDescription: String { "Extract dominant colors from an image" }
    var argsPlaceholder: String { "<path> [count=8]" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let parsed = IWS.parse(args)
        guard let path = parsed.positional.first else {
            return "Usage: `/image-palette <path> [count=8]`."
        }
        let info = try IWS.loadImage(path: path)
        let count = Int(parsed.options["count"] ?? "8") ?? 8
        let colors = IWS.palette(from: info.image, count: max(1, min(16, count)))
        let rows = colors.enumerated().map { idx, item in
            "| \(idx + 1) | `\(IWS.hex(item.color))` | \(item.pixels) |"
        }.joined(separator: "\n")
        return """
        # Image Palette

        - **Source**: `\(info.url.path)`
        - **Size**: \(info.width)x\(info.height)

        | # | Color | Samples |
        |---|---|---:|
        \(rows)
        """
    }
}

struct ImageCompareWorkflow: WorkflowDefinition {
    var name: String { "image-compare" }
    var displayTitle: String { "Image Compare" }
    var slashCommand: String { "/image-compare" }
    var shortDescription: String { "Create a visual diff and metrics for two images" }
    var argsPlaceholder: String { "<left> <right>" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let parsed = IWS.parse(args)
        guard parsed.positional.count >= 2 else {
            return "Usage: `/image-compare <left> <right>`."
        }
        let left = try IWS.loadImage(path: parsed.positional[0])
        let right = try IWS.loadImage(path: parsed.positional[1])
        let result = IWS.compare(left.image, right.image)
        let output = IWS.outputURL(for: left.url, suffix: "diff", ext: "png")
        try IWS.save(result.diff, to: output, format: "png")
        return imageResult("Image diff created", source: "\(left.url.path) vs \(right.url.path)", output: output.path, details: [
            "Left": "\(left.width)x\(left.height)",
            "Right": "\(right.width)x\(right.height)",
            "Changed": String(format: "%.2f%%", result.changedPercent),
            "MAE": String(format: "%.2f", result.meanAbsoluteError)
        ])
    }
}

struct ImageAltTextWorkflow: WorkflowDefinition {
    var name: String { "image-alt-text" }
    var displayTitle: String { "Image Alt Text" }
    var slashCommand: String { "/image-alt-text" }
    var shortDescription: String { "Draft accessibility alt text from image metadata, OCR, and color signals" }
    var argsPlaceholder: String { "<path> [context=\"where this image appears\"]" }
    var maxAgents: Int { 2 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let parsed = IWS.parse(args)
        guard let path = parsed.positional.first else {
            return "Usage: `/image-alt-text <path> [context=\"where this image appears\"]`."
        }
        let info = try IWS.loadImage(path: path)
        let lines = (try? IWS.recognizeText(in: info.image)) ?? []
        let colors = IWS.palette(from: info.image, count: 5).map { IWS.hex($0.color) }.joined(separator: ", ")
        let context = parsed.options["context"] ?? parsed.positional.dropFirst().joined(separator: " ")
        let vlDescription = await describeImageWithVL(engine: engine, url: info.url)
        let prompt = """
        Draft accessible alt text for an image. Use the VL description when available; otherwise use only the structured local signals and do not invent visual objects that are not supported.

        Path: \(info.url.path)
        Size: \(info.width)x\(info.height)
        Context: \(context.isEmpty ? "(none)" : context)
        VL description:
        \(vlDescription ?? "(not available)")

        Dominant colors: \(colors)
        OCR text:
        \(lines.map { "- \($0.text)" }.joined(separator: "\n"))

        Return:
        ## Short alt text
        One sentence, under 140 characters.

        ## Detailed description
        2-4 sentences for accessibility or QA.

        ## Confidence
        High/medium/low and why.
        """
        return try await engine.agent(prompt, label: "alt-text")
    }
}

struct ScreenshotToCodeWorkflow: WorkflowDefinition {
    var name: String { "screenshot-to-code" }
    var displayTitle: String { "Screenshot to Code" }
    var slashCommand: String { "/screenshot-to-code" }
    var shortDescription: String { "Turn a UI screenshot into a React/Tailwind implementation brief or component" }
    var argsPlaceholder: String { "<path> [framework=react] [context=\"where this screen lives\"]" }
    var maxAgents: Int { 2 }
    var allowsEmptyArgs: Bool { false }
    var managedDomain: SomeIMManagedDomain { .coding }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let parsed = IWS.parse(args)
        guard let path = parsed.positional.first else {
            return "Usage: `/screenshot-to-code <path> [framework=react] [context=\"where this screen lives\"]`."
        }
        let info = try IWS.loadImage(path: path)
        let framework = parsed.options["framework"] ?? "react"
        let context = parsed.options["context"] ?? parsed.positional.dropFirst().joined(separator: " ")
        let vlDescription = await describeImageWithVL(engine: engine, url: info.url)
        let lines = (try? IWS.recognizeText(in: info.image)) ?? []
        let colors = IWS.palette(from: info.image, count: 8).map { IWS.hex($0.color) }.joined(separator: ", ")
        let prompt = """
        Convert a UI screenshot into an implementation plan and starter code.

        Target framework: \(framework)
        Screenshot path: \(info.url.path)
        Screenshot size: \(info.width)x\(info.height)
        Product context: \(context.isEmpty ? "(none)" : context)

        VL description:
        \(vlDescription ?? "(not available; rely on OCR/palette and be explicit about uncertainty)")

        OCR text:
        \(lines.map { "- \($0.text)" }.joined(separator: "\n"))

        Dominant colors: \(colors)

        Requirements:
        - Prefer React + TypeScript + Tailwind CSS unless the requested framework says otherwise.
        - Do not hardcode user-facing copy inside JSX when describing repo integration; put strings behind an i18n dictionary.
        - Use semantic layout, accessible controls, stable responsive dimensions, and no decorative gradient blobs.
        - If the screenshot description is incomplete, state assumptions before code.

        Return:
        ## Reading
        Concise description of the UI hierarchy and important visual details.

        ## Implementation Plan
        Component breakdown and state/interaction notes.

        ## Starter Code
        A focused component scaffold with i18n placeholders and Tailwind classes.

        ## Gaps
        Anything that requires visual confirmation or product-specific data.
        """
        return try await engine.agent(prompt, label: "screenshot-code")
    }
}

private func imageResult(_ title: String, source: String, output: String, details: [String: String]) -> String {
    let rows = details.map { "- **\($0.key)**: \($0.value)" }.joined(separator: "\n")
    return """
    # \(title)

    - **Source**: `\(source)`
    - **Output**: `\(output)`
    \(rows)

    Open:

    ```
    open "\(output)"
    ```
    """
}

private func qualityValue(_ raw: String?, fallback: Int) -> CGFloat {
    let value = Double(raw ?? "\(fallback)") ?? Double(fallback)
    return CGFloat(max(1.0, min(100.0, value)) / 100.0)
}

private func fileSize(_ url: URL) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
}

private func humanBytes(_ bytes: Int64) -> String {
    if bytes >= 1024 * 1024 {
        return String(format: "%.1f MB", Double(bytes) / 1024.0 / 1024.0)
    }
    return String(format: "%.0f KB", Double(bytes) / 1024.0)
}

private func escapeMarkdown(_ raw: String) -> String {
    raw.replacingOccurrences(of: "\n", with: " ")
}

private func isSensitive(_ text: String, patterns: Set<String>) -> Bool {
    let lower = text.lowercased()
    if patterns.contains("email"), lower.range(of: #"[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}"#, options: .regularExpression) != nil {
        return true
    }
    if patterns.contains("phone"), lower.range(of: #"(\+?\d[\d\s\-()]{7,}\d)"#, options: .regularExpression) != nil {
        return true
    }
    if patterns.contains("token"), lower.range(of: #"[a-z0-9_\-]{24,}"#, options: .regularExpression) != nil {
        return true
    }
    if patterns.contains("url"), lower.range(of: #"https?://\S+"#, options: .regularExpression) != nil {
        return true
    }
    return false
}

@MainActor
private func describeImageWithVL(engine: WorkflowEngine, url: URL) async -> String? {
    guard let appState = engine.appState,
          let data = try? Data(contentsOf: url),
          let mimeType = AgentImagePasteboardHelper.mimeType(forPath: url.path) else {
        return nil
    }
    let attachment = AgentImageAttachment(mimeType: mimeType, dataBase64: data.base64EncodedString())
    let configuration = appState.agentConfiguration.normalized.imageDescription.agentConfiguration
    return try? await appState.describeImagesForTextOnlyProvider([attachment], configuration: configuration)
}
