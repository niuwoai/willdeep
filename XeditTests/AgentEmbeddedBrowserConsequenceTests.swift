//
//  AgentEmbeddedBrowserConsequenceTests.swift
//  XeditTests
//
//  A click that sends, deletes, pays or signs in is confirmed even on a site
//  the user allowed; ordinary clicks ride on the site rule. The host reads
//  the target's label itself.
//

import AppKit
import Foundation
import Testing
import WebKit
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentEmbeddedBrowserConsequenceTests {
    private let hostKey = AgentToolAuthorization.embeddedBrowserPageHostArgument
    private let labelKey = AgentToolAuthorization.embeddedBrowserTargetLabelArgument

    private func click(_ label: String, host: String = "www.example.com") -> [String: AgentJSONValue] {
        ["selector": .string("#b"), hostKey: .string(host), labelKey: .string(label)]
    }

    @Test("按钮文字判定：发送 / 删除 / 付款 / 登录算有后果，搜索 / 下一页不算；只看点击和激活键")
    func consequenceFromLabels() {
        for label in ["发送", "Send", "删除", "Delete account", "立即付款", "Buy now", "登录", "发布", "授权"] {
            #expect(AgentToolAuthorization.embeddedBrowserActionConsequence(
                toolName: "embedded_browser_click", arguments: click(label)
            ) != nil, "\(label)")
        }
        for label in ["百度一下", "搜索", "下一页", "展开全文", "", "Search"] {
            #expect(AgentToolAuthorization.embeddedBrowserActionConsequence(
                toolName: "embedded_browser_click", arguments: click(label)
            ) == nil, "\(label)")
        }
        var enter = click("发送")
        enter["key"] = .string("Enter")
        #expect(AgentToolAuthorization.embeddedBrowserActionConsequence(toolName: "embedded_browser_press_key", arguments: enter) != nil)
        enter["key"] = .string("a")
        #expect(AgentToolAuthorization.embeddedBrowserActionConsequence(toolName: "embedded_browser_press_key", arguments: enter) == nil)
        #expect(AgentToolAuthorization.embeddedBrowserActionConsequence(toolName: "embedded_browser_scroll", arguments: click("删除")) == nil)
        // Computer Use keeps using the same keyword groups.
        #expect(AgentComputerUsePolicy.consequence(describedBy: "点击 发送") == .send)
    }

    @Test("有后果的点击：网站规则和本会话允许都不放行，也不提供始终允许；Goal 模式照常自主")
    func consequentialClickIsAlwaysConfirmed() async {
        let appState = AppState()
        appState.agentAlwaysAllowedCommands = [
            AgentAlwaysAllowedCommand(commandSignature: "browser:embedded:site:www.example.com"),
        ]
        #expect(appState.isAgentToolCallAlwaysAllowed(toolName: "embedded_browser_click", arguments: click("下一页"), risk: .write))
        #expect(!appState.isAgentToolCallAlwaysAllowed(toolName: "embedded_browser_click", arguments: click("发送"), risk: .write))
        #expect(AgentToolAuthorization.suggestedPersistentSignature(toolName: "embedded_browser_click", arguments: click("发送")) == nil)
        #expect(AgentToolAuthorization.suggestedPersistentSignature(toolName: "embedded_browser_click", arguments: click("下一页"))
            == "browser:embedded:site:www.example.com")

        let conversation = await appState.autoApprovalSource(
            toolName: "embedded_browser_click", arguments: click("删除"), risk: .write, rootDirectory: nil,
            conversationAllowedToolSignatures: ["browser:embedded"]
        )
        #expect(conversation == nil)
        let ordinary = await appState.autoApprovalSource(
            toolName: "embedded_browser_click", arguments: click("下一页"), risk: .write, rootDirectory: nil,
            conversationAllowedToolSignatures: ["browser:embedded"]
        )
        #expect(ordinary == .user)
        let goal = await appState.autoApprovalSource(
            toolName: "embedded_browser_click", arguments: click("删除"), risk: .write, rootDirectory: nil,
            interactionMode: .goal
        )
        #expect(goal == .goalMode)
    }

    @Test("卡片写明为什么要确认；普通点击不带说明")
    func cardExplainsConsequentialClick() {
        let note = AgentCompactAuthorizationCopy.descriptor(toolName: "embedded_browser_click", arguments: click("发送"))?.note
        #expect(note == L10n.ToolCard.browserConsequentialActionNote("发送"))
        #expect(note?.contains("发送") == true)
        #expect(AgentCompactAuthorizationCopy.descriptor(toolName: "embedded_browser_click", arguments: click("下一页"))?.note == nil)
    }

    @Test("宿主读出目标控件的文字：按钮里的图标、链接、表单输入框按 Enter 取提交按钮")
    func hostReadsTargetLabel() async throws {
        let runtimeID = UUID()
        defer { AgentEmbeddedBrowserController.release(for: runtimeID) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-browser-consequence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = directory.appendingPathComponent("page.html")
        try #"""
        <meta charset="utf-8"><html><body>
        <button id="send"><span id="icon">✉</span> 发送消息</button>
        <a id="next" href="#p2">下一页</a>
        <form><input id="comment" name="c"><button>发布评论</button></form>
        </body></html>
        """#.write(to: page, atomically: true, encoding: .utf8)
        let controller = AgentEmbeddedBrowserController.controller(for: runtimeID)
        try controller.navigate(to: page.absoluteString)
        // First load of a suite: see AgentEmbeddedBrowserInputTests.
        #expect(await controller.waitForNavigationToSettle(timeout: .seconds(60)))

        #expect(await controller.targetLabel(selector: "#icon") == "✉ 发送消息")
        #expect(await controller.targetLabel(selector: "#next") == "下一页")
        #expect(await controller.targetLabel(selector: "#comment") == "发布评论")
        #expect(await controller.targetLabel(selector: "#missing") == "")

        let stamped = await AgentEmbeddedBrowserController.stampingTargetLabel(
            toolName: "embedded_browser_click",
            arguments: ["selector": .string("#icon"), labelKey: .string("下一页")],
            runtimeID: runtimeID
        )
        #expect(stamped[labelKey]?.stringValue() == "✉ 发送消息", "the host's reading overrides the model's")
        let scroll = await AgentEmbeddedBrowserController.stampingTargetLabel(
            toolName: "embedded_browser_scroll", arguments: [:], runtimeID: runtimeID
        )
        #expect(scroll[labelKey] == nil)
    }
}
