//
//  VoiceModelLifecycleController.swift
//  WillDeep
//
//  1.88.0 起。语音模型(SenseVoice ONNX, ~937 MB)的智能加载/释放策略,
//  目标:对常用语音的用户瞬时响应,对不用的用户零内存成本。
//
//  策略矩阵:
//
//   ┌─────────────────────────────┬─────────────────────────────┐
//   │ 触发                         │ 行为                         │
//   ├─────────────────────────────┼─────────────────────────────┤
//   │ App 启动 + 用户用过语音 +    │ Task.detached(.utility) 后台 │
//   │ 用户主动打开预热开关         │ preload(),不阻塞 UI         │
//   │ VoiceRecorder 转录成功一次   │ markUsed() 写 UserDefaults  │
//   │ App 进后台 10 分钟           │ unloadModel(),让出 937MB   │
//   │ App 回前台                   │ 取消未触发的 10 分钟 timer   │
//   │ 内置 5 分钟空闲(已存在)     │ unload(SpeechTranscriptionModel│
//   │                             │ 内部已实现,不重复加)        │
//   │ 内置 4GB 内存压力(已存在)   │ unload(同上)                │
//   └─────────────────────────────┴─────────────────────────────┘
//
//  AppDelegate.applicationDidFinishLaunching 调 install()。
//

import AppKit
import Combine
import OSLog

@MainActor
final class VoiceModelLifecycleController {
    static let shared = VoiceModelLifecycleController()

    private let log = Logger(subsystem: "com.willdeep.app", category: "VoiceLifecycle")

    private var resignObserver: NSObjectProtocol?
    private var activateObserver: NSObjectProtocol?
    private var backgroundUnloadTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?

    /// 进后台多久之后主动 unload。10 分钟是经验值:用户切走小会儿
    /// (查资料、回消息)回来不需要重新付 1-5s 冷启动;切走半小时以上
    /// 多半短期不会回来,937 MB 该让让。
    private static let backgroundUnloadDelaySeconds: TimeInterval = 10 * 60

    private var installed = false

    private init() {}

    func install() {
        guard !installed else { return }
        installed = true
        guard !Self.isRunningUnderXCTest else {
            log.info("install(): XCTest detected — skip voice model lifecycle preload")
            return
        }
        log.info("install()")

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.appDidResignActive()
            }
        }

        activateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.appDidBecomeActive()
            }
        }

        preloadIfWarranted()
    }

    /// 用户在 Settings 里改了 preload 开关 / 第一次成功用了语音时,
    /// 可以再调一次来按当前 prefs 触发 preload。幂等。
    func preloadIfWarranted() {
        guard !Self.isRunningUnderXCTest else {
            log.info("preloadIfWarranted: XCTest detected — skip")
            return
        }
        guard VoiceLifecyclePrefs.userHasUsedVoice else {
            log.info("preloadIfWarranted: user hasn't used voice yet — skip")
            return
        }
        guard VoiceLifecyclePrefs.preloadOnLaunch else {
            log.info("preloadIfWarranted: preloadOnLaunch=false — skip")
            return
        }
        guard SpeechTranscriptionModel.hasModelFile() else {
            log.info("preloadIfWarranted: no model file on disk — skip")
            return
        }
        guard preloadTask == nil else {
            log.info("preloadIfWarranted: preload already running — skip")
            return
        }
        log.info("preloadIfWarranted: kicking background preload")
        preloadTask = Task(priority: .utility) { [weak self] in
            let ok = await SpeechTranscriptionModel.shared.preload()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.log.info("preload finished: ok=\(ok)")
                self?.preloadTask = nil
            }
        }
    }

    private func appDidResignActive() {
        guard VoiceLifecyclePrefs.userHasUsedVoice else { return }
        log.info("didResignActive: scheduling background unload in \(Int(Self.backgroundUnloadDelaySeconds))s")
        backgroundUnloadTask?.cancel()
        let nanos = UInt64(Self.backgroundUnloadDelaySeconds * 1_000_000_000)
        backgroundUnloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await SpeechTranscriptionModel.shared.unloadModel()
            await MainActor.run {
                self?.log.info("background unload fired")
                self?.backgroundUnloadTask = nil
            }
        }
    }

    private func appDidBecomeActive() {
        if backgroundUnloadTask != nil {
            log.info("didBecomeActive: cancelling pending background unload")
            backgroundUnloadTask?.cancel()
            backgroundUnloadTask = nil
        }
    }

    /// Settings 「Unload now」按钮调。
    func unloadNow() async {
        preloadTask?.cancel()
        preloadTask = nil
        await SpeechTranscriptionModel.shared.unloadModel()
        log.info("manual unload")
    }

    /// Settings 「Is the model in memory?」展示用。actor 隔离需要 await。
    func isLoaded() async -> Bool {
        await SpeechTranscriptionModel.shared.isModelLoaded()
    }

    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
