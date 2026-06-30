//
//  TranscribeWorkflow.swift
//  WillDeep
//
//  /transcribe <audio-or-video path> — phase 1 voice-to-text workflow.
//  Runs the SenseVoice ONNX pipeline ported from fastv against the
//  file, outputs a markdown report with the raw transcript and basic
//  metadata. **Pure Swift work, no LLM sub-agents** — engine.agent()
//  isn't called. We still return through the Workflow surface so the
//  user gets the same card + progress + history affordances.
//

import Foundation
import AVFoundation

struct TranscribeWorkflow: WorkflowDefinition {
    var name: String { "transcribe" }
    var displayTitle: String { "Transcribe" }
    var slashCommand: String { "/transcribe" }
    var shortDescription: String { "Transcribe an audio/video file using the on-device SenseVoice model" }
    var argsPlaceholder: String { "<path to audio or video file>" }
    /// 100% Swift（local model）→ "agents" 字段在卡片上只是占位 1。
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let path = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return "Usage: `/transcribe <path>`, e.g. `/transcribe ~/Downloads/meeting.m4a`."
        }

        // Preflight: model + audio file.
        do {
            try WhisperPreflight.checkModel()
            try WhisperPreflight.checkAudio(path: path)
        } catch let failure as WhisperPreflight.Failure {
            return failure.errorDescription ?? "Preflight failed."
        }

        let expandedPath = (path as NSString).expandingTildeInPath
        let audioURL = URL(fileURLWithPath: expandedPath)

        // Run SenseVoice. SpeechTranscriber.transcribe(audioURL:) handles
        // PCM conversion, mel feature extraction, ONNX inference, and
        // token decoding internally — single async call.
        let started = Date()
        let transcript: String
        do {
            transcript = try await SpeechTranscriber.transcribe(
                audioURL: audioURL,
                language: .auto,
                enableCTCDeduplication: false
            )
        } catch {
            return """
            Transcription failed: \(error.localizedDescription)

            Audio file: `\(expandedPath)`
            Model dir: `\(VoiceModelLocation.modelDirectory.path)`

            If this is the first time using `/transcribe`, the ONNX
            Runtime dylib may not be findable at launch. See
            `Xedit/Voice/PHASE1_NOTES.md` for the rpath / Copy Files
            build phase status.
            """
        }
        let elapsed = Date().timeIntervalSince(started)

        // Read audio duration (best-effort — works for most formats).
        let durationSeconds: Double
        if let cmTime = try? await AVURLAsset(url: audioURL).load(.duration), cmTime.isValid {
            durationSeconds = cmTime.seconds
        } else {
            durationSeconds = 0
        }

        let durationFmt = formatDuration(durationSeconds)
        let elapsedFmt = formatDuration(elapsed)
        let speedFmt = durationSeconds > 0 ? String(format: "%.1fx", durationSeconds / elapsed) : "—"

        return """
        # Transcript — \((expandedPath as NSString).lastPathComponent)

        - **Model**: SenseVoice (ONNX, on-device)
        - **Audio duration**: \(durationFmt)
        - **Transcribed in**: \(elapsedFmt) (\(speedFmt) realtime)
        - **Source**: `\(expandedPath)`

        ## Transcript

        \(transcript.isEmpty ? "_(empty — model produced no tokens; the audio may be silent or unsupported)_" : transcript)
        """
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        if m == 0 { return "\(s)s" }
        return "\(m)m \(s)s"
    }
}
