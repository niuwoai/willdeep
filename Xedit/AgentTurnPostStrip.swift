//
//  AgentTurnPostStrip.swift
//  WillDeep
//
//  1.85.0-rc13:把原本贴在 transcript 底部的两张大卡片(AgentTurnReportCard
//  + AgentLearningEventsCard)收成一行紧凑的 footer 图标条 + popover。
//
//  动机:用户反馈大卡片每轮都吃掉一屏底部空间 —— "agent learn from this turn
//  也一样,在当次 AI 输出后简要地用一行告诉用户学到了什么 skill 或加了什么
//  memory,用户可以展开,并一项项地进行拒绝或复制"。
//
//  当前实现范围:仅渲染 CURRENT 轮的数据(`appState.agentLatestTurnReport` /
//  `appState.agentLearningEvents`),挂在 AgentChatTranscript 的底部哨兵之
//  上。把这两张卡片彻底从 transcript inline 渲染中移走。
//
//  历史轮次的 per-message 图标(显示在 TextKit 历史 footer 上)是另一个量级
//  的活,需要扩展 AgentChatHistoryChromeRenderer 的 footer chrome 以及加
//  per-message snapshot 数据 —— 留给后续 rc。
//

import SwiftUI
import AppKit

struct AgentTurnPostStrip: View {
    // 1.103.0-rc11: report 入参保留只为外部 call site 兼容,内部不再渲染;
    // doc.text + 计数已搬进 TextKit footer chrome,跟 copy/clock/tokens 同一行。
    let report: AgentTurnReport?
    let learningEvents: [AgentLearningEvent]
    /// 1.85.0-rc16:Approve 回调,popover 里点 ✓ 触发,把 LearningEvent 上
    /// 的 pending `memoryDrafts` 真正写入 memory store。AppState 提供
    /// `applyAgentMemoryDrafts(for:)` 实现。
    var onApproveMemory: ((AgentLearningEvent) -> Void)? = nil

    @State private var showLearning = false

    private var hasLearning: Bool { !learningEvents.isEmpty }

    var body: some View {
        if hasLearning {
            HStack(spacing: 14) {
                learningButton
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var learningButton: some View {
        Button {
            showLearning.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 12, weight: .medium))
                Text(L10n.Transcript.postTurnLearningOneLiner(String(learningEvents.count)))
                    .font(AgentDesign.captionFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.purple)
        }
        .buttonStyle(.plain)
        .help(L10n.Transcript.postTurnLearningTooltip)
        .popover(isPresented: $showLearning, arrowEdge: .top) {
            // 1.102.0-rc1:5 条建议每条都可能展开 4 行 detail + 多行 action
            // 摘要,popover 没有 ScrollView 时直接撑出屏幕,用户反馈"看不全"。
            // 这里给定 maxHeight,溢出走原生滚动条。
            ScrollView {
                AgentLearningEventsCard(
                    events: learningEvents,
                    onReject: { event in
                        AgentLearningReviewStore.mark(id: event.id, decision: .dismissed)
                    },
                    onApprove: onApproveMemory,
                    capItems: false
                )
                .padding(12)
                .frame(width: 480, alignment: .leading)
            }
            .frame(width: 480)
            .frame(maxHeight: 520)
        }
    }
}
