//
//  AgentChatHistoryLongTokenTests.swift
//  WillDeepTests
//
//  不变量：**TextKit 历史渲染不往正文里插零宽断点**。
//
//  背景：`AgentLongTokenBreaker` 是给 SwiftUI Text 防卡死的（遇到不含天然
//  断点的字符连续超过 30 个就插 U+200B），1.52.1-rc18 被原样搬进了 TextKit
//  formatter，但 NSTextView 的 byWordWrapping 碰到超长单词本来就会退回按
//  字符断行，不需要它。插进去的 U+200B 反而：
//    1. 让会话内搜索（在渲染串上匹配）搜不到 64 位哈希、40 位 commit；
//    2. 让路径 chip 只认出 30 字符之后的半截文件名；
//    3. 跟着链接目标被百分号编码成 %E2%80%8B 写进 URL；
//    4. 跟着表格 payload 进独立表格窗口；
//    5. 把紧跟在 29 字符单词后面的 `**` 劈开，粗体失效、星号原样露出。
//  最后一项测的是拿掉断行器之后大消息照样不卡——那是它当年存在的理由。
//

import AppKit
import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentChatHistoryLongTokenTests {

    private static let zwsp = "\u{200B}"
    private static let sha256 = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
    private static let commit = "94681448348c48c46f7e754df8f555a8f2525569"
    private static let longSwiftPath = "Xedit/AppStateAgentBackgroundCompletionDelivery.swift"

    private static func render(_ messages: [AgentMessage]) -> NSAttributedString {
        AgentChatHistoryRenderer.render(messages: messages, isDark: false)
    }

    // MARK: - 正文

    @Test("user 气泡与助手正文都不含 U+200B")
    func renderedBodiesCarryNoZeroWidthBreakpoints() {
        let content = "校验和 \(Self.sha256)，提交 \(Self.commit)，见 \(Self.longSwiftPath)"
        let rendered = Self.render([
            AgentMessage(role: .user, content: content),
            AgentMessage(role: .assistant, content: content),
        ])
        #expect(!rendered.string.contains(Self.zwsp))
        #expect(occurrences(of: Self.sha256, in: rendered.string) == 2)
    }

    @Test("紧跟在 29 字符单词后面的 ** 仍被当成粗体标记，不原样露出")
    func boldMarkerRightAfterLongWordIsNotLeaked() {
        let word = "abcdefghijklmnopqrstuvwxyzabc"
        #expect(word.count == 29)
        let rendered = Self.render([
            AgentMessage(role: .assistant, content: "\(word)**重点**结束"),
        ])
        #expect(rendered.string.contains("\(word)重点结束"))
        #expect(!rendered.string.contains("*"))
    }

    // MARK: - 会话内搜索

    @Test("会话内搜索能命中 64 位哈希和 40 位 commit")
    func transcriptSearchFindsLongHashes() {
        let rendered = Self.render([
            AgentMessage(role: .assistant, content: "sha256 是 \(Self.sha256)，对应提交 \(Self.commit)。"),
        ])
        #expect(AgentTranscriptSearch.matchRanges(in: rendered.string, query: Self.sha256).count == 1)
        #expect(AgentTranscriptSearch.matchRanges(in: rendered.string, query: Self.commit).count == 1)
    }

    // MARK: - 路径 chip

    @Test("超过 30 字符的文件名，路径 chip 覆盖完整路径")
    func pathChipCoversWholeLongFileName() throws {
        let rendered = Self.render([
            AgentMessage(role: .assistant, content: "改动在 \(Self.longSwiftPath) 里。"),
        ])
        let range = try #require(firstAttributeRange(
            .agentChatHistoryFilePath,
            value: Self.longSwiftPath,
            in: rendered
        ))
        #expect((rendered.string as NSString).substring(with: range) == Self.longSwiftPath)
    }

    // MARK: - 链接

    @Test("链接目标原样保留，不带 %E2%80%8B")
    func markdownLinkTargetStaysVerbatim() throws {
        let target = "https://github.com/niuwoai/willdeep/commit/\(Self.commit)"
        let rendered = Self.render([
            AgentMessage(role: .assistant, content: "详见 [这次提交](\(target))。"),
        ])
        var urls: [URL] = []
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let url = value as? URL { urls.append(url) }
        }
        let url = try #require(urls.first)
        #expect(url.absoluteString == target)
        #expect(!url.absoluteString.contains("%E2%80%8B"))
    }

    // MARK: - 表格 payload

    @Test("表格 payload 不带零宽字符进独立窗口")
    func tablePayloadCarriesNoZeroWidth() throws {
        let content = """
        | 提交 | 校验和 |
        | --- | --- |
        | \(Self.commit) | \(Self.sha256) |
        """
        let rendered = Self.render([AgentMessage(role: .assistant, content: content)])
        var payloads: [AgentMarkdownTablePayload] = []
        rendered.enumerateAttribute(
            .agentChatHistoryTablePayload,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            if let payload = value as? AgentMarkdownTablePayload { payloads.append(payload) }
        }
        let payload = try #require(payloads.first)
        #expect(payload.rows == [[Self.commit, Self.sha256]])
        #expect(!(payload.headers + payload.rows.flatMap { $0 }).joined().contains(Self.zwsp))
    }

    // MARK: - 大消息不卡

    /// 当年断行器要防的就是这种：pnpm store 列表，每行一段 126 位十六进制。
    /// 3000 行约 49 万字符，user 气泡和助手正文各一份，渲染 + 整篇排版一次。
    ///
    /// 2026-09-26 本机实测（负载均值 45~110，别的会话在并行编译）：渲染约
    /// 1.3~1.6 秒，ensureLayout 约 1.6~1.8 秒。同一进程里先把内容过一遍
    /// `AgentLongTokenBreaker` 再渲染（等于断行器还接在 TextKit 路径上），
    /// 排版耗时不变，渲染却要 17.5 秒，插零宽在这条路径上只会拖慢。
    /// 上限 15 秒：比修复后满载实测高 4 倍，扛得住并行跑测试的 CPU
    /// 争抢，又低于断行器接回来之后的耗时。
    private static let largeMessageBudgetSeconds: TimeInterval = 15
    private static let pnpmLineCount = 3000

    @Test("pnpm 3000 行级别的大消息：渲染 + 排版不卡、不溢出")
    @MainActor
    func pnpmStoreListingRendersAndLaysOutWithinBudget() {
        let listing = Self.pnpmStoreListing(lineCount: Self.pnpmLineCount)
        #expect(listing.count > 450_000)
        let width = AgentChatHistoryLayoutMetrics.defaultTranscriptWidth / 2

        let clock = ContinuousClock()
        var rendered = NSAttributedString()
        var usedRect = NSRect.zero
        var glyphBounds = NSRect.zero
        let elapsed = clock.measure {
            rendered = AgentChatHistoryRenderer.render(
                messages: [
                    AgentMessage(role: .user, content: listing),
                    AgentMessage(role: .assistant, content: listing),
                ],
                isDark: false,
                layoutWidth: width
            )
            let storage = NSTextStorage(attributedString: rendered)
            let layoutManager = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(layoutManager)
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)
            usedRect = layoutManager.usedRect(for: container)
            glyphBounds = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs),
                in: container
            )
        }

        #expect(!rendered.string.contains(Self.zwsp))
        #expect(occurrences(of: "-index.json", in: rendered.string) == Self.pnpmLineCount * 2)
        // byWordWrapping 碰到超长单词自己退回按字符断行：一行也不许伸出容器。
        #expect(usedRect.width <= width + 0.5)
        #expect(glyphBounds.maxX <= width + 0.5)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        #expect(seconds < Self.largeMessageBudgetSeconds, "render + layout took \(seconds)s")
    }

    /// 形如 `.pnpm-store/v10/files/3f/<126 位十六进制>-index.json`，
    /// 用固定种子的 splitmix64 生成，每次跑都是同一份语料。
    private static func pnpmStoreListing(lineCount: Int) -> String {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextHex(_ count: Int) -> String {
            let digits = Array("0123456789abcdef")
            var out = ""
            out.reserveCapacity(count)
            while out.count < count {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                z ^= z >> 31
                for shift in stride(from: 0, to: 64, by: 4) where out.count < count {
                    out.append(digits[Int((z >> UInt64(shift)) & 0xF)])
                }
            }
            return out
        }
        return (0..<lineCount)
            .map { _ in ".pnpm-store/v10/files/\(nextHex(2))/\(nextHex(126))-index.json" }
            .joined(separator: "\n")
    }
}
