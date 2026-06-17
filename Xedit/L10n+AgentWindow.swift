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
        /// Placeholder body shown when no editor window is open
        /// (e.g. user closed every workspace but left the Agent window
        /// floating). Pairs with a button that opens a folder picker.
        static let emptyTitle = String(
            localized: "agent-window.empty-title",
            defaultValue: "No editor window open"
        )
        static let emptySubtitle = String(
            localized: "agent-window.empty-subtitle",
            defaultValue: "Open a workspace to give the agent context to talk about."
        )
        static let emptyOpenButton = String(
            localized: "agent-window.empty-open-button",
            defaultValue: "Open Workspace…"
        )
    }
}
