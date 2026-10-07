import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WillDeep

@Suite("圆桌聊天卡片长文渲染", .serialized)
@MainActor
struct AgentRoundtableChatDesignTests {
    private func fixture(phase: AgentRoundtableReport.Phase, text: String) -> AgentRoundtableReport {
        let seats = [
            RoundtableCustomExpert(id: "chief", name: "总策划", expertise: "弧光与爽点", persona: "审读"),
            RoundtableCustomExpert(id: "pace", name: "节奏剪辑师", expertise: "前三秒与钩子", persona: "审读"),
            RoundtableCustomExpert(id: "continuity", name: "连续性编辑", expertise: "设定账本", persona: "审读")
        ]
        let start = Date().addingTimeInterval(-138)
        return AgentRoundtableReport(
            topic: "第 1 集剧本",
            title: "专家圆桌 · 第 1 集剧本",
            phase: phase,
            messages: [
                .init(speaker: .expert, round: 1, content: "先明确主角返乡的目标，再进入鸭苗争执。" + String(repeating: "背景通过人物行动呈现。", count: 200), createdAt: start.addingTimeInterval(32), customExpertID: "chief", speakerDisplayName: "总策划"),
                .init(speaker: .expert, round: 1, content: "账本记录 486 只，冲突中的数量必须一致。" + String(repeating: "核对前后口径。", count: 200), createdAt: start.addingTimeInterval(66), customExpertID: "continuity", speakerDisplayName: "连续性编辑")
            ],
            currentRound: 1,
            activeExpertDraft: phase == .discussing ? text : nil,
            customExperts: seats,
            activeCustomExpertID: phase == .discussing ? "pace" : nil,
            createdAt: start
        )
    }

    private func hosting(_ report: AgentRoundtableReport, width: CGFloat) -> NSHostingView<some View> {
        let card = AgentPluginRoundtableChatProgressCard(report: report, onOpen: {})
            .frame(width: width, alignment: .topLeading)
            .preferredColorScheme(.light)
        let host = NSHostingView(rootView: card)
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 720)
        host.layoutSubtreeIfNeeded()
        host.frame.size.height = host.fittingSize.height
        host.layoutSubtreeIfNeeded()
        return host
    }

    @Test("数万字当前发言不改变卡片高度")
    func longSpeechHasBoundedHeight() {
        let short = hosting(fixture(phase: .discussing, text: "先抛冲突。"), width: 900)
        let long = hosting(fixture(phase: .discussing, text: String(repeating: "背景放在争执里，前三秒先亮出数量不对。\n", count: 2_000)), width: 900)
        #expect(abs(short.fittingSize.height - long.fittingSize.height) < 30)
        #expect(long.fittingSize.height < 720)
    }

    @Test("导出实际原生流式与等待答复卡片，供设计验收")
    func renderSnapshots() throws {
        for phase in [AgentRoundtableReport.Phase.discussing, .awaitingUser] {
            let report = fixture(phase: phase, text: String(repeating: "我不同意把背景放在开场。前三秒先亮出数量不对，返乡原因可以在争执中带出来。\n\n", count: 80))
            let host = hosting(report, width: 900)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("willdeep-roundtable-chat-\(phase.rawValue).png")
            try png.write(to: output, options: .atomic)
            #expect(png.count > 10_000)
        }
    }
}
