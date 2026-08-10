//
//  VoiceModelDownloader.swift
//  WillDeep
//
//  Phase 2 voice-to-text onboarding：下载 ~937 MB 的 SenseVoice
//  model.onnx 到 VoiceModelLocation。tokens.json / am.mvn / config.yaml
//  这三个辅助文件已经打包进 Bundle 的 Voice/BundledAssets/，不需下载。
//
//  模型托管在自有 OSS（img.niuwoai.com）上，与 App DMG 同一个发布桶。
//  如果用户机器装过 fastv，ImportFromFastv() 直接 symlink 现有副本
//  （0 下载，秒完成）。
//

import Foundation
import Combine

@MainActor
final class VoiceModelDownloader: ObservableObject {
    static let shared = VoiceModelDownloader()

    /// 自有 OSS 上的 SenseVoice 模型。1.238.2 起从借用的第三方
    /// endpoint（cdn.wxside.com）迁到 img.niuwoai.com —— 与 App DMG
    /// 同一个发布桶，生命周期自己说了算。换源改这里就行。
    private static let defaultDownloadURL = URL(string: "https://img.niuwoai.com/models/sensevoice-small/model.onnx")!

    /// SenseVoice ONNX 的实测体积（迁移时校验过 MD5 的那一份），只用作
    /// 服务端未给 Content-Length 时的回退分母。真实体积以响应头为准。
    /// 注意这是十进制 937.6 MB，不是 937 MiB —— 旧值写成 937 * 1024 * 1024
    /// （982,614,016）会把分母抬高约 4.8%，进度条永远差一截到不了头。
    static let approximateModelBytes: Int64 = 937_615_562

    enum State: Equatable {
        case idle
        case importing
        case downloading(progress: Double, bytesReceived: Int64, totalBytes: Int64, speedBytesPerSec: Double)
        case finished
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle

    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var observer: NSKeyValueObservation?
    private var lastProgressUpdate: (date: Date, bytes: Int64)?

    /// 是否已就绪（model.onnx 文件存在）。Settings UI / Workflow 都查这个。
    static var isModelInstalled: Bool {
        FileManager.default.fileExists(atPath: VoiceModelLocation.modelOnnxURL.path)
    }

    /// 用户机器上是否有 fastv 的现成模型可以直接 symlink。
    static var canImportFromFastv: Bool {
        let candidates = [
            "~/Library/Application Support/妙打/Models/sensevoice-small/model.onnx",
            "~/Library/Application Support/fastv/Models/sensevoice-small/model.onnx",
            "~/Library/Application Support/若一智能助手/Models/sensevoice-small/model.onnx",
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) }
    }

    private init() {}

    /// 0-下载路径：如果检测到 fastv 已经下载过模型，直接 symlink 过来。
    /// 失败抛错；成功后 state 变 .finished。
    func importFromFastv() async throws {
        guard !Self.isModelInstalled else {
            state = .finished
            return
        }
        state = .importing
        let candidates = [
            "~/Library/Application Support/妙打/Models/sensevoice-small/model.onnx",
            "~/Library/Application Support/fastv/Models/sensevoice-small/model.onnx",
            "~/Library/Application Support/若一智能助手/Models/sensevoice-small/model.onnx",
        ]
        guard let sourcePath = candidates
            .map({ ($0 as NSString).expandingTildeInPath })
            .first(where: { FileManager.default.fileExists(atPath: $0) })
        else {
            state = .failed(message: "No fastv model copy found.")
            throw NSError(domain: "VoiceModelDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: "No fastv model copy found on disk."])
        }
        try FileManager.default.createDirectory(at: VoiceModelLocation.modelDirectory, withIntermediateDirectories: true)
        let destURL = VoiceModelLocation.modelOnnxURL
        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.createSymbolicLink(atPath: destURL.path, withDestinationPath: sourcePath)
        state = .finished
    }

    /// 从 CDN 下载 model.onnx。进度通过 @Published `state` 更新。
    /// 已经下完就直接 state = .finished 不重下。
    func download() async {
        guard !Self.isModelInstalled else {
            state = .finished
            return
        }
        try? FileManager.default.createDirectory(at: VoiceModelLocation.modelDirectory, withIntermediateDirectories: true)
        state = .downloading(progress: 0, bytesReceived: 0, totalBytes: 0, speedBytesPerSec: 0)

        let session = URLSession(configuration: .default)
        self.session = session
        let url = Self.defaultDownloadURL
        let downloadTask = session.downloadTask(with: url) { [weak self] tempURL, _, error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    self.state = .failed(message: "Download failed: \(error.localizedDescription)")
                    return
                }
                guard let tempURL else {
                    self.state = .failed(message: "Download finished but no file URL.")
                    return
                }
                let dest = VoiceModelLocation.modelOnnxURL
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    self.state = .finished
                } catch {
                    self.state = .failed(message: "Move failed: \(error.localizedDescription)")
                }
            }
        }
        self.task = downloadTask

        // 进度观察。downloadTask.progress 是 NSProgress，KVO 它的
        // fractionCompleted。
        // Byte counts come from the task, not from `progress`. A download
        // task's `fractionCompleted` is driven internally and its
        // `completedUnitCount` / `totalUnitCount` are not guaranteed to be
        // populated alongside it — reading them here made the bar advance
        // while the label sat at "0.0 MB / 0.0 MB". `countOfBytesReceived`
        // and `countOfBytesExpectedToReceive` are the authoritative pair.
        observer = downloadTask.progress.observe(\.fractionCompleted, options: [.new]) { [weak self, weak downloadTask] progress, _ in
            guard let self else { return }
            let received = downloadTask?.countOfBytesReceived ?? progress.completedUnitCount
            // `countOfBytesExpectedToReceive` is NSURLSessionTransferSizeUnknown
            // (-1) until the response headers land, and stays there when the
            // server sends no Content-Length. Fall back to the known asset size
            // so the denominator is never 0 or negative.
            let reported = downloadTask?.countOfBytesExpectedToReceive ?? 0
            let total = reported > 0 ? reported : Self.approximateModelBytes
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                let speed = self.computeSpeed(receivedNow: received)
                self.state = .downloading(progress: fraction, bytesReceived: received, totalBytes: total, speedBytesPerSec: speed)
            }
        }

        downloadTask.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        observer?.invalidate()
        observer = nil
        if Self.isModelInstalled {
            state = .finished
        } else {
            state = .idle
        }
    }

    private func computeSpeed(receivedNow: Int64) -> Double {
        let now = Date()
        defer { lastProgressUpdate = (now, receivedNow) }
        guard let last = lastProgressUpdate else { return 0 }
        let elapsed = now.timeIntervalSince(last.date)
        guard elapsed > 0.1 else { return 0 }
        let deltaBytes = Double(receivedNow - last.bytes)
        return deltaBytes / elapsed
    }
}
