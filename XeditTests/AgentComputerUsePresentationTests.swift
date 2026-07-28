import CoreGraphics
import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentComputerUsePresentationTests {
    @Test("active control exposes pause, takeover, and stop without resume")
    func activeControlActions() {
        for phase in [
            AgentComputerUseControlPhase.observing,
            AgentComputerUseControlPhase.controlling,
        ] {
            let actions = AgentComputerUsePresentationPolicy.actions(for: phase)
            #expect(actions.showsPause)
            #expect(actions.showsTakeover)
            #expect(!actions.showsResume)
            #expect(actions.showsStop)
        }
    }

    @Test("paused and user-takeover states expose an explicit resume")
    func yieldedControlActions() {
        for phase in [
            AgentComputerUseControlPhase.paused,
            AgentComputerUseControlPhase.userTakeover,
        ] {
            let actions = AgentComputerUsePresentationPolicy.actions(for: phase)
            #expect(!actions.showsPause)
            #expect(!actions.showsTakeover)
            #expect(actions.showsResume)
            #expect(actions.showsStop)
        }
    }

    @Test("stopping is non-interactive while failure remains dismissible")
    func terminalControlActions() {
        let stopping = AgentComputerUsePresentationPolicy.actions(for: .stopping)
        #expect(!stopping.showsPause)
        #expect(!stopping.showsTakeover)
        #expect(!stopping.showsResume)
        #expect(!stopping.showsStop)

        let failed = AgentComputerUsePresentationPolicy.actions(for: .failed)
        #expect(!failed.showsPause)
        #expect(!failed.showsTakeover)
        #expect(!failed.showsResume)
        #expect(failed.showsStop)
    }

    @Test("compact presentation never intercepts transparent conversation space")
    func compactPresentationPassesThroughHitTesting() {
        #expect(
            !AgentComputerUsePresentationPolicy.interceptsTransparentRegion(
                isExpanded: false
            )
        )
        #expect(
            AgentComputerUsePresentationPolicy.interceptsTransparentRegion(
                isExpanded: true
            )
        )
    }

    @Test("floating controls appear only for an attributed active lease")
    func floatingPanelVisibilityPolicy() {
        let lease = AgentComputerUseLease(
            owner: AgentComputerUseOwner(
                runtimeID: UUID(),
                turnID: UUID(),
                sessionTitle: "UI review"
            ),
            target: AgentComputerUseTarget(
                pid: 321,
                applicationName: "GitWise",
                bundleIdentifier: "com.example.gitwise",
                windowTitle: "Issues"
            ),
            operation: .controlling
        )

        #expect(
            AgentComputerUseFloatingPanelPolicy.shouldPresent(
                state: .controlling(lease)
            )
        )
        #expect(
            !AgentComputerUseFloatingPanelPolicy.shouldPresent(state: .idle)
        )
        #expect(
            !AgentComputerUseFloatingPanelPolicy.shouldPresent(
                state: .failed(nil, message: "No lease")
            )
        )
    }

    @Test("floating controls stay compact and centered above the screen edge")
    func floatingPanelGeometryPolicy() {
        let wideSize = AgentComputerUseFloatingPanelPolicy.size(
            availableWidth: 1_000
        )
        #expect(wideSize == CGSize(width: 660, height: 70))

        let narrowSize = AgentComputerUseFloatingPanelPolicy.size(
            availableWidth: 500
        )
        #expect(narrowSize == CGSize(width: 468, height: 70))

        let origin = AgentComputerUseFloatingPanelPolicy.origin(
            panelSize: wideSize,
            visibleFrame: CGRect(x: 100, y: 50, width: 1_000, height: 700)
        )
        #expect(origin == CGPoint(x: 270, y: 68))

        let displayIndex = AgentComputerUseFloatingPanelPolicy.displayIndex(
            forWindowBounds: CGRect(
                x: 2_100,
                y: 120,
                width: 1_000,
                height: 800
            ),
            displayBounds: [
                CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
                CGRect(x: 1_920, y: 0, width: 2_560, height: 1_440),
            ]
        )
        #expect(displayIndex == 1)
    }

    @Test("all visible Computer Use labels come from non-empty localized resources")
    func localizedLabelsAreAvailable() {
        let labels = [
            L10n.ComputerUsePreview.idle,
            L10n.ComputerUsePreview.observing,
            L10n.ComputerUsePreview.controlling,
            L10n.ComputerUsePreview.paused,
            L10n.ComputerUsePreview.userTakeover,
            L10n.ComputerUsePreview.stopping,
            L10n.ComputerUsePreview.stoppingDetail,
            L10n.ComputerUsePreview.failed,
            L10n.ComputerUsePreview.unknownTarget,
            L10n.ComputerUsePreview.pause,
            L10n.ComputerUsePreview.takeOver,
            L10n.ComputerUsePreview.resume,
            L10n.ComputerUsePreview.stop,
            L10n.ComputerUsePreview.statusAccessibility,
        ]

        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(L10n.ComputerUsePreview.owningTask("UI review").contains("UI review"))
    }
}
