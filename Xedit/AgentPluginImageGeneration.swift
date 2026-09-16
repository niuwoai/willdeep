//
//  AgentPluginImageGeneration.swift
//  WillDeep
//
//  插件出图的唯一实现。两个入口共用它：
//  - 插件页面的 `window.willdeep.ai.generateImage`（`AppState.runPluginImageGeneration`）；
//  - 插件 MCP 进程在处理工具调用时反向请求宿主出图（`willdeep/images/generate`，
//    见 `AgentMCPHostRequests`）。
//
//  从 AppState 扩展里搬出来的原因：MCP 那条路没有页面、也不持有 AppState，
//  而这里用到的东西（插件注册表、生成目录、some.im 客户端）本来就都是全局的。
//  两个入口各写一份，迟早会在路径钳制或权限判断上漂开。
//

import Foundation

enum AgentPluginImageGeneration {
    static func run(
        pluginID: AgentPluginID,
        request: AgentPluginImageRequest
    ) async throws -> AgentPluginImageResult {
        guard AgentPluginRegistry.shared.hasPermission(.aiImage, pluginID: pluginID) else {
            throw AgentPluginAIError.imagePermissionDenied
        }
        let outputDirectory = try AgentPluginGeneratedMediaResolver.directory(pluginID: pluginID)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let referenceURLs = try await uploadedReferenceImages(
            paths: request.referenceImagePaths,
            mediaRoot: outputDirectory
        )
        let image = try await SomeIMClient.generateImage(
            prompt: request.prompt,
            size: request.size,
            model: request.model,
            outputDirectory: outputDirectory,
            referenceImageURLs: referenceURLs
        )
        let filename = image.fileURL.lastPathComponent
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed) ?? filename
        return AgentPluginImageResult(
            mediaURL: "willdeep-plugin://bundle/__media__/\(encoded)",
            filePath: image.fileURL.path,
            model: image.model,
            providerID: "some-im"
        )
    }

    /// 把递上来的参照图路径钳到本插件自己的生成目录里，再上传换 URL。
    ///
    /// 这道钳制是唯一的边界：调用方递的是路径，少了它，一个插件就能指使宿主
    /// 去读任意文件并**上传到公网**。判据和取图那条一致——规范化之后父目录
    /// 必须恰好等于本插件的媒体根，并且拒绝符号链接（否则根目录里放一个链接
    /// 就能指出去）。
    private static func uploadedReferenceImages(
        paths: [String],
        mediaRoot: URL
    ) async throws -> [String] {
        guard !paths.isEmpty else { return [] }
        let root = mediaRoot.standardizedFileURL.resolvingSymlinksInPath()
        var fileURLs: [URL] = []
        for path in paths {
            let candidate = URL(fileURLWithPath: path).standardizedFileURL
            guard candidate.isFileURL, candidate.path.hasPrefix("/") else {
                throw AgentPluginAIError.referenceImageOutsidePluginData(path)
            }
            let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values?.isSymbolicLink != true, values?.isRegularFile == true else {
                throw AgentPluginAIError.referenceImageOutsidePluginData(path)
            }
            let resolved = candidate.resolvingSymlinksInPath()
            guard resolved.deletingLastPathComponent() == root else {
                throw AgentPluginAIError.referenceImageOutsidePluginData(path)
            }
            fileURLs.append(resolved)
        }
        return try await SomeIMClient.uploadReferenceImages(fileURLs)
    }
}
