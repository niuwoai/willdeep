//
//  VoiceSmokeTests.swift
//  WillDeepTests
//
//  Phase 1 voice-to-text smoke test. Looks for a user-supplied audio
//  file under ~/Downloads/willdeep-voice-test.* (any common format).
//  If found, runs SpeechTranscriber and asserts a non-empty transcript.
//  If not found, skips — these aren't CI tests, they're for the
//  feat/voice-to-text branch verification.
//

import Testing
import Foundation
import AVFoundation
@testable import WillDeep

@MainActor
struct VoiceSmokeTests {
    private static let maxDefaultSmokeDuration: TimeInterval = 45
    private static let maxDefaultSmokeFileSizeBytes = 80 * 1024 * 1024
    private static let allowLongAudioEnvironmentKey = "WILLDEEP_VOICE_SMOKE_ALLOW_LONG_AUDIO"

    @Test func transcribeM4AIfPresent() async throws {
        // Pick a test file. Order of preference: explicit
        // willdeep-voice-test.{m4a,wav,mp3}, then anything matching
        // in Downloads, then skip.
        let candidates: [String] = [
            "~/Downloads/willdeep-voice-test.m4a",
            "~/Downloads/willdeep-voice-test.wav",
            "~/Downloads/willdeep-voice-test.mp3",
            "~/Downloads/download_音频.m4a",
            "~/Downloads/replicate-prediction-tsnsg6s7g9rgg0cf6mj8cmhkj8.wav",
        ]

        var resolved: URL?
        for raw in candidates {
            let path = (raw as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) {
                resolved = URL(fileURLWithPath: path)
                break
            }
        }

        guard let url = resolved else {
            // Not an error — the test is opportunistic. Print so it's
            // visible in xcodebuild output why nothing happened.
            print("[voice-smoke] No test audio file found in ~/Downloads. Skipping.")
            return
        }

        guard try await shouldRunSmokeTranscription(for: url) else {
            return
        }

        // Preflight first — surfaces the friendly model-missing message
        // instead of a deep ONNX error.
        do {
            try WhisperPreflight.checkModel()
        } catch {
            Issue.record("Preflight failed: \(error.localizedDescription)")
            return
        }

        print("[voice-smoke] Transcribing: \(url.lastPathComponent)")
        let start = Date()
        let transcript = try await SpeechTranscriber.transcribe(
            audioURL: url,
            language: .auto,
            enableCTCDeduplication: false
        )
        let elapsed = Date().timeIntervalSince(start)

        print("[voice-smoke] Done in \(String(format: "%.1f", elapsed))s, length=\(transcript.count) chars")
        print("[voice-smoke] First 300 chars:\n\(String(transcript.prefix(300)))")

        #expect(!transcript.isEmpty, "Transcript was empty — model produced no tokens.")
    }

    private func shouldRunSmokeTranscription(for url: URL) async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env[Self.allowLongAudioEnvironmentKey] == "1" {
            print("[voice-smoke] Long-audio override enabled via \(Self.allowLongAudioEnvironmentKey)=1.")
            return true
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if fileSize > Self.maxDefaultSmokeFileSizeBytes {
            let fileMB = Double(fileSize) / 1024.0 / 1024.0
            let limitMB = Double(Self.maxDefaultSmokeFileSizeBytes) / 1024.0 / 1024.0
            print("[voice-smoke] Skipping \(url.lastPathComponent): file is \(String(format: "%.1f", fileMB)) MB; default smoke limit is \(String(format: "%.0f", limitMB)) MB. Set \(Self.allowLongAudioEnvironmentKey)=1 for manual long-audio dogfood.")
            return false
        }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        if duration.isFinite, duration > Self.maxDefaultSmokeDuration {
            print("[voice-smoke] Skipping \(url.lastPathComponent): duration is \(String(format: "%.1f", duration))s; default smoke limit is \(String(format: "%.0f", Self.maxDefaultSmokeDuration))s. Set \(Self.allowLongAudioEnvironmentKey)=1 for manual long-audio dogfood.")
            return false
        }

        return true
    }
}
