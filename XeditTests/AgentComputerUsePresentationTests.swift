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

    @Test("menu-bar status appears only for an attributed active lease")
    func statusItemVisibilityPolicy() {
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
            AgentComputerUseStatusItemPolicy.shouldPresent(
                state: .controlling(lease)
            )
        )
        #expect(
            !AgentComputerUseStatusItemPolicy.shouldPresent(state: .idle)
        )
        #expect(
            !AgentComputerUseStatusItemPolicy.shouldPresent(
                state: .failed(nil, message: "No lease")
            )
        )
    }

    @Test("local previews refresh only while control is operational")
    func previewVisibilityPolicy() {
        #expect(
            AgentComputerUseStatusItemPolicy.shouldRefreshPreview(
                phase: .observing
            )
        )
        #expect(
            AgentComputerUseStatusItemPolicy.shouldRefreshPreview(
                phase: .controlling
            )
        )
        #expect(
            !AgentComputerUseStatusItemPolicy.shouldRefreshPreview(
                phase: .userTakeover
            )
        )
        #expect(
            !AgentComputerUsePresentationPolicy.showsPreview(
                for: .paused
            )
        )
        #expect(
            AgentComputerUseStatusItemPolicy.menuBarIconSize
                == CGSize(width: 30, height: 18)
        )
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
