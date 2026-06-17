//
//  MicPushToTalkButton.swift
//  WillDeep
//
//  Phase 2 voice → composer：composer 工具栏里的 mic 按钮。按下开始
//  录音，松开（onChange of isPressed → false）停录并转录，结果 append
//  到 appState.agentInput。视觉上模仿 Slack push-to-talk 风格。
//
//  Push-to-talk 用 long-press gesture 的 `.onChanged` + `.onEnded` 实现。
//  录音中红色脉动；转录中蓝色 spinner；错误状态显示 1 秒红色感叹号。
//

import SwiftUI

struct MicPushToTalkButton: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var recorder = VoiceRecorder.shared

    var body: some View {
        Button(action: {}) {
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
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if case .idle = recorder.state {
                        Task { await recorder.start() }
                    }
                }
                .onEnded { _ in
                    guard case .recording = recorder.state else { return }
                    Task {
                        if let transcript = await recorder.stopAndTranscribe() {
                            appState.agentInput.append(
                                appState.agentInput.isEmpty ? transcript : " " + transcript
                            )
                        }
                    }
                }
        )
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
        case .idle: return "Press and hold to record; release to transcribe and insert into the composer."
        case .recording: return "Recording — release to transcribe."
        case .transcribing: return "Transcribing…"
        case .failed(let message): return message
        }
    }

    private var isAvailable: Bool {
        VoiceModelDownloader.isModelInstalled
    }
}
