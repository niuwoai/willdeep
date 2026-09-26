//
//  SomeIMImageGenerationRequest.swift
//  WillDeep
//
//  `/images/generations` 的请求体。从 `SomeIMClient.generateImage` 里拆出来，
//  是为了能不发网络请求就把 body 钉进单测。
//
//  为什么要额外带 `aspect_ratio`：nano-banana 系（Gemini 出图）不认 OpenAI 的
//  `size`。插件递 `size: "1024x1536"` 要一张竖图，gpt-image-2 出来是
//  1024x1536，nano-banana-2 却永远是 1024x1024——而它恰恰是短剧工坊的默认出图
//  模型，竖屏首帧就这样变成了方图，随后的视频只能裁或拉伸。
//
//  字段名以 muchtoken 网关为准：网关自己唯一会读的比例字段是 snake_case 的
//  `aspect_ratio`（`internal/asyncmedia/params.go`、`internal/gateway/images.go`），
//  主路径则把 body 原样转给上游。网关控制台 Playground 的做法也一样：非 GPT
//  模型发 `aspect_ratio`，gpt-image 只发 `size`。
//
//  gpt-image / dall-e 家族**不带** `aspect_ratio`：它们认 `size`，而有的中继对
//  多余字段直接回 `unknown_parameter`（网关 `openai_images_payload.go` 的注释
//  记过这件事）。这条分支的 body 与改动前逐键一致。
//

import Foundation

nonisolated enum SomeIMImageGenerationRequest {
    /// Gemini 出图认的比例。`size` 约分后不在表里（比如 1792x1024 是 7:4），
    /// 就贴到最近的一档，而不是送一个上游不认、会被悄悄当成 1:1 的值。
    static let supportedAspectRatios: [(label: String, width: Int, height: Int)] = [
        ("1:1", 1, 1),
        ("2:3", 2, 3), ("3:2", 3, 2),
        ("3:4", 3, 4), ("4:3", 4, 3),
        ("4:5", 4, 5), ("5:4", 5, 4),
        ("9:16", 9, 16), ("16:9", 16, 9),
        ("21:9", 21, 9),
    ]

    static func body(
        model: String,
        prompt: String,
        size: String,
        referenceImageURLs: [String] = []
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "size": size
        ]
        if !isOpenAIImageFamily(model), let ratio = aspectRatio(forSize: size) {
            body["aspect_ratio"] = ratio
        }
        if !referenceImageURLs.isEmpty {
            // 两种写法都带上：网关会把它们归一化去重，而不同上游读的是不同
            // 那一个（严格 edits 读首图，GRSAI 读数组）。
            body["image_url"] = referenceImageURLs[0]
            body["reference_image_url"] = referenceImageURLs[0]
            body["image_urls"] = referenceImageURLs
            body["reference_image_urls"] = referenceImageURLs
        }
        return body
    }

    /// `"1024x1536"` → `"2:3"`。解析不了的（`"auto"`、空串、非正数）返回 nil，
    /// 调用方就不带这个字段，让上游按自己的默认来。
    static func aspectRatio(forSize size: String) -> String? {
        let parts = size.lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .split(separator: "x", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let width = Int(parts[0]), let height = Int(parts[1]),
              width > 0, height > 0 else {
            return nil
        }
        // 按对数比值找最近的一档：2:1 与 1:2 离 1:1 一样远，线性比值做不到这点。
        let target = log(Double(width) / Double(height))
        return supportedAspectRatios.min { lhs, rhs in
            abs(log(Double(lhs.width) / Double(lhs.height)) - target)
                < abs(log(Double(rhs.width) / Double(rhs.height)) - target)
        }?.label
    }

    /// OpenAI Images API 家族（gpt-image-*、dall-e-*）。判据照抄网关 Playground
    /// 的 `isGptImageFamilyModel`，再补上 dall-e。
    static func isOpenAIImageFamily(_ model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: " ", with: "-")
        guard !normalized.isEmpty else { return false }
        if normalized.contains("gpt-image") || normalized.contains("dall-e") { return true }
        return normalized.range(of: #"gpt-?\d+[-.]?image"#, options: .regularExpression) != nil
    }
}
