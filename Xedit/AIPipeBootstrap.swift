//
//  AIPipeBootstrap.swift
//  WillDeep
//
//  Keeps AIPipe crash/log reporting optional at runtime. The API key
//  must come from the environment or an external Info.plist injection;
//  never commit it into source.
//

import AppKit
import Foundation
import UserNotifications

final class WillDeepAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AIPipeBootstrap.initialize()
        AppUpdateChecker.checkForUpdatesOnLaunch()
        // Route taps on agent approval / job notifications back to the
        // session that posted them (see AgentNotificationResponder).
        UNUserNotificationCenter.current().delegate = AgentNotificationResponder.shared
        MainActor.assumeIsolated {
            FnPushToTalkMonitor.shared.install()
            VoiceModelLifecycleController.shared.install()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AIPipe.flush()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AIPipe.flush()
        return .terminateNow
    }
}

enum AIPipeBootstrap {
    private static let defaultEndpoint = "https://17push.com/api/v1"

    static func initialize(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) {
        guard let apiKey = firstNonEmpty(
            environment["AIPIPE_API_KEY"],
            infoDictionary["AIPipeAPIKey"] as? String
        ) else {
            return
        }

        let endpoint = firstNonEmpty(
            environment["AIPIPE_ENDPOINT"],
            infoDictionary["AIPipeEndpoint"] as? String
        ) ?? defaultEndpoint

        let config = AIPipeConfig.default()
        config.apiKey = apiKey
        config.endpoint = endpoint
        config.source = "macos"
        config.format = "macos"
        config.topic = firstNonEmpty(
            environment["AIPIPE_TOPIC"],
            infoDictionary["AIPipeTopic"] as? String
        )
        config.enabled = true
        AIPipe.initialize(with: config)
        AIPipe.log(withLevel: "INFO", content: "WillDeep started")
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}
