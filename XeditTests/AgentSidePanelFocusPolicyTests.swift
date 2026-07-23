import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WillDeep

@Suite("Agent side-panel focus policy")
struct AgentSidePanelFocusPolicyTests {
    private static let panelSourceFiles = [
        "AgentSidePanel.swift",
        "AgentSidePanelTerminalView.swift",
        "AgentTaskMonitorRail.swift",
        "AgentConversationActivityOverlay.swift",
        "AgentMediaTasks.swift",
        "AgentMediaTaskRow.swift",
        "AgentDevServerPanel.swift",
        "AgentShortDrama.swift",
        "AgentShortDramaArtifactTile.swift",
        "AgentShortDramaAssetViews.swift",
        "AgentShortDramaProductionGapActions.swift",
        "AgentEmbeddedBrowser.swift",
        "AgentImageEditPanel.swift",
    ]

    @Test("Side-panel chrome controls stay out of the keyboard focus chain")
    func sidePanelChromeControlsAreNotFocusable() throws {
        for fileName in Self.panelSourceFiles {
            let source = try Self.source(named: fileName)
            let lines = source.components(separatedBy: .newlines)

            for (index, line) in lines.enumerated() where Self.isChromeControlModifier(line) {
                let end = min(index + 5, lines.count - 1)
                let modifierWindow = lines[index...end].joined(separator: "\n")
                #expect(
                    modifierWindow.contains(".focusable(false)"),
                    "\(fileName):\(index + 1) must apply .focusable(false) to side-panel chrome"
                )
            }
        }
    }

    @Test("Terminal shortcut rows fit three entries without a circled play button")
    func terminalShortcutRowsStayCompact() throws {
        #expect(TerminalRecordingMetrics.visibleHistoryRows == 3)
        #expect(TerminalRecordingMetrics.historyRowHeight == 28)
        #expect(TerminalRecordingMetrics.playButtonSize == 22)

        let source = try Self.source(named: "AgentSidePanelTerminalView.swift")
        let controlStart = try #require(source.range(of: "private func shortcutControl("))
        let detailsStart = try #require(
            source.range(of: "private func shortcutDetails(", range: controlStart.upperBound..<source.endIndex)
        )
        let shortcutControlSource = source[controlStart.lowerBound..<detailsStart.lowerBound]
        #expect(!shortcutControlSource.contains("Circle()"))
    }

    @Test("Terminal shortcut copy emphasizes quick command execution")
    func terminalShortcutCopyDescribesQuickExecution() throws {
        let catalog = try Self.source(named: "Localizable.xcstrings")
        let localization = try Self.source(named: "L10n+AgentTerminal.swift")

        #expect(catalog.contains("录制常用命令，之后可快捷执行"))
        #expect(catalog.contains("\"value\" : \"执行\""))
        #expect(catalog.contains("\"value\" : \"停止执行\""))
        #expect(!catalog.contains("录制终端操作，稍后可重复播放"))
        #expect(localization.contains("defaultValue: \"Record common commands for quick execution later\""))
        #expect(!localization.contains("defaultValue: \"Replay\""))
    }

    @Test("Retired task monitor cannot return from persisted session state")
    func retiredTaskMonitorIsNormalizedOnSessionChanges() throws {
        let source = try Self.source(named: "AgentModeView.swift")

        #expect(source.contains("if appState.agentSidePanelKind == .backgroundTasks"))
        #expect(source.contains("if newPanel == .backgroundTasks"))
        #expect(source.contains("guard request.kind != .backgroundTasks else"))
        #expect(source.contains("let activeSidePanel: AgentSidePanelKind? = if appState.agentPrimaryDestination == .scheduledTasks"))
        #expect(source.contains("else if appState.agentSidePanelKind == .backgroundTasks"))
        #expect(source.contains("newPanel == .backgroundTasks ? nil : newPanel"))
    }

    @Test("Activity cards use a light gray border and dismiss control")
    func activityCardsExposeDismissControlAndGrayBorder() throws {
        let source = try Self.source(named: "AgentConversationActivityOverlay.swift")

        #expect(source.contains("AgentActivityCardDismissButton"))
        #expect(source.contains("Image(systemName: \"xmark\")"))
        #expect(!source.contains("Image(systemName: \"chevron.right\")"))
        #expect(source.contains(".help(\"关闭摘要\")"))
        #expect(source.contains("borderColor = Color(nsColor: .separatorColor)"))
        #expect(source.contains("dismissedCardKeys.insert"))
    }

    @Test("Render host-identity popover for design QA")
    @MainActor
    func renderHostIdentityPopoverForDesignQA() throws {
        let defaultOutputURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/visual-qa/side-panel-focus/implementation-rc11.png")
        let outputPath = ProcessInfo.processInfo.environment["WILLDEEP_SIDE_PANEL_FOCUS_QA_OUTPUT"]
            ?? defaultOutputURL.path
        guard FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: outputPath).deletingLastPathComponent().path
        ) else { return }

        let size = NSSize(width: 330, height: 220)
        let tab = AgentTerminalTab(
            kind: .localShell,
            originAgentSessionID: nil,
            title: "Shell 1",
            settings: EditorTerminalSettings.default
        )
        let root = AgentHostIdentityPopover(
            tab: tab,
            palette: EditorInterfaceSkin.system.palette
        )
        .frame(width: size.width, height: size.height, alignment: .top)
        .preferredColorScheme(.light)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    private static func isChromeControlModifier(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains(".buttonStyle(")
            || trimmed.contains(".menuStyle(")
            || trimmed.contains(".pickerStyle(")
            || trimmed.hasPrefix("Slider(")
            || trimmed.hasPrefix("Toggle(")
    }

    private static func source(named fileName: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Xedit", isDirectory: true)
            .appendingPathComponent(fileName)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
