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
@testable import WillDeep

@MainActor
struct VoiceSmokeTests {
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
}
