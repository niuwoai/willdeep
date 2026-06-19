//
//  VideoSubtitleExportWorkflow.swift
//  WillDeep
//
//  /video-subtitle-export <path> [format=srt|vtt]
//
//  Generates a sidecar subtitle file from local SenseVoice transcription.
//

import Foundation

struct VideoSubtitleExportWorkflow: WorkflowDefinition {
    var name: String { "video-subtitle-export" }
    var displayTitle: String { "Export Subtitles" }
    var slashCommand: String { "/video-subtitle-export" }
    var shortDescription: String { "Transcribe a video and export sidecar subtitles as SRT or VTT" }
    var argsPlaceholder: String { "<path> [format=srt|vtt]" }
    var maxAgents: Int { 1 }
    var allowsEmptyArgs: Bool { false }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let parsed = ImageWorkflowSupport.parse(args)
        guard let path = parsed.positional.first else {
            return "Usage: `/video-subtitle-export <path> [format=srt|vtt]`."
        }
        let format = (parsed.options["format"] ?? "srt").lowercased()
        guard ["srt", "vtt"].contains(format) else {
            return "Unsupported subtitle format `\(format)`. Use `srt` or `vtt`."
        }

        do {
            try WhisperPreflight.checkModel()
            try VideoToolPreflight.checkFFmpeg()
            try VideoToolPreflight.checkLocalVideoFile(path)
        } catch let f as WhisperPreflight.Failure {
            return f.errorDescription ?? "Preflight failed."
        } catch let f as VideoToolPreflight.Failure {
            return f.errorDescription ?? "Preflight failed."
        }

        let expanded = (path as NSString).expandingTildeInPath
        let videoURL = URL(fileURLWithPath: expanded)
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillDeep-SubtitleExport-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

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
        guard !srt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Transcript did not yield subtitle segments."
        }
        let outputBody = format == "vtt" ? convertSRTToVTT(srt) : srt
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let stem = videoURL.deletingPathExtension().lastPathComponent
        let stamp = Int(Date().timeIntervalSince1970)
        let outputURL = downloads.appendingPathComponent("\(stem)-subtitles-\(stamp).\(format)")
        try outputBody.write(to: outputURL, atomically: true, encoding: .utf8)

        return """
        # Subtitles exported

        - **Source**: `\(expanded)`
        - **Output**: `\(outputURL.path)`
        - **Format**: \(format.uppercased())

        Open:

        ```
        open "\(outputURL.path)"
        ```
        """
    }

    private func buildSRT(from transcript: String) -> String {
        let pattern = #"\[(\d+)/\d+\]\s+([\d.]+)s\s*-\s*([\d.]+)s"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let nsTranscript = transcript as NSString
        let matches = regex.matches(in: transcript, range: NSRange(location: 0, length: nsTranscript.length))
        guard !matches.isEmpty else {
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "" }
            return """
            1
            00:00:00,000 --> 00:00:30,000
            \(text)

            """
        }

        var srt = ""
        var index = 1
        for (offset, match) in matches.enumerated() {
            guard match.numberOfRanges >= 4,
                  let start = Double(nsTranscript.substring(with: match.range(at: 2))),
                  let end = Double(nsTranscript.substring(with: match.range(at: 3))),
                  end > start else { continue }

            let textStart = match.range.location + match.range.length
            let textEnd = offset + 1 < matches.count
                ? matches[offset + 1].range.location
                : nsTranscript.length
            guard textEnd > textStart else { continue }
            let text = nsTranscript
                .substring(with: NSRange(location: textStart, length: textEnd - textStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            srt += """
            \(index)
            \(timestamp(start)) --> \(timestamp(end))
            \(text)

            """
            index += 1
        }
        return srt
    }

    private func convertSRTToVTT(_ srt: String) -> String {
        let body = srt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                Int(line.trimmingCharacters(in: .whitespacesAndNewlines)) == nil
            }
            .joined(separator: "\n")
            .replacingOccurrences(of: ",", with: ".")
        return "WEBVTT\n\n\(body)"
    }

    private func timestamp(_ seconds: Double) -> String {
        let millis = Int((seconds * 1000).rounded())
        let ms = millis % 1000
        let totalSeconds = millis / 1000
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
