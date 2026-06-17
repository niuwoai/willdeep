//
//  L10n+AgentWindow.swift
//  WillDeep
//
//  L10n strings for the standalone Agent window introduced in 1.80.0-rc1.
//  Separate file to avoid bloating L10n.swift (which is already approaching
//  the 2000-line split threshold).
//

import Foundation

extension L10n {
    enum AgentWindow {
        /// Menu item — opens (or focuses) the singleton Agent window.
        /// Replaces the old "Switch to Agent Mode" string semantically:
        /// editor and agent no longer toggle, agent has its own window.
        static let openMenuItem = String(
            localized: "menu.view.open-agent-window",
            defaultValue: "Open Agent Window"
        )
        /// Window title (also shown in the dock window list).
        static let title = String(
            localized: "agent-window.title",
            defaultValue: "WillDeep Agent"
        )
        // 1.85.0-rc12:旧的 `emptyTitle / emptySubtitle / emptyOpenButton`
        // 三条「关掉所有 editor 显示占位」的文案已删除 —— agent 窗口
        // 现在永远基于一个 AppState 显示,不再有空占位状态。
    }
}
