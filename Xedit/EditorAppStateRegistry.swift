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
    ///
    /// rc12 起 never-nil:`unregister` 关掉最后一个 editor 不再清空它;
    /// 冷启动场景由 `ensureHeadlessFallback()` 兜底惰性 mint 一个
    /// headless AppState,保证 agent 窗口永远有内容(会话/草稿/配置)。
    @Published private(set) var current: AppState?

    /// 所有活跃 editor 窗口的 AppState。用 ObjectIdentifier 做 key 是
    /// 因为 AppState 是 class（不 Equatable），ObjectIdentifier 稳定且
    /// 比 hashable wrapper 简单。
    private var activeEditors: [ObjectIdentifier: AppState] = [:]

    /// 冷启动时 `ensureHeadlessFallback()` mint 的 headless AppState。
    /// 1.153.0-rc3：单独强引用留着 —— 用户在 agent-only 工作流里临时
    /// 开了个 editor 窗口又关掉时，`unregister` 把 current 切回这里,
    /// agent 窗口回到之前正聊着的会话，而不是停在刚关掉那个窗口的
    /// 空 AppState 上（表现为「聊天被清空成新聊天」）。
    private var headlessFallback: AppState?

    /// 每个 editor 窗口的 NSWindow 弱引用。AgentChatHeader 的"切回
    /// editor"按钮用这个找到当前 current 对应的窗口、激活到前台。
    /// 弱引用避免持有 NSWindow 阻止系统正常释放。
    private var windows: [ObjectIdentifier: WeakWindow] = [:]

    private init() {}

    /// Agent 窗口 onAppear 调用,确保 `current` 非空。冷启动只开 agent
    /// 窗口、还没有任何 editor 窗口注册时,惰性建一个 headless AppState
    /// 顶上。当后续 editor 窗口 becomeKey 时,`setCurrent` 会自然把
    /// orphan 替换掉。
    func ensureHeadlessFallback() {
        guard current == nil else { return }
        let fallback = AppState()
        headlessFallback = fallback
        current = fallback
        syncDockBadgeTracking()
    }

    /// Editor 窗口 onAppear 调用。注册自己;如果是第一个窗口,或者
    /// 当前 current 是 rc12 引入的 headless orphan(没有任何对应的真实
    /// editor 窗口),把自己升为 current —— 真 editor 注册后应该立刻
    /// 取代 orphan,而不是要等到 becomeKey 才切。
    func register(_ appState: AppState) {
        activeEditors[ObjectIdentifier(appState)] = appState
        if current == nil {
            current = appState
            syncDockBadgeTracking()
            return
        }
        if let existing = current,
           activeEditors[ObjectIdentifier(existing)] == nil {
            // existing 是 orphan headless,优先切到刚注册的真 editor。
            current = appState
        }
        syncDockBadgeTracking()
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
        syncDockBadgeTracking()
    }

    /// Editor 窗口 onDisappear 调用。摘掉自己;如果是 current,优先
    /// fallback 到任意剩余 editor 窗口。
    ///
    /// 1.85.0-rc12:**最后一个 editor 窗口关闭时不再把 current 置 nil**。
    /// 用户原话「editor 窗口关了 agent mode 窗口里就没有内容了,这太
    /// 扯淡了」—— 改成保留这个 orphan AppState(registry 强引用,它不会
    /// 被释放),agent 窗口继续基于它显示会话/草稿。下次 editor 窗口
    /// becomeKey 通过 `setCurrent` 把 current 切到新窗口的 AppState,
    /// orphan 自然被替换。
    func unregister(_ appState: AppState) {
        let key = ObjectIdentifier(appState)
        activeEditors.removeValue(forKey: key)
        windows.removeValue(forKey: key)
        if current === appState {
            if let next = activeEditors.values.first {
                current = next
            } else if let headlessFallback, headlessFallback !== appState {
                // 1.153.0-rc3:最后一个 editor 窗口关闭时,如果 agent
                // 冷启动 mint 过 headless AppState,回退到它 —— 用户
                // 的 agent 会话都在那上面,停在刚关掉窗口的 AppState
                // 会让 agent 窗口看起来被重置成了新聊天。
                current = headlessFallback
            }
            // 都没有:保留 current 指向 orphan,不主动置 nil(rc12)。
        }
        syncDockBadgeTracking()
    }

    /// 找到拥有指定 runtimeID 的 AppState。1.84.0-rc2 起 `run_workflow`
    /// 工具用这个把 agent 主动派的 workflow 注入到正确的 transcript。
    /// 跨多个 editor 窗口扫一遍 —— window 数量极小（用户开 3 个就算
    /// 多），扫表无所谓。
    func appState(forRuntime runtimeID: UUID) -> AppState? {
        for appState in activeEditors.values {
            if appState.agentRuntimes[runtimeID] != nil {
                return appState
            }
        }
        return nil
    }

    /// Find the (AppState, sessionID) of a runtime that currently has a
    /// tool call waiting on the user (approval / confirm / answer). Used
    /// by the notification responder to deep-link the user straight to
    /// the session that needs them, instead of making them hunt for it.
    /// When several are pending, returns the one whose runtime turn
    /// started most recently.
    func appStateWithPendingAttention() -> (appState: AppState, sessionID: AgentSession.ID)? {
        var best: (appState: AppState, sessionID: AgentSession.ID, since: Date)?
        var candidates = Array(activeEditors.values)
        if let current, !candidates.contains(where: { $0 === current }) {
            candidates.append(current)
        }
        for appState in candidates {
            for runtime in appState.agentRuntimes.values {
                let isWaiting = runtime.toolCalls.contains { call in
                    switch call.status {
                    case .pendingApproval, .awaitingConfirm, .awaitingUserAnswer:
                        return true
                    case .running, .succeeded, .failed, .denied:
                        return false
                    }
                }
                guard isWaiting else { continue }
                let since = runtime.turnStartedAt ?? .distantPast
                if best == nil || since > best!.since {
                    best = (appState, runtime.id, since)
                }
            }
        }
        guard let best else { return nil }
        return (best.appState, best.sessionID)
    }

    /// 把当前 current 对应的 editor 窗口激活到前台。Agent 窗口的
    /// header 「切回 editor」按钮用。返回 false 表示当前只有 orphan
    /// AppState 或窗口弱引用已失效,调用方应通过 SwiftUI `openWindow`
    /// 创建/显示主 editor 窗口。
    @discardableResult
    func focusCurrentEditorWindow() -> Bool {
        guard let appState = current,
              let window = windows[ObjectIdentifier(appState)]?.window else {
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    private final class WeakWindow {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    private func syncDockBadgeTracking() {
        var appStates = Array(activeEditors.values)
        if let current,
           !appStates.contains(where: { $0 === current }) {
            appStates.append(current)
        }
        AgentDockBadgeCoordinator.shared.track(appStates: appStates)
    }
}
