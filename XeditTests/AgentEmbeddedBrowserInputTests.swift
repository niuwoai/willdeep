//
//  AgentEmbeddedBrowserInputTests.swift
//  XeditTests
//
//  Keyboard, scrolling and file upload for the embedded browser, plus the
//  workspace-only upload policy.
//

import AppKit
import Foundation
import Testing
import WebKit
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentEmbeddedBrowserInputTests {
    // MARK: - Helpers

    private final class Sandbox {
        let directory: URL
        let runtimeID = UUID()
        private var window: NSWindow?
        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("willdeep-browser-input-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func write(_ name: String, _ html: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try (#"<meta charset="utf-8">"# + html).write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        func writeData(_ name: String, _ contents: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        /// Scrolling and hit-testing need a real viewport; in the app the web
        /// view lives in the side panel's window.
        func attachWindow(_ webView: WKWebView) {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            webView.frame = window.contentView?.bounds ?? .zero
            window.contentView?.addSubview(webView)
            self.window = window
        }
        deinit {
            window?.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func open(_ url: URL, in sandbox: Sandbox, withWindow: Bool = false) async throws -> AgentEmbeddedBrowserController {
        let controller = AgentEmbeddedBrowserController.controller(for: sandbox.runtimeID)
        if withWindow {
            sandbox.attachWindow(controller.ensureWebView(loadInitialPage: false))
        }
        try controller.navigate(to: url.absoluteString)
        #expect(await controller.waitForNavigationToSettle(timeout: Self.initialLoadTimeout))
        return controller
    }

    /// The first load in a suite spawns a cold WebContent process; under the
    /// full 4.5k-test run that alone outlasts the production 10 s settle
    /// window, and only the suite's first test ever failed. Only the test's
    /// setup load gets the longer window; the actions under test keep theirs.
    private static let initialLoadTimeout: Duration = .seconds(60)

    private func value(_ controller: AgentEmbeddedBrowserController, _ expression: String) async throws -> String {
        let result = try await controller.evaluate(source: "return \(expression);", maxChars: 10_000)
        return result["value"] as? String ?? ""
    }

    private let noModifiers = AgentEmbeddedBrowserController.KeyModifiers()

    // MARK: - Keys

    @Test("在表单输入框里按 Enter 会提交表单，并等到新页面")
    func enterSubmitsForm() async throws {
        let sandbox = try Sandbox()
        defer { AgentEmbeddedBrowserController.release(for: sandbox.runtimeID) }
        _ = try sandbox.write("result.html", "<html><head><title>Results</title></head><body>searched</body></html>")
        let page = try sandbox.write("search.html", #"<html><body><form action="result.html"><input id="q" name="q"></form></body></html>"#)
        let controller = try await open(page, in: sandbox)

        let result = try await controller.pressKey(key: "Enter", selector: "#q", code: nil, modifiers: noModifiers)
        #expect(result["action"] as? String == "submitted")
        #expect(result["navigated"] as? Bool == true)
        #expect(result["title"] as? String == "Results")
    }

    @Test("字符插入、Backspace 删除、Tab 移焦点、空格勾选、方向键切换下拉")
    func keyDefaultActions() async throws {
        let sandbox = try Sandbox()
        defer { AgentEmbeddedBrowserController.release(for: sandbox.runtimeID) }
        let page = try sandbox.write("keys.html", #"""
        <html><body>
        <input id="a" value="ab"><input id="b">
        <input id="c" type="checkbox">
        <select id="s"><option>one</option><option>two</option></select>
        </body></html>
        """#)
        let controller = try await open(page, in: sandbox, withWindow: true)

        #expect(try await controller.pressKey(key: "c", selector: "#a", code: nil, modifiers: noModifiers)["action"] as? String == "inserted")
        #expect(try await value(controller, "document.getElementById('a').value") == #""abc""#)
        #expect(try await controller.pressKey(key: "Backspace", selector: "#a", code: nil, modifiers: noModifiers)["action"] as? String == "deleted")
        #expect(try await value(controller, "document.getElementById('a').value") == #""ab""#)

        let tab = try await controller.pressKey(key: "Tab", selector: "#a", code: nil, modifiers: noModifiers)
        #expect(tab["focused"] as? String == "input#b")

        #expect(try await controller.pressKey(key: " ", selector: "#c", code: nil, modifiers: noModifiers)["action"] as? String == "toggled")
        #expect(try await value(controller, "document.getElementById('c').checked") == "true")

        #expect(try await controller.pressKey(key: "ArrowDown", selector: "#s", code: nil, modifiers: noModifiers)["action"] as? String == "option_changed")
        #expect(try await value(controller, "document.getElementById('s').value") == #""two""#)
    }

    @Test("页面拦截了按键时不再补默认动作")
    func pagePreventDefaultWins() async throws {
        let sandbox = try Sandbox()
        defer { AgentEmbeddedBrowserController.release(for: sandbox.runtimeID) }
        let page = try sandbox.write("prevent.html", #"""
        <html><body><input id="a">
        <script>document.getElementById('a').addEventListener('keydown', (e) => e.preventDefault());</script>
        </body></html>
        """#)
        let controller = try await open(page, in: sandbox)
        let result = try await controller.pressKey(key: "x", selector: "#a", code: nil, modifiers: noModifiers)
        #expect(result["action"] as? String == "prevented_by_page")
        #expect(try await value(controller, "document.getElementById('a').value") == #""""#)
    }

    // MARK: - Scroll

    @Test("滚动：向下一屏、到底、回顶、滚到元素，返回 at_top / at_bottom")
    func scrollPage() async throws {
        let sandbox = try Sandbox()
        defer { AgentEmbeddedBrowserController.release(for: sandbox.runtimeID) }
        let page = try sandbox.write("tall.html", #"""
        <html><body style="margin:0"><div style="height:5000px">top</div><p id="far">far away</p>
        <div id="box" style="height:100px;overflow:auto"><div style="height:1000px">inner</div></div></body></html>
        """#)
        let controller = try await open(page, in: sandbox, withWindow: true)

        let down = try await controller.scroll(direction: "down", pages: 1, selector: nil)
        #expect((down["scroll_y"] as? Int ?? 0) > 0)
        #expect(down["at_top"] as? Bool == false)
        let bottom = try await controller.scroll(direction: "bottom", pages: 1, selector: nil)
        #expect(bottom["at_bottom"] as? Bool == true)
        let top = try await controller.scroll(direction: "top", pages: 1, selector: nil)
        #expect(top["at_top"] as? Bool == true)

        let intoView = try await controller.scroll(direction: "into_view", pages: 1, selector: "#far")
        #expect(intoView["ok"] as? Bool == true)
        #expect((intoView["scroll_y"] as? Int ?? 0) > 4_000)

        let container = try await controller.scroll(direction: "down", pages: 2, selector: "#box")
        #expect((container["scroll_y"] as? Int ?? 0) > 0)

        await #expect(throws: AgentToolError.self) {
            _ = try await controller.scroll(direction: "sideways", pages: 1, selector: nil)
        }
    }

    // MARK: - Upload

    @Test("上传到 <input type=file>：文件名、大小写入 files，并触发 change")
    func uploadIntoFileInput() async throws {
        let sandbox = try Sandbox()
        defer { AgentEmbeddedBrowserController.release(for: sandbox.runtimeID) }
        let file = try sandbox.writeData("docs/report.txt", "hello upload")
        let page = try sandbox.write("upload.html", #"""
        <html><body><input id="f" type="file">
        <script>document.getElementById('f').addEventListener('change', (e) => { window.picked = e.target.files[0].name; });</script>
        </body></html>
        """#)
        let controller = try await open(page, in: sandbox)

        let result = try await AgentEmbeddedBrowserTools.uploadFile(
            arguments: ["selector": .string("#f"), "paths": .array([.string("docs/report.txt")])],
            runtimeID: sandbox.runtimeID,
            workspaceRoots: [sandbox.directory]
        )
        #expect(result.payload.contains("report.txt"))
        #expect(try await value(controller, "window.picked") == #""report.txt""#)
        #expect(try await value(controller, "document.getElementById('f').files[0].size") == "\(try Data(contentsOf: file).count)")

        let second = try sandbox.writeData("docs/b.txt", "b")
        let multiple = try await controller.uploadFiles(selector: "#f", files: [file, second])
        #expect(multiple["ok"] as? Bool == false)
    }

    @Test("目标不是 file input 时点击它，并把文件交给页面打开的文件选择框")
    func uploadThroughCustomButton() async throws {
        let sandbox = try Sandbox()
        defer { AgentEmbeddedBrowserController.release(for: sandbox.runtimeID) }
        let file = try sandbox.writeData("photo.png", "fake-png")
        let page = try sandbox.write("button.html", #"""
        <html><body>
        <input id="hidden" type="file" style="display:none">
        <button id="pick" onclick="document.getElementById('hidden').click()">Upload</button>
        <script>document.getElementById('hidden').addEventListener('change', (e) => { window.picked = e.target.files[0].name; });</script>
        </body></html>
        """#)
        let controller = try await open(page, in: sandbox, withWindow: true)

        let result = try await controller.uploadFiles(selector: "#pick", files: [file])
        // Scripts run through WKWebView count as a user gesture, so the page's
        // hidden input.click() does reach runOpenPanel (verified standalone).
        #expect(result["mode"] as? String == "file_chooser")
        #expect(result["files_provided"] as? Bool == true)
        #expect(try await value(controller, "window.picked") == #""photo.png""#)
        #expect(controller.pendingOpenPanelFiles.isEmpty)
    }

    @Test("上传策略：只允许工作区内的普通文件，拒绝凭据、目录、越界、超量")
    func uploadPolicy() throws {
        let sandbox = try Sandbox()
        let root = sandbox.directory
        _ = try sandbox.writeData("a.txt", "a")
        _ = try sandbox.writeData(".env", "SECRET=1")
        _ = try sandbox.writeData("keys/id_rsa", "key")
        _ = try sandbox.writeData("cert.pem", "pem")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("etc-link"), withDestinationURL: URL(fileURLWithPath: "/etc"))

        guard case .allow(let files) = AgentEmbeddedBrowserUploadPolicy.evaluate(paths: ["a.txt"], workspaceRoots: [root]) else {
            Issue.record("workspace file rejected"); return
        }
        #expect(files.first?.lastPathComponent == "a.txt")

        let rejected = [".env", "keys/id_rsa", "cert.pem", "folder", "missing.txt", "/etc/hosts", "etc-link/hosts", "../outside.txt"]
        for path in rejected {
            if case .allow = AgentEmbeddedBrowserUploadPolicy.evaluate(paths: [path], workspaceRoots: [root]) {
                Issue.record("\(path) was allowed")
            }
        }
        if case .allow = AgentEmbeddedBrowserUploadPolicy.evaluate(paths: ["a.txt"], workspaceRoots: []) {
            Issue.record("upload allowed without a workspace")
        }
        let tooMany = Array(repeating: "a.txt", count: AgentEmbeddedBrowserUploadPolicy.maxFileCount + 1)
        if case .allow = AgentEmbeddedBrowserUploadPolicy.evaluate(paths: tooMany, workspaceRoots: [root]) {
            Issue.record("too many files allowed")
        }
    }

    @Test("上传每次都要单独批准：不随会话授权、不能持久放行")
    func uploadAlwaysAsks() {
        #expect(AgentToolAuthorization.interactiveSurfaceSignature(toolName: "embedded_browser_upload_file") == nil)
        #expect(AgentToolAuthorization.suggestedPersistentSignature(
            toolName: "embedded_browser_upload_file",
            arguments: ["selector": .string("#f"), "paths": .array([.string("a.txt")])]
        ) == nil)
        #expect(AgentToolAuthorization.interactiveSurfaceSignature(toolName: "embedded_browser_press_key") == "browser:embedded")
        #expect(AgentToolAuthorization.suggestedPersistentSignature(
            toolName: "embedded_browser_scroll",
            arguments: ["direction": .string("down"), AgentToolAuthorization.embeddedBrowserPageHostArgument: .string("example.com")]
        ) == "browser:embedded:site:example.com")
    }
}
