//
//  AgentComputerUsePolicyTests.swift
//  XeditTests
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentComputerUsePolicyTests {
    @Test
    func consequentialComputerUseActionsAlwaysRequireFreshConfirmation() {
        for consequence in [
            "send",
            "delete",
            "purchase",
            "legal_agreement",
            "permission_change",
            "account_change",
            "sensitive_data_transfer",
        ] {
            let arguments: [String: AgentJSONValue] = [
                "purpose": .string("Complete the requested action"),
                "target_label": .string("Continue"),
                "consequence": .string(consequence),
            ]
            #expect(
                AgentToolRegistry.risk(
                    for: "computer_use_click",
                    arguments: arguments
                ) == .danger,
                "\(consequence) must bypass session-wide approval"
            )
            #expect(
                AgentSandboxPolicy.decision(
                    toolName: "computer_use_click",
                    arguments: arguments,
                    rootDirectory: nil
                ).requiresTypedConfirmation
            )
        }
    }

    @Test
    func harmlessClassifiedClickRemainsWriteTier() {
        let arguments: [String: AgentJSONValue] = [
            "ref": .string("snapshot:e1"),
            "snapshot_id": .string("snapshot"),
            "purpose": .string("Open the requested settings tab"),
            "target_label": .string("General"),
            "consequence": .string("navigation"),
        ]
        #expect(
            AgentToolRegistry.risk(
                for: "computer_use_click",
                arguments: arguments
            ) == .write
        )
    }

    @Test
    func ordinaryActionsRemainWriteTierForOperationalLeaseApproval() {
        let cases: [(String, [String: AgentJSONValue])] = [
            (
                "computer_use_type_text",
                [
                    "pid": .number(123),
                    "snapshot_id": .string("snapshot"),
                    "text": .string("Hello"),
                    "purpose": .string("Enter a non-sensitive draft"),
                    "target_label": .string("Draft"),
                    "consequence": .string("none"),
                ]
            ),
            (
                "computer_use_press_key",
                [
                    "pid": .number(123),
                    "snapshot_id": .string("snapshot"),
                    "key": .string("tab"),
                    "purpose": .string("Move focus"),
                    "target_label": .string("Form"),
                    "consequence": .string("navigation"),
                ]
            ),
            (
                "computer_use_set_value",
                [
                    "ref": .string("snapshot:e1"),
                    "snapshot_id": .string("snapshot"),
                    "value": .string("Draft"),
                    "purpose": .string("Set a non-sensitive draft value"),
                    "target_label": .string("Draft"),
                    "consequence": .string("none"),
                ]
            ),
            (
                "computer_use_select_text",
                [
                    "ref": .string("snapshot:e1"),
                    "snapshot_id": .string("snapshot"),
                    "text": .string("Draft"),
                    "purpose": .string("Select non-sensitive draft text"),
                    "target_label": .string("Draft"),
                    "consequence": .string("none"),
                ]
            ),
            (
                "computer_use_click",
                [
                    "snapshot_id": .string("snapshot"),
                    "ref": .string("snapshot:e2"),
                    "purpose": .string("Open the requested tab"),
                    "target_label": .string("General"),
                    "consequence": .string("navigation"),
                ]
            ),
            (
                "computer_use_secondary_action",
                [
                    "snapshot_id": .string("snapshot"),
                    "ref": .string("snapshot:e3"),
                    "purpose": .string("Open the requested context menu"),
                    "target_label": .string("Document"),
                    "consequence": .string("none"),
                ]
            ),
        ]

        for (toolName, arguments) in cases {
            #expect(
                AgentToolRegistry.risk(
                    for: toolName,
                    arguments: arguments
                ) == .write,
                "\(toolName) should be eligible for an operational lease"
            )
            let decision = AgentSandboxPolicy.decision(
                toolName: toolName,
                arguments: arguments,
                rootDirectory: nil
            )
            #expect(!decision.requiresTypedConfirmation)
        }
    }

    @Test
    @MainActor
    func coordinateMutationsAlwaysRequirePerActionTypedConfirmation() {
        let owner = AgentComputerUseOwner(
            runtimeID: UUID(),
            turnID: UUID(),
            sessionTitle: "Coordinate fallback"
        )
        let lease = AgentComputerUseLease(
            owner: owner,
            target: AgentComputerUseTarget(
                pid: 123,
                applicationName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                windowTitle: "Draft"
            ),
            operation: .controlling
        )
        let cases: [(String, [String: AgentJSONValue])] = [
            (
                "computer_use_click",
                [
                    "pid": .number(123),
                    "snapshot_id": .string("snapshot"),
                    "x": .number(20),
                    "y": .number(40),
                    "purpose": .string("Open the requested tab"),
                    "target_label": .string("General"),
                    "consequence": .string("navigation"),
                ]
            ),
            (
                "computer_use_secondary_action",
                [
                    "pid": .number(123),
                    "snapshot_id": .string("snapshot"),
                    "x": .number(20),
                    "y": .number(40),
                    "purpose": .string("Open the requested context menu"),
                    "target_label": .string("Document"),
                    "consequence": .string("none"),
                ]
            ),
            (
                "computer_use_drag",
                [
                    "pid": .number(123),
                    "snapshot_id": .string("snapshot"),
                    "from_x": .number(20),
                    "from_y": .number(40),
                    "to_x": .number(100),
                    "to_y": .number(120),
                    "purpose": .string("Move the requested item"),
                    "target_label": .string("Document"),
                    "consequence": .string("none"),
                ]
            ),
        ]

        for (toolName, arguments) in cases {
            #expect(
                AgentToolRegistry.risk(
                    for: toolName,
                    arguments: arguments
                ) == .danger
            )
            #expect(
                AgentSandboxPolicy.decision(
                    toolName: toolName,
                    arguments: arguments,
                    rootDirectory: nil
                ).requiresTypedConfirmation
            )
            #expect(
                !AgentComputerUsePolicy.canAutoApproveInOperationalLease(
                    toolName: toolName,
                    arguments: arguments,
                    owner: owner,
                    controlState: .controlling(lease)
                )
            )
        }
    }

    @Test
    func onlyNavigationKeyAllowlistAvoidsTypedConfirmation() {
        for key in [
            "tab", "shift+tab", "left", "arrow_right", "up", "down",
            "escape", "esc", "home", "end", "page-up", "page_down",
        ] {
            #expect(AgentComputerUsePolicy.isLeaseSafeNavigationKey(key))
        }

        for key in [
            "return", "enter", "delete", "backspace", "space",
            "cmd+s", "shift+left", "option+tab", "f5", "unknown",
        ] {
            let arguments: [String: AgentJSONValue] = [
                "pid": .number(123),
                "snapshot_id": .string("snapshot"),
                "key": .string(key),
                "purpose": .string("Use the requested key"),
                "target_label": .string("Editor"),
                "consequence": .string("none"),
            ]
            #expect(!AgentComputerUsePolicy.isLeaseSafeNavigationKey(key))
            #expect(
                AgentToolRegistry.risk(
                    for: "computer_use_press_key",
                    arguments: arguments
                ) == .danger
            )
            #expect(
                AgentSandboxPolicy.decision(
                    toolName: "computer_use_press_key",
                    arguments: arguments,
                    rootDirectory: nil
                ).requiresTypedConfirmation
            )
        }
    }

    @Test
    func operationalLeaseAutoApprovesOnlyMatchingOrdinaryActions() {
        let runtimeID = UUID()
        let owner = AgentComputerUseOwner(
            runtimeID: runtimeID,
            turnID: UUID(),
            sessionTitle: "Edit draft"
        )
        let lease = AgentComputerUseLease(
            owner: owner,
            target: AgentComputerUseTarget(
                pid: 123,
                applicationName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                windowTitle: "Draft"
            ),
            operation: .controlling
        )
        let state = AgentComputerUseControlState.controlling(lease)
        let cases: [(String, [String: AgentJSONValue])] = [
            (
                "computer_use_type_text",
                [
                    "pid": .number(123),
                    "snapshot_id": .string("snapshot"),
                    "text": .string("Hello"),
                    "purpose": .string("Enter a non-sensitive draft"),
                    "target_label": .string("Draft"),
                    "consequence": .string("none"),
                ]
            ),
            (
                "computer_use_set_value",
                [
                    "snapshot_id": .string("snapshot"),
                    "ref": .string("snapshot:e1"),
                    "value": .string("Hello"),
                    "purpose": .string("Update the draft"),
                    "target_label": .string("Draft"),
                    "consequence": .string("none"),
                ]
            ),
            (
                "computer_use_select_text",
                [
                    "snapshot_id": .string("snapshot"),
                    "ref": .string("snapshot:e1"),
                    "text": .string("Hello"),
                    "purpose": .string("Select draft text"),
                    "target_label": .string("Draft"),
                    "consequence": .string("none"),
                ]
            ),
            (
                "computer_use_press_key",
                [
                    "pid": .number(123),
                    "snapshot_id": .string("snapshot"),
                    "key": .string("shift+tab"),
                    "purpose": .string("Move focus backward"),
                    "target_label": .string("Form"),
                    "consequence": .string("navigation"),
                ]
            ),
            (
                "computer_use_click",
                [
                    "snapshot_id": .string("snapshot"),
                    "ref": .string("snapshot:e2"),
                    "purpose": .string("Open the requested tab"),
                    "target_label": .string("General"),
                    "consequence": .string("navigation"),
                ]
            ),
            (
                "computer_use_secondary_action",
                [
                    "snapshot_id": .string("snapshot"),
                    "ref": .string("snapshot:e5"),
                    "purpose": .string("Open the context menu"),
                    "target_label": .string("Draft"),
                    "consequence": .string("none"),
                ]
            ),
            (
                "computer_use_scroll",
                [
                    "pid": .number(123),
                    "snapshot_id": .string("snapshot"),
                    "direction": .string("down"),
                    "pages": .number(2),
                ]
            ),
            (
                "computer_use_focus",
                [
                    "snapshot_id": .string("snapshot"),
                    "ref": .string("snapshot:e3"),
                ]
            ),
            (
                "computer_use_hover",
                [
                    "snapshot_id": .string("snapshot"),
                    "ref": .string("snapshot:e4"),
                ]
            ),
        ]

        for (toolName, arguments) in cases {
            #expect(
                AgentComputerUsePolicy.canAutoApproveInOperationalLease(
                    toolName: toolName,
                    arguments: arguments,
                    owner: owner,
                    controlState: state
                ),
                "\(toolName) should run inside the matching operational lease"
            )
        }

        let ordinaryType = cases[0].1
        #expect(
            AppState.canAutoApproveComputerUse(
                toolName: "computer_use_type_text",
                arguments: ordinaryType,
                interactionMode: .normal,
                approvalMode: .smart,
                owner: owner,
                controlState: state
            )
        )
        #expect(
            AppState.computerUseLeaseApprovalSource(
                toolName: "computer_use_type_text",
                arguments: ordinaryType,
                interactionMode: .normal,
                approvalMode: .smart,
                owner: owner,
                controlState: state
            ) == .controlLease
        )
        #expect(
            !AppState.canAutoApproveComputerUse(
                toolName: "computer_use_type_text",
                arguments: ordinaryType,
                interactionMode: .normal,
                approvalMode: .requestEveryTime,
                owner: owner,
                controlState: state
            )
        )
        #expect(
            AppState.canAutoApproveComputerUse(
                toolName: "computer_use_type_text",
                arguments: ordinaryType,
                interactionMode: .goal,
                approvalMode: .smart,
                owner: owner,
                controlState: state
            )
        )
        #expect(
            !AgentComputerUsePolicy.canAutoApproveInOperationalLease(
                toolName: "computer_use_type_text",
                arguments: ordinaryType,
                owner: AgentComputerUseOwner(
                    runtimeID: UUID(),
                    turnID: owner.turnID,
                    sessionTitle: owner.sessionTitle
                ),
                controlState: state
            )
        )
        #expect(
            !AgentComputerUsePolicy.canAutoApproveInOperationalLease(
                toolName: "computer_use_type_text",
                arguments: ordinaryType,
                owner: AgentComputerUseOwner(
                    runtimeID: owner.runtimeID,
                    turnID: UUID(),
                    sessionTitle: owner.sessionTitle
                ),
                controlState: state
            )
        )
        #expect(
            !AgentComputerUsePolicy.canAutoApproveInOperationalLease(
                toolName: "computer_use_type_text",
                arguments: ordinaryType.merging([
                    "app": .string("com.apple.Safari"),
                ]) { _, new in new },
                owner: owner,
                controlState: state
            )
        )
        #expect(
            !AgentComputerUsePolicy.canAutoApproveInOperationalLease(
                toolName: "computer_use_type_text",
                arguments: ordinaryType.merging([
                    "pid": .number(999),
                ]) { _, new in new },
                owner: owner,
                controlState: state
            )
        )
        #expect(
            !AgentComputerUsePolicy.canAutoApproveInOperationalLease(
                toolName: "computer_use_type_text",
                arguments: ordinaryType,
                owner: owner,
                controlState: .paused(lease)
            )
        )
        #expect(
            !AgentComputerUsePolicy.canAutoApproveInOperationalLease(
                toolName: "computer_use_type_text",
                arguments: ordinaryType,
                owner: owner,
                controlState: .observing(lease)
            )
        )
        #expect(
            !AgentComputerUsePolicy.canAutoApproveInOperationalLease(
                toolName: "computer_use_click",
                arguments: [
                    "snapshot_id": .string("stale"),
                    "ref": .string("snapshot:e2"),
                    "purpose": .string("Open tab"),
                    "target_label": .string("General"),
                    "consequence": .string("navigation"),
                ],
                owner: owner,
                controlState: state
            )
        )
    }

    @Test
    func sensitiveOrControlCharacterTextNeverAutoApproves() {
        #expect(AgentComputerUsePolicy.containsControlCharacters("line 1\nline 2"))
        #expect(!AgentComputerUsePolicy.containsControlCharacters("plain text"))

        for text in ["OTP: 123456", "line 1\nline 2"] {
            let arguments: [String: AgentJSONValue] = [
                "pid": .number(123),
                "snapshot_id": .string("snapshot"),
                "text": .string(text),
                "purpose": .string("Enter text"),
                "target_label": .string("Draft"),
                "consequence": .string("none"),
            ]
            #expect(
                AgentToolRegistry.risk(
                    for: "computer_use_type_text",
                    arguments: arguments
                ) == .danger
            )
        }
    }

    @Test
    func missingOrDishonestClassificationFailsClosed() {
        let missing: [String: AgentJSONValue] = [
            "purpose": .string("Click a button"),
            "target_label": .string("Continue"),
        ]
        #expect(
            AgentToolRegistry.risk(
                for: "computer_use_click",
                arguments: missing
            ) == .danger
        )

        let dishonest: [String: AgentJSONValue] = [
            "purpose": .string("Delete the account permanently"),
            "target_label": .string("Delete account"),
            "consequence": .string("none"),
        ]
        #expect(
            AgentToolRegistry.risk(
                for: "computer_use_click",
                arguments: dishonest
            ) == .danger
        )

        let disguisedAuthentication: [String: AgentJSONValue] = [
            "purpose": .string("Log in to the requested account"),
            "target_label": .string("Sign in"),
            "consequence": .string("none"),
        ]
        #expect(
            AgentComputerUsePolicy.requiresUserTakeover(
                disguisedAuthentication
            )
        )
        #expect(throws: AgentToolError.self) {
            try AgentComputerUsePolicy.validateBeforeHelper(
                action: "click",
                arguments: disguisedAuthentication
            )
        }
    }

    @Test
    func privateActionsRequireTakeoverBeforeHelper() async {
        for consequence in [
            "authentication",
            "captcha",
            "credential_entry",
            "financial_transaction",
        ] {
            let arguments: [String: AgentJSONValue] = [
                "pid": .number(123),
                "snapshot_id": .string("snapshot"),
                "target_label": .string("Sensitive control"),
                "purpose": .string("Complete a private step"),
                "consequence": .string(consequence),
            ]
            await #expect(throws: AgentToolError.self) {
                try await AgentComputerUseTools.perform(
                    action: "click",
                    arguments: arguments
                )
            }
        }
    }

    @Test
    func sensitiveTextDetectionCoversCommonCredentialShapes() {
        for value in [
            "OTP: 123456",
            "验证码：12 34 56",
            "password: correct horse battery staple",
            "-----BEGIN PRIVATE KEY-----",
            "4111 1111 1111 1111",
            "11010519491231002X",
        ] {
            #expect(
                AgentComputerUsePolicy.likelySensitiveText(value),
                "\(value) should require private takeover"
            )
        }
        #expect(!AgentComputerUsePolicy.likelySensitiveText("Draft release notes"))
    }

    @Test
    func clipboardPasteIsRejectedBeforeHelper() throws {
        for shortcut in ["cmd+c", "command-x", "⌘V", "cmd+shift+c"] {
            let arguments: [String: AgentJSONValue] = [
                "key": .string(shortcut),
                "purpose": .string("Use a keyboard shortcut"),
                "target_label": .string("Editor"),
                "consequence": .string("none"),
            ]
            #expect(throws: AgentToolError.self) {
                try AgentComputerUsePolicy.validateBeforeHelper(
                    action: "press_key",
                    arguments: arguments
                )
            }
        }

        for menuLabel in ["Copy", "Cut", "Paste", "复制", "剪切", "粘贴"] {
            let menuAction: [String: AgentJSONValue] = [
                "ref": .string("snapshot:e1"),
                "target_label": .string(menuLabel),
                "purpose": .string("Use the context menu"),
                "consequence": .string("none"),
            ]
            #expect(throws: AgentToolError.self) {
                try AgentComputerUsePolicy.validateBeforeHelper(
                    action: "click",
                    arguments: menuAction
                )
            }
        }

        try AgentComputerUsePolicy.validateBeforeHelper(
            action: "press_key",
            arguments: [
                "key": .string("tab"),
                "purpose": .string("Use a keyboard shortcut to move focus"),
                "target_label": .string("Form"),
                "consequence": .string("navigation"),
            ]
        )
    }

    @Test
    func screenClipboardAndGUIScriptingCommandsRequireTypedEscalation() {
        let commands = [
            "screencapture /tmp/private-screen.png",
            "/usr/bin/pbpaste",
            "printf secret | /usr/bin/pbcopy",
            "osascript -e 'get the clipboard'",
            "osascript -e 'tell application \"System Events\" to keystroke \"x\"'",
            "swift -e 'CGWindowListCreateImage(.infinite, .optionOnScreenOnly, 0, [])'",
            "ruby -e 'system(\"screencapture /tmp/wrapped.png\")'",
        ]
        let root = URL(fileURLWithPath: "/tmp/willdeep-workspace")

        for command in commands {
            let decision = AgentSandboxPolicy.commandDecision(
                command: command,
                rootDirectory: root
            )
            #expect(decision.mode == .escalated, "\(command) must leave workspace-write")
            #expect(decision.requiresUserApproval)
            #expect(decision.requiresTypedConfirmation)
            #expect(AgentSandboxPolicy.commandUsesExternalAccess(command))
            #expect(
                !AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(
                    command: command,
                    rootDirectory: root
                )
            )
            #expect(
                AgentToolRegistry.risk(
                    for: "run_command",
                    arguments: ["command": .string(command)],
                    rootDirectory: root
                ) == .danger
            )
            #expect(
                AgentToolAuthorization.suggestedPersistentSignature(
                    toolName: "run_command",
                    arguments: ["command": .string(command)]
                ) == nil
            )
        }
    }

    @Test
    func sensitiveDesktopCommandsAreAlsoDangerousInVisibleTerminal() {
        for command in [
            "pbpaste",
            "pbcopy",
            "screencapture /tmp/private-screen.png",
            "osascript -e 'tell application \"System Events\" to click menu item 1'",
        ] {
            let arguments: [String: AgentJSONValue] = [
                "command": .string(command),
            ]
            let decision = AgentSandboxPolicy.decision(
                toolName: "terminal_send_command",
                arguments: arguments,
                rootDirectory: nil
            )
            #expect(decision.mode == .escalated)
            #expect(decision.requiresTypedConfirmation)
            #expect(
                AgentToolRegistry.risk(
                    for: "terminal_send_command",
                    arguments: arguments
                ) == .danger
            )
            #expect(
                AgentToolAuthorization.suggestedPersistentSignature(
                    toolName: "terminal_send_command",
                    arguments: arguments
                ) == nil
            )
        }
    }

    @Test
    @MainActor
    func durableAlwaysAllowNeverAppliesToComputerUse() {
        #expect(
            AgentToolAuthorization.suggestedPersistentSignature(
                toolName: "computer_use_scroll",
                arguments: [
                    "pid": .number(123),
                    "direction": .string("down"),
                ]
            ) == nil
        )

        let appState = AppState()
        appState.agentAlwaysAllowedCommands = [
            AgentAlwaysAllowedCommand(commandSignature: "computer_use:*"),
        ]
        #expect(
            !appState.isAgentToolCallAlwaysAllowed(
                toolName: "computer_use_click",
                arguments: [
                    "purpose": .string("Open tab"),
                    "target_label": .string("General"),
                    "consequence": .string("navigation"),
                ],
                risk: .write
            )
        )
    }

    @Test
    func computerUseNeverMintsConversationScopedGrant() {
        for toolName in [
            "computer_use_permissions",
            "computer_use_request_permissions",
            "computer_use_list_apps",
            "computer_use_get_app_state",
            "computer_use_inspect_app",
            "computer_use_wait_for",
            "computer_use_type_text",
            "computer_use_press_key",
            "computer_use_set_value",
            "computer_use_select_text",
            "computer_use_drag",
            "computer_use_restart_helper",
            "computer_use_scroll",
            "computer_use_click",
            "computer_use_hover",
        ] {
            #expect(
                AgentToolAuthorization.interactiveSurfaceSignature(
                    toolName: toolName
                ) == nil
            )
        }
    }

    @Test
    func computerUseCoordinateSchemaIsScreenshotRelativeOnly() throws {
        for toolName in [
            "computer_use_click",
            "computer_use_secondary_action",
            "computer_use_drag",
            "computer_use_hover",
        ] {
            let descriptor = try #require(AgentToolRegistry.descriptor(for: toolName))
            #expect(!descriptor.parameters.contains { $0.name == "coordinate_space" })
            #expect(!descriptor.description.contains("screen-space"))
        }
    }
}
