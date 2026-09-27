//
//  AgentMCPToolResultContent.swift
//  WillDeep
//
//  把 MCP `tools/call` 结果里的二进制内容块从「给模型的文本」里剥出来。
//
//  在此之前宿主把整段结果 JSON 原样当工具输出交给模型。结果里若有
//  `{"type":"image","data":"<base64>"}`，模型拿到的是一长串 base64 文本：
//  看不到图，还白白占掉上下文——工具输出有截断，截下来的正好是一段 base64
//  垃圾。`audio` 块和 `resource.blob` 同理。
//
//  这里按块处理：
//  - `image`：解码、按截图同一套规则限边并重编码成 JPEG，挂成工具结果的图片
//    附件（支持视觉的 provider 直接看到像素），原图与预览落在截图同一处
//    （`~/.willdeep/captures/<id>/`）。
//  - `audio`、`resource.blob`：解码后落盘到同一体系的目录里，模型拿到路径，
//    可以在回复里引用。
//  - 其余字段（`text` 块、`structuredContent`、`isError`……）原样保留。
//
//  输出仍是结果 JSON，只把二进制字段的值换成一行说明，不改结构：模型和既有
//  测试看到的形状与原来一致，没有二进制块的结果一个字节都不变。
//
//  只管「给模型的 Agent 工具结果」这条路。插件页面 / MCP App 走
//  `AgentMCPBridge.callPluginTool`，要的是原始 MCP result，不经过这里。
//

import CoreGraphics
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

nonisolated enum AgentMCPToolResultContent {
    /// 输出的排版：`call_mcp_tool` 一直给模型缩进的 JSON，插件一等工具一直给
    /// 紧凑的 JSON。各走各的老路，这次只换掉二进制字段。
    nonisolated enum PayloadStyle: Sendable {
        case indented
        case compact
    }

    nonisolated struct Limits: Sendable, Equatable {
        /// 单个二进制块解码后的体积上限。
        var maximumBlockBytes: Int
        /// 一次结果最多挂几张图。
        var maximumImages: Int
        /// 一次结果最多落几个音频 / 资源文件。
        var maximumSavedFiles: Int

        static let standard = Limits(
            maximumBlockBytes: 20 * 1_024 * 1_024,
            maximumImages: 8,
            maximumSavedFiles: 16
        )
    }

    /// 落盘位置。首选与截图同一处；写不进去时退到 App 自己的附件目录。
    nonisolated struct Storage: Sendable {
        let capturesRoot: URL
        let fallbackDirectory: @Sendable (UUID) throws -> URL

        static var standard: Storage {
            Storage(
                capturesRoot: standardCapturesRoot,
                fallbackDirectory: { try AgentImageAttachment.attachmentDirectory(for: $0) }
            )
        }

        /// 测试进程不往用户的 `~/.willdeep/captures` 里写。
        private static var standardCapturesRoot: URL {
            let environment = ProcessInfo.processInfo.environment
            if NSClassFromString("XCTestCase") != nil || environment["XCTestConfigurationFilePath"] != nil {
                return FileManager.default.temporaryDirectory
                    .appendingPathComponent("WillDeepTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
                    .appendingPathComponent("captures", isDirectory: true)
            }
            return AgentCaptureTools.defaultCapturesRoot
        }
    }

    nonisolated struct SavedFile: Sendable, Equatable {
        nonisolated enum Kind: String, Sendable {
            case audio
            case resource
        }

        let kind: Kind
        let mimeType: String
        let byteCount: Int
        let url: URL
    }

    nonisolated struct Extraction: Sendable {
        /// 给模型的文本。
        let payload: String
        let images: [AgentImageAttachment]
        let savedFiles: [SavedFile]
    }

    private static let log = Logger(subsystem: "com.willdeep.agent", category: "mcp-tool-result")

    /// 模型那条路的出口：剥二进制块、挂图片，组装成工具结果。
    ///
    /// 解码、缩放、写盘都放到后台：一次结果可以带好几张大图，在主线程上做会
    /// 卡住界面。
    static func toolResult(
        summary: String,
        resultJSON: String,
        style: PayloadStyle,
        storage: Storage = .standard,
        limits: Limits = .standard
    ) async -> AgentToolResult {
        let extraction = await Task.detached(priority: .userInitiated) {
            extract(resultJSON: resultJSON, style: style, storage: storage, limits: limits)
        }.value
        return AgentToolResult(summary: summary, payload: extraction.payload, images: extraction.images)
    }

    /// 插件一等工具（紧凑格式）原来走页面那条路，结果超过
    /// `AgentMCPBridge.pageFacingResultLimit` 就报错、不交半份 JSON。现在为了
    /// 先剥二进制改取完整结果，这道上限挪到剥完之后再守：剥掉图片音频后仍然
    /// 这么大的纯文本，照旧报错，不整段灌进上下文。缩进格式（`call_mcp_tool`）
    /// 由 `prettyJSON` 截断，不受这里影响。
    static func enforcePayloadLimit(
        _ result: AgentToolResult,
        style: PayloadStyle,
        limit: Int = AgentMCPBridge.pageFacingResultLimit,
        discardImages: ([AgentImageAttachment]) -> Void = { images in
            images.forEach { $0.removeStoredFileIfNeeded() }
        }
    ) throws -> AgentToolResult {
        guard style == .compact else { return result }
        let byteCount = result.payload.utf8.count
        guard byteCount > limit else { return result }
        // 报错的结果不交给模型，已落盘的图也不该留下成孤儿。
        discardImages(result.images)
        throw AgentToolError.commandFailed(
            -1,
            "MCP result is \(byteCount) bytes after removing binary blocks, over the \(limit) byte limit"
        )
    }

    /// 输入是 `tools/call` 的 `result`（完整 JSON 文本，不能是截断过的）。
    static func extract(
        resultJSON: String,
        style: PayloadStyle,
        storage: Storage = .standard,
        limits: Limits = .standard
    ) -> Extraction {
        guard let data = resultJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return Extraction(payload: resultJSON, images: [], savedFiles: [])
        }
        guard var result = object as? [String: Any],
              let content = result[Key.content] as? [Any] else {
            return Extraction(payload: unchangedPayload(object, originalText: resultJSON, style: style), images: [], savedFiles: [])
        }

        var walker = Walker(storage: storage, limits: limits)
        result[Key.content] = content.map { walker.rewrite($0) }
        guard walker.replacedAny else {
            return Extraction(payload: unchangedPayload(object, originalText: resultJSON, style: style), images: [], savedFiles: [])
        }
        let payload: String
        switch style {
        case .indented:
            payload = AgentMCPBridge.prettyJSON(result)
        case .compact:
            payload = (try? AgentMCPBridge.compactJSON(result, limit: nil)) ?? AgentMCPBridge.prettyJSON(result)
        }
        return Extraction(payload: payload, images: walker.images, savedFiles: walker.savedFiles)
    }

    /// 没有二进制块时，输出与改动前完全一致。
    private static func unchangedPayload(_ object: Any, originalText: String, style: PayloadStyle) -> String {
        switch style {
        case .indented: return AgentMCPBridge.prettyJSON(object)
        case .compact: return originalText
        }
    }

    // MARK: - Walker

    private nonisolated enum Key {
        static let content = "content"
        static let type = "type"
        static let data = "data"
        static let mimeType = "mimeType"
        static let resource = "resource"
        static let blob = "blob"
        static let uri = "uri"
    }

    private nonisolated enum BlockType {
        static let image = "image"
        static let audio = "audio"
        static let resource = "resource"
    }

    private nonisolated enum Decoded {
        case data(Data)
        case failure(String)
    }

    private nonisolated struct PersistFailure: LocalizedError {
        let reasons: [String]
        var errorDescription: String? { reasons.joined(separator: "; ") }
    }

    private nonisolated struct Walker {
        let storage: Storage
        let limits: Limits
        private(set) var images: [AgentImageAttachment] = []
        private(set) var savedFiles: [SavedFile] = []
        private(set) var replacedAny = false
        private var imageOrdinal = 0
        private var audioOrdinal = 0
        private var resourceOrdinal = 0

        init(storage: Storage, limits: Limits) {
            self.storage = storage
            self.limits = limits
        }

        mutating func rewrite(_ block: Any) -> Any {
            guard var dictionary = block as? [String: Any],
                  let type = dictionary[Key.type] as? String else { return block }
            switch type {
            case BlockType.image:
                guard let encoded = dictionary[Key.data] as? String else { return block }
                dictionary[Key.data] = image(encoded, declaredMIME: dictionary[Key.mimeType] as? String)
            case BlockType.audio:
                guard let encoded = dictionary[Key.data] as? String else { return block }
                dictionary[Key.data] = audio(encoded, declaredMIME: dictionary[Key.mimeType] as? String)
            case BlockType.resource:
                guard var resource = dictionary[Key.resource] as? [String: Any],
                      let encoded = resource[Key.blob] as? String else { return block }
                resource[Key.blob] = resourceBlob(
                    encoded,
                    declaredMIME: resource[Key.mimeType] as? String,
                    uri: resource[Key.uri] as? String
                )
                dictionary[Key.resource] = resource
            default:
                return block
            }
            replacedAny = true
            return dictionary
        }

        // MARK: Blocks

        private mutating func image(_ encoded: String, declaredMIME: String?) -> String {
            imageOrdinal += 1
            let label = "image \(imageOrdinal)"
            let mime = AgentMCPToolResultContent.normalizedMIME(declaredMIME)
            // 协议要求带 mimeType；没带的按实际解出来的格式认，声明成别的类型的不收。
            guard mime.isEmpty || mime.hasPrefix("image/") else {
                return skipped(label, "unsupported image type \(mime)")
            }
            guard images.count < limits.maximumImages else {
                return skipped(label, "this result already carries \(limits.maximumImages) images, the per-result limit")
            }
            let data: Data
            switch decode(encoded) {
            case .failure(let reason): return skipped(label, reason)
            case .data(let decoded): data = decoded
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0 else {
                return skipped(label, "could not decode the image data")
            }
            guard width <= ImageWorkflowSupport.maxImageDimension,
                  height <= ImageWorkflowSupport.maxImageDimension,
                  width <= ImageWorkflowSupport.maxDecodedPixels / height else {
                return skipped(label, "image dimensions \(width)×\(height) exceed the decoding safety budget")
            }
            guard let preview = AgentMCPToolResultContent.modelPreview(from: source, width: width, height: height) else {
                return skipped(label, "could not re-encode the image for the model")
            }

            let id = UUID()
            let originalName = "\(AgentCaptureTools.originalFilenameStem).\(AgentMCPToolResultContent.imageFileExtension(source: source, mime: mime))"
            let directory: URL
            do {
                directory = try persist(
                    [(originalName, data), (AgentCaptureTools.previewFilename, preview.data)],
                    id: id,
                    what: label
                )
            } catch {
                return skipped(label, "could not save it (\(error.localizedDescription))")
            }
            let previewURL = directory.appendingPathComponent(AgentCaptureTools.previewFilename, isDirectory: false)
            images.append(AgentImageAttachment(
                id: id,
                mimeType: AgentCaptureTools.previewMIMEType,
                filePath: previewURL.standardizedFileURL.path,
                byteCount: preview.data.count,
                source: .capture,
                createdAt: Date()
            ))
            let downscaled = max(preview.width, preview.height) < max(width, height)
                ? " (downscaled to \(preview.width)×\(preview.height))"
                : ""
            let originalPath = directory.appendingPathComponent(originalName, isDirectory: false).path
            let shownMIME = mime.isEmpty ? AgentMCPToolResultContent.detectedMIME(source) : mime
            return "[\(label): \(shownMIME), \(width)×\(height), attached\(downscaled); original saved to \(originalPath)]"
        }

        private mutating func audio(_ encoded: String, declaredMIME: String?) -> String {
            audioOrdinal += 1
            let label = "audio \(audioOrdinal)"
            let mime = AgentMCPToolResultContent.normalizedMIME(declaredMIME)
            guard mime.hasPrefix("audio/"),
                  let fileExtension = AgentMCPToolResultContent.fileExtension(forMIME: mime) else {
                return skipped(label, "unsupported audio type \(mime.isEmpty ? "(none)" : mime)")
            }
            return saveFile(
                encoded,
                kind: .audio,
                label: label,
                mime: mime,
                filename: "\(SavedFile.Kind.audio.rawValue).\(fileExtension)"
            )
        }

        private mutating func resourceBlob(_ encoded: String, declaredMIME: String?, uri: String?) -> String {
            resourceOrdinal += 1
            let mime = AgentMCPToolResultContent.normalizedMIME(declaredMIME)
            return saveFile(
                encoded,
                kind: .resource,
                label: "resource \(resourceOrdinal)",
                mime: mime,
                filename: AgentMCPToolResultContent.resourceFilename(uri: uri, mime: mime)
            )
        }

        private mutating func saveFile(
            _ encoded: String,
            kind: SavedFile.Kind,
            label: String,
            mime: String,
            filename: String
        ) -> String {
            guard savedFiles.count < limits.maximumSavedFiles else {
                return skipped(label, "this result already saved \(limits.maximumSavedFiles) files, the per-result limit")
            }
            let data: Data
            switch decode(encoded) {
            case .failure(let reason): return skipped(label, reason)
            case .data(let decoded): data = decoded
            }
            let directory: URL
            do {
                directory = try persist([(filename, data)], id: UUID(), what: label)
            } catch {
                return skipped(label, "could not save it (\(error.localizedDescription))")
            }
            let url = directory.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
            let typeLabel = mime.isEmpty ? "unknown type" : mime
            savedFiles.append(SavedFile(kind: kind, mimeType: typeLabel, byteCount: data.count, url: url))
            let size = AgentMCPToolResultContent.formattedByteCount(data.count)
            return "[\(label): \(typeLabel), \(size), saved to \(url.path)]"
        }

        // MARK: Helpers

        private func skipped(_ label: String, _ reason: String) -> String {
            "[\(label) skipped: \(reason)]"
        }

        private func decode(_ encoded: String) -> Decoded {
            let limit = limits.maximumBlockBytes
            // 先按字符数估一下，明显超限的不解码：base64 每 4 个字符 3 字节，
            // 留一点余量给换行之类的空白。
            let estimated = encoded.utf8.count / 4 * 3
            guard estimated <= limit + limit / AgentMCPToolResultContent.base64WhitespaceAllowanceDivisor else {
                return .failure(sizeReason(AgentMCPToolResultContent.formattedByteCount(estimated), approximate: true))
            }
            guard let data = AgentMCPToolResultContent.decodeBase64(encoded) else {
                return .failure("data is not valid base64")
            }
            guard !data.isEmpty else { return .failure("data is empty") }
            guard data.count <= limit else {
                return .failure(sizeReason(AgentMCPToolResultContent.formattedByteCount(data.count), approximate: false))
            }
            return .data(data)
        }

        private func sizeReason(_ size: String, approximate: Bool) -> String {
            let limit = AgentMCPToolResultContent.formattedByteCount(limits.maximumBlockBytes)
            return "\(approximate ? "about " : "")\(size), over the \(limit) per-block limit"
        }

        /// 首选截图目录；建不了目录或写不进去就退到 App 自己的附件目录。
        private func persist(_ files: [(name: String, data: Data)], id: UUID, what: String) throws -> URL {
            var candidates = [AgentCaptureTools.captureDirectory(for: id, in: storage.capturesRoot)]
            var reasons: [String] = []
            do {
                candidates.append(try storage.fallbackDirectory(id))
            } catch {
                reasons.append(error.localizedDescription)
                AgentMCPToolResultContent.log.error(
                    "MCP tool result: no fallback directory for \(what, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            for directory in candidates {
                var created = false
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    created = true
                    for file in files {
                        try file.data.write(
                            to: directory.appendingPathComponent(file.name, isDirectory: false),
                            options: [.atomic]
                        )
                    }
                    return directory.standardizedFileURL
                } catch {
                    reasons.append(error.localizedDescription)
                    AgentMCPToolResultContent.log.error(
                        "MCP tool result: could not save \(what, privacy: .public) under \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    // 目录名是新生成的 UUID，只可能是这次建的，清掉半截的产物。
                    if created { try? FileManager.default.removeItem(at: directory) }
                }
            }
            throw PersistFailure(reasons: reasons)
        }
    }

    // MARK: - Decoding & encoding

    /// 估算解码体积时给换行等空白留的余量：限额的 1/16。
    private static let base64WhitespaceAllowanceDivisor = 16
    private static let dataURLBase64Marker = ";base64,"
    private static let fallbackBinaryExtension = "bin"
    private static let fallbackResourceStem = "resource"
    private static let maximumFilenameStemCharacters = 100
    private static let maximumFilenameExtensionCharacters = 16
    private static let bytesPerKilobyte = 1_024

    static func decodeBase64(_ raw: String) -> Data? {
        var text = Substring(raw)
        // 有的服务端给的是 data URL。
        if text.hasPrefix("data:"), let marker = text.range(of: dataURLBase64Marker) {
            text = text[marker.upperBound...]
        }
        if let data = Data(base64Encoded: String(text)) { return data }
        // 按 76 列折行的 base64 也常见；只去空白，不放过别的非法字符。
        let compact = String(String.UnicodeScalarView(
            text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        ))
        return Data(base64Encoded: compact)
    }

    /// 限边与编码沿用截图的规则（`AgentCaptureTools`）：长边不超过
    /// `maxLongEdge`，铺白底后按 `jpegQuality` 编成 JPEG。
    ///
    /// 用 ImageIO 的缩略图接口直接解到目标尺寸，不先解出整张原图；截图那边的
    /// 缩放函数挂在主 actor 上，这里要在后台跑。
    static func modelPreview(
        from source: CGImageSource,
        width: Int,
        height: Int
    ) -> (data: Data, width: Int, height: Int)? {
        let longEdge = min(CGFloat(max(width, height)), AgentCaptureTools.maxLongEdge)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(longEdge.rounded()),
        ] as CFDictionary),
              let flattened = flattenedOnWhite(image),
              let data = jpegData(flattened) else {
            return nil
        }
        return (data, image.width, image.height)
    }

    private static func flattenedOnWhite(_ image: CGImage) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return nil
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        return context.makeImage()
    }

    private static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: AgentCaptureTools.jpegQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length > 0 else { return nil }
        return data as Data
    }

    // MARK: - Names & formatting

    /// `image/png; charset=...` → `image/png`。
    static func normalizedMIME(_ raw: String?) -> String {
        guard let raw else { return "" }
        let base = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        return base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 系统类型库认不全的常见音频类型。
    private static let knownExtensions: [String: String] = [
        "audio/mpeg": "mp3",
        "audio/mp3": "mp3",
        "audio/wav": "wav",
        "audio/wave": "wav",
        "audio/x-wav": "wav",
        "audio/ogg": "ogg",
        "audio/opus": "opus",
        "audio/webm": "webm",
        "audio/flac": "flac",
        "audio/x-flac": "flac",
        "audio/aac": "aac",
        "audio/mp4": "m4a",
        "audio/x-m4a": "m4a",
        "audio/aiff": "aiff",
        "audio/x-aiff": "aiff",
    ]

    static func fileExtension(forMIME mime: String) -> String? {
        guard !mime.isEmpty else { return nil }
        if let known = knownExtensions[mime] { return known }
        return UTType(mimeType: mime)?.preferredFilenameExtension
    }

    private static func detectedMIME(_ source: CGImageSource) -> String {
        guard let type = CGImageSourceGetType(source),
              let mime = UTType(type as String)?.preferredMIMEType else { return BlockType.image }
        return mime
    }

    /// 原图扩展名按实际解出来的格式定，声明的 mimeType 可能不准。
    private static func imageFileExtension(source: CGImageSource, mime: String) -> String {
        if let type = CGImageSourceGetType(source),
           let fileExtension = UTType(type as String)?.preferredFilenameExtension {
            return fileExtension
        }
        return fileExtension(forMIME: mime) ?? fallbackBinaryExtension
    }

    /// 资源文件名取 URI 的最后一段（收敛成安全字符），没有扩展名时按 mimeType
    /// 补一个；都没有就是 `resource.bin`。资源本来就可以是任意类型，认不出
    /// 类型也照样落盘，不丢数据。
    static func resourceFilename(uri: String?, mime: String) -> String {
        let lastComponent = uri.flatMap { URL(string: $0)?.lastPathComponent } ?? ""
        let sanitized = String(lastComponent.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
                ? character
                : "_"
        })
        let trimmed = String(sanitized.drop(while: { $0 == "." }))
        let stem = String((trimmed as NSString).deletingPathExtension.prefix(maximumFilenameStemCharacters))
        let existingExtension = String((trimmed as NSString).pathExtension.prefix(maximumFilenameExtensionCharacters))
        let resolvedStem = stem.isEmpty ? fallbackResourceStem : stem
        let resolvedExtension = existingExtension.isEmpty
            ? (fileExtension(forMIME: mime) ?? fallbackBinaryExtension)
            : existingExtension
        return "\(resolvedStem).\(resolvedExtension)"
    }

    /// 给模型看的体积，不随系统语言变。
    static func formattedByteCount(_ bytes: Int) -> String {
        let kilobyte = bytesPerKilobyte
        let megabyte = kilobyte * kilobyte
        if bytes < kilobyte { return "\(bytes) B" }
        if bytes < megabyte { return "\(Int((Double(bytes) / Double(kilobyte)).rounded())) KB" }
        return String(format: "%.1f MB", Double(bytes) / Double(megabyte))
    }
}
