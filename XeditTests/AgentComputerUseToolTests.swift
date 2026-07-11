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
    func computerUseToolRiskBoundariesAreExplicit() throws {
        let permissions = try #require(AgentToolRegistry.descriptor(for: "computer_use_permissions"))
        let apps = try #require(AgentToolRegistry.descriptor(for: "computer_use_list_apps"))
        #expect(permissions.risk == .read)
        #expect(apps.risk == .read)
        for name in [
            "computer_use_request_permissions", "computer_use_launch_app", "computer_use_get_app_state",
            "computer_use_click", "computer_use_secondary_action", "computer_use_scroll", "computer_use_drag",
            "computer_use_type_text", "computer_use_press_key", "computer_use_set_value", "computer_use_restart_helper"
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
    func computerUseRefusesLikelySecretsBeforeLaunchingHelper() async {
        await #expect(throws: AgentToolError.self) {
            try await AgentComputerUseTools.perform(
                action: "type_text",
                arguments: ["pid": .number(123), "text": .string("sk-example-secret")]
            )
        }
    }
}
