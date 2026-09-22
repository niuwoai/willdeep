//
//  AgentEmbeddedBrowserExtractTests.swift
//  XeditTests
//
//  Declarative extraction: field spec parsing, a search-results page with an
//  ad marker (the Baidu task that used to take four eval calls), selector
//  errors, and sensitive input values staying out of results.
//

import Foundation
import Testing
import WebKit
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AgentEmbeddedBrowserExtractTests {
    private final class Sandbox {
        let directory: URL
        let runtimeID = UUID()
        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("willdeep-browser-extract-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func write(_ name: String, _ html: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try (#"<meta charset="utf-8">"# + html).write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    /// See AgentEmbeddedBrowserInputTests: the first load of a suite starts a
    /// cold WebContent process that can outlast 10 s under the full run.
    private static let initialLoadTimeout: Duration = .seconds(60)

    private func open(_ url: URL, in sandbox: Sandbox) async throws -> AgentEmbeddedBrowserController {
        let controller = AgentEmbeddedBrowserController.controller(for: sandbox.runtimeID)
        try controller.navigate(to: url.absoluteString)
        #expect(await controller.waitForNavigationToSettle(timeout: Self.initialLoadTimeout))
        return controller
    }

    @Test("字段语法：name=子选择器@来源，来源缺省为文字，空子选择器指元素本身")
    func parsesFieldSpecs() throws {
        #expect(try AgentBrowserExtractField.parse("title=h3") == .init(name: "title", selector: "h3", source: .text))
        #expect(try AgentBrowserExtractField.parse("link = h3 a@href") == .init(name: "link", selector: "h3 a", source: .attribute("href")))
        #expect(try AgentBrowserExtractField.parse("ad=.ec-tuiguang@exists") == .init(name: "ad", selector: ".ec-tuiguang", source: .exists))
        #expect(try AgentBrowserExtractField.parse("n=li@count") == .init(name: "n", selector: "li", source: .count))
        #expect(try AgentBrowserExtractField.parse("classes=@class") == .init(name: "classes", selector: nil, source: .attribute("class")))
        // An @ inside an attribute selector is part of the selector.
        #expect(try AgentBrowserExtractField.parse("mail=a[href^='mailto:x@y']") == .init(name: "mail", selector: "a[href^='mailto:x@y']", source: .text))
        for bad in ["title", "=h3", "bad name=h3"] {
            #expect(throws: AgentToolError.self) { try AgentBrowserExtractField.parse(bad) }
        }
    }

    @Test("搜索结果页：一次提取拿到标题、真实链接和广告标记，跳过广告取第一条")
    func extractsSearchResultsWithAdMarkers() async throws {
        let sandbox = try Sandbox()
        defer { AgentEmbeddedBrowserController.release(for: sandbox.runtimeID) }
        let page = try sandbox.write("results.html", #"""
        <html><head><title>杭州一日游_搜索</title></head><body><div id="content_left">
          <div class="result c-container" data-id="1"><h3><a href="https://ad.example/x">杭州旅游特价</a></h3><span class="ec-tuiguang">广告</span></div>
          <div class="result c-container" data-id="2"><h3><a href="/link?url=abc" data-mu="https://www.sohu.com/a/1">杭州一日游攻略</a></h3><p>上午灵隐寺，下午西湖。</p></div>
          <div class="result c-container" data-id="3"><h3><a href="https://c.example/">西湖一日游</a></h3></div>
        </div></body></html>
        """#)
        let controller = try await open(page, in: sandbox)
        let fields = try ["title=h3", "link=h3 a@href", "real=h3 a@data-mu", "ad=.ec-tuiguang@exists", "id=@data-id"]
            .map(AgentBrowserExtractField.parse)
        let payload = try await controller.extract(selector: "#content_left > .result", fields: fields, limit: 10, maxChars: 200)
        #expect(payload["matched"] as? Int == 3)
        let items = try #require(payload["items"] as? [[String: Any]])
        #expect(items.count == 3)
        #expect(items[0]["ad"] as? Bool == true)
        let firstOrganic = try #require(items.first { $0["ad"] as? Bool == false })
        #expect(firstOrganic["title"] as? String == "杭州一日游攻略")
        #expect(firstOrganic["real"] as? String == "https://www.sohu.com/a/1")
        #expect((firstOrganic["link"] as? String)?.hasSuffix("/link?url=abc") == true)
        #expect((firstOrganic["link"] as? String)?.hasPrefix("file://") == true, "href resolves to an absolute URL")
        #expect(firstOrganic["id"] as? String == "2")

        let limited = try await controller.extract(selector: ".result", fields: [], limit: 1, maxChars: 200)
        let only = try #require((limited["items"] as? [[String: Any]])?.first)
        #expect((only["text"] as? String)?.contains("杭州旅游特价") == true)
        #expect(only["href"] as? String == "https://ad.example/x")
        #expect(limited["returned"] as? Int == 1)
    }

    @Test("非法选择器报错；密码框的值不会被提取")
    func rejectsBadSelectorsAndHidesSecrets() async throws {
        let sandbox = try Sandbox()
        defer { AgentEmbeddedBrowserController.release(for: sandbox.runtimeID) }
        let page = try sandbox.write("form.html", #"""
        <html><body><form><input class="f" name="user" value="alice"><input class="f" type="password" name="pw" value="hunter2"></form></body></html>
        """#)
        let controller = try await open(page, in: sandbox)
        await #expect(throws: AgentToolError.self) {
            _ = try await controller.extract(selector: "div[[", fields: [], limit: 5, maxChars: 100)
        }
        let payload = try await controller.extract(
            selector: "input.f", fields: [try AgentBrowserExtractField.parse("v=@value")], limit: 5, maxChars: 100
        )
        let items = try #require(payload["items"] as? [[String: Any]])
        #expect(items.first?["v"] as? String == "alice")
        #expect(!(String(describing: payload)).contains("hunter2"))
    }

    @Test("提取工具是只读工具，登记在工具表里")
    func extractIsRegisteredReadOnly() throws {
        let descriptor = try #require(AgentToolRegistry.descriptor(for: "embedded_browser_extract"))
        #expect(descriptor.risk == .read)
        #expect(descriptor.parameters.contains { $0.name == "selector" && $0.required })
    }
}
