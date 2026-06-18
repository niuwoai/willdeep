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
//  并且会和系统默认的 Fn=听写冲突 —— 用户在 #5 选择题里明确要 app
//  内即可。
//
//  鲁棒性细节:
//  - 用 rising/falling edge,而不是 .contains(.function) 当前值,防止 Fn+F1
//    这种组合按出多次 flagsChanged 时重复触发。
//  - app 失焦时如果还在录,主动 cancel —— 不然按 Fn → cmd+tab 走人,
//    录音机会一直跑着。
//  - start() 是 async,按一下立刻松开会撞上「start Task 还没把 state
//    切到 .recording,stop 已经被调用」的竞态;rc1 用 `isStarting` 标志
//    把 stop 推迟到 start 真完成。
//  - 全程 NSLog 走 OSLog,Console.app 里 subsystem 过滤 com.willdeep.app
//    就能看到事件流,方便用户自查触发问题。
//

import AppKit
import Combine
import OSLog

@MainActor
final class FnPushToTalkMonitor {
    static let shared = FnPushToTalkMonitor()

    private let log = Logger(subsystem: "com.willdeep.app", category: "Fn-PTT")

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var activateObserver: NSObjectProtocol?
    private var fnDown: Bool = false

    /// start() 还在 await 时为 true。stop 触发但 isStarting 还是 true
    /// 表示用户按了一下立刻松开,我们等 start 完成后立刻收尾。
    private var isStarting: Bool = false
    private var pendingStop: Bool = false

    private init() {}

    func install() {
        guard monitor == nil else { return }
        log.info("install()")

        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
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

        activateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fnDown = false  // 失焦期间 Fn 状态不可信,重置
            }
        }
    }

    private func handle(_ event: NSEvent) {
        guard NSApp.isActive else { return }
        let nowDown = event.modifierFlags.contains(.function)
        guard nowDown != fnDown else { return }
        fnDown = nowDown
        log.info("flagsChanged: fn=\(nowDown ? "down" : "up"), flags=\(event.modifierFlags.rawValue)")

        if nowDown {
            startRecording()
        } else {
            finishRecording()
        }
    }

    private func startRecording() {
        guard VoiceModelDownloader.isModelInstalled else {
            log.warning("model not installed; beep + bail")
            NSSound.beep()
            return
        }
        let recorder = VoiceRecorder.shared
        // 1.87.0-rc2:从 .failed 残留态自动脱困
        if case .failed = recorder.state {
            log.info("startRecording: clearing stale .failed state")
            recorder.reset()
        }
        guard case .idle = recorder.state else {
            log.info("startRecording: recorder not idle (state=\(String(describing: recorder.state)))")
            return
        }
        isStarting = true
        pendingStop = false
        log.info("startRecording: awaiting recorder.start()")
        Task {
            await recorder.start()
            self.isStarting = false
            self.log.info("recorder.start() returned; state=\(String(describing: recorder.state)), pendingStop=\(self.pendingStop)")
            // 1.87.0-rc3:start 失败如果是权限被拒,主动弹 alert。
            if case .failed(let msg) = recorder.state,
               MicPermissionAlert.messageIsPermissionDenied(msg) {
                MicPermissionAlert.present(message: msg)
            }
            if self.pendingStop {
                self.pendingStop = false
                await self.completeRecording()
            }
        }
    }

    private func finishRecording() {
        if isStarting {
            // start 还没完,标记一下,等 start 回来再收尾
            pendingStop = true
            log.info("finishRecording: start still in flight, defer to pendingStop")
            return
        }
        Task { await completeRecording() }
    }

    private func completeRecording() async {
        let recorder = VoiceRecorder.shared
        guard case .recording = recorder.state else {
            log.info("completeRecording: state not .recording (state=\(String(describing: recorder.state))) — nothing to do")
            return
        }
        log.info("completeRecording: awaiting stopAndTranscribe()")
        let transcript = await recorder.stopAndTranscribe()
        log.info("completeRecording: transcript=\(transcript ?? "<nil>")")
        if let transcript {
            appendToCurrentComposer(transcript)
        }
    }

    private func abortIfRecording() {
        let recorder = VoiceRecorder.shared
        if case .recording = recorder.state {
            log.info("abortIfRecording: cancelling in-flight recording")
            recorder.cancel()
        }
        fnDown = false
        isStarting = false
        pendingStop = false
    }

    /// 找当前活跃的 AppState(跟 MicPushToTalkButton 走的是 EnvironmentObject
    /// 拿到的同一份 —— Agent 窗口里那份取自 EditorAppStateRegistry.current),
    /// 在它的 agentInput 末尾拼上转录文本。注意 `agentInput` 是 computed
    /// property 走 `activeRuntime?.input`,如果 activeRuntime 是 nil
    /// (workspace 还没有 active agent session)写不进去 —— 提前 detect
    /// 给出诊断。
    private func appendToCurrentComposer(_ transcript: String) {
        guard let appState = EditorAppStateRegistry.shared.current else {
            log.warning("append: no current AppState — transcript dropped (\(transcript))")
            return
        }
        guard appState.activeRuntime != nil else {
            log.warning("append: no activeRuntime (activeAgentSessionID=\(String(describing: appState.activeAgentSessionID))) — transcript dropped (\(transcript))")
            return
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log.info("append: trimmed transcript empty")
            return
        }
        let next = appState.agentInput.isEmpty ? trimmed : appState.agentInput + " " + trimmed
        appState.agentInput = next
        log.info("append: wrote \(trimmed.count) chars; total now \(appState.agentInput.count)")
    }
}
