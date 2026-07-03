//
//  VideoWatermarkWorkflow.swift
//  WillDeep
//
//  /video-watermark <path> "<text>" [position=br|tr|bl|tl|center] [opacity=0.5]
//
//  纯 Swift。用 ffmpeg `drawtext` filter 加文字水印，常用于"我抄了别人
//  视频但要署名我自己"或"加 @ 用户名标签"。字体走 macOS 内置 Helvetica
//  Neue（保证存在）。
//

import Foundation

struct VideoWatermarkWorkflow: WorkflowDefinition {
    var name: String { "video-watermark" }
    var displayTitle: String { "Video Watermark" }
    var slashCommand: String { "/video-watermark" }
    var shortDescription: String { "Burn a text watermark into a video (position/opacity configurable)" }
    var argsPlaceholder: String { "<path> \"<text>\" [position=br|tr|bl|tl|center] [opacity=0.5]" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    /// macOS 必装的字体路径。`drawtext` 找不到 fontfile 会失败。
    private let systemFontPath = "/System/Library/Fonts/Helvetica.ttc"

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        // 解析：第一个 token 是 path，然后引号包起来的 text，剩下是 k=v。
        // 简单解析：path 不带空格 → split 拿第一个；text 找配对引号。
        guard let (path, text, kvs) = parseArgs(args) else {
            return "Usage: `/video-watermark <path> \"<text>\" [position=br|tr|bl|tl|center] [opacity=0.5]`. Path must not contain spaces; text must be quoted with double quotes."
        }

        var position = "br"
        var opacity = 0.5
        for token in kvs {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "position":
                if ["br", "tr", "bl", "tl", "center"].contains(parts[1]) {
                    position = parts[1]
                }
            case "opacity":
                if let v = Double(parts[1]), v > 0, v <= 1 {
                    opacity = v
                }
            default: break
            }
        }

        do {
            try VideoToolPreflight.checkFFmpeg()
            try VideoToolPreflight.checkLocalVideoFile(path)
        } catch let f as VideoToolPreflight.Failure {
            return f.errorDescription ?? "Preflight failed."
        }
        guard FileManager.default.fileExists(atPath: systemFontPath) else {
            return "System font `\(systemFontPath)` not found. Without a fontfile drawtext won't render — this is unexpected on macOS."
        }

        let expanded = (path as NSString).expandingTildeInPath
        let videoURL = URL(fileURLWithPath: expanded)
        let stem = videoURL.deletingPathExtension().lastPathComponent
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let stamp = Int(Date().timeIntervalSince1970)
        let outputURL = downloads.appendingPathComponent("\(stem)-watermarked-\(stamp).mp4")

        let (x, y) = coordinates(for: position)
        // Escape special chars in text for ffmpeg drawtext.
        let escaped = escapeForDrawtext(text)
        let filter = """
        drawtext=fontfile=\(systemFontPath):text='\(escaped)':fontsize=h/24:fontcolor=white@\(opacity):x=\(x):y=\(y):box=1:boxcolor=black@\(opacity * 0.6):boxborderw=8
        """

        do {
            try await runFFmpeg([
                "-y", "-i", videoURL.path,
                "-vf", filter,
                "-c:a", "copy",
                "-movflags", "+faststart",
                outputURL.path,
            ])
        } catch {
            return "ffmpeg drawtext failed: \(error.localizedDescription)"
        }

        let outputBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        return """
        # Watermark added

        - **Source**: `\(expanded)`
        - **Output**: `\(outputURL.path)` (\(String(format: "%.1f MB", Double(outputBytes) / 1024.0 / 1024.0)))
        - **Text**: `\(text)`
        - **Position**: \(position) · **Opacity**: \(opacity)

        Open:

        ```
        open "\(outputURL.path)"
        ```
        """
    }

    /// 解析 args。`<path> "<text>" k=v k=v` 形式。
    private func parseArgs(_ raw: String) -> (path: String, text: String, kvs: [String])? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 找 path（第一个空格之前）
        let spaceIdx = trimmed.firstIndex(of: " ") ?? trimmed.endIndex
        let path = String(trimmed[..<spaceIdx])
        guard !path.isEmpty else { return nil }
        guard spaceIdx < trimmed.endIndex else { return nil }
        let rest = String(trimmed[trimmed.index(after: spaceIdx)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 找 text —— 配对 " "
        guard rest.hasPrefix("\"") else { return nil }
        let afterFirstQuote = rest.index(after: rest.startIndex)
        guard let closeQuote = rest[afterFirstQuote...].firstIndex(of: "\"") else { return nil }
        let text = String(rest[afterFirstQuote..<closeQuote])
        // kvs：closeQuote 之后剩下的
        let tail = String(rest[rest.index(after: closeQuote)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let kvs = tail.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return (path, text, kvs)
    }

    private func coordinates(for position: String) -> (x: String, y: String) {
        let margin = "20"
        switch position {
        case "tr": return ("w-tw-\(margin)", margin)
        case "bl": return (margin, "h-th-\(margin)")
        case "tl": return (margin, margin)
        case "center": return ("(w-tw)/2", "(h-th)/2")
        default: return ("w-tw-\(margin)", "h-th-\(margin)")  // br
        }
    }

    /// ffmpeg `drawtext` 的 text 字段必须 escape：`\`、`'`、`:`、`%`。
    private func escapeForDrawtext(_ raw: String) -> String {
        var out = ""
        for ch in raw {
            switch ch {
            case "\\": out.append("\\\\")
            case "'": out.append("\\'")
            case ":": out.append("\\:")
            case "%": out.append("\\%")
            default: out.append(ch)
            }
        }
        return out
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
            throw NSError(domain: "video-watermark", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg exit \(p.terminationStatus): \(err.suffix(400))"
            ])
        }
    }
}
