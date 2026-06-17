//
//  EditorAppStateRegistry.swift
//  WillDeep
//
//  全局单例，追踪「当前聚焦的 editor 窗口的 AppState」。Agent 窗口
//  （1.80.0-rc1 开始独立成单例 Window）通过 @ObservedObject 这个 registry
//  拿到上下文 —— editor 窗口聚焦时 agent 窗口的 transcript 自动跟着切，
//  对标 codex / cursor「agent 永远在跟我看的项目对话」的心智模型。
//
//  关键约定：**只有 editor 窗口 becomeKey 时才更新 current**。Agent 窗口
//  本身被聚焦时不更新 —— 这样用户在 editor 间切完、跳到 agent 窗口看
//  transcript 时，current 还是最后聚焦的那个 editor 的 AppState。
//
//  Editor 窗口由 `WindowRootView` 在 onAppear 时调 `register(_:)`，本窗口
//  becomeKey 时调 `setCurrent(_:)`；onDisappear 时调 `unregister(_:)`。
//

import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
final class EditorAppStateRegistry: ObservableObject {
    static let shared = EditorAppStateRegistry()

    /// 当前应该被 agent 窗口跟随的 editor AppState。SwiftUI 用
    /// `@ObservedObject` 订阅 → 这个值变化 agent 窗口 body 重算 →
    /// 注入新的 AppState 到 environment（配合 `.id()` 强制 AgentModeView
    /// 重建，避免旧窗口的滚动位置 / 草稿之类 stale @State）。
    @Published private(set) var current: AppState?

    /// 所有活跃 editor 窗口的 AppState。用 ObjectIdentifier 做 key 是
    /// 因为 AppState 是 class（不 Equatable），ObjectIdentifier 稳定且
    /// 比 hashable wrapper 简单。
    private var activeEditors: [ObjectIdentifier: AppState] = [:]

    /// 每个 editor 窗口的 NSWindow 弱引用。AgentChatHeader 的"切回
    /// editor"按钮用这个找到当前 current 对应的窗口、激活到前台。
    /// 弱引用避免持有 NSWindow 阻止系统正常释放。
    private var windows: [ObjectIdentifier: WeakWindow] = [:]

    private init() {}

    /// Editor 窗口 onAppear 调用。注册自己；如果是第一个窗口、
    /// current 还没设过，顺便把自己设成 current（用户启动 app → 直接
    /// 开 agent 窗口的场景能立刻有内容看）。
    func register(_ appState: AppState) {
        activeEditors[ObjectIdentifier(appState)] = appState
        if current == nil {
            current = appState
        }
    }

    /// Editor 窗口的 NSWindow becomeKey 时调用。把本窗口提升为
    /// current 并同步记下 NSWindow 弱引用。Agent 窗口、Settings 窗口
    /// 的聚焦不应该触发此调用。
    func setCurrent(_ appState: AppState, window: NSWindow? = nil) {
        let key = ObjectIdentifier(appState)
        // 防御：注册过的才允许设为 current。
        guard activeEditors[key] != nil else { return }
        if let window {
            windows[key] = WeakWindow(window)
        }
        // 同一引用避免无谓 @Published 通知（虽然同值 @Published 也会
        // 发，但比较一下能省 N 次 body 重算）。
        if current === appState { return }
        current = appState
    }

    /// Editor 窗口 onDisappear 调用。摘掉自己；如果是 current，
    /// fallback 到任意一个剩余窗口（用 dict 任意值）；都关了 current
    /// 置 nil，agent 窗口会显示「No editor open」占位。
    func unregister(_ appState: AppState) {
        let key = ObjectIdentifier(appState)
        activeEditors.removeValue(forKey: key)
        windows.removeValue(forKey: key)
        if current === appState {
            current = activeEditors.values.first
        }
    }

    /// 把当前 current 对应的 editor 窗口激活到前台。Agent 窗口的
    /// header 「切回 editor」按钮用。如果窗口已经被系统释放（不该
    /// 发生，因为 unregister 时会清掉 windows entry，但 weak ref 兜底）
    /// 则什么都不做。
    func focusCurrentEditorWindow() {
        guard let appState = current,
              let window = windows[ObjectIdentifier(appState)]?.window else {
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private final class WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }
}
