//
//  VideoGifWorkflow.swift
//  WillDeep
//
//  /video-gif <path> <description> — 转录 → LLM 找精彩段（5-12s）→
//  ffmpeg palette-optimized GIF。先 `palettegen` 提取色板，再
//  `paletteuse` 应用色板做出明显比 naive GIF 小且色彩准确的输出。
//

import Foundation
import AVFoundation

struct VideoGifWorkflow: WorkflowDefinition {
    var name: String { "video-gif" }
    var displayTitle: String { "Video → GIF" }
    var slashCommand: String { "/video-gif" }
    var shortDescription: String { "Pick a memorable moment by description and ffmpeg-encode it as an optimized GIF" }
    var argsPlaceholder: String { "<path> <what part should become a gif>" }
    var maxAgents: Int { 2 }
    var allowsEmptyArgs: Bool { false }

    /// GIF 段长上限。给得太大文件爆炸，给得太短意思不到。
    private let maxDurationSeconds = 12
    private let preferredFps = 12
    /// GIF 宽度。原视频 > 720p 时缩到这个值省体积；≤ 720p 保持原宽。
    private let scaleWidth = 480

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let spaceIdx = trimmed.firstIndex(of: " ") else {
            return "Usage: `/video-gif <path> <description>`, e.g. `/video-gif ~/Movies/funny.mp4 the moment the cat jumps onto the keyboard`."
        }
        let path = String(trimmed[..<spaceIdx])
        let description = String(trimmed[trimmed.index(after: spaceIdx)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            return "Missing description. Usage: `/video-gif <path> <description>`."
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
            .appendingPathComponent("WillDeep-Gif-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let audioURL = workDir.appendingPathComponent("audio.wav")
        do {
            try await VideoMediaHelpers.extractWavAudio(videoURL: videoURL, audioURL: audioURL)
        } catch {
            return "Audio extraction failed: \(error.localizedDescription)"
        }
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

        let locatorPrompt = """
        You are picking a short moment to clip from a video to turn into
        a GIF. Video duration: \(formatHMS(durationSeconds)).

        User wants:
        \(description)

        Transcript (with timestamp markers preceding chunks):

        \(transcript)

        Choose a SHORT segment — strictly between 3 and \(maxDurationSeconds) seconds.
        Pick a punchy moment that captures the described content. Round
        to the nearest second.

        Output ONLY one line of valid JSON, no markdown, no commentary:
        {"start_seconds": <int>, "duration_seconds": <int>, "caption": "<one short sentence to describe the moment>"}

        If you can't find a matching short moment, output exactly:
        {"error": "no match"}
        """
        let locator = try await engine.agent(locatorPrompt, label: "locate")

        guard let pick = parsePickJSON(locator) else {
            return """
            Could not pick a moment.

            Locator response:

            \(locator)

            Transcript (manual pick reference):

            \(transcript)
            """
        }

        // 1. palettegen
        let paletteURL = workDir.appendingPathComponent("palette.png")
        let scaleFilter = "fps=\(preferredFps),scale=\(scaleWidth):-1:flags=lanczos"
        do {
            try await runFFmpeg([
                "-y",
                "-ss", "\(pick.start)",
                "-t", "\(pick.duration)",
                "-i", videoURL.path,
                "-vf", "\(scaleFilter),palettegen=stats_mode=diff",
                paletteURL.path,
            ])
        } catch {
            return "ffmpeg palettegen failed: \(error.localizedDescription)"
        }

        // 2. paletteuse
        let outputURL = makeOutputURL(originalPath: expanded, suffix: "-gif")
        do {
            try await runFFmpeg([
                "-y",
                "-ss", "\(pick.start)",
                "-t", "\(pick.duration)",
                "-i", videoURL.path,
                "-i", paletteURL.path,
                "-lavfi", "\(scaleFilter) [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=5",
                outputURL.path,
            ])
        } catch {
            return "ffmpeg paletteuse failed: \(error.localizedDescription)"
        }

        let outputBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        let outputKB = Double(outputBytes) / 1024.0

        return """
        # GIF created

        - **Source**: `\(expanded)`
        - **Range**: \(formatHMS(Double(pick.start))) (+\(pick.duration)s)
        - **Output**: `\(outputURL.path)` (\(formatSize(outputKB)))
        - **Caption**: \(pick.caption)
        - **Encoder**: ffmpeg palettegen + paletteuse, \(preferredFps) fps, \(scaleWidth)px wide

        Preview / share:

        ```
        open "\(outputURL.path)"
        ```
        """
    }

    private struct PickRange {
        let start: Int
        let duration: Int
        let caption: String
    }

    private func parsePickJSON(_ text: String) -> PickRange? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            guard let start = obj["start_seconds"] as? Int,
                  let duration = obj["duration_seconds"] as? Int,
                  duration >= 3, duration <= maxDurationSeconds,
                  start >= 0 else {
                continue
            }
            let caption = (obj["caption"] as? String) ?? ""
            return PickRange(start: start, duration: duration, caption: caption)
        }
        return nil
    }

    private func runFFmpeg(_ arguments: [String]) async throws {
        let p = Process()
        p.launchPath = "/usr/bin/env"
        p.arguments = ["-S", "ffmpeg"] + arguments
        let errPipe = Pipe()
        p.standardOutput = Pipe()
        p.standardError = errPipe
        try p.run()
        await AgentProcessSupport.waitUntilExit(p)
        if p.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "video-gif", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg exit \(p.terminationStatus): \(err.suffix(500))"
            ])
        }
    }

    private func makeOutputURL(originalPath: String, suffix: String) -> URL {
        let originalURL = URL(fileURLWithPath: originalPath)
        let stem = originalURL.deletingPathExtension().lastPathComponent
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let stamp = Int(Date().timeIntervalSince1970)
        return downloads.appendingPathComponent("\(stem)\(suffix)-\(stamp).gif")
    }

    private func formatHMS(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func formatSize(_ kb: Double) -> String {
        if kb >= 1024 { return String(format: "%.1f MB", kb / 1024) }
        return String(format: "%.0f KB", kb)
    }
}
