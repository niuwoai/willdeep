//
//  AppUpdateSkipState.swift
//  WillDeep
//
//  Teaching the sidebar update banner about Sparkle's "skip this version".
//
//  There are two update surfaces in this app: Sparkle's own dialog, which
//  owns the signed download and the skip button, and a sidebar banner driven
//  by a separate 17-minute JSON poll. Only the first one knew about skipping,
//  and that asymmetry produced a bug that looked like the skip button was
//  broken:
//
//    1. The poll finds a new version and the banner appears. It has no
//       dismiss control, so it stays.
//    2. The user clicks it. That routes into Sparkle's *user-initiated*
//       check, which by Sparkle's contract always shows a dialog.
//    3. The user clicks 跳过这个版本. Sparkle writes SUSkippedMinorVersion.
//    4. The banner does not move — it never read that key — so the user
//       clicks it again. A user-initiated check calls
//       `_clearSkippedUpdatesIfUserInitiated`, which deletes the record, and
//       the same version is offered again.
//
//  The skip was written correctly every time and then erased by the only
//  affordance the user had. Making the banner honour the same state breaks
//  the loop at step 4: once skipped, the banner goes away, so nothing pushes
//  the user back through the user-initiated path.
//
//  The comparison mirrors Sparkle's own, in SUAppcastDriver's
//  `item:containsSkippedUpdate:`: an item is skipped when the recorded
//  version is greater than *or equal to* the candidate, not merely equal.
//

import Foundation

nonisolated enum AppUpdateSkipState {
    /// Sparkle's own defaults keys, written by SPUSkippedUpdate into the host
    /// bundle's domain — the same domain `UserDefaults.standard` reads from
    /// inside the app.
    static let skippedMinorVersionKey = "SUSkippedMinorVersion"
    static let skippedMajorVersionKey = "SUSkippedMajorVersion"

    /// Whether the banner should stay quiet about this build.
    ///
    /// `candidateBundleVersion` is the appcast's `sparkle:version`, which for
    /// this app is the integer build number — the same value Sparkle records
    /// when skipping. Comparing display versions here would be wrong: Sparkle
    /// never writes `1.365.0-rc1`, it writes `725`.
    ///
    /// Fails open on every uncertainty. A missing or unparseable value means
    /// the banner shows, because failing to offer an update is worse than
    /// offering one the user already waved away.
    static func skipsUpdate(
        candidateBundleVersion: Int?,
        skippedMinorVersion: String?
    ) -> Bool {
        guard let candidateBundleVersion else { return false }
        guard let skippedMinorVersion,
              let skipped = Int(skippedMinorVersion.trimmingCharacters(in: .whitespaces)) else {
            return false
        }
        return skipped >= candidateBundleVersion
    }

    /// Reads the live state. Major-upgrade skips are deliberately not
    /// consulted: Sparkle only writes `SUSkippedMajorVersion` for items
    /// carrying `minimumAutoupdateVersion`, this app's feed publishes none,
    /// and reproducing that comparison without an appcast item in hand would
    /// be guesswork in the direction of hiding updates.
    static func skipsUpdate(
        candidateBundleVersion: Int?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        skipsUpdate(
            candidateBundleVersion: candidateBundleVersion,
            skippedMinorVersion: defaults.string(forKey: skippedMinorVersionKey)
        )
    }
}
