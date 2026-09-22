//
//  AgentBrowserSecurityTests.swift
//  XeditTests
//
//  Browser-use security boundaries: durable approvals are one tool (and one
//  host for navigation) wide, eval / raw CDP always ask, Agent navigation is
//  limited to web + workspace files, secrets never come back through page
//  reads, and page text reaches the model inside an untrusted envelope.
//

import Foundation
import Testing
import WebKit
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentBrowserSecurityTests {
    // MARK: - Durable approval scope

    @Test("内置浏览器的持久规则按网站：navigate 取目标域名，其余工具取发起时页面的域名；Chrome 仍按工具")
    func persistentSignaturesAreSiteScoped() {
        let host = AgentToolAuthorization.embeddedBrowserPageHostArgument
        #expect(
            AgentToolAuthorization.suggestedPersistentSignature(
                toolName: "embedded_browser_navigate",
                arguments: ["url": .string("https://www.baidu.com/s?wd=x")]
            ) == "browser:embedded:site:www.baidu.com"
        )
        #expect(
            AgentToolAuthorization.suggestedPersistentSignature(
                toolName: "embedded_browser_navigate",
                arguments: ["url": .string("Example.COM/path")]
            ) == "browser:embedded:site:example.com"
        )
        for toolName in ["embedded_browser_click", "embedded_browser_type", "embedded_browser_eval"] {
            #expect(
                AgentToolAuthorization.suggestedPersistentSignature(
                    toolName: toolName,
                    arguments: ["selector": .string("button"), host: .string("www.baidu.com")]
                ) == "browser:embedded:site:www.baidu.com", "\(toolName)"
            )
            // No page (blank tab, local file): nothing to scope a rule to.
            #expect(AgentToolAuthorization.suggestedPersistentSignature(
                toolName: toolName,
                arguments: ["selector": .string("button"), host: .string("")]
            ) == nil, "\(toolName)")
            #expect(AgentToolAuthorization.suggestedPersistentSignature(
                toolName: toolName,
                arguments: ["selector": .string("button")]
            ) == nil, "\(toolName)")
        }
        #expect(
            AgentToolAuthorization.suggestedPersistentSignature(
                toolName: "chrome_type",
                arguments: ["ref": .string("dom-1:e1"), "text": .string("hi")]
            ) == "browser:chrome:chrome_type"
        )
        #expect(
            AgentToolAuthorization.suggestedPersistentSignature(
                toolName: "embedded_browser_navigate",
                arguments: [:]
            ) == nil
        )
    }

    @Test("宿主写入发起时页面的域名，覆盖模型自带的值；navigate 与 Chrome 不写")
    func pageHostIsStampedByTheHost() {
        let key = AgentToolAuthorization.embeddedBrowserPageHostArgument
        let stamped = AgentToolAuthorization.stampingEmbeddedBrowserPageHost(
            toolName: "embedded_browser_click",
            arguments: ["selector": .string("a"), key: .string("attacker.example")],
            currentURL: "https://WWW.Baidu.com/s?wd=x"
        )
        #expect(stamped[key]?.stringValue() == "www.baidu.com")
        for blank in ["about:blank", "", "file:///tmp/a.html"] {
            let noSite = AgentToolAuthorization.stampingEmbeddedBrowserPageHost(
                toolName: "embedded_browser_eval", arguments: [:], currentURL: blank
            )
            #expect(noSite[key]?.stringValue() == "", "\(blank)")
        }
        #expect(AgentToolAuthorization.stampingEmbeddedBrowserPageHost(
            toolName: "embedded_browser_navigate", arguments: [:], currentURL: "https://a.example/"
        )[key] == nil)
        #expect(AgentToolAuthorization.stampingEmbeddedBrowserPageHost(
            toolName: "chrome_click", arguments: [:], currentURL: "https://a.example/"
        )[key] == nil)
    }

    @Test("批准后页面跳到别的域名，执行前拒绝；同域名或没写域名的调用照常执行")
    func hostDriftIsRefusedAtExecution() {
        let key = AgentToolAuthorization.embeddedBrowserPageHostArgument
        let arguments: [String: AgentJSONValue] = [key: .string("www.baidu.com")]
        #expect(AgentToolAuthorization.embeddedBrowserHostDriftMessage(
            arguments: arguments, currentURL: "https://www.baidu.com/s?wd=y"
        ) == nil)
        let drift = AgentToolAuthorization.embeddedBrowserHostDriftMessage(
            arguments: arguments, currentURL: "https://evil.example/"
        )
        #expect(drift?.contains("evil.example") == true)
        #expect(AgentToolAuthorization.embeddedBrowserHostDriftMessage(
            arguments: arguments, currentURL: "about:blank"
        ) != nil)
        #expect(AgentToolAuthorization.embeddedBrowserHostDriftMessage(
            arguments: [key: .string("")], currentURL: "https://evil.example/"
        ) == nil)
        #expect(AgentToolAuthorization.embeddedBrowserHostDriftMessage(
            arguments: [:], currentURL: "https://evil.example/"
        ) == nil)
    }

    @Test("1.396–1.398 存下的按工具规则继续匹配")
    func perToolRulesFromEarlierBuildsStillMatch() {
        let key = AgentToolAuthorization.embeddedBrowserPageHostArgument
        let click = AgentToolAuthorization.matchingSignatures(
            toolName: "embedded_browser_click",
            arguments: ["selector": .string("a"), key: .string("www.baidu.com")]
        )
        #expect(click.contains("browser:embedded:site:www.baidu.com"))
        #expect(click.contains("browser:embedded:embedded_browser_click"))
        let navigate = AgentToolAuthorization.matchingSignatures(
            toolName: "embedded_browser_navigate",
            arguments: ["url": .string("https://www.baidu.com/")]
        )
        #expect(navigate.contains("browser:embedded:site:www.baidu.com"))
        #expect(navigate.contains("browser:embedded:embedded_browser_navigate:www.baidu.com"))
    }

    @Test("只有 CDP 调试命令和上传逐次确认：不能持久放行，也不随本会话浏览器授权放行")
    func debuggerAndUploadAlwaysAsk() {
        #expect(!AgentToolAuthorization.browserToolsRequiringPerCallApproval.contains("embedded_browser_eval"))
        for toolName in ["chrome_debugger_command", "embedded_browser_upload_file"] {
            #expect(AgentToolAuthorization.interactiveSurfaceSignature(toolName: toolName) == nil)
            #expect(AgentToolAuthorization.suggestedPersistentSignature(
                toolName: toolName,
                arguments: [
                    "method": .string("Network.getAllCookies"),
                    AgentToolAuthorization.embeddedBrowserPageHostArgument: .string("www.baidu.com"),
                ]
            ) == nil)
            #expect(AgentToolAuthorization.matchingSignatures(
                toolName: toolName,
                arguments: [AgentToolAuthorization.embeddedBrowserPageHostArgument: .string("www.baidu.com")]
            ).isEmpty)
        }
    }

    @Test("旧版整族规则 browser:embedded / browser:chrome 不再匹配任何调用")
    func legacyFamilyRulesNoLongerMatch() {
        let calls: [(String, [String: AgentJSONValue])] = [
            ("embedded_browser_navigate", ["url": .string("https://example.org")]),
            ("embedded_browser_click", ["selector": .string("a")]),
            ("embedded_browser_type", ["selector": .string("input"), "text": .string("x")]),
            ("chrome_click", ["ref": .string("dom-1:e1")]),
        ]
        for (toolName, arguments) in calls {
            let signatures = AgentToolAuthorization.matchingSignatures(toolName: toolName, arguments: arguments)
            #expect(!signatures.contains("browser:embedded"))
            #expect(!signatures.contains("browser:chrome"))
        }
        let otherHost = AgentToolAuthorization.matchingSignatures(
            toolName: "embedded_browser_navigate",
            arguments: ["url": .string("https://evil.example/")]
        )
        #expect(!otherHost.contains("browser:embedded:embedded_browser_navigate:www.baidu.com"))
    }

    @Test("一条网站规则放行该网站上的打开、点击、输入和脚本，换一个网站仍要确认")
    func siteRuleCoversEveryEmbeddedActionOnThatSiteOnly() {
        let appState = AppState()
        appState.agentAlwaysAllowedCommands = [
            AgentAlwaysAllowedCommand(commandSignature: "browser:embedded:site:www.baidu.com"),
        ]
        let key = AgentToolAuthorization.embeddedBrowserPageHostArgument
        #expect(appState.isAgentToolCallAlwaysAllowed(
            toolName: "embedded_browser_navigate",
            arguments: ["url": .string("https://www.baidu.com/s?wd=x")],
            risk: .write
        ))
        for toolName in ["embedded_browser_click", "embedded_browser_type", "embedded_browser_eval", "embedded_browser_scroll"] {
            #expect(appState.isAgentToolCallAlwaysAllowed(
                toolName: toolName, arguments: [key: .string("www.baidu.com")], risk: .write
            ), "\(toolName)")
            #expect(!appState.isAgentToolCallAlwaysAllowed(
                toolName: toolName, arguments: [key: .string("evil.example")], risk: .write
            ), "\(toolName)")
            #expect(!appState.isAgentToolCallAlwaysAllowed(
                toolName: toolName, arguments: [key: .string("")], risk: .write
            ), "\(toolName)")
        }
        #expect(!appState.isAgentToolCallAlwaysAllowed(
            toolName: "embedded_browser_navigate",
            arguments: ["url": .string("https://evil.example/")],
            risk: .write
        ))
        #expect(!appState.isAgentToolCallAlwaysAllowed(
            toolName: "embedded_browser_upload_file",
            arguments: [key: .string("www.baidu.com"), "path": .string("a.txt")],
            risk: .write
        ))
    }

    @Test("本会话浏览器授权也覆盖 eval")
    func conversationGrantCoversEval() async {
        let appState = AppState()
        for toolName in ["embedded_browser_eval", "embedded_browser_click"] {
            let approval = await appState.autoApprovalSource(
                toolName: toolName,
                arguments: ["javascript": .string("return document.title"), "selector": .string("button")],
                risk: .write,
                rootDirectory: nil,
                approvalMode: .requestEveryTime,
                conversationAllowedToolSignatures: ["browser:embedded"]
            )
            #expect(approval == .user, "\(toolName)")
        }
    }

    // MARK: - Navigation policy

    @Test(
        "navigate 只放行 http(s)、about:blank、本机开发服务和工作区内文件",
        arguments: [
            ("https://www.baidu.com/s?wd=x", true),
            ("example.com", true),
            ("http://localhost:5173/", true),
            ("http://127.0.0.1:8080/app", true),
            ("http://[::1]:3000/", true),
            ("about:blank", true),
            ("http://192.168.1.1/", false),
            ("http://10.0.0.8:8000/", false),
            ("http://169.254.169.254/latest/meta-data/", false),
            ("http://nas.local/", false),
            ("javascript:alert(1)", false),
            ("data:text/html,<p>x</p>", false),
            ("file:///etc/passwd", false),
            ("about:config", false),
            ("ftp://example.com/file", false),
        ]
    )
    func navigationPolicy(rawURL: String, allowed: Bool) {
        let decision = AgentEmbeddedBrowserNavigationPolicy.evaluate(
            rawURL: rawURL,
            allowedFileRoots: [URL(fileURLWithPath: "/tmp/workspace-root")]
        )
        if case .allow = decision {
            #expect(allowed, "unexpectedly allowed \(rawURL)")
        } else {
            #expect(!allowed, "unexpectedly rejected \(rawURL)")
        }
    }

    @Test("file:// 只允许工作区内，符号链接与 .. 逃逸都会被拒")
    func fileURLsMustStayInsideWorkspace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-nav-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("index.html")
        try "<p>ok</p>".write(to: inside, atomically: true, encoding: .utf8)
        let escape = root.appendingPathComponent("../outside.html").absoluteString
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc"))

        #expect(AgentEmbeddedBrowserNavigationPolicy.evaluate(rawURL: inside.absoluteString, allowedFileRoots: [root]) == .allow(inside))
        if case .allow = AgentEmbeddedBrowserNavigationPolicy.evaluate(rawURL: escape, allowedFileRoots: [root]) {
            Issue.record("../ escape was allowed")
        }
        if case .allow = AgentEmbeddedBrowserNavigationPolicy.evaluate(
            rawURL: link.appendingPathComponent("passwd").absoluteString,
            allowedFileRoots: [root]
        ) {
            Issue.record("symlink escape was allowed")
        }
        if case .allow = AgentEmbeddedBrowserNavigationPolicy.evaluate(rawURL: inside.absoluteString, allowedFileRoots: []) {
            Issue.record("file:// allowed without a workspace")
        }
    }

    @Test("navigate 工具拒绝内网地址时抛出可读错误，不去加载")
    func navigateToolRejectsPrivateNetwork() async {
        let runtimeID = UUID()
        defer { AgentEmbeddedBrowserController.release(for: runtimeID) }
        await #expect(throws: AgentToolError.self) {
            _ = try await AgentEmbeddedBrowserTools.navigate(
                arguments: ["url": .string("http://192.168.1.1/admin")],
                runtimeID: runtimeID
            )
        }
        #expect(!AgentEmbeddedBrowserController.controller(for: runtimeID).isReady)
    }

    // MARK: - Secret values in page reads

    @Test("read_page / snapshot 不回传密码框的值，hidden 字段直接略过")
    func pageReadsNeverReturnSecretValues() async throws {
        let runtimeID = UUID()
        defer { AgentEmbeddedBrowserController.release(for: runtimeID) }
        let controller = AgentEmbeddedBrowserController.controller(for: runtimeID)
        let html = """
        <html><body>
        <input id="user" name="user" value="alice">
        <input id="pw" type="password" name="pw" value="hunter2-secret">
        <input id="otp" name="one_time_code" value="918273">
        <input type="hidden" name="csrf" value="csrf-token-xyz">
        </body></html>
        """
        // loadHTMLString, not a data: URL: the page URL is echoed back in
        // every read and would carry the values in its own source.
        controller.ensureWebView(loadInitialPage: false).loadHTMLString(html, baseURL: nil)
        #expect(await controller.waitForNavigationToSettle())

        let page = try await controller.readPage(maxChars: 5_000)
        let pageJSON = String(data: try JSONSerialization.data(withJSONObject: page), encoding: .utf8) ?? ""
        #expect(pageJSON.contains("alice"))
        for secret in ["hunter2-secret", "918273", "csrf-token-xyz"] {
            #expect(!pageJSON.contains(secret), "read_page leaked \(secret)")
        }
        let forms = try #require(page["forms"] as? [[String: Any]])
        #expect(!forms.contains { ($0["name"] as? String) == "csrf" })
        let password = try #require(forms.first { ($0["id"] as? String) == "pw" })
        #expect(password["has_value"] as? Bool == true)

        let snapshot = try await controller.snapshot(maxElements: 50)
        let snapshotJSON = String(data: try JSONSerialization.data(withJSONObject: snapshot), encoding: .utf8) ?? ""
        for secret in ["hunter2-secret", "918273", "csrf-token-xyz"] {
            #expect(!snapshotJSON.contains(secret), "snapshot leaked \(secret)")
        }
    }

    // MARK: - Untrusted web content envelope

    @Test("网页类工具结果被标成不可信数据，其它工具不受影响")
    func webContentEnvelope() {
        for toolName in ["embedded_browser_read_page", "chrome_read_page", "web_fetch", "web_search"] {
            #expect(AgentInjectionDefense.returnsWebContent(toolName: toolName))
        }
        for toolName in ["read_file", "run_command", "call_mcp_tool"] {
            #expect(!AgentInjectionDefense.returnsWebContent(toolName: toolName))
        }
        let wrapped = AgentInjectionDefense.wrapWebContent("page says hi", toolName: "web_fetch")
        #expect(wrapped.hasPrefix("<untrusted_web_content tool=\"web_fetch\">"))
        #expect(wrapped.hasSuffix("</untrusted_web_content>"))
        #expect(wrapped.contains("page says hi"))
    }

    // MARK: - Chrome bridge token

    @Test("Chrome 桥 token 从文件读取并去掉空白，空文件视为没有")
    func chromeBridgeTokenReading() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-bridge-token-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("bridge-token")
        #expect(AgentChromeTools.bridgeToken(at: file) == nil)
        try "abc123\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(AgentChromeTools.bridgeToken(at: file) == "abc123")
        try "  \n".write(to: file, atomically: true, encoding: .utf8)
        #expect(AgentChromeTools.bridgeToken(at: file) == nil)
        #expect(AgentChromeTools.bridgeTokenHeader == "X-WillDeep-Bridge-Token")
    }
}
