//
//  VideoToolPreflight.swift
//  WillDeep
//
//  Phase 2 voice → video：检查 ffmpeg / yt-dlp 装好。/video-summary
//  workflow 开跑前 check 一次。
//

import Foundation

enum VideoToolPreflight {
    enum Failure: Error, LocalizedError {
        case ffmpegMissing
        case ytDlpMissing
        case videoFileMissing(path: String)

        var errorDescription: String? {
            switch self {
            case .ffmpegMissing:
                return "`ffmpeg` is not installed or not on PATH. Install with: `brew install ffmpeg`."
            case .ytDlpMissing:
                return "`yt-dlp` is not installed or not on PATH. Install with: `brew install yt-dlp`."
            case .videoFileMissing(let path):
                return "Video file not found: `\(path)`. Pass either a path or a video URL (YouTube / Bilibili / Vimeo / X / TikTok etc.)."
            }
        }
    }

    static func checkFFmpeg() throws {
        if run("/usr/bin/env", ["-S", "ffmpeg", "-version"]).exitCode != 0 {
            throw Failure.ffmpegMissing
        }
    }

    static func checkYtDlp() throws {
        if run("/usr/bin/env", ["-S", "yt-dlp", "--version"]).exitCode != 0 {
            throw Failure.ytDlpMissing
        }
    }

    static func checkLocalVideoFile(_ path: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: expanded) {
            throw Failure.videoFileMissing(path: path)
        }
    }

    /// Heuristic：以 http(s):// 开头视作 URL，其它视作本地路径。
    static func isURL(_ input: String) -> Bool {
        let lower = input.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    private struct RunResult {
        let exitCode: Int32
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> RunResult {
        let process = Process()
        process.launchPath = launchPath
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return RunResult(exitCode: -1)
        }
        process.waitUntilExit()
        return RunResult(exitCode: process.terminationStatus)
    }
}
