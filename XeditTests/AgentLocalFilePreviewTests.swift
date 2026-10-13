import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import WillDeep

@Suite("工作面板本地 HTML 与超限文件", .serialized)
struct AgentLocalFilePreviewTests {
    @Test("HTML 超过旧 64 KB 上限后仍完整读取，1 MB 边界可预览")
    func htmlReadsThroughOneMegabyte() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("中文流程图.HTML")
        let prefix = "<!doctype html><html><head></head><body>"
        let suffix = "<p id='tail'>完整结尾</p></body></html>"
        let padding = AgentLocalFilePreview.maximumHTMLBytes - prefix.utf8.count - suffix.utf8.count
        let html = prefix + String(repeating: " ", count: padding) + suffix
        try Data(html.utf8).write(to: url)
        #expect(AgentLocalFilePreview.loadHTML(at: url) == .html(html))
    }

    @Test("超过 1 MB 与二进制 HTML 返回不可预览，文件本身保持原样")
    func oversizedAndBinaryHTMLRemainAvailableOnDisk() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("too-large.htm")
        let data = Data(repeating: 97, count: AgentLocalFilePreview.maximumHTMLBytes + 1)
        try data.write(to: url)
        #expect(AgentLocalFilePreview.loadHTML(at: url) == .unavailable(L10n.FilePreview.htmlTooLarge))
        #expect(try Data(contentsOf: url) == data)
        try Data([60, 0, 62]).write(to: url)
        #expect(AgentLocalFilePreview.loadHTML(at: url) == .unavailable(L10n.FilePreview.invalidText))
    }

    @Test("缺失文件与符号链接退回文件操作，路径不能越出工作区")
    func invalidFilesAndEscapingPaths() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing.html")
        guard case .unavailable = AgentLocalFilePreview.loadHTML(at: missing) else {
            Issue.record("Missing file should not render")
            return
        }
        let source = root.appendingPathComponent("source.html")
        let link = root.appendingPathComponent("link.html")
        try Data("<p>Hello</p>".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(AgentLocalFilePreview.loadHTML(at: link) == .unavailable(L10n.FilePreview.unreadable))
        #expect(AgentLocalFilePreview.fileURL(path: "../outside.html", repositoryRoot: root) == nil)
        #expect(AgentLocalFilePreview.fileURL(path: "nested/中文.html", repositoryRoot: root)?.path.hasSuffix("/nested/中文.html") == true)
    }

    @Test("选中单文件支持 64 KB 到 1 MB，批量预览仍使用原预算")
    func selectedDiffHasIndependentBudget() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "diagram.html"
        let html = "<html>" + String(repeating: "x", count: 100_000) + "</html>"
        try Data(html.utf8).write(to: root.appendingPathComponent(path))
        let change = AgentFileChangeSummary(path: path, kind: .untracked, lineStats: AgentLineChangeStats(added: 1, deleted: 0))
        #expect(AgentGitReviewLoader.loadDetail(scope: .uncommitted, change: change, repositoryRoot: root) == .text(AppState.syntheticUntrackedDiff(path: path, text: html)))
        guard case .summaryReason = AppState.loadUntrackedDiffPreviewSection(change, repositoryRoot: root) else {
            Issue.record("Combined review should keep its small-file budget")
            return
        }
        try Data(repeating: 97, count: AgentLocalFilePreview.maximumHTMLBytes + 1).write(to: root.appendingPathComponent(path))
        guard case .unavailable = AgentGitReviewLoader.loadDetail(scope: .uncommitted, change: change, repositoryRoot: root) else {
            Issue.record("Selected detail must stop above 1 MB")
            return
        }
    }

    @MainActor
    @Test("真实 WebKit 页面保留 CSS 与交互脚本并渲染超过 64 KB 的 HTML")
    func rendersStyledHTML() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preview.html")
        let html = "<!doctype html><!-- <head>example</head> --><html><head><style>#diagram {font-size:37px}</style></head><body><div id='diagram'>图表</div><script>document.getElementById('diagram').dataset.ready='yes'</script><!--" + String(repeating: "x", count: 90_000) + "--></body></html>"
        try Data(html.utf8).write(to: url)
        let view = NSHostingView(rootView: AgentHTMLFilePreviewView(fileURL: url))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        for _ in 0..<100 {
            view.layoutSubtreeIfNeeded()
            if let webView = findWebView(in: view),
               let result = try? await webView.evaluateJavaScript("document.getElementById('diagram')?.dataset.ready + ':' + (document.getElementById('diagram') ? getComputedStyle(document.getElementById('diagram')).fontSize : '')"),
               result as? String == "yes:37px" {
                #expect(webView.configuration.userContentController.userScripts.isEmpty)
                #expect(!webView.configuration.websiteDataStore.isPersistent)
                let standardsMode = try await webView.evaluateJavaScript("document.compatMode")
                #expect(standardsMode as? String == "CSS1Compat")
                let policy = try await webView.evaluateJavaScript("document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]').content")
                #expect((policy as? String)?.contains("connect-src 'none'") == true)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("HTML did not render with inline CSS and scripts")
    }

    @MainActor
    @Test("文件卡片提供浅色、深色、窄面板渲染样本")
    func rendersFallbackCards() throws {
        for (name, width, scheme) in [("light", 520.0, ColorScheme.light), ("dark", 520.0, .dark), ("narrow", 280.0, .light)] {
            let view = NSHostingView(rootView: AgentFilePreviewUnavailableView(
                fileURL: URL(fileURLWithPath: "/Users/demo/Workspace/reports/系统流程图.html"),
                reason: L10n.FilePreview.htmlTooLarge
            ).environment(\.colorScheme, scheme))
            view.frame = NSRect(x: 0, y: 0, width: width, height: 440)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(!data.isEmpty)
            try data.write(to: URL(fileURLWithPath: "/private/tmp/willdeep-file-preview-\(name).png"))
        }
    }

    @MainActor private func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews {
            if let webView = findWebView(in: child) { return webView }
        }
        return nil
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("willdeep-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
