//
//  AgentVisualQATools.swift
//  WillDeep
//
//  On-demand screenshot inspection for agentic UI development.
//

import Foundation

enum AgentVisualQATools {
    private static let maxImageBytes = 12 * 1024 * 1024
    private static let maxOCRLines = 24
    private static let maxVLCharacters = 16_000

    static func analyzeScreenshot(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let rawPath = arguments["path"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            throw AgentToolError.missingArgument("path")
        }

        let allowVL = arguments["allow_vl"]?.boolValue() ?? true
        let focus = arguments["focus"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let userContext = arguments["context"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = try resolveImageURL(rawPath, rootDirectory: context.rootDirectory)
        try validateImageFile(url)

        let info = try ImageWorkflowSupport.loadImage(path: url.path)
        let palette = ImageWorkflowSupport.palette(from: info.image, count: 8)
        let ocrLines = (try? ImageWorkflowSupport.recognizeText(in: info.image)) ?? []
        let theme = themeSummary(from: palette)

        let vlSection: String
        if allowVL {
            vlSection = await visualModelSection(
                url: url,
                focus: focus,
                userContext: userContext,
                imageSize: "\(info.width)x\(info.height)"
            )
        } else {
            vlSection = "VL analysis: skipped because `allow_vl=false`; only local palette/OCR signals were used."
        }

        let pathNote = pathDisplay(url: url, rootDirectory: context.rootDirectory)
        let payload = """
        # Visual QA Screenshot

        Source: `\(pathNote)`
        Size: \(info.width)x\(info.height)
        Focus: \(focus?.isEmpty == false ? focus! : "general UI QA")
        Context: \(userContext?.isEmpty == false ? userContext! : "not provided")

        ## Local Signals

        Theme estimate: \(theme.label)
        \(theme.reason)

        Dominant palette:
        \(paletteMarkdown(palette))

        OCR preview:
        \(ocrMarkdown(ocrLines))

        ## Visual Model Review

        \(vlSection)

        ## Call Boundary

        This tool is for explicit or clearly implied visual QA only: screenshots, UI color/theme checks, layout regressions, accessibility contrast review, or post-render verification after an approved browser screenshot. With `allow_vl=true`, the image may be sent to the configured Image Understanding provider. Use `allow_vl=false` for local-only palette/OCR inspection.
        """

        return AgentToolResult(
            summary: "Visual QA inspected \(url.lastPathComponent) (\(info.width)x\(info.height), \(theme.label))",
            payload: payload
        )
    }

    private static func resolveImageURL(_ rawPath: String, rootDirectory: URL?) throws -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        guard let rootDirectory else {
            throw AgentToolError.invalidArgument("path must be absolute when no workspace root is available")
        }
        return rootDirectory.appendingPathComponent(expanded).standardizedFileURL
    }

    private static func validateImageFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw AgentToolError.invalidArgument("path must point to a regular image file")
        }
        let size = values.fileSize ?? 0
        guard size > 0 else {
            throw AgentToolError.invalidArgument("image file is empty")
        }
        guard size <= maxImageBytes else {
            throw AgentToolError.invalidArgument("image file is too large; maximum is \(maxImageBytes / 1024 / 1024) MB")
        }
        guard mimeType(for: url) != nil else {
            throw AgentToolError.invalidArgument("unsupported image type; use png, jpeg, webp, tiff, gif, or heic")
        }
    }

    private static func visualModelSection(
        url: URL,
        focus: String?,
        userContext: String?,
        imageSize: String
    ) async -> String {
        let imageConfiguration = AgentSettingsStore.load().imageDescription.agentConfiguration.normalized
        guard imageConfiguration.supportsImageInput else {
            return "VL analysis: unavailable because the configured Image Understanding provider does not support image input."
        }
        guard !imageConfiguration.apiKey.isEmpty else {
            return "VL analysis: unavailable because Image Understanding API key is not configured."
        }
        guard let mimeType = mimeType(for: url) else {
            return "VL analysis: unavailable because the image MIME type is unsupported."
        }

        do {
            let data = try Data(contentsOf: url)
            let attachment = AgentImageAttachment(
                mimeType: mimeType,
                dataBase64: data.base64EncodedString()
            )
            let prompt = visualQAPrompt(
                focus: focus,
                userContext: userContext,
                imageSize: imageSize
            )
            let message = AgentMessage(role: .user, content: prompt, images: [attachment])
            let collector = CompressionSummaryCollector()
            try await AgentClient(configuration: imageConfiguration).streamChat(messages: [message]) { event in
                if case .textDelta(let delta) = event {
                    await collector.append(delta)
                }
            }
            let result = await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else { return "VL analysis: provider returned an empty response." }
            return limit(result, to: maxVLCharacters)
        } catch {
            return "VL analysis: unavailable because the configured Image Understanding provider did not return a usable result."
        }
    }

    private static func visualQAPrompt(
        focus: String?,
        userContext: String?,
        imageSize: String
    ) -> String {
        """
        You are reviewing a UI screenshot for a coding agent.
        Image size: \(imageSize)
        User context: \(userContext?.isEmpty == false ? userContext! : "not provided")
        Focus: \(focus?.isEmpty == false ? focus! : "general visual QA")

        Return concise, actionable notes under these headings:
        - Visual summary
        - Color/theme consistency
        - Layout/readability/accessibility risks
        - Concrete fixes to inspect in code

        Prefer observable facts. Mention uncertainty when the screenshot is too small, cropped, or ambiguous. Do not invent hidden state.
        """
    }

    private static func themeSummary(
        from palette: [(color: ImageWorkflowSupport.RGBAColor, pixels: Int)]
    ) -> (label: String, reason: String) {
        let total = max(1, palette.reduce(0) { $0 + $1.pixels })
        var light = 0
        var dark = 0
        var mid = 0

        for item in palette {
            let lum = luminance(item.color)
            if lum >= 0.72 {
                light += item.pixels
            } else if lum <= 0.28 {
                dark += item.pixels
            } else {
                mid += item.pixels
            }
        }

        let lightPct = Double(light) / Double(total)
        let darkPct = Double(dark) / Double(total)
        let midPct = Double(mid) / Double(total)
        let label: String
        if lightPct >= 0.55 {
            label = "mostly light"
        } else if darkPct >= 0.55 {
            label = "mostly dark"
        } else {
            label = "mixed"
        }
        let reason = String(
            format: "Approx palette distribution: light %.0f%%, mid %.0f%%, dark %.0f%%.",
            lightPct * 100,
            midPct * 100,
            darkPct * 100
        )
        return (label, reason)
    }

    private static func paletteMarkdown(
        _ palette: [(color: ImageWorkflowSupport.RGBAColor, pixels: Int)]
    ) -> String {
        guard !palette.isEmpty else { return "- No palette colors detected." }
        var rows = ["| Rank | Color | Pixels | Luminance |", "|---:|---|---:|---:|"]
        for (idx, item) in palette.enumerated() {
            rows.append(String(
                format: "| %d | `%@` | %d | %.2f |",
                idx + 1,
                ImageWorkflowSupport.hex(item.color),
                item.pixels,
                luminance(item.color)
            ))
        }
        return rows.joined(separator: "\n")
    }

    private static func ocrMarkdown(_ lines: [ImageWorkflowSupport.OCRLine]) -> String {
        guard !lines.isEmpty else { return "- No readable text detected locally." }
        let preview = lines.prefix(maxOCRLines).map { line in
            String(format: "- %.0f%% `%@`", line.confidence * 100, line.text)
        }
        let suffix = lines.count > maxOCRLines ? "\n- ... \(lines.count - maxOCRLines) more line(s)" : ""
        return preview.joined(separator: "\n") + suffix
    }

    private static func luminance(_ color: ImageWorkflowSupport.RGBAColor) -> Double {
        let r = Double(color.red) / 255
        let g = Double(color.green) / 255
        let b = Double(color.blue) / 255
        return (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
    }

    private static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "webp":
            return "image/webp"
        case "tif", "tiff":
            return "image/tiff"
        case "gif":
            return "image/gif"
        case "heic", "heif":
            return "image/heic"
        default:
            return nil
        }
    }

    private static func pathDisplay(url: URL, rootDirectory: URL?) -> String {
        guard let rootDirectory else { return url.path }
        let rootPath = rootDirectory.standardizedFileURL.path
        let imagePath = url.standardizedFileURL.path
        guard imagePath.hasPrefix(rootPath + "/") else { return imagePath }
        return String(imagePath.dropFirst(rootPath.count + 1))
    }

    private static func limit(_ text: String, to maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let idx = text.index(text.startIndex, offsetBy: maxCharacters)
        return "\(text[..<idx])\n\n[truncated]"
    }
}
