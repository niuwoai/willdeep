//
//  VideoSubtitleWorkflow.swift
//  WillDeep
//
//  /video-subtitle <path> [srt-path]
//
//  没传 srt：用 SenseVoice 转录视频音轨，把 transcript 里的
//  `[N/M] start.ssS - end.ssS` 段落标记解析成 SRT，再用 ffmpeg
//  `subtitles=` 滤镜烧字幕进画面（hard sub，永久嵌入）。
//
//  传了 srt：直接烧用户提供的 srt。
//

import Foundation
import AVFoundation

struct VideoSubtitleWorkflow: WorkflowDefinition {
    var name: String { "video-subtitle" }
    var displayTitle: String { "Burn Subtitles" }
    var slashCommand: String { "/video-subtitle" }
    var shortDescription: String { "Auto-transcribe (or use provided SRT) and burn subtitles into the video" }
    var argsPlaceholder: String { "<path> [srt-path]" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let tokens = args.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let videoPath = tokens.first, !videoPath.isEmpty else {
            return "Usage: `/video-subtitle <path> [srt-path]`. Without an SRT, transcription runs and generates one automatically."
        }
        let providedSrt: String? = tokens.count >= 2 ? tokens[1] : nil

        do {
            try VideoToolPreflight.checkFFmpeg()
            try VideoToolPreflight.checkLocalVideoFile(videoPath)
        } catch let f as VideoToolPreflight.Failure {
            return f.errorDescription ?? "Preflight failed."
        }

        let expanded = (videoPath as NSString).expandingTildeInPath
        let videoURL = URL(fileURLWithPath: expanded)

        // 决定 SRT 来源。
        let srtURL: URL
        let srtIsTemp: Bool
        if let provided = providedSrt {
            let expandedSrt = (provided as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expandedSrt) else {
                return "SRT file not found: `\(provided)`. Either pass a valid path or omit the second arg to auto-generate."
            }
            srtURL = URL(fileURLWithPath: expandedSrt)
            srtIsTemp = false
        } else {
            // 自动转录 → SRT
            do {
                try WhisperPreflight.checkModel()
            } catch let f as WhisperPreflight.Failure {
                return f.errorDescription ?? "Voice preflight failed."
            }
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("WillDeep-Subtitle-\(UUID().uuidString.prefix(8))")
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let wavURL = workDir.appendingPathComponent("audio.wav")
            do {
                try VideoMediaHelpers.extractWavAudio(videoURL: videoURL, audioURL: wavURL)
            } catch {
                return "Audio extract for transcription failed: \(error.localizedDescription)"
            }
            let transcript: String
            do {
                transcript = try await SpeechTranscriber.transcribe(
                    audioURL: wavURL,
                    language: .auto,
                    enableCTCDeduplication: false
                )
            } catch {
                return "Transcription failed: \(error.localizedDescription)"
            }
            let srt = buildSRT(from: transcript)
            guard !srt.isEmpty else {
                return "Transcript didn't yield any timestamped segments. The video may have no speech or transcription failed silently. Transcript was:\n\n\(transcript)"
            }
            let generatedSrt = workDir.appendingPathComponent("auto.srt")
            try? srt.write(to: generatedSrt, atomically: true, encoding: .utf8)
            srtURL = generatedSrt
            srtIsTemp = true
        }
        defer {
            if srtIsTemp {
                try? FileManager.default.removeItem(at: srtURL.deletingLastPathComponent())
            }
        }

        // 烧字幕。
        let stem = videoURL.deletingPathExtension().lastPathComponent
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let stamp = Int(Date().timeIntervalSince1970)
        let outputURL = downloads.appendingPathComponent("\(stem)-subtitled-\(stamp).mp4")

        // ffmpeg subtitles filter 需要 SRT path 用 `:` 之类字符 escape。
        // 简化：copy 到 tmpdir 取一个无特殊字符的名字。
        let safeSrt = FileManager.default.temporaryDirectory
            .appendingPathComponent("subs-\(UUID().uuidString.prefix(8)).srt")
        try? FileManager.default.removeItem(at: safeSrt)
        try? FileManager.default.copyItem(at: srtURL, to: safeSrt)
        defer { try? FileManager.default.removeItem(at: safeSrt) }
        // ASS style：白字 + 黑描边，避免在亮色背景看不见。
        let style = "FontSize=20,PrimaryColour=&H00FFFFFF,OutlineColour=&H80000000,Outline=2,BorderStyle=1,Shadow=0"

        do {
            try runFFmpeg([
                "-y", "-i", videoURL.path,
                "-vf", "subtitles='\(safeSrt.path)':force_style='\(style)'",
                "-c:a", "copy",
                "-movflags", "+faststart",
                outputURL.path,
            ])
        } catch {
            return "ffmpeg subtitle burn failed: \(error.localizedDescription)"
        }

        let outputBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        return """
        # Subtitles burned in

        - **Source**: `\(expanded)`
        - **Output**: `\(outputURL.path)` (\(String(format: "%.1f MB", Double(outputBytes) / 1024.0 / 1024.0)))
        - **SRT**: \(providedSrt.map { "provided (`\($0)`)" } ?? "auto-generated from SenseVoice transcription")
        - **Style**: white text with dark outline (hard-coded; phase 2 will accept style overrides)

        Open:

        ```
        open "\(outputURL.path)"
        ```
        """
    }

    /// 把 SpeechTranscriber 的输出（含 `[N/M] start.ssS - end.ssS` 段落
    /// 标记）解析成 SRT。SenseVoice 转录的具体格式可能是
    /// "[1/9] 0.00s - 54.45s\n大家晚上好...\n[2/9] 54.45s - 89.22s\n还..."
    /// 之类。SRT 段格式：
    ///
    ///   1
    ///   00:00:00,000 --> 00:00:54,450
    ///   大家晚上好...
    ///
    ///   2
    ///   ...
    private func buildSRT(from transcript: String) -> String {
        // 用正则找形如 `[1/9] 0.00s - 54.45s` 的 header
        let pattern = #"\[(\d+)/\d+\]\s+([\d.]+)s\s*-\s*([\d.]+)s"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let nsTranscript = transcript as NSString
        let matches = regex.matches(in: transcript, range: NSRange(location: 0, length: nsTranscript.length))
        guard !matches.isEmpty else {
            // Fallback：整段当一条字幕 0-30s。比啥都没有强。
            return """
            1
            00:00:00,000 --> 00:00:30,000
            \(transcript.trimmingCharacters(in: .whitespacesAndNewlines))

            """
        }

        var srt = ""
        var idx = 1
        for (i, m) in matches.enumerated() {
            guard m.numberOfRanges >= 4 else { continue }
            let startStr = nsTranscript.substring(with: m.range(at: 2))
            let endStr = nsTranscript.substring(with: m.range(at: 3))
            guard let start = Double(startStr), let end = Double(endStr), end > start else { continue }

            // 段内容：从 match end 到下一个 match start（或文件末尾）
            let textStart = m.range.location + m.range.length
            let textEnd: Int
            if i + 1 < matches.count {
                textEnd = matches[i + 1].range.location
            } else {
                textEnd = nsTranscript.length
            }
            let textRange = NSRange(location: textStart, length: textEnd - textStart)
            let text = nsTranscript.substring(with: textRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            srt += "\(idx)\n\(srtTimestamp(start)) --> \(srtTimestamp(end))\n\(text)\n\n"
            idx += 1
        }
        return srt
    }

    /// 把秒（含小数）转成 SRT 时间戳 `HH:MM:SS,mmm`。
    private func srtTimestamp(_ seconds: Double) -> String {
        let totalMs = Int((seconds * 1000).rounded())
        let h = totalMs / 3_600_000
        let m = (totalMs % 3_600_000) / 60_000
        let s = (totalMs % 60_000) / 1000
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private func runFFmpeg(_ arguments: [String]) throws {
        let p = Process()
        p.launchPath = "/usr/bin/env"
        p.arguments = ["-S", "ffmpeg"] + arguments
        p.standardOutput = Pipe()
        let errPipe = Pipe()
        p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "video-subtitle", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg exit \(p.terminationStatus): \(err.suffix(400))"
            ])
        }
    }
}
