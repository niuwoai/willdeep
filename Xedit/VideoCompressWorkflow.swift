//
//  VideoCompressWorkflow.swift
//  WillDeep
//
//  /video-compress <path> [target-MB] — 智能压缩视频。用 ffprobe 看
//  原视频时长 / 码率 / 分辨率，根据 target 体积计算目标 video bitrate，
//  调 ffmpeg two-pass H.264。默认目标 = 原文件的 30%（不传 target-MB
//  时）。没有 sub-agent —— 纯 Swift。
//

import Foundation

struct VideoCompressWorkflow: WorkflowDefinition {
    var name: String { "video-compress" }
    var displayTitle: String { "Video Compress" }
    var slashCommand: String { "/video-compress" }
    var shortDescription: String { "Compress a video with ffmpeg two-pass H.264 to a target size" }
    var argsPlaceholder: String { "<path> [target-MB]" }
    /// Workflow registry's "agents" counter — pure-Swift workflows
    /// still pass through the card UI, so 1 is the conventional value.
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let parts = args.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let path = parts.first, !path.isEmpty else {
            return "Usage: `/video-compress <path> [target-MB]`, e.g. `/video-compress ~/Movies/big.mp4 25`."
        }
        let targetMB: Double? = (parts.count >= 2) ? Double(parts[1]) : nil

        do {
            try VideoToolPreflight.checkFFmpeg()
            try VideoToolPreflight.checkFFprobe()
            try VideoToolPreflight.checkLocalVideoFile(path)
        } catch let f as VideoToolPreflight.Failure {
            return f.errorDescription ?? "Preflight failed."
        }

        let expanded = (path as NSString).expandingTildeInPath
        let videoURL = URL(fileURLWithPath: expanded)

        // Probe original.
        let probe: [String: Any]
        do {
            probe = try await VideoMediaHelpers.probe(videoURL: videoURL)
        } catch {
            return "ffprobe failed: \(error.localizedDescription)"
        }

        guard let format = probe["format"] as? [String: Any],
              let durationStr = format["duration"] as? String,
              let duration = Double(durationStr), duration > 0 else {
            return "ffprobe didn't return a usable duration. Is `\(expanded)` actually a video?"
        }

        let originalBytes = (try? FileManager.default.attributesOfItem(atPath: expanded)[.size] as? Int64) ?? 0
        let originalMB = Double(originalBytes) / (1024 * 1024)

        // Audio bitrate budget: fixed 128 kbps (good enough for talking
        // head / music background). Video bitrate = (target_bytes -
        // audio_bytes) / duration.
        let audioBitrateKbps: Double = 128
        let targetSizeMB = targetMB ?? (originalMB * 0.3)  // 默认 30%
        guard targetSizeMB > 0, targetSizeMB < originalMB else {
            return "Target size \(targetSizeMB) MB is invalid (must be > 0 and < original \(String(format: "%.1f", originalMB)) MB)."
        }
        let targetBytes = targetSizeMB * 1024 * 1024
        let audioBytes = (audioBitrateKbps * 1000 / 8) * duration
        let videoBytes = max(targetBytes - audioBytes, 0)
        let videoBitrateKbps = (videoBytes * 8 / 1000) / duration
        guard videoBitrateKbps >= 200 else {
            return "Target \(targetSizeMB) MB is too aggressive for a \(formatDuration(duration)) video — would need video bitrate below 200 kbps, which looks terrible. Try a larger target or use `/video-clip` first to cut down."
        }

        let outputURL = makeOutputURL(originalPath: expanded, suffix: "-compressed")
        let passLogPrefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillDeep-CompressPass-\(UUID().uuidString.prefix(8))").path
        defer {
            for ext in [".log", ".log.mbtree"] {
                try? FileManager.default.removeItem(atPath: passLogPrefix + ext)
            }
        }

        // Pass 1: analysis only, /dev/null output, no audio.
        do {
            let p1 = Process()
            p1.launchPath = "/usr/bin/env"
            p1.arguments = [
                "-S", "ffmpeg", "-y",
                "-i", videoURL.path,
                "-c:v", "libx264", "-preset", "medium",
                "-b:v", "\(Int(videoBitrateKbps))k",
                "-pass", "1", "-passlogfile", passLogPrefix,
                "-an",
                "-f", "null",
                "/dev/null",
            ]
            let result = try await AgentSubprocess.run(p1)
            if result.exitStatus != 0 {
                return "ffmpeg pass 1 failed (\(result.exitStatus)): \(result.stderrText.suffix(500))"
            }
        } catch {
            return "Failed to launch ffmpeg pass 1: \(error.localizedDescription)"
        }

        // Pass 2: real encode with audio.
        do {
            let p2 = Process()
            p2.launchPath = "/usr/bin/env"
            p2.arguments = [
                "-S", "ffmpeg", "-y",
                "-i", videoURL.path,
                "-c:v", "libx264", "-preset", "medium",
                "-b:v", "\(Int(videoBitrateKbps))k",
                "-pass", "2", "-passlogfile", passLogPrefix,
                "-c:a", "aac", "-b:a", "\(Int(audioBitrateKbps))k",
                "-movflags", "+faststart",
                outputURL.path,
            ]
            let result = try await AgentSubprocess.run(p2)
            if result.exitStatus != 0 {
                return "ffmpeg pass 2 failed (\(result.exitStatus)): \(result.stderrText.suffix(500))"
            }
        } catch {
            return "Failed to launch ffmpeg pass 2: \(error.localizedDescription)"
        }

        let actualBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        let actualMB = Double(actualBytes) / (1024 * 1024)
        let ratio = originalMB > 0 ? actualMB / originalMB : 0

        return """
        # Video compressed

        - **Source**: `\(expanded)` (\(formatMB(originalMB)))
        - **Output**: `\(outputURL.path)` (\(formatMB(actualMB)))
        - **Ratio**: \(String(format: "%.0f%%", ratio * 100)) of original
        - **Duration**: \(formatDuration(duration))
        - **Video bitrate**: \(Int(videoBitrateKbps)) kbps · **Audio**: \(Int(audioBitrateKbps)) kbps · **Codec**: H.264 (libx264, medium preset, two-pass)

        Quick check:

        ```
        open "\(outputURL.path)"
        ```
        """
    }

    private func formatMB(_ mb: Double) -> String {
        if mb >= 100 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f MB", mb)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    private func makeOutputURL(originalPath: String, suffix: String) -> URL {
        let originalURL = URL(fileURLWithPath: originalPath)
        let stem = originalURL.deletingPathExtension().lastPathComponent
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let stamp = Int(Date().timeIntervalSince1970)
        return downloads.appendingPathComponent("\(stem)\(suffix)-\(stamp).mp4")
    }
}
