//
//  L10n+Header.swift
//  WillDeep
//

import Foundation

extension L10n {
    enum Header {
        static let newChat = String(localized: "header.new-chat", defaultValue: "New Chat")
        static let showSidebar = String(localized: "header.show-sidebar", defaultValue: "Show Sidebar")
        static let hideSidebar = String(localized: "header.hide-sidebar", defaultValue: "Hide Sidebar")
        static let sidebarAutoHidden = String(
            localized: "header.sidebar-auto-hidden",
            defaultValue: "Widen the window to show the sidebar"
        )
        static let searchSessions = String(localized: "header.search-sessions", defaultValue: "Search Chats")
    }
}
