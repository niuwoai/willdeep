//
//  AgentShortDramaProductionGapActions.swift
//  WillDeep
//
//  Compact production-gap action strip for the short-drama side panel.
//

import SwiftUI

extension AgentShortDramaPanel {
    @ViewBuilder
    func productionGapActionStrip(
        missingImages: Int,
        missingVideos: Int,
        openReviews: Int,
        missingAssetReferences: Int,
        openMediaTasks: @escaping () -> Void,
        sendImageContext: @escaping () -> Void,
        sendVideoContext: @escaping () -> Void,
        sendReviewContext: @escaping () -> Void,
        generateAssetReferences: @escaping () -> Void,
        isGeneratingAssetReferences: Bool
    ) -> some View {
        let parts = productionGapParts(
            missingImages: missingImages,
            missingVideos: missingVideos,
            openReviews: openReviews,
            missingAssetReferences: missingAssetReferences
        )
        if !parts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.clipboard")
                        .font(.caption2)
                    Text("制作缺口")
                        .font(.caption2.weight(.semibold))
                    Text(parts.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button(action: openMediaTasks) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("打开这个项目的媒体任务")
                }

                HStack(spacing: 6) {
                    if missingImages > 0 {
                        productionGapActionButton(
                            title: "补主图 \(missingImages)",
                            systemImage: "photo.stack",
                            help: "把缺主图队列和批量生成建议发送到聊天，并附带可直接预检/提交的参数",
                            action: sendImageContext
                        )
                    }
                    if missingVideos > 0 {
                        productionGapActionButton(
                            title: "补视频 \(missingVideos)",
                            systemImage: "film.stack",
                            help: "把缺视频队列和图生视频参数发送到聊天",
                            action: sendVideoContext
                        )
                    }
                    if openReviews > 0 {
                        productionGapActionButton(
                            title: "审片 \(openReviews)",
                            systemImage: "checklist",
                            help: "把未解决检查项和修复建议发送到聊天",
                            action: sendReviewContext
                        )
                    }
                    if missingAssetReferences > 0 {
                        Button(action: generateAssetReferences) {
                            Label("补参考 \(missingAssetReferences)", systemImage: "sparkles.rectangle.stack")
                                .font(.caption2.weight(.medium))
                        }
                        .buttonStyle(.borderless)
                        .focusable(false)
                        .disabled(isGeneratingAssetReferences)
                        .help("直接提交缺失的人物/场景参考图任务")
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.orange.opacity(0.16), lineWidth: 1)
            )
        }
    }

    func productionGapParts(
        missingImages: Int,
        missingVideos: Int,
        openReviews: Int,
        missingAssetReferences: Int
    ) -> [String] {
        var parts: [String] = []
        if missingImages > 0 { parts.append("缺主图 \(missingImages)") }
        if missingVideos > 0 { parts.append("缺视频 \(missingVideos)") }
        if openReviews > 0 { parts.append("检查项 \(openReviews)") }
        if missingAssetReferences > 0 { parts.append("缺参考 \(missingAssetReferences)") }
        return parts
    }

    private func productionGapActionButton(
        title: String,
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.medium))
        }
        .buttonStyle(.borderless)
        .focusable(false)
        .help(help)
    }
}
