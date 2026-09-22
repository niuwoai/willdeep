//
//  AgentEmbeddedBrowserInteractionTests.swift
//  XeditTests
//
//  Interaction fidelity of the embedded browser: popups open in place,
//  clicks wait for the page they open, dialogs are reported, stale snapshot
//  refs are cleared, typing reaches controlled inputs, scripts can be
//  cancelled, page exceptions keep their message, console payloads stay
//  bounded, and screenshots reach the model as images.
//

import AppKit
import Foundation
import Testing
import WebKit
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentEmbeddedBrowserInteractionTests {
    // MARK: - Helpers

    private final class Sandbox {
        let directory: URL
        let runtimeID = UUID()
        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("willdeep-browser-interaction-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func write(_ name: String, _ html: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            // Without a declared charset WebKit decodes local files as
            // Latin-1 and CJK labels turn into mojibake.
            try (#"<meta charset="utf-8">"# + html).write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private func open(_ url: URL, in sandbox: Sandbox) async throws -> AgentEmbeddedBrowserController {
        let controller = AgentEmbeddedBrowserController.controller(for: sandbox.runtimeID)
        try controller.navigate(to: url.absoluteString)
        #expect(await controller.waitForNavigationToSettle())
        return controller
    }

    private func pageValue(_ controller: AgentEmbeddedBrowserController, _ expression: String) async throws -> String {
        let result = try await controller.evaluate(source: "return \(expression);", maxChars: 10_000)
        return result["value"] as? String ?? ""
    }

    // MARK: - Navigation from clicks

    @Test("target=_blank 链接在当前页打开，click 等到新页面并返回 navigated")
    func blankTargetLinkOpensInPlace() async throws {
        let sandbox = try Sandbox()
        defer { AgentEmbeddedBrowserController.release(for: sandbox.runtimeID) }
        _ = try sandbox.write("page2.html", "<html><head><title>Page Two</title></head><body><p>second page</p></body></html>")
        let first = try sandbox.write("page1.html", #"<html><head><title>Page One</title></head><body><a id="go" href="page2.html" target="_blank">next</a></body></html>"#)
        let controller = try await open(first, in: sandbox)

        let result = try await controller.click(selector: "#go")
        #expect(result["ok"] as? Bool == true)
        #expect(result["navigated"] as? Bool == true)
        #expect(result["title"] as? String == "Page Two")
        let page = try await controller.readPage(maxChars: 2_000)
        #expect((page["text"] as? String)?.contains("second page") == true)
    }

    @Test("普通链接点击后等新页面提交，紧接着的 read_page 读到的是新页面")
    func sameTabLinkWaitsForNewDocument() async throws {
        let sandbox = try Sandbox()
        defer { AgentEmbeddedBrowserController.release(for: sandbox.runtimeID) }
        _ = try sandbox.write("b.html", "<html><head><title>B</title></head><body><p>page b body</p></body></html>")
        let a = try sandbox.write("a.html", #"<html><head><title>A</title></head><body><a id="go" href="b.html">b</a></body></html>"#)
        let controller = try await open(a, in: sandbox)

        let result = try await controller.click(selector: "#go")
        #expect(result["navigated"] as? Bool == true)
        let page = try await controller.readPage(maxChars: 2_000)
        #expect(page["title"] as? String == "B")
        #expect((page["text"] as? String)?.contains("page b body") == true)
    }

    @Test("不跳转的点击不带 navigated；confirm 被取消并报告在 dialogs 里")
    func dialogsAreDismissedAndReported() async throws {
        let sandbox = try Sandbox()
        defer { AgentEmbeddedBrowserController.release(for: sandbox.runtimeID) }
        let page = try sandbox.write("dialog.html", #"""
        <html><body>
        <button id="del" onclick="window.answer = String(confirm('Delete everything?'))">delete</button>
        </body></html>
        """#)
        let controller = try await open(page, in: sandbox)

        let result = try await controller.click(selector: "#del")
        #expect(result["ok"] as? Bool == true)
        #expect(result["navigated"] == nil)
        let dialogs = try #require(result["dialogs"] as? [[String: Any]])
        #expect(dialogs.first?["kind"] as? String == "confirm")
        #expect(dialogs.first?["message"] as? String == "Delete everything?")
        #expect(dialogs.first?["answer"] as? String == "cancelled")
        #expect(try await pageValue(controller, "window.answer") == #""false""#)
        #expect((controller.statusPayload()["last_dialog"] as? [String: Any])?["kind"] as? String == "confirm")
    }

    // MARK: - Click fidelity

    @Test("click 派发 pointerdown/mousedown，被遮挡时报告 covered_by，禁用元素拒绝点击")
    func clickFidelity() async throws {
        let sandbox = try Sandbox()
        defer { AgentEmbeddedBrowserController.release(for: sandbox.runtimeID) }
        let page = try sandbox.write("click.html", #"""
        <html><body style="margin:0">
        <button id="menu" style="position:absolute;left:10px;top:10px;width:120px;height:40px">menu</button>
        <div id="overlay" style="position:absolute;left:0;top:0;width:300px;height:100px;background:rgba(0,0,0,.1)"></div>
        <button id="off" disabled style="position:absolute;left:10px;top:200px">off</button>
        <script>
          window.events = [];
          for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
            document.getElementById('menu').addEventListener(type, () => window.events.push(type));
          }
        </script>
        </body></html>
        """#)
        let controller = try await open(page, in: sandbox)
        // Hit-testing needs a real viewport. In the app the web view always
        // lives in the side panel's window; in a unit test it has frame .zero
        // and elementFromPoint finds nothing.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let webView = controller.ensureWebView(loadInitialPage: false)
        webView.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(webView)
        defer {
            webView.removeFromSuperview()
            window.close()
        }
        try await Task.sleep(for: .milliseconds(200))

        let result = try await controller.click(selector: "#menu")
        #expect(result["ok"] as? Bool == true)
        #expect((result["covered_by"] as? String)?.hasPrefix("div#overlay") == true)
        #expect(try await pageValue(controller, "window.events.join(',')") == #""pointerdown,mousedown,pointerup,mouseup,click""#)

        let disabled = try await controller.click(selector: "#off")
        #expect(disabled["ok"] as? Bool == false)
    }

    @Test("snapshot 前清掉上一轮的 ref，同一个 ref 不会挂在两个元素上")
    func snapshotClearsStaleRefs() async throws {
        let sandbox = try Sandbox()
        defer { AgentEmbeddedBrowserController.release(for: sandbox.runtimeID) }
        let page = try sandbox.write("refs.html", #"<html><body><button id="a">A</button><button id="b">B</button></body></html>"#)
        let controller = try await open(page, in: sandbox)

        _ = try await controller.snapshot(maxElements: 20)
        _ = try await controller.evaluate(
            source: "const n = document.createElement('button'); n.textContent = 'new'; document.body.prepend(n); return true;",
            maxChars: 100
        )
        _ = try await controller.snapshot(maxElements: 20)
        #expect(try await pageValue(controller, "document.querySelectorAll('[data-wd-browser-ref=\"wd1\"]').length") == "1")
        #expect(try await pageValue(controller, "document.querySelector('[data-wd-browser-ref=\"wd1\"]').textContent") == #""new""#)
    }

    // MARK: - Typing

    @Test("type 用原型 setter 赋值，受控输入框（React 式值跟踪）能感知到变化")
    func typeReachesControlledInputs() async throws {
        let sandbox = try Sandbox()
        defer { AgentEmbeddedBrowserController.release(for: sandbox.runtimeID) }
        let page = try sandbox.write("type.html", #"""
        <html><body>
        <input id="name">
        <select id="city"><option value="">-</option><option value="hz">杭州</option></select>
        <input id="agree" type="checkbox">
        <script>
          // Mimic React's value tracker: it records instance-level writes and
          // ignores an input event whose DOM value equals the tracked one.
          const input = document.getElementById('name');
          const native = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
          window.tracked = '';
          Object.defineProperty(input, 'value', {
            configurable: true,
            get() { return native.get.call(this); },
            set(v) { window.tracked = v; native.set.call(this, v); }
          });
          input.addEventListener('input', () => { window.reactWouldFire = input.value !== window.tracked; });
          document.getElementById('city').addEventListener('change', (e) => { window.city = e.target.value; });
        </script>
        </body></html>
        """#)
        let controller = try await open(page, in: sandbox)

        let typed = try await controller.typeText(selector: "#name", text: "hello")
        #expect(typed["ok"] as? Bool == true)
        #expect(try await pageValue(controller, "window.reactWouldFire") == "true")
        #expect(try await pageValue(controller, "document.getElementById('name').value") == #""hello""#)

        let selected = try await controller.typeText(selector: "#city", text: "杭州")
        #expect(selected["ok"] as? Bool == true)
        #expect(try await pageValue(controller, "window.city") == #""hz""#)

        let checkbox = try await controller.typeText(selector: "#agree", text: "on")
        #expect(checkbox["ok"] as? Bool == false)
        #expect((checkbox["error"] as? String)?.contains("embedded_browser_click") == true)
    }

    // MARK: - Script robustness

    @Test("永不结束的 eval 可以被取消，不会把回合挂死")
    func hungEvalIsCancellable() async throws {
        let sandbox = try Sandbox()
        defer { AgentEmbeddedBrowserController.release(for: sandbox.runtimeID) }
        let page = try sandbox.write("hang.html", "<html><body>hang</body></html>")
        let controller = try await open(page, in: sandbox)

        let started = ContinuousClock.now
        let task = Task { @MainActor in
            try await controller.evaluate(source: "await new Promise(() => {});", maxChars: 100)
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("非法选择器报出页面里的真实异常信息")
    func pageExceptionsKeepTheirMessage() async throws {
        let sandbox = try Sandbox()
        defer { AgentEmbeddedBrowserController.release(for: sandbox.runtimeID) }
        let page = try sandbox.write("sel.html", "<html><body><a>x</a></body></html>")
        let controller = try await open(page, in: sandbox)
        do {
            _ = try await controller.click(selector: "a[")
            Issue.record("invalid selector did not throw")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("JavaScript exception in the page"), "\(message)")
            #expect(message.lowercased().contains("selector") || message.contains("SyntaxError"), "\(message)")
        }
    }

    @Test("控制台消息按字段截断，超长日志不会撑爆返回")
    func consoleMessagesAreBounded() async throws {
        let sandbox = try Sandbox()
        defer { AgentEmbeddedBrowserController.release(for: sandbox.runtimeID) }
        let page = try sandbox.write("log.html", "<html><body><script>console.log('x'.repeat(50000));</script></body></html>")
        let controller = try await open(page, in: sandbox)
        var message: String?
        for _ in 0..<20 {
            let payload = controller.consolePayload(maxEntries: 10, levels: [])
            let entries = payload["entries"] as? [[String: Any]] ?? payload["events"] as? [[String: Any]] ?? []
            message = entries.compactMap { $0["message"] as? String }.first { $0.hasPrefix("xxxx") }
            if message != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let captured = try #require(message)
        #expect(captured.count < AgentEmbeddedBrowserController.consoleFieldCharacterLimit + 100)
        #expect(captured.contains("[truncated"))
    }

    // MARK: - Screenshots

    @Test("截图缩到最长边 1280 的 JPEG 附给模型，原图仍在磁盘上")
    func screenshotAttachmentIsDownscaledJPEG() throws {
        let sandbox = try Sandbox()
        let size = NSSize(width: 3_000, height: 1_500)
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let pngURL = sandbox.directory.appendingPathComponent("shot.png")
        try png.write(to: pngURL)

        let attachment = try #require(AgentEmbeddedBrowserTools.screenshotAttachment(atPath: pngURL.path))
        #expect(attachment.mimeType == "image/jpeg")
        #expect(attachment.originToolName == "embedded_browser_capture_screenshot")
        let path = try #require(attachment.filePath)
        let decoded = try #require(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))))
        #expect(max(decoded.pixelsWide, decoded.pixelsHigh) == Int(AgentEmbeddedBrowserTools.screenshotAttachmentMaxDimension))
        #expect(FileManager.default.fileExists(atPath: pngURL.path))
    }

    // MARK: - Chrome bridge timeouts

    @Test("Chrome 桥超时的报错说明动作可能已执行，而不是让人去装扩展")
    func chromeTimeoutMessage() {
        let message = AgentChromeTools.timeoutMessage(seconds: 15)
        #expect(message.contains("15 s"))
        #expect(message.contains("may still have run"))
        #expect(!message.contains("Install"))
    }
}
