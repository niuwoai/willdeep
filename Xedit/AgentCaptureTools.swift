//
//  AgentCaptureTools.swift
//  WillDeep
//
//  `capture_screenshot` — grab a screenshot of the local Mac, a connected
//  Android device/emulator (adb), or a booted iOS simulator (simctl), then
//  hand the pixels back to the model. Vision-capable providers see the image
//  directly (it rides on the tool_result as an image block); text-only
//  providers get the local OCR/size summary in the payload and can follow up
//  with `visual_qa_screenshot` for a VL description.
//
//  Images are downscaled to a bounded long edge before they enter the
//  conversation. This is deliberate: an unscaled retina screenshot is several
//  MB of base64 that would be re-sent every turn — the exact shape of the
//  runaway-memory incidents this codebase has fought before.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum AgentCaptureTools {
    struct PersistedCapture {
        let originalURL: URL
        let attachment: AgentImageAttachment
    }

    /// Anthropic's recommended max long edge — larger buys no quality but
    /// costs tokens and memory linearly.
    private static let maxLongEdge: CGFloat = 1568
    private static let jpegQuality: CGFloat = 0.82
    private static let maxOCRLines = 20

    /// Extra locations appended to PATH so `adb` / `xcrun` resolve even when
    /// the host process was launched from Finder (no login shell PATH).
    nonisolated private static let extraPaths = [
        "/usr/bin",
        "/usr/sbin",
        "/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        NSString(string: "~/Library/Android/sdk/platform-tools").expandingTildeInPath,
        NSString(string: "~/Android/sdk/platform-tools").expandingTildeInPath
    ]

    static func captureScreenshot(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        let target = (arguments["target"]?.stringValue() ?? "mac_screen")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let device = arguments["device"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayIndex = arguments["display"]?.intValue()
        let localObservationGuard = try await AgentComputerUseExecution
            .prepareLocalObservation(
                toolName: "capture_screenshot",
                arguments: arguments
            )

        let rawURL: URL
        let label: String
        switch target {
        case "mac_screen", "mac", "screen", "desktop":
            rawURL = try await AgentComputerUseTools.captureDisplay(
                displayIndex: displayIndex,
                sessionPersistenceBarrier: context.sessionPersistenceBarrier
            )
            label = "Mac screen"
        case "android", "adb", "device":
            rawURL = try temporaryCaptureURL(target: target)
            try await captureAndroid(to: rawURL, device: device)
            label = device?.isEmpty == false ? "Android \(device!)" : "Android device"
        case "ios_simulator", "ios", "simulator", "simctl":
            rawURL = try temporaryCaptureURL(target: target)
            try await captureIOSSimulator(to: rawURL, device: device)
            label = "iOS simulator"
        default:
            throw AgentToolError.invalidArgument(
                "unknown target `\(target)`; use mac_screen, android, or ios_simulator"
            )
        }

        do {
            // Validate we actually got a non-empty image.
            let size = (try? rawURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0 else {
                throw AgentToolError.commandFailed(1, "screenshot command produced an empty file")
            }

            let info = try ImageWorkflowSupport.loadImage(path: rawURL.path)
            let originalWidth = info.image.width
            let originalHeight = info.image.height

            // Downscale for the wire; OCR runs on the full-res original.
            let scaled = downscaled(info.image)
            guard let jpegData = encodeJPEG(scaled, quality: jpegQuality) else {
                throw AgentToolError.commandFailed(1, "failed to encode captured screenshot")
            }
            let ocrLines = (try? ImageWorkflowSupport.recognizeText(in: info.image)) ?? []
            let ocrSection = ocrMarkdown(ocrLines)
            let scaledNote = (scaled.width != originalWidth || scaled.height != originalHeight)
                ? " (downscaled to \(scaled.width)x\(scaled.height) for the model)"
                : ""

            // Do not persist pixels captured across a private takeover boundary.
            try await AgentComputerUseExecution.validateLocalObservation(
                localObservationGuard
            )
            let persistedCapture = try persistCaptureArtifacts(
                originalURL: rawURL,
                previewData: jpegData
            )
            do {
                // Close the final race between persistence and result return.
                try await AgentComputerUseExecution.validateLocalObservation(
                    localObservationGuard
                )
            } catch {
                try? FileManager.default.removeItem(
                    at: persistedCapture.originalURL.deletingLastPathComponent()
                )
                throw error
            }
            let attachment = persistedCapture.attachment

            let payload = """
            # Screenshot captured

            Target: \(label)
            Original size: \(originalWidth)x\(originalHeight)\(scaledNote)
            Saved (full resolution): `\(persistedCapture.originalURL.path)`

            The image is attached to this tool result. If you can see it, describe/act on it directly. If your model cannot see images, call `visual_qa_screenshot` on the saved path above for a VL description, or rely on the OCR below.

            ## OCR text (local, best-effort)

            \(ocrSection)
            """

            return AgentToolResult(
                summary: "Captured \(label) (\(originalWidth)x\(originalHeight))",
                payload: payload,
                images: [attachment]
            )
        } catch {
            if localObservationGuard != nil {
                try? FileManager.default.removeItem(at: rawURL)
            }
            throw error
        }
    }

    // MARK: - Capture backends

    static func persistCaptureArtifacts(
        originalURL: URL,
        previewData: Data,
        captureID: UUID = UUID(),
        capturesRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".willdeep/captures", isDirectory: true)
    ) throws -> PersistedCapture {
        let captureDirectory = capturesRoot
            .appendingPathComponent(captureID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: true
        )

        let originalExtension = originalURL.pathExtension.isEmpty
            ? "png"
            : originalURL.pathExtension.lowercased()
        let persistedOriginalURL = captureDirectory
            .appendingPathComponent("original.\(originalExtension)", isDirectory: false)
        if originalURL.standardizedFileURL != persistedOriginalURL.standardizedFileURL {
            do {
                try FileManager.default.moveItem(at: originalURL, to: persistedOriginalURL)
            } catch {
                try FileManager.default.copyItem(at: originalURL, to: persistedOriginalURL)
                try? FileManager.default.removeItem(at: originalURL)
            }
        }

        let previewURL = captureDirectory.appendingPathComponent("preview.jpg", isDirectory: false)
        try previewData.write(to: previewURL, options: [.atomic])
        let attachment = AgentImageAttachment(
            id: captureID,
            mimeType: "image/jpeg",
            filePath: previewURL.standardizedFileURL.path,
            byteCount: previewData.count,
            source: .capture,
            createdAt: Date()
        )
        return PersistedCapture(
            originalURL: persistedOriginalURL.standardizedFileURL,
            attachment: attachment
        )
    }

    static func discardPersistedCaptureArtifacts(in result: AgentToolResult) {
        let capturesRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".willdeep/captures", isDirectory: true)
            .standardizedFileURL
        for image in result.images {
            guard let filePath = image.filePath else { continue }
            let imageURL = URL(fileURLWithPath: filePath)
                .standardizedFileURL
            let captureDirectory = imageURL.deletingLastPathComponent()
            guard captureDirectory.deletingLastPathComponent() == capturesRoot else {
                continue
            }
            try? FileManager.default.removeItem(at: captureDirectory)
        }
    }

    private static func temporaryCaptureURL(target: String) throws -> URL {
        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-captures", isDirectory: true)
        try FileManager.default.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: true
        )
        let stamp = Int(Date().timeIntervalSince1970)
        return captureDirectory.appendingPathComponent("capture-\(target)-\(stamp).png")
    }

    private static func captureAndroid(to url: URL, device: String?) async throws {
        // `adb exec-out screencap -p` streams the PNG on stdout — no
        // on-device temp file / pull round-trip needed.
        var args: [String] = []
        if let device, !device.isEmpty {
            args.append(contentsOf: ["-s", device])
        }
        args.append(contentsOf: ["exec-out", "screencap", "-p"])
        try await runProcess(executable: "adb", arguments: args, stdoutToFile: url)
    }

    private static func captureIOSSimulator(to url: URL, device: String?) async throws {
        let udid = (device?.isEmpty == false) ? device! : "booted"
        try await runProcess(
            executable: "xcrun",
            arguments: ["simctl", "io", udid, "screenshot", url.path],
            stdoutToFile: nil
        )
    }

    // MARK: - Process runner

    /// Runs `executable` (resolved via an augmented PATH) with `arguments`.
    /// When `stdoutToFile` is set, stdout bytes are written there (used for
    /// `adb exec-out` which emits the PNG on stdout); otherwise the command
    /// is expected to write the file itself.
    private static func runProcess(
        executable: String,
        arguments: [String],
        stdoutToFile: URL?
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments

            var environment = ProcessInfo.processInfo.environment
            let existingPath = environment["PATH"] ?? ""
            let merged = (extraPaths + existingPath.split(separator: ":").map(String.init))
            var seen = Set<String>()
            let dedupedPath = merged.filter { seen.insert($0).inserted }.joined(separator: ":")
            environment["PATH"] = dedupedPath
            process.environment = environment

            let result: AgentSubprocess.Output
            do {
                result = try await AgentSubprocess.run(
                    process,
                    timeout: 30,
                    stdoutLimit: stdoutToFile == nil ? 64 * 1_024 : 64 * 1_024 * 1_024,
                    stderrLimit: 256 * 1_024
                )
            } catch {
                throw AgentToolError.commandFailed(
                    127,
                    "could not launch `\(executable)`: \(error.localizedDescription). Make sure it is installed and on PATH."
                )
            }

            guard result.exitStatus == 0, !result.timedOut else {
                let stderrText = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = result.timedOut ? "screenshot command timed out" : (stderrText.isEmpty ? "screenshot command failed" : stderrText)
                throw AgentToolError.commandFailed(result.exitStatus, message)
            }

            if let stdoutToFile {
                guard !result.stdoutWasTruncated else {
                    throw AgentToolError.commandFailed(1, "screenshot output exceeded the 64 MiB safety limit")
                }
                try result.stdout.write(to: stdoutToFile)
            }
        }.value
    }

    // MARK: - Image helpers

    private static func downscaled(_ image: CGImage) -> CGImage {
        let longEdge = CGFloat(max(image.width, image.height))
        guard longEdge > maxLongEdge else { return image }
        let scale = maxLongEdge / longEdge
        let target = CGSize(
            width: max(1, (CGFloat(image.width) * scale).rounded()),
            height: max(1, (CGFloat(image.height) * scale).rounded())
        )
        return ImageWorkflowSupport.fit(image, within: target)
    }

    private static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let flattened = ImageWorkflowSupport.flatten(image, background: .white)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, flattened, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func ocrMarkdown(_ lines: [ImageWorkflowSupport.OCRLine]) -> String {
        guard !lines.isEmpty else { return "- No readable text detected locally." }
        let preview = lines.prefix(maxOCRLines).map { "- `\($0.text)`" }
        let suffix = lines.count > maxOCRLines ? "\n- … \(lines.count - maxOCRLines) more line(s)" : ""
        return preview.joined(separator: "\n") + suffix
    }
}
