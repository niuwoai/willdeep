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
        #expect(mediumSize.height < 440)
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
        #expect(AgentConfirmationReviewMetrics.commandVisibleLineCount == 5)
        #expect(AgentConfirmationReviewMetrics.commandScrollAxes.contains(.vertical))
        #expect(!AgentConfirmationReviewMetrics.commandScrollAxes.contains(.horizontal))
        #expect(AgentConfirmationReviewMetrics.commandViewportHeight == 112)
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
        let backgroundTaskSize = try render(
            call: surfaceAuthorizationCall(
                toolName: "kill_job",
                arguments: ["job_id": .string("job_540157")]
            ),
            appState: appState,
            width: 714,
            outputURL: outputDirectory.appendingPathComponent(
                "background-task-termination-authorization-compact.png"
            )
        )

        #expect(computerUseSize.width == 714)
        #expect(browserSize.width == 714)
        #expect(backgroundTaskSize.width == 714)
        #expect(computerUseSize.height < 180)
        #expect(browserSize.height < 180)
        #expect(backgroundTaskSize.height < 180)
        #expect(AgentCompactAuthorizationMetrics.minimumButtonWidth == 76)
        #expect(AgentCompactAuthorizationMetrics.primaryButtonMinimumWidth == 112)
        #expect(AgentCompactAuthorizationMetrics.minimumButtonHeight == 36)
        #expect(AgentCompactAuthorizationMetrics.usesHorizontalActions(availableWidth: 714))
        #expect(!AgentCompactAuthorizationMetrics.usesHorizontalActions(availableWidth: 480))
    }

    /// 扫光是给「正在看」的人的装饰性反馈，而它会持续整个回合——一条跑十
    /// 分钟的 run_command 就是十分钟的动画。一次 CA transaction flush 会把
    /// 所有待布局窗口一起过一遍，所以每一帧扫光都要付一次主窗口整棵视图树
    /// 的代价。窗口不活跃时必须停摆。
    @Test("窗口不活跃时扫光停摆")
    func sweepParksWhileWindowIsInactive() {
        #expect(AgentActivitySweepGate.shouldAnimate(
            isActive: true,
            reduceMotion: false,
            windowIsActive: true
        ))
        #expect(!AgentActivitySweepGate.shouldAnimate(
            isActive: true,
            reduceMotion: false,
            windowIsActive: false
        ))
        #expect(!AgentActivitySweepGate.shouldAnimate(
            isActive: false,
            reduceMotion: false,
            windowIsActive: true
        ))
        #expect(!AgentActivitySweepGate.shouldAnimate(
            isActive: true,
            reduceMotion: true,
            windowIsActive: true
        ))
    }

    /// 侧栏切换按钮在窗口过窄时不可点，但必须保持 enabled——AppKit 不会为
    /// 禁用控件跟踪鼠标，tooltip 也就永远弹不出来，用户只看到一个没有任何
    /// 解释的灰按钮。拒绝切换是 action 的职责。
    @Test("侧栏切换按钮保持可悬停以便解释原因")
    func sidebarToggleStaysHoverableWhileAutoHidden() {
        #expect(AgentSidebarToggleButtonState.isEnabled(isAutoHidden: true))
        #expect(AgentSidebarToggleButtonState.isEnabled(isAutoHidden: false))
        #expect(!AgentSidebarToggleButtonState.acceptsToggle(isAutoHidden: true))
        #expect(AgentSidebarToggleButtonState.acceptsToggle(isAutoHidden: false))
        #expect(
            AgentSidebarToggleButtonState.tooltip(isAutoHidden: true, isVisible: false)
                == L10n.Header.sidebarAutoHidden
        )
        #expect(
            AgentSidebarToggleButtonState.tooltip(isAutoHidden: false, isVisible: true)
                == L10n.Header.hideSidebar
        )
        #expect(
            AgentSidebarToggleButtonState.tooltip(isAutoHidden: false, isVisible: false)
                == L10n.Header.showSidebar
        )
    }

    @Test("标题栏搜索按钮紧跟在侧栏切换按钮之后")
    func titlebarSearchFollowsSidebarToggle() {
        let zoomFrame = CGRect(x: 54, y: 9, width: 14, height: 14)
        let sidebarFrame = AgentWindowChromeControlLayout.sidebarButtonFrame(after: zoomFrame)
        let searchFrame = AgentWindowChromeControlLayout.searchButtonFrame(after: sidebarFrame)

        #expect(sidebarFrame.minX == zoomFrame.maxX + AgentWindowChromeControlLayout.gapAfterZoom)
        #expect(searchFrame.minX == sidebarFrame.maxX + AgentWindowChromeControlLayout.interButtonGap)
        #expect(searchFrame.minY == sidebarFrame.minY)
        #expect(searchFrame.size == sidebarFrame.size)
        #expect(
            AgentWindowChromeControlLayout.hiddenSidebarHeaderLeadingInset
                > searchFrame.maxX - zoomFrame.minX
        )
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

    private func surfaceAuthorizationCall(
        toolName: String,
        arguments: [String: AgentJSONValue] = ["ref": .string("snapshot:e1")]
    ) -> AgentToolCall {
        AgentToolCall(
            messageID: UUID(),
            externalID: "surface-authorization-design-qa",
            toolName: toolName,
            arguments: arguments,
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
