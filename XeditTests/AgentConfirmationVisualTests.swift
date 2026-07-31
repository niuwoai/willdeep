import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WillDeep

@Suite
struct AgentConfirmationVisualTests {
    @Test("render command confirmation in every interface skin")
    @MainActor
    func renderEverySkinForDesignQA() throws {
        let outputDirectory = try designQAOutputDirectory()
        let call = commandConfirmationCall(status: .pendingApproval)

        for skin in EditorInterfaceSkin.allCases {
            var settings = EditorSettings.default
            settings.interfaceSkinID = skin.id
            let appState = AppState(editorSettings: settings)
            let size = try render(
                call: call,
                appState: appState,
                width: 1_040,
                outputURL: outputDirectory.appendingPathComponent(
                    "command-confirmation-\(skin.id).png"
                )
            )
            #expect(size.width == 1_040)
            #expect(size.height > 260)
        }
    }

    @Test("render wide and narrow command confirmations for design QA")
    @MainActor
    func renderResponsiveCommandConfirmationForDesignQA() throws {
        let outputDirectory = try designQAOutputDirectory()

        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.ricePaper.id
        let appState = AppState(editorSettings: settings)
        let call = commandConfirmationCall(
            status: .awaitingConfirm,
            toolName: "terminal_send_command"
        )

        let wideSize = try render(
            call: call,
            appState: appState,
            width: 1_040,
            outputURL: outputDirectory.appendingPathComponent("command-confirmation-wide.png")
        )
        let mediumSize = try render(
            call: call,
            appState: appState,
            width: 520,
            outputURL: outputDirectory.appendingPathComponent("command-confirmation-medium.png")
        )
        let narrowSize = try render(
            call: call,
            appState: appState,
            width: 400,
            outputURL: outputDirectory.appendingPathComponent("command-confirmation-narrow.png")
        )

        #expect(wideSize.height <= mediumSize.height)
        #expect(mediumSize.height <= narrowSize.height)
        #expect(mediumSize.height < 400)
        #expect(wideSize.width == 1_040)
        #expect(mediumSize.width == 520)
        #expect(narrowSize.width == 400)
        #expect(AgentConfirmationReviewMetrics.usesHorizontalLayout(availableWidth: 1_040))
        #expect(!AgentConfirmationReviewMetrics.usesHorizontalLayout(availableWidth: 520))
        #expect(!AgentConfirmationReviewMetrics.usesHorizontalLayout(availableWidth: 400))
        #expect(
            AgentConfirmationReviewMetrics.horizontalContentMinimumWidth
                == AgentConfirmationReviewMetrics.horizontalMinimumWidth
                    - (AgentConfirmationReviewMetrics.contentPadding * 2)
        )
        #expect(AgentConfirmationReviewMetrics.commandVisibleLineCount == 3)
        #expect(AgentApprovalActionMetrics.minimumButtonHeight == 36)
        #expect(AgentConfirmationReviewMetrics.actionButtonHeight == 28)
        #expect(AgentConfirmationReviewMetrics.actionButtonMaxWidth == 124)
        #expect(AgentConfirmationReviewMetrics.actionButtonSpacing == 12)
        #expect(
            AgentApprovalNoticeCopy.descriptor(
                toolName: "terminal_send_command",
                arguments: [:]
            ).usesOutlinedApproveAction
        )
        #expect(
            !AgentApprovalNoticeCopy.descriptor(
                toolName: "run_command",
                arguments: [:]
            ).usesOutlinedApproveAction
        )
    }

    @Test("render Codex-style Computer Use and browser authorizations")
    @MainActor
    func renderCompactSurfaceAuthorizationsForDesignQA() throws {
        let outputDirectory = try designQAOutputDirectory()
        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.ricePaper.id
        let appState = AppState(editorSettings: settings)

        let computerUseSize = try render(
            call: surfaceAuthorizationCall(toolName: "computer_use_click"),
            appState: appState,
            width: 714,
            outputURL: outputDirectory.appendingPathComponent(
                "computer-use-authorization-codex-style.png"
            )
        )
        let browserSize = try render(
            call: surfaceAuthorizationCall(toolName: "chrome_click"),
            appState: appState,
            width: 714,
            outputURL: outputDirectory.appendingPathComponent(
                "browser-authorization-codex-style.png"
            )
        )

        #expect(computerUseSize.width == 714)
        #expect(browserSize.width == 714)
        #expect(computerUseSize.height < 180)
        #expect(browserSize.height < 180)
        #expect(AgentCompactAuthorizationMetrics.minimumButtonWidth == 76)
        #expect(AgentCompactAuthorizationMetrics.primaryButtonMinimumWidth == 112)
        #expect(AgentCompactAuthorizationMetrics.minimumButtonHeight == 36)
        #expect(AgentCompactAuthorizationMetrics.usesHorizontalActions(availableWidth: 714))
        #expect(!AgentCompactAuthorizationMetrics.usesHorizontalActions(availableWidth: 480))
    }

    @Test("当前动作文字从左向右扫光，计时保持稳定")
    func currentActionSweepStaysSubtle() {
        #expect(AgentActivitySweepMetrics.sweepDuration >= 1.0)
        #expect(AgentActivitySweepMetrics.pauseDuration >= 0.5)
        #expect(AgentActivitySweepMetrics.bandWidthFraction <= 0.4)
        #expect(AgentActivitySweepMetrics.progress(elapsed: 0) == 0)
        #expect(AgentActivitySweepMetrics.progress(
            elapsed: AgentActivitySweepMetrics.sweepDuration / 2
        ) == 0.5)
        #expect(AgentActivitySweepMetrics.progress(
            elapsed: AgentActivitySweepMetrics.sweepDuration + 0.1
        ) > 1)
        #expect(!AgentActivitySweepMetrics.animatesElapsedTime)
        #expect(AgentActivitySweepMetrics.maximumFramesPerSecond <= 12)
        #expect(
            AgentActivitySweepMetrics.frameInterval
                == 1.0 / AgentActivitySweepMetrics.maximumFramesPerSecond
        )
    }

    private func designQAOutputDirectory() throws -> URL {
        let outputDirectory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["WILLDEEP_CONFIRMATION_QA_OUTPUT"]
                ?? "/tmp/Xedit-confirmation-design-qa",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        return outputDirectory
    }

    private func commandConfirmationCall(
        status: AgentToolCallStatus,
        toolName: String = "run_command"
    ) -> AgentToolCall {
        AgentToolCall(
            messageID: UUID(),
            externalID: "command-confirmation-design-qa",
            toolName: toolName,
            arguments: [
                "command": .string(
                    "find 剧本 -name '*.md' | sort -t'第' -k2 -n | while read file; "
                        + "do bytes=$(wc -c < \"$file\"); echo \"$file ($bytes bytes)\"; done"
                ),
                "cwd": .string("/tmp/novel"),
            ],
            risk: .danger,
            status: status
        )
    }

    private func surfaceAuthorizationCall(toolName: String) -> AgentToolCall {
        AgentToolCall(
            messageID: UUID(),
            externalID: "surface-authorization-design-qa",
            toolName: toolName,
            arguments: ["ref": .string("snapshot:e1")],
            risk: .write,
            status: .pendingApproval
        )
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
            .preferredColorScheme(appState.editorSettings.interfaceSkin.preferredColorScheme)
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
