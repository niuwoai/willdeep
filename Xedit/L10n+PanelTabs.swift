import Foundation

extension L10n {
    enum PanelTabs {
        static let title = String(localized: "panel-tabs.title", defaultValue: "Workspace panel", table: "PanelTabs")
        static let all = String(localized: "panel-tabs.all", defaultValue: "All tabs", table: "PanelTabs")
        static let add = String(localized: "panel-tabs.add", defaultValue: "Add tab", table: "PanelTabs")
        static let closeTab = String(localized: "panel-tabs.close", defaultValue: "Close tab", table: "PanelTabs")
        static let openTabs = String(localized: "panel-tabs.open", defaultValue: "Open tabs", table: "PanelTabs")
        static let dock = String(localized: "panel-tabs.dock", defaultValue: "Sidebar", table: "PanelTabs")
        static let window = String(localized: "panel-tabs.window", defaultValue: "Separate window", table: "PanelTabs")
        static let returnToDock = String(localized: "panel-tabs.return", defaultValue: "Return to sidebar", table: "PanelTabs")
        static let returnAll = String(localized: "panel-tabs.return-all", defaultValue: "Return all windows", table: "PanelTabs")
        static let allInWindows = String(localized: "panel-tabs.all-in-windows", defaultValue: "Every tab of this session is open in its own window.", table: "PanelTabs")
        static let focusWindow = String(localized: "panel-tabs.focus", defaultValue: "Show window", table: "PanelTabs")
        static let keepsRunning = String(localized: "panel-tabs.keeps-running", defaultValue: "Closing a tab does not stop running processes.", table: "PanelTabs")
        static let empty = String(localized: "panel-tabs.empty", defaultValue: "Open a tab to get started.", table: "PanelTabs")
    }
}
