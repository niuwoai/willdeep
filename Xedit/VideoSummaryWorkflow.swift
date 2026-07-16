//
//  VideoSummaryWorkflow.swift
//  WillDeep
//
//  /video-summary <path|url> — phase 2 剑走偏锋。
//
//  Pipeline：
//    1. Swift 端：如果是 URL → yt-dlp 拉到临时 mp4；ffmpeg 抽 16kHz mono
//       wav 音轨；调 SpeechTranscriber.transcribe(...) 出 transcript
//    2. Sub-agent：拿 transcript 写 markdown 笔记（章节 / TL;DR / key
//       quotes / takeaways）
//
//  Phase 3 会加：ffmpeg 取关键帧 → 多模态 LLM 看图 → 视频笔记带画面
//  描述。当前 phase 2 只走纯语音线路。
//

import Foundation
import AVFoundation

struct VideoSummaryWorkflow: WorkflowDefinition {
    var name: String { "video-summary" }
    var displayTitle: String { "Video Summary" }
    var slashCommand: String { "/video-summary" }
    var shortDescription: String { "Transcribe a video (file or URL) and turn it into structured notes" }
    var argsPlaceholder: String { "<video file path or URL>" }
    var maxAgents: Int { 2 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let input = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            return "Usage: `/video-summary <path>` or `/video-summary <url>`, e.g. `/video-summary ~/Movies/talk.mp4` or `/video-summary https://www.youtube.com/watch?v=...`."
        }

        // Preflight chain.
        do {
            try WhisperPreflight.checkModel()
            try VideoToolPreflight.checkFFmpeg()
            if VideoToolPreflight.isURL(input) {
                try VideoToolPreflight.checkYtDlp()
            } else {
                try VideoToolPreflight.checkLocalVideoFile(input)
            }
        } catch let f as WhisperPreflight.Failure { return f.errorDescription ?? "Preflight failed." }
        catch let f as VideoToolPreflight.Failure { return f.errorDescription ?? "Preflight failed." }

        // Make a work directory under tmp so we can clean up after.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillDeep-Video-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Step 1: produce a local video file URL.
        let videoURL: URL
        do {
            if VideoToolPreflight.isURL(input) {
                videoURL = try await downloadVideo(url: input, to: workDir)
            } else {
                let expanded = (input as NSString).expandingTildeInPath
                videoURL = URL(fileURLWithPath: expanded)
            }
        } catch {
            return "Video acquisition failed: \(error.localizedDescription)"
        }

        // Step 2: extract 16 kHz mono PCM WAV via ffmpeg.
        let audioURL = workDir.appendingPathComponent("audio.wav")
        do {
            try await extractAudio(videoURL: videoURL, audioURL: audioURL)
        } catch {
            return "Audio extraction failed: \(error.localizedDescription)"
        }

        // Step 3: run STT locally (NOT a sub-agent).
        let transcript: String
        do {
            transcript = try await SpeechTranscriber.transcribe(
                audioURL: audioURL,
                language: .auto,
                enableCTCDeduplication: false
            )
        } catch {
            return "Local transcription failed: \(error.localizedDescription)"
        }

        let durationSeconds = (try? await AVURLAsset(url: videoURL).load(.duration))?.seconds ?? 0
        let durationLabel = formatDuration(durationSeconds.isFinite ? durationSeconds : 0)

        // Step 4: one sub-agent writes the markdown notes.
        let synthesisPrompt = """
        You're producing a structured markdown notes document from the
        raw transcript of a video. The video is \(durationLabel) long.

        Source: `\(input)`

        Output structure:
        # \((input as NSString).lastPathComponent) — video summary

        ## TL;DR
        3-5 sentence executive summary of what the video is actually about
        and why a reader should care.

        ## Chapters
        Break the transcript into logical chapters. For each: a 3-7 word
        title + a 1-3 sentence summary. Aim for ~6-12 chapters depending
        on length. Don't fabricate chapter timestamps — only include
        approximate `~MM:SS` markers if you can infer them from the
        transcript flow.

        ## Key quotes
        3-6 short verbatim quotes that capture the most distinctive or
        argument-driving lines. Quote exactly; do not paraphrase.

        ## Takeaways
        3-5 actionable bullets — what does the listener walk away knowing
        or being able to do.

        ## Open questions
        Anything the video raises but doesn't answer. Skip the section if
        none surfaced.

        Transcript:

        \(transcript)
        """

        return try await engine.agent(synthesisPrompt, label: "synthesize")
    }

    // MARK: - Helpers

    private func downloadVideo(url: String, to workDir: URL) async throws -> URL {
        let outputTemplate = workDir.appendingPathComponent("video.%(ext)s").path
        let result = await runProcess("/usr/bin/env", [
            "-S", "yt-dlp",
            "--no-playlist",
            "-f", "best[height<=720]/best",  // 720p 够 OCR / 关键帧；省带宽
            "-o", outputTemplate,
            url,
        ])
        guard result.exitCode == 0 else {
            throw NSError(domain: "video-summary", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "yt-dlp exit \(result.exitCode): \(result.stderr)"
            ])
        }
        // yt-dlp 把 %(ext)s 替换为实际格式，找 video.* 中第一个。
        let items = (try? FileManager.default.contentsOfDirectory(atPath: workDir.path)) ?? []
        guard let candidate = items.first(where: { $0.hasPrefix("video.") }) else {
            throw NSError(domain: "video-summary", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "yt-dlp finished but no video.* file appeared in \(workDir.path)"
            ])
        }
        return workDir.appendingPathComponent(candidate)
    }

    private func extractAudio(videoURL: URL, audioURL: URL) async throws {
        let result = await runProcess("/usr/bin/env", [
            "-S", "ffmpeg",
            "-y",                              // overwrite
            "-i", videoURL.path,
            "-ac", "1",                        // mono
            "-ar", "16000",                    // 16 kHz
            "-vn",                             // discard video
            "-acodec", "pcm_s16le",
            audioURL.path,
        ])
        guard result.exitCode == 0 else {
            throw NSError(domain: "video-summary", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg exit \(result.exitCode): \(result.stderr)"
            ])
        }
    }

    private struct RunResult { let exitCode: Int32; let stdout: String; let stderr: String }

    private func runProcess(_ launchPath: String, _ arguments: [String]) async -> RunResult {
        let p = Process()
        p.launchPath = launchPath
        p.arguments = arguments
        do {
            let result = try await AgentSubprocess.run(p)
            return RunResult(exitCode: result.exitStatus, stdout: result.stdoutText, stderr: result.stderrText)
        } catch {
            return RunResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
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
