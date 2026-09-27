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

    func open(payload: AgentTranscriptMediaPayload) {
        let key = payload.url.path
        if let existing = controllers[key] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = AgentTranscriptMediaPlayerWindowController(payload: payload)
        controller.onClose = { [weak self] in
            self?.controllers.removeValue(forKey: key)
        }
        controllers[key] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class AgentTranscriptMediaPlayerWindowController: NSWindowController, NSWindowDelegate {
    private enum Metrics {
        static let videoContentSize = NSSize(width: 640, height: 360)
        static let audioContentSize = NSSize(width: 420, height: 64)
        static let minimumVideoSize = NSSize(width: 320, height: 180)
        static let minimumAudioSize = NSSize(width: 300, height: 64)
    }

    var onClose: (() -> Void)?
    private let player: AVPlayer
    private var keyMonitor: Any?

    init(payload: AgentTranscriptMediaPayload) {
        player = AVPlayer(url: payload.url)
        player.actionAtItemEnd = .pause
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        playerView.showsFullScreenToggleButton = payload.kind == .video
        playerView.allowsPictureInPicturePlayback = false

        let contentSize = payload.kind == .video ? Metrics.videoContentSize : Metrics.audioContentSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = payload.url.lastPathComponent
        window.representedURL = payload.url
        window.contentView = playerView
        window.contentMinSize = payload.kind == .video ? Metrics.minimumVideoSize : Metrics.minimumAudioSize
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
        keyMonitor = AuxiliaryWindowCloseShortcut.install(on: window, closesOnEscape: true)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
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
