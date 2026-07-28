//
//  AgentComputerUseToolTests.swift
//  XeditTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentComputerUseToolTests {
    @Test
    func latestComputerUseActivityUsesNewestMatchingToolScreenshot() throws {
        let first = try AgentImageAttachment.fileBacked(
            data: Data([0x01]),
            mimeType: "image/jpeg",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let second = try AgentImageAttachment.fileBacked(
            data: Data([0x02]),
            mimeType: "image/jpeg",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        defer {
            first.removeStoredFileIfNeeded()
            second.removeStoredFileIfNeeded()
        }

        let messages = [
            AgentMessage(
                role: .assistant,
                content: "",
                toolCalls: [
                    AgentMessageToolCall(externalID: "cu-1", toolName: "computer_use_get_app_state", argumentsJSON: "{}"),
                    AgentMessageToolCall(externalID: "other", toolName: "capture_screenshot", argumentsJSON: "{}"),
                    AgentMessageToolCall(externalID: "cu-2", toolName: "computer_use_click", argumentsJSON: "{}")
                ]
            ),
            AgentMessage(role: .tool, content: "first", images: [first], toolCallID: "cu-1"),
            AgentMessage(role: .tool, content: "other", images: [first], toolCallID: "other"),
            AgentMessage(role: .tool, content: "second", images: [second], toolCallID: "cu-2")
        ]

        let activity = try #require(AgentComputerUseActivity.latest(in: messages))
        #expect(activity.image.id == second.id)
        #expect(activity.toolName == "computer_use_click")
        #expect(activity.capturedAt == Date(timeIntervalSince1970: 20))
    }

    @Test
    func latestComputerUseActivityIgnoresUnrelatedImages() throws {
        let image = try AgentImageAttachment.fileBacked(data: Data([0x01]), mimeType: "image/jpeg")
        defer { image.removeStoredFileIfNeeded() }
        let messages = [
            AgentMessage(
                role: .assistant,
                content: "",
                toolCalls: [
                    AgentMessageToolCall(externalID: "capture-1", toolName: "capture_screenshot", argumentsJSON: "{}")
                ]
            ),
            AgentMessage(role: .tool, content: "capture", images: [image], toolCallID: "capture-1")
        ]

        #expect(AgentComputerUseActivity.latest(in: messages) == nil)
    }

    @Test
    func computerUseToolRiskBoundariesAreExplicit() throws {
        let permissions = try #require(AgentToolRegistry.descriptor(for: "computer_use_permissions"))
        let apps = try #require(AgentToolRegistry.descriptor(for: "computer_use_list_apps"))
        let inspect = try #require(AgentToolRegistry.descriptor(for: "computer_use_inspect_app"))
        let state = try #require(AgentToolRegistry.descriptor(for: "computer_use_get_app_state"))
        let wait = try #require(AgentToolRegistry.descriptor(for: "computer_use_wait_for"))
        #expect(permissions.risk == .read)
        #expect(apps.risk == .read)
        #expect(inspect.risk == .read)
        #expect(state.risk == .read)
        #expect(wait.risk == .read)
        for name in [
            "computer_use_request_permissions", "computer_use_launch_app", "computer_use_activate_app",
            "computer_use_click", "computer_use_secondary_action", "computer_use_scroll", "computer_use_drag",
            "computer_use_type_text", "computer_use_press_key", "computer_use_set_value", "computer_use_focus",
            "computer_use_hover", "computer_use_select_text", "computer_use_restart_helper"
        ] {
            let descriptor = try #require(AgentToolRegistry.descriptor(for: name))
            #expect(descriptor.risk == .write, "\(name) must require approval")
        }
    }

    @Test
    func pureScreenshotToolsRunWithoutWillDeepApprovalCards() throws {
        for name in [
            "capture_screenshot",
            "computer_use_get_app_state",
            "chrome_capture_tab",
            "embedded_browser_capture_screenshot",
        ] {
            let descriptor = try #require(AgentToolRegistry.descriptor(for: name))
            let decision = AgentSandboxPolicy.decision(
                toolName: name,
                arguments: [:],
                rootDirectory: nil
            )
            #expect(descriptor.risk == .read, "\(name) must be read-only")
            #expect(!decision.requiresUserApproval, "\(name) must not show an approval card")
            #expect(!decision.requiresTypedConfirmation)
        }
    }

    @Test
    func toolContextPreservesSystemPermissionPersistenceBarrier() async throws {
        var barrierCallCount = 0
        let context = AgentToolContext(
            rootDirectory: nil,
            sessionPersistenceBarrier: {
                barrierCallCount += 1
            }
        )

        let copied = context
            .withAdditionalSecretRedactionValues(["redacted"])
            .withSandboxMode(.workspaceWrite)
        let barrier = try #require(copied.sessionPersistenceBarrier)
        barrier()

        #expect(barrierCallCount == 1)
    }

    @Test
    func computerUseHelperOwnsScreenCapturePermissionContract() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helperInfoURL = repositoryRoot
            .appendingPathComponent("ComputerUseHelper/Info.plist")
        let helperInfoData = try Data(contentsOf: helperInfoURL)
        let helperInfo = try #require(
            PropertyListSerialization.propertyList(
                from: helperInfoData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        #expect(helperInfo["CFBundleIdentifier"] as? String == "com.willdeep.computer-use-helper")
        #expect(helperInfo["NSScreenCaptureUsageDescription"] != nil)

        let mainInfoData = try Data(
            contentsOf: repositoryRoot.appendingPathComponent("Xedit/Info.plist")
        )
        let mainInfo = try #require(
            PropertyListSerialization.propertyList(
                from: mainInfoData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        #expect(mainInfo["NSScreenCaptureUsageDescription"] == nil)

        let helperSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("ComputerUseHelper/main.swift"),
            encoding: .utf8
        )
        #expect(helperSource.contains("\"capture_display\""))
        #expect(helperSource.contains("\"needs_helper_restart\""))
        #expect(!helperSource.contains("\"requires_helper_restart\""))

        let mainSourceRoot = repositoryRoot.appendingPathComponent("Xedit")
        let sourceEnumerator = try #require(
            FileManager.default.enumerator(
                at: mainSourceRoot,
                includingPropertiesForKeys: nil
            )
        )
        for case let sourceURL as URL in sourceEnumerator
        where sourceURL.pathExtension == "swift" {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            #expect(!source.contains("CGRequestScreenCaptureAccess("), "\(sourceURL.lastPathComponent) must not request Screen Recording")
            #expect(!source.contains("/usr/sbin/screencapture"), "\(sourceURL.lastPathComponent) must not invoke screencapture")
        }
    }

    @Test
    func screenshotArtifactsPersistUnderWillDeepCaptureDirectory() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-capture-test-\(UUID().uuidString)", isDirectory: true)
        let rawURL = temporaryRoot.appendingPathComponent("incoming/raw.png")
        try FileManager.default.createDirectory(
            at: rawURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x01, 0x02, 0x03]).write(to: rawURL)
        let preview = Data([0x04, 0x05])
        let captureID = UUID()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let persisted = try AgentCaptureTools.persistCaptureArtifacts(
            originalURL: rawURL,
            previewData: preview,
            captureID: captureID,
            capturesRoot: temporaryRoot.appendingPathComponent(".willdeep/captures")
        )

        #expect(persisted.originalURL.lastPathComponent == "original.png")
        #expect(FileManager.default.fileExists(atPath: persisted.originalURL.path))
        #expect(persisted.attachment.source == .capture)
        #expect(persisted.attachment.fileURL?.lastPathComponent == "preview.jpg")
        #expect(persisted.attachment.byteCount == preview.count)
        #expect(!FileManager.default.fileExists(atPath: rawURL.path))
    }

    @Test
    func capturedToolImageIsSurfacedOnFinalAssistantMessage() throws {
        let capture = AgentImageAttachment(
            mimeType: "image/jpeg",
            dataBase64: Data([0x01]).base64EncodedString(),
            source: .capture
        )
        let assistant = AgentMessage(role: .assistant, content: "截图完成。")
        let runtime = AgentRuntime(
            session: AgentSession(
                messages: [
                    AgentMessage(
                        role: .tool,
                        content: "captured",
                        images: [capture],
                        toolCallID: "capture-1"
                    ),
                    assistant,
                ]
            )
        )

        let appState = AppState()
        appState.attachRecentVisibleToolImages(to: assistant.id, in: runtime)

        #expect(runtime.messages.last?.images.map(\.id) == [capture.id])
    }

    @Test
    @MainActor
    func computerUseActionsCannotAutoApproveWithoutMatchingRuntimeLease() async {
        let arguments: [String: AgentJSONValue] = [
            "pid": .number(123),
            "snapshot_id": .string("snapshot"),
            "x": .number(10),
            "y": .number(10),
            "target_label": .string("General"),
            "purpose": .string("Open the requested settings tab"),
            "consequence": .string("navigation"),
        ]
        let risk = AgentToolRegistry.risk(
            for: "computer_use_click",
            arguments: arguments
        )
        let decision = AgentSandboxPolicy.decision(
            toolName: "computer_use_click",
            arguments: arguments,
            rootDirectory: nil
        )
        #expect(risk == .danger)
        #expect(decision.mode == .escalated)
        #expect(decision.requiresUserApproval)
        #expect(decision.requiresTypedConfirmation)

        let appState = AppState()
        let approval = await appState.autoApprovalSource(
            toolName: "computer_use_click",
            arguments: arguments,
            risk: risk,
            rootDirectory: nil,
            interactionMode: .goal,
            approvalMode: .workspaceAccess,
            conversationAllowedToolSignatures: ["computer_use:*"],
            computerUseOwner: AgentComputerUseOwner(
                runtimeID: UUID(),
                turnID: UUID(),
                sessionTitle: "Test"
            )
        )
        #expect(approval == nil)
    }

    @Test
    func computerUseAuthorizationNeverUsesFamilyScopedConversationGrant() async {
        #expect(
            AgentToolAuthorization.interactiveSurfaceSignature(
                toolName: "computer_use_click"
            ) == nil
        )
        #expect(
            AgentToolAuthorization.signature(
                toolName: "computer_use_type_text",
                arguments: ["pid": .number(123), "text": .string("hello")]
            ) == nil
        )

        let semanticArguments: [String: AgentJSONValue] = [
            "pid": .number(123),
            "snapshot_id": .string("snapshot"),
            "ref": .string("snapshot:e1"),
            "target_label": .string("General"),
            "purpose": .string("Open the requested settings tab"),
            "consequence": .string("navigation"),
        ]
        let appState = AppState()
        let approval = await appState.autoApprovalSource(
            toolName: "computer_use_click",
            arguments: semanticArguments,
            risk: AgentToolRegistry.risk(
                for: "computer_use_click",
                arguments: semanticArguments
            ),
            rootDirectory: nil,
            approvalMode: .requestEveryTime,
            conversationAllowedToolSignatures: ["computer_use:*"],
            computerUseOwner: AgentComputerUseOwner(
                runtimeID: UUID(),
                turnID: UUID(),
                sessionTitle: "Test"
            )
        )
        #expect(approval == nil)
    }

    @Test
    func controlLeaseApprovalSourceIsAuditable() {
        let appState = AppState()
        let mode = appState.sandboxModeForToolExecution(
            risk: .write,
            approvalSource: .controlLease,
            sandboxDecision: AgentSandboxDecision(
                mode: .workspaceWrite,
                requiresUserApproval: true,
                requiresTypedConfirmation: false,
                reason: "test",
                prefixRule: nil
            )
        )

        #expect(mode == .workspaceWrite)
        #expect(AgentToolApprovalSource.controlLease.rawValue == "controlLease")
        #expect(!L10n.ToolCard.approvalControlLeaseBadge.isEmpty)
        #expect(!L10n.ToolCard.approvalControlLeaseTooltip.isEmpty)
        #expect(!L10n.Transcript.turnReportApprovalControlLease.isEmpty)
    }

    @Test
    func computerUseRefusesLikelySecretsBeforeLaunchingHelper() async {
        await #expect(throws: AgentToolError.self) {
            try await AgentComputerUseTools.perform(
                action: "type_text",
                arguments: ["pid": .number(123), "text": .string("sk-example-secret")]
            )
        }
    }

    @Test
    func richerComputerUseActionsExposeFreshRefParameters() throws {
        let focus = try #require(AgentToolRegistry.descriptor(for: "computer_use_focus"))
        let hover = try #require(AgentToolRegistry.descriptor(for: "computer_use_hover"))
        let select = try #require(AgentToolRegistry.descriptor(for: "computer_use_select_text"))
        let state = try #require(AgentToolRegistry.descriptor(for: "computer_use_get_app_state"))
        let wait = try #require(AgentToolRegistry.descriptor(for: "computer_use_wait_for"))

        #expect(focus.parameters.contains { $0.name == "ref" && $0.required })
        #expect(hover.parameters.contains { $0.name == "ref" && !$0.required })
        #expect(select.parameters.contains { $0.name == "selection_type" && !$0.required })
        #expect(state.parameters.contains { $0.name == "include_screenshot" && !$0.required })
        #expect(wait.parameters.contains { $0.name == "condition" && $0.required })
        let waitSnapshot = try #require(
            wait.parameters.first { $0.name == "snapshot_id" }
        )
        #expect(!waitSnapshot.required)
        #expect(waitSnapshot.description.contains("Required whenever condition is ref_exists or value_contains"))
        let waitRef = try #require(
            wait.parameters.first { $0.name == "ref" }
        )
        #expect(waitRef.description.contains("prefix must match snapshot_id"))
        #expect(wait.description.contains("title_contains does not require either one"))
    }

    @Test
    func computerUseSelectTextRefusesLikelySecretsBeforeLaunchingHelper() async {
        await #expect(throws: AgentToolError.self) {
            try await AgentComputerUseTools.perform(
                action: "select_text",
                arguments: ["ref": .string("snapshot:e1"), "text": .string("123456")]
            )
        }
    }
}
