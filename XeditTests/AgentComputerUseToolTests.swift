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
        let wait = try #require(AgentToolRegistry.descriptor(for: "computer_use_wait_for"))
        #expect(permissions.risk == .read)
        #expect(apps.risk == .read)
        #expect(inspect.risk == .read)
        #expect(wait.risk == .read)
        for name in [
            "computer_use_request_permissions", "computer_use_launch_app", "computer_use_activate_app", "computer_use_get_app_state",
            "computer_use_click", "computer_use_secondary_action", "computer_use_scroll", "computer_use_drag",
            "computer_use_type_text", "computer_use_press_key", "computer_use_set_value", "computer_use_focus",
            "computer_use_hover", "computer_use_select_text", "computer_use_restart_helper"
        ] {
            let descriptor = try #require(AgentToolRegistry.descriptor(for: name))
            #expect(descriptor.risk == .write, "\(name) must require approval")
        }
    }

    @Test
    func computerUseActionsCannotGoalModeAutoApprove() {
        let decision = AgentSandboxPolicy.decision(
            toolName: "computer_use_click",
            arguments: ["pid": .number(123), "x": .number(10), "y": .number(10)],
            rootDirectory: nil
        )
        #expect(decision.mode == .escalated)
        #expect(decision.requiresUserApproval)
        #expect(!decision.requiresTypedConfirmation)
    }

    @Test
    func computerUseAuthorizationUsesFamilyScopedConversationGrant() async {
        #expect(
            AgentToolAuthorization.interactiveSurfaceSignature(
                toolName: "computer_use_click"
            ) == "computer_use:*"
        )
        #expect(
            AgentToolAuthorization.signature(
                toolName: "computer_use_type_text",
                arguments: ["pid": .number(123), "text": .string("hello")]
            ) == "computer_use:*"
        )

        let appState = AppState()
        let approval = await appState.autoApprovalSource(
            toolName: "computer_use_click",
            arguments: ["pid": .number(123), "x": .number(10), "y": .number(10)],
            risk: .write,
            rootDirectory: nil,
            approvalMode: .requestEveryTime,
            conversationAllowedToolSignatures: ["computer_use:*"]
        )
        #expect(approval == .user)
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
