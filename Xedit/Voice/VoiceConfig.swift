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

/// Shim for the fastv `UserPreferences` global the ported STT code
/// reaches into. Currently exposes the single knob the STT path actually
/// reads: `enableCTCDeduplication`. Persists via UserDefaults under a
/// `com.willdeep.voice.*` key so it never collides with the rest of the
/// AgentSettingsStore namespace.
@MainActor
final class UserPreferences: ObservableObject {
    static let shared = UserPreferences()

    private enum Keys {
        static let enableCTCDeduplication = "com.willdeep.voice.enableCTCDeduplication.v1"
    }

    @Published var enableCTCDeduplication: Bool {
        didSet { UserDefaults.standard.set(enableCTCDeduplication, forKey: Keys.enableCTCDeduplication) }
    }

    private init() {
        // Default off — fastv's CTC dedup affected real-time UX more than
        // batch transcription; safer default for `/transcribe` is off.
        if let existing = UserDefaults.standard.object(forKey: Keys.enableCTCDeduplication) as? Bool {
            self.enableCTCDeduplication = existing
        } else {
            self.enableCTCDeduplication = false
        }
    }
}

/// Where SenseVoice / tokens / cmvn live on disk after ModelDownloader
/// has fetched them. Kept here so all Voice code consults the same path.
/// Resolves to `~/Library/Application Support/WillDeep/Voice/Models/sensevoice-small/`.
enum VoiceModelLocation {
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
