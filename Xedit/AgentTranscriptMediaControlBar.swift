//
//  AgentTranscriptMediaControlBar.swift
//  WillDeep
//
//  The always-visible control strip under every inline player: play/pause,
//  elapsed time, a draggable position bar, duration, mute + volume, and (for
//  video) full screen.
//
//  Why not AVPlayerView's own controls: `.inline` keeps its volume slider in a
//  hover-only glass panel that floats *outside* the view's bounds, so inside
//  the transcript's rounded, clipped container it never appears; `.floating`
//  needs ~110pt of height and far more width than a 236pt portrait clip has.
//  Users asked for volume on every player, so the strip is drawn here with
//  plain AppKit controls and AVPlayerView only paints the picture.
//

import AppKit
import AVFoundation
import Foundation

// MARK: - Pure logic

nonisolated enum AgentTranscriptMediaControlLogic {
    /// `m:ss`, or `h:mm:ss` from an hour up. Unknown / invalid → `--:--`.
    static func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return unknownTimeText }
        let total = Int(seconds.rounded(.down))
        let hours = total / secondsPerHour
        let minutes = (total % secondsPerHour) / secondsPerMinute
        let remainder = total % secondsPerMinute
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    static let unknownTimeText = "--:--"
    private static let secondsPerMinute = 60
    private static let secondsPerHour = 3_600

    /// Slider position (0…1) → `AVPlayer.volume`. Linear, clamped.
    static func volume(forSliderValue value: Double) -> Float {
        guard value.isFinite else { return 0 }
        return Float(min(max(value, 0), 1))
    }

    /// What the volume slider shows: a muted player reads as silent, and
    /// comes back to its old level on unmute.
    static func sliderValue(forVolume volume: Float, isMuted: Bool) -> Double {
        guard !isMuted, volume.isFinite else { return 0 }
        return Double(min(max(volume, 0), 1))
    }

    /// Dragging the slider off zero while muted means "I want sound".
    static func adjusted(isMuted: Bool, sliderValue: Double) -> (volume: Float, isMuted: Bool) {
        let volume = self.volume(forSliderValue: sliderValue)
        return (volume, isMuted && volume == 0)
    }

    /// The mute button. Unmuting a player whose volume was dragged to zero
    /// would stay silent, so it comes back at a usable level instead.
    static func toggledMute(volume: Float, isMuted: Bool) -> (volume: Float, isMuted: Bool) {
        if isMuted || volume == 0 {
            return (volume > 0 ? volume : AgentTranscriptMediaControlMetrics.unmuteFallbackVolume, false)
        }
        return (volume, true)
    }

    static func speakerSymbolName(volume: Float, isMuted: Bool) -> String {
        if isMuted || volume <= 0 { return "speaker.slash.fill" }
        if volume < AgentTranscriptMediaControlMetrics.quietVolumeThreshold { return "speaker.wave.1.fill" }
        if volume < AgentTranscriptMediaControlMetrics.loudVolumeThreshold { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    /// Position-bar value (0…1) for the current time.
    static func progress(current: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0, current.isFinite else { return 0 }
        return min(max(current / duration, 0), 1)
    }
}

nonisolated enum AgentTranscriptMediaControlMetrics {
    /// Height of the strip. Video placeholders are picture + this; audio
    /// placeholders are exactly this.
    static let barHeight: CGFloat = 34
    static let horizontalPadding: CGFloat = 8
    static let itemSpacing: CGFloat = 6
    static let buttonSize: CGFloat = 22
    static let symbolPointSize: CGFloat = 13
    static let sliderHeight: CGFloat = 20
    /// Wide enough for `1:00:00` in 11pt monospaced digits.
    static let timeLabelWidth: CGFloat = 46
    static let timeFontSize: CGFloat = 11
    static let timeLabelHeight: CGFloat = 16
    static let volumeSliderWidth: CGFloat = 72
    static let compactVolumeSliderWidth: CGFloat = 44
    /// Position-bar minimums for each tier, widest first. The last tier has
    /// none: the volume control outlives the position bar.
    static let scrubberMinimumWithTimes: CGFloat = 120
    static let scrubberMinimumWithFullVolume: CGFloat = 100
    static let scrubberMinimumCompact: CGFloat = 56
    static let timeObserverIntervalSeconds: Double = 0.25
    static let unmuteFallbackVolume: Float = 0.5
    static let quietVolumeThreshold: Float = 0.34
    static let loudVolumeThreshold: Float = 0.67
    /// Pressing play this close to the end starts over instead of stalling.
    static let restartThresholdSeconds: Double = 0.25
    static let separatorThickness: CGFloat = 1
}

/// Where each control sits for a given strip width. Pure, so the narrow-width
/// trade-offs are testable: time labels go first, then the volume slider
/// shortens, then the position bar shrinks — the mute button and volume
/// slider never disappear.
nonisolated struct AgentTranscriptMediaControlLayout: Equatable {
    var playButton: NSRect
    var elapsedLabel: NSRect?
    var scrubber: NSRect
    var durationLabel: NSRect?
    var muteButton: NSRect
    var volumeSlider: NSRect
    var fullScreenButton: NSRect?

    var showsTimes: Bool { elapsedLabel != nil }

    static func make(width: CGFloat, height: CGFloat, includesFullScreen: Bool) -> Self {
        typealias M = AgentTranscriptMediaControlMetrics
        let fixed = M.horizontalPadding * 2
            + M.buttonSize * 2 // play + mute
            + M.itemSpacing * 3 // play|scrubber, scrubber|mute, mute|volume
            + (includesFullScreen ? M.itemSpacing + M.buttonSize : 0)
        let available = max(0, width - fixed)
        let timesWidth = (M.timeLabelWidth + M.itemSpacing) * 2
        let tiers: [(times: Bool, volume: CGFloat, minimumScrubber: CGFloat)] = [
            (true, M.volumeSliderWidth, M.scrubberMinimumWithTimes),
            (false, M.volumeSliderWidth, M.scrubberMinimumWithFullVolume),
            (false, M.compactVolumeSliderWidth, M.scrubberMinimumCompact),
        ]
        let chosen = tiers.first { tier in
            (tier.times ? timesWidth : 0) + tier.volume + tier.minimumScrubber <= available
        } ?? (false, M.compactVolumeSliderWidth, 0)
        let volumeWidth = min(chosen.volume, available)
        let scrubberWidth = max(0, available - volumeWidth - (chosen.times ? timesWidth : 0))

        func centered(x: CGFloat, width: CGFloat, height itemHeight: CGFloat) -> NSRect {
            NSRect(x: x, y: ((height - itemHeight) / 2).rounded(), width: width, height: itemHeight)
        }
        var x = M.horizontalPadding
        let play = centered(x: x, width: M.buttonSize, height: M.buttonSize)
        x += M.buttonSize + M.itemSpacing
        var elapsed: NSRect?
        if chosen.times {
            elapsed = centered(x: x, width: M.timeLabelWidth, height: M.timeLabelHeight)
            x += M.timeLabelWidth + M.itemSpacing
        }
        let scrubber = centered(x: x, width: scrubberWidth, height: M.sliderHeight)
        x += scrubberWidth + M.itemSpacing
        var duration: NSRect?
        if chosen.times {
            duration = centered(x: x, width: M.timeLabelWidth, height: M.timeLabelHeight)
            x += M.timeLabelWidth + M.itemSpacing
        }
        let mute = centered(x: x, width: M.buttonSize, height: M.buttonSize)
        x += M.buttonSize + M.itemSpacing
        let volume = centered(x: x, width: volumeWidth, height: M.sliderHeight)
        x += volumeWidth
        var fullScreen: NSRect?
        if includesFullScreen {
            x += M.itemSpacing
            fullScreen = centered(x: x, width: M.buttonSize, height: M.buttonSize)
        }
        return Self(
            playButton: play,
            elapsedLabel: elapsed,
            scrubber: scrubber,
            durationLabel: duration,
            muteButton: mute,
            volumeSlider: volume,
            fullScreenButton: fullScreen
        )
    }
}

// MARK: - View

/// One strip per player, bound to that player only.
final class AgentTranscriptMediaControlBar: NSView {
    let playButton = NSButton()
    let elapsedLabel = NSTextField(labelWithString: AgentTranscriptMediaControlLogic.formattedTime(0))
    let scrubber = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let durationLabel = NSTextField(labelWithString: AgentTranscriptMediaControlLogic.unknownTimeText)
    let muteButton = NSButton()
    let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    let fullScreenButton: NSButton?

    private weak var player: AVPlayer?
    private let drawsTopSeparator: Bool
    private var timeObserver: Any?
    private var timeControlObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var isScrubbing = false
    /// Video only: what the full-screen button does.
    var onFullScreen: (() -> Void)?

    init(player: AVPlayer, kind: AgentTranscriptMediaKind) {
        self.player = player
        self.drawsTopSeparator = kind == .video
        self.fullScreenButton = kind == .video ? NSButton() : nil
        super.init(frame: .zero)
        configureControls()
        bind(to: player)
        refreshFromPlayer()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Opaque, so text under a video's strip never shows through. Colours
        // are resolved against the current appearance (light / dark).
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = NSColor.controlBackgroundColor
            let fill = base.blended(withFraction: Self.tintFraction, of: .labelColor) ?? base
            layer?.backgroundColor = fill.cgColor
            separatorLayer.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Strip tint over the control background: enough to read as a bar in
    /// both modes without dimming the controls.
    private static let tintFraction: CGFloat = 0.06
    private let separatorLayer = CALayer()

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyLayout()
    }

    var currentLayout: AgentTranscriptMediaControlLayout {
        AgentTranscriptMediaControlLayout.make(
            width: bounds.width,
            height: bounds.height,
            includesFullScreen: fullScreenButton != nil
        )
    }

    private func applyLayout() {
        let layout = currentLayout
        playButton.frame = layout.playButton
        scrubber.frame = layout.scrubber
        scrubber.isHidden = layout.scrubber.width <= 0
        elapsedLabel.isHidden = layout.elapsedLabel == nil
        durationLabel.isHidden = layout.durationLabel == nil
        if let frame = layout.elapsedLabel { elapsedLabel.frame = frame }
        if let frame = layout.durationLabel { durationLabel.frame = frame }
        muteButton.frame = layout.muteButton
        volumeSlider.frame = layout.volumeSlider
        if let fullScreenButton, let frame = layout.fullScreenButton {
            fullScreenButton.frame = frame
        }
        // Video only: a hairline between picture and controls.
        separatorLayer.isHidden = !drawsTopSeparator
        separatorLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: AgentTranscriptMediaControlMetrics.separatorThickness
        )
    }

    // MARK: Setup

    private func configureControls() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.addSublayer(separatorLayer)
        for button in [playButton, muteButton] + [fullScreenButton].compactMap({ $0 }) {
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = .labelColor
            button.target = self
            addSubview(button)
        }
        playButton.action = #selector(togglePlay(_:))
        muteButton.action = #selector(toggleMute(_:))
        fullScreenButton?.action = #selector(enterFullScreen(_:))
        fullScreenButton?.image = Self.symbol("arrow.up.left.and.arrow.down.right")
        fullScreenButton?.toolTip = L10n.TranscriptMedia.fullScreen
        fullScreenButton?.setAccessibilityLabel(L10n.TranscriptMedia.fullScreen)

        let timeFont = NSFont.monospacedDigitSystemFont(
            ofSize: AgentTranscriptMediaControlMetrics.timeFontSize,
            weight: .regular
        )
        for label in [elapsedLabel, durationLabel] {
            label.font = timeFont
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byClipping
            addSubview(label)
        }
        elapsedLabel.alignment = .right
        durationLabel.alignment = .left
        elapsedLabel.setAccessibilityLabel(L10n.TranscriptMedia.elapsedTime)
        durationLabel.setAccessibilityLabel(L10n.TranscriptMedia.duration)

        for slider in [scrubber, volumeSlider] {
            slider.controlSize = .small
            slider.isContinuous = true
            slider.target = self
            addSubview(slider)
        }
        scrubber.action = #selector(scrub(_:))
        scrubber.toolTip = L10n.TranscriptMedia.playbackPosition
        scrubber.setAccessibilityLabel(L10n.TranscriptMedia.playbackPosition)
        volumeSlider.action = #selector(changeVolume(_:))
        volumeSlider.toolTip = L10n.TranscriptMedia.volume
        volumeSlider.setAccessibilityLabel(L10n.TranscriptMedia.volume)
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: AgentTranscriptMediaControlMetrics.symbolPointSize,
                weight: .medium
            ))
    }

    private func bind(to player: AVPlayer) {
        let interval = CMTime(
            seconds: AgentTranscriptMediaControlMetrics.timeObserverIntervalSeconds,
            preferredTimescale: AgentTranscriptMediaMetrics.timeScale
        )
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTime() }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshPlayButton() }
        }
        durationObservation = player.currentItem?.observe(\.duration, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshTime() }
        }
    }

    /// Removes the time observer and KVO. Called when the pool evicts the
    /// player; the bar is inert afterwards.
    func detach() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        durationObservation?.invalidate()
        durationObservation = nil
        player = nil
    }

    var isBound: Bool { timeObserver != nil }

    // MARK: Refresh

    func refreshFromPlayer() {
        refreshPlayButton()
        refreshTime()
        refreshVolume()
    }

    private func refreshPlayButton() {
        let isPlaying = player.map { $0.timeControlStatus != .paused } ?? false
        playButton.image = Self.symbol(isPlaying ? "pause.fill" : "play.fill")
        let title = isPlaying ? L10n.TranscriptMedia.pause : L10n.TranscriptMedia.play
        playButton.toolTip = title
        playButton.setAccessibilityLabel(title)
    }

    private func refreshTime() {
        guard let player else { return }
        let current = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? .nan
        elapsedLabel.stringValue = AgentTranscriptMediaControlLogic.formattedTime(current.isFinite ? current : 0)
        durationLabel.stringValue = AgentTranscriptMediaControlLogic.formattedTime(duration)
        scrubber.isEnabled = duration.isFinite && duration > 0
        if !isScrubbing {
            scrubber.doubleValue = AgentTranscriptMediaControlLogic.progress(current: current, duration: duration)
        }
    }

    private func refreshVolume() {
        guard let player else { return }
        volumeSlider.doubleValue = AgentTranscriptMediaControlLogic.sliderValue(
            forVolume: player.volume,
            isMuted: player.isMuted
        )
        muteButton.image = Self.symbol(AgentTranscriptMediaControlLogic.speakerSymbolName(
            volume: player.volume,
            isMuted: player.isMuted
        ))
        let title = player.isMuted || player.volume == 0 ? L10n.TranscriptMedia.unmute : L10n.TranscriptMedia.mute
        muteButton.toolTip = title
        muteButton.setAccessibilityLabel(title)
    }

    // MARK: Actions

    @objc func togglePlay(_ sender: Any?) {
        guard let player else { return }
        if player.timeControlStatus != .paused {
            player.pause()
        } else {
            let duration = player.currentItem?.duration.seconds ?? .nan
            let current = player.currentTime().seconds
            if duration.isFinite,
               current >= duration - AgentTranscriptMediaControlMetrics.restartThresholdSeconds {
                player.seek(to: .zero)
            }
            player.play()
        }
        refreshPlayButton()
    }

    @objc func scrub(_ sender: NSSlider) {
        guard let player,
              let duration = player.currentItem?.duration.seconds,
              duration.isFinite, duration > 0 else {
            return
        }
        // Continuous slider: every drag step lands here; mouse-up ends it.
        // While the finger is down, time ticks must not yank the knob back.
        let eventType = NSApp.currentEvent?.type
        isScrubbing = eventType == .leftMouseDown || eventType == .leftMouseDragged
        let target = CMTime(
            seconds: sender.doubleValue * duration,
            preferredTimescale: AgentTranscriptMediaMetrics.timeScale
        )
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        elapsedLabel.stringValue = AgentTranscriptMediaControlLogic.formattedTime(target.seconds)
    }

    @objc func changeVolume(_ sender: NSSlider) {
        guard let player else { return }
        let adjusted = AgentTranscriptMediaControlLogic.adjusted(
            isMuted: player.isMuted,
            sliderValue: sender.doubleValue
        )
        player.volume = adjusted.volume
        player.isMuted = adjusted.isMuted
        refreshVolume()
    }

    @objc func toggleMute(_ sender: Any?) {
        guard let player else { return }
        let toggled = AgentTranscriptMediaControlLogic.toggledMute(volume: player.volume, isMuted: player.isMuted)
        player.volume = toggled.volume
        player.isMuted = toggled.isMuted
        refreshVolume()
    }

    @objc private func enterFullScreen(_ sender: Any?) {
        onFullScreen?()
    }
}
