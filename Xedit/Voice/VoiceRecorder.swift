//
//  VoiceRecorder.swift
//  WillDeep
//
//  Phase 2 push-to-talk recorder：按下开始录、松开转录文字。AVAudioRecorder
//  写入 ~/Library/Application Support/WillDeep/Voice/Recordings/<uuid>.m4a，
//  录完调 `SpeechTranscriber.transcribe(audioURL:)`，转录结果通过 async
//  方法返回给调用方（composer 接住后 append 到 agentInput）。
//
//  Mic 权限：app 启动时不主动 prompt，第一次按 push-to-talk 才 prompt。
//  WillDeep.entitlements + Info.plist 已加 audio-input + NSMicrophoneUsage
//  Description，permission flow 一次拒绝后用户可去 System Settings 重开。
//

import Foundation
import AVFoundation
import Combine

@MainActor
final class VoiceRecorder: ObservableObject {
    static let shared = VoiceRecorder()

    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case transcribing
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var permissionDenied: Bool = false

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meterTimer: Timer?

    private init() {}

    deinit {
        meterTimer?.invalidate()
    }

    /// 录音目录：~/Library/Application Support/WillDeep/Voice/Recordings/
    private static var recordingsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("WillDeep")
            .appendingPathComponent("Voice")
            .appendingPathComponent("Recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 按下 mic 按钮触发。先请求权限（一次性 prompt），通过则开 recorder。
    func start() async {
        // 模型必须先到位 —— transcribe 阶段会用。提前 check 给清晰错误。
        guard VoiceModelDownloader.isModelInstalled else {
            state = .failed(message: "Voice model not installed. Open Settings → AI Providers → Voice to download it (~937 MB).")
            return
        }

        // 权限请求。macOS 用 AVCaptureDevice.requestAccess(for: .audio)。
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    continuation.resume(returning: ok)
                }
            }
        }
        guard granted else {
            permissionDenied = true
            state = .failed(message: "Microphone permission denied. Re-enable in System Settings → Privacy & Security → Microphone.")
            return
        }
        permissionDenied = false

        let url = Self.recordingsDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else {
                state = .failed(message: "Failed to start recording (AVAudioRecorder.record() returned false).")
                return
            }
            recorder = r
            recordingURL = url
            state = .recording(startedAt: Date())
            WaveformOverlayWindowManager.shared.show()
            startMetering()
        } catch {
            state = .failed(message: "Failed to init recorder: \(error.localizedDescription)")
        }
    }

    /// 按 ~30Hz 把 AVAudioRecorder 的平均电平归一化后推给浮窗。
    /// dB 到 [0, 1] 用 fastv 同款经验公式:`pow(10, dB / 20)`,再轻度
    /// 抬底,避免完全静音时 bar 塌成一条线。
    private func startMetering() {
        meterTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                let db = r.averagePower(forChannel: 0)
                let linear = pow(10.0, Double(db) / 20.0)
                let normalized = Float(min(max(linear * 1.6, 0.05), 1.0))
                WaveformOverlayWindowManager.shared.updateAudioLevel(normalized)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    /// 松开 mic 按钮触发。停录 → 转录 → 返回 transcript 字符串。
    /// 失败抛错或返回 nil。
    @discardableResult
    func stopAndTranscribe() async -> String? {
        guard let r = recorder, let url = recordingURL else {
            state = .idle
            return nil
        }
        r.stop()
        recorder = nil
        recordingURL = nil
        stopMetering()
        state = .transcribing
        WaveformOverlayWindowManager.shared.setTranscribing()

        do {
            let transcript = try await SpeechTranscriber.transcribe(
                audioURL: url,
                language: .auto,
                enableCTCDeduplication: false
            )
            // 录音文件留磁盘 —— phase 3 加自动清理 / 历史浏览。
            state = .idle
            WaveformOverlayWindowManager.shared.hide()
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // 1.88.0:首次成功使用语音后,启用「下次启动预热」习惯。
                // 调一次 preloadIfWarranted 是为了「现在 已经加载好了 +
                // markUsed 让下次启动也享受预热」—— 现在这次不再二次
                // 触发 load(model 已在内存)。
                let firstTime = !VoiceLifecyclePrefs.userHasUsedVoice
                VoiceLifecyclePrefs.markUsed()
                if firstTime {
                    VoiceModelLifecycleController.shared.preloadIfWarranted()
                }
            }
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            state = .failed(message: "Transcription failed: \(error.localizedDescription)")
            WaveformOverlayWindowManager.shared.hide()
            return nil
        }
    }

    /// 把状态强制置回 .idle。1.87.0-rc2 修「.failed 卡死」:gesture
    /// 在 `if case .idle` 才 start,残留的 .failed 状态让按钮永远显示
    /// 感叹号,按了没反应。下一次 push-to-talk 前先 reset 一下脱困。
    /// 不动正在录音的 recorder —— 真在录就走 cancel(),不要从这里来。
    func reset() {
        guard recorder == nil else { return }  // 真在录别瞎清
        state = .idle
    }

    /// 取消（用户改主意）。停录 + 丢弃文件。
    func cancel() {
        if let r = recorder {
            r.stop()
        }
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        recordingURL = nil
        stopMetering()
        state = .idle
        WaveformOverlayWindowManager.shared.hide()
    }
}
