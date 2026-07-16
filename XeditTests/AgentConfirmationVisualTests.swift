import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WillDeep

@Suite
struct AgentConfirmationVisualTests {
    @Test("render wide and narrow command confirmations for design QA")
    @MainActor
    func renderResponsiveCommandConfirmationForDesignQA() throws {
        let outputDirectory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["WILLDEEP_CONFIRMATION_QA_OUTPUT"]
                ?? "/tmp/Xedit-confirmation-design-qa",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.ricePaper.id
        let appState = AppState(editorSettings: settings)
        let call = AgentToolCall(
            messageID: UUID(),
            externalID: "command-confirmation-design-qa",
            toolName: "run_command",
            arguments: [
                "command": .string(
                    "find 剧本 -name '*.md' | sort -t'第' -k2 -n | while read file; "
                        + "do bytes=$(wc -c < \"$file\"); echo \"$file ($bytes bytes)\"; done"
                ),
                "cwd": .string("/tmp/novel")
            ],
            risk: .danger,
            status: .awaitingConfirm
        )

        let wideSize = try render(
            call: call,
            appState: appState,
            width: 1_040,
            outputURL: outputDirectory.appendingPathComponent("command-confirmation-wide.png")
        )
        let narrowSize = try render(
            call: call,
            appState: appState,
            width: 620,
            outputURL: outputDirectory.appendingPathComponent("command-confirmation-narrow.png")
        )

        #expect(wideSize.height < narrowSize.height)
        #expect(wideSize.width == 1_040)
        #expect(narrowSize.width == 620)
        #expect(AgentConfirmationReviewMetrics.usesHorizontalLayout(availableWidth: 1_040))
        #expect(!AgentConfirmationReviewMetrics.usesHorizontalLayout(availableWidth: 620))
        #expect(AgentConfirmationReviewMetrics.commandVisibleLineCount == 2)
        #expect(AgentConfirmationReviewMetrics.actionButtonHeight == 28)
        #expect(AgentConfirmationReviewMetrics.actionButtonMaxWidth == 124)
        #expect(AgentConfirmationReviewMetrics.actionButtonSpacing == 24)
    }

    @MainActor
    private func render(
        call: AgentToolCall,
        appState: AppState,
        width: CGFloat,
        outputURL: URL
    ) throws -> NSSize {
        let root = AgentToolCallCard(call: call)
            .environmentObject(appState)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .background(appState.editorSettings.interfaceSkin.windowBackground)
            .preferredColorScheme(.light)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        hostingView.layoutSubtreeIfNeeded()

        let fittingHeight = max(1, hostingView.fittingSize.height)
        let size = NSSize(width: width, height: fittingHeight)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: outputURL, options: .atomic)
        return size
    }
}
