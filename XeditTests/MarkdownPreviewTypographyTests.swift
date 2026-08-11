import Foundation
import Testing
@testable import WillDeep

@Suite
struct MarkdownPreviewTypographyTests {
    @Test("Agent preview typography follows the chat appearance values")
    func agentAppearanceValues() {
        let typography = MarkdownPreviewTypography.agentAppearance(
            fontID: AgentChatFontChoice.serif.id,
            baseFontSize: 18,
            lineHeightMultiple: 1.75
        )

        #expect(typography.fontID == AgentChatFontChoice.serif.id)
        #expect(typography.baseFontSize == 18)
        #expect(typography.headingBaseFontSize == 18)
        #expect(typography.tableFontSize == 18)
        #expect(abs(typography.bodyLineSpacing - 13.5) < 0.001)
        #expect(abs(typography.headingSize(level: 1) - 31.2) < 0.001)
        #expect(abs(typography.headingSize(level: 4) - 18) < 0.001)
    }

    @Test("Agent preview typography uses the same persisted setting clamps as chat")
    func agentAppearanceClampsInvalidValues() {
        let typography = MarkdownPreviewTypography.agentAppearance(
            fontID: "missing-font",
            baseFontSize: 200,
            lineHeightMultiple: 10
        )

        #expect(typography.fontID == AgentSettingsStore.chatFontIDDefault)
        #expect(typography.baseFontSize == AgentSettingsStore.chatBaseFontSizeMax)
        #expect(typography.headingBaseFontSize == AgentSettingsStore.chatBaseFontSizeMax)
        #expect(typography.tableFontSize == AgentSettingsStore.chatBaseFontSizeMax)
        #expect(typography.lineHeightMultiple == AgentSettingsStore.chatLineHeightMultipleMax)
    }

    @Test("The Agent preview sidebar injects current chat appearance settings")
    func previewSidebarWiring() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Xedit/AgentSidePanel.swift"),
            encoding: .utf8
        )

        #expect(source.contains("fontID: appState.agentChatFontID"))
        #expect(source.contains("baseFontSize: appState.agentChatBaseFontSize"))
        #expect(source.contains("lineHeightMultiple: appState.agentChatLineHeightMultiple"))
        #expect(source.contains("typography: previewTypography"))
    }
}
