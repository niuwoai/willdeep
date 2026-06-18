//
//  MicPushToTalkButton.swift
//  WillDeep
//
//  Composer 工具栏右侧的麦克风按钮。1.88.0-rc1 起从 push-to-talk
//  (按住录)改成 **click-to-toggle**(点一下开始,再点停止+转录):
//
//   - 鼠标 click 触发的「按下立刻松开」会把 DragGesture push-to-talk
//     压成几毫秒,VoiceRecorder.start() 还没把 state 切到 .recording,
//     onEnded guard 就 return 了 —— 浮窗一闪而过,用户什么也录不到。
//   - 改成 toggle 之后,用户必须有意识地再点一次才停,中间用户实际
//     在说话,recorder 也有充足时间切状态。
//   - 键盘端(Fn)继续 push-to-talk —— 那本来就是键盘自然手势,且
//     FnPushToTalkMonitor 自己有 isStarting/pendingStop 防竞态。
//
//  视觉态:
//   - idle           mic.fill        accent
//   - recording      stop.fill       红色(pulsing 可后续加)
//   - transcribing   waveform        蓝色
//   - failed         exclamationmark 橙色 → 点击进入失败处理(权限弹 alert 或 reset)
//

import SwiftUI

struct MicPushToTalkButton: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var recorder = VoiceRecorder.shared

    var body: some View {
        Button(action: { onTap() }) {
            ZStack {
                Circle()
                    .fill(backgroundColor)
                    .frame(width: 22, height: 22)
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .opacity(isAvailable ? 1.0 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .help(helpText)
    }

    // MARK: - Action

    private func onTap() {
        switch recorder.state {
        case .idle:
            Task {
                await recorder.start()
                // start 失败如果是权限被拒,主动弹 alert(同 Fn 路径)
                if case .failed(let msg) = recorder.state,
                   MicPermissionAlert.messageIsPermissionDenied(msg) {
                    MicPermissionAlert.present(message: msg)
                }
            }
        case .recording:
            Task {
                if let transcript = await recorder.stopAndTranscribe() {
                    appState.appendAgentInputTextCreatingSessionIfNeeded(transcript)
                }
            }
        case .transcribing:
            // 后台正在转,再点没意义。
            return
        case .failed(let msg):
            if MicPermissionAlert.messageIsPermissionDenied(msg) {
                MicPermissionAlert.present(message: msg)
            } else {
                recorder.reset()
            }
        }
    }

    // MARK: - Styling

    private var symbol: String {
        switch recorder.state {
        case .idle: return "mic.fill"
        case .recording: return "stop.fill"
        case .transcribing: return "waveform"
        case .failed: return "exclamationmark"
        }
    }

    private var backgroundColor: Color {
        switch recorder.state {
        case .idle: return Color.accentColor
        case .recording: return .red
        case .transcribing: return .blue
        case .failed: return .orange
        }
    }

    private var helpText: String {
        if !VoiceModelDownloader.isModelInstalled {
            return "Voice model not installed — go to Settings → Voice."
        }
        switch recorder.state {
        case .idle:
            return "Click to start recording. Click again to stop and transcribe. (Or hold Fn anywhere in the app for push-to-talk.)"
        case .recording:
            return "Recording — click to stop and transcribe."
        case .transcribing:
            return "Transcribing…"
        case .failed(let message):
            return message
        }
    }

    private var isAvailable: Bool {
        VoiceModelDownloader.isModelInstalled
    }
}
