import CoreGraphics
import Testing
@testable import WillDeep

struct AgentFeedbackFlowLayoutTests {
    @Test func actionsShareWideHeadingRow() {
        let plan = AgentFeedbackFlowPlan(sizes: [CGSize(width: 220, height: 48), CGSize(width: 360, height: 28)],
                                         width: 900, spacing: 16, trailingLastItem: true)
        #expect(plan.origins == [CGPoint.zero, CGPoint(x: 540, y: 0)])
        #expect(plan.size == CGSize(width: 900, height: 48))
    }

    @Test func narrowActionsWrapBelowHeadingWithoutTrailingOffset() {
        let plan = AgentFeedbackFlowPlan(sizes: [CGSize(width: 220, height: 48), CGSize(width: 280, height: 64)],
                                         width: 300, spacing: 16, trailingLastItem: true)
        #expect(plan.origins == [CGPoint.zero, CGPoint(x: 0, y: 64)])
        #expect(plan.size.height == 128)
    }

    @Test func rowsUseTallestControlAndExactFitDoesNotWrap() {
        let plan = AgentFeedbackFlowPlan(sizes: [CGSize(width: 80, height: 24), CGSize(width: 112, height: 30),
                                               CGSize(width: 80, height: 20)], width: 200, spacing: 8)
        #expect(plan.origins == [CGPoint.zero, CGPoint(x: 88, y: 0), CGPoint(x: 0, y: 38)])
        #expect(plan.size == CGSize(width: 200, height: 58))
    }

    @Test func emptyLayoutHasNoHeight() {
        let plan = AgentFeedbackFlowPlan(sizes: [], width: 300, spacing: 8)
        #expect(plan.origins.isEmpty)
        #expect(plan.size == .zero)
    }
}
