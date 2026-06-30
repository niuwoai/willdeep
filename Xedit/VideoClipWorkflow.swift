//
//  VideoClipWorkflow.swift
//  WillDeep
//
//  /video-clip <path> <description> — 用 SenseVoice 转录视频，让 LLM 在
//  转录文字里找到匹配 description 的段落，输出 `[start_s, end_s]` 范围，
//  Swift 用 ffmpeg `-ss -to -c copy` 无重编码切片到 ~/Downloads。
//

import Foundation
import AVFoundation

struct VideoClipWorkflow: WorkflowDefinition {
    var name: String { "video-clip" }
    var displayTitle: String { "Video Clip" }
    var slashCommand: String { "/video-clip" }
    var shortDescription: String { "Find a section by transcript description and ffmpeg-cut it out" }
    var argsPlaceholder: String { "<path> <description of the segment>" }
    var maxAgents: Int { 2 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let spaceIdx = trimmed.firstIndex(of: " ") else {
            return "Usage: `/video-clip <path> <description>`, e.g. `/video-clip ~/Movies/keynote.mp4 the part where she demos the new editor`."
        }
        let path = String(trimmed[..<spaceIdx])
        let description = String(trimmed[trimmed.index(after: spaceIdx)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            return "Missing description. Usage: `/video-clip <path> <description of the segment>`."
        }

        do {
            try WhisperPreflight.checkModel()
            try VideoToolPreflight.checkFFmpeg()
            try VideoToolPreflight.checkLocalVideoFile(path)
        } catch let f as WhisperPreflight.Failure { return f.errorDescription ?? "Preflight failed." }
        catch let f as VideoToolPreflight.Failure { return f.errorDescription ?? "Preflight failed." }

        let expanded = (path as NSString).expandingTildeInPath
        let videoURL = URL(fileURLWithPath: expanded)
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillDeep-Clip-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let audioURL = workDir.appendingPathComponent("audio.wav")
        do {
            try VideoMediaHelpers.extractWavAudio(videoURL: videoURL, audioURL: audioURL)
        } catch {
            return "Audio extraction failed: \(error.localizedDescription)"
        }

        // Local STT, with segments → so the LLM can see approximate
        // timestamps. SpeechTranscriber currently returns one big
        // string; we ask the locator agent to estimate timestamps from
        // segment markers it sees inside the transcript text.
        let transcript: String
        do {
            transcript = try await SpeechTranscriber.transcribe(
                audioURL: audioURL,
                language: .auto,
                enableCTCDeduplication: false
            )
        } catch {
            return "Transcription failed: \(error.localizedDescription)"
        }

        let durationSeconds = (try? await AVURLAsset(url: videoURL).load(.duration))?.seconds ?? 0
        let durationLabel = formatHMS(durationSeconds)

        // Locator agent — outputs strict JSON line with start/end seconds.
        let locatorPrompt = """
        You are picking a segment to clip from a video. The video is
        \(durationLabel) long.

        Description of the segment the user wants:
        \(description)

        Transcript (segment markers like `[1/9] 0.00s - 54.45s` precede
        each chunk):

        \(transcript)

        Find the SHORTEST contiguous segment that captures what the user
        described. Prefer 5–60 seconds. Round to the nearest second.

        Output ONLY one line of valid JSON, no markdown, no commentary:
        {"start_seconds": <int>, "end_seconds": <int>, "reason": "<one short sentence>"}

        If you cannot find a segment that matches the description, output
        exactly: {"error": "no match"}
        """
        let locator = try await engine.agent(locatorPrompt, label: "locate")

        guard let range = parseRangeJSON(locator) else {
            return """
            Could not pick a clip range from the transcript.

            Locator agent response:

            \(locator)

            Transcript (so you can decide manually):

            \(transcript)
            """
        }

        let outputURL = makeOutputURL(originalPath: expanded, suffix: "-clip")
        do {
            try VideoMediaHelpers.cutSegment(
                videoURL: videoURL,
                outputURL: outputURL,
                startSeconds: range.start,
                endSeconds: range.end
            )
        } catch {
            return "ffmpeg clip failed: \(error.localizedDescription)"
        }

        let clipDuration = range.end - range.start
        return """
        # Clip extracted

        - **Source**: `\(expanded)`
        - **Range**: \(formatHMS(Double(range.start))) → \(formatHMS(Double(range.end))) (\(clipDuration)s)
        - **Output**: `\(outputURL.path)`
        - **Why**: \(range.reason)

        Open it in QuickTime / Finder:

        ```
        open "\(outputURL.path)"
        ```
        """
    }

    private struct ClipRange {
        let start: Int
        let end: Int
        let reason: String
    }

    private func parseRangeJSON(_ text: String) -> ClipRange? {
        // 找第一行像 JSON 的内容
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            guard let start = obj["start_seconds"] as? Int,
                  let end = obj["end_seconds"] as? Int,
                  end > start, start >= 0 else {
                continue
            }
            let reason = (obj["reason"] as? String) ?? ""
            return ClipRange(start: start, end: end, reason: reason)
        }
        return nil
    }

    private func makeOutputURL(originalPath: String, suffix: String) -> URL {
        let originalURL = URL(fileURLWithPath: originalPath)
        let stem = originalURL.deletingPathExtension().lastPathComponent
        let ext = originalURL.pathExtension.isEmpty ? "mp4" : originalURL.pathExtension
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let stamp = Int(Date().timeIntervalSince1970)
        return downloads.appendingPathComponent("\(stem)\(suffix)-\(stamp).\(ext)")
    }

    private func formatHMS(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Shared media helpers

enum VideoMediaHelpers {
    /// Audio-only extraction (16 kHz mono PCM WAV). 用于 STT。
    static func extractWavAudio(videoURL: URL, audioURL: URL) throws {
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
            throw NSError(domain: "video-media", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg extractWavAudio exit \(p.terminationStatus): \(err)"
            ])
        }
    }

    /// 无重编码切片（`-c copy`），速度极快但只能切在关键帧边界 ——
    /// MVP 接受这个误差（最差几秒偏移）。Phase 2 加 `-c:v h264` 重编码
    /// 选项做精确切。
    static func cutSegment(videoURL: URL, outputURL: URL, startSeconds: Int, endSeconds: Int) throws {
        let p = Process()
        p.launchPath = "/usr/bin/env"
        p.arguments = [
            "-S", "ffmpeg", "-y",
            "-ss", "\(startSeconds)",
            "-to", "\(endSeconds)",
            "-i", videoURL.path,
            "-c", "copy",
            outputURL.path,
        ]
        let errPipe = Pipe()
        p.standardOutput = Pipe()
        p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "video-media", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg cutSegment exit \(p.terminationStatus): \(err)"
            ])
        }
    }

    /// Run ffprobe -show_format -show_streams -of json, return JSON dict.
    static func probe(videoURL: URL) throws -> [String: Any] {
        let p = Process()
        p.launchPath = "/usr/bin/env"
        p.arguments = [
            "-S", "ffprobe",
            "-v", "error",
            "-show_format",
            "-show_streams",
            "-of", "json",
            videoURL.path,
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "video-media", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "ffprobe exit \(p.terminationStatus): \(err)"
            ])
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "video-media", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "ffprobe output not parseable as JSON"
            ])
        }
        return obj
    }
}
