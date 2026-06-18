//
//  MicPermissionAlert.swift
//  WillDeep
//
//  1.87.0-rc3 增量。麦克风权限被拒后,直接弹 NSAlert 并提供「Open
//  System Settings」一键深链,省得用户自己翻菜单。macOS 一旦被拒了
//  后台一次,下次 AVCaptureDevice.requestAccess 不会再弹 prompt,只能
//  人工去隐私设置勾开。我们把这个痛点收敛到一个 helper。
//
//  注意:NSAlert 必须 main thread。我们在 @MainActor 上下文里同步调,
//  alert 弹出期间会卡住调用方 —— 但调用方就是 mic 按钮 / Fn 监听器,
//  本来就在 main,直接卡这一下也无所谓。
//

import AppKit

@MainActor
enum MicPermissionAlert {
    /// 上次弹 alert 的时间。防止短时间反复按 Fn / 反复点 mic 按钮
    /// 把窗口刷成 alert 雪片。
    private static var lastShownAt: Date?

    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    /// 把 `.failed` 里的 message 透出来,弹 alert,用户点「Open
    /// System Settings」就深链到隐私页。
    static func present(message: String) {
        if let last = lastShownAt, Date().timeIntervalSince(last) < 5 {
            return
        }
        lastShownAt = Date()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Microphone access needed"
        alert.informativeText = message + "\n\nAfter enabling WillDeep in System Settings → Privacy & Security → Microphone, you may need to restart the app for macOS to re-issue the prompt."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(systemSettingsURL)
        }
    }

    /// 试着从 VoiceRecorder 的 .failed message 里判断这是不是权限相关。
    /// 不严格 —— 字符串匹配就够。VoiceRecorder.start() 里写死了开头是
    /// "Microphone permission denied"。
    static func messageIsPermissionDenied(_ message: String) -> Bool {
        message.lowercased().contains("microphone permission")
    }
}
