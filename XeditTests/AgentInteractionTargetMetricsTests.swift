import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentInteractionTargetMetricsTests {
    @Test("composer expands before applying its readable-width cap")
    func composerUsesStableAvailableWidth() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Xedit/AgentModeComposerView.swift"
            ),
            encoding: .utf8
        )

        let stableWidthModifiers =
            ".frame(maxWidth: .infinity)\n"
            + "                .frame(maxWidth: AgentDesign.chatMaxContentWidth)"
        #expect(source.contains(stableWidthModifiers))
    }

    @Test("side-panel divider keeps a forgiving hit target around a thin visual rule")
    func sidePanelDividerHitTarget() {
        #expect(AgentSidePanelResizeMetrics.hitTargetWidth >= 10)
        #expect(AgentSidePanelResizeMetrics.lineWidth == 1)
        #expect(
            AgentSidePanelResizeMetrics.hitTargetWidth
                > AgentSidePanelResizeMetrics.lineWidth
        )
    }
}
