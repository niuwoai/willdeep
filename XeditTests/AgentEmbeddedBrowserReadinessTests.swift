//
//  AgentEmbeddedBrowserReadinessTests.swift
//  XeditTests
//
//  The embedded browser's eval tool returns async results, and page reads
//  wait for a parsed document and flag an empty one instead of returning a
//  silent blank.
//

import Foundation
import Testing
import WebKit
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentEmbeddedBrowserReadinessTests {
    @Test("readyState 为 interactive / complete 才算 DOM 可读")
    func parsedReadyStates() {
        #expect(AgentEmbeddedBrowserReadiness.isParsed(readyState: "interactive"))
        #expect(AgentEmbeddedBrowserReadiness.isParsed(readyState: "complete"))
        #expect(!AgentEmbeddedBrowserReadiness.isParsed(readyState: "loading"))
        #expect(!AgentEmbeddedBrowserReadiness.isParsed(readyState: ""))
    }

    @Test("读到空内容时附带提示，有内容时不附带")
    func emptyContentNote() throws {
        #expect(AgentEmbeddedBrowserReadiness.emptyContentNote(readyState: "complete", isEmpty: false) == nil)
        let note = try #require(AgentEmbeddedBrowserReadiness.emptyContentNote(readyState: "loading", isEmpty: true))
        #expect(note.contains("ready_state=loading"))
        #expect(note.contains("embedded_browser_wait_for"))
        let unknown = try #require(AgentEmbeddedBrowserReadiness.emptyContentNote(readyState: "", isEmpty: true))
        #expect(unknown.contains("ready_state=unknown"))
    }

    @Test("eval 能返回 async 脚本的结果，不再报返回类型不受支持")
    func evaluateReturnsAsyncResult() async throws {
        let runtimeID = UUID()
        defer { AgentEmbeddedBrowserController.release(for: runtimeID) }
        let controller = AgentEmbeddedBrowserController.controller(for: runtimeID)
        try await load(html: "<html><body><p id='x'>hello</p></body></html>", into: controller)

        let payload = try await controller.evaluate(
            source: "await new Promise((r) => setTimeout(r, 10)); return { text: document.getElementById('x').textContent };",
            maxChars: 1_000
        )
        #expect(payload["ok"] as? Bool == true)
        #expect(payload["type"] as? String == "object")
        #expect(payload["value"] as? String == #"{"text":"hello"}"#)
    }

    @Test("eval 脚本抛错时返回 ok=false 和错误信息，结果超长时截断")
    func evaluateReportsErrorsAndTruncates() async throws {
        let runtimeID = UUID()
        defer { AgentEmbeddedBrowserController.release(for: runtimeID) }
        let controller = AgentEmbeddedBrowserController.controller(for: runtimeID)
        try await load(html: "<html><body></body></html>", into: controller)

        let failure = try await controller.evaluate(source: "throw new Error('boom');", maxChars: 1_000)
        #expect(failure["ok"] as? Bool == false)
        #expect((failure["error"] as? String)?.contains("boom") == true)

        let long = try await controller.evaluate(source: "return 'a'.repeat(50);", maxChars: 10)
        let value = try #require(long["value"] as? String)
        #expect(value.hasSuffix("[truncated]"))
        #expect(value.hasPrefix("\"aaaaaaaaa"))
    }

    @Test("navigate 后 read_page 读到正文，带 ready_state 且不附提示")
    func readPageAfterNavigateSeesContent() async throws {
        let runtimeID = UUID()
        defer { AgentEmbeddedBrowserController.release(for: runtimeID) }
        let controller = AgentEmbeddedBrowserController.controller(for: runtimeID)
        try controller.navigate(to: "data:text/html,<html><head><title>T</title></head><body><p>hello page</p></body></html>")
        #expect(await controller.waitForNavigationToSettle())

        let payload = try await controller.readPage(maxChars: 1_000)
        #expect((payload["text"] as? String)?.contains("hello page") == true)
        #expect(AgentEmbeddedBrowserReadiness.isParsed(readyState: payload["ready_state"] as? String ?? ""))
        #expect(payload["note"] == nil)
    }

    @Test("空白页面 read_page / snapshot 附带提示，而不是静默返回空")
    func emptyPageReadsCarryNote() async throws {
        let runtimeID = UUID()
        defer { AgentEmbeddedBrowserController.release(for: runtimeID) }
        let controller = AgentEmbeddedBrowserController.controller(for: runtimeID)
        try controller.navigate(to: "data:text/html,<html><body></body></html>")
        #expect(await controller.waitForNavigationToSettle())

        let page = try await controller.readPage(maxChars: 1_000)
        #expect((page["note"] as? String)?.contains("no readable content") == true)
        let snapshot = try await controller.snapshot(maxElements: 20)
        #expect(snapshot["count"] as? Int == 0)
        #expect(snapshot["note"] != nil)
    }

    private func load(html: String, into controller: AgentEmbeddedBrowserController) async throws {
        let webView = controller.ensureWebView(loadInitialPage: false)
        webView.loadHTMLString(html, baseURL: nil)
        #expect(await controller.waitForNavigationToSettle())
    }
}
