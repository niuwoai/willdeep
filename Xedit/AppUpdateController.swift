//
//  AppUpdateController.swift
//  WillDeep
//
//  Sparkle owns the privileged install handoff: it downloads and verifies the
//  signed DMG, waits for WillDeep to terminate, atomically replaces the app,
//  rolls back on failure, and relaunches the installed version.
//

import Foundation
import Sparkle

@MainActor
final class AppUpdateController: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdateController()

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private var hasStarted = false

    private override init() {
        super.init()
    }

    func start() {
        guard !hasStarted, !Self.isRunningTests else { return }
        updaterController.startUpdater()
        hasStarted = true
    }

    func checkForUpdates() {
        guard !Self.isRunningTests else { return }
        start()
        updaterController.checkForUpdates(nil)
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated {
            AppUpdateChecker.managedAppcastURL()?.absoluteString
        }
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
