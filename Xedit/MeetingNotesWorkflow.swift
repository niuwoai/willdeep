//
//  MeetingNotesWorkflow.swift
//  WillDeep
//
//  /meeting-notes <audio-or-video path> — phase 2 killer feature。
//  Local STT 转录 → 1 sub-agent 拆 action items / decisions / open
//  questions / participants 提及。
//
//  Phase 3 会加 speaker diarization（从 fastv 搬 SpeakerDiarization
//  模型 + ONNX 推理代码），让笔记区分每个人说了什么。当前 MVP 不带
//  speaker 区分，prompt 引导 LLM 凭文字风格猜每条 action item / decision
//  的归属人（如果文中提名）。
//

import Foundation
import AVFoundation

struct MeetingNotesWorkflow: WorkflowDefinition {
    var name: String { "meeting-notes" }
    var displayTitle: String { "Meeting Notes" }
    var slashCommand: String { "/meeting-notes" }
    var shortDescription: String { "Transcribe a meeting recording and extract action items + decisions" }
    var argsPlaceholder: String { "<audio or video file path>" }
    var maxAgents: Int { 2 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let path = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return "Usage: `/meeting-notes <path>`, e.g. `/meeting-notes ~/Recordings/standup-2026-06-17.m4a`."
        }

        let expanded = (path as NSString).expandingTildeInPath

        do {
            try WhisperPreflight.checkModel()
        } catch let f as WhisperPreflight.Failure {
            return f.errorDescription ?? "Preflight failed."
        }
        guard FileManager.default.fileExists(atPath: expanded) else {
            return "File not found: `\(path)`."
        }

        let audioURL = URL(fileURLWithPath: expanded)

        // 如果传的是视频文件，先用 ffmpeg 抽音轨。判断方法：扩展名。
        let workingAudioURL: URL
        var tempDir: URL?
        let videoExts = [".mp4", ".mov", ".mkv", ".webm", ".avi", ".m4v"]
        if videoExts.contains(where: { expanded.lowercased().hasSuffix($0) }) {
            do {
                try VideoToolPreflight.checkFFmpeg()
            } catch let f as VideoToolPreflight.Failure {
                return f.errorDescription ?? "Preflight failed."
            }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("WillDeep-Meeting-\(UUID().uuidString.prefix(8))")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            tempDir = dir
            let extracted = dir.appendingPathComponent("audio.wav")
            do {
                try extractAudio(videoURL: audioURL, audioURL: extracted)
            } catch {
                return "Audio extraction failed: \(error.localizedDescription)"
            }
            workingAudioURL = extracted
        } else {
            workingAudioURL = audioURL
        }
        defer { if let dir = tempDir { try? FileManager.default.removeItem(at: dir) } }

        // STT (Swift local — not a sub-agent).
        let transcript: String
        do {
            transcript = try await SpeechTranscriber.transcribe(
                audioURL: workingAudioURL,
                language: .auto,
                enableCTCDeduplication: false
            )
        } catch {
            return "Transcription failed: \(error.localizedDescription)"
        }

        let durationSeconds = (try? await AVURLAsset(url: audioURL).load(.duration))?.seconds ?? 0
        let durationLabel = formatDuration(durationSeconds.isFinite ? durationSeconds : 0)

        // One synthesis agent.
        let synthesisPrompt = """
        Below is a transcript of a meeting recording (\(durationLabel)
        long). Speaker labels are NOT available in this transcript — pull
        names out only when the speakers say someone's name in the audio
        (e.g. "Anna will follow up on …").

        Output structure (markdown):
        # Meeting notes — \((expanded as NSString).lastPathComponent)

        ## TL;DR
        2-4 sentences: what was this meeting about, what got resolved,
        what's next.

        ## Decisions made
        Bulleted list of every decision the meeting reached. For each:
        the decision in one sentence + (if recoverable from the text)
        who's accountable.

        ## Action items
        Markdown checklist. For each:
        - [ ] <action> — owner: <name or "unassigned"> — due: <date if
          mentioned, else "—">

        ## Open questions
        Anything raised but not resolved. Skip if none.

        ## Highlights / quotes
        2-5 short verbatim lines worth capturing (no paraphrase).

        Transcript:

        \(transcript)
        """

        return try await engine.agent(synthesisPrompt, label: "synthesize")
    }

    // MARK: - ffmpeg helper (duplicated from VideoSummaryWorkflow to keep
    // the two files independently readable; phase 3 will extract a
    // shared MediaExtraction helper).
    private func extractAudio(videoURL: URL, audioURL: URL) throws {
        let p = Process()
        p.launchPath = "/usr/bin/env"
        p.arguments = [
            "-S", "ffmpeg", "-y",
            "-i", videoURL.path,
            "-ac", "1", "-ar", "16000", "-vn",
            "-acodec", "pcm_s16le",
            audioURL.path,
        ]
        let errPipe = Pipe()
        p.standardOutput = Pipe()
        p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "meeting-notes", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg exit \(p.terminationStatus): \(err)"
            ])
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}
