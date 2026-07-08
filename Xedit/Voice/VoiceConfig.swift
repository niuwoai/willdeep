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

enum VoiceTranscriptLanguagePreference: String, CaseIterable, Identifiable {
    case followSystem
    case auto
    case zh
    case en
    case yue
    case ja
    case ko

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .followSystem: return L10n.Settings.Voice.languageFollowSystem
        case .auto: return L10n.Settings.Voice.languageAuto
        case .zh: return L10n.Settings.Voice.languageChinese
        case .en: return L10n.Settings.Voice.languageEnglish
        case .yue: return L10n.Settings.Voice.languageCantonese
        case .ja: return L10n.Settings.Voice.languageJapanese
        case .ko: return L10n.Settings.Voice.languageKorean
        }
    }

    var transcriptLanguage: TranscriptLanguage {
        switch self {
        case .followSystem:
            return Self.systemTranscriptLanguage()
        case .auto:
            return .auto
        case .zh:
            return .zh
        case .en:
            return .en
        case .yue:
            return .yue
        case .ja:
            return .ja
        case .ko:
            return .ko
        }
    }

    static func systemTranscriptLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> TranscriptLanguage {
        guard let primary = preferredLanguages.first?.lowercased() else {
            return .auto
        }
        if primary.hasPrefix("ja") {
            return .ja
        }
        if primary.hasPrefix("ko") {
            return .ko
        }
        if primary.hasPrefix("yue") || primary.contains("-yue") || primary.contains("_yue") {
            return .yue
        }
        if primary.hasPrefix("zh") {
            return .zh
        }
        if primary.hasPrefix("en") {
            return .en
        }
        return .auto
    }
}

nonisolated enum VoiceTranscriptCleanupMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case punctuation
    case bulletPoints

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return L10n.Settings.Voice.cleanupOff
        case .punctuation: return L10n.Settings.Voice.cleanupPunctuation
        case .bulletPoints: return L10n.Settings.Voice.cleanupBulletPoints
        }
    }

    var description: String {
        switch self {
        case .off: return L10n.Settings.Voice.cleanupOffDescription
        case .punctuation: return L10n.Settings.Voice.cleanupPunctuationDescription
        case .bulletPoints: return L10n.Settings.Voice.cleanupBulletPointsDescription
        }
    }

    var usesAI: Bool {
        self != .off
    }
}

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
        static let transcriptLanguagePreference = "com.willdeep.voice.transcriptLanguagePreference.v1"
        static let transcriptCleanupMode = "com.willdeep.voice.transcriptCleanupMode.v1"
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

    @Published var transcriptLanguagePreference: VoiceTranscriptLanguagePreference {
        didSet {
            UserDefaults.standard.set(transcriptLanguagePreference.rawValue, forKey: Keys.transcriptLanguagePreference)
        }
    }

    @Published var transcriptCleanupMode: VoiceTranscriptCleanupMode {
        didSet {
            UserDefaults.standard.set(transcriptCleanupMode.rawValue, forKey: Keys.transcriptCleanupMode)
        }
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

        if let raw = UserDefaults.standard.string(forKey: Keys.transcriptLanguagePreference),
           let preference = VoiceTranscriptLanguagePreference(rawValue: raw) {
            self.transcriptLanguagePreference = preference
        } else {
            self.transcriptLanguagePreference = .followSystem
        }

        if let raw = UserDefaults.standard.string(forKey: Keys.transcriptCleanupMode),
           let mode = VoiceTranscriptCleanupMode(rawValue: raw) {
            self.transcriptCleanupMode = mode
        } else {
            self.transcriptCleanupMode = .off
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
