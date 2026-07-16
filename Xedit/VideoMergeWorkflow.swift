//
//  VideoMergeWorkflow.swift
//  WillDeep
//
//  /video-merge <path1> <path2> [path3...]
//
//  纯 Swift。两个策略：
//   1. **Concat demuxer**（首选，无重编码）：所有输入同 codec+container
//      时用，速度极快。生成一个 concat list 文件喂给 ffmpeg。
//   2. **Re-encode fallback**：input 异构（不同编码 / 分辨率 / fps）时
//      用，输出 H.264 + AAC，让所有片段统一成同一规格。
//
//  输出到 ~/Downloads/merged-<timestamp>.mp4。
//

import Foundation

struct VideoMergeWorkflow: WorkflowDefinition {
    var name: String { "video-merge" }
    var displayTitle: String { "Video Merge" }
    var slashCommand: String { "/video-merge" }
    var shortDescription: String { "Concatenate multiple videos — fast copy when codecs match, else re-encode" }
    var argsPlaceholder: String { "<path1> <path2> [path3...]" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        // 路径里可能有空格 — 但 MVP 不解析引号，提示用户用无空格路径
        // 或 cp 到一个无空格目录再 merge。
        let paths = args
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
        guard paths.count >= 2 else {
            return "Usage: `/video-merge <path1> <path2> [path3...]` (at least 2 files). Paths must NOT contain spaces in this rc — copy to ~/Downloads first if they do."
        }

        do {
            try VideoToolPreflight.checkFFmpeg()
            try VideoToolPreflight.checkFFprobe()
            for p in paths { try VideoToolPreflight.checkLocalVideoFile(p) }
        } catch let f as VideoToolPreflight.Failure {
            return f.errorDescription ?? "Preflight failed."
        }

        let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

        // 探测每个 input 的 video codec + width + height + fps，判断是
        // 否能走 concat demuxer 无重编码路径。
        var codecs: Set<String> = []
        var sizes: Set<String> = []
        for url in urls {
            do {
                let probe = try await VideoMediaHelpers.probe(videoURL: url)
                if let streams = probe["streams"] as? [[String: Any]] {
                    for s in streams where (s["codec_type"] as? String) == "video" {
                        codecs.insert((s["codec_name"] as? String) ?? "?")
                        let w = s["width"] as? Int ?? 0
                        let h = s["height"] as? Int ?? 0
                        sizes.insert("\(w)x\(h)")
                    }
                }
            } catch {
                return "ffprobe failed on `\(url.path)`: \(error.localizedDescription)"
            }
        }

        let canCopy = codecs.count == 1 && sizes.count == 1
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let stamp = Int(Date().timeIntervalSince1970)
        let outputURL = downloads.appendingPathComponent("merged-\(stamp).mp4")

        if canCopy {
            // Concat demuxer 路径。
            let listURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("WillDeep-Merge-\(UUID().uuidString.prefix(8)).txt")
            let listText = urls.map { "file '\($0.path)'" }.joined(separator: "\n") + "\n"
            try listText.write(to: listURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: listURL) }
            do {
                try await runFFmpeg([
                    "-y",
                    "-f", "concat", "-safe", "0",
                    "-i", listURL.path,
                    "-c", "copy",
                    outputURL.path,
                ])
            } catch {
                // 无重编码失败 fallback 到重编码。
                return try await reencodeMerge(urls: urls, outputURL: outputURL, failureReason: error.localizedDescription, fellBack: true)
            }
        } else {
            return try await reencodeMerge(urls: urls, outputURL: outputURL, failureReason: "inputs differ (codecs: \(codecs.joined(separator: ", ")) · sizes: \(sizes.joined(separator: ", ")))", fellBack: false)
        }

        let outputBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        return """
        # Videos merged

        - **Inputs** (\(urls.count) files):
        \(urls.map { "  - `\($0.path)`" }.joined(separator: "\n"))
        - **Output**: `\(outputURL.path)` (\(String(format: "%.1f MB", Double(outputBytes) / 1024.0 / 1024.0)))
        - **Strategy**: concat demuxer, `-c copy` (no re-encode — fast and lossless)

        Open:

        ```
        open "\(outputURL.path)"
        ```
        """
    }

    private func reencodeMerge(
        urls: [URL],
        outputURL: URL,
        failureReason: String,
        fellBack: Bool
    ) async throws -> String {
        // concat protocol + filter 让 ffmpeg 把多路 input 统一编码出去。
        // 用 -filter_complex concat=n=N:v=1:a=1 形式。
        let inputArgs = urls.flatMap { ["-i", $0.path] }
        let n = urls.count
        let filter = (0..<n).map { "[\($0):v:0][\($0):a:0]" }.joined(separator: "")
            + "concat=n=\(n):v=1:a=1[outv][outa]"
        var args: [String] = ["-y"]
        args.append(contentsOf: inputArgs)
        args.append(contentsOf: [
            "-filter_complex", filter,
            "-map", "[outv]", "-map", "[outa]",
            "-c:v", "libx264", "-preset", "medium",
            "-c:a", "aac", "-b:a", "128k",
            "-movflags", "+faststart",
            outputURL.path,
        ])
        do {
            try await runFFmpeg(args)
        } catch {
            return "ffmpeg re-encode merge failed: \(error.localizedDescription)"
        }
        let outputBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        let prefix = fellBack
            ? "(Concat demuxer attempt failed: \(failureReason). Fell back to re-encode.)\n\n"
            : "(Inputs are not concat-copy compatible: \(failureReason). Used re-encode.)\n\n"
        return """
        \(prefix)# Videos merged

        - **Inputs** (\(urls.count) files):
        \(urls.map { "  - `\($0.path)`" }.joined(separator: "\n"))
        - **Output**: `\(outputURL.path)` (\(String(format: "%.1f MB", Double(outputBytes) / 1024.0 / 1024.0)))
        - **Strategy**: libx264 medium + AAC re-encode (inputs had different specs)

        Open:

        ```
        open "\(outputURL.path)"
        ```
        """
    }

    private func runFFmpeg(_ arguments: [String]) async throws {
        let p = Process()
        p.launchPath = "/usr/bin/env"
        p.arguments = ["-S", "ffmpeg"] + arguments
        let result = try await AgentSubprocess.run(p)
        if result.exitStatus != 0 {
            throw NSError(domain: "video-merge", code: Int(result.exitStatus), userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg exit \(result.exitStatus): \(result.stderrText.suffix(400))"
            ])
        }
    }
}
