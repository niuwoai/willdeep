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

    @Test("结构化长问题使用标题、正文与分组信息")
    @MainActor
    func structuredAskUserPromptPresentation() throws {
        let presentation = try #require(
            AgentAskUserPromptPresentationBuilder.make(arguments: structuredAskUserArguments())
        )

        #expect(presentation.title == "配置 SSO 数据库连接")
        #expect(presentation.body == "当前集群无法解析密码，请补充缺失信息，并确认其余默认配置。")
        #expect(presentation.requestedInformation == [
            "MySQL 用户 `m_u_1_5` 的 `DB_PASSWORD`",
        ])
        #expect(presentation.defaultAssumptions.count == 2)
        #expect(presentation.hasStructuredSections)
    }

    @Test("旧版长问题降级为通用标题和常规正文")
    @MainActor
    func legacyLongAskUserPromptUsesReadableFallback() throws {
        let longQuestion = String(repeating: "请确认这项配置。", count: 10)
        let presentation = try #require(
            AgentAskUserPromptPresentationBuilder.make(arguments: [
                "question": .string(longQuestion),
            ])
        )

        #expect(presentation.title == L10n.ToolCard.askUserDefaultTitle)
        #expect(presentation.body == longQuestion)
        #expect(!presentation.hasStructuredSections)
    }

    @Test("短问题保持原有单标题层级")
    @MainActor
    func shortAskUserPromptRemainsCompact() throws {
        let presentation = try #require(
            AgentAskUserPromptPresentationBuilder.make(arguments: [
                "question": .string("要继续吗？"),
            ])
        )

        #expect(presentation.title == "要继续吗？")
        #expect(presentation.body == nil)
    }

    @Test("渲染结构化 ask_user 供设计 QA")
    @MainActor
    func renderStructuredAskUserForDesignQA() throws {
        let outputDirectory = try designQAOutputDirectory()
        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.ricePaper.id
        let appState = AppState(editorSettings: settings)
        let wideSize = try render(
            call: structuredAskUserCall(),
            appState: appState,
            width: 1_040,
            outputURL: outputDirectory.appendingPathComponent(
                "ask-user-structured-option-2.png"
            )
        )
        let narrowSize = try render(
            call: structuredAskUserCall(),
            appState: appState,
            width: 520,
            outputURL: outputDirectory.appendingPathComponent(
                "ask-user-structured-option-2-narrow.png"
            )
        )

        #expect(wideSize.width == 1_040)
        #expect(wideSize.height > 320)
        #expect(wideSize.height < 720)
        #expect(narrowSize.width == 520)
        #expect(narrowSize.height > wideSize.height)
        #expect(narrowSize.height < 900)
    }

    @Test("渲染与正文对齐的黑白补丁审批供设计 QA")
    @MainActor
    func renderMonochromeAlignedPatchApprovalForDesignQA() throws {
        let outputDirectory = try designQAOutputDirectory()
        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.ricePaper.id
        let appState = AppState(editorSettings: settings)
        let proposal = AgentPatchProposal(
            messageID: UUID(),
            title: "编辑文件: internal/handler/mysql.go",
            diff: """
            *** Begin Patch
            *** Update File: internal/handler/mysql.go
            @@
            -return oldValue
            +return newValue
            *** End Patch
            """
        )
        let width: CGFloat = 760
        let root = VStack(alignment: .leading, spacing: 18) {
            Text("创建 guides 文档索引，并复制文档到前端静态目录。")
                .font(.system(size: 15))
                .padding(.leading, AgentChatHistoryLayoutMetrics.assistantContentHeadIndent)
                .padding(.trailing, AgentChatHistoryLayoutMetrics.assistantContentTailInset)

            AgentPatchProposalList(
                proposals: [proposal],
                maxContentWidth: AgentDesign.chatMaxContentWidth
            )
            .padding(.leading, AgentChatHistoryLayoutMetrics.assistantContentHeadIndent)
            .padding(.trailing, AgentChatHistoryLayoutMetrics.assistantContentTailInset)
            .frame(maxWidth: AgentDesign.chatMaxContentWidth, alignment: .leading)
        }
        .environmentObject(appState)
        .padding(.vertical, 24)
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(appState.editorSettings.interfaceSkin.windowBackground)
        .preferredColorScheme(.light)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        hostingView.layoutSubtreeIfNeeded()
        let size = NSSize(width: width, height: max(1, hostingView.fittingSize.height))
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(
            to: outputDirectory.appendingPathComponent("patch-approval-monochrome-aligned.png"),
            options: .atomic
        )

        #expect(size.width == width)
        #expect(size.height > 130)
        #expect(AgentPatchDecisionMetrics.buttonHeight == 26)
        #expect(AgentPatchDecisionMetrics.cornerRadius == 7)
    }

    /// 运行态扫光曾用 12fps TimelineView 驱动主窗口，每帧都会触发 macOS 26
    /// 的完整焦点/无障碍响应树扫描。生产组件必须保持静态，只允许显式注入
    /// progressOverride 的设计预览绘制单帧扫光。
    @Test("当前动作不创建连续动画时间线")
    func currentActionDoesNotCreateContinuousTimeline() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Xedit/AgentPanelView.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "struct AgentActivitySweepLabel: View"))
        let end = try #require(source.range(
            of: "private enum AgentInlineStatusLayout",
            range: start.upperBound..<source.endIndex
        ))
        let component = source[start.lowerBound..<end.lowerBound]

        #expect(!component.contains("TimelineView(.animation"))
        #expect(component.contains("if isActive, let progressOverride"))
        #expect(component.contains(".accessibilityHidden(true)"))
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

    @Test("设计预览扫光保持克制，运行计时不参与动画")
    func currentActionSweepPreviewStaysSubtle() {
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

    private func structuredAskUserArguments() -> [String: AgentJSONValue] {
        [
            "title": .string("配置 SSO 数据库连接"),
            "question": .string("当前集群无法解析密码，请补充缺失信息，并确认其余默认配置。"),
            "requested_information": .array([
                .string("MySQL 用户 `m_u_1_5` 的 `DB_PASSWORD`"),
            ]),
            "default_assumptions": .array([
                .string("节点 k8s-worker-05 · 镜像 0.2.0-rc1 · 域名 sso.vibapp.net"),
                .string("`${secret:online-sso-password}` 当前未绑定 Secret"),
            ]),
        ]
    }

    private func structuredAskUserCall() -> AgentToolCall {
        AgentToolCall(
            messageID: UUID(),
            externalID: "ask-user-structured-design-qa",
            toolName: "ask_user",
            arguments: structuredAskUserArguments(),
            risk: .userInput,
            status: .awaitingUserAnswer
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
