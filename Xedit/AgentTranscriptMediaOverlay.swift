//
//  AgentTranscriptMediaOverlay.swift
//  WillDeep
//
//  Real players over the transcript's media placeholders. After every text
//  change, width change or scroll, the controller asks the layout manager
//  where each placeholder landed and moves one `AVPlayerView` per media id
//  there. Each id owns its own AVPlayer, so play/pause, position and volume
//  are independent — starting one never pauses another.
//
//  Lifecycle rules:
//  - Players live in a pool keyed by media id, so a whole-string swap
//    (hover, search, expand) keeps position and volume.
//  - Views exist only for placeholders near the viewport, and at most
//    `AgentTranscriptMediaMetrics.maxLivePlayers` at a time.
//  - A player that leaves the viewport, or whose window closes, pauses.
//

import AppKit
import AVFoundation
import AVKit
import Foundation

// MARK: - Pool

/// LRU pool keyed by media id. Generic so the reuse / eviction policy is
/// testable without creating AVPlayers.
@MainActor
final class AgentTranscriptMediaPlayerPool<Entry: AnyObject> {
    let capacity: Int
    private(set) var entries: [String: Entry] = [:]
    /// Least recently used first.
    private var recency: [String] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { entries.count }

    func entry(for id: String) -> Entry? {
        entries[id]
    }

    /// Returns the existing entry for `id` or creates one. When the pool is
    /// full, the least recently used entry *not* in `protected` is evicted
    /// and handed back so the caller can tear it down. Returns a nil entry
    /// when every slot is protected.
    func acquire(
        id: String,
        protected: Set<String>,
        make: () -> Entry
    ) -> (entry: Entry?, evicted: [Entry]) {
        if let existing = entries[id] {
            touch(id)
            return (existing, [])
        }
        var evicted: [Entry] = []
        while entries.count >= capacity {
            guard let victimIndex = recency.firstIndex(where: { !protected.contains($0) && $0 != id }) else {
                return (nil, evicted)
            }
            let victimID = recency.remove(at: victimIndex)
            if let victim = entries.removeValue(forKey: victimID) {
                evicted.append(victim)
            }
        }
        let created = make()
        entries[id] = created
        recency.append(id)
        return (created, evicted)
    }

    @discardableResult
    func remove(id: String) -> Entry? {
        recency.removeAll { $0 == id }
        return entries.removeValue(forKey: id)
    }

    func removeAll() -> [Entry] {
        let all = Array(entries.values)
        entries.removeAll()
        recency.removeAll()
        return all
    }

    private func touch(_ id: String) {
        recency.removeAll { $0 == id }
        recency.append(id)
    }
}

// MARK: - Player entry

struct AgentTranscriptMediaResumeState: Equatable {
    let seconds: Double
    let volume: Float
    let isMuted: Bool
}

/// One media id's player and the view that shows it.
@MainActor
final class AgentTranscriptMediaPlayerEntry {
    let mediaID: String
    let url: URL
    let kind: AgentTranscriptMediaKind
    let player: AVPlayer
    let view: AgentTranscriptMediaPlayerContainerView
    private let displayName: String
    private var statusObservation: NSKeyValueObservation?

    init(
        mediaID: String,
        url: URL,
        kind: AgentTranscriptMediaKind,
        displayName: String,
        resumeState: AgentTranscriptMediaResumeState?
    ) {
        self.mediaID = mediaID
        self.url = url
        self.kind = kind
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        // Nothing starts on its own: the transcript is a document, not a feed.
        player.actionAtItemEnd = .pause
        self.player = player
        self.displayName = displayName
        self.view = AgentTranscriptMediaPlayerContainerView(player: player, kind: kind, url: url)
        view.setAccessibilityLabel(displayName)
        if let resumeState {
            Self.apply(resumeState, to: player)
            view.controlBar.refreshFromPlayer()
        }
        view.onFullScreen = { [weak self] in self?.enterFullScreen() }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            let failed = observed.status == .failed
            Task { @MainActor [weak self] in
                self?.view.showsPlaybackFailure = failed
            }
        }
    }

    var resumeState: AgentTranscriptMediaResumeState {
        let seconds = player.currentTime().seconds
        return AgentTranscriptMediaResumeState(
            seconds: seconds.isFinite ? seconds : 0,
            volume: player.volume,
            isMuted: player.isMuted
        )
    }

    static func apply(_ state: AgentTranscriptMediaResumeState, to player: AVPlayer) {
        player.volume = state.volume
        player.isMuted = state.isMuted
        if state.seconds > 0 {
            player.seek(to: CMTime(seconds: state.seconds, preferredTimescale: AgentTranscriptMediaMetrics.timeScale))
        }
    }

    /// AVPlayerView has no public "enter full screen" call once its own
    /// controls are off, so full screen is the standalone player window,
    /// taken full screen at the same position and volume. Closing it hands
    /// the position and volume back to the inline player.
    func enterFullScreen() {
        let state = resumeState
        player.pause()
        AgentTranscriptMediaPlayerWindowRegistry.shared.open(
            payload: AgentTranscriptMediaPayload(localID: mediaID, url: url, kind: kind, displayName: displayName),
            resumeState: state,
            entersFullScreen: true
        ) { [weak self] final in
            guard let self else { return }
            Self.apply(final, to: self.player)
            self.view.controlBar.refreshFromPlayer()
        }
    }

    /// Unconditional: `timeControlStatus` lags a `play()` by a runloop turn,
    /// and a pause that trusted it could leave a just-started clip running.
    func pause() {
        player.pause()
    }

    func tearDown() {
        statusObservation?.invalidate()
        statusObservation = nil
        player.pause()
        view.removeFromSuperview()
        view.detachPlayer()
        player.replaceCurrentItem(with: nil)
    }
}

/// The picture (video only) above an always-visible control strip, with
/// rounded corners and an inline failure notice. Audio is the strip alone.
final class AgentTranscriptMediaPlayerContainerView: NSView {
    let player: AVPlayer
    /// Video only. `.none` controls: it paints the picture, the strip below
    /// owns the playback UI (AVPlayerView's inline volume never shows here).
    let playerView: AVPlayerView?
    let controlBar: AgentTranscriptMediaControlBar
    /// What the strip's full-screen button does (video only).
    var onFullScreen: (() -> Void)?
    private let failureLabel = NSTextField(labelWithString: L10n.TranscriptMedia.unsupportedFormat)
    private let revealButton = NSButton(title: L10n.TranscriptMedia.showInFinder, target: nil, action: nil)
    private let url: URL

    init(player: AVPlayer, kind: AgentTranscriptMediaKind, url: URL, roundsCorners: Bool = true) {
        self.player = player
        self.url = url
        self.controlBar = AgentTranscriptMediaControlBar(player: player, kind: kind)
        if kind == .video {
            let playerView = AVPlayerView()
            playerView.player = player
            playerView.controlsStyle = .none
            playerView.videoGravity = .resizeAspect
            playerView.allowsPictureInPicturePlayback = false
            self.playerView = playerView
        } else {
            self.playerView = nil
        }
        super.init(frame: .zero)
        wantsLayer = true
        if roundsCorners {
            layer?.cornerRadius = AgentTranscriptMediaMetrics.cornerRadius
            layer?.masksToBounds = true
        }
        if let playerView {
            addSubview(playerView)
        }
        addSubview(controlBar)
        controlBar.onFullScreen = { [weak self] in self?.onFullScreen?() }

        failureLabel.textColor = .secondaryLabelColor
        failureLabel.isHidden = true
        revealButton.bezelStyle = .inline
        revealButton.target = self
        revealButton.action = #selector(revealInFinder(_:))
        revealButton.isHidden = true
        let stack = NSStackView(views: [failureLabel, revealButton])
        stack.orientation = .horizontal
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let barHeight = min(bounds.height, AgentTranscriptMediaControlMetrics.barHeight)
        controlBar.frame = NSRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
        playerView?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - barHeight)
    }

    var showsPlaybackFailure = false {
        didSet {
            failureLabel.isHidden = !showsPlaybackFailure
            revealButton.isHidden = !showsPlaybackFailure
            playerView?.isHidden = showsPlaybackFailure
            controlBar.isHidden = showsPlaybackFailure
        }
    }

    /// Drops the picture's player reference and the strip's observers.
    func detachPlayer() {
        playerView?.player = nil
        controlBar.detach()
    }

    @objc private func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Overlay controller

struct AgentTranscriptMediaPlacement: Equatable {
    let id: String
    let url: URL
    let kind: AgentTranscriptMediaKind
    let displayName: String
    let frame: NSRect
}

@MainActor
final class AgentTranscriptMediaOverlayController: NSObject {
    private weak var textView: NSTextView?
    let pool = AgentTranscriptMediaPlayerPool<AgentTranscriptMediaPlayerEntry>(
        capacity: AgentTranscriptMediaMetrics.maxLivePlayers
    )
    private var resumeStates: [String: AgentTranscriptMediaResumeState] = [:]
    private var resumeStateOrder: [String] = []
    private(set) var placements: [AgentTranscriptMediaPlacement] = []
    private var geometryIsStale = true
    /// Starts pending: the controller is created lazily, possibly after the
    /// first content swap it would otherwise have heard about.
    private var syncIsPending = true
    private var asyncSyncScheduled = false
    private var lastKnownFrameSize: NSSize?
    private weak var observedClipView: NSClipView?
    private weak var observedWindow: NSWindow?

    init(textView: NSTextView) {
        self.textView = textView
        super.init()
        let center = NotificationCenter.default
        if let storage = textView.textStorage {
            center.addObserver(
                self,
                selector: #selector(transcriptStorageDidProcessEditing(_:)),
                name: NSTextStorage.didProcessEditingNotification,
                object: storage
            )
        }
        center.addObserver(
            self,
            selector: #selector(mediaMetadataDidLoad(_:)),
            name: .agentTranscriptMediaMetadataDidLoad,
            object: nil
        )
    }

    // MARK: Hooks from the text view

    /// Width or height changed: glyph positions moved. SwiftUI re-applies an
    /// unchanged frame on every layout pass; ignoring those keeps this hook
    /// from feeding a layout loop.
    func textViewFrameDidChange() {
        guard let size = textView?.frame.size, size != lastKnownFrameSize else { return }
        lastKnownFrameSize = size
        invalidateGeometry()
    }

    /// Called from the text view's `layout()`; does the deferred work in the
    /// same pass instead of a frame later.
    func textViewDidLayout() {
        syncIfNeeded()
    }

    func hostWindowDidChange() {
        rebindWindowObservers()
        rebindScrollObserver()
        if textView?.window == nil {
            pauseAll()
        }
        invalidateGeometry()
    }

    // MARK: Sync

    func syncIfNeeded() {
        guard syncIsPending else { return }
        syncNow()
    }

    func syncNow() {
        syncIsPending = false
        guard let textView else { return }
        if geometryIsStale {
            placements = Self.placements(in: textView)
            geometryIsStale = false
        }
        guard !placements.isEmpty || pool.count > 0 else { return }
        // A window-less view (being torn down or not yet shown) plays nothing.
        let visibleRect = textView.window == nil ? NSRect.zero : textView.visibleRect
        let nearRect = visibleRect.isEmpty
            ? NSRect.zero
            : visibleRect.insetBy(dx: 0, dy: -AgentTranscriptMediaMetrics.nearVisibleMargin)
        let wanted = placements
            .filter { $0.frame.intersects(nearRect) }
            .sorted { abs($0.frame.midY - visibleRect.midY) < abs($1.frame.midY - visibleRect.midY) }
        let wantedIDs = Set(wanted.map(\.id))

        for (id, entry) in pool.entries where !wantedIDs.contains(id) {
            entry.pause()
            entry.view.removeFromSuperview()
        }
        for placement in wanted {
            guard let entry = mountedEntry(for: placement, protecting: wantedIDs) else { continue }
            entry.view.frame = placement.frame
            if entry.view.superview !== textView {
                textView.addSubview(entry.view)
            }
            if !placement.frame.intersects(visibleRect) {
                entry.pause()
            }
        }
    }

    func pauseAll() {
        for entry in pool.entries.values {
            entry.pause()
        }
    }

    // MARK: Private

    private func mountedEntry(
        for placement: AgentTranscriptMediaPlacement,
        protecting wantedIDs: Set<String>
    ) -> AgentTranscriptMediaPlayerEntry? {
        // Same id, different file (the message was edited): start over.
        if let existing = pool.entry(for: placement.id), existing.url != placement.url {
            pool.remove(id: placement.id)
            existing.tearDown()
        }
        let acquired = pool.acquire(id: placement.id, protected: wantedIDs) {
            AgentTranscriptMediaPlayerEntry(
                mediaID: placement.id,
                url: placement.url,
                kind: placement.kind,
                displayName: placement.displayName,
                resumeState: resumeStates[placement.id]
            )
        }
        for victim in acquired.evicted {
            rememberResumeState(of: victim)
            victim.tearDown()
        }
        return acquired.entry
    }

    private func rememberResumeState(of entry: AgentTranscriptMediaPlayerEntry) {
        if resumeStates[entry.mediaID] == nil {
            resumeStateOrder.append(entry.mediaID)
        }
        resumeStates[entry.mediaID] = entry.resumeState
        while resumeStateOrder.count > AgentTranscriptMediaMetrics.resumeStateLimit {
            resumeStates.removeValue(forKey: resumeStateOrder.removeFirst())
        }
    }

    private func invalidateGeometry() {
        geometryIsStale = true
        // With media on the page, ask for a layout pass so the players move in
        // the same pass as the glyphs (and `layoutSubtreeIfNeeded` settles
        // them). Transcripts without media never pay for the extra pass; the
        // async hop covers the case where no layout pass comes at all.
        if let textView, !placements.isEmpty || pool.count > 0 || Self.containsMedia(textView) {
            textView.needsLayout = true
        }
        scheduleSync()
    }

    private static func containsMedia(_ textView: NSTextView) -> Bool {
        guard let storage = textView.textStorage, storage.length > 0 else { return false }
        var found = false
        storage.enumerateAttribute(
            .agentChatHistoryMedia,
            in: NSRange(location: 0, length: storage.length)
        ) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private func scheduleSync() {
        syncIsPending = true
        guard !asyncSyncScheduled else { return }
        asyncSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.asyncSyncScheduled = false
            self.syncIfNeeded()
        }
    }

    // Not `textStorageDidProcessEditing(_:)`: NSObject still carries a
    // deprecated informal method of that name.
    @objc private func transcriptStorageDidProcessEditing(_ notification: Notification) {
        invalidateGeometry()
    }

    /// A video's real aspect ratio arrived: re-lay out its placeholders here
    /// (drawn or not — the cell only knows the layout managers that drew it),
    /// then move the players.
    @objc private func mediaMetadataDidLoad(_ notification: Notification) {
        guard let path = notification.userInfo?[AgentTranscriptMediaMetadataStore.pathUserInfoKey] as? String,
              let textView,
              let storage = textView.textStorage,
              let layoutManager = textView.layoutManager,
              storage.length > 0 else {
            return
        }
        var touched = false
        storage.enumerateAttribute(
            .agentChatHistoryMedia,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard (value as? AgentTranscriptMediaPayload)?.url.path == path else { return }
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: range)
            touched = true
        }
        guard touched else { return }
        textView.invalidateIntrinsicContentSize()
        invalidateGeometry()
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        // Scrolling moves the viewport, not the glyphs: no geometry rebuild,
        // and no `needsLayout` (that would re-measure the SwiftUI host on
        // every scroll tick).
        scheduleSync()
    }

    @objc private func hostWindowWillClose(_ notification: Notification) {
        pauseAll()
    }

    private func rebindScrollObserver() {
        let center = NotificationCenter.default
        let clipView = textView?.enclosingScrollView?.contentView
        guard clipView !== observedClipView else { return }
        if let observedClipView {
            center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClipView)
        }
        observedClipView = clipView
        if let clipView {
            clipView.postsBoundsChangedNotifications = true
            center.addObserver(
                self,
                selector: #selector(clipViewBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }
    }

    private func rebindWindowObservers() {
        let center = NotificationCenter.default
        let window = textView?.window
        guard window !== observedWindow else { return }
        if let observedWindow {
            center.removeObserver(self, name: NSWindow.willCloseNotification, object: observedWindow)
        }
        observedWindow = window
        if let window {
            center.addObserver(
                self,
                selector: #selector(hostWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }
    }

    /// Every laid-out playable placeholder, in text-view coordinates. The id
    /// is `<message id>#<ordinal>`: stable across re-renders, unique across
    /// messages that embed the same file.
    static func placements(in textView: NSTextView) -> [AgentTranscriptMediaPlacement] {
        guard let storage = textView.textStorage,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              storage.length > 0 else {
            return []
        }
        var result: [AgentTranscriptMediaPlacement] = []
        var seen = Set<String>()
        storage.enumerateAttribute(
            .agentChatHistoryMedia,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let payload = value as? AgentTranscriptMediaPayload else { return }
            let messageID = storage.attribute(
                .agentChatHistoryMessageID,
                at: range.location,
                effectiveRange: nil
            ) as? String ?? ""
            let id = "\(messageID)#\(payload.localID)"
            guard !seen.contains(id),
                  let frame = AgentTranscriptMediaLayout.playerFrame(
                      forCharacterAt: range.location,
                      layoutManager: layoutManager,
                      textContainer: textContainer,
                      textContainerOrigin: textView.textContainerOrigin
                  ) else {
                return
            }
            seen.insert(id)
            result.append(AgentTranscriptMediaPlacement(
                id: id,
                url: payload.url,
                kind: payload.kind,
                displayName: payload.displayName,
                frame: frame
            ))
        }
        return result
    }
}
