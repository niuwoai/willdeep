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

    @Test("Terminal host-verification popover cannot auto-focus its copy action")
    func hostVerificationCopyActionIsNotFocusable() throws {
        let source = try Self.source(named: "AgentSidePanelTerminalView.swift")
        let copyAction = try #require(
            source.range(of: "Button(action: copyAction)")
        )
        let trailingSource = source[copyAction.lowerBound...]
        let buttonStyle = try #require(trailingSource.range(of: ".buttonStyle(.plain)"))
        let focusPolicy = try #require(trailingSource.range(of: ".focusable(false)"))

        #expect(focusPolicy.lowerBound > buttonStyle.lowerBound)
        #expect(trailingSource.distance(from: buttonStyle.lowerBound, to: focusPolicy.lowerBound) < 80)
    }

    @Test("Render host-verification popover for design QA")
    @MainActor
    func renderHostVerificationPopoverForDesignQA() throws {
        let defaultOutputURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/visual-qa/side-panel-focus/implementation-rc11.png")
        let outputPath = ProcessInfo.processInfo.environment["WILLDEEP_SIDE_PANEL_FOCUS_QA_OUTPUT"]
            ?? defaultOutputURL.path
        guard FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: outputPath).deletingLastPathComponent().path
        ) else { return }

        let size = NSSize(width: 330, height: 156)
        let root = AgentHostVerificationPopover(
            hostnameCommandCopied: false,
            palette: EditorInterfaceSkin.system.palette,
            copyAction: {}
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
