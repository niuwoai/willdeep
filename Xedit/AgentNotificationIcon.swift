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

import AppKit
import Foundation
import UserNotifications

enum AgentNotificationIcon {
    /// PNG of the running app icon, written once to the temp dir and reused
    /// across every notification post. UN copies the file into its own store
    /// when the attachment is created, so a single cached file is enough.
    private static let iconFileURL: URL? = {
        let image = NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
        guard let tiff = image?.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-notification-icon.png")
        do {
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }()

    /// Build a fresh attachment for one notification. Must be called on the
    /// main actor (it reads `NSApp`) and BEFORE entering the background
    /// `getNotificationSettings` completion — never inside it.
    @MainActor
    static func attachment() -> UNNotificationAttachment? {
        guard let url = iconFileURL else { return nil }
        return try? UNNotificationAttachment(identifier: "willdeep.icon", url: url, options: nil)
    }
}
