//
//  AgentNotificationAuthorizationTests.swift
//  XeditTests
//
//  The Dock only paints `NSDockTile.badgeLabel` for a notification-registered
//  app when its permission includes `.badge`. These pin the request set and
//  the launch-time repair decision that fixed the blank Dock in 1.404.0-rc2.
//

import Testing
@preconcurrency import UserNotifications
@testable import WillDeep

@Suite
struct AgentNotificationAuthorizationTests {
    @Test("notification permission requests include the Dock badge")
    func requestedOptionsIncludeBadge() {
        let options = AgentNotificationAuthorization.options
        #expect(options.contains(.badge))
        #expect(options.contains(.alert))
        #expect(options.contains(.sound))
        #expect(!options.contains(.provisional))
    }

    @Test("an existing grant that never asked for badges is repaired")
    func authorizedWithoutBadgeIsRepaired() {
        #expect(AgentNotificationAuthorization.shouldRequestBadge(
            authorizationStatus: .authorized,
            badgeSetting: .notSupported
        ))
    }

    @Test(
        "no repair when badges are already on, or the user switched them off",
        arguments: [UNNotificationSetting.enabled, .disabled]
    )
    func authorizedWithBadgeDecisionIsLeftAlone(badgeSetting: UNNotificationSetting) {
        #expect(!AgentNotificationAuthorization.shouldRequestBadge(
            authorizationStatus: .authorized,
            badgeSetting: badgeSetting
        ))
    }

    /// Undecided would raise the permission prompt at launch; provisional
    /// would be prompted to upgrade; denied is the user's answer.
    @Test(
        "launch never re-requests outside a full grant",
        arguments: [UNAuthorizationStatus.notDetermined, .denied, .provisional]
    )
    func otherStatusesAreLeftAlone(status: UNAuthorizationStatus) {
        #expect(!AgentNotificationAuthorization.shouldRequestBadge(
            authorizationStatus: status,
            badgeSetting: .notSupported
        ))
    }
}
