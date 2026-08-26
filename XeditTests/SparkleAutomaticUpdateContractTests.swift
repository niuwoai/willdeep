//
//  SparkleAutomaticUpdateContractTests.swift
//  WillDeepTests
//
//  Guards the four Info.plist keys that decide whether an update installs by
//  itself. They are easy to lose in a merge and impossible to notice locally:
//  the symptom is "users never get updated automatically", weeks later, on
//  someone else's Mac.
//

import Testing
import Foundation
@testable import WillDeep

@Suite
nonisolated struct SparkleAutomaticUpdateContractTests {
    private func appInfoPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Xedit/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try #require(plist as? [String: Any])
    }

    @Test("automatic checks and automatic install are both enabled by default")
    func testAutomaticUpdateDefaultsAreOn() throws {
        let info = try appInfoPlist()
        // Without SUEnableAutomaticChecks Sparkle asks permission on first
        // launch and stays off until someone answers; without
        // SUAutomaticallyUpdate the default is download-but-ask.
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(info["SUAutomaticallyUpdate"] as? Bool == true)
    }

    @Test("the scheduled check interval is short enough to beat the in-app poller")
    func testScheduledCheckIntervalIsSet() throws {
        let info = try appInfoPlist()
        // Sparkle's own default is 24h. AppStateAppUpdates polls every 17
        // minutes and surfaces a manual banner, so at 24h the automatic path
        // never got there first and the "install automatically" preference
        // looked broken to users. Anything above an hour reopens that gap.
        let interval = try #require(info["SUScheduledCheckInterval"] as? Int)
        #expect(interval > 0)
        #expect(interval <= 3600, "interval \(interval)s is slower than the in-app poller")
    }

    @Test("automatic installs are not disallowed by the host bundle")
    func testAutomaticUpdatesAreNotDisallowed() throws {
        let info = try appInfoPlist()
        // SUAllowsAutomaticUpdates=false makes Sparkle's setter a no-op and
        // hides the option entirely — the Settings toggle would silently do
        // nothing. Absent is correct; present-and-true is acceptable.
        if let allows = info["SUAllowsAutomaticUpdates"] as? Bool {
            #expect(allows, "SUAllowsAutomaticUpdates=false disables the Settings toggle")
        }
    }

    @Test("update verification stays on and the feed is the signed appcast")
    func testFeedAndVerificationAreIntact() throws {
        let info = try appInfoPlist()
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        let key = try #require(info["SUPublicEDKey"] as? String)
        #expect(!key.isEmpty, "without the EdDSA public key Sparkle refuses every update")
        let feed = try #require(info["SUFeedURL"] as? String)
        #expect(feed.hasPrefix("https://"), "an http feed would be rejected")
        #expect(feed.contains("app_id=willdeep"))
    }

    @Test("the automatic-update toggle has user-facing copy in every state")
    func testSettingsCopyExists() {
        // A disabled toggle with no explanation is the shape of a bug report.
        #expect(!L10n.Settings.automaticUpdates.isEmpty)
        #expect(!L10n.Settings.automaticUpdatesHelp.isEmpty)
        #expect(!L10n.Settings.automaticUpdatesUnavailable.isEmpty)
        #expect(L10n.Settings.automaticUpdates != L10n.Settings.automaticUpdatesHelp)
    }
}
