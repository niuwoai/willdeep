//
//  AgentTranscriptMediaPlayerWindow.swift
//  WillDeep
//
//  A small standalone player for media placeholders that have no inline
//  player: the reader windows (plain NSTextViews that reuse the renderer but
//  not the overlay), and chat placeholders beyond the live-player cap.
//

import AppKit
import AVKit
import Foundation
import SwiftUI

@MainActor
final class AgentTranscriptMediaPlayerWindowRegistry {
    static let shared = AgentTranscriptMediaPlayerWindowRegistry()

    private var controllers: [String: AgentTranscriptMediaPlayerWindowController] = [:]

    /// Opens (or brings forward) the window for `payload`. `resumeState`
    /// starts it where an inline player left off; `onFinish` gets the final
    /// position and volume back when the window closes.
    func open(
        payload: AgentTranscriptMediaPayload,
        resumeState: AgentTranscriptMediaResumeState? = nil,
        entersFullScreen: Bool = false,
        onFinish: ((AgentTranscriptMediaResumeState) -> Void)? = nil
    ) {
        let key = payload.url.path
        if let existing = controllers[key] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            if entersFullScreen, existing.window?.styleMask.contains(.fullScreen) == false {
                existing.window?.toggleFullScreen(nil)
            }
            return
        }
        let controller = AgentTranscriptMediaPlayerWindowController(payload: payload, resumeState: resumeState)
        controller.onFinish = onFinish
        controller.onClose = { [weak self] in
            self?.controllers.removeValue(forKey: key)
        }
        controllers[key] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if resumeState != nil {
            controller.play()
        }
        if entersFullScreen {
            controller.window?.toggleFullScreen(nil)
        }
    }
}

@MainActor
private final class AgentTranscriptMediaPlayerWindowController: NSWindowController, NSWindowDelegate {
    private enum Metrics {
        static let videoContentSize = NSSize(
            width: 640,
            height: 360 + AgentTranscriptMediaControlMetrics.barHeight
        )
        static let audioContentSize = NSSize(width: 420, height: AgentTranscriptMediaControlMetrics.barHeight)
        static let minimumVideoSize = NSSize(
            width: 320,
            height: 180 + AgentTranscriptMediaControlMetrics.barHeight
        )
        static let minimumAudioSize = NSSize(width: 300, height: AgentTranscriptMediaControlMetrics.barHeight)
    }

    var onClose: (() -> Void)?
    var onFinish: ((AgentTranscriptMediaResumeState) -> Void)?
    private let player: AVPlayer
    private let container: AgentTranscriptMediaPlayerContainerView
    private var keyMonitor: Any?

    init(payload: AgentTranscriptMediaPayload, resumeState: AgentTranscriptMediaResumeState?) {
        player = AVPlayer(url: payload.url)
        player.actionAtItemEnd = .pause
        if let resumeState {
            AgentTranscriptMediaPlayerEntry.apply(resumeState, to: player)
        }
        // Same picture + strip as inline, so volume is always on screen here too.
        container = AgentTranscriptMediaPlayerContainerView(
            player: player,
            kind: payload.kind,
            url: payload.url,
            roundsCorners: false
        )
        container.controlBar.refreshFromPlayer()

        let contentSize = payload.kind == .video ? Metrics.videoContentSize : Metrics.audioContentSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = payload.url.lastPathComponent
        window.representedURL = payload.url
        window.contentView = container
        window.contentMinSize = payload.kind == .video ? Metrics.minimumVideoSize : Metrics.minimumAudioSize
        if payload.kind == .video {
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        container.onFullScreen = { [weak window] in window?.toggleFullScreen(nil) }
        keyMonitor = AuxiliaryWindowCloseShortcut.install(on: window, closesOnEscape: true)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func play() {
        player.play()
    }

    func windowWillClose(_ notification: Notification) {
        let seconds = player.currentTime().seconds
        onFinish?(AgentTranscriptMediaResumeState(
            seconds: seconds.isFinite ? seconds : 0,
            volume: player.volume,
            isMuted: player.isMuted
        ))
        player.pause()
        container.detachPlayer()
        player.replaceCurrentItem(with: nil)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        onClose?()
    }
}

// MARK: - Reader windows

// The reader windows render with `AgentChatHistoryRenderer` into plain
// NSTextViews; their clicks on a placeholder or a "Show in Finder" link land
// here. Anything else keeps AppKit's default link handling.
extension AgentTranscriptReaderWindowController: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        AgentTranscriptMediaLinkRouter.handleClick(in: textView, at: charIndex)
    }
}

extension AgentSingleMessageReaderWindowController: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        AgentTranscriptMediaLinkRouter.handleClick(in: textView, at: charIndex)
    }
}

// MARK: - Markdown preview

/// `.media` block in the editor's Markdown preview and other SwiftUI block
/// renderers: a compact row that opens the file, since those surfaces have
/// no TextKit overlay to host a player.
struct MarkdownMediaBlockView: View {
    let media: MarkdownMediaReference?
    var typography: MarkdownPreviewTypography = .editorDefault
    var baseURL: URL? = nil

    var body: some View {
        if let media {
            let url = AgentTranscriptMediaResolver.localFileURL(for: media.source, relativeTo: baseURL)
            HStack(spacing: 6) {
                Image(systemName: media.kind == .video ? "film" : "waveform")
                Text(media.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: typography.baseFontSize))
            .foregroundColor(url == nil ? .secondary : .accentColor)
            .contentShape(Rectangle())
            .onTapGesture {
                if let url { _ = NSWorkspace.shared.open(url) }
            }
            .help(url?.path ?? media.source)
            .padding(.vertical, 2)
        }
    }
}
