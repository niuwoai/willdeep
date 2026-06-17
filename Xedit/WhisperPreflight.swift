//
//  WhisperPreflight.swift
//  WillDeep
//
//  Phase-1 voice-to-text preflight：检查 SenseVoice 模型文件是否齐全。
//  Workflow 在 sub-agent 真正 spawn 前先调一次 —— 缺哪个文件直接报错给
//  用户，不浪费 LLM 调用。
//
//  Naming note：叫 "Whisper" 是因为这条管道在文档里都用 whisper 类比；
//  实际跑的是 SenseVoice ONNX，但用户视角是「语音→文字」，沿用熟悉名。
//

import Foundation

enum WhisperPreflight {
    enum Failure: Error, LocalizedError {
        case modelMissing(missing: [String])
        case audioFileMissing(path: String)
        case unsupportedAudioFormat(path: String)

        var errorDescription: String? {
            switch self {
            case .modelMissing(let missing):
                let list = missing.map { "  - `\($0)`" }.joined(separator: "\n")
                return """
                SenseVoice model files are missing. Expected under \
                `\(VoiceModelLocation.modelDirectory.path)`:
                \(list)

                If you have fastv installed, you can symlink:
                ```
                mkdir -p "\(VoiceModelLocation.modelDirectory.path)"
                ln -s "$HOME/Library/Application Support/妙打/Models/sensevoice-small/model.onnx" "\(VoiceModelLocation.modelOnnxURL.path)"
                ln -s "$HOME/Sites/fastv/fastv/Resources/Models/sensevoice-small/tokens.json" "\(VoiceModelLocation.tokensURL.path)"
                ln -s "$HOME/Sites/fastv/fastv/Resources/Models/sensevoice-small/am.mvn" "\(VoiceModelLocation.cmvnURL.path)"
                ```

                Or wait for the onboarding sheet in phase 2 (planned).
                """
            case .audioFileMissing(let path):
                return "Audio file not found: `\(path)`."
            case .unsupportedAudioFormat(let path):
                return "File `\(path)` doesn't look like a supported audio/video format (expected .wav / .m4a / .mp3 / .flac / .aac / .mp4 / .mov)."
            }
        }
    }

    /// 检查模型文件齐全。Workflow 启动时调一次。
    static func checkModel() throws {
        let expected: [(name: String, url: URL)] = [
            ("model.onnx", VoiceModelLocation.modelOnnxURL),
            ("tokens.json", VoiceModelLocation.tokensURL),
            ("am.mvn", VoiceModelLocation.cmvnURL),
        ]
        let missing = expected.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.map(\.name)
        if !missing.isEmpty {
            throw Failure.modelMissing(missing: missing)
        }
    }

    /// 检查音频文件本身（exists + 扩展名合理）。
    static func checkAudio(path: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw Failure.audioFileMissing(path: path)
        }
        let lower = expanded.lowercased()
        let supported = [".wav", ".m4a", ".mp3", ".flac", ".aac", ".mp4", ".mov", ".caf", ".aiff"]
        guard supported.contains(where: { lower.hasSuffix($0) }) else {
            throw Failure.unsupportedAudioFormat(path: path)
        }
    }
}
