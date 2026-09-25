//
//  AgentNotificationAuthorization.swift
//  WillDeep
//
//  The one place that decides what WillDeep asks the notification system for.
//
//  macOS ties the Dock badge to notification permission. An app that has
//  never asked for notifications can set `NSDockTile.badgeLabel` freely, but
//  once it has asked, the Dock only paints the label when `.badge` was part of
//  the request and the user has not switched badges off. WillDeep used to ask
//  for `[.alert, .sound]` only, so `badgeSetting` stayed `.notSupported`: the
//  badge coordinator set "1", AppKit read back "1", and the Dock stayed blank
//  while the sidebar said a session was waiting. Reproduced with a signed
//  probe app on macOS 26 in 1.404.0-rc2.
//

import Foundation
import os
@preconcurrency import UserNotifications

private let notificationAuthorizationLog = Logger(subsystem: "com.willdeep.app", category: "dock-badge")

enum AgentNotificationAuthorization {
    /// Every `requestAuthorization` call goes through this set. Leaving
    /// `.badge` out does not fail anywhere; it just hides the Dock number.
    nonisolated static let options: UNAuthorizationOptions = [.alert, .sound, .badge]

    /// Whether an existing permission should be requested again to pick up
    /// the badge. Only when the user already allowed notifications and badges
    /// were never asked for: the system prompts once per app, so the repeat
    /// request is silent and simply adds `.badge`. `.disabled` is the user's
    /// own switch in System Settings and stays untouched. An undecided app is
    /// left to the first-post request so launch never raises a prompt, and a
    /// provisional one would be prompted to upgrade, so it is skipped too.
    nonisolated static func shouldRequestBadge(
        authorizationStatus: UNAuthorizationStatus,
        badgeSetting: UNNotificationSetting
    ) -> Bool {
        authorizationStatus == .authorized && badgeSetting == .notSupported
    }

    /// Launch-time repair for installs that allowed notifications before
    /// `.badge` was part of the request.
    nonisolated static func restoreDockBadgePermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            let badge = settings.badgeSetting
            if status == .authorized, badge == .disabled {
                notificationAuthorizationLog.info(
                    "notification badges are turned off for WillDeep in System Settings; the Dock will not show the number"
                )
                return
            }
            guard shouldRequestBadge(authorizationStatus: status, badgeSetting: badge) else { return }
            center.requestAuthorization(options: options) { granted, error in
                if let error {
                    notificationAuthorizationLog.error(
                        "requesting badge permission failed: \(error.localizedDescription, privacy: .public)"
                    )
                    return
                }
                notificationAuthorizationLog.info(
                    "requested badge permission for an existing notification grant: granted=\(granted, privacy: .public)"
                )
            }
        }
    }
}
