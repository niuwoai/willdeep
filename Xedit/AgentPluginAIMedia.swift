//
//  AgentPluginAIMedia.swift
//  WillDeep
//
//  插件页面问模型时附带的图片与视频。
//
//  起因是短剧工坊的内容审核：出图、出片之后要让一个多模态模型真的看一眼，
//  而不是只审生成时的提示词。在此之前 `ai.complete` 的消息只收字符串，
//  插件就算选了识图模型也递不进任何一张图。
//
//  三条边界，和参照图上传那条路（`uploadedReferenceImages`）同一套判据：
//  1. 页面递的是**路径**，不是字节。路径必须规范化后恰好落在本插件自己的
//     生成目录里，并拒绝符号链接——少了这道钳制，一个插件页就能让宿主读取
//     任意本地文件、再发给第三方模型。
//  2. 图片在宿主这侧解码、限边、重编码成 JPEG。页面递来的文件可能是 8K
//     PNG，原样 base64 进请求既烧 token 又容易被上游按体积拒掉。
//  3. 视频不假设 provider 支持 `video_url`：宿主用 AVFoundation 按时间均匀
//     抽关键帧，当成一组有序图片发出去。任何识图模型都能审，页面不必关心
//     哪家 adapter 认视频。
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum AgentPluginAIMedia {
    /// 一次请求里页面直接附的图片张数上限。
    static let maximumImages = 12
    /// 一次请求里附的视频个数上限。
    static let maximumVideos = 2
    /// 每个视频抽几帧。八帧对四到六秒的短剧镜头足够看清动作起止，
    /// 再多主要是在烧视觉 token。
    static let framesPerVideo = 8
    /// 送进模型之前把长边限到这里。1568 是主流视觉模型不再额外缩放的上限。
    static let maximumImagePixels = 1_568
    /// 单个源文件的体积上限。生成目录里的图不会超过它，超了多半是递错了文件。
    static let maximumImageBytes = 25 * 1_024 * 1_024
    static let maximumVideoBytes = 512 * 1_024 * 1_024
    /// 附件路径本身的长度上限，挡住拿超长字符串撑载荷。
    static let maximumPathCharacters = 4_096

    /// 规范化并钳制到插件生成目录。返回可读的普通文件 URL，否则抛
    /// `mediaOutsidePluginData`。
    static func clampedFileURL(path: String, mediaRoot: URL) throws -> URL {
        let root = mediaRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        guard candidate.isFileURL, path.hasPrefix("/") else {
            throw AgentPluginAIError.mediaOutsidePluginData(path)
        }
        let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values?.isSymbolicLink != true, values?.isRegularFile == true else {
            throw AgentPluginAIError.mediaOutsidePluginData(path)
        }
        let resolved = candidate.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent() == root else {
            throw AgentPluginAIError.mediaOutsidePluginData(path)
        }
        return resolved
    }

    /// 读一张图，限边后编码成 JPEG 附件。
    static func imageAttachment(at url: URL) throws -> AgentImageAttachment {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= maximumImageBytes else {
            throw AgentPluginAIError.unreadableMedia(url.lastPathComponent)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumImagePixels,
              ] as CFDictionary) else {
            throw AgentPluginAIError.unreadableMedia(url.lastPathComponent)
        }
        return try jpegAttachment(image, name: url.lastPathComponent)
    }

    /// 按时间均匀抽帧。取每段的中点而不是端点：第 0 秒常是黑场或转场，
    /// 最后一帧常被编码器截掉。
    static func videoFrames(at url: URL, count: Int = framesPerVideo) async throws -> [(seconds: Double, attachment: AgentImageAttachment)] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= maximumVideoBytes else {
            throw AgentPluginAIError.unreadableMedia(url.lastPathComponent)
        }
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw AgentPluginAIError.unreadableMedia(url.lastPathComponent)
        }
        let total = duration.seconds
        guard total.isFinite, total > 0, count > 0 else {
            throw AgentPluginAIError.unreadableMedia(url.lastPathComponent)
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumImagePixels, height: maximumImagePixels)
        // 允许就近取关键帧：精确到帧的解码对审核没有意义，只会慢几倍。
        let tolerance = CMTime(seconds: max(total / Double(count) / 4, 0.05), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var frames: [(seconds: Double, attachment: AgentImageAttachment)] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let seconds = total * (Double(index) + 0.5) / Double(count)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { continue }
            frames.append((seconds, try jpegAttachment(image, name: url.lastPathComponent)))
        }
        // 一帧都抽不出来说明文件不是能解码的视频，别发一个「附了视频」却
        // 没有画面的请求，让模型对着空气下结论。
        guard !frames.isEmpty else { throw AgentPluginAIError.unreadableMedia(url.lastPathComponent) }
        return frames
    }

    private static func jpegAttachment(_ image: CGImage, name: String) throws -> AgentImageAttachment {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AgentPluginAIError.unreadableMedia(name)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length > 0 else {
            throw AgentPluginAIError.unreadableMedia(name)
        }
        return AgentImageAttachment(mimeType: "image/jpeg", dataBase64: (data as Data).base64EncodedString())
    }
}
