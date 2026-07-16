//
//  VideoThumbnailWorkflow.swift
//  WillDeep
//
//  /video-thumbnail <path> [mode=scene|interval] [count=N]
//
//  纯 Swift —— 不调 LLM。ffmpeg 抽帧到 `~/Downloads/<stem>-thumbs-<ts>/`
//  外加一张 contact-sheet `<stem>-sheet-<ts>.jpg`（把多张帧拼一张大图，
//  方便预览整段视频的视觉概要）。
//
//  两种模式：
//   - `scene`（默认）：用 `select='gt(scene,0.4)'` 抽场景切换帧
//   - `interval`：等距抽 N 帧（默认 12 张）
//

import Foundation
import AVFoundation

struct VideoThumbnailWorkflow: WorkflowDefinition {
    var name: String { "video-thumbnail" }
    var displayTitle: String { "Video Thumbnail" }
    var slashCommand: String { "/video-thumbnail" }
    var shortDescription: String { "Pull representative frames (scene-change or interval) + a contact sheet" }
    var argsPlaceholder: String { "<path> [mode=scene|interval] [count=N]" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    private let defaultIntervalCount = 12
    private let maxFrames = 60
    private let sceneThreshold = 0.4

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let tokens = args.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let path = tokens.first, !path.isEmpty else {
            return "Usage: `/video-thumbnail <path> [mode=scene|interval] [count=N]`, e.g. `/video-thumbnail ~/Movies/x.mp4` or `/video-thumbnail x.mp4 mode=interval count=24`."
        }
        var mode = "scene"
        var count = defaultIntervalCount
        for token in tokens.dropFirst() {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "mode": if ["scene", "interval"].contains(parts[1]) { mode = parts[1] }
            case "count": if let n = Int(parts[1]), n > 0, n <= maxFrames { count = n }
            default: break
            }
        }

        do {
            try VideoToolPreflight.checkFFmpeg()
            try VideoToolPreflight.checkLocalVideoFile(path)
        } catch let f as VideoToolPreflight.Failure {
            return f.errorDescription ?? "Preflight failed."
        }

        let expanded = (path as NSString).expandingTildeInPath
        let videoURL = URL(fileURLWithPath: expanded)
        let stem = videoURL.deletingPathExtension().lastPathComponent
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let stamp = Int(Date().timeIntervalSince1970)
        let framesDir = downloads.appendingPathComponent("\(stem)-thumbs-\(stamp)")
        try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)

        let durationSeconds = (try? await AVURLAsset(url: videoURL).load(.duration))?.seconds ?? 0

        // 抽帧
        do {
            switch mode {
            case "scene":
                try await runFFmpeg([
                    "-y", "-i", videoURL.path,
                    "-vf", "select='gt(scene,\(sceneThreshold))'",
                    "-vsync", "vfr",
                    "-frames:v", "\(min(count * 2, maxFrames))",  // 多抽点防止 scene 太少
                    "-q:v", "3",
                    framesDir.appendingPathComponent("scene-%03d.jpg").path,
                ])
            case "interval":
                guard durationSeconds > 0 else {
                    return "Could not determine video duration. Pass mode=scene instead."
                }
                let intervalSec = max(1.0, durationSeconds / Double(count))
                try await runFFmpeg([
                    "-y", "-i", videoURL.path,
                    "-vf", "fps=1/\(intervalSec)",
                    "-frames:v", "\(count)",
                    "-q:v", "3",
                    framesDir.appendingPathComponent("frame-%03d.jpg").path,
                ])
            default:
                break
            }
        } catch {
            return "ffmpeg frame extract failed: \(error.localizedDescription)"
        }

        let frames = ((try? FileManager.default.contentsOfDirectory(atPath: framesDir.path)) ?? [])
            .filter { $0.hasSuffix(".jpg") }
            .sorted()
        guard !frames.isEmpty else {
            return "ffmpeg ran but didn't produce any frames. The video may be too static for scene detection — try `mode=interval`."
        }

        // Contact sheet：用 ffmpeg 的 tile filter 拼成大图。栅格按 frame
        // count 算 cols x rows，最多 4 列。
        let cols = min(4, frames.count)
        let rows = (frames.count + cols - 1) / cols
        let sheetURL = downloads.appendingPathComponent("\(stem)-sheet-\(stamp).jpg")
        let sheetPattern = framesDir.appendingPathComponent(
            mode == "scene" ? "scene-%03d.jpg" : "frame-%03d.jpg"
        ).path
        do {
            try await runFFmpeg([
                "-y",
                "-pattern_type", "sequence",
                "-start_number", "1",
                "-i", sheetPattern,
                "-vf", "scale=320:-1,tile=\(cols)x\(rows):padding=4:margin=4:color=#1c1c1e",
                "-frames:v", "1",
                "-q:v", "2",
                sheetURL.path,
            ])
        } catch {
            // 不致命 — 单帧已经生成。
        }

        let sheetExists = FileManager.default.fileExists(atPath: sheetURL.path)
        return """
        # Thumbnails extracted

        - **Source**: `\(expanded)` (\(formatDuration(durationSeconds)))
        - **Mode**: `\(mode)`
        - **Frames**: \(frames.count) in `\(framesDir.path)/`
        - **Contact sheet**: \(sheetExists ? "`\(sheetURL.path)`" : "_(skipped — single-image montage failed)_")

        Open the folder + sheet:

        ```
        open "\(framesDir.path)"
        \(sheetExists ? "open \"\(sheetURL.path)\"" : "")
        ```
        """
    }

    private func runFFmpeg(_ arguments: [String]) async throws {
        let p = Process()
        p.launchPath = "/usr/bin/env"
        p.arguments = ["-S", "ffmpeg"] + arguments
        let result = try await AgentSubprocess.run(p)
        if result.exitStatus != 0 {
            throw NSError(domain: "video-thumbnail", code: Int(result.exitStatus), userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg exit \(result.exitStatus): \(result.stderrText.suffix(400))"
            ])
        }
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
}
