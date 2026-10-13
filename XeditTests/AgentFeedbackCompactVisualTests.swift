import AppKit
import SwiftUI
import Testing
@testable import WillDeep

@Suite("紧凑回合反馈", .serialized)
@MainActor
struct AgentFeedbackCompactVisualTests {
    @Test("默认反馈在宽窄窗口都只有一行，展开后显示完整操作")
    func renderCollapsedAndExpanded() throws {
        let review = sampleReview()
        for width: CGFloat in [1040, 520, 280] {
            for scheme in [ColorScheme.light, .dark] {
                let collapsed = try render(review: review, expanded: false, width: width, scheme: scheme)
                let expanded = try render(review: review, expanded: true, width: width, scheme: scheme)
                #expect(collapsed > 0 && collapsed <= 40)
                #expect(expanded > collapsed)
                #expect(expanded < 220)
            }
        }
    }

    @Test("没有待反馈回合时不再留下配置卡片")
    func noReviewLeavesNoCard() throws {
        let height = try render(review: nil, expanded: false, width: 520, scheme: .light, suffix: "empty")
        #expect(height <= 1)
    }

    @Test("模型判断和判断失败仍可在展开详情里查看")
    func renderAssessmentStates() throws {
        var review = sampleReview()
        review.assessmentFailed = true
        let failed = try render(review: review, expanded: true, width: 520, scheme: .light, suffix: "failed")
        review.assessmentFailed = false
        review.assessment = AgentFeedbackAssessment(schema: AgentFeedbackAssessment.schemaID, judgment: "needs_review", confidence: 80, reasonCode: "tool_failures")
        let assessed = try render(review: review, expanded: true, width: 520, scheme: .light, suffix: "assessed")
        #expect(failed > 40 && assessed > 40)
    }

    @Test("上一回合展开后，新回合默认恢复单行")
    func newTurnResetsExpansion() async throws {
        let makeView: (AgentFeedbackReview?) -> AnyView = { review in
            AnyView(AgentFeedbackReviewCard(review: review, initiallyExpanded: true,
                                           onDisposition: { _ in }, onAssess: {})
                .frame(width: 520).fixedSize(horizontal: false, vertical: true))
        }
        let view = NSHostingView(rootView: makeView(sampleReview()))
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 200)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.height > 40)
        view.rootView = makeView(nil)
        view.layoutSubtreeIfNeeded()
        view.rootView = makeView(sampleReview())
        for _ in 0..<50 {
            view.layoutSubtreeIfNeeded()
            if view.fittingSize.height > 0 && view.fittingSize.height <= 40 { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        Issue.record("New feedback turn kept the previous expanded state")
    }

    private func sampleReview() -> AgentFeedbackReview {
        AgentFeedbackReview(id: UUID(), turnID: UUID(), provider: nil, model: nil,
                            parameterFingerprint: nil, toolSuccesses: 8, toolFailures: 1, stopReason: "completed")
    }

    private func render(review: AgentFeedbackReview?, expanded: Bool, width: CGFloat,
                        scheme: ColorScheme, suffix: String = "") throws -> CGFloat {
        let root = AgentFeedbackReviewCard(review: review, initiallyExpanded: expanded,
                                          onDisposition: { _ in }, onAssess: {})
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, scheme)
        let view = NSHostingView(rootView: root)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        view.layoutSubtreeIfNeeded()
        let height = max(1, view.fittingSize.height)
        view.frame.size.height = height
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let name = "feedback-\(expanded ? "expanded" : "compact")-\(Int(width))-\(scheme == .dark ? "dark" : "light")\(suffix).png"
        try png.write(to: URL(fileURLWithPath: "/private/tmp/\(name)"))
        return height
    }
}
