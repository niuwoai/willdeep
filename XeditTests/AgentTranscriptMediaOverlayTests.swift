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
        // The picture has no controls of its own; the strip below does.
        #expect(container.playerView?.player === container.player)
        #expect(container.playerView?.controlsStyle == AVPlayerViewControlsStyle.none)
        #expect(container.controlBar.fullScreenButton != nil)
        Self.expectVisibleVolumeControl(in: container)

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
        let player = before.player
        #expect(before.playerView == nil)
        before.controlBar.volumeSlider.doubleValue = 0.25
        before.controlBar.changeVolume(before.controlBar.volumeSlider)

        // Search highlighting and a new message both replace the whole
        // attributed string.
        host.view.applySearch(query: "录音", activeMatchIndex: 0, isDark: false)
        host.view.applyMessages([assistant, AgentMessage(role: .user, content: "收到")], isDark: false)
        host.view.layoutSubtreeIfNeeded()

        let after = try #require(host.mountedContainers.first)
        #expect(after === before)
        #expect(after.player === player)
        #expect(after.player.volume == 0.25)
        #expect(after.controlBar.volumeSlider.doubleValue == 0.25)
        #expect(after.frame == host.placeholderFrame())
    }

    @Test
    func everyMountedPlayerHasItsOwnVisibleVolumeControl() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        // A landscape clip, a narrow portrait-width clip and an audio bar.
        let video = try fixture.file("wide.mp4")
        let song = try fixture.file("song.m4a")
        let host = TranscriptHost(height: 1_400)
        defer { host.close() }
        AgentTranscriptMediaSizeCache.store(CGSize(width: 1080, height: 1920), forPath: video.path)
        defer { AgentTranscriptMediaSizeCache.store(nil, forPath: video.path) }

        host.view.applyMessages([
            AgentMessage(role: .assistant, content: "竖屏：\n\n![竖屏](\(video.path))\n\n音频：\n\n[音频](\(song.path))"),
        ], isDark: false)
        host.view.layoutSubtreeIfNeeded()

        let containers = host.mountedContainers
        #expect(containers.count == 2)
        for container in containers {
            Self.expectVisibleVolumeControl(in: container)
        }
        let narrow = try #require(containers.first { $0.playerView != nil })
        #expect(narrow.frame.width < AgentTranscriptMediaMetrics.maxDisplayWidth)
    }

    @Test
    func eachVolumeSliderDrivesOnlyItsOwnPlayer() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let first = try fixture.file("first.mp3")
        let second = try fixture.file("second.mp3")
        let host = TranscriptHost()
        defer { host.close() }

        host.view.applyMessages([
            AgentMessage(role: .assistant, content: "[一](\(first.path))\n\n[二](\(second.path))"),
        ], isDark: false)
        host.view.layoutSubtreeIfNeeded()
        let containers = host.mountedContainers.sorted { $0.frame.minY < $1.frame.minY }
        #expect(containers.count == 2)
        let top = try #require(containers.first)
        let bottom = try #require(containers.last)

        top.controlBar.volumeSlider.doubleValue = 0.3
        top.controlBar.changeVolume(top.controlBar.volumeSlider)
        #expect(top.player.volume == 0.3)
        #expect(bottom.player.volume == 1)

        bottom.controlBar.toggleMute(nil)
        #expect(bottom.player.isMuted)
        #expect(!top.player.isMuted)
        #expect(bottom.controlBar.volumeSlider.doubleValue == 0)
        #expect(abs(top.controlBar.volumeSlider.doubleValue - 0.3) < Self.floatTolerance)
    }

    @Test
    func evictedPlayerComesBackWithItsVolume() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let clip = try fixture.file("resumed.m4a")
        let resume = AgentTranscriptMediaResumeState(seconds: 0, volume: 0.4, isMuted: true)

        let entry = AgentTranscriptMediaPlayerEntry(
            mediaID: "m#media-0",
            url: clip,
            kind: .audio,
            displayName: "resumed",
            resumeState: resume
        )
        defer { entry.tearDown() }
        #expect(entry.player.volume == 0.4)
        #expect(entry.player.isMuted)
        #expect(entry.resumeState.volume == 0.4)
        // Muted reads as silent on the slider; unmuting restores 0.4.
        #expect(entry.view.controlBar.volumeSlider.doubleValue == 0)
        entry.view.controlBar.toggleMute(nil)
        #expect(abs(entry.view.controlBar.volumeSlider.doubleValue - 0.4) < Self.floatTolerance)
    }

    /// `AVPlayer.volume` is a Float; the slider is a Double.
    private static let floatTolerance = 0.000_1

    @Test
    func evictionRemovesTheTimeObserver() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let entry = AgentTranscriptMediaPlayerEntry(
            mediaID: "m#media-0",
            url: try fixture.file("detached.mp4"),
            kind: .video,
            displayName: "detached",
            resumeState: nil
        )
        #expect(entry.view.controlBar.isBound)
        entry.tearDown()
        #expect(!entry.view.controlBar.isBound)
        #expect(entry.view.playerView?.player == nil)
    }

    /// The volume slider and mute button are on screen: not hidden, a real
    /// width, and inside the container's (clipped) bounds.
    private static func expectVisibleVolumeControl(in container: AgentTranscriptMediaPlayerContainerView) {
        let bar = container.controlBar
        for control in [bar.volumeSlider, bar.muteButton] as [NSView] {
            #expect(!control.isHiddenOrHasHiddenAncestor)
            #expect(control.frame.width > 0)
            let inContainer = container.convert(control.frame, from: bar)
            #expect(container.bounds.contains(inContainer), "\(inContainer) outside \(container.bounds)")
        }
        #expect(bar.frame.maxY == container.bounds.maxY)
        #expect(bar.frame.height == AgentTranscriptMediaControlMetrics.barHeight)
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
        let player = container.player
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
        let player = try #require(host.mountedContainers.first?.player)
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
