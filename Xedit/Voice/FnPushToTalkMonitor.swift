//
//  FnPushToTalkMonitor.swift
//  WillDeep
//
//  1.87.0 增量。按住 Fn 键时(Xedit 在前台)走和 composer mic 按钮同款的
//  push-to-talk 链路:VoiceRecorder.start → WaveformOverlayWindow 浮出 →
//  松开 → stopAndTranscribe → 文本 append 到当前 AppState.agentInput。
//
//  实现走 NSEvent.addLocalMonitorForEvents(.flagsChanged),只在本 app 是
//  active 时响应。为什么不走全局 monitor:全局监听需要「辅助功能」授权,
//  并且会和系统默认的 Fn=听写冲突 —— 用户(在 #5 选择题里)明确要 app
//  内即可。
//
//  鲁棒性细节:
//  - 用 rising/falling edge,而不是 .contains(.function) 当前值,防止 Fn+F1
//    这种组合按出多次 flagsChanged 时重复触发。
//  - app 失焦时如果还在录,主动 cancel —— 不然按 Fn → cmd+tab 走人,
//    录音机会一直跑着。
//

import AppKit
import Combine

@MainActor
final class FnPushToTalkMonitor {
    static let shared = FnPushToTalkMonitor()

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var fnDown: Bool = false

    private init() {}

    func install() {
        guard monitor == nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // hop to MainActor — flagsChanged comes in on the main thread
            // for local monitors already, so we can call directly into our
            // MainActor-isolated method via a non-isolated dispatch trick.
            MainActor.assumeIsolated {
                self?.handle(event)
            }
            return event
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.abortIfRecording()
            }
        }
    }

    private func handle(_ event: NSEvent) {
        guard NSApp.isActive else { return }
        let nowDown = event.modifierFlags.contains(.function)
        guard nowDown != fnDown else { return }
        fnDown = nowDown

        if nowDown {
            startRecording()
        } else {
            finishRecording()
        }
    }

    private func startRecording() {
        guard VoiceModelDownloader.isModelInstalled else {
            // 没装模型不闹腾,只在 console 提一句。用户去 Settings → Voice
            // 装好后下次按 Fn 自动生效。
            NSSound.beep()
            return
        }
        let recorder = VoiceRecorder.shared
        if case .idle = recorder.state {
            Task { await recorder.start() }
        }
    }

    private func finishRecording() {
        let recorder = VoiceRecorder.shared
        guard case .recording = recorder.state else { return }
        Task {
            if let transcript = await recorder.stopAndTranscribe() {
                appendToCurrentComposer(transcript)
            }
        }
    }

    private func abortIfRecording() {
        let recorder = VoiceRecorder.shared
        if case .recording = recorder.state {
            recorder.cancel()
        }
        fnDown = false
    }

    /// 找当前活跃的 AppState(跟 MicPushToTalkButton 走的是 EnvironmentObject
    /// 拿到的同一份 —— Agent 窗口里那份取自 EditorAppStateRegistry.current),
    /// 在它的 agentInput 末尾拼上转录文本。
    private func appendToCurrentComposer(_ transcript: String) {
        guard let appState = EditorAppStateRegistry.shared.current else { return }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appState.agentInput.append(
            appState.agentInput.isEmpty ? trimmed : " " + trimmed
        )
    }
}
