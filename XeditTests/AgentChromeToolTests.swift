//
//  AgentChromeToolTests.swift
//  XeditTests
//

import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentChromeToolTests {
    @Test
    func chromeNavigationAndSnapshotToolsExposeExpectedRisks() throws {
        for name in ["chrome_status", "chrome_read_page", "chrome_read_selection", "chrome_snapshot", "chrome_list_tabs", "chrome_wait_for", "chrome_capture_tab"] {
            #expect(try #require(AgentToolRegistry.descriptor(for: name)).risk == .read)
        }
        for name in ["chrome_activate_tab", "chrome_navigate", "chrome_history", "chrome_click", "chrome_type", "chrome_hover", "chrome_select_option", "chrome_press_key", "chrome_scroll"] {
            #expect(try #require(AgentToolRegistry.descriptor(for: name)).risk == .write)
        }
        #expect(try #require(AgentToolRegistry.descriptor(for: "chrome_debugger_command")).risk == .danger)
    }

    @Test
    func browserAuthorizationSeparatesChromeAndEmbeddedConversationGrants() async {
        #expect(
            AgentToolAuthorization.interactiveSurfaceSignature(
                toolName: "chrome_click"
            ) == "browser:chrome"
        )
        #expect(
            AgentToolAuthorization.interactiveSurfaceSignature(
                toolName: "embedded_browser_click"
            ) == "browser:embedded"
        )

        let appState = AppState()
        let chromeApproval = await appState.autoApprovalSource(
            toolName: "chrome_click",
            arguments: ["ref": .string("dom-1:e1")],
            risk: .write,
            rootDirectory: nil,
            approvalMode: .requestEveryTime,
            conversationAllowedToolSignatures: ["browser:chrome"]
        )
        let embeddedApproval = await appState.autoApprovalSource(
            toolName: "embedded_browser_click",
            arguments: ["selector": .string("button")],
            risk: .write,
            rootDirectory: nil,
            approvalMode: .requestEveryTime,
            conversationAllowedToolSignatures: ["browser:chrome"]
        )
        let debuggerApproval = await appState.autoApprovalSource(
            toolName: "chrome_debugger_command",
            arguments: ["method": .string("Runtime.evaluate")],
            risk: .danger,
            rootDirectory: nil,
            approvalMode: .requestEveryTime,
            conversationAllowedToolSignatures: ["browser:chrome"]
        )

        #expect(chromeApproval == .user)
        #expect(embeddedApproval == nil)
        #expect(debuggerApproval == nil)
    }

    @Test("每个 Chrome 页面/标签页工具都能用 tab_id 指定标签页，列表和切换工具除外")
    func chromePageToolsAcceptTabID() throws {
        let targeted = [
            "chrome_read_page", "chrome_read_selection", "chrome_snapshot", "chrome_navigate",
            "chrome_history", "chrome_click", "chrome_type", "chrome_hover", "chrome_select_option",
            "chrome_press_key", "chrome_scroll", "chrome_wait_for", "chrome_capture_tab",
            "chrome_debugger_command",
        ]
        for name in targeted {
            let descriptor = try #require(AgentToolRegistry.descriptor(for: name))
            let tabID = try #require(descriptor.parameters.first { $0.name == "tab_id" }, "\(name) has no tab_id")
            #expect(tabID.type == .integer)
            #expect(!tabID.required)
            #expect(!descriptor.description.contains("active Chrome tab"), "\(name) still says active tab")
        }
        #expect(try #require(AgentToolRegistry.descriptor(for: "chrome_list_tabs")).description.contains("agent_target"))
        #expect(try #require(AgentToolRegistry.descriptor(for: "chrome_activate_tab")).parameters.first { $0.name == "tab_id" }?.required == true)
    }

    @Test("tab_id 解析：整数通过，缺省为 nil，非整数报错")
    func chromeTargetTabIDParsing() throws {
        #expect(try AgentChromeTools.targetTabID(["tab_id": .number(42)]) == 42)
        #expect(try AgentChromeTools.targetTabID([:]) == nil)
        #expect(try AgentChromeTools.targetTabID(["tab_id": .null]) == nil)
        #expect(throws: AgentToolError.self) {
            _ = try AgentChromeTools.targetTabID(["tab_id": .string("current")])
        }
    }

    @Test
    func chromeSnapshotAndRefActionsExposeFreshRefContract() throws {
        let snapshot = try #require(AgentToolRegistry.descriptor(for: "chrome_snapshot"))
        let click = try #require(AgentToolRegistry.descriptor(for: "chrome_click"))
        let type = try #require(AgentToolRegistry.descriptor(for: "chrome_type"))
        let hover = try #require(AgentToolRegistry.descriptor(for: "chrome_hover"))
        let select = try #require(AgentToolRegistry.descriptor(for: "chrome_select_option"))

        #expect(snapshot.parameters.contains { $0.name == "max_elements" })
        #expect(click.parameters.contains { $0.name == "ref" && !$0.required })
        #expect(type.parameters.contains { $0.name == "ref" && !$0.required })
        #expect(type.parameters.contains { $0.name == "text" && $0.required })
        #expect(hover.parameters.contains { $0.name == "ref" && !$0.required })
        #expect(select.parameters.contains { $0.name == "label" && !$0.required })
    }

    @Test
    func chromeClickRejectsMissingOrAmbiguousTargetBeforeNetwork() async {
        await #expect(throws: AgentToolError.self) {
            try await AgentChromeTools.click(arguments: [:])
        }
        await #expect(throws: AgentToolError.self) {
            try await AgentChromeTools.click(arguments: [
                "ref": .string("dom-1:e1"),
                "selector": .string("button")
            ])
        }
    }

    @Test
    func chromeWaitRejectsUnsupportedConditionBeforeNetwork() async {
        await #expect(throws: AgentToolError.self) {
            try await AgentChromeTools.waitFor(arguments: [
                "condition": .string("cookie"),
                "value": .string("session")
            ])
        }
    }

    @Test
    func chromeSelectOptionRejectsMissingOrAmbiguousChoiceBeforeNetwork() async {
        await #expect(throws: AgentToolError.self) {
            try await AgentChromeTools.selectOption(arguments: ["ref": .string("dom-1:e1")])
        }
        await #expect(throws: AgentToolError.self) {
            try await AgentChromeTools.selectOption(arguments: [
                "ref": .string("dom-1:e1"),
                "value": .string("pro"),
                "label": .string("专业")
            ])
        }
    }
}
