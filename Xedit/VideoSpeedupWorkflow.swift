//
//  VideoSpeedupWorkflow.swift
//  WillDeep
//
//  /video-speedup <path> <factor>
//
//  纯 Swift。Factor 范围 0.25-4.0。`setpts=PTS/factor` 改变 video PTS；
//  `atempo=factor` 改变 audio tempo（atempo 单次 0.5-2.0，超过要 chain
//  多个 atempo）。视频和音频保持同步。
//

import Foundation

struct VideoSpeedupWorkflow: WorkflowDefinition {
    var name: String { "video-speedup" }
    var displayTitle: String { "Video Speed Up / Slow Down" }
    var slashCommand: String { "/video-speedup" }
    var shortDescription: String { "Change playback speed of a video (audio + video stay in sync). Range 0.25× – 4×." }
    var argsPlaceholder: String { "<path> <factor>  (e.g. 2 for 2×, 0.5 for half-speed)" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let tokens = args.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count >= 2,
              let factor = Double(tokens[1]),
              factor >= 0.25, factor <= 4.0 else {
            return "Usage: `/video-speedup <path> <factor>` with factor in 0.25–4.0. E.g. `/video-speedup ~/Movies/x.mp4 2` (2×), `/video-speedup x.mp4 0.5` (half-speed)."
        }
        let path = tokens[0]

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
        let suffix = factor >= 1 ? "fast\(formatFactor(factor))x" : "slow\(formatFactor(factor))x"
        let outputURL = downloads.appendingPathComponent("\(stem)-\(suffix)-\(stamp).mp4")

        let atempoChain = buildAtempoChain(for: factor)
        // `setpts=PTS/factor` 中 factor 是音视频共同的速率倍率：>1 加速，
        // <1 慢放。注意 PTS/factor，不是 PTS*factor。
        let videoSetpts = "setpts=PTS/\(factor)"
        let filter = "[0:v]\(videoSetpts)[v];[0:a]\(atempoChain)[a]"

        do {
            try await runFFmpeg([
                "-y", "-i", videoURL.path,
                "-filter_complex", filter,
                "-map", "[v]", "-map", "[a]",
                "-c:v", "libx264", "-preset", "medium",
                "-c:a", "aac", "-b:a", "128k",
                "-movflags", "+faststart",
                outputURL.path,
            ])
        } catch {
            return "ffmpeg setpts/atempo failed: \(error.localizedDescription)"
        }

        let outputBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        return """
        # Speed adjusted

        - **Source**: `\(expanded)`
        - **Output**: `\(outputURL.path)` (\(String(format: "%.1f MB", Double(outputBytes) / 1024.0 / 1024.0)))
        - **Factor**: \(factor)× (\(factor > 1 ? "faster" : factor < 1 ? "slower" : "unchanged"))
        - **Filters**: `\(videoSetpts)` + `\(atempoChain)`

        Open:

        ```
        open "\(outputURL.path)"
        ```
        """
    }

    /// `atempo` 单步范围 [0.5, 2.0]。要做 4× 就 chain 两个 `atempo=2`，
    /// 0.25× 就 chain 两个 `atempo=0.5`。
    private func buildAtempoChain(for factor: Double) -> String {
        var remaining = factor
        var parts: [String] = []
        while remaining > 2.0 {
            parts.append("atempo=2.0")
            remaining /= 2.0
        }
        while remaining < 0.5 {
            parts.append("atempo=0.5")
            remaining /= 0.5
        }
        // 最后一步
        if abs(remaining - 1.0) > 0.001 {
            parts.append(String(format: "atempo=%.4f", remaining))
        }
        return parts.isEmpty ? "anull" : parts.joined(separator: ",")
    }

    private func formatFactor(_ factor: Double) -> String {
        // 文件名里别用 `.`，会被 macOS 当扩展名分隔。改 `_`。
        let raw = String(format: "%.2f", factor)
        return raw.replacingOccurrences(of: ".", with: "_")
    }

    private func runFFmpeg(_ arguments: [String]) async throws {
        let p = Process()
        p.launchPath = "/usr/bin/env"
        p.arguments = ["-S", "ffmpeg"] + arguments
        let result = try await AgentSubprocess.run(p)
        if result.exitStatus != 0 {
            throw NSError(domain: "video-speedup", code: Int(result.exitStatus), userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg exit \(result.exitStatus): \(result.stderrText.suffix(400))"
            ])
        }
    }
}
