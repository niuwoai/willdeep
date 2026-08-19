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

    @Test("session-sidebar divider keeps the current width as its minimum")
    func sessionSidebarDividerMetrics() {
        #expect(AgentSessionsSidebarResizeMetrics.minimumWidth == 230)
        #expect(AgentSessionsSidebarResizeMetrics.maximumWidth > AgentSessionsSidebarResizeMetrics.minimumWidth)
        #expect(AgentSessionsSidebarResizeMetrics.hitTargetWidth == AgentSidePanelResizeMetrics.hitTargetWidth)
        #expect(AgentSessionsSidebarResizeMetrics.lineWidth == AgentSidePanelResizeMetrics.lineWidth)
    }

    @Test("composer icons use only monochrome semantic colors")
    func composerIconsStayMonochrome() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "Xedit/AgentModeComposerView.swift",
            "Xedit/AgentComposerAttachments.swift",
            "Xedit/AgentComposerContextPickers.swift",
            "Xedit/AgentComposerFileAttachmentViews.swift",
            "Xedit/AgentComposerPaletteViews.swift",
            "Xedit/AgentComposerPickers.swift",
            "Xedit/AgentComposerSecondaryPickers.swift",
            "Xedit/AgentComposerTaskProgress.swift",
        ]
        let source = try relativePaths.map { relativePath in
            try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
        }.joined(separator: "\n")

        let chromaticNames = "accentColor|blue|green|orange|red|purple|teal|cyan|indigo|mint|yellow"
        let imagePattern = #"Image\(systemName:[\s\S]{0,220}?\.foregroundStyle\((?:Color\.)?(?:\#(chromaticNames))\)"#
        let labelPattern = #"Label\([\s\S]{0,220}?systemImage:[\s\S]{0,220}?\.foregroundStyle\((?:Color\.)?(?:\#(chromaticNames))\)"#
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)

        for pattern in [imagePattern, labelPattern] {
            let regex = try NSRegularExpression(pattern: pattern)
            #expect(regex.firstMatch(in: source, range: fullRange) == nil)
        }

        #expect(source.contains(".symbolRenderingMode(.monochrome)"))
        #expect(source.contains(".tint(AgentComposerChrome.iconPrimary)"))
        #expect(source.contains("static let iconPrimary = Color.primary.opacity(0.82)"))
        #expect(source.contains("static let iconSecondary = Color.secondary"))
        #expect(source.contains("static let actionForeground = Color(nsColor: .textBackgroundColor)"))
        #expect(!source.contains("LinearGradient(colors: [.teal, .blue]"))

        // Coding Plan was intentionally removed from the model picker. Keep
        // this visual contract focused on the remaining monochrome controls
        // instead of requiring the deleted purchase button to come back.
        #expect(!source.contains("buyCodingPlan"))
    }
}
