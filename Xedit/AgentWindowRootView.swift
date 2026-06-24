//
//  AgentWindowRootView.swift
//  WillDeep
//
//  Root view for the standalone Agent window (1.80.0-rc1+). Agent is no
//  longer a fullscreen mode toggled inside an editor window — it has its
//  own singleton Window scene that *follows* whichever editor window was
//  focused last. Same idea as codex / cursor: "agent is always talking
//  about the project I'm looking at."
//
//  We DO NOT create our own AppState here. Instead we read
//  EditorAppStateRegistry.shared.current and inject that into the
//  environment. When the user focuses a different editor window, the
//  registry updates and SwiftUI re-injects + rebuilds AgentModeView (forced
//  via `.id(ObjectIdentifier(appState))`) so no stale @State (scroll
//  position, composer draft, …) leaks across workspace contexts.
//

import SwiftUI
import AppKit

struct AgentWindowRootView: View {
    @ObservedObject private var registry = EditorAppStateRegistry.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let appState = registry.current {
                AgentModeView()
                    .environmentObject(appState)
                    .tint(appState.editorSettings.interfaceSkin.palette.accent)
                    .preferredColorScheme(appState.editorSettings.interfaceSkin.preferredColorScheme)
                    // Force-rebuild AgentModeView when the source AppState
                    // changes — otherwise SwiftUI re-uses the same view
                    // instances and the AgentSessionsSidebar / Composer
                    // keep showing the previous workspace's draft / scroll
                    // position. ObjectIdentifier is stable for an
                    // AppState's lifetime.
                    .id(ObjectIdentifier(appState))
            } else {
                // rc12 兜底:理论上不会走到(`ensureHeadlessFallback`
                // 在 onAppear 已经 mint),但万一在 onAppear 跑之前 SwiftUI
                // 就已经先评估了一次 body 仍然能给个明确占位。
                Color.clear
            }
        }
        // 窗口最小宽度交给 AgentModeView 的 AgentWindowMinWidthSetter
        // 动态写进 NSWindow.contentMinSize —— SwiftUI 的静态 minWidth 会在
        // 每次 resize layout 时把 contentMinSize 重置成固定值,压不住
        // 「侧面板打开 → 内容更宽」的动态下限,导致最左会话列表被挤出
        // 窗体左缘。这里只保留高度下限。
        .frame(minHeight: 480)
        // 标记「agent 窗口在前台」，供全局 ⌘N 命令分流到「新聊天」。
        // 常量值，不随 transcript 流式刷新 republish。
        .focusedSceneValue(\.agentWindowActive, true)
        .onAppear {
            // 冷启动只开 agent 窗口、还没任何 editor 注册时,惰性建一个
            // headless AppState 顶上,保证「editor 没开 / 没选 workspace
            // 时 agent 窗口里就空了」这件事不再发生。
            registry.ensureHeadlessFallback()
        }
        // Tapped agent notification → focus this window (covers the case
        // where the Agent window is open but no editor window is).
        .onReceive(NotificationCenter.default.publisher(for: .willDeepRevealAgentSession)) { _ in
            openWindow(id: AgentWindowID.value)
        }
    }
}

// 1.85.0-rc12:旧的 `AgentWindowEmptyState` 已经删除 —— agent 窗口现在
// 永远基于一个 AppState 显示(真 editor 的 / orphan / 冷启动惰性建的
// headless),「关掉 editor 就一片空白」的窘境不再发生。L10n 里的
// `AgentWindow.emptyTitle / emptySubtitle / emptyOpenButton` 三条空状态
// 文案也跟着失效,统一在 `L10n.swift` 那边清掉。
