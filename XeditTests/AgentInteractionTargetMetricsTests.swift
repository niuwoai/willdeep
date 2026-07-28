import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentInteractionTargetMetricsTests {
    @Test("transcript and composer share the centered readable column")
    func chatSurfacesShareReadableColumn() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let composerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Xedit/AgentModeComposerView.swift"
            ),
            encoding: .utf8
        )
        let transcriptSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Xedit/AgentChatTranscript.swift"
            ),
            encoding: .utf8
        )
        let layoutSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Xedit/AgentModeView.swift"
            ),
            encoding: .utf8
        )

        #expect(composerSource.contains(
            ".agentChatReadableColumn(verticalPadding: 14)"
        ))
        #expect(transcriptSource.contains(
            ".agentChatReadableColumn(verticalPadding: 20)"
        ))
        #expect(layoutSource.contains(
            ".frame(minWidth: 0, maxWidth: .infinity, alignment: .center)"
        ))
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
