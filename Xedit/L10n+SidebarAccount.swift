//
//  L10n+SidebarAccount.swift
//  WillDeep
//
//  Localized strings for the Agent sidebar account footer and popover.
//

import Foundation

extension L10n {
    enum SidebarAccount {
        static let menuHelp = String(localized: "sidebar.account.menu-help", defaultValue: "Open account menu")
        static let help = String(localized: "sidebar.account.help", defaultValue: "WillDeep help")
        static let remainingCredits = String(localized: "sidebar.account.remaining-credits", defaultValue: "Remaining credits")
        static let showDesktopPet = String(localized: "sidebar.account.show-desktop-pet", defaultValue: "Show desktop pet")
        static let hideDesktopPet = String(localized: "sidebar.account.hide-desktop-pet", defaultValue: "Hide desktop pet")
        static let settings = String(localized: "sidebar.account.settings", defaultValue: "Settings")
        static let logOut = String(localized: "sidebar.account.log-out", defaultValue: "Log Out")
        static let logOutTitle = String(localized: "sidebar.account.log-out-title", defaultValue: "Log out of some.im?")
        static let logOutMessage = String(localized: "sidebar.account.log-out-message", defaultValue: "WillDeep will remove the local some.im session and managed provider configuration from this Mac.")
        static let cancel = String(localized: "sidebar.account.cancel", defaultValue: "Cancel")
    }
}
