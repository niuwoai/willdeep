//
//  VideoMediaHelpers.swift
//  WillDeep
//
//  ffmpeg/ffprobe 的共享封装。
//
//  1.262.0 之前它寄居在 VideoClipWorkflow.swift 里（那个工作流是第一个
//  需要它的）。本地转写栈下线时 /video-clip 跟着删掉，把仍在用的
//  /video-compress、/video-merge、/video-extract 一起带崩了 —— 共享
//  helper 不该住在某个具体工作流的文件里，这次给它一个自己的家。
//
//  只保留还有人用的 `probe`。`extractWavAudio`（16 kHz 单声道 PCM，
//  专供 STT）和 `cutSegment`（`-c copy` 快切，只有 /video-clip 用）
//  随转写栈一起移除。
//

import Foundation

enum VideoMediaHelpers {
    /// Run ffprobe -show_format -show_streams -of json, return JSON dict.
    static func probe(videoURL: URL) async throws -> [String: Any] {
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
        let result = try await AgentSubprocess.run(p, timeout: 60)
        if result.exitStatus != 0 {
            throw NSError(domain: "video-media", code: Int(result.exitStatus), userInfo: [
                NSLocalizedDescriptionKey: "ffprobe exit \(result.exitStatus): \(result.stderrText)"
            ])
        }
        guard let obj = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw NSError(domain: "video-media", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "ffprobe output not parseable as JSON"
            ])
        }
        return obj
    }
}
