//
//  AgentTranscriptMediaControlBarTests.swift
//  WillDeepTests
//
//  The inline player's own control strip: time text, slider ↔ volume
//  mapping, mute behaviour, and which controls survive a narrow column.
//

import AppKit
import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentTranscriptMediaControlBarTests {
    private typealias Logic = AgentTranscriptMediaControlLogic
    private typealias Metrics = AgentTranscriptMediaControlMetrics

    // MARK: - Time text

    @Test
    func timeIsMinutesAndSecondsUnderAnHour() {
        #expect(Logic.formattedTime(0) == "0:00")
        #expect(Logic.formattedTime(9.9) == "0:09")
        #expect(Logic.formattedTime(65) == "1:05")
        #expect(Logic.formattedTime(3_599) == "59:59")
    }

    @Test
    func timeGainsHoursFromAnHourUp() {
        #expect(Logic.formattedTime(3_600) == "1:00:00")
        #expect(Logic.formattedTime(3_725) == "1:02:05")
    }

    @Test
    func unknownTimeIsDashes() {
        #expect(Logic.formattedTime(.nan) == Logic.unknownTimeText)
        #expect(Logic.formattedTime(.infinity) == Logic.unknownTimeText)
        #expect(Logic.formattedTime(-1) == Logic.unknownTimeText)
    }

    @Test
    func progressIsClampedAndSafeWithoutADuration() {
        #expect(Logic.progress(current: 30, duration: 120) == 0.25)
        #expect(Logic.progress(current: 500, duration: 120) == 1)
        #expect(Logic.progress(current: 10, duration: .nan) == 0)
        #expect(Logic.progress(current: 10, duration: 0) == 0)
    }

    // MARK: - Volume

    @Test
    func sliderMapsLinearlyToVolumeAndIsClamped() {
        #expect(Logic.volume(forSliderValue: 0.5) == 0.5)
        #expect(Logic.volume(forSliderValue: -1) == 0)
        #expect(Logic.volume(forSliderValue: 2) == 1)
        #expect(Logic.volume(forSliderValue: .nan) == 0)
        #expect(Logic.sliderValue(forVolume: 0.75, isMuted: false) == 0.75)
        #expect(Logic.sliderValue(forVolume: 0.75, isMuted: true) == 0)
    }

    @Test
    func draggingTheSliderUpWhileMutedUnmutes() {
        let raised = Logic.adjusted(isMuted: true, sliderValue: 0.6)
        #expect(raised.volume == 0.6)
        #expect(!raised.isMuted)
        let stillSilent = Logic.adjusted(isMuted: true, sliderValue: 0)
        #expect(stillSilent.isMuted)
    }

    @Test
    func muteButtonTogglesAndNeverUnmutesIntoSilence() {
        let muted = Logic.toggledMute(volume: 0.7, isMuted: false)
        #expect(muted.isMuted && muted.volume == 0.7)
        let back = Logic.toggledMute(volume: 0.7, isMuted: true)
        #expect(!back.isMuted && back.volume == 0.7)
        let fromZero = Logic.toggledMute(volume: 0, isMuted: false)
        #expect(!fromZero.isMuted && fromZero.volume == Metrics.unmuteFallbackVolume)
    }

    @Test
    func speakerIconFollowsLevel() {
        #expect(Logic.speakerSymbolName(volume: 0.8, isMuted: true) == "speaker.slash.fill")
        #expect(Logic.speakerSymbolName(volume: 0, isMuted: false) == "speaker.slash.fill")
        #expect(Logic.speakerSymbolName(volume: 0.2, isMuted: false) == "speaker.wave.1.fill")
        #expect(Logic.speakerSymbolName(volume: 0.5, isMuted: false) == "speaker.wave.2.fill")
        #expect(Logic.speakerSymbolName(volume: 1, isMuted: false) == "speaker.wave.3.fill")
    }

    // MARK: - Layout

    @Test
    func wideStripShowsEverything() {
        let layout = AgentTranscriptMediaControlLayout.make(width: 560, height: Metrics.barHeight, includesFullScreen: true)
        #expect(layout.showsTimes)
        #expect(layout.volumeSlider.width == Metrics.volumeSliderWidth)
        #expect(layout.scrubber.width >= Metrics.scrubberMinimumWithTimes)
        #expect(layout.fullScreenButton != nil)
        expectInOrderAndInside(layout, width: 560)
    }

    @Test
    func portraitVideoWidthDropsTimesButKeepsVolume() {
        // A 1080×1920 clip at the 420pt height cap is 236pt wide.
        let layout = AgentTranscriptMediaControlLayout.make(width: 236, height: Metrics.barHeight, includesFullScreen: true)
        #expect(!layout.showsTimes)
        #expect(layout.volumeSlider.width > 0)
        #expect(layout.scrubber.width > 0)
        #expect(layout.fullScreenButton != nil)
        expectInOrderAndInside(layout, width: 236)
    }

    @Test
    func narrowestVideoStillHasAVolumeSlider() {
        let width = AgentTranscriptMediaMetrics.minimumVideoWidth
        let layout = AgentTranscriptMediaControlLayout.make(width: width, height: Metrics.barHeight, includesFullScreen: true)
        #expect(layout.volumeSlider.width == Metrics.compactVolumeSliderWidth)
        #expect(layout.muteButton.width == Metrics.buttonSize)
        expectInOrderAndInside(layout, width: width)
    }

    @Test
    func audioStripHasNoFullScreenButton() {
        let layout = AgentTranscriptMediaControlLayout.make(width: 400, height: Metrics.barHeight, includesFullScreen: false)
        #expect(layout.fullScreenButton == nil)
        #expect(layout.showsTimes)
        expectInOrderAndInside(layout, width: 400)
    }

    @Test
    func controlsAreVerticallyCentred() {
        let layout = AgentTranscriptMediaControlLayout.make(width: 560, height: Metrics.barHeight, includesFullScreen: false)
        #expect(layout.playButton.midY == Metrics.barHeight / 2)
        #expect(layout.volumeSlider.midY == Metrics.barHeight / 2)
    }

    private func expectInOrderAndInside(_ layout: AgentTranscriptMediaControlLayout, width: CGFloat) {
        let frames = [
            layout.playButton, layout.elapsedLabel, layout.scrubber, layout.durationLabel,
            layout.muteButton, layout.volumeSlider, layout.fullScreenButton,
        ].compactMap { $0 }.filter { $0.width > 0 }
        for (left, right) in zip(frames, frames.dropFirst()) {
            #expect(left.maxX <= right.minX, "\(left) overlaps \(right)")
        }
        for frame in frames {
            #expect(frame.minX >= 0 && frame.maxX <= width, "\(frame) outside width \(width)")
            #expect(frame.minY >= 0 && frame.maxY <= Metrics.barHeight)
        }
    }
}
