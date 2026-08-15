//
//  AIPipeBootstrap.swift
//  WillDeep
//
//  Keeps AIPipe crash/log reporting optional at runtime. Release builds
//  compile the API configuration from a generated DerivedData source file;
//  credentials are never committed to the repository.
//

import AppKit
import Foundation
import UserNotifications

final class WillDeepAppDelegate: NSObject, NSApplicationDelegate {
    private var isFlushingBeforeTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wire the shared some.im login store before anything reads credentials:
        // sets the shared Keychain access group, migrates legacy per-app keys,
        // and starts forwarding cross-app login/logout changes.
        SomeIMIntegrationStore.configureSharedSession()
        guard !Self.isRunningUnderXCTest else { return }
        Self.refreshExistingCommandLineToolIfNeeded()
        // Skill discovery touches bundled, user, legacy, and plugin trees.
        // Warm the shared catalog away from AppKit's main thread so mobile
        // gateway snapshots and the first composer `$` menu are cache hits.
        _ = Task.detached(priority: .utility) {
            _ = AgentSkillDirectory.list(includeDisabled: true)
        }
        AIPipeBootstrap.initialize()
        ChromeNativeHostInstaller.installAtLaunch()
        // Route taps on agent approval / job notifications back to the
        // session that posted them (see AgentNotificationResponder).
        UNUserNotificationCenter.current().delegate = AgentNotificationResponder.shared
        MainActor.assumeIsolated {
            // The menu-bar status and local preview feed must outlive
            // AgentModeView navigation while another app is being controlled.
            AgentComputerUseStatusController.shared.install()
            // 手机网关(互联网中继)开机自连并常驻：不再等用户打开设置页，
            // 保证配对过的手机在任何网络下都能连上桌面。全局单点，多窗口只
            // 维持一份中继连接。
            MobileGatewayAutostart.shared.startIfNeeded()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let fileURL = WillDeepExternalURLParser.fileURL(fromOpenURL: url) else { continue }
            NSWorkspace.shared.open(fileURL)
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            NSWorkspace.shared.open(URL(fileURLWithPath: filename))
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AIPipe.flush()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFlushingBeforeTermination else { return .terminateLater }
        guard AppTerminationGuard.shouldAllowTermination(
            appStates: EditorAppStateRegistry.shared.appStatesForTerminationCheck
        ) else {
            return .terminateCancel
        }
        isFlushingBeforeTermination = true
        AIPipe.flush()
        // Do not synchronously block AppKit while a large transcript is still
        // encoding/writing. macOS keeps the app alive until we reply, while the
        // main run loop remains responsive instead of showing a beachball.
        DispatchQueue.global(qos: .utility).async {
            AgentSessionStore.flushPendingWrites()
            DispatchQueue.main.async {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static func refreshExistingCommandLineToolIfNeeded() {
        guard CommandLineToolInstaller.installState() == .needsUpdate else {
            return
        }

        do {
            try CommandLineToolInstaller.install()
        } catch {
            NSLog("WillDeep command-line tool refresh failed: %@", error.localizedDescription)
        }
    }
}

enum AIPipeBootstrap {
    private static let defaultEndpoint = "https://17push.com/api/v1"

    static func initialize(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        compiledConfiguration: AIPipeBuildConfiguration = .generated,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        reportingInitializer: (AIPipeConfig) -> Void = { config in
            AIPipe.initialize(with: config)
            AIPipe.log(withLevel: "INFO", content: "WillDeep started")
        }
    ) {
        guard let apiKey = firstNonEmpty(
            environment["AIPIPE_API_KEY"],
            compiledConfiguration.apiKey,
            infoDictionary["AIPipeAPIKey"] as? String
        ) else {
            return
        }

        let endpoint = firstNonEmpty(
            environment["AIPIPE_ENDPOINT"],
            compiledConfiguration.endpoint,
            infoDictionary["AIPipeEndpoint"] as? String
        ) ?? defaultEndpoint

        let config = AIPipeConfig.default()
        config.apiKey = apiKey
        config.endpoint = endpoint
        config.source = "macos"
        config.format = "macos"
        config.topic = firstNonEmpty(
            environment["AIPIPE_TOPIC"],
            compiledConfiguration.topic,
            infoDictionary["AIPipeTopic"] as? String
        )
        config.enabled = true
        reportingInitializer(config)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty, !isUnexpandedBuildSetting(trimmed) {
                return trimmed
            }
        }
        return nil
    }

    private static func isUnexpandedBuildSetting(_ value: String) -> Bool {
        value.hasPrefix("$(") && value.hasSuffix(")")
    }
}

struct AIPipeBuildConfiguration {
    let apiKey: String
    let endpoint: String
    let topic: String

    static let empty = AIPipeBuildConfiguration(apiKey: "", endpoint: "", topic: "")

    static var generated: AIPipeBuildConfiguration {
        AIPipeBuildConfiguration(
            apiKey: AIPipeGeneratedBuildConfiguration.apiKey,
            endpoint: AIPipeGeneratedBuildConfiguration.endpoint,
            topic: AIPipeGeneratedBuildConfiguration.topic
        )
    }
}
