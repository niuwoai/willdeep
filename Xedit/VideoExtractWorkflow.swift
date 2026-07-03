//
//  VideoExtractWorkflow.swift
//  WillDeep
//
//  /video-extract <path> — 一键 dump 这个视频里所有"可抄"的素材到
//  ~/Downloads/<stem>-extracted-<timestamp>/。专门为"照抄别人视频"
//  设计：技术参数 + 音轨 + 转录 + 场景切换抽帧 + LLM 综合分析。
//
//  目录结构：
//   ├── metadata.json     ffprobe -show_format -show_streams 全部 JSON
//   ├── audio.m4a         音轨复制（无重编码）
//   ├── transcript.md     带时间戳的转录
//   ├── keyframes/        ffmpeg scene-detect 抽出的关键帧（00-..jpg）
//   └── report.md         1 个 sub-agent 综合写的「这视频是怎么做的」分析
//

import Foundation
import AVFoundation

struct VideoExtractWorkflow: WorkflowDefinition {
    var name: String { "video-extract" }
    var displayTitle: String { "Video Extract" }
    var slashCommand: String { "/video-extract" }
    var shortDescription: String { "Dump every reusable element from a video — metadata, audio, transcript, keyframes, analysis" }
    var argsPlaceholder: String { "<path to video>" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    /// 关键帧抽取的 scene threshold。0.3 偏宽松（多抽），0.5 偏严格
    /// （少而精）。0.4 是 ffmpeg 文档推荐值。
    private let sceneThreshold = 0.4
    /// 关键帧数量硬上限 —— 超长视频不至于 dump 几百张图。
    private let maxKeyframes = 40

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let path = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return "Usage: `/video-extract <path>`, e.g. `/video-extract ~/Movies/inspo.mp4`."
        }

        do {
            try WhisperPreflight.checkModel()
            try VideoToolPreflight.checkFFmpeg()
            try VideoToolPreflight.checkFFprobe()
            try VideoToolPreflight.checkLocalVideoFile(path)
        } catch let f as WhisperPreflight.Failure { return f.errorDescription ?? "Preflight failed." }
        catch let f as VideoToolPreflight.Failure { return f.errorDescription ?? "Preflight failed." }

        let expanded = (path as NSString).expandingTildeInPath
        let videoURL = URL(fileURLWithPath: expanded)
        let stem = videoURL.deletingPathExtension().lastPathComponent

        // 输出目录：~/Downloads/<stem>-extracted-<ts>/
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let stamp = Int(Date().timeIntervalSince1970)
        let outputDir = downloads.appendingPathComponent("\(stem)-extracted-\(stamp)")
        let keyframesDir = outputDir.appendingPathComponent("keyframes")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: keyframesDir, withIntermediateDirectories: true)

        // -- 1. ffprobe metadata.json --
        let metadataURL = outputDir.appendingPathComponent("metadata.json")
        let probeJSON: [String: Any]
        do {
            probeJSON = try await VideoMediaHelpers.probe(videoURL: videoURL)
            let data = try JSONSerialization.data(withJSONObject: probeJSON, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: metadataURL)
        } catch {
            return "ffprobe failed: \(error.localizedDescription)"
        }

        // -- 2. 音轨复制到 audio.m4a（无重编码）--
        let audioURL = outputDir.appendingPathComponent("audio.m4a")
        do {
            try await runFFmpeg([
                "-y", "-i", videoURL.path,
                "-vn", "-c:a", "copy",
                audioURL.path,
            ])
        } catch {
            // 不少视频音轨非 AAC（比如 MP3-in-MOV），-c copy 进 m4a 会
            // 抱怨。fallback：转 AAC。
            do {
                try await runFFmpeg([
                    "-y", "-i", videoURL.path,
                    "-vn", "-c:a", "aac", "-b:a", "128k",
                    audioURL.path,
                ])
            } catch {
                return "Audio extract failed (both copy and re-encode paths): \(error.localizedDescription)"
            }
        }

        // -- 3. 关键帧抽到 keyframes/<N>.jpg —— ffmpeg scene-detect --
        // ffmpeg 的 select='gt(scene,T)' 会跳到下一个场景切换；用
        // -vsync vfr 避免重复帧。文件名按 ffmpeg 自动编号。
        do {
            try await runFFmpeg([
                "-y", "-i", videoURL.path,
                "-vf", "select='gt(scene,\(sceneThreshold))',showinfo",
                "-vsync", "vfr",
                "-frames:v", "\(maxKeyframes)",
                "-q:v", "3",
                keyframesDir.appendingPathComponent("scene-%03d.jpg").path,
            ])
        } catch {
            // 不致命 —— 极静态视频可能完全抽不到 scene。继续。
        }

        let keyframeCount = ((try? FileManager.default.contentsOfDirectory(atPath: keyframesDir.path)) ?? [])
            .filter { $0.hasSuffix(".jpg") }
            .count

        // -- 4. STT transcript.md --
        // 临时 wav 提取，跑 SenseVoice，写带时间戳的 markdown。
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillDeep-Extract-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let wavURL = workDir.appendingPathComponent("audio.wav")
        var transcript = ""
        do {
            try await VideoMediaHelpers.extractWavAudio(videoURL: videoURL, audioURL: wavURL)
            transcript = try await SpeechTranscriber.transcribe(
                audioURL: wavURL,
                language: .auto,
                enableCTCDeduplication: false
            )
        } catch {
            transcript = "(transcription failed: \(error.localizedDescription))"
        }
        let transcriptMD = """
        # Transcript — \(stem)

        Source: `\(expanded)`

        \(transcript)
        """
        let transcriptURL = outputDir.appendingPathComponent("transcript.md")
        try? transcriptMD.write(to: transcriptURL, atomically: true, encoding: .utf8)

        // -- 5. 综合 report.md：1 个 sub-agent 看 metadata + transcript --
        let techSpecs = summarizeProbe(probeJSON)
        let durationSeconds = (try? await AVURLAsset(url: videoURL).load(.duration))?.seconds ?? 0
        let reportPrompt = """
        You're being given the full extracted contents of a video so you
        can analyze "how this video is put together" — the user wants to
        understand the structure, pacing, voice/tone, and technical
        choices in order to make something similar.

        Source: `\(expanded)` · Duration: \(formatDuration(durationSeconds))

        Technical specs (from ffprobe):

        \(techSpecs)

        Transcript:

        \(transcript)

        Keyframes available: \(keyframeCount) scene-detected frames in `\(keyframesDir.path)`

        Produce a markdown analysis named "How this video was made":

        # How this video was made

        ## TL;DR
        2-3 sentences: what the video does and what's most distinctive
        about its construction.

        ## Structure
        Inferred chapters or beats from the transcript — title + 1-line
        summary + approximate timestamp (mm:ss). Aim for 4-10 beats.

        ## Voice & tone
        How does the narrator/speaker present? Pacing, register, fillers,
        rhetorical moves. Quote 2-3 distinctive lines verbatim.

        ## Technical choices
        Read from the specs above — resolution, fps, bitrate, codec,
        audio quality. Comment on what those choices say about the
        production (mobile-first? edited in a desktop NLE? livestream
        upload?).

        ## How to imitate
        3-5 concrete steps someone could take to make a similar video,
        in priority order. Be specific (e.g. "shoot at 30fps to match
        the slightly cinematic feel" — not "shoot good footage").
        """
        var reportBody = ""
        do {
            reportBody = try await engine.agent(reportPrompt, label: "analyze")
        } catch {
            reportBody = "_(analysis agent failed: \(error.localizedDescription))_"
        }
        let reportURL = outputDir.appendingPathComponent("report.md")
        try? reportBody.write(to: reportURL, atomically: true, encoding: .utf8)

        // -- 6. Keyframes widget：6 张代表帧缩成 240px jpg 后 base64
        //       嵌进 HTML，让用户直接在 transcript 里看到画面概览。
        //       Widget HTML 上限 1 MB —— 6 张 240px jpg 大约 120-180 KB
        //       base64，安全。
        await pushKeyframeGalleryWidget(
            engine: engine,
            keyframesDir: keyframesDir,
            stem: stem
        )

        // -- 7. 返回 workflow card summary --
        let audioBytes = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0
        let audioMB = Double(audioBytes) / (1024 * 1024)

        return """
        # Video extracted

        Source: `\(expanded)` (\(formatDuration(durationSeconds)))
        Output: `\(outputDir.path)/`

        | File | Note |
        |---|---|
        | `metadata.json` | Full ffprobe output (format + streams) |
        | `audio.m4a` | Audio track copy (\(String(format: "%.1f MB", audioMB))) |
        | `transcript.md` | SenseVoice transcript |
        | `keyframes/` | \(keyframeCount) scene-detected frames (jpg) |
        | `report.md` | LLM "how this was made" analysis |

        ## How this video was made

        \(reportBody)

        ---

        Open the folder:

        ```
        open "\(outputDir.path)"
        ```
        """
    }

    private func summarizeProbe(_ probe: [String: Any]) -> String {
        var lines: [String] = []
        if let format = probe["format"] as? [String: Any] {
            if let duration = format["duration"] as? String { lines.append("- duration: \(duration)s") }
            if let size = format["size"] as? String, let bytes = Int(size) {
                lines.append("- size: \(bytes / 1024 / 1024) MB")
            }
            if let bitRate = format["bit_rate"] as? String, let br = Int(bitRate) {
                lines.append("- total bitrate: \(br / 1000) kbps")
            }
            if let formatName = format["format_long_name"] as? String { lines.append("- container: \(formatName)") }
        }
        if let streams = probe["streams"] as? [[String: Any]] {
            for stream in streams {
                let codecType = (stream["codec_type"] as? String) ?? "?"
                let codecName = (stream["codec_name"] as? String) ?? "?"
                if codecType == "video" {
                    let width = stream["width"] as? Int ?? 0
                    let height = stream["height"] as? Int ?? 0
                    let frameRate = stream["avg_frame_rate"] as? String ?? "?"
                    let pixFmt = stream["pix_fmt"] as? String ?? "?"
                    let videoBitrate = (stream["bit_rate"] as? String).flatMap { Int($0) }.map { "\($0 / 1000) kbps" } ?? "?"
                    lines.append("- video: \(codecName) \(width)×\(height) @ \(frameRate) fps · \(pixFmt) · \(videoBitrate)")
                } else if codecType == "audio" {
                    let sampleRate = stream["sample_rate"] as? String ?? "?"
                    let channels = stream["channels"] as? Int ?? 0
                    let audioBitrate = (stream["bit_rate"] as? String).flatMap { Int($0) }.map { "\($0 / 1000) kbps" } ?? "?"
                    lines.append("- audio: \(codecName) \(sampleRate) Hz \(channels)ch · \(audioBitrate)")
                }
            }
        }
        return lines.isEmpty ? "(no probe data)" : lines.joined(separator: "\n")
    }

    private func runFFmpeg(_ arguments: [String]) async throws {
        let p = Process()
        p.launchPath = "/usr/bin/env"
        p.arguments = ["-S", "ffmpeg"] + arguments
        p.standardOutput = Pipe()
        let errPipe = Pipe()
        p.standardError = errPipe
        try p.run()
        await AgentProcessSupport.waitUntilExit(p)
        if p.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "video-extract", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg exit \(p.terminationStatus): \(err.suffix(400))"
            ])
        }
    }

    /// 从 keyframesDir 里挑最多 6 张，缩到 240px 宽，base64 嵌入 HTML
    /// gallery widget 推到 transcript。失败静默 —— 主流程已经成功。
    private func pushKeyframeGalleryWidget(
        engine: WorkflowEngine,
        keyframesDir: URL,
        stem: String
    ) async {
        let frames = ((try? FileManager.default.contentsOfDirectory(atPath: keyframesDir.path)) ?? [])
            .filter { $0.hasSuffix(".jpg") }
            .sorted()
        guard !frames.isEmpty else { return }

        // 等距挑 6 张代表
        let picks: [String]
        if frames.count <= 6 {
            picks = frames
        } else {
            let step = Double(frames.count) / 6.0
            picks = (0..<6).map { i in
                let idx = min(Int(Double(i) * step), frames.count - 1)
                return frames[idx]
            }
        }

        // 缩图到临时目录
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillDeep-ExtractThumbs-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        var cards: [(name: String, base64: String)] = []
        for (i, name) in picks.enumerated() {
            let src = keyframesDir.appendingPathComponent(name)
            let dst = workDir.appendingPathComponent("thumb-\(i).jpg")
            do {
                try await runFFmpeg([
                    "-y", "-i", src.path,
                    "-vf", "scale=240:-1",
                    "-q:v", "5",
                    dst.path,
                ])
            } catch { continue }
            guard let data = try? Data(contentsOf: dst) else { continue }
            cards.append((name, data.base64EncodedString()))
        }
        guard !cards.isEmpty else { return }

        let imgs = cards.map { card in
            // 从文件名抽时间标签（best-effort —— 文件名可能是 scene-001.jpg）
            let label = card.name.replacingOccurrences(of: ".jpg", with: "")
            return """
            <figure style="margin:0;display:flex;flex-direction:column;gap:4px;align-items:center;">
                <img src="data:image/jpeg;base64,\(card.base64)" style="width:100%;border-radius:4px;border:1px solid rgba(255,255,255,0.08);" />
                <figcaption style="font-size:10px;color:var(--secondary);">\(label)</figcaption>
            </figure>
            """
        }.joined(separator: "\n")

        let html = """
        <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:10px;">
            \(imgs)
        </div>
        """

        let widget = AgentWidget(title: "\(stem) — keyframes", html: html)
        await engine.displayWidget(widget)
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
