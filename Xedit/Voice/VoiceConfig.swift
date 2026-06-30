//
//  VoiceConfig.swift
//  WillDeep
//
//  Phase-1 voice-to-text scaffold: minimal stubs for `UserPreferences`
//  references the ported fastv code makes. Keeps fastv's source mostly
//  verbatim by providing a `UserPreferences.shared.enableCTCDeduplication`
//  shim backed by UserDefaults. When the voice feature ships in a polished
//  form, we'll fold these knobs into `AgentSettingsStore` proper.
//

import Foundation
import Combine

/// Shim for the fastv `UserPreferences` global the ported STT code reaches
/// into. Persists voice-only knobs via `com.willdeep.voice.*` keys so they
/// never collide with the rest of the AgentSettingsStore namespace.
@MainActor
final class UserPreferences: ObservableObject {
    static let shared = UserPreferences()

    private enum Keys {
        static let enableCTCDeduplication = "com.willdeep.voice.enableCTCDeduplication.v1"
        static let waveformOverlayPosition = "com.willdeep.voice.waveformOverlay.position.v1"
        static let waveformOverlayStyle = "com.willdeep.voice.waveformOverlay.style.v1"
        static let waveformOverlayColorStyle = "com.willdeep.voice.waveformOverlay.colorStyle.v1"
    }

    @Published var enableCTCDeduplication: Bool {
        didSet { UserDefaults.standard.set(enableCTCDeduplication, forKey: Keys.enableCTCDeduplication) }
    }

    @Published var waveformOverlayPosition: WaveformOverlayWindowPosition {
        didSet { UserDefaults.standard.set(waveformOverlayPosition.rawValue, forKey: Keys.waveformOverlayPosition) }
    }

    @Published var waveformOverlayStyle: WaveformOverlayWindowStyle {
        didSet { UserDefaults.standard.set(waveformOverlayStyle.rawValue, forKey: Keys.waveformOverlayStyle) }
    }

    @Published var waveformOverlayColorStyle: WaveformOverlayWindowColorStyle {
        didSet { UserDefaults.standard.set(waveformOverlayColorStyle.rawValue, forKey: Keys.waveformOverlayColorStyle) }
    }

    private init() {
        // Default off — fastv's CTC dedup affected real-time UX more than
        // batch transcription; safer default for `/transcribe` is off.
        if let existing = UserDefaults.standard.object(forKey: Keys.enableCTCDeduplication) as? Bool {
            self.enableCTCDeduplication = existing
        } else {
            self.enableCTCDeduplication = false
        }

        if let raw = UserDefaults.standard.string(forKey: Keys.waveformOverlayPosition),
           let position = WaveformOverlayWindowPosition(rawValue: raw) {
            self.waveformOverlayPosition = position
        } else {
            self.waveformOverlayPosition = .bottomCenter
        }

        if let raw = UserDefaults.standard.string(forKey: Keys.waveformOverlayStyle),
           let style = WaveformOverlayWindowStyle(rawValue: raw) {
            self.waveformOverlayStyle = style
        } else {
            self.waveformOverlayStyle = .compact
        }

        if let raw = UserDefaults.standard.string(forKey: Keys.waveformOverlayColorStyle),
           let colorStyle = WaveformOverlayWindowColorStyle(rawValue: raw) {
            self.waveformOverlayColorStyle = colorStyle
        } else {
            self.waveformOverlayColorStyle = .darkGrayBlue
        }
    }
}

/// Where SenseVoice / tokens / cmvn live on disk after ModelDownloader
/// has fetched them. Kept here so all Voice code consults the same path.
/// Resolves to `~/Library/Application Support/WillDeep/Voice/Models/sensevoice-small/`.
// nonisolated：仅是一组纯路径常量，actor SpeechTranscriptionModel（off-main）
// 需要直接读它们；不标的话会被工程默认 @MainActor 隔离卷进去而报跨隔离告警。
nonisolated enum VoiceModelLocation {
    static let modelDirectoryName = "sensevoice-small"

    static var modelDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("WillDeep")
            .appendingPathComponent("Voice")
            .appendingPathComponent("Models")
            .appendingPathComponent(modelDirectoryName)
    }

    static var modelOnnxURL: URL { modelDirectory.appendingPathComponent("model.onnx") }
    static var tokensURL: URL { modelDirectory.appendingPathComponent("tokens.json") }
    static var cmvnURL: URL { modelDirectory.appendingPathComponent("am.mvn") }

    static var isModelInstalled: Bool {
        FileManager.default.fileExists(atPath: modelOnnxURL.path)
            && FileManager.default.fileExists(atPath: tokensURL.path)
    }
}
