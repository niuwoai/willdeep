//
//  AgentNotificationIcon.swift
//  WillDeep
//
//  System notifications on macOS show the *delivering app's* bundle icon by
//  default — but for an unsigned / Xcode-run dev build that fallback is often
//  the generic placeholder rather than the WillDeep logo, so banners looked
//  inconsistent with the Dock icon. We fix that by attaching the running app
//  icon (`NSApp.applicationIconImage`) as a UNNotificationAttachment, which
//  forces every WillDeep banner to render the same logo the user sees in the
//  Dock. Added in 1.78.0-rc15.
//
//  Every attachment gets its OWN temp file (1.404.0-rc2). Once a request is
//  added, UserNotifications MOVES the attachment file into its data store, so
//  the single cached file we used to share only survived the first post; from
//  the second notification on usernoted failed with "file does not exist" and
//  dropped the whole request — banner, sound and all. `UNNotificationAttachment`
//  does not check that the file exists when it is created, so the failure only
//  ever showed up asynchronously inside usernoted.
//

import AppKit
import Foundation
import os
import UserNotifications

private let notificationIconLog = Logger(subsystem: "com.willdeep.app", category: "notification-icon")

enum AgentNotificationIcon {
    static let attachmentIdentifier = "willdeep.icon"

    /// Holds only the per-notification icon files, so the stale sweep never
    /// touches anything else in the temp dir.
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("willdeep-notification-icons", isDirectory: true)

    /// A file still in `directory` after this long was never handed to
    /// usernoted (notifications denied, request suppressed under tests, add
    /// failed); successful posts move theirs out within seconds. Generous
    /// enough to cover the first post waiting on the authorization prompt.
    static let staleFileAge: TimeInterval = 60 * 60

    /// PNG bytes of the running app icon, rendered once and kept in memory.
    /// Only the bytes are cached — the file on disk is per notification.
    private static let iconPNGData: Data? = {
        guard let image = NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) else {
            notificationIconLog.error("notification icon unavailable: no application icon image")
            return nil
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            notificationIconLog.error("notification icon unavailable: PNG encoding of the application icon failed")
            return nil
        }
        return png
    }()

    /// Build a fresh attachment for one notification. Must be called on the
    /// main actor (it reads `NSApp`) and BEFORE entering the background
    /// `getNotificationSettings` completion — never inside it.
    @MainActor
    static func attachment() -> UNNotificationAttachment? {
        guard let png = iconPNGData else { return nil }
        return attachment(pngData: png, in: directory)
    }

    /// Writes `pngData` to a uniquely named file in `directory` and wraps it in
    /// an attachment. Returns nil (after logging and removing the file) on any
    /// failure — a banner without our icon beats no banner at all.
    static func attachment(
        pngData: Data,
        in directory: URL,
        now: Date = Date()
    ) -> UNNotificationAttachment? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            notificationIconLog.error(
                "notification icon: cannot create \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
        removeStaleFiles(in: directory, olderThan: now.addingTimeInterval(-staleFileAge))

        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        do {
            try pngData.write(to: url, options: .atomic)
        } catch {
            notificationIconLog.error(
                "notification icon: cannot write \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            removeFile(at: url)
            return nil
        }
        do {
            return try UNNotificationAttachment(identifier: attachmentIdentifier, url: url, options: nil)
        } catch {
            notificationIconLog.error(
                "notification icon: attachment rejected \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            removeFile(at: url)
            return nil
        }
    }

    private static func removeStaleFiles(in directory: URL, olderThan cutoff: Date) {
        let fileManager = FileManager.default
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            notificationIconLog.error(
                "notification icon: cannot list \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        for entry in entries {
            let modified: Date?
            do {
                modified = try entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            } catch {
                notificationIconLog.error(
                    "notification icon: cannot stat \(entry.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
            if let modified, modified < cutoff {
                removeFile(at: entry)
            }
        }
    }

    private static func removeFile(at url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            notificationIconLog.error(
                "notification icon: cannot remove \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
