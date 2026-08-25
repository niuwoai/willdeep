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

    @Test("waiting-approval badge is an emphasized black capsule")
    func waitingApprovalBadgeUsesBlackAndWhiteHierarchy() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Xedit/AgentSessionApprovalBadge.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains(".foregroundStyle(Color.white)"))
        #expect(source.contains(".background(Color.black, in: Capsule())"))
        #expect(!source.contains(".background(Color.primary.opacity(0.05), in: Capsule())"))
    }

    @Test("composer image thumbnails expose the existing large-image preview")
    func composerImageThumbnailOpensPreviewWindow() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Xedit/AgentImageViews.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("Button(action: onPreview)"))
        #expect(source.contains("AgentImagePreviewWindowRegistry.shared.open(image: image)"))
        #expect(source.contains(".accessibilityLabel(L10n.ImagePreview.openButton)"))
    }

    @Test("patch review actions stay monochrome and align with assistant prose")
    func patchReviewActionsUseMonochromeHierarchyAndTranscriptInsets() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let panelCardsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Xedit/AgentPanelCards.swift"
            ),
            encoding: .utf8
        )
        let transcriptSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Xedit/AgentChatTranscript.swift"
            ),
            encoding: .utf8
        )

        #expect(panelCardsSource.contains("AgentApprovalPrimaryButtonStyle("))
        #expect(panelCardsSource.contains("AgentApprovalSecondaryButtonStyle("))
        #expect(!panelCardsSource.contains("Color.accentColor"))
        #expect(panelCardsSource.contains(".symbolRenderingMode(.monochrome)"))
        #expect(transcriptSource.contains(
            "AgentPatchProposalList(\n                        proposals: appState.agentPatchProposals"
        ))
        #expect(transcriptSource.contains(
            ".padding(.leading, AgentChatHistoryLayoutMetrics.assistantContentHeadIndent)"
        ))
        #expect(transcriptSource.contains(
            ".padding(.trailing, AgentChatHistoryLayoutMetrics.assistantContentTailInset)"
        ))
    }
}
