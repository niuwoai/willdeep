//
//  VoiceLifecyclePrefs.swift
//  WillDeep
//
//  1.88.0 起。UserDefaults 包一层,记录:
//   - 用户有没有用过语音(一次成功转录后置 true) —— 用于决定下次启动
//     是否后台预热模型
//   - 用户是否允许「启动时预热」(默认 true,可在 Settings → Voice 关掉)
//

import Foundation

enum VoiceLifecyclePrefs {
    private static let hasUsedKey = "willdeep.voice.hasBeenUsed"
    private static let preloadOnLaunchKey = "willdeep.voice.preloadOnLaunch"

    /// 用户至少成功用过一次语音转录。`VoiceRecorder.stopAndTranscribe`
    /// 拿到非空 transcript 时主动置 true。
    static var userHasUsedVoice: Bool {
        get { UserDefaults.standard.bool(forKey: hasUsedKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasUsedKey) }
    }

    /// 启动时预热开关。默认 true:用户用过一次,以后启动就后台 preload。
    /// 关掉之后每次 push-to-talk 都要等 1-5s 冷启动。
    static var preloadOnLaunch: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: preloadOnLaunchKey)
            return (v as? Bool) ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: preloadOnLaunchKey) }
    }

    static func markUsed() {
        userHasUsedVoice = true
    }
}
