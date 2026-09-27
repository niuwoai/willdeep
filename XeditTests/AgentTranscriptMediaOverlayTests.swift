//
//  AgentTranscriptMediaOverlayTests.swift
//  WillDeepTests
//
//  The players laid over the TextKit transcript: placement math, the
//  id-keyed pool, and an offscreen end-to-end pass that mounts a real
//  AVPlayerView over a real placeholder and keeps it across a whole-string
//  swap.
//

import AppKit
import AVKit
import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentTranscriptMediaOverlayTests {

    // MARK: - Placement math

    @Test
    func playerSitsOnTheBaselineOfItsLineFragment() {
        // Baseline 320pt into a fragment that starts at y=100: a 315pt-tall
        // attachment spans y 105…420.
        let frame = AgentTranscriptMediaLayout.playerFrame(
            lineFragmentRect: NSRect(x: 0, y: 100, width: 600, height: 330),
            glyphLocation: NSPoint(x: 32, y: 320),
            attachmentSize: NSSize(width: 560, height: 315),
            textContainerOrigin: .zero
        )
        #expect(frame == NSRect(x: 32, y: 105, width: 560, height: 315))
    }

    @Test
    func textContainerOriginOffsetsThePlayer() {
        let frame = AgentTranscriptMediaLayout.playerFrame(
            lineFragmentRect: NSRect(x: 0, y: 0, width: 600, height: 50),
            glyphLocation: NSPoint(x: 10, y: 40),
            attachmentSize: NSSize(width: 300, height: 40),
            textContainerOrigin: NSPoint(x: 16, y: 16)
        )
        #expect(frame == NSRect(x: 26, y: 16, width: 300, height: 40))
    }

    // MARK: - Pool

    private final class Token {
        let id: String
        init(_ id: String) { self.id = id }
    }

    @Test
    func sameIDReusesTheSameEntry() {
        let pool = AgentTranscriptMediaPlayerPool<Token>(capacity: 3)
        var made = 0
        let first = pool.acquire(id: "a", protected: ["a"]) { made += 1; return Token("a") }
        let second = pool.acquire(id: "a", protected: ["a"]) { made += 1; return Token("a") }
        #expect(first.entry === second.entry)
        #expect(made == 1)
        #expect(second.evicted.isEmpty)
    }

    @Test
    func fullPoolEvictsTheLeastRecentlyUsedUnprotectedEntry() {
        let pool = AgentTranscriptMediaPlayerPool<Token>(capacity: 2)
        _ = pool.acquire(id: "a", protected: []) { Token("a") }
        _ = pool.acquire(id: "b", protected: []) { Token("b") }
        // Touch "a" so "b" becomes the oldest.
        _ = pool.acquire(id: "a", protected: []) { Token("a") }
        let third = pool.acquire(id: "c", protected: ["c"]) { Token("c") }
        #expect(third.entry?.id == "c")
        #expect(third.evicted.map(\.id) == ["b"])
        #expect(pool.entry(for: "a") != nil)
        #expect(pool.entry(for: "b") == nil)
        #expect(pool.count == 2)
    }

    @Test
    func protectedEntriesAreNeverEvicted() {
        let pool = AgentTranscriptMediaPlayerPool<Token>(capacity: 2)
        _ = pool.acquire(id: "a", protected: []) { Token("a") }
        _ = pool.acquire(id: "b", protected: []) { Token("b") }
        let refused = pool.acquire(id: "c", protected: ["a", "b", "c"]) { Token("c") }
        #expect(refused.entry == nil)
        #expect(refused.evicted.isEmpty)
        #expect(pool.count == 2)
    }

    // MARK: - Offscreen end-to-end

    @Test
    func playerViewIsMountedExactlyOverThePlaceholder() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let clip = try fixture.file("mounted.mp4")
        let host = TranscriptHost()
        defer { host.close() }

        host.view.applyMessages([
            AgentMessage(role: .assistant, content: "演示如下：\n\n![演示](\(clip.path))\n\n以上。"),
        ], isDark: false)
        host.view.layoutSubtreeIfNeeded()

        let containers = host.mountedContainers
        #expect(containers.count == 1)
        let container = try #require(containers.first)
        #expect(container.playerView.player != nil)
        #expect(container.playerView.controlsStyle == .inline)

        let expected = try #require(host.placeholderFrame())
        #expect(container.frame == expected)
        let cell = try #require(host.placeholderCell())
        #expect(container.frame.size == NSSize(
            width: cell.displaySize.width.rounded(),
            height: cell.displaySize.height.rounded()
        ))
    }

    @Test
    func wholeStringSwapKeepsTheSamePlayer() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let clip = try fixture.file("kept.m4a")
        let host = TranscriptHost()
        defer { host.close() }
        let assistant = AgentMessage(role: .assistant, content: "录音：\n\n[录音](\(clip.path))")

        host.view.applyMessages([assistant], isDark: false)
        host.view.layoutSubtreeIfNeeded()
        let before = try #require(host.mountedContainers.first)
        let player = try #require(before.playerView.player)
        player.volume = 0.25

        // Search highlighting and a new message both replace the whole
        // attributed string.
        host.view.applySearch(query: "录音", activeMatchIndex: 0, isDark: false)
        host.view.applyMessages([assistant, AgentMessage(role: .user, content: "收到")], isDark: false)
        host.view.layoutSubtreeIfNeeded()

        let after = try #require(host.mountedContainers.first)
        #expect(after === before)
        #expect(after.playerView.player === player)
        #expect(after.playerView.player?.volume == 0.25)
        #expect(after.frame == host.placeholderFrame())
    }

    @Test
    func livePlayersAreCapped() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let lines = try (0..<(AgentTranscriptMediaMetrics.maxLivePlayers + 3)).map { index in
            "[第\(index)段](\(try fixture.file("track-\(index).mp3").path))"
        }
        let host = TranscriptHost(height: 2_000)
        defer { host.close() }

        host.view.applyMessages([
            AgentMessage(role: .assistant, content: "全部音轨：\n\n" + lines.joined(separator: "\n\n")),
        ], isDark: false)
        host.view.layoutSubtreeIfNeeded()

        #expect(host.mountedContainers.count == AgentTranscriptMediaMetrics.maxLivePlayers)
        #expect(host.view.mediaOverlay.pool.count == AgentTranscriptMediaMetrics.maxLivePlayers)
    }

    @Test
    func scrollingAwayPausesAndUnmountsThePlayer() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let clip = try fixture.file("scrolled.mp4")
        let host = TranscriptHost(height: 600, documentHeight: 12_000)
        defer { host.close() }
        let filler = (0..<300).map { "第 \($0) 段填充文字。" }.joined(separator: "\n\n")

        host.view.applyMessages([
            AgentMessage(role: .assistant, content: "![开头](\(clip.path))\n\n" + filler),
        ], isDark: false)
        host.view.layoutSubtreeIfNeeded()
        let container = try #require(host.mountedContainers.first)
        let player = try #require(container.playerView.player)
        player.play()
        #expect(player.rate != 0)

        host.scroll(toY: 9_000)
        host.view.mediaOverlay.syncNow()

        #expect(container.superview == nil)
        #expect(player.rate == 0)
    }

    @Test
    func closingTheWindowPausesEveryPlayer() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let clip = try fixture.file("closing.mov")
        let host = TranscriptHost()

        host.view.applyMessages([
            AgentMessage(role: .assistant, content: "看：\n\n![](\(clip.path))"),
        ], isDark: false)
        host.view.layoutSubtreeIfNeeded()
        let player = try #require(host.mountedContainers.first?.playerView.player)
        player.play()
        #expect(player.rate != 0)

        host.close()
        #expect(player.rate == 0)
    }
}

/// An offscreen window hosting the transcript text view inside a scroll
/// view, the way the chat pane's SwiftUI ScrollView does.
@MainActor
private final class TranscriptHost {
    let window: NSWindow
    let scrollView: NSScrollView
    let view: AgentChatHistoryNSTextView

    init(height: CGFloat = 800, documentHeight: CGFloat? = nil) {
        let size = NSSize(width: 800, height: height)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        view = AgentChatHistoryNSTextView()
        view.frame = NSRect(x: 0, y: 0, width: size.width, height: documentHeight ?? size.height)
        scrollView.documentView = view
        window.contentView = scrollView
    }

    var mountedContainers: [AgentTranscriptMediaPlayerContainerView] {
        view.subviews.compactMap { $0 as? AgentTranscriptMediaPlayerContainerView }
    }

    func placeholderLocation() -> Int? {
        guard let storage = view.textStorage else { return nil }
        var found: Int?
        storage.enumerateAttribute(
            .agentChatHistoryMedia,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            if value != nil {
                found = range.location
                stop.pointee = true
            }
        }
        return found
    }

    func placeholderFrame() -> NSRect? {
        guard let location = placeholderLocation(),
              let layoutManager = view.layoutManager,
              let textContainer = view.textContainer else {
            return nil
        }
        return AgentTranscriptMediaLayout.playerFrame(
            forCharacterAt: location,
            layoutManager: layoutManager,
            textContainer: textContainer,
            textContainerOrigin: view.textContainerOrigin
        )
    }

    func placeholderCell() -> AgentTranscriptMediaAttachmentCell? {
        guard let location = placeholderLocation(),
              let attachment = view.textStorage?.attribute(.attachment, at: location, effectiveRange: nil)
                as? NSTextAttachment else {
            return nil
        }
        return attachment.attachmentCell as? AgentTranscriptMediaAttachmentCell
    }

    func scroll(toY y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func close() {
        window.close()
    }
}
