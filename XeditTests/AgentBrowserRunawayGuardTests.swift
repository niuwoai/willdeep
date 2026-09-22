//
//  AgentBrowserRunawayGuardTests.swift
//  XeditTests
//
//  Guards against the runaway pattern seen on 2026-09-04 (225 web_fetch
//  guesses) and 2026-09-22 (Baidu: browser → curl → OCR → proxies): failure
//  notes flip to "stop and report", block pages are flagged, browser
//  guidance rides with the pack and states real capabilities, browsing does
//  not trigger plan requests, and audits record what a browser call did.
//

import Foundation
import Testing
import WebKit
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentBrowserRunawayGuardTests {
    @Test("失败提示：前几次鼓励换方法，同一工具 3 次或本回合 8 次后改为停下汇报")
    func failureNoteCircuitBreaker() {
        let early = AgentToolFailureGuidance.note(toolName: "web_fetch", toolFailures: 1, turnFailures: 1)
        #expect(early == AgentToolFailureGuidance.recoverNote)
        #expect(early.contains("Do not stop here"))

        let sameTool = AgentToolFailureGuidance.note(toolName: "web_fetch", toolFailures: 3, turnFailures: 3)
        #expect(!sameTool.contains("Do not stop here"))
        #expect(sameTool.contains("Stop retrying"))
        #expect(sameTool.contains("web_fetch has failed 3 time(s)"))

        let spread = AgentToolFailureGuidance.note(toolName: "run_command", toolFailures: 1, turnFailures: 8)
        #expect(spread.contains("Stop retrying"))
        #expect(spread.contains("spoofed user agents"))
    }

    @Test("熔断计数按回合累计，回合开始时清零")
    func failureCountsAccumulatePerTurn() throws {
        let appState = AppState()
        let session = appState.startNewAgentSession()
        defer { AgentSessionStore.delete(id: session.id) }
        let runtime = try #require(appState.agentRuntimes[session.id])
        #expect(appState.recordToolFailureGuidance(runtime: runtime, toolName: "web_fetch") == AgentToolFailureGuidance.recoverNote)
        _ = appState.recordToolFailureGuidance(runtime: runtime, toolName: "web_fetch")
        let third = appState.recordToolFailureGuidance(runtime: runtime, toolName: "web_fetch")
        #expect(third.contains("Stop retrying"))
        #expect(runtime.currentTurnToolFailureCounts["web_fetch"] == 3)
    }

    @Test(
        "拦截页识别",
        arguments: [
            ("百度安全验证", "https://wappass.baidu.com/static/captcha/tuxing.html", "", nil as Int?, true),
            ("百度安全验证", "https://www.baidu.com/s?wd=x", "请完成下方验证", nil, true),
            ("", "https://wappass.baidu.com/static/captcha", "", nil, true),
            ("Just a moment...", "https://example.org/", "Checking your browser before accessing", nil, true),
            ("Example", "https://example.org/", "Too many requests", 429, true),
            ("Forbidden", "https://example.org/", "", 403, true),
            ("杭州一日游_百度搜索", "https://www.baidu.com/s?wd=%E6%9D%AD", String(repeating: "西湖 灵隐寺 ", count: 400), 200, false),
            ("How CAPTCHAs work", "https://blog.example.org/post", String(repeating: "A captcha is a challenge. ", count: 200), 200, false),
            ("Example Domain", "https://example.com/", "This domain is for use in examples.", 200, false),
        ]
    )
    func blockedPageDetection(title: String, url: String, text: String, status: Int?, blocked: Bool) {
        let reason = AgentBlockedPageDetector.reason(title: title, url: url, text: text, httpStatus: status)
        #expect((reason != nil) == blocked, "title=\(title) url=\(url) reason=\(reason ?? "nil")")
    }

    @Test("read_page 读到拦截页时标 blocked_by_site 并给出停下汇报的提示")
    func readPageFlagsBlockPage() async throws {
        let runtimeID = UUID()
        defer { AgentEmbeddedBrowserController.release(for: runtimeID) }
        let controller = AgentEmbeddedBrowserController.controller(for: runtimeID)
        controller.ensureWebView(loadInitialPage: false).loadHTMLString(
            "<html><head><title>百度安全验证</title></head><body><p>请完成下方验证后继续操作</p></body></html>",
            baseURL: nil
        )
        #expect(await controller.waitForNavigationToSettle())
        let page = try await controller.readPage(maxChars: 2_000)
        #expect(page["blocked_by_site"] as? Bool == true)
        #expect((page["note"] as? String)?.contains("Stop here") == true)
        #expect(await controller.blockedPageReason() != nil)
    }

    @Test("普通页面不标 blocked_by_site")
    func readPageLeavesNormalPagesAlone() async throws {
        let runtimeID = UUID()
        defer { AgentEmbeddedBrowserController.release(for: runtimeID) }
        let controller = AgentEmbeddedBrowserController.controller(for: runtimeID)
        controller.ensureWebView(loadInitialPage: false).loadHTMLString(
            "<html><head><title>杭州一日游攻略</title></head><body><p>西湖、灵隐寺、河坊街。</p></body></html>",
            baseURL: nil
        )
        #expect(await controller.waitForNavigationToSettle())
        let page = try await controller.readPage(maxChars: 2_000)
        #expect(page["blocked_by_site"] == nil)
        #expect(await controller.blockedPageReason() == nil)
    }

    @Test("加载 browser_web 工具包即附带浏览器指引，不必再激活专家")
    func browserGuidanceRidesWithPack() {
        #expect(AgentPromptCapabilities(activeExperts: [], computerUseGranted: false, browserPackLoaded: true).browserUI)
        #expect(!AgentPromptCapabilities(activeExperts: [], computerUseGranted: false).browserUI)
        #expect(AgentPromptCapabilities(activeExperts: [.browserOps], computerUseGranted: false).browserUI)
        for descriptor in AgentToolRegistry.all where descriptor.name.hasPrefix("embedded_browser_") || descriptor.name.hasPrefix("chrome_") {
            #expect(!descriptor.description.contains("Browser Ops expert"), "\(descriptor.name) still demands the expert")
        }
    }

    @Test("浏览器指引写明拦截即停、工具怎么选，内置浏览器能力如实列出（有按键/滚动/上传，没有 hover）")
    func browserGuidanceIsAccurate() {
        let block = AgentContextBuilder.browserUICapabilityBlock
        #expect(block.contains("blocked_by_site"))
        #expect(block.contains("Never get around it"))
        #expect(block.contains("web_fetch for a public URL"))
        let embeddedLine = block.split(separator: "\n").first { $0.contains("embedded_browser_* navigates") }
        #expect(embeddedLine != nil)
        #expect(embeddedLine.map { !$0.contains("hover") } == true)
        #expect(embeddedLine.map { $0.contains("presses keys") && $0.contains("scrolls") && $0.contains("uploads workspace files") } == true)
    }

    @Test("读页面先用 read_page / snapshot；eval 每次都要确认，要一次取全")
    func browserGuidanceSteersReadsAwayFromEval() {
        let block = AgentContextBuilder.browserUICapabilityBlock
        let readLine = block.split(separator: "\n").first { $0.contains("To read a page") }
        #expect(readLine.map { $0.contains("embedded_browser_read_page") && $0.contains("embedded_browser_snapshot") } == true)
        #expect(readLine.map { $0.contains("asks the user every single time") && $0.contains("in one script") } == true)
        let eval = AgentToolRegistry.all.first { $0.name == "embedded_browser_eval" }
        #expect(eval?.description.contains("gather everything you need in one script") == true)
    }

    @Test("逐次确认的浏览器工具在授权卡上说明为什么没有一直允许，其他工具不带说明")
    func perCallBrowserToolsExplainMissingAlwaysAllow() {
        for toolName in AgentToolAuthorization.browserToolsRequiringPerCallApproval {
            let descriptor = AgentCompactAuthorizationCopy.descriptor(toolName: toolName, arguments: [:])
            #expect(descriptor?.note == L10n.ToolCard.browserPerCallAuthorizationNote, "\(toolName)")
        }
        for toolName in ["embedded_browser_navigate", "embedded_browser_click", "chrome_click"] {
            #expect(AgentCompactAuthorizationCopy.descriptor(toolName: toolName, arguments: [:])?.note == nil, "\(toolName)")
        }
    }

    @Test("浏览类调用不计入触发计划的写操作")
    func browsingDoesNotCountAsExecution() {
        #expect(!AgentPlanOnDemandPolicy.countsAsExecutionWrite(toolName: "embedded_browser_navigate", risk: .write))
        #expect(!AgentPlanOnDemandPolicy.countsAsExecutionWrite(toolName: "chrome_click", risk: .write))
        #expect(!AgentPlanOnDemandPolicy.countsAsExecutionWrite(toolName: "read_file", risk: .read))
        #expect(AgentPlanOnDemandPolicy.countsAsExecutionWrite(toolName: "edit_file", risk: .write))
        #expect(AgentPlanOnDemandPolicy.countsAsExecutionWrite(toolName: "run_command", risk: .write))
    }

    @Test("审计摘要记录 URL、选择器和脚本指纹，但不记录输入的文字")
    func browserAuditSummary() {
        #expect(
            AgentSandboxAuditLog.browserSummary(
                toolName: "embedded_browser_navigate",
                arguments: ["url": .string("https://www.baidu.com/s?wd=x")]
            ) == "embedded_browser_navigate url=https://www.baidu.com/s?wd=x"
        )
        let typed = AgentSandboxAuditLog.browserSummary(
            toolName: "embedded_browser_type",
            arguments: ["selector": .string("#pw"), "text": .string("hunter2")]
        )
        #expect(typed.contains("selector=#pw"))
        #expect(typed.contains("text_chars=7"))
        #expect(!typed.contains("hunter2"))
        let eval = AgentSandboxAuditLog.browserSummary(
            toolName: "embedded_browser_eval",
            arguments: ["javascript": .string("return document.title")]
        )
        #expect(eval.contains("js_chars=21"))
        #expect(eval.contains("js_sha256="))
        #expect(eval.contains("js=return document.title"))
    }

    @Test("每个浏览器工具都有中文显示名")
    func browserToolsHaveDisplayNames() {
        for descriptor in AgentToolRegistry.all where descriptor.name.hasPrefix("embedded_browser_") || descriptor.name.hasPrefix("chrome_") {
            #expect(AgentToolDisplay.name(for: descriptor.name) != descriptor.name, "\(descriptor.name) has no display name")
        }
    }
}
